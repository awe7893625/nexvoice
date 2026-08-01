import AppKit
import Darwin
import Foundation

enum VoiceRuntimeState: Equatable {
    case disabled
    case idle
    case arming
    case recording
    case transcribing(STTRoute)
    case cleaning
    case pasting
    case complete(String)
    case cancelled
    case failed(String)

    var label: String {
        switch self {
        case .disabled: "已停用"
        case .idle: "就緒"
        case .arming: "準備錄音"
        case .recording: "錄音中"
        case .transcribing(let route): "轉錄中 · \(route.rawValue)"
        case .cleaning: "整理中"
        case .pasting: "貼上中"
        case .complete(let message): message
        case .cancelled: "已取消"
        case .failed(let message): message
        }
    }
}

enum VoiceRuntimeError: LocalizedError {
    case microphoneDenied
    case accessibilityDenied
    case recordingFailed
    case legacyTriggerStillActive
    case monitorInstallationFailed
    case tooShort
    case rejectedTranscript

    var errorDescription: String? {
        switch self {
        case .microphoneDenied: "未取得麥克風權限"
        case .accessibilityDenied: "未取得輔助使用權限，NexVoice 未接管快捷鍵"
        case .recordingFailed: "無法開始錄音"
        case .legacyTriggerStillActive: "無法停用 Hammerspoon trigger"
        case .monitorInstallationFailed: "無法安裝全域快捷鍵監聽，已恢復原語音工具"
        case .tooShort: "錄音時間太短"
        case .rejectedTranscript: "內容過短或疑似幻聽，未貼上"
        }
    }
}

@MainActor
final class VoiceRuntimeController {
    var onStateChange: ((VoiceRuntimeState) -> Void)?
    var onTranscript: ((String) -> Void)?
    var preferencesProvider: (() -> RuntimePreferences)?
    var vocabularyProvider: (() -> [VocabEntry])?

    private(set) var state: VoiceRuntimeState = .disabled {
        didSet {
            onStateChange?(state)
            applyPendingHotkeyProfileIfPossible()
        }
    }

    private let recorder = AudioRecorderService()
    private let api = VoiceAPI()
    private let routing = RoutingPolicy()
    private let hud = CompactRecorderHUD()
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?
    private var pipelineTask: Task<Void, Never>?
    private var maxDurationTask: Task<Void, Never>?
    private var liveTranscriptTask: Task<Void, Never>?
    private var currentSession: UUID?
    private var targetApplication: NSRunningApplication?
    private var hotkeyEngine = HotkeyGestureEngine()
    private var pendingHotkeyProfile: HotkeyProfile?
    private var ownershipGeneration = 0
    private var desiredOwner: HotkeyOwner = .legacy
    private let ownershipMutex = AsyncMutex()
    private var pasteGate = SessionPasteGate()
    private var selectedTextAtArm: String?
    private var liveCaptionsEnabled = true
    private var activeVocabulary: [VocabEntry] = []
    private var liveTranscriptSequence = 0
    private(set) var lastSuccessfulText = ""

