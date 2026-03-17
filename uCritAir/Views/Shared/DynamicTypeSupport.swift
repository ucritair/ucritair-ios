import SwiftUI

extension DynamicTypeSize {
    var usesAccessibilityLayout: Bool {
        isAccessibilitySize
    }
}

extension View {
    func minimumAccessibleTapTarget() -> some View {
        frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
    }
}

struct AdaptiveStack<Content: View>: View {

    let vertical: Bool

    var verticalAlignment: HorizontalAlignment = .leading

    var horizontalAlignment: VerticalAlignment = .center

    var spacing: CGFloat? = nil

    @ViewBuilder var content: () -> Content

    var body: some View {
        let layout = vertical
            ? AnyLayout(VStackLayout(alignment: verticalAlignment, spacing: spacing))
            : AnyLayout(HStackLayout(alignment: horizontalAlignment, spacing: spacing))

        layout {
            content()
        }
    }
}

struct ConnectedDeviceHeader: View {

    @Environment(DeviceViewModel.self) private var deviceVM

    @Environment(BLEManager.self) private var bleManager

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if bleManager.connectionState == .connected {
            VStack(alignment: .leading, spacing: 10) {
                Text("Connected Device")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                AdaptiveStack(
                    vertical: dynamicTypeSize.usesAccessibilityLayout,
                    verticalAlignment: .leading,
                    horizontalAlignment: .center,
                    spacing: 8
                ) {
                    Text(deviceVM.petName?.nonEmpty ?? "Unnamed Device")
                        .font(.headline)
                        .foregroundStyle(.primary)

                    if let deviceName = deviceVM.deviceName?.nonEmpty {
                        Text(deviceName)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color(.systemGray5), in: Capsule())
                    }
                }

                if let room = deviceVM.activeProfile?.roomLabel?.nonEmpty {
                    Text(room)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityIdentifier("connectedDeviceHeader")
        }
    }

    private var accessibilityLabel: String {
        var parts = ["Connected device"]

        if let petName = deviceVM.petName?.nonEmpty {
            parts.append(petName)
        }

        if let deviceName = deviceVM.deviceName?.nonEmpty {
            parts.append(deviceName)
        }

        if let room = deviceVM.activeProfile?.roomLabel?.nonEmpty {
            parts.append(room)
        }

        return parts.joined(separator: ", ")
    }
}

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
