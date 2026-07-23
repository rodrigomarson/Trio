import Foundation

public enum MicroTechChecksums {
    public static func crc8Maxim<C: Collection>(_ bytes: C) -> UInt8 where C.Element == UInt8 {
        var crc: UInt8 = 0

        for byte in bytes {
            crc ^= byte
            for _ in 0 ..< 8 {
                if crc & 0x01 == 0x01 {
                    crc = (crc >> 1) ^ 0x8C
                } else {
                    crc >>= 1
                }
            }
        }

        return crc
    }

    public static func crc16CcittFalse<C: Collection>(_ bytes: C) -> UInt16 where C.Element == UInt8 {
        var crc: UInt16 = 0xFFFF

        for byte in bytes {
            crc ^= UInt16(byte) << 8
            for _ in 0 ..< 8 {
                if crc & 0x8000 == 0x8000 {
                    crc = (crc << 1) ^ 0x1021
                } else {
                    crc <<= 1
                }
            }
        }

        return crc
    }

    static func appendingCrc16(to bytes: [UInt8]) -> [UInt8] {
        let crc = crc16CcittFalse(bytes)
        return bytes + [UInt8(truncatingIfNeeded: crc), UInt8(truncatingIfNeeded: crc >> 8)]
    }

    static func hasValidTrailingCrc16(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 2 else {
            return false
        }

        let payload = bytes.dropLast(2)
        let expected = crc16CcittFalse(payload)
        let actual = UInt16(bytes[bytes.count - 2]) | UInt16(bytes[bytes.count - 1]) << 8
        return actual == expected
    }
}
