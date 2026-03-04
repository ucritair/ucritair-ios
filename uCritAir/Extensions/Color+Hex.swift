import SwiftUI

// MARK: - File Overview
// ============================================================================
// Color+Hex.swift
// uCritAir
//
// PURPOSE:
//   Extends SwiftUI's `Color` type with:
//   1. A convenience initializer that creates a Color from a CSS-style hex
//      string (e.g., "#22c55e" or "22c55e").
//   2. A set of static color constants for the air quality color palette,
//      matching the web app's Tailwind CSS colors exactly.
//
// WHY HEX COLORS?
//   Web developers commonly specify colors as 6-digit hexadecimal strings
//   (e.g., "#FF0000" for red). Each pair of hex digits represents one color
//   channel (Red, Green, Blue) with a value from 0x00 (0) to 0xFF (255).
//
//   Since this app is ported from a web app that uses Tailwind CSS color
//   classes, using the same hex values ensures pixel-perfect color matching
//   across platforms.
//
// HEX COLOR FORMAT:
//   A 6-digit hex color string encodes 3 bytes (24 bits) of color data:
//
//     "#22c55e"
//      ^^       Red   = 0x22 = 34  (out of 255)
//        ^^     Green = 0xC5 = 197 (out of 255)
//          ^^   Blue  = 0x5E = 94  (out of 255)
//
//   The optional "#" prefix is stripped before parsing.
//   SwiftUI expects color components as Doubles in the range 0.0 to 1.0,
//   so each byte value is divided by 255.0.
// ============================================================================

extension Color {
    /// Create a `Color` from a hexadecimal color string.
    ///
    /// Accepts both `"#22c55e"` (with hash prefix) and `"22c55e"` (without).
    /// Only 6-digit RGB hex strings are supported (no alpha channel, no 3-digit shorthand).
    ///
    /// **How the parsing works, step by step:**
    ///
    /// 1. Strip the `#` prefix if present using `trimmingCharacters`.
    /// 2. Use `Scanner.scanHexInt64` to parse the 6 hex digits into a single
    ///    `UInt64` integer. For example, `"22c55e"` becomes `0x22C55E` = `2,278,750`.
    /// 3. Extract each color channel using bitwise right-shift (`>>`) and masking (`& 0xFF`):
    ///    - **Red**:   bits 16-23 -> `(rgb >> 16) & 0xFF`
    ///    - **Green**: bits 8-15  -> `(rgb >> 8) & 0xFF`
    ///    - **Blue**:  bits 0-7   -> `rgb & 0xFF`
    /// 4. Divide each channel by 255.0 to convert from the integer range [0, 255]
    ///    to the `Double` range [0.0, 1.0] that SwiftUI expects.
    ///
    /// **Example:**
    /// ```swift
    /// let green = Color(hex: "#22c55e")
    /// // Red   = 0x22 / 255 = 0.133
    /// // Green = 0xC5 / 255 = 0.773
    /// // Blue  = 0x5E / 255 = 0.369
    /// ```
    ///
    /// - Parameter hex: A 6-digit hexadecimal color string, with or without a `#` prefix.
    init(hex: String) {
        // Strip the leading "#" if present
        let hex = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        // Parse the hex string into a single 64-bit integer
        var rgb: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&rgb)

        // Extract individual color channels using bitwise operations:
        // The hex value 0xRRGGBB packs red in bits 16-23, green in 8-15, blue in 0-7
        let r = Double((rgb >> 16) & 0xFF) / 255.0  // Red channel
        let g = Double((rgb >> 8) & 0xFF) / 255.0   // Green channel
        let b = Double(rgb & 0xFF) / 255.0           // Blue channel

        self.init(red: r, green: g, blue: b)
    }

    // MARK: - Air Quality Color Palette
    //
    // These four colors form a traffic-light-style palette for air quality display.
    // They are used by `AQIScoring.goodnessColor(_:)` and `AQIScoring.sensorStatus(_:)`
    // to color-code sensor readings throughout the app.
    //
    // The hex values match Tailwind CSS's color palette from the web app:
    //   Good = green-500  (#22c55e)
    //   Fair = yellow-500 (#eab308)
    //   Poor = orange-500 (#f97316)
    //   Bad  = red-500    (#ef4444)

    /// Air quality color for **"Good"** readings (green).
    ///
    /// Hex: `#22c55e` -- Tailwind CSS `green-500`.
    /// Used when air quality goodness >= 80% or individual sensor score <= 1.
    static let aqGood = Color(hex: "#22c55e")

    /// Air quality color for **"Fair"** readings (yellow).
    ///
    /// Hex: `#eab308` -- Tailwind CSS `yellow-500`.
    /// Used when air quality goodness is 60-79% or individual sensor score is 1-2.
    static let aqFair = Color(hex: "#eab308")

    /// Air quality color for **"Poor"** readings (orange).
    ///
    /// Hex: `#f97316` -- Tailwind CSS `orange-500`.
    /// Used when air quality goodness is 40-59% or individual sensor score is 2-3.
    static let aqPoor = Color(hex: "#f97316")

    /// Air quality color for **"Bad"** readings (red).
    ///
    /// Hex: `#ef4444` -- Tailwind CSS `red-500`.
    /// Used when air quality goodness < 40% or individual sensor score > 3.
    static let aqBad = Color(hex: "#ef4444")
}
