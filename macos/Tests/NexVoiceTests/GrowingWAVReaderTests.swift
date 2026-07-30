import XCTest
@testable import NexVoice

final class GrowingWAVReaderTests: XCTestCase {
    private func uint32LE(_ value: UInt32) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)]
    }

    private func canonicalFmtChunk() -> [UInt8] {
        // 16kHz mono 16-bit linear PCM, matching AudioRecorderService's settings.
        var fmt: [UInt8] = []
        fmt += [1, 0]              // audio format = PCM
        fmt += [1, 0]              // channels = 1
        fmt += uint32LE(16_000)    // sample rate
        fmt += uint32LE(32_000)    // byte rate = sampleRate * channels * bitsPerSample/8
        fmt += [2, 0]              // block align
        fmt += [16, 0]             // bits per sample
        return fmt
    }

    /// Reproduces the exact real-world layout captured from a live installed
    /// NexVoice recording: RIFF/WAVE, a JUNK alignment chunk, fmt, then a
    /// filler chunk (FLLR) whose declared size does NOT track how much audio
    /// has actually been appended after it.
    private func avAudioRecorderStyleBytes(audioByteCount: Int, declaredFillerSize: Int) -> Data {
        var bytes: [UInt8] = []
        bytes += Array("RIFF".utf8)
        bytes += uint32LE(4088) // stale declared RIFF size, as observed live
        bytes += Array("WAVE".utf8)

        bytes += Array("JUNK".utf8)
        bytes += uint32LE(28)
        bytes += Array(repeating: UInt8(0), count: 28)

        let fmt = canonicalFmtChunk()
        bytes += Array("fmt ".utf8)
        bytes += uint32LE(UInt32(fmt.count))
        bytes += fmt

        bytes += Array("FLLR".utf8)
        bytes += uint32LE(UInt32(declaredFillerSize))
        // Actual audio bytes written so far may be more (or less) than the
        // filler's own declared size -- that declared size is exactly the
        // stale value that must be ignored.
        bytes += Array(repeating: UInt8(0x42), count: audioByteCount)

        return Data(bytes)
    }

    func testMidRecordingSnapshotIgnoresStaleFillerSizeAndUsesActualBytesOnDisk() {
        // Declared filler size (4008) is far smaller than the 50,000 bytes of
        // real audio that have actually been appended after it -- exactly the
        // live-observed case (declared data size stuck at a few KB while the
        // file itself was hundreds of KB and growing).
        let bytes = avAudioRecorderStyleBytes(audioByteCount: 50_000, declaredFillerSize: 4_008)
        guard let snapshot = GrowingWAVReader.snapshot(of: bytes) else {
            return XCTFail("expected a snapshot")
        }
        XCTAssertEqual(dataChunkSize(of: snapshot), 50_000)
        XCTAssertEqual(snapshot.count, 44 + 50_000)
    }

    func testFinalizedFileWithAccurateDataChunkStillReadsCorrectly() {
        // After stop(), AVAudioRecorder rewrites FLLR -> data with an
        // accurate size. The reader must behave identically in this case.
        var bytes: [UInt8] = []
        bytes += Array("RIFF".utf8)
        bytes += uint32LE(UInt32(36 + 12_000))
        bytes += Array("WAVE".utf8)
        let fmt = canonicalFmtChunk()
        bytes += Array("fmt ".utf8)
        bytes += uint32LE(UInt32(fmt.count))
        bytes += fmt
        bytes += Array("data".utf8)
        bytes += uint32LE(12_000)
        bytes += Array(repeating: UInt8(0x11), count: 12_000)

        guard let snapshot = GrowingWAVReader.snapshot(of: Data(bytes)) else {
            return XCTFail("expected a snapshot")
        }
        XCTAssertEqual(dataChunkSize(of: snapshot), 12_000)
    }

    func testZeroAudioBytesWrittenSoFarProducesNoSnapshot() {
        let bytes = avAudioRecorderStyleBytes(audioByteCount: 0, declaredFillerSize: 4_008)
        XCTAssertNil(GrowingWAVReader.snapshot(of: bytes))
    }

    func testNonRIFFDataProducesNoSnapshot() {
        XCTAssertNil(GrowingWAVReader.snapshot(of: Data([0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11])))
    }

    func testTruncatedHeaderProducesNoSnapshot() {
        XCTAssertNil(GrowingWAVReader.snapshot(of: Data(Array("RIFF".utf8))))
    }

    private func dataChunkSize(of wav: Data) -> UInt32? {
        guard wav.count >= 44 else { return nil }
        let start = wav.startIndex
        let idRange = start + 36..<start + 40
        guard wav[idRange].elementsEqual(Array("data".utf8)) else { return nil }
        let sizeBytes = wav[start + 40..<start + 44]
        return sizeBytes.enumerated().reduce(into: UInt32(0)) { partial, element in
            partial |= UInt32(element.element) << (8 * element.offset)
        }
    }
}
