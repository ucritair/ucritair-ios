import SwiftUI

extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var rgb: UInt64 = 0
        guard cleaned.count == 6, Scanner(string: cleaned).scanHexInt64(&rgb) else {
            assertionFailure("Invalid hex color: \(hex)")
            self.init(red: 0, green: 0, blue: 0)
            return
        }

        let r = Double((rgb >> 16) & 0xFF) / 255.0
        let g = Double((rgb >> 8) & 0xFF) / 255.0
        let b = Double(rgb & 0xFF) / 255.0

        self.init(red: r, green: g, blue: b)
    }

    static let aqGood = Color(hex: "#22c55e")

    static let aqFair = Color(hex: "#eab308")

    static let aqPoor = Color(hex: "#f97316")

    static let aqBad = Color(hex: "#ef4444")
}
