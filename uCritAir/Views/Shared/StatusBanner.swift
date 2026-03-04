// ────────────────────────────────────────────────────────────────────────────
// StatusBanner.swift
// uCritAir
// ────────────────────────────────────────────────────────────────────────────
//
// PURPOSE:
//   A reusable status banner component displayed at the top of the Dashboard.
//   It communicates important transient states to the user:
//
//   1. **Reconnecting banner** (orange) — Shown when the BLE connection was
//      lost and the app is automatically attempting to reconnect. Includes
//      a spinner to indicate activity.
//
//   2. **Error banner** (red) — Shown when an error has occurred (e.g., a BLE
//      write failed). Includes a dismiss button (X) so the user can clear it.
//
//   Both banners are conditionally rendered — they only appear when their
//   respective conditions are true. When neither condition is active, this
//   view renders nothing (empty VStack).
//
// SWIFTUI CONCEPTS USED:
//   - @Environment: Reads shared view models for connection state and error messages.
//   - VStack: Stacks the two banners vertically (both can be visible simultaneously).
//   - Conditional rendering: `if` statements inside the view body control
//     whether each banner is rendered. SwiftUI only creates views for the
//     active branches.
//   - ProgressView: A system spinner indicating background activity.
//   - .accessibilityHidden(true): Hides decorative icons from VoiceOver
//     since the text already conveys the meaning.
//   - .accessibilityLabel: Provides a VoiceOver description for the dismiss button.
//
// ────────────────────────────────────────────────────────────────────────────

import SwiftUI

/// A pair of contextual status banners displayed at the top of the Dashboard.
///
/// This view conditionally renders up to two full-width banners:
///
/// 1. **Orange "Reconnecting" banner** — Appears when `bleManager.connectionState`
///    is `.reconnecting`. Shows a spinner and message. Disappears automatically
///    when the connection is restored or lost.
///
/// 2. **Red "Error" banner** — Appears when `deviceVM.error` is non-nil. Shows
///    the error message with a dismiss (X) button. Tapping the X sets
///    `deviceVM.error = nil`, which removes the banner.
///
/// ## Dependencies
/// - `DeviceViewModel`: Provides the `error` string (nil when no error).
/// - `BLEManager`: Provides the `connectionState` for detecting reconnection.
///
/// ## Usage
/// Place at the top of a VStack in any view that needs status feedback:
/// ```swift
/// VStack {
///     StatusBanner()
///     // ... other content
/// }
/// ```
struct StatusBanner: View {

    /// The device view model providing the current error message (if any).
    @Environment(DeviceViewModel.self) private var deviceVM

    /// The BLE manager providing the current connection state.
    @Environment(BLEManager.self) private var bleManager

    /// The view body — a vertical stack of conditionally rendered banners.
    ///
    /// The `VStack(spacing: 0)` ensures that if both banners are visible
    /// simultaneously, they appear flush against each other with no gap.
    var body: some View {
        VStack(spacing: 0) {
            // Orange reconnecting banner — shown during automatic reconnection attempts.
            if bleManager.connectionState == .reconnecting {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                    Text("Reconnecting to device...")
                        .font(.caption)
                        .fontWeight(.medium)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(Color.orange)
                .foregroundStyle(.white)
            }

            // Red error banner — shown when deviceVM.error is non-nil.
            // The user can dismiss it by tapping the X button.
            if let error = deviceVM.error {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .accessibilityHidden(true)  // Decorative — the text conveys the meaning.
                    Text(error)
                        .font(.caption)
                        .lineLimit(2)
                    Spacer()
                    // Dismiss button — sets the error to nil, removing the banner.
                    Button {
                        deviceVM.error = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .accessibilityLabel("Dismiss error")
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.red)
                .foregroundStyle(.white)
            }
        }
    }
}
