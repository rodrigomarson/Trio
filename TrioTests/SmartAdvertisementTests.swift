import Foundation
import Testing
@testable import Trio

@Suite("Smart Advertisement Tests") struct SmartAdvertisementTests {
    @Test("Parses captured Smart advertisements") func parsesCapturedAdvertisements() throws {
        let samples: [(hex: String, minutes: UInt16, trend: Int8, current: UInt16, quality: UInt8, previous: [UInt16])] = [
            ("59004D000000037680627480647480630000FDC32BE7", 77, 3, 118, 98, [116, 116]),
            ("5900590000000177806375806475806400000F8DAF82", 89, 1, 119, 99, [117, 117]),
            ("590067000000FE75806476806377806400000563554D", 103, -2, 117, 100, [118, 119]),
            ("59006B000000FF7580647480647580640000C9654683", 107, -1, 117, 100, [116, 117])
        ]

        for sample in samples {
            let advertisement = try #require(SmartAdvertisement(manufacturerData: try data(from: sample.hex)))
            #expect(advertisement.minutesSinceStart == sample.minutes)
            #expect(advertisement.trend == sample.trend)
            #expect(advertisement.current.glucose == sample.current)
            #expect(advertisement.current.quality == sample.quality)
            #expect(advertisement.current.isValid)
            #expect(advertisement.previous.map(\.glucose) == sample.previous)
            #expect(advertisement.previous.allSatisfy { $0.isValid })
        }
    }

    @Test("Rejects an invalid checksum") func rejectsInvalidChecksum() throws {
        var bytes = [UInt8](try data(from: "59006B000000FF7580647480647580640000C9654683"))
        bytes[7] ^= 0x01
        #expect(SmartAdvertisement(manufacturerData: Data(bytes)) == nil)
    }

    @Test("Rejects another manufacturer") func rejectsAnotherManufacturer() throws {
        var bytes = [UInt8](try data(from: "59006B000000FF7580647480647580640000C9654683"))
        bytes[0] = 0x58
        #expect(SmartAdvertisement(manufacturerData: Data(bytes)) == nil)
    }

    @Test("Accepts captured advertisements with trailing transport data")
    func acceptsTrailingTransportData() throws {
        let advertisement = try #require(
            SmartAdvertisement(
                manufacturerData: try data(
                    from: "59009D010000026480636580636480640000E8DDD08203F7057236"
                )
            )
        )

        #expect(advertisement.minutesSinceStart == 413)
        #expect(advertisement.trend == 2)
        #expect(advertisement.current.glucose == 100)
        #expect(advertisement.current.quality == 99)
        #expect(advertisement.current.isValid)
        #expect(advertisement.previous.map(\.glucose) == [101, 100])
    }

    @Test("Orders current and previous records by session minute") func ordersHistoricalRecords() throws {
        let advertisement = try #require(
            SmartAdvertisement(
                manufacturerData: try data(from: "59006B000000FF7580647480647580640000C9654683")
            )
        )

        #expect(advertisement.chronologicalRecords.map(\.minutesSinceStart) == [105, 106, 107])
        #expect(advertisement.chronologicalRecords.map(\.record.glucose) == [117, 116, 117])
        #expect(advertisement.chronologicalRecords.allSatisfy { $0.record.isValid })
    }

    private func data(from hex: String) throws -> Data {
        let characters = Array(hex)
        guard characters.count.isMultiple(of: 2) else {
            throw TestError("Hex input must contain an even number of characters")
        }

        return try Data(stride(from: 0, to: characters.count, by: 2).map { offset in
            let byte = String(characters[offset ... offset + 1])
            guard let value = UInt8(byte, radix: 16) else {
                throw TestError("Invalid hexadecimal byte: \(byte)")
            }
            return value
        })
    }
}
