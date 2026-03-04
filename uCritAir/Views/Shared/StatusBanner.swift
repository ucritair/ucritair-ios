import SwiftUI

/// Contextual status banners displayed at the top of the Dashboard.
///
/// Shows an orange "Reconnecting" banner with a spinner when BLE is reconnecting,
/// and a red dismissible error banner when ``DeviceViewModel/error`` is non-nil.
/// Ported from the web app's `Layout.tsx` error/reconnecting banners.
struct StatusBanner: View {
    /// Device view model providing the current error message.
    @Environment(DeviceViewModel.self) private var deviceVM

    /// BLE manager providing the current connection state.
    @Environment(BLEManager.self) private var bleManager

    /// Vertically stacks the reconnecting and error banners, showing each conditionally.
    var body: some View {
        VStack(spacing: 0) {
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

            if let error = deviceVM.error {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .accessibilityHidden(true)
                    Text(error)
                        .font(.caption)
                        .lineLimit(2)
                    Spacer()
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
