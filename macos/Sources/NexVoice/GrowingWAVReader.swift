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
        let payload = bytes[payloadOffset..<bytes.endIndex]
        guard !payload.isEmpty else { return nil }

        var result = Data()
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
