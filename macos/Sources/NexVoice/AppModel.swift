import AppKit
import ApplicationServices
import AVFoundation
import Combine
import Foundation
import ServiceManagement

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var isEnabled: Bool
    @Published var privacyMode: Bool {
        didSet { defaults.set(privacyMode, forKey: Keys.privacyMode) }
    }
    @Published var cleanupEnabled: Bool {
        didSet { defaults.set(cleanupEnabled, forKey: Keys.cleanupEnabled) }
    }
    @Published var smartFormatEnabled: Bool {
        didSet { defaults.set(smartFormatEnabled, forKey: Keys.smartFormatEnabled) }
    }
    @Published var cloudFallbackEnabled: Bool {
        didSet { defaults.set(cloudFallbackEnabled, forKey: Keys.cloudFallbackEnabled) }
    }
    @Published var localEndpoint: String {
        didSet { defaults.set(localEndpoint, forKey: LocalRuntimeConfiguration.endpointKey) }
    }
    @Published var groqAPIKeyInput = ""
    @Published var geminiAPIKeyInput = ""
    @Published private(set) var providerTestStatus = ""
    @Published private(set) var providerTestInProgress = false
    @Published var productPreferences: ProductPreferences {
        didSet {
            ProductPreferencesStore.save(productPreferences, defaults)
            NV.theme = productPreferences.appTheme
            runtime.updateHUDPreferences(
                style: productPreferences.hudStyle,
                chrome: productPreferences.hudChrome,
                liveCaptionsEnabled: productPreferences.liveCaptionsEnabled,
                subtitleStyle: productPreferences.subtitleStyle
            )
        }
    }
    @Published var zeroCostMode: Bool {
        didSet {
            defaults.set(zeroCostMode, forKey: Keys.zeroCostMode)
            if zeroCostMode {
                cloudFallbackEnabled = false
                cleanupEnabled = false
            }
        }
    }
    @Published var hotkeyProfile: HotkeyProfile {
        didSet {
            do {
                try hotkeyStore.save(hotkeyProfile)
                runtime.updateHotkeyProfile(hotkeyProfile)
            } catch {
                notice = "快捷鍵設定無法儲存，已保留目前設定。"
            }
        }
    }
    @Published var openAtLogin: Bool = false
    @Published private(set) var mlx = ServiceStatus.checking("Local MLX", detail: "127.0.0.1:5112")
    @Published private(set) var gateway = ServiceStatus.checking("資料服務", detail: "127.0.0.1:5111")
    @Published private(set) var typelessRunning = false
    @Published private(set) var currentHotkeyOwner: HotkeyOwner
    @Published private(set) var groqConfigured = false
    @Published private(set) var geminiConfigured = false
    @Published private(set) var microphoneGranted = false
    @Published private(set) var accessibilityGranted = false
    private(set) var lastRefresh = Date.distantPast
    @Published var notice: String?
    @Published private(set) var runtimeState: VoiceRuntimeState = .disabled
    @Published private(set) var lastTranscript = ""
    @Published private(set) var history: [HistoryEntry] = []
    @Published private(set) var vocab: [VocabEntry] = []
    /// Drives first-run / permission setup window.
    @Published var showOnboarding = false

    let routingPolicy = RoutingPolicy()

    private enum Keys {
        static let enabled = "nexvoice.native.enabled"
        static let privacyMode = "nexvoice.native.privacyMode"
        static let cleanupEnabled = "nexvoice.native.cleanupEnabled"
        static let smartFormatEnabled = "nexvoice.native.smartFormatEnabled"
        static let cloudFallbackEnabled = "nexvoice.native.cloudFallbackEnabled"
        static let zeroCostMode = "nexvoice.native.zeroCostMode"
        static let openAtLogin = "nexvoice.native.openAtLogin"
        static let onboardingCompleted = "nexvoice.native.onboardingCompleted"
    }

    private let defaults: UserDefaults
    private let runtime: VoiceRuntimeController
    private let hotkeyStore: HotkeyProfileStore
    private var monitorTask: Task<Void, Never>?
    private var typelessWatchTask: Task<Void, Never>?
    private let localRuntimeSupervisor = LocalRuntimeSupervisor()
    private var restoredRuntime = false
    private var runtimeOperationID = 0
    /// Set when enable() failed transiently (busy Hammerspoon IPC, monitor
    /// hiccup) while the persisted user intent stays "enabled" -- the monitor
    /// loop retries the takeover instead of leaving the hotkey dead.
    private var enableRetryPending = false
    private var enableRetryTick = 0

    init(defaults: UserDefaults = .standard) {
        SecretStore.migrateLegacySecretsToKeychain()
        // Do NOT touch the legacy Hammerspoon trigger here. This used to run
        // unconditionally on every launch, killing the working Option hotkey
        // the instant the app opened — even if native never went on to
        // successfully enable (blocked behind mic/AX dialogs). Ownership
        // handoff belongs solely to VoiceRuntimeController.enable()/disable(),
        // which only run when native actually takes over.
        self.defaults = defaults
        let hotkeyStore = HotkeyProfileStore(defaults: defaults)
        self.hotkeyStore = hotkeyStore
        self.hotkeyProfile = hotkeyStore.load()
        self.currentHotkeyOwner = LegacyBridge.loadOwner() ?? .legacy
        self.isEnabled = defaults.bool(forKey: Keys.enabled)
        self.privacyMode = defaults.bool(forKey: Keys.privacyMode)
        // Zero-cost is the product default. Existing installs migrate to this
        // safe state once; merely having an API key never authorizes requests.
        if defaults.object(forKey: Keys.zeroCostMode) == nil {
            self.zeroCostMode = true
            self.cleanupEnabled = false
            self.smartFormatEnabled = false
            self.cloudFallbackEnabled = false
        } else {
            let zeroCostMode = defaults.bool(forKey: Keys.zeroCostMode)
            self.zeroCostMode = zeroCostMode
            self.cleanupEnabled = zeroCostMode ? false : defaults.bool(forKey: Keys.cleanupEnabled)
            self.smartFormatEnabled = zeroCostMode ? false : defaults.bool(forKey: Keys.smartFormatEnabled)
            self.cloudFallbackEnabled = zeroCostMode
                ? false
                : defaults.bool(forKey: Keys.cloudFallbackEnabled)
        }
        self.openAtLogin = defaults.bool(forKey: Keys.openAtLogin)
        self.localEndpoint = defaults.string(forKey: LocalRuntimeConfiguration.endpointKey)
            ?? LocalRuntimeConfiguration.defaultEndpoint
        let loadedPreferences = ProductPreferencesStore.load(defaults)
        self.productPreferences = loadedPreferences
        NV.theme = loadedPreferences.appTheme
        self.runtime = VoiceRuntimeController()
        runtime.updateHotkeyProfile(hotkeyProfile)
        runtime.updateHUDPreferences(
            style: productPreferences.hudStyle,
            chrome: productPreferences.hudChrome,
            liveCaptionsEnabled: productPreferences.liveCaptionsEnabled,
            subtitleStyle: productPreferences.subtitleStyle
        )
        runtime.onStateChange = { [weak self] state in self?.runtimeState = state }
        runtime.onTranscript = { [weak self] text in
            self?.lastTranscript = text
            self?.reloadHistory()
        }
        runtime.preferencesProvider = { [weak self] in
            guard let self else {
                return RuntimePreferences(
                    privacyMode: false,
                    cleanupEnabled: true,
                    smartFormatEnabled: false,
                    localEnabled: true,
                    localHealthy: false,
                    overloaded: SystemLoad.isOverloaded,
                    groqConfigured: false,
                    cloudSTTAllowed: false,
                    cloudTextAllowed: false,
                    cloudTextConfigured: false
                )
            }
            return self.runtimePreferences
        }
        runtime.vocabularyProvider = { [weak self] in
            self?.vocab ?? VocabStore.loadCached()
        }
        history = LocalHistoryStore.load()
        if let previous = history.first?.text, !previous.isEmpty {
            lastTranscript = previous
            runtime.restoreLastSuccessfulText(previous)
        }
        microphoneGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        accessibilityGranted = AXIsProcessTrusted()
        vocab = VocabStore.loadCached()
        reloadVocab()
    }

    func saveProviderKeys() {
        if !groqAPIKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            _ = SecretStore.writeSecretFile(".groq_key", value: groqAPIKeyInput)
            groqAPIKeyInput = ""
        }
        if !geminiAPIKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            _ = SecretStore.writeSecretFile(".gemini_key", value: geminiAPIKeyInput)
            geminiAPIKeyInput = ""
        }
        groqConfigured = SecretStore.isSecureSecret(named: ".groq_key")
        geminiConfigured = SecretStore.isSecureSecret(named: ".gemini_key")
        notice = "本機設定已儲存；API key 只保存在此 Mac 的 0600 檔案。"
    }

    func saveTestAndEnableProviders() {
        saveProviderKeys()
        // Clicking this specifically authorizes cloud use. Merely storing a
        // key elsewhere still never changes the zero-cost/privacy defaults.
        privacyMode = false
        zeroCostMode = false
        if groqConfigured { cloudFallbackEnabled = true }
        cleanupEnabled = groqConfigured || geminiConfigured
        providerTestInProgress = true
        providerTestStatus = "正在檢查本地模型與 API…"
        Task { @MainActor in
            var results: [String] = []
            let localOK = await ProviderConnectionTester.localRuntime()
            results.append("MLX \(localOK ? "✓" : "✕")")
            if groqConfigured {
                results.append("Groq \(await ProviderConnectionTester.groq() ? "✓" : "✕")")
            }
            if geminiConfigured {
                results.append("Gemini \(await ProviderConnectionTester.gemini() ? "✓" : "✕")")
            }
            providerTestStatus = results.joined(separator: " · ")
            providerTestInProgress = false
            notice = results.contains(where: { $0.hasSuffix("✕") })
                ? "部分連線失敗；請檢查 key、網路或本地 runtime。"
                : "連線完成，NexVoice 已可使用。"
        }
    }

    func reloadHistory() {
        history = LocalHistoryStore.load()
        if lastTranscript.isEmpty, let previous = history.first?.text {
            lastTranscript = previous
            runtime.restoreLastSuccessfulText(previous)
        }
    }

    func updateHistory(id: String, text: String) {
        if LocalHistoryStore.update(id: id, text: text) {
            reloadHistory()
            notice = "歷史內容已更新。"
        } else {
            notice = "無法更新這筆內容。"
        }
    }

    func deleteHistory(id: String) {
        if LocalHistoryStore.delete(id: id) {
            reloadHistory()
            notice = "歷史內容已刪除。"
        } else {
            notice = "無法刪除這筆內容。"
        }
    }

    func reloadVocab() {
        Task { @MainActor in
            vocab = await VocabStore.load()
        }
    }

    func addVocab(phrase: String, soundsLike: String) {
        Task { @MainActor in
            if await VocabStore.add(phrase: phrase, soundsLike: soundsLike) {
                vocab = await VocabStore.load()
                notice = "詞彙已加入；下一次錄音會套用到 MLX 辨識與文字修正。"
            } else {
                notice = "詞彙新增失敗；請確認資料服務已啟動，且內容未超過 128 bytes。"
            }
        }
    }

    func deleteVocab(id: Int) {
        Task { @MainActor in
            if await VocabStore.delete(id: id) {
                vocab = await VocabStore.load()
                notice = "詞彙已刪除。"
            } else {
                notice = "詞彙刪除失敗；請重新整理後再試。"
            }
        }
    }

    deinit {
        monitorTask?.cancel()
        typelessWatchTask?.cancel()
    }

    var runtimePreferences: RuntimePreferences {
        RuntimePreferences(
            privacyMode: privacyMode,
            cleanupEnabled: cleanupEnabled && !zeroCostMode,
            smartFormatEnabled: smartFormatEnabled && !zeroCostMode,
            localEnabled: true,
            localHealthy: mlx.isHealthy,
            overloaded: SystemLoad.isOverloaded,
            groqConfigured: groqConfigured,
            cloudSTTAllowed: cloudFallbackEnabled && !zeroCostMode,
            cloudTextAllowed: cleanupEnabled && !zeroCostMode,
            cloudTextConfigured: groqConfigured || geminiConfigured
        )
    }

    var permissionsReady: Bool {
        microphoneGranted && accessibilityGranted
    }

    /// First incomplete step for the onboarding wizard.
    var suggestedOnboardingStep: Int {
        if !microphoneGranted { return 1 }
        if !accessibilityGranted { return 2 }
        return 3
    }

    var onboardingCompleted: Bool {
        defaults.bool(forKey: Keys.onboardingCompleted)
    }

    func startMonitoring() {
        guard monitorTask == nil else { return }
        typelessWatchTask = Task { [weak self] in
            let notifications = NSWorkspace.shared.notificationCenter.notifications(
                named: NSWorkspace.didLaunchApplicationNotification
            )
            let launchedBundleIdentifiers = notifications.compactMap { notification -> String? in
                let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication
                return application?.bundleIdentifier
            }
            for await bundleIdentifier in launchedBundleIdentifiers {
                guard let self, bundleIdentifier == "now.typeless.desktop" else { continue }
                self.typelessRunning = true
                if self.isEnabled {
                    let relinquished = await self.relinquishToTypeless(reason: "external-launch")
                    if relinquished {
                        self.notice = "偵測到 Typeless 已啟動，NexVoice 已自動停用。"
                    }
                }
            }
        }
        monitorTask = Task { [weak self] in
            guard let self else { return }
            await self.localRuntimeSupervisor.startIfNeeded()
            await self.refresh()
            await self.reconcileHotkeyOwnerAtStartup()
            // First launch or missing permissions → open guided setup.
            if !self.onboardingCompleted || !self.permissionsReady {
                self.showOnboarding = true
            }
            if self.isEnabled, !self.restoredRuntime {
                self.restoredRuntime = true
                if self.typelessRunning {
                    let relinquished = await self.relinquishToTypeless(reason: "startup-reconcile")
                    if relinquished {
                        self.notice = "偵測到 Typeless 正在執行，NexVoice 保持停用。"
                    }
                } else if self.permissionsReady {
                    await self.setRuntimeEnabled(true)
                } else {
                    self.notice = "請先完成設定引導中的麥克風與輔助使用權限。"
                    self.showOnboarding = true
                }
            }
            while !Task.isCancelled {
                // Keep the bundled MLX helper alive.  A transient Python/MLX
                // exit must not leave the hotkey path apparently dead until
                // the user relaunches the app.
                if self.isEnabled && !self.typelessRunning {
                    await self.localRuntimeSupervisor.startIfNeeded()
                }
                if self.enableRetryPending, !self.isEnabled, !self.typelessRunning,
                   self.defaults.bool(forKey: Keys.enabled), self.permissionsReady {
                    // Every 3rd tick (~15s) so a wedged Hammerspoon isn't hammered.
                    self.enableRetryTick += 1
                    if self.enableRetryTick % 3 == 1 {
                        DiagnosticLog.log("auto-retrying hotkey takeover after transient enable failure")
                        await self.setRuntimeEnabled(true)
                    }
                } else {
                    self.enableRetryTick = 0
                }
                await self.refresh()
                if self.typelessRunning, self.isEnabled {
                    let relinquished = await self.relinquishToTypeless(reason: "health-reconcile")
                    if relinquished {
                        self.notice = "偵測到 Typeless 已啟動，NexVoice 已自動停用。"
                    }
                }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func refresh() async {
        async let gatewayResult = ServiceProbe.check(
            name: "資料服務",
            detail: "127.0.0.1:5111",
            url: URL(string: "http://127.0.0.1:5111/health")!
        )

        let nextMLX = await localRuntimeSupervisor.serviceStatus()
        let nextGateway = await gatewayResult
        if mlx.state != nextMLX.state { mlx = nextMLX }
        if gateway.state != nextGateway.state { gateway = nextGateway }
        let nextTypelessRunning = Self.typelessApplication() != nil
        if typelessRunning != nextTypelessRunning { typelessRunning = nextTypelessRunning }
        let nextGroqConfigured = SecretStore.isSecureSecret(named: ".groq_key")
        let nextGeminiConfigured = SecretStore.isSecureSecret(named: ".gemini_key")
        if groqConfigured != nextGroqConfigured { groqConfigured = nextGroqConfigured }
        if geminiConfigured != nextGeminiConfigured { geminiConfigured = nextGeminiConfigured }
        await refreshPermissions()
        lastRefresh = Date()
    }

    private func reconcileHotkeyOwnerAtStartup() async {
        if typelessRunning {
            let result = await LegacyBridge.transition(to: .typeless)
            currentHotkeyOwner = result.succeeded ? .typeless : .unknown
            return
        }
        let willAttemptNative = isEnabled && permissionsReady
        if !willAttemptNative, currentHotkeyOwner != .legacy {
            let result = await LegacyBridge.transition(to: .legacy)
            currentHotkeyOwner = result.succeeded ? .legacy : .unknown
            DiagnosticLog.log("startup owner reconcile: \(result.diagnosticLabel)")
        }
        if isEnabled, !permissionsReady {
            isEnabled = false
            defaults.set(false, forKey: Keys.enabled)
            notice = "權限尚未完成，已先恢復原語音工具。"
        }
    }

    func refreshPermissions() async {
        let nextMicrophoneGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        if microphoneGranted != nextMicrophoneGranted { microphoneGranted = nextMicrophoneGranted }
        // Re-query with options so post-toggle grants are picked up without restart
        // (still may need relaunch for ad-hoc identity changes).
        let opts = ["AXTrustedCheckOptionPrompt": false] as CFDictionary
        let nextAccessibilityGranted = AXIsProcessTrustedWithOptions(opts) || AXIsProcessTrusted()
        if accessibilityGranted != nextAccessibilityGranted { accessibilityGranted = nextAccessibilityGranted }
    }

    @discardableResult
    func requestMicrophoneAccess() async -> Bool {
        let granted = await SystemSettings.requestMicrophone()
        await refreshPermissions()
        if granted {
            notice = "麥克風已授權。"
        } else {
            notice = "請在系統設定 → 隱私權 → 麥克風 勾選 NexVoice。"
        }
        return granted
    }

    @discardableResult
    func requestAccessibilityAccess() -> Bool {
        let granted = SystemSettings.requestAccessibility()
        accessibilityGranted = AXIsProcessTrusted()
        if granted {
            notice = "輔助使用已授權。"
        } else {
            notice = "請在系統設定 → 隱私權 → 輔助使用 勾選 NexVoice。"
        }
        return granted
    }

    func dismissOnboarding(completed: Bool) {
        if completed, permissionsReady {
            defaults.set(true, forKey: Keys.onboardingCompleted)
        }
        showOnboarding = false
    }

    func reopenOnboarding() {
        showOnboarding = true
    }

    var currentRoute: STTRoute {
        routingPolicy.choose(runtimePreferences.snapshot)
    }

    func switchToNexVoice() {
        DiagnosticLog.log("switchToNexVoice(): tapped, mic=\(microphoneGranted) ax=\(accessibilityGranted) enabled=\(isEnabled)")
        // Refresh first so we don't block on stale flags.
        Task { @MainActor in
            await refreshPermissions()
            await self.performSwitchToNexVoice()
        }
    }

    @MainActor
    private func performSwitchToNexVoice() async {
        var terminatedTypelessForSwitch = false
        if !microphoneGranted {
            let alert = NSAlert()
            alert.messageText = "需要麥克風權限"
            alert.informativeText = "請允許 NexVoice 使用麥克風後再啟用。"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "開啟麥克風設定")
            alert.addButton(withTitle: "取消")
            if alert.runModal() == .alertFirstButtonReturn {
                _ = await requestMicrophoneAccess()
            }
            return
        }

        if !accessibilityGranted {
            let alert = NSAlert()
            alert.messageText = "需要重新綁定輔助使用權限"
            alert.informativeText = """
            如果系統設定顯示已開啟，但 NexVoice 仍顯示未授權，請將 NexVoice 開關關閉後再開啟一次。

            請選：
            1. 打開輔助使用設定
            2. 取消，稍後再處理
            """
            alert.alertStyle = .warning
            alert.addButton(withTitle: "打開輔助使用設定")
            alert.addButton(withTitle: "取消")
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                DiagnosticLog.log("performSwitchToNexVoice(): AX not granted, user opened Settings")
                requestAccessibilityAccess()
            }
            return
        }

        if let typeless = Self.typelessApplication() {
            let alert = NSAlert()
            alert.messageText = "切換到 NexVoice？"
            alert.informativeText = "Typeless 正在執行。同時開兩個會搶 Option 快捷鍵。建議先結束 Typeless。"
            alert.alertStyle = .informational
            alert.addButton(withTitle: "結束 Typeless 並切換")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }

            _ = typeless.terminate()
            guard await Self.waitUntilTerminated(typeless, timeout: 3) else {
                notice = "Typeless 尚未結束，NexVoice 保持停用。"
                return
            }
            typelessRunning = false
            terminatedTypelessForSwitch = true
        }

        await setRuntimeEnabled(true)
        if isEnabled {
            notice = "NexVoice 已啟用。\(hotkeyProfile.userInstruction)"
        } else if terminatedTypelessForSwitch {
            await performSwitchToTypeless()
            if typelessRunning {
                notice = "NexVoice 無法安全接管，已恢復 Typeless。"
            }
        }
    }

    func switchToTypeless() {
        Task { await performSwitchToTypeless() }
    }

    func disableNexVoice() {
        Task { await setRuntimeEnabled(false) }
    }

    func prepareForTermination() async -> Bool {
        runtimeOperationID &+= 1
        let destination: HotkeyOwner = Self.typelessApplication() == nil ? .legacy : .typeless
        let result = await runtime.disable(destination: destination)
        DiagnosticLog.log(
            "prepareForTermination(): destination=\(destination.rawValue), bridge=\(result.diagnosticLabel)"
        )
        if !result.succeeded {
            currentHotkeyOwner = .unknown
            notice = "無法安全交還快捷鍵，NexVoice 暫不退出。請確認 Hammerspoon 後重試。"
        }
        guard result.succeeded else { return false }
        let runtimeStopped = await localRuntimeSupervisor.stop()
        if !runtimeStopped {
            notice = "本機 MLX runtime 未安全停止，NexVoice 暫不退出。"
        }
        return runtimeStopped
    }

    func repasteLast() {
        Task { await runtime.repasteLast() }
    }

    func dispatchLastDraft() {
        runtime.dispatchLastDraft()
    }

    func setOpenAtLogin(_ enabled: Bool) {
        openAtLogin = enabled
        applyOpenAtLogin(enabled)
    }

    func previewRecorderHUD(thinking: Bool = false, duration: TimeInterval = 3) {
        runtime.previewCompactHUD(thinking: thinking, duration: duration)
    }

    private func setRuntimeEnabled(_ enabled: Bool) async {
        runtimeOperationID &+= 1
        let operationID = runtimeOperationID
        if enabled {
            guard Self.typelessApplication() == nil else {
                isEnabled = false
                defaults.set(false, forKey: Keys.enabled)
                notice = "Typeless 正在執行，NexVoice 保持停用。"
                return
            }
            do {
                try await runtime.enable()
                guard operationID == runtimeOperationID,
                      Self.typelessApplication() == nil
                else {
                    let destination: HotkeyOwner = Self.typelessApplication() == nil ? .legacy : .typeless
                    let result = await runtime.disable(destination: destination)
                    if result.succeeded { currentHotkeyOwner = destination }
                    isEnabled = false
                    defaults.set(false, forKey: Keys.enabled)
                    notice = "啟用條件已改變，NexVoice 保持停用。"
                    return
                }
                isEnabled = true
                enableRetryPending = false
                currentHotkeyOwner = .native
                defaults.set(true, forKey: Keys.enabled)
                // Global Option monitor silently receives nothing without Accessibility —
                // say so instead of claiming the hotkey works when it can't.
                if accessibilityGranted {
                    notice = "NexVoice 已接管快捷鍵；\(hotkeyProfile.userInstruction) ⌥⌘V 重貼 · ⌥⌘D 派工草稿。"
                } else {
                    notice = "熱鍵未就緒：尚未取得輔助使用權限。請在系統設定將 NexVoice 關閉後再開啟一次。"
                }
                DiagnosticLog.log("setRuntimeEnabled(true): OK, defaults.enabled=1, ax=\(accessibilityGranted)")
            } catch {
                guard operationID == runtimeOperationID else {
                    DiagnosticLog.log("setRuntimeEnabled(true): stale operation ignored")
                    return
                }
                isEnabled = false
                currentHotkeyOwner = LegacyBridge.loadOwner() ?? currentHotkeyOwner
                // A busy Hammerspoon IPC channel or a monitor hiccup is
                // transient: keep the persisted user intent and let the
                // monitor loop retry, instead of permanently disabling the
                // hotkey until a manual re-enable. Permission failures stay
                // persisted-off: retrying can't fix those.
                let transient: Bool = switch error {
                case VoiceRuntimeError.legacyTriggerStillActive,
                     VoiceRuntimeError.monitorInstallationFailed: true
                default: false
                }
                if transient {
                    enableRetryPending = true
                    defaults.set(true, forKey: Keys.enabled)
                    notice = "\(error.localizedDescription)；稍後會自動重試接管。"
                } else {
                    defaults.set(false, forKey: Keys.enabled)
                    notice = error.localizedDescription
                }
                DiagnosticLog.log("setRuntimeEnabled(true): FAILED — \(error.localizedDescription)\(transient ? " (will auto-retry)" : "")")
            }
        } else {
            enableRetryPending = false
            let result = await runtime.disable(destination: .legacy)
            guard operationID == runtimeOperationID else {
                DiagnosticLog.log("setRuntimeEnabled(false): stale operation ignored")
                return
            }
            isEnabled = false
            defaults.set(false, forKey: Keys.enabled)
            if result.succeeded {
                currentHotkeyOwner = .legacy
                notice = "NexVoice 已停用，已恢復原語音工具。"
            } else {
                currentHotkeyOwner = .unknown
                notice = "NexVoice 已停止監聽，但無法確認原語音工具已恢復。請開啟診斷。"
            }
            DiagnosticLog.log("setRuntimeEnabled(false): bridge=\(result.diagnosticLabel)")
        }
    }

    @discardableResult
    private func relinquishToTypeless(reason: String) async -> Bool {
        runtimeOperationID &+= 1
        let operationID = runtimeOperationID
        let result = await runtime.disable(destination: .typeless)
        guard operationID == runtimeOperationID else {
            DiagnosticLog.log("relinquishToTypeless(\(reason)): stale operation ignored")
            return false
        }
        isEnabled = false
        defaults.set(false, forKey: Keys.enabled)
        DiagnosticLog.log("relinquishToTypeless(\(reason)): bridge=\(result.diagnosticLabel)")
        if !result.succeeded {
            currentHotkeyOwner = .unknown
            notice = "NexVoice 已停止監聽，但無法確認快捷鍵操控權，請開啟診斷。"
        } else {
            currentHotkeyOwner = .typeless
        }
        return result.succeeded
    }

    private func performSwitchToTypeless() async {
        let wasNativeEnabled = isEnabled
        guard await relinquishToTypeless(reason: "user-switch") else {
            if wasNativeEnabled {
                do {
                    try await runtime.enable()
                    isEnabled = true
                    currentHotkeyOwner = .native
                    defaults.set(true, forKey: Keys.enabled)
                } catch {
                    let restored = await LegacyBridge.transition(to: .legacy)
                    currentHotkeyOwner = restored.succeeded ? .legacy : .unknown
                }
            }
            notice = "無法安全切換操控權，Typeless 未啟動。"
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        do {
            guard let typelessURL = Self.typelessApplication()?.bundleURL
                ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "now.typeless.desktop")
            else {
                throw CocoaError(.fileNoSuchFile)
            }
            _ = try await Self.openApplication(
                at: typelessURL,
                configuration: configuration
            )
            typelessRunning = true
            currentHotkeyOwner = .typeless
            notice = "NexVoice 已停用，已切到 Typeless。"
        } catch {
            typelessRunning = false
            if wasNativeEnabled {
                do {
                    try await runtime.enable()
                    isEnabled = true
                    currentHotkeyOwner = .native
                    defaults.set(true, forKey: Keys.enabled)
                    notice = "無法開啟 Typeless，已恢復 NexVoice。"
                } catch {
                    isEnabled = false
                    defaults.set(false, forKey: Keys.enabled)
                    let restored = await LegacyBridge.transition(to: .legacy)
                    currentHotkeyOwner = restored.succeeded ? .legacy : .unknown
                    notice = restored.succeeded
                        ? "無法開啟 Typeless，也無法恢復 NexVoice；已恢復原語音工具。"
                        : "無法開啟 Typeless，也無法確認任何快捷鍵操控權。"
                }
            } else {
                let restored = await LegacyBridge.transition(to: .legacy)
                currentHotkeyOwner = restored.succeeded ? .legacy : .unknown
                notice = restored.succeeded
                    ? "無法開啟 Typeless，已恢復原語音工具。"
                    : "無法開啟 Typeless，也無法確認原語音工具已恢復。"
            }
        }
    }

    private func applyOpenAtLogin(_ enabled: Bool) {
        defaults.set(enabled, forKey: Keys.openAtLogin)
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            notice = "開機啟動設定失敗：\(error.localizedDescription)"
        }
    }

    private static func typelessApplication() -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == "now.typeless.desktop"
        }
    }

    private static func waitUntilTerminated(
        _ application: NSRunningApplication,
        timeout: TimeInterval
    ) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(timeout)
        while !application.isTerminated, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(80))
        }
        return application.isTerminated
    }

    private static func openApplication(
        at url: URL,
        configuration: NSWorkspace.OpenConfiguration
    ) async throws -> NSRunningApplication {
        try await withCheckedThrowingContinuation { continuation in
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let app {
                    continuation.resume(returning: app)
                } else {
                    continuation.resume(throwing: CocoaError(.fileNoSuchFile))
                }
            }
        }
    }
}

extension HotkeyProfile {
    var bindingName: String {
        if let keyCode {
            switch keyCode {
            case 49: return "Space"
            case 36: return "Return"
            case 48: return "Tab"
            case 53: return "Escape"
            default: return "自訂按鍵"
            }
        }
        return trigger.displayName
    }

    var userInstruction: String {
        switch behavior {
        case .toggle: "按一下 \(bindingName) 開始，再按一下停止。"
        case .pushToTalk: "按住 \(bindingName) 錄音，放開後停止。"
        }
    }
}

extension TriggerKey {
    var displayName: String {
        switch self {
        case .option: "任一 Option"
        case .leftOption: "左 Option"
        case .rightOption: "右 Option"
        case .leftCommand: "左 Command"
        case .rightCommand: "右 Command"
        case .leftControl: "左 Control"
        case .rightControl: "右 Control"
        case .function: "Fn"
        }
    }
}

extension TriggerBehavior {
    var displayName: String {
        switch self {
        case .toggle: "按一下切換"
        case .pushToTalk: "按住說話"
        }
    }
}
