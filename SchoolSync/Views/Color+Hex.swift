import SwiftUI

extension Color {
    init(hex: String) {
        var cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned.removeAll { $0 == "#" }
        guard cleaned.count == 6, let value = UInt32(cleaned, radix: 16) else {
            self = .blue
            return
        }
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        self = Color(red: r, green: g, blue: b)
    }
}
