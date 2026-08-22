import Foundation

/// A glucose record carried in the manufacturer data advertised by Smart/LinX sensors.
struct SmartAdvertisement: Equatable {
    struct GlucoseRecord: Equatable {
        let glucose: UInt16
        let quality: UInt8
        let isValid: Bool
    }

    static let companyIdentifier: UInt16 = 0x0059
    static let payloadLength = 22

    let minutesSinceStart: UInt16
    let status: UInt8
    let calibrationTemperatureStatus: UInt8
    let trend: Int8
    let current: GlucoseRecord
    let previous: [GlucoseRecord]
    let checksum: UInt32

    /// Returns the records carried by one advertisement in chronological order.
    ///
    /// Captures from the physical sensor show that `previous[0]` belongs to the
    /// preceding session minute and `previous[1]` to the minute before that.
    var chronologicalRecords: [(minutesSinceStart: UInt16, record: GlucoseRecord)] {
        var records: [(minutesSinceStart: UInt16, record: GlucoseRecord)] = []
        if minutesSinceStart >= 2, previous.indices.contains(1) {
            records.append((minutesSinceStart - 2, previous[1]))
        }
        if minutesSinceStart >= 1, previous.indices.contains(0) {
            records.append((minutesSinceStart - 1, previous[0]))
        }
        records.append((minutesSinceStart, current))
        return records
    }

    init?(manufacturerData: Data) {
        guard manufacturerData.count >= Self.payloadLength else { return nil }

        // Some Smart/LinX firmware appends five transport-specific bytes after
        // the 22-byte glucose payload. The checksum covers only the protocol
        // payload, so ignore any trailing transport data.
        let bytes = [UInt8](manufacturerData.prefix(Self.payloadLength))
        guard Self.uint16(bytes, at: 0) == Self.companyIdentifier else { return nil }

        let checksum = Self.uint32(bytes, at: 18)
        guard checksum == Self.calculateChecksum(bytes) else { return nil }

        minutesSinceStart = Self.uint16(bytes, at: 2)
        status = bytes[4]
        calibrationTemperatureStatus = bytes[5]
        trend = Int8(bitPattern: bytes[6])
        current = Self.glucoseRecord(bytes, wordOffset: 7, qualityOffset: 9)
        previous = [
            Self.glucoseRecord(bytes, wordOffset: 10, qualityOffset: 12),
            Self.glucoseRecord(bytes, wordOffset: 13, qualityOffset: 15)
        ]
        self.checksum = checksum
    }

    private static func glucoseRecord(
        _ bytes: [UInt8],
        wordOffset: Int,
        qualityOffset: Int
    ) -> GlucoseRecord {
        let word = uint16(bytes, at: wordOffset)
        return GlucoseRecord(
            glucose: word & 0x03FF,
            quality: bytes[qualityOffset],
            isValid: word & 0x8000 != 0
        )
    }

    private static func calculateChecksum(_ bytes: [UInt8]) -> UInt32 {
        let payload = Array(bytes[2 ..< 18])
        // The sensor firmware performs this sum in a 32-bit register and
        // discards the carry before applying the modulus. This matters whenever
        // the four words add up to more than UInt32.max.
        let sum = stride(from: 0, to: payload.count, by: 4).reduce(UInt32(0)) { partial, offset in
            partial &+ uint32(payload, at: offset)
        }
        var crc = sum % 0x7FA777

        for byte in payload {
            crc ^= UInt32(byte) << 24
            for _ in 0 ..< 8 {
                crc = crc & 0x8000_0000 != 0
                    ? (crc << 1) ^ 0x04C1_1DB7
                    : crc << 1
            }
        }

        return crc
    }

    private static func uint16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    private static func uint32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset]) |
            UInt32(bytes[offset + 1]) << 8 |
            UInt32(bytes[offset + 2]) << 16 |
            UInt32(bytes[offset + 3]) << 24
    }
}

/// Suppresses repeated radio callbacks carrying the same sensor minute.
///
/// The Bluetooth scan must allow duplicate discoveries for Smart firmware that
/// otherwise reports only once. This gate prevents those repeated packets from
/// waking Trio's state, storage, and algorithm pipeline.
struct SmartAdvertisementDeduplicator {
    private var lastForwarded: [UUID: (minute: UInt16, checksum: UInt32)] = [:]

    mutating func shouldForward(
        peripheralIdentifier: UUID,
        advertisement: SmartAdvertisement
    ) -> Bool {
        let fingerprint = (
            minute: advertisement.minutesSinceStart,
            checksum: advertisement.checksum
        )
        if let previous = lastForwarded[peripheralIdentifier],
           previous.minute == fingerprint.minute,
           previous.checksum == fingerprint.checksum
        {
            return false
        }
        lastForwarded[peripheralIdentifier] = fingerprint
        return true
    }
}

/// The standard Bluetooth CGM Feature characteristic (2AA8).
struct SmartCGMFeature: Equatable {
    private static let e2eCRCBit: UInt32 = 1 << 12

    let featureBits: UInt32
    let typeAndSampleLocation: UInt8

    var supportsE2ECRC: Bool {
        featureBits & Self.e2eCRCBit != 0
    }

    init?(data: Data) {
        guard data.count >= 4 else { return nil }
        let bytes = [UInt8](data)
        featureBits = UInt32(bytes[0]) |
            UInt32(bytes[1]) << 8 |
            UInt32(bytes[2]) << 16
        typeAndSampleLocation = bytes[3]

        if supportsE2ECRC {
            guard bytes.count >= 6, SmartCGMCRC.isValid(bytes) else {
                return nil
            }
        }
    }
}

enum SmartCGMCRC {
    static func isValid(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 2 else { return false }
        let payload = Array(bytes.dropLast(2))
        let transmitted = UInt16(bytes[bytes.count - 2]) |
            UInt16(bytes[bytes.count - 1]) << 8

        // The captured Smart 2.0 Feature value uses the byte-wise CCITT
        // implementation. Accept the bit-reflected form from the Bluetooth CGM
        // specification as well so standards-compliant firmware also works.
        return transmitted == byteWiseCRC(payload) ||
            transmitted == reflectedCRC(payload)
    }

    static func checksum(for bytes: [UInt8]) -> UInt16 {
        byteWiseCRC(bytes)
    }

    static func appendingChecksum(to bytes: [UInt8]) -> Data {
        let checksum = checksum(for: bytes)
        return Data(bytes + [UInt8(checksum & 0xFF), UInt8(checksum >> 8)])
    }

    private static func byteWiseCRC(_ bytes: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for byte in bytes {
            crc ^= UInt16(byte) << 8
            for _ in 0 ..< 8 {
                crc = crc & 0x8000 != 0
                    ? (crc << 1) ^ 0x1021
                    : crc << 1
            }
        }
        return crc
    }

    private static func reflectedCRC(_ bytes: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for byte in bytes {
            crc ^= UInt16(byte)
            for _ in 0 ..< 8 {
                crc = crc & 1 != 0
                    ? (crc >> 1) ^ 0x8408
                    : crc >> 1
            }
        }
        return crc
    }
}

/// The standard Bluetooth CGM Status characteristic (2AA9).
struct SmartCGMStatus: Equatable {
    enum ParsingError: Error, Equatable {
        case invalidLength
        case invalidCRC
    }

    let timeOffset: UInt16
    let sensorStatus: UInt8
    let calibrationTemperatureStatus: UInt8
    let warningStatus: UInt8

    var isSessionStopped: Bool { sensorStatus & (1 << 0) != 0 }
    var needsTimeSynchronization: Bool { sensorStatus & (1 << 3) != 0 }

    init(data: Data, supportsE2ECRC: Bool) throws {
        let bytes = [UInt8](data)
        let expectedLength = supportsE2ECRC ? 7 : 5
        guard bytes.count == expectedLength else {
            throw ParsingError.invalidLength
        }
        if supportsE2ECRC, !SmartCGMCRC.isValid(bytes) {
            throw ParsingError.invalidCRC
        }

        timeOffset = UInt16(bytes[0]) | UInt16(bytes[1]) << 8
        sensorStatus = bytes[2]
        calibrationTemperatureStatus = bytes[3]
        warningStatus = bytes[4]
    }
}

enum SmartCGMSpecificOpsControlPoint {
    enum ResponseError: Error, Equatable {
        case invalidLength
        case invalidCRC
        case unexpectedResponse
        case failed(UInt8)
    }

    private static let startSessionOpcode: UInt8 = 0x1A
    private static let responseOpcode: UInt8 = 0x1C
    private static let successResponse: UInt8 = 0x01

    static func startSessionCommand(supportsE2ECRC: Bool) -> Data {
        let bytes = [startSessionOpcode]
        return supportsE2ECRC ? SmartCGMCRC.appendingChecksum(to: bytes) : Data(bytes)
    }

