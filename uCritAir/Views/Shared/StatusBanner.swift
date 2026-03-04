import SwiftUI

struct StatusBanner: View {

    @Environment(DeviceViewModel.self) private var deviceVM

    @Environment(BLEManager.self) private var bleManager

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
