import Foundation

/// AVAudioRecorder (linear-PCM `.wav`) reserves a header region up front --
/// `RIFF`/`WAVE`, a `JUNK` alignment chunk, the `fmt ` chunk, and a filler
/// chunk (`FLLR`) sized to reserve room for the eventual `data` chunk -- and
/// only rewrites the declared RIFF/data chunk sizes when `stop()` finalizes
/// the file. Any reader that trusts the file's own header while recording is
/// still in progress sees a permanently stale (often zero) frame count,
/// because that header is never patched until the recorder actually stops.
///
/// This walks the real RIFF chunk structure to find where the PCM payload
/// begins, then treats everything from there to the file's *actual* current
/// end-of-file as audio -- ignoring whatever the chunk's own declared size
/// says -- and re-wraps it in a header whose sizes match reality. This is
/// safe to call both mid-recording (stale header) and after `stop()`
/// (already-accurate header): in both cases "payload start to real EOF" is
/// the correct set of audio bytes.
enum GrowingWAVReader {
    /// Chunk IDs AVAudioFile is known to use as a placeholder for the
    /// eventual `data` chunk while a file is still being written.
    private static let dataChunkIDs: Set<String> = ["data", "FLLR"]

    static func snapshot(of bytes: Data) -> Data? {
        guard let header = parseHeader(bytes) else { return nil }
        let payload = bytes[(bytes.startIndex + header.payloadOffset)..<bytes.endIndex]
        guard !payload.isEmpty else { return nil }
        return wrap(fmtChunk: header.fmtChunk, payload: payload)
    }

    /// Bytes read from the front of the file to locate `fmt ` and the payload
    /// start. AVAudioRecorder's header (incl. the FLLR reservation's chunk
    /// header) sits well inside this.
    static let headerProbeBytes = 64 * 1_024

    /// Like `snapshot(of:)`, but reads only the header plus the last
    /// `maxSeconds` of audio straight from disk (claude-c13r). The live
    /// preview used to load the whole growing recording every 1.8s, which made
    /// memory and I/O grow quadratically with dictation length.
    static func tailSnapshot(of url: URL, maxSeconds: Double) throws -> Data? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let fileSize = try Int(handle.seekToEnd())
        try handle.seek(toOffset: 0)
        guard let headerBytes = try handle.read(upToCount: min(fileSize, headerProbeBytes)),
              let header = parseHeader(headerBytes),
              header.payloadOffset < fileSize
        else { return nil }

        let fmt = header.fmtChunk
        // WAVEFORMAT: byteRate at offset 8 (UInt32), blockAlign at 12 (UInt16).
        let byteRate = fmt.count >= 12 ? Int(readUInt32LE(fmt, at: fmt.startIndex + 8)) : 0
        let blockAlign = fmt.count >= 14
            ? max(1, Int(fmt[fmt.startIndex + 12]) | Int(fmt[fmt.startIndex + 13]) << 8)
            : 1
        let payloadLength = fileSize - header.payloadOffset
        var skip = 0
        if byteRate > 0, maxSeconds > 0 {
            let window = Int(Double(byteRate) * maxSeconds)
            if payloadLength > window {
                // Keep the tail frame-aligned relative to the payload start.
                skip = (payloadLength - window + blockAlign - 1) / blockAlign * blockAlign
            }
        }
        guard skip < payloadLength else { return nil }
        try handle.seek(toOffset: UInt64(header.payloadOffset + skip))
        guard let payload = try handle.read(upToCount: payloadLength - skip),
              !payload.isEmpty
        else { return nil }
        return wrap(fmtChunk: fmt, payload: payload)
    }

    private static func parseHeader(_ bytes: Data) -> (fmtChunk: Data, payloadOffset: Int)? {
        guard bytes.count >= 12 else { return nil }
        let start = bytes.startIndex
        guard bytes[start..<start + 4].elementsEqual(Array("RIFF".utf8)),
              bytes[start + 8..<start + 12].elementsEqual(Array("WAVE".utf8))
        else { return nil }

        var fmtChunkData: Data?
        var payloadOffset: Int?
        var cursor = start + 12
        while cursor + 8 <= bytes.endIndex {
            let idBytes = bytes[cursor..<cursor + 4]
            guard let chunkID = String(bytes: idBytes, encoding: .ascii) else { break }
            let declaredSize = Int(readUInt32LE(bytes, at: cursor + 4))
            let dataStart = cursor + 8

            if chunkID == "fmt " {
                guard dataStart + declaredSize <= bytes.endIndex else { break }
                fmtChunkData = bytes[dataStart..<dataStart + declaredSize]
            }
            if dataChunkIDs.contains(chunkID) {
                payloadOffset = dataStart
                break
            }
            guard declaredSize >= 0, dataStart + declaredSize <= bytes.endIndex else { break }
            cursor = dataStart + declaredSize + (declaredSize % 2)
        }

        guard let fmtChunkData, let payloadOffset, payloadOffset <= bytes.endIndex else { return nil }
        return (fmtChunkData, payloadOffset - start)
    }

    private static func wrap(fmtChunk fmtChunkData: Data, payload: Data) -> Data {
        var result = Data()
        result.reserveCapacity(20 + fmtChunkData.count + payload.count)
        result.append(contentsOf: Array("RIFF".utf8))
        appendUInt32LE(&result, UInt32(4 + (8 + fmtChunkData.count) + (8 + payload.count)))
        result.append(contentsOf: Array("WAVE".utf8))
        result.append(contentsOf: Array("fmt ".utf8))
        appendUInt32LE(&result, UInt32(fmtChunkData.count))
        result.append(fmtChunkData)
        result.append(contentsOf: Array("data".utf8))
        appendUInt32LE(&result, UInt32(payload.count))
        result.append(payload)
        return result
    }

    private static func readUInt32LE(_ data: Data, at offset: Data.Index) -> UInt32 {
        guard offset + 4 <= data.endIndex else { return 0 }
        let bytes = data[offset..<offset + 4]
        return bytes.enumerated().reduce(into: UInt32(0)) { partial, element in
            partial |= UInt32(element.element) << (8 * element.offset)
        }
    }

    private static func appendUInt32LE(_ data: inout Data, _ value: UInt32) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 24) & 0xFF))
    }
}