    static func validateStartSessionResponse(
        _ data: Data,
        supportsE2ECRC: Bool
    ) throws {
        let bytes = [UInt8](data)
        let expectedLength = supportsE2ECRC ? 5 : 3
        guard bytes.count == expectedLength else {
            throw ResponseError.invalidLength
        }
        if supportsE2ECRC, !SmartCGMCRC.isValid(bytes) {
            throw ResponseError.invalidCRC
        }
        guard bytes[0] == responseOpcode, bytes[1] == startSessionOpcode else {
            throw ResponseError.unexpectedResponse
        }
        guard bytes[2] == successResponse else {
            throw ResponseError.failed(bytes[2])
        }
    }
}

enum SmartCGMSessionStartTime {
    /// Encodes the standard CGM Session Start Time characteristic (2AAA).
    static func data(
        date: Date,
        timeZone: TimeZone,
        supportsE2ECRC: Bool
    ) -> Data {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )
        let year = UInt16(clamping: components.year ?? 0)
        let quarterHours = max(-48, min(56, timeZone.secondsFromGMT(for: date) / 900))
        let daylightSavingOffset = timeZone.daylightSavingTimeOffset(for: date)
        let dstOffset: UInt8
        switch Int(daylightSavingOffset / 900) {
        case 2: dstOffset = 2
        case 4: dstOffset = 4
        case 8: dstOffset = 8
        default: dstOffset = 0
        }

        let bytes: [UInt8] = [
            UInt8(year & 0xFF),
            UInt8(year >> 8),
            UInt8(clamping: components.month ?? 0),
            UInt8(clamping: components.day ?? 0),
            UInt8(clamping: components.hour ?? 0),
            UInt8(clamping: components.minute ?? 0),
            UInt8(clamping: components.second ?? 0),
            UInt8(bitPattern: Int8(quarterHours)),
            dstOffset
        ]
        return supportsE2ECRC ? SmartCGMCRC.appendingChecksum(to: bytes) : Data(bytes)
    }
}

/// A record returned by the standard Bluetooth CGM Measurement characteristic (2AA7).
struct SmartCGMMeasurement: Equatable {
    enum ParsingError: Error, Equatable {
        case truncatedRecord
        case invalidRecordSize
        case invalidGlucose
        case invalidCRC
        case unexpectedRecordSize
    }

    let glucose: Double
    let timeOffset: UInt16
    let trendRate: Double?
    let quality: Double?
    let sensorStatus: UInt8?
    let calibrationTemperatureStatus: UInt8?
    let warningStatus: UInt8?

    static func records(
        from data: Data,
        supportsE2ECRC: Bool
    ) throws -> [SmartCGMMeasurement] {
        let bytes = [UInt8](data)
        var records: [SmartCGMMeasurement] = []
        var recordOffset = 0

        while recordOffset < bytes.count {
            guard bytes.count - recordOffset >= 6 else {
                throw ParsingError.truncatedRecord
            }

            let size = Int(bytes[recordOffset])
            guard size >= 6 else {
                throw ParsingError.invalidRecordSize
            }
            guard recordOffset + size <= bytes.count else {
                throw ParsingError.truncatedRecord
            }

            records.append(
                try parseRecord(
                    Array(bytes[recordOffset ..< recordOffset + size]),
                    supportsE2ECRC: supportsE2ECRC
                )
            )
            recordOffset += size
        }

        return records
    }

    private static func parseRecord(
        _ bytes: [UInt8],
        supportsE2ECRC: Bool
    ) throws -> SmartCGMMeasurement {
        if supportsE2ECRC, !SmartCGMCRC.isValid(bytes) {
            throw ParsingError.invalidCRC
        }

        let flags = bytes[1]
        guard let glucose = decodeSFloat(uint16(bytes, at: 2)) else {
            throw ParsingError.invalidGlucose
        }

        var offset = 6
        let recordEnd = bytes.count - (supportsE2ECRC ? 2 : 0)
        guard recordEnd >= offset else {
            throw ParsingError.truncatedRecord
        }

        func optionalByte(when mask: UInt8) throws -> UInt8? {
            guard flags & mask != 0 else { return nil }
            guard offset < recordEnd else { throw ParsingError.truncatedRecord }
            defer { offset += 1 }
            return bytes[offset]
        }

        func optionalSFloat(when mask: UInt8) throws -> Double? {
            guard flags & mask != 0 else { return nil }
            guard offset + 1 < recordEnd else { throw ParsingError.truncatedRecord }
            defer { offset += 2 }
            return decodeSFloat(uint16(bytes, at: offset))
        }

        let sensorStatus = try optionalByte(when: 1 << 5)
        let calibrationTemperatureStatus = try optionalByte(when: 1 << 6)
        let warningStatus = try optionalByte(when: 1 << 7)
        let trendRate = try optionalSFloat(when: 1 << 0)
        let quality = try optionalSFloat(when: 1 << 1)

        guard offset == recordEnd else {
            throw ParsingError.unexpectedRecordSize
        }

        return SmartCGMMeasurement(
            glucose: glucose,
            timeOffset: uint16(bytes, at: 4),
            trendRate: trendRate,
            quality: quality,
            sensorStatus: sensorStatus,
            calibrationTemperatureStatus: calibrationTemperatureStatus,
            warningStatus: warningStatus
        )
    }

