import Foundation
import zlib

enum ZipError: Error, LocalizedError {
    case invalidArchive
    case unsupportedCompression(UInt16)
    case decompressionFailed
    case compressionFailed

    var errorDescription: String? {
        switch self {
        case .invalidArchive: return "El archivo ZIP/.docx está dañado o no es válido."
        case .unsupportedCompression(let m): return "Método de compresión no soportado (\(m))."
        case .decompressionFailed: return "No se pudo descomprimir una entrada del archivo .docx."
        case .compressionFailed: return "Error al comprimir el archivo .docx."
        }
    }
}

private extension Data {
    func readUInt16LE(at offset: Int) -> UInt16 {
        UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    func readUInt32LE(at offset: Int) -> UInt32 {
        UInt32(self[offset])
            | (UInt32(self[offset + 1]) << 8)
            | (UInt32(self[offset + 2]) << 16)
            | (UInt32(self[offset + 3]) << 24)
    }

    mutating func appendUInt16LE(_ v: UInt16) {
        var le = v.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }

    mutating func appendUInt32LE(_ v: UInt32) {
        var le = v.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }
}

struct PureZip {
    static func read(data: Data) throws -> [String: Data] {
        guard data.count >= 22 else { throw ZipError.invalidArchive }

        // Locate End of Central Directory (0x06054b50) scanning backwards up to 64 KB + 22 bytes
        let minOffset = Swift.max(0, data.count - 65557)
        var eocdOffset = -1
        var idx = data.count - 22
        while idx >= minOffset {
            if data.readUInt32LE(at: idx) == 0x06054b50 {
                eocdOffset = idx
                break
            }
            idx -= 1
        }
        guard eocdOffset >= 0 else { throw ZipError.invalidArchive }

        let totalEntries = Int(data.readUInt16LE(at: eocdOffset + 10))
        let cdOffset = Int(data.readUInt32LE(at: eocdOffset + 16))
        guard cdOffset >= 0, cdOffset < data.count else { throw ZipError.invalidArchive }

        var result: [String: Data] = [:]
        var cursor = cdOffset

        for _ in 0..<totalEntries {
            guard cursor + 46 <= data.count, data.readUInt32LE(at: cursor) == 0x02014b50 else {
                throw ZipError.invalidArchive
            }

            let method = data.readUInt16LE(at: cursor + 10)
            let compSize = Int(data.readUInt32LE(at: cursor + 20))
            let uncompSize = Int(data.readUInt32LE(at: cursor + 24))
            let nameLen = Int(data.readUInt16LE(at: cursor + 28))
            let extraLen = Int(data.readUInt16LE(at: cursor + 30))
            let commentLen = Int(data.readUInt16LE(at: cursor + 32))
            let localHeaderOffset = Int(data.readUInt32LE(at: cursor + 42))

            guard cursor + 46 + nameLen <= data.count else { throw ZipError.invalidArchive }
            let nameData = data.subdata(in: (cursor + 46)..<(cursor + 46 + nameLen))
            let name = String(data: nameData, encoding: .utf8) ?? String(data: nameData, encoding: .isoLatin1) ?? ""
            cursor += 46 + nameLen + extraLen + commentLen

            if name.hasSuffix("/") { continue }

            guard localHeaderOffset + 30 <= data.count,
                  data.readUInt32LE(at: localHeaderOffset) == 0x04034b50 else {
                throw ZipError.invalidArchive
            }
            let localNameLen = Int(data.readUInt16LE(at: localHeaderOffset + 26))
            let localExtraLen = Int(data.readUInt16LE(at: localHeaderOffset + 28))
            let payloadStart = localHeaderOffset + 30 + localNameLen + localExtraLen
            let payloadEnd = payloadStart + compSize
            guard payloadStart >= 0, payloadEnd <= data.count else { throw ZipError.invalidArchive }

            let compressedSlice = data.subdata(in: payloadStart..<payloadEnd)
            let extracted: Data
            if method == 0 {
                extracted = compressedSlice
            } else if method == 8 {
                extracted = try inflateRaw(compressedSlice, expectedSize: uncompSize)
            } else {
                throw ZipError.unsupportedCompression(method)
            }
            result[name] = extracted
        }

        return result
    }

    static func write(entries: [String: Data]) throws -> Data {
        var out = Data()
        var centralDir = Data()
        var entryCount: UInt16 = 0

        for name in entries.keys.sorted() {
            guard let raw = entries[name] else { continue }
            let nameData = Data(name.utf8)
            let crc = computeCRC32(raw)
            let compressed = try deflateRaw(raw)

            let useDeflate = compressed.count < raw.count
            let method: UInt16 = useDeflate ? 8 : 0
            let payload = useDeflate ? compressed : raw
            let localOffset = UInt32(out.count)

            // Local file header (30 bytes + name)
            out.appendUInt32LE(0x04034b50)
            out.appendUInt16LE(20) // version needed
            out.appendUInt16LE(0x0800) // UTF-8 flag
            out.appendUInt16LE(method)
            out.appendUInt16LE(0) // mod time
            out.appendUInt16LE(0x5421) // mod date
            out.appendUInt32LE(crc)
            out.appendUInt32LE(UInt32(payload.count))
            out.appendUInt32LE(UInt32(raw.count))
            out.appendUInt16LE(UInt16(nameData.count))
            out.appendUInt16LE(0) // extra len
            out.append(nameData)
            out.append(payload)

            // Central directory record (46 bytes + name)
            centralDir.appendUInt32LE(0x02014b50)
            centralDir.appendUInt16LE(0x031E) // version made by (macOS/UNIX)
            centralDir.appendUInt16LE(20) // version needed
            centralDir.appendUInt16LE(0x0800) // UTF-8
            centralDir.appendUInt16LE(method)
            centralDir.appendUInt16LE(0)
            centralDir.appendUInt16LE(0x5421)
            centralDir.appendUInt32LE(crc)
            centralDir.appendUInt32LE(UInt32(payload.count))
            centralDir.appendUInt32LE(UInt32(raw.count))
            centralDir.appendUInt16LE(UInt16(nameData.count))
            centralDir.appendUInt16LE(0)
            centralDir.appendUInt16LE(0)
            centralDir.appendUInt16LE(0)
            centralDir.appendUInt16LE(0)
            centralDir.appendUInt32LE(0)
            centralDir.appendUInt32LE(localOffset)
            centralDir.append(nameData)

            entryCount &+= 1
        }

        let cdOffset = UInt32(out.count)
        let cdSize = UInt32(centralDir.count)
        out.append(centralDir)

        // End of central directory (22 bytes)
        out.appendUInt32LE(0x06054b50)
        out.appendUInt16LE(0)
        out.appendUInt16LE(0)
        out.appendUInt16LE(entryCount)
        out.appendUInt16LE(entryCount)
        out.appendUInt32LE(cdSize)
        out.appendUInt32LE(cdOffset)
        out.appendUInt16LE(0)

        return out
    }

    private static func computeCRC32(_ data: Data) -> UInt32 {
        if data.isEmpty { return 0 }
        return data.withUnsafeBytes { ptr -> UInt32 in
            guard let base = ptr.bindMemory(to: Bytef.self).baseAddress else { return 0 }
            return UInt32(crc32(0, base, uInt(data.count)))
        }
    }

    private static func deflateRaw(_ data: Data) throws -> Data {
        if data.isEmpty { return Data() }
        var stream = z_stream()
        let initStatus = deflateInit2_(
            &stream,
            Z_DEFAULT_COMPRESSION,
            Z_DEFLATED,
            -MAX_WBITS,
            8,
            Z_DEFAULT_STRATEGY,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard initStatus == Z_OK else { throw ZipError.compressionFailed }
        defer { deflateEnd(&stream) }

        var output = Data()
        let chunkSize = 16384
        var buffer = [UInt8](repeating: 0, count: chunkSize)

        try data.withUnsafeBytes { srcPtr in
            guard let base = srcPtr.bindMemory(to: Bytef.self).baseAddress else { return }
            stream.next_in = UnsafeMutablePointer(mutating: base)
            stream.avail_in = uInt(data.count)

            while true {
                let status = buffer.withUnsafeMutableBufferPointer { dstPtr -> Int32 in
                    stream.next_out = dstPtr.baseAddress
                    stream.avail_out = uInt(chunkSize)
                    return deflate(&stream, Z_FINISH)
                }
                let written = chunkSize - Int(stream.avail_out)
                if written > 0 {
                    output.append(buffer, count: written)
                }
                if status == Z_STREAM_END { break }
                if status != Z_OK && status != Z_BUF_ERROR {
                    throw ZipError.compressionFailed
                }
            }
        }
        return output
    }

    private static func inflateRaw(_ data: Data, expectedSize: Int) throws -> Data {
        if data.isEmpty { return Data() }
        var stream = z_stream()
        let initStatus = inflateInit2_(
            &stream,
            -MAX_WBITS,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard initStatus == Z_OK else { throw ZipError.decompressionFailed }
        defer { inflateEnd(&stream) }

        var output = Data(capacity: Swift.max(expectedSize, 64))
        let chunkSize = 16384
        var buffer = [UInt8](repeating: 0, count: chunkSize)

        try data.withUnsafeBytes { srcPtr in
            guard let base = srcPtr.bindMemory(to: Bytef.self).baseAddress else { return }
            stream.next_in = UnsafeMutablePointer(mutating: base)
            stream.avail_in = uInt(data.count)

            while true {
                let status = buffer.withUnsafeMutableBufferPointer { dstPtr -> Int32 in
                    stream.next_out = dstPtr.baseAddress
                    stream.avail_out = uInt(chunkSize)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                let written = chunkSize - Int(stream.avail_out)
                if written > 0 {
                    output.append(buffer, count: written)
                }
                if status == Z_STREAM_END { break }
                if status != Z_OK && status != Z_BUF_ERROR {
                    throw ZipError.decompressionFailed
                }
                if stream.avail_in == 0 && written == 0 {
                    break
                }
            }
        }
        return output
    }
}