    func restoreLastSuccessfulText(_ text: String) {
        lastSuccessfulText = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func updateHUDPreferences(style: HUDStyle, chrome: HUDChrome, liveCaptionsEnabled: Bool, subtitleStyle: SubtitleStyle) {
        self.liveCaptionsEnabled = liveCaptionsEnabled
        hud.configure(style: style, chrome: chrome, liveCaptionsEnabled: liveCaptionsEnabled, subtitleStyle: subtitleStyle)
        if !liveCaptionsEnabled {
            liveTranscriptTask?.cancel()
            liveTranscriptTask = nil
        }
    }

    func updateHotkeyProfile(_ profile: HotkeyProfile) {
        guard state == .disabled || state == .idle || state.isTerminal else {
            pendingHotkeyProfile = profile
            return
        }
        pendingHotkeyProfile = nil
        hotkeyEngine.setProfile(profile)
        DiagnosticLog.log("hotkey profile applied: \(profile.trigger.rawValue)/\(profile.behavior.rawValue)")
    }

    init() {
        installLiveMeter()
    }

    /// Single definition of "the HUD listens to the microphone" -- preview mode
    /// swaps it out and must restore exactly this, not a copy that can drift.
    private func installLiveMeter() {
        hud.bypassNoiseGate = false
        hud.meterProvider = { [weak self] in self?.recorder.meterLevel() ?? 0 }
    }

    func enable() async throws {
        ownershipGeneration &+= 1
        let generation = ownershipGeneration
        desiredOwner = .native
        await ownershipMutex.lock()
        do {
            try ensureOwnershipGeneration(generation)
            try await enableLocked(generation: generation)
            await ownershipMutex.unlock()
        } catch {
            await ownershipMutex.unlock()
            throw error
        }
    }

    private func enableLocked(generation: Int) async throws {
        if state != .disabled {
            // Re-install monitors if somehow dropped while already enabled.
            _ = installMonitors()
            DiagnosticLog.log("enable(): already \(state), re-installed monitors")
            return
        }

        // Permission preflight must not change ownership or trigger another TCC
        // prompt. If either permission is missing, legacy remains untouched.
        guard await recorder.requestPermission() else {
            DiagnosticLog.log("enable(): FAILED — microphone permission denied")
            throw VoiceRuntimeError.microphoneDenied
        }
        try ensureOwnershipGeneration(generation)
        guard AXIsProcessTrusted() else {
            DiagnosticLog.log("enable(): FAILED — Accessibility not trusted; legacy untouched")
            throw VoiceRuntimeError.accessibilityDenied
        }

        var legacyStopped = await LegacyBridge.transition(to: .native)
        DiagnosticLog.log("enable(): legacy bridge=\(legacyStopped.diagnosticLabel)")
        if legacyStopped == .timeout, generation == ownershipGeneration {
            // A timeout is the one transient failure mode here (a busy
            // Hammerspoon IPC channel), and a failed enable persists
            // "disabled" until the user manually re-enables -- worth one
            // bounded retry before giving up.
            try? await Task.sleep(for: .milliseconds(300))
            if generation == ownershipGeneration {
                legacyStopped = await LegacyBridge.transition(to: .native)
                DiagnosticLog.log("enable(): legacy bridge retry=\(legacyStopped.diagnosticLabel)")
            }
        }
        if generation != ownershipGeneration {
            _ = await LegacyBridge.transition(to: desiredOwner)
            throw CancellationError()
        }
        guard legacyStopped.succeeded else {
            throw VoiceRuntimeError.legacyTriggerStillActive
        }

        guard installMonitors() else {
            removeMonitors()
            let rollbackTarget: HotkeyOwner = generation == ownershipGeneration ? .legacy : desiredOwner
            let rollback = await LegacyBridge.transition(to: rollbackTarget)
            DiagnosticLog.log("enable(): monitor install failed; rollback=\(rollback.diagnosticLabel)")
            throw VoiceRuntimeError.monitorInstallationFailed
        }
        state = .idle
        DiagnosticLog.log("enable(): OK, state=idle, owner=native, AXIsProcessTrusted=true")
    }

    @discardableResult
    func disable(destination: HotkeyOwner = .legacy) async -> LegacyBridgeResult {
        ownershipGeneration &+= 1
        let generation = ownershipGeneration
        desiredOwner = destination
        await ownershipMutex.lock()
        let target = generation == ownershipGeneration ? destination : desiredOwner
        cancelCurrentSession()
        removeMonitors()
        let result = await LegacyBridge.transition(to: target)
        DiagnosticLog.log("disable(): destination=\(target.rawValue), bridge=\(result.diagnosticLabel)")
        hud.hide()
        state = .disabled
        await ownershipMutex.unlock()
        return result
    }

    func previewCompactHUD(thinking: Bool = false, duration: TimeInterval = 3) {
        // No recorder runs during a preview, so the real meter would report
        // silence -- and since motion now follows the voice, the HUD would sit
        // still and the screenshot loop would show nothing. Feed it the same
        // synthetic breath the settings tiles use, and bypass the room-tone
        // gate: that envelope has no syllable gaps for min-hold to latch onto.
        hud.bypassNoiseGate = true
        hud.meterProvider = {
            nexVoiceHUDPreviewSignal(at: Date().timeIntervalSinceReferenceDate).level
        }
        hud.show()
        if thinking { hud.showBusy() }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard let self else { return }
            self.hud.hide()
            self.installLiveMeter()
        }
    }