    private static func decodeSFloat(_ rawValue: UInt16) -> Double? {
        let rawMantissa = Int(rawValue & 0x0FFF)
        guard !(0x07FF ... 0x0802).contains(rawMantissa) else { return nil }

        let mantissa = rawMantissa & 0x0800 == 0
            ? rawMantissa
            : rawMantissa - 0x1000
        let rawExponent = Int((rawValue >> 12) & 0x0F)
        let exponent = rawExponent & 0x08 == 0
            ? rawExponent
            : rawExponent - 0x10
        return Double(mantissa) * pow(10, Double(exponent))
    }

    private static func uint16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }
}

/// Read-only commands and responses for the standard Record Access Control Point (2A52).
enum SmartRecordAccessControlPoint {
    enum Response: Equatable {
        case numberOfRecords(UInt16)
        case completion(requestOpcode: UInt8, responseCode: UInt8)
    }

    static func reportStoredRecords(from minimumTimeOffset: UInt16?) -> Data {
        guard let minimumTimeOffset else {
            return Data([0x01, 0x01])
        }
        return Data([
            0x01,
            0x03,
            0x01,
            UInt8(truncatingIfNeeded: minimumTimeOffset),
            UInt8(truncatingIfNeeded: minimumTimeOffset >> 8)
        ])
    }

    static func response(from data: Data) -> Response? {
        let bytes = [UInt8](data)
        guard bytes.count >= 2, bytes[1] == 0 else { return nil }

        switch bytes[0] {
        case 0x05:
            guard bytes.count == 4 else { return nil }
            return .numberOfRecords(
                UInt16(bytes[2]) | UInt16(bytes[3]) << 8
            )
        case 0x06:
            guard bytes.count == 4 else { return nil }
            return .completion(
                requestOpcode: bytes[2],
                responseCode: bytes[3]
            )
        default:
            return nil
        }
    }
}

/// Chooses a five-minute historical series from the minute records kept by the sensor.
enum SmartBackfillSelector {
    static let maximumAgeMinutes: UInt16 = 6 * 60
    private static let deliveryInterval: UInt16 = 5

    static func select(
        _ records: [SmartCGMMeasurement],
        endingAt currentMinute: UInt16
    ) -> [SmartCGMMeasurement] {
        let earliestMinute = currentMinute > maximumAgeMinutes
            ? currentMinute - maximumAgeMinutes
            : 0
        let candidates = records
            .filter {
                $0.timeOffset >= earliestMinute &&
                    $0.timeOffset <= currentMinute &&
                    $0.glucose.isFinite &&
                    (20 ... 600).contains($0.glucose) &&
                    ($0.quality.map { $0 > 0 } ?? true)
            }
            .sorted { $0.timeOffset > $1.timeOffset }

        var selected: [SmartCGMMeasurement] = []
        for record in candidates {
            guard
                let lastMinute = selected.last?.timeOffset
            else {
                selected.append(record)
                continue
            }
            if lastMinute - record.timeOffset >= deliveryInterval {
                selected.append(record)
            }
        }
        return Array(selected.reversed())
    }
}

/// Maintains the minute-by-minute history advertised by Smart sensors.
///
/// Keeps the denser sensor data for trend calculation and produces a guarded
/// estimate for every new Smart minute. Trio's existing glucose storage filter
/// remains responsible for the cadence used by the dosing pipeline.
struct SmartGlucoseRegularizer {
    struct Sample: Equatable {
        let minutesSinceStart: UInt16
        let glucose: Double
        let quality: UInt8
    }

    struct Estimate: Equatable {
        let glucose: Double
        let trendRate: Double?
        let usedRegularization: Bool
        let sampleCount: Int
    }

