import SwiftUI

extension Color {
    /// Create a Color from a hex string like "#22c55e" or "22c55e".
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var rgb: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&rgb)

        let r = Double((rgb >> 16) & 0xFF) / 255.0
        let g = Double((rgb >> 8) & 0xFF) / 255.0
        let b = Double(rgb & 0xFF) / 255.0

        self.init(red: r, green: g, blue: b)
    }

    // MARK: - Air Quality Color Palette

    /// Air quality color for "Good" readings (green, #22c55e).
    /// Matches the web app's Tailwind `green-500` color.
    static let aqGood = Color(hex: "#22c55e")

    /// Air quality color for "Fair" readings (yellow, #eab308).
    /// Matches the web app's Tailwind `yellow-500` color.
    static let aqFair = Color(hex: "#eab308")

    /// Air quality color for "Poor" readings (orange, #f97316).
    /// Matches the web app's Tailwind `orange-500` color.
    static let aqPoor = Color(hex: "#f97316")

    /// Air quality color for "Bad" readings (red, #ef4444).
    /// Matches the web app's Tailwind `red-500` color.
    static let aqBad = Color(hex: "#ef4444")
}