    @discardableResult
    private func installMonitors() -> Bool {
        // Global: other apps focused. Local: NexVoice itself focused.
        // Without both, Option feels "dead" half the time.
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .keyUp]
        if globalMonitor == nil {
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
                Task { @MainActor in self?.handle(event) }
            }
        }
        if localMonitor == nil {
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
                Task { @MainActor in self?.handle(event) }
                return event
            }
        }
        if eventTap == nil {
            let mask = (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
                | (CGEventMask(1) << CGEventType.keyDown.rawValue)
                | (CGEventMask(1) << CGEventType.keyUp.rawValue)
            let refcon = Unmanaged.passUnretained(self).toOpaque()
            eventTap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .listenOnly,
                eventsOfInterest: mask,
                callback: { _, type, event, refcon in
                    guard let refcon else { return Unmanaged.passUnretained(event) }
                    let controller = Unmanaged<VoiceRuntimeController>
                        .fromOpaque(refcon).takeUnretainedValue()
                    if let nsEvent = NSEvent(cgEvent: event) {
                        Task { @MainActor in controller.handle(nsEvent) }
                    }
                    return Unmanaged.passUnretained(event)
                },
                userInfo: refcon
            )
            if let eventTap {
                eventTapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
                if let eventTapSource {
                    CFRunLoopAddSource(CFRunLoopGetMain(), eventTapSource, .commonModes)
                }
            } else {
                DiagnosticLog.log("CGEvent tap unavailable; relying on AppKit monitors")
            }
        }
        DiagnosticLog.log("hotkey monitors installed: appkit=\(globalMonitor != nil && localMonitor != nil), eventTap=\(eventTap != nil)")
        return globalMonitor != nil && localMonitor != nil
    }

    private func removeMonitors() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        globalMonitor = nil
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        localMonitor = nil
        if let eventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), eventTapSource, .commonModes)
        }
        if let eventTap { CFMachPortInvalidate(eventTap) }
        eventTapSource = nil
        eventTap = nil
    }

    private func handle(_ event: NSEvent) {
        guard state != .disabled else { return }
        if event.type == .flagsChanged {
            DiagnosticLog.logVerbose("hotkey flags event keyCode=\(event.keyCode) flags=\(event.modifierFlags.rawValue)")
        }
        if event.type == .keyDown {
            if event.keyCode == 53 {
                cancelCurrentSession()
                state = .cancelled
                return
            }
            cancelHotkeyGestureForChordIfNeeded()
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let optionCmd = flags.contains(.option) && flags.contains(.command)
                && !flags.contains(.control) && !flags.contains(.shift)
            // ⌥⌘V — repaste last successful transcript once into current focus.
            if optionCmd, event.keyCode == 9 {
                Task { await repasteLast() }
                return
            }
            // ⌥⌘D — dispatch draft only (pending_approval, never auto-run).
            if optionCmd, event.keyCode == 2 {
                dispatchLastDraft()
                return
            }
            return
        }

        guard let phase = hotkeyPhase(for: event) else { return }
        let action = hotkeyEngine.handle(
            phase,
            isRecording: state == .recording,
            canStart: state == .idle || state.isTerminal
        )
        switch action {
        case .startRecording:
            DiagnosticLog.log("hotkey start: \(hotkeyEngine.profile.trigger.rawValue)/\(hotkeyEngine.profile.behavior.rawValue)")
            startRecording()
        case .finishRecording:
            DiagnosticLog.log("hotkey finish: \(hotkeyEngine.profile.trigger.rawValue)/\(hotkeyEngine.profile.behavior.rawValue)")
            finishRecordingNow()
        case .cancelRecording:
            cancelCurrentSession()
            state = .cancelled
        case .none:
            break
        }
    }

    func repasteLast() async {
        let text = lastSuccessfulText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            state = .failed("沒有可重貼的內容")
            return
        }
        guard state == .idle || state.isTerminal else { return }
        let session = UUID()
        currentSession = session
        pasteGate.begin(session: session)
        guard pasteGate.claimPaste(session: session) else { return }
        state = .pasting
        let target = NSWorkspace.shared.frontmostApplication
        let outcome = await PasteService.insertOnce(text, target: target)
        guard currentSession == session else { return }
        currentSession = nil
        state = .complete(outcome == .pasted ? "已重貼 · \(text.count) 字" : "已複製 · \(text.count) 字")
    }

    func dispatchLastDraft() {
        let text = lastSuccessfulText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            state = .failed("沒有可派工的文字")
            return
        }
        do {
            let entry = try DispatchDraftStore.create(text: text)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            state = .complete("派工草稿 · \(entry.id)")
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func startRecording() {
        guard state == .idle || state.isTerminal else { return }
        let session = UUID()
        currentSession = session
        activeVocabulary = VocabularyPolicy.sanitizedEntries(
            vocabularyProvider?() ?? VocabStore.loadCached()
        )
        liveTranscriptSequence = 0
        pasteGate.begin(session: session)
        targetApplication = NSWorkspace.shared.frontmostApplication
        selectedTextAtArm = SelectionService.selectedText()
        do {
            try recorder.start(session: session)
            state = .recording
            hud.show()
            if liveCaptionsEnabled { startLiveTranscript(session: session) }
            scheduleMaxDurationCap(session: session)
        } catch {
            currentSession = nil
            selectedTextAtArm = nil
            activeVocabulary = []
            state = .failed(error.localizedDescription)
        }
    }

    private func scheduleMaxDurationCap(session: UUID) {
        maxDurationTask?.cancel()
        maxDurationTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(RecordingLimits.maxDurationSeconds))
            guard let self, !Task.isCancelled else { return }
            guard self.currentSession == session, self.state == .recording else { return }
            self.finishRecordingNow()
        }
    }

    private func finishRecordingNow() {
        guard state == .recording, let session = currentSession else { return }
        guard let recording = recorder.stop() else {
            // A recorder that produced nothing must not leave the session
            // stuck in .recording with the HUD on screen forever.
            DiagnosticLog.log("finishRecordingNow: recorder.stop() returned nil, resetting session")
            maxDurationTask?.cancel()
            maxDurationTask = nil
            liveTranscriptTask?.cancel()
            liveTranscriptTask = nil
            currentSession = nil
            activeVocabulary = []
            hud.hide()
            state = .failed("錄音檔無法讀取")
            return
        }
        maxDurationTask?.cancel()
        maxDurationTask = nil
        liveTranscriptTask?.cancel()
        liveTranscriptTask = nil
        guard recording.duration >= RecordingLimits.minDurationSeconds else {
            try? FileManager.default.removeItem(at: recording.url)
            currentSession = nil
            activeVocabulary = []
            hud.hide()
            state = .idle
            return
        }
        hud.showBusy("轉錄中…")
        startPipeline(
            session: session,
            fileURL: recording.url,
            selected: selectedTextAtArm,
            vocabulary: activeVocabulary
        )
        selectedTextAtArm = nil
    }

    private func startPipeline(
        session: UUID,
        fileURL: URL,
        selected: String?,
        vocabulary: [VocabEntry]
    ) {
        pipelineTask?.cancel()
        pipelineTask = Task { [weak self] in
            guard let self else { return }
            var preserveRecording = false
            defer {
                if preserveRecording {
                    Self.preserveFailedRecording(at: fileURL)
                } else {
                    try? FileManager.default.removeItem(at: fileURL)
                }
            }
            do {
                let prefs = currentPreferences()
                let preferred = routing.choose(prefs.snapshot)
                guard preferred != .unavailable else {
                    throw VoiceAPIError.serviceUnavailable(
                        prefs.privacyMode
                            ? "隱私模式需要本機 MLX 可用"
                            : "沒有可用的轉錄路由"
                    )
                }

                hud.showBusy("轉錄中…")
                let transcription = try await transcribe(
                    fileURL: fileURL,
                    preferred: preferred,
                    privacyMode: prefs.privacyMode,
                    allowCloudFallback: prefs.allowsCloudSTT,
                    session: session,
                    vocabulary: vocabulary
                )
                try ensureCurrent(session)

                let transcriptText = transcription.text
                let raw = await Task.detached(priority: .userInitiated) {
                    LocalTranscriptPostprocessor.process(
                        transcriptText,
                        vocabulary: vocabulary
                    )
                }.value
                guard let instruction = TranscriptGuards.sanitize(raw) else {
                    throw VoiceRuntimeError.rejectedTranscript
                }

                // Speak-to-edit / speak-to-ask when user had a selection at arm time.
                if let selected, !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    if prefs.privacyMode {
                        throw VoiceAPIError.serviceUnavailable("隱私模式不支援選區改寫／問答（需雲端整理）")
                    }
                    guard prefs.allowsCloudText else {
                        throw VoiceAPIError.serviceUnavailable(
                            "零費用／本機模式尚未啟用選區改寫與問答；不會自動呼叫雲端 API"
                        )
                    }
                    let kind = SelectionService.classifyInstruction(instruction)
                    let result: String?
                    if kind == .ask {
                        hud.showBusy("回答中…")
                        state = .cleaning
                        result = await api.answerAboutSelected(selected: selected, question: instruction)
                    } else {
                        hud.showBusy("改寫中…")
                        state = .cleaning
                        result = await api.editSelected(selected: selected, instruction: instruction)
                    }
                    try ensureCurrent(session)
                    guard let result,
                          let output = TranscriptGuards.sanitize(result)
                    else {
                        throw VoiceAPIError.serviceUnavailable(
                            "選區改寫／問答服務沒有可用結果，原文未變更"
                        )
                    }
                    guard pasteGate.claimPaste(session: session) else { return }
                    hud.showBusy("貼上中…")
                    state = .pasting
                    // Ask mode: paste answer without replacing selection intent —
                    // still insert at caret / clipboard (Cmd+V path).
                    let outcome = await PasteService.insertOnce(output, target: targetApplication)
                    try ensureCurrent(session)
                    lastSuccessfulText = output
                    LocalHistoryStore.append(text: output, route: transcription.route)
                    onTranscript?(output)
                    currentSession = nil
                    activeVocabulary = []
                    hud.hide()
                    let verb = kind == .ask ? "已回答" : "已改寫"
                    state = .complete(
                        outcome == .pasted
                            ? "\(verb) · \(output.count) 字"
                            : "已複製 · \(output.count) 字"
                    )
                    return
                }

                let prepared: String
                let livePrefs = currentPreferences()
                let wantsSmartFormat = livePrefs.smartFormatEnabled
                    && livePrefs.allowsCloudText
                    && instruction.count >= SmartFormatPolicy.minimumCharacters
                var organized: String?
                if wantsSmartFormat {
                    hud.showBusy("整理重點中…")
                    state = .cleaning
                    organized = await api.organize(instruction, appContext: targetApplication?.localizedName)
                    if organized == nil {
                        DiagnosticLog.log("smart format unavailable, falling back to cleanup lane")
                    }
                }
                if let organized {
                    // Organized output is already deliberately formatted (bullets/numbering);
                    // the prose postprocessor would append 。 to every bullet, so it is
                    // skipped here and only the transcript guards run below.
                    prepared = organized
                } else if livePrefs.cleanupEnabled && livePrefs.allowsCloudText {
                    hud.showBusy("整理中…")
                    state = .cleaning
                    let cleaned = await api.clean(instruction, appContext: targetApplication?.localizedName)
                    prepared = await Task.detached(priority: .userInitiated) {
                        LocalTranscriptPostprocessor.process(
                            cleaned,
                            vocabulary: vocabulary
                        )
                    }.value
                } else {
                    prepared = instruction
                }
                try ensureCurrent(session)

                guard let text = TranscriptGuards.sanitize(prepared) else {
                    throw VoiceRuntimeError.rejectedTranscript
                }

                guard pasteGate.claimPaste(session: session) else { return }
                hud.showBusy("貼上中…")
                state = .pasting
                let outcome = await PasteService.insertOnce(text, target: targetApplication)
                try ensureCurrent(session)
                lastSuccessfulText = text
                LocalHistoryStore.append(text: text, route: transcription.route)
                onTranscript?(text)
                currentSession = nil
                activeVocabulary = []
                hud.hide()
                state = .complete(outcome == .pasted ? "已貼上 · \(text.count) 字" : "已複製 · \(text.count) 字")
            } catch is CancellationError {
                guard currentSession == session else { return }
                currentSession = nil
                activeVocabulary = []
                state = .cancelled
                hud.hide()
            } catch {
                guard currentSession == session else { return }
                // The recording is the only copy of what the user said; a
                // failed pipeline must never destroy it.
                preserveRecording = true
                DiagnosticLog.log("pipeline FAILED session=\(session.uuidString.prefix(8)): \(error.localizedDescription)")
                currentSession = nil
                activeVocabulary = []
                hud.hide()
                state = .failed("\(error.localizedDescription)（錄音已保留）")
            }
        }
    }

    /// Typeless-style live caption preview. It samples the growing WAV without
    /// interrupting recording; the final stopped file still owns the canonical
    /// transcript and paste operation.
    private func startLiveTranscript(session: UUID) {
        liveTranscriptTask?.cancel()
        liveTranscriptTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(1_800))
                guard !Task.isCancelled, self.currentSession == session,
                      self.state == .recording, let source = self.recorder.outputURL
                else { continue }
                let temp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("nexvoice-live-\(session.uuidString).wav")
                do {
                    // AVAudioRecorder's own header stays stale (0 frames)
                    // until stop() finalizes it, so a raw file copy always
                    // produces an unreadable/empty sample here. Reconstruct
                    // a header from the actual bytes present so far instead.
                    let rawBytes = try Data(contentsOf: source)
                    guard let readableSnapshot = GrowingWAVReader.snapshot(of: rawBytes) else { continue }
                    try readableSnapshot.write(to: temp)
                    defer { try? FileManager.default.removeItem(at: temp) }
                    self.liveTranscriptSequence += 1
                    let sequence = self.liveTranscriptSequence
                    let partial = try await self.api.transcribeLocal(
                        fileURL: temp,
                        partial: true,
                        sessionID: session,
                        sequence: sequence,
                        vocabulary: self.activeVocabulary
                    )
                    guard self.currentSession == session,
                          self.state == .recording,
                          sequence == self.liveTranscriptSequence
                    else { continue }
                    let partialText = partial.text
                    let vocabulary = self.activeVocabulary
                    let preview = await Task.detached(priority: .utility) {
                        LocalTranscriptPostprocessor.preview(
                            partialText,
                            vocabulary: vocabulary
                        )
                    }.value
                    guard self.currentSession == session,
                          self.state == .recording,
                          sequence == self.liveTranscriptSequence
                    else { continue }
                    self.hud.showPartial(preview)
                } catch {
                    // Partial captions are best-effort; never interrupt recording.
                }
            }
        }
    }

    private func currentPreferences() -> RuntimePreferences {
        preferencesProvider?() ?? RuntimePreferences(
            privacyMode: false,
            cleanupEnabled: true,
            smartFormatEnabled: false,
            localEnabled: true,
            localHealthy: true,
            overloaded: SystemLoad.isOverloaded,
            groqConfigured: SecretStore.isSecureSecret(named: ".groq_key"),
            cloudSTTAllowed: false,
            cloudTextAllowed: false,
            cloudTextConfigured: false
        )
    }

    private func transcribe(
        fileURL: URL,
        preferred: STTRoute,
        privacyMode: Bool,
        allowCloudFallback: Bool,
        session: UUID,
        vocabulary: [VocabEntry]
    ) async throws -> TranscriptionResult {
        switch preferred {
        case .localMLX:
            state = .transcribing(.localMLX)
            do {
                do {
                    return try await api.transcribeLocal(
                        fileURL: fileURL,
                        sessionID: session,
                        vocabulary: vocabulary
                    )
                } catch let error where Self.isTransientLocalError(error) {
                    // One bounded retry: a 409 (live-caption pass still holding
                    // the model) or a dropped/timed-out connection is transient;
                    // giving up immediately throws the whole recording away.
                    // A refused connection means the helper died and the 5s
                    // supervisor loop is respawning it -- wait long enough for
                    // that instead of retrying into the same dead socket.
                    let connectionDown = (error as? URLError).map {
                        [.cannotConnectToHost, .cannotFindHost, .networkConnectionLost].contains($0.code)
                    } ?? false
                    DiagnosticLog.log("transcribe local transient error, retrying once: \(error.localizedDescription)")
                    try await Task.sleep(for: connectionDown ? .seconds(6) : .milliseconds(800))
                    try ensureCurrent(session)
                    return try await api.transcribeLocal(
                        fileURL: fileURL,
                        sessionID: session,
                        vocabulary: vocabulary
                    )
                }
            } catch {
                // Re-read capability immediately before uploading. Settings may
                // have changed while the local helper was timing out.
                let live = currentPreferences()
                if privacyMode || !allowCloudFallback || !live.allowsCloudSTT || live.privacyMode {
                    throw error
                }
                DiagnosticLog.log("transcribe local failed, falling back to Groq: \(error.localizedDescription)")
                state = .transcribing(.groqWhisper)
                return try await api.transcribeGroq(fileURL: fileURL)
            }
        case .groqWhisper:
            if privacyMode {
                throw VoiceAPIError.serviceUnavailable("隱私模式禁止雲端轉錄")
            }
            state = .transcribing(.groqWhisper)
            return try await api.transcribeGroq(fileURL: fileURL)
        case .unavailable:
            throw VoiceAPIError.serviceUnavailable("沒有可用的轉錄路由")
        }
    }

    /// Failed sessions keep their WAV in Application Support so a timeout or
    /// runtime crash never silently destroys what the user dictated. Bounded
    /// to the newest 10 recordings.
    private static func preserveFailedRecording(at url: URL) {
        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path),
              let support = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return }
        let recovery = support.appendingPathComponent("NexVoice/recovery", isDirectory: true)
        do {
            try manager.createDirectory(at: recovery, withIntermediateDirectories: true)
            let stamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            let destination = recovery.appendingPathComponent("failed-\(stamp).wav")
            try manager.moveItem(at: url, to: destination)
            DiagnosticLog.log("recording preserved: \(destination.lastPathComponent)")
            let kept = try manager.contentsOfDirectory(at: recovery, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "wav" }
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
            for stale in kept.dropFirst(10) {
                try? manager.removeItem(at: stale)
            }
        } catch {
            DiagnosticLog.log("recording preserve failed: \(error.localizedDescription)")
        }
    }

    private static func isTransientLocalError(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            return [
                .timedOut, .cannotConnectToHost, .networkConnectionLost, .cannotFindHost,
            ].contains(urlError.code)
        }
        if case VoiceAPIError.serviceUnavailable = error { return true }
        return false
    }

    private func ensureCurrent(_ session: UUID) throws {
        guard currentSession == session, !Task.isCancelled else { throw CancellationError() }
    }

    private func ensureOwnershipGeneration(_ generation: Int) throws {
        guard generation == ownershipGeneration else { throw CancellationError() }
    }

    private func cancelCurrentSession() {
        pipelineTask?.cancel()
        pipelineTask = nil
        maxDurationTask?.cancel()
        maxDurationTask = nil
        recorder.cancel()
        liveTranscriptTask?.cancel()
        liveTranscriptTask = nil
        if let currentSession { pasteGate.cancel(session: currentSession) }
        currentSession = nil
        targetApplication = nil
        selectedTextAtArm = nil
        activeVocabulary = []
        liveTranscriptSequence = 0
        hotkeyEngine.reset()
        hud.hide()
    }

    private func applyPendingHotkeyProfileIfPossible() {
        guard state == .disabled || state == .idle || state.isTerminal,
              let pendingHotkeyProfile
        else { return }
        self.pendingHotkeyProfile = nil
        hotkeyEngine.setProfile(pendingHotkeyProfile)
        DiagnosticLog.log(
            "pending hotkey profile applied: \(pendingHotkeyProfile.trigger.rawValue)/\(pendingHotkeyProfile.behavior.rawValue)"
        )
    }

    private func hotkeyPhase(for event: NSEvent) -> HotkeyGesturePhase? {
        if let customCode = hotkeyEngine.profile.keyCode {
            guard event.keyCode == customCode else { return nil }
            switch event.type {
            case .keyDown: return .pressed
            case .keyUp: return .released
            default: return nil
            }
        }
        guard event.type == .flagsChanged else { return nil }

        if hotkeyEngine.triggerIsDown,
           !hotkeyEngine.profile.trigger.accepts(keyCode: event.keyCode),
           CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(event.keyCode)) {
            cancelHotkeyGestureForChordIfNeeded()
            return nil
        }
        guard hotkeyEngine.profile.trigger.accepts(keyCode: event.keyCode) else { return nil }

        // AppKit/CGEvent can report modifier key state before the combined
        // session key-state table updates (especially with event taps and
        // non-US layouts). Use the event's flags as the authoritative edge;
        // keyState remains only a fallback for aggregate left/right Option.
        let normalizedFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let modifierIsPressed = normalizedFlags.contains(
            hotkeyEngine.profile.trigger.modifierFlag
        )
        // For flagsChanged, the event's modifier mask is the authoritative
        // edge.  CGEventSource.keyState can lag behind the release event and
        // turn a Toggle release into a second press (making Option appear
        // completely unresponsive).
        let isPressed = modifierIsPressed
        if isPressed {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let activeVoiceModifiers = flags.intersection([
                .command, .control, .option, .shift, .function,
            ])
            let allowed = hotkeyEngine.profile.trigger.modifierFlag
            guard activeVoiceModifiers.subtracting(allowed).isEmpty else { return nil }
        }
        let phase: HotkeyGesturePhase = isPressed ? .pressed : .released
        DiagnosticLog.log("hotkey phase: keyCode=\(event.keyCode) phase=\(phase)")
        return phase
    }

    private func cancelHotkeyGestureForChordIfNeeded() {
        let action = hotkeyEngine.cancelForChord(isRecording: state == .recording)
        guard action == .cancelRecording else { return }
        DiagnosticLog.log("hotkey gesture cancelled because it became a chord")
        cancelCurrentSession()
        state = .cancelled
    }
}

private extension VoiceRuntimeState {
    var isTerminal: Bool {
        switch self {
        case .complete, .failed, .cancelled: true
        default: false
        }
    }
}

private extension TriggerKey {
    func accepts(keyCode: UInt16) -> Bool {
        switch self {
        case .option: keyCode == 58 || keyCode == 61
        case .leftOption: keyCode == 58
        case .rightOption: keyCode == 61
        case .leftCommand: keyCode == 55
        case .rightCommand: keyCode == 54
        case .leftControl: keyCode == 59
        case .rightControl: keyCode == 62
        case .function: keyCode == 63
        }
    }

    var modifierFlag: NSEvent.ModifierFlags {
        switch self {
        case .option, .leftOption, .rightOption: .option
        case .leftCommand, .rightCommand: .command
        case .leftControl, .rightControl: .control
        case .function: .function
        }
    }
}

enum SystemLoad {
    static var isOverloaded: Bool {
        var values = [Double](repeating: 0, count: 3)
        let count = values.withUnsafeMutableBufferPointer { buffer in
            getloadavg(buffer.baseAddress, 3)
        }
        guard count > 0 else { return false }
        return values[0] / Double(max(1, ProcessInfo.processInfo.processorCount)) >= 1.2
    }
}
