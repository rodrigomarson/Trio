import Foundation

extension Array where Element == UInt8 {
    init(hexadecimalString: String) {
        precondition(hexadecimalString.count.isMultiple(of: 2))
        self = stride(from: 0, to: hexadecimalString.count, by: 2).map { offset in
            let start = hexadecimalString.index(hexadecimalString.startIndex, offsetBy: offset)
            let end = hexadecimalString.index(start, offsetBy: 2)
            return UInt8(hexadecimalString[start ..< end], radix: 16)!
        }
    }
}
