#if DEBUG
import SwiftUI

struct AccessibilityPreviews: PreviewProvider {
    static var previews: some View {
        Group {
            PreviewAppHarness(scenario: .uiConnected) {
                NavigationStack {
                    DashboardView(selectedTab: .constant(0))
                }
                .environment(\.dynamicTypeSize, .large)
            }
            .previewDisplayName("Dashboard Large iPhone")
            .previewDevice("iPhone 16")

            PreviewAppHarness(scenario: .uiConnected) {
                NavigationStack {
                    DashboardView(selectedTab: .constant(0))
                }
                .environment(\.dynamicTypeSize, .accessibility3)
            }
            .previewDisplayName("Dashboard Accessibility3 iPad")
            .previewDevice("iPad Pro (11-inch) (M4)")

            PreviewAppHarness(scenario: .uiConnected) {
                NavigationStack {
                    HistoryView()
                }
                .environment(\.dynamicTypeSize, .accessibility3)
            }
            .previewDisplayName("History Accessibility3 iPhone")
            .previewDevice("iPhone 16")

            PreviewAppHarness(scenario: .uiConnected) {
                NavigationStack {
                    HistoryView()
                }
                .environment(\.dynamicTypeSize, .accessibility5)
            }
            .previewDisplayName("History Accessibility5 iPad")
            .previewDevice("iPad Pro (11-inch) (M4)")

            PreviewAppHarness(scenario: .uiConnected) {
                NavigationStack {
                    DeviceListView(selectedTab: .constant(2))
                }
                .environment(\.dynamicTypeSize, .accessibility5)
            }
            .previewDisplayName("Devices Accessibility5 iPhone")
            .previewDevice("iPhone 16")

            PreviewAppHarness(scenario: .uiConnected) {
                NavigationStack {
                    DeviceView()
                }
                .environment(\.dynamicTypeSize, .large)
            }
            .previewDisplayName("Device Settings Large iPad")
            .previewDevice("iPad Pro (11-inch) (M4)")
        }
    }
}
#endif
