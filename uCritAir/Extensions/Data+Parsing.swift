import Foundation

enum DataParsingError: LocalizedError, Equatable {
    case outOfBounds(offset: Int, length: Int, count: Int)

    var errorDescription: String? {
        switch self {
        case .outOfBounds(let offset, let length, let count):
            let needed = offset + length
            return "Need at least \(needed) bytes to read \(length) byte(s) at offset \(offset); payload has \(count) bytes."
        }
    }
}

extension Data {

    private func validatedStartIndex(offset: Int, length: Int) throws -> Data.Index {
        guard offset >= 0, length > 0 else {
            throw DataParsingError.outOfBounds(offset: offset, length: length, count: count)
        }
        guard count >= offset + length else {
            throw DataParsingError.outOfBounds(offset: offset, length: length, count: count)
        }
        return startIndex + offset
    }

    func tryReadUInt8(at offset: Int) throws -> UInt8 {
        let i = try validatedStartIndex(offset: offset, length: 1)
        return self[i]
    }

    func tryReadInt16LE(at offset: Int) throws -> Int16 {
        let i = try validatedStartIndex(offset: offset, length: 2)
        return Int16(self[i]) | (Int16(self[i + 1]) << 8)
    }

    func tryReadUInt16LE(at offset: Int) throws -> UInt16 {
        let i = try validatedStartIndex(offset: offset, length: 2)
        return UInt16(self[i]) | (UInt16(self[i + 1]) << 8)
    }

    func tryReadInt32LE(at offset: Int) throws -> Int32 {
        let i = try validatedStartIndex(offset: offset, length: 4)
        return Int32(self[i])
            | (Int32(self[i + 1]) << 8)
            | (Int32(self[i + 2]) << 16)
            | (Int32(self[i + 3]) << 24)
    }

    func tryReadUInt32LE(at offset: Int) throws -> UInt32 {
        let i = try validatedStartIndex(offset: offset, length: 4)
        return UInt32(self[i])
            | (UInt32(self[i + 1]) << 8)
            | (UInt32(self[i + 2]) << 16)
            | (UInt32(self[i + 3]) << 24)
    }

    func tryReadUInt64LE(at offset: Int) throws -> UInt64 {
        let low = UInt64(try tryReadUInt32LE(at: offset))
        let high = UInt64(try tryReadUInt32LE(at: offset + 4))
        return (high << 32) | low
    }

    func tryReadFloat32LE(at offset: Int) throws -> Float {
        let bits = try tryReadUInt32LE(at: offset)
        return Float(bitPattern: bits)
    }

    /// Convenience reads — callers must validate `count` before calling.
    /// Asserts in debug; returns zero in release if bounds are violated.
    func readUInt8(at offset: Int) -> UInt8 {
        guard let v = try? tryReadUInt8(at: offset) else {
            assertionFailure("Data.readUInt8 out of bounds (offset \(offset), count \(count))")
            return 0
        }
        return v
    }

    func readInt16LE(at offset: Int) -> Int16 {
        guard let v = try? tryReadInt16LE(at: offset) else {
            assertionFailure("Data.readInt16LE out of bounds (offset \(offset), count \(count))")
            return 0
        }
        return v
    }

    func readUInt16LE(at offset: Int) -> UInt16 {
        guard let v = try? tryReadUInt16LE(at: offset) else {
            assertionFailure("Data.readUInt16LE out of bounds (offset \(offset), count \(count))")
            return 0
        }
        return v
    }

    func readInt32LE(at offset: Int) -> Int32 {
        guard let v = try? tryReadInt32LE(at: offset) else {
            assertionFailure("Data.readInt32LE out of bounds (offset \(offset), count \(count))")
            return 0
        }
        return v
    }

    func readUInt32LE(at offset: Int) -> UInt32 {
        guard let v = try? tryReadUInt32LE(at: offset) else {
            assertionFailure("Data.readUInt32LE out of bounds (offset \(offset), count \(count))")
            return 0
        }
        return v
    }

    func readUInt64LE(at offset: Int) -> UInt64 {
        guard let v = try? tryReadUInt64LE(at: offset) else {
            assertionFailure("Data.readUInt64LE out of bounds (offset \(offset), count \(count))")
            return 0
        }
        return v
    }

    func readFloat32LE(at offset: Int) -> Float {
        guard let v = try? tryReadFloat32LE(at: offset) else {
            assertionFailure("Data.readFloat32LE out of bounds (offset \(offset), count \(count))")
            return 0
        }
        return v
    }

    var hexString: String {
        map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    static func fromHexString(_ hex: String) -> Data? {
        let tokens = hex.split(separator: " ")
        var bytes: [UInt8] = []
        for token in tokens {
            guard token.count == 2, let byte = UInt8(token, radix: 16) else { return nil }
            bytes.append(byte)
        }
        return Data(bytes)
    }

    mutating func writeUInt16LE(_ value: UInt16, at offset: Int) {
        let i = startIndex + offset
        self[i] = UInt8(value & 0xFF)
        self[i + 1] = UInt8((value >> 8) & 0xFF)
    }

    mutating func writeUInt32LE(_ value: UInt32, at offset: Int) {
        let i = startIndex + offset
        self[i] = UInt8(value & 0xFF)
        self[i + 1] = UInt8((value >> 8) & 0xFF)
        self[i + 2] = UInt8((value >> 16) & 0xFF)
        self[i + 3] = UInt8((value >> 24) & 0xFF)
    }

    mutating func writeUInt8(_ value: UInt8, at offset: Int) {
        self[startIndex + offset] = value
    }

    mutating func writeUInt64LE(_ value: UInt64, at offset: Int) {
        writeUInt32LE(UInt32(value & 0xFFFFFFFF), at: offset)
        writeUInt32LE(UInt32((value >> 32) & 0xFFFFFFFF), at: offset + 4)
    }
}
