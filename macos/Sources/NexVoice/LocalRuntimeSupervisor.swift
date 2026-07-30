import Foundation

/// Owns the bundled local helper lifecycle. A listener on port 5112 is never
/// trusted merely because it returns HTTP 200: the signed bundle manifest,
/// runtime build identity, and per-App owner nonce must all match.
///
/// `startIfNeeded()` awaits across several suspension points (probe, spawn,
/// poll loop). A `generation` token is bumped on every `stop()` (and captured
/// at the top of every `startIfNeeded()`); every await boundary re-checks its
/// captured generation against the current one before touching shared state,
/// so a `stop()` that races an in-flight start reliably wins and the start
/// tears down whatever it just spawned instead of adopting/reporting on it.
@MainActor
final class LocalRuntimeSupervisor {
    private enum State {
        case idle
        case starting
        case running
        case stopping
    }

    private var process: Process?
    private var ownerNonce: String?
    private var state: State = .idle
    private var generation = 0
    private(set) var lastError: String?

    func startIfNeeded() async {
        guard state == .idle || (state == .running && process?.isRunning != true) else { return }
        state = .starting
        generation += 1
        let myGeneration = generation
        defer {
            if generation == myGeneration, state == .starting { state = .idle }
        }

        guard let script = Bundle.main.url(
            forResource: "nexvoice_local_runtime",
            withExtension: "py",
            subdirectory: "NexVoiceRuntime"
        ), let manifest = LocalRuntimeContract.bundledManifest else {
            lastError = "App bundle 缺少已驗證的 NexVoiceRuntime"
            return
        }
        let python = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/nexvoice/runtime/.venv/bin/python3").path
        guard FileManager.default.isExecutableFile(atPath: python) else {
            lastError = "尚未安裝 MLX runtime，請執行下載包內的 Install NexVoice.command"
            return
        }
        guard let installedModelPath = LocalRuntimeConfiguration.installedModelPath,
              let installedPartialModelPath = LocalRuntimeConfiguration.installedPartialModelPath
        else {
            lastError = "找不到已鎖定版本的本機模型，請重新執行 Install NexVoice.command"
            return
        }

        switch await LocalRuntimeContract.probe(expected: manifest, timeout: 0.6) {
        case .unavailable:
            break
        case .occupied(let reason):
            lastError = reason
            return
        case .recognized(let identity, _):
            // A compatible or older v2 runtime may be an orphan from the
            // previous signed App. It shuts itself down only after the exact
            // authenticated identity tuple is echoed back; no PID is killed.
            guard await LocalRuntimeContract.requestShutdown(identity),
                  await waitUntilPortIsFree(manifest: manifest)
            else {
                lastError = "既有 NexVoice runtime 無法安全交接"
                return
            }
        }
        guard generation == myGeneration else { return }

        let nonce = UUID().uuidString.lowercased()
        let child = Process()
        child.executableURL = URL(fileURLWithPath: python)
        child.arguments = [script.path]
        child.environment = ProcessInfo.processInfo.environment.merging([
            "NEXVOICE_LOCAL_PORT": "5112",
            "NEXVOICE_MLX_MODEL": installedModelPath,
            "NEXVOICE_MLX_PARTIAL_MODEL": installedPartialModelPath,
            "NEXVOICE_RUNTIME_EXPECTED_BUILD": manifest.runtimeBuild,
            "NEXVOICE_RUNTIME_OWNER_NONCE": nonce,
            "NEXVOICE_RUNTIME_PARENT_PID": String(ProcessInfo.processInfo.processIdentifier),
            "PYTHONUNBUFFERED": "1",
        ]) { _, new in new }
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        child.terminationHandler = { [weak self] terminated in
            Task { @MainActor in
                guard let self, self.process === terminated else { return }
                self.process = nil
                if self.state != .stopping {
                    self.lastError = "本機 MLX runtime 已停止（exit \(terminated.terminationStatus)）"
                }
            }
        }

        do {
            try child.run()
        } catch {
            lastError = "無法啟動本機 MLX runtime：\(error.localizedDescription)"
            return
        }

        guard generation == myGeneration else {
            // A stop() (or a newer start) raced us while the process was
            // launching -- tear down the orphan instead of adopting it.
            await terminateOrphan(child)
            return
        }
        process = child
        ownerNonce = nonce

        for _ in 0..<60 {
            guard generation == myGeneration else {
                await terminateOrphan(child)
                if process === child { process = nil; ownerNonce = nil }
                return
            }
            if !child.isRunning { break }
            switch await LocalRuntimeContract.probe(expected: manifest, timeout: 0.4) {
            case .recognized(let identity, let matchesExpectedBuild)
                where matchesExpectedBuild && identity.ownerNonce == nonce:
                lastError = nil
                state = .running
                return
            case .occupied(let reason):
                lastError = reason
            case .recognized:
                lastError = "runtime 身分與本次 App 不一致"
            case .unavailable:
                break
            }
            try? await Task.sleep(for: .milliseconds(100))
        }

        guard generation == myGeneration else {
            await terminateOrphan(child)
            if process === child { process = nil; ownerNonce = nil }
            return
        }
        if child.isRunning { child.terminate() }
        _ = await waitForExit(child, attempts: 30)
        if process === child { process = nil }
        ownerNonce = nil
        if lastError == nil { lastError = "本機 MLX runtime 啟動逾時" }
    }

