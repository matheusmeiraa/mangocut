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
    static let capcutDark = Color(hex: "#0E0E12")
    static let capcutBar = Color(hex: "#15151C")
    static let capcutCard = Color(hex: "#1D1D26")
    static let capcutCardHover = Color(hex: "#262632")
    static let capcutBorder = Color(hex: "#2A2A36")
    static let capcutCyan = Color(hex: "#00F0FF")
    static let capcutYellow = Color(hex: "#FFD60A")
    static let capcutPurple = Color(hex: "#AF52DE")
}

extension Double {
    /// Número no formato do idioma do aparelho ("0,5" em português), com até `digits` casas.
    func decimalText(_ digits: Int = 2) -> String {
        formatted(.number.precision(.fractionLength(0...digits)))
    }
}