    private enum Config {
        static let retainedMinutes: UInt16 = 15
        static let estimationMinutes: UInt16 = 4
        static let maximumAdjustment = 10.0
        static let rapidChangeRate = 2.0
        static let lowSafetyThreshold = 100.0
    }

    private(set) var samples: [Sample]

    init(samples: [Sample] = []) {
        self.samples = samples.sorted { $0.minutesSinceStart < $1.minutesSinceStart }
        trimHistory()
    }

    mutating func reset() {
        samples.removeAll()
    }

    mutating func ingest(
        _ records: [(minutesSinceStart: UInt16, record: SmartAdvertisement.GlucoseRecord)],
        packetStateIsReliable: Bool
    ) {
        guard packetStateIsReliable else { return }

        for item in records where Self.isReliable(item.record) {
            let sample = Sample(
                minutesSinceStart: item.minutesSinceStart,
                glucose: Double(item.record.glucose),
                quality: item.record.quality
            )

            if let existingIndex = samples.firstIndex(where: {
                $0.minutesSinceStart == sample.minutesSinceStart
            }) {
                samples[existingIndex] = sample
            } else {
                samples.append(sample)
            }
        }

        samples.sort { $0.minutesSinceStart < $1.minutesSinceStart }
        trimHistory()
    }

    func estimate(at minutesSinceStart: UInt16, regularizationEnabled: Bool) -> Estimate? {
        let recent = samples.filter {
            $0.minutesSinceStart <= minutesSinceStart &&
                minutesSinceStart - $0.minutesSinceStart <= Config.estimationMinutes
        }
        guard let latest = recent.last(where: { $0.minutesSinceStart == minutesSinceStart }) else {
            return nil
        }

        let rate = Self.linearRate(recent)
        let shouldUseRegularization = regularizationEnabled &&
            recent.count >= 4 &&
            !Self.requiresLatestRawValue(latest: latest, rate: rate)

        guard shouldUseRegularization, let fitted = Self.fittedValue(recent, at: minutesSinceStart) else {
            return Estimate(
                glucose: latest.glucose,
                trendRate: rate,
                usedRegularization: false,
                sampleCount: recent.count
            )
        }

        let lowerBound = latest.glucose - Config.maximumAdjustment
        let upperBound = latest.glucose + Config.maximumAdjustment
        return Estimate(
            glucose: min(max(fitted, lowerBound), upperBound).rounded(),
            trendRate: rate,
            usedRegularization: true,
            sampleCount: recent.count
        )
    }

    private mutating func trimHistory() {
        guard let latestMinute = samples.last?.minutesSinceStart else { return }
        samples.removeAll {
            $0.minutesSinceStart > latestMinute ||
                latestMinute - $0.minutesSinceStart > Config.retainedMinutes
        }
    }

    private static func isReliable(_ record: SmartAdvertisement.GlucoseRecord) -> Bool {
        record.isValid &&
            record.quality > 0 &&
            (20 ... 600).contains(Int(record.glucose))
    }

    private static func requiresLatestRawValue(latest: Sample, rate: Double?) -> Bool {
        guard let rate else { return true }
        return abs(rate) >= Config.rapidChangeRate ||
            (latest.glucose <= Config.lowSafetyThreshold && rate < 0)
    }

    private static func linearRate(_ samples: [Sample]) -> Double? {
        guard samples.count >= 2 else { return nil }

        let xs = samples.map { Double($0.minutesSinceStart) }
        let ys = samples.map(\.glucose)
        let meanX = xs.reduce(0, +) / Double(xs.count)
        let meanY = ys.reduce(0, +) / Double(ys.count)
        let denominator = xs.reduce(0) { partial, x in
            partial + pow(x - meanX, 2)
        }
        guard denominator > 0 else { return nil }

        let numerator = zip(xs, ys).reduce(0) { partial, pair in
            partial + (pair.0 - meanX) * (pair.1 - meanY)
        }
        return numerator / denominator
    }

    private static func fittedValue(_ samples: [Sample], at minutesSinceStart: UInt16) -> Double? {
        guard let rate = linearRate(samples) else { return nil }

        let xs = samples.map { Double($0.minutesSinceStart) }
        let ys = samples.map(\.glucose)
        let meanX = xs.reduce(0, +) / Double(xs.count)
        let meanY = ys.reduce(0, +) / Double(ys.count)
        return meanY + rate * (Double(minutesSinceStart) - meanX)
    }
}