    private func terminateOrphan(_ child: Process) async {
        if child.isRunning { child.terminate() }
        _ = await waitForExit(child, attempts: 30)
    }

    func serviceStatus() async -> ServiceStatus {
        let name = "Local MLX"
        let detail = "127.0.0.1:5112"
        let start = ContinuousClock.now
        let probe = await LocalRuntimeContract.probe(timeout: 1.5)
        let latency = milliseconds(from: start.duration(to: .now))
        switch probe {
        case .recognized(let identity, let matchesExpectedBuild)
            where matchesExpectedBuild && identity.ownerNonce == ownerNonce:
            return ServiceStatus(
                id: name,
                name: name,
                detail: "\(detail) · mlx-whisper \(identity.mlxWhisperVersion ?? "unknown")",
                state: .healthy,
                latencyMilliseconds: latency
            )
        case .recognized(_, let matchesExpectedBuild):
            return ServiceStatus(
                id: name,
                name: name,
                detail: detail,
                state: .unavailable(
                    matchesExpectedBuild
                        ? "runtime 不屬於目前 App 執行個體"
                        : "runtime build 與目前 App 不一致"
                ),
                latencyMilliseconds: latency
            )
        case .occupied(let reason), .unavailable(let reason):
            return ServiceStatus(
                id: name,
                name: name,
                detail: detail,
                state: .unavailable(lastError ?? reason),
                latencyMilliseconds: nil
            )
        }
    }

    func stop() async -> Bool {
        // Invalidate any in-flight startIfNeeded() before touching shared
        // state -- it will see this new generation at its next await
        // boundary and tear down whatever it just spawned on its own.
        generation += 1
        state = .stopping
        defer { if state == .stopping { state = .idle } }

        let nonce = ownerNonce
        if let process, process.isRunning {
            process.terminate()
            guard await waitForExit(process, attempts: 40) else {
                lastError = "本機 MLX runtime 未在期限內停止"
                return false
            }
        }
        process = nil

        if let manifest = LocalRuntimeContract.bundledManifest,
           case .recognized(let identity, _) = await LocalRuntimeContract.probe(
               expected: manifest,
               timeout: 0.5
           ), identity.ownerNonce == nonce {
            guard await LocalRuntimeContract.requestShutdown(identity),
                  await waitUntilPortIsFree(manifest: manifest)
            else {
                lastError = "本機 MLX runtime 未釋放 5112"
                return false
            }
        }
        ownerNonce = nil
        lastError = nil
        return true
    }

    private func waitUntilPortIsFree(manifest: LocalRuntimeManifest) async -> Bool {
        for _ in 0..<30 {
            if case .unavailable = await LocalRuntimeContract.probe(
                expected: manifest,
                timeout: 0.25
            ) { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    private func waitForExit(_ process: Process, attempts: Int) async -> Bool {
        for _ in 0..<attempts {
            if !process.isRunning { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return !process.isRunning
    }

    private func milliseconds(from duration: Duration) -> Int {
        Int(duration.components.seconds * 1_000)
            + Int(duration.components.attoseconds / 1_000_000_000_000_000)
    }
}
