import Foundation
import Testing
@testable import uCritAir

@Suite("Data Parsing")
struct DataParsingTests {

    @Test("little-endian read/write round trips")
    func littleEndianRoundTrips() throws {
        var data = Data(count: 20)
        data.writeUInt8(0xAB, at: 0)
        data.writeUInt16LE(0x1234, at: 1)
        data.writeUInt32LE(0x89ABCDEF, at: 3)
        data.writeUInt64LE(0x1122334455667788, at: 7)
        data.writeUInt32LE(Float(12.5).bitPattern, at: 15)

        #expect(data.readUInt8(at: 0) == 0xAB)
        #expect(data.readUInt16LE(at: 1) == 0x1234)
        #expect(data.readUInt32LE(at: 3) == 0x89ABCDEF)
        #expect(data.readUInt64LE(at: 7) == 0x1122334455667788)
        #expect(abs(data.readFloat32LE(at: 15) - 12.5) < 0.001)
    }

    @Test("signed reads decode two's-complement values")
    func signedReads() throws {
        let int16Data = Data([0xFE, 0xFF])
        let int32Data = Data([0xFC, 0xFF, 0xFF, 0xFF])

        #expect(try int16Data.tryReadInt16LE(at: 0) == -2)
        #expect(try int32Data.tryReadInt32LE(at: 0) == -4)
    }

    @Test("tryRead APIs throw out-of-bounds errors")
    func tryReadThrowsOutOfBounds() {
        let data = Data([0x01, 0x02])

        do {
            _ = try data.tryReadUInt32LE(at: 0)
            #expect(Bool(false))
        } catch let error as DataParsingError {
            guard case let .outOfBounds(offset, length, count) = error else {
                #expect(Bool(false))
                return
            }
            #expect(offset == 0)
            #expect(length == 4)
            #expect(count == 2)
        } catch {
            #expect(Bool(false))
        }

        do {
            _ = try data.tryReadUInt8(at: -1)
            #expect(Bool(false))
        } catch {
            #expect(error is DataParsingError)
        }
    }

    @Test("hex conversion round-trip and invalid tokens")
    func hexConversion() {
        let original = Data([0x0A, 0xFF, 0x10])
        #expect(original.hexString == "0A FF 10")
        #expect(Data.fromHexString(original.hexString) == original)
        #expect(Data.fromHexString("GG") == nil)
        #expect(Data.fromHexString("AA B") == nil)
    }
}
