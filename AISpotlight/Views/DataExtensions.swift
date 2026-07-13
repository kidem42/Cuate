import Foundation

extension Data {
    /// Adds string data to existing Data
    mutating func appendString(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }
}