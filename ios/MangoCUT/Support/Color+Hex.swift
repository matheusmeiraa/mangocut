import SwiftUI

extension Color {
    /// `#RRGGBB`
    init(hex: String) {
        let value = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0xFFFFFF
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    static let mango = Color(hex: "#FF8A00")
}

extension Double {
    /// Número no formato do idioma do aparelho ("0,5" em português), com até `digits` casas.
    func decimalText(_ digits: Int = 2) -> String {
        formatted(.number.precision(.fractionLength(0...digits)))
    }
}
