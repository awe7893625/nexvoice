import AVFoundation
import Foundation

@MainActor
final class AudioRecorderService: NSObject {
    private var recorder: AVAudioRecorder?
    private(set) var outputURL: URL?

    func requestPermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    func start(session: UUID) throws {
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NexVoice/Recordings", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        pruneStaleRecordings(in: directory)
        let url = directory.appendingPathComponent("\(session.uuidString).wav")

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false
        ]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        recorder.isMeteringEnabled = true
        guard recorder.prepareToRecord(), recorder.record() else {
            throw VoiceRuntimeError.recordingFailed
        }
        self.recorder = recorder
        self.outputURL = url
    }

    func stop() -> (url: URL, duration: TimeInterval)? {
        guard let recorder, let outputURL else { return nil }
        let duration = recorder.currentTime
        recorder.stop()
        self.recorder = nil
        self.outputURL = nil
        return (outputURL, duration)
    }

    func meterLevel() -> Double {
        guard let recorder else { return 0 }
        recorder.updateMeters()
        // AVAudioRecorder reports dBFS (-160...0).  The previous exponential
        // mapping kept normal speech (-35...-15 dBFS) near the visual floor,
        // so the HUD looked frozen.  Blend peak and average power, remove the
        // room-noise floor, then apply a gamma curve that keeps speech lively.
        let peak = Double(recorder.peakPower(forChannel: 0))
        let average = Double(recorder.averagePower(forChannel: 0))
        let decibels = max(average + 6, peak)
        let linear = max(0, min(1, (decibels + 55) / 50))
        return pow(linear, 0.62)
    }

    func cancel() {
        recorder?.stop()
        recorder = nil
        if let outputURL {
            try? FileManager.default.removeItem(at: outputURL)
        }
        outputURL = nil
    }

    private func pruneStaleRecordings(in directory: URL) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return }
        for file in files where file.pathExtension.lowercased() == "wav" {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
