import SwiftUI

struct StatusBanner: View {

    @Environment(DeviceViewModel.self) private var deviceVM

    @Environment(BLEManager.self) private var bleManager

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(spacing: 0) {
            if bleManager.connectionState == .reconnecting {
                AdaptiveStack(
                    vertical: dynamicTypeSize.usesAccessibilityLayout,
                    verticalAlignment: .leading,
                    horizontalAlignment: .center,
                    spacing: 8
                ) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                    Text("Reconnecting to device...")
                        .font(.caption)
                        .fontWeight(.medium)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
                .frame(minHeight: 44)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.orange)
                .foregroundStyle(.white)
            }

            if let error = deviceVM.error {
                Group {
                    if dynamicTypeSize.usesAccessibilityLayout {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .accessibilityHidden(true)
                                Text(error)
                                    .font(.caption)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            Button("Dismiss Error") {
                                deviceVM.error = nil
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.white.opacity(0.2))
                            .foregroundStyle(.white)
                            .minimumAccessibleTapTarget()
                        }
                    } else {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .accessibilityHidden(true)
                            Text(error)
                                .font(.caption)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            Button {
                                deviceVM.error = nil
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .accessibilityLabel("Dismiss error")
                            .minimumAccessibleTapTarget()
                        }
                    }
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
