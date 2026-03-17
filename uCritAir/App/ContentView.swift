import SwiftUI

struct ContentView: View {

    private enum AppTab: Int, CaseIterable, Identifiable {
        case dashboard = 0
        case data = 1
        case devices = 2
        case advanced = 3

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .dashboard:
                return "Dashboard"
            case .data:
                return "Data"
            case .devices:
                return "Devices"
            case .advanced:
                return "Advanced"
            }
        }

        var systemImage: String {
            switch self {
            case .dashboard:
                return "square.grid.2x2"
            case .data:
                return "chart.xyaxis.line"
            case .devices:
                return "rectangle.stack"
            case .advanced:
                return "gearshape.2"
            }
        }
    }

    @Environment(DeviceViewModel.self) private var deviceVM
    @Environment(BLEManager.self) private var bleManager
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.modelContext) private var modelContext

    @State private var selectedTab = AppTab.dashboard.rawValue
    @State private var hasCheckedInitialDevices = false
    @State private var hasRegisteredBluetoothReadyCallback = false

    private var currentTab: AppTab {
        AppTab(rawValue: selectedTab) ?? .dashboard
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            dashboardTab
                .tabItem {
                    Label(AppTab.dashboard.title, systemImage: AppTab.dashboard.systemImage)
                }
                .tag(AppTab.dashboard.rawValue)

            historyTab
                .tabItem {
                    Label(AppTab.data.title, systemImage: AppTab.data.systemImage)
                }
                .tag(AppTab.data.rawValue)

            devicesTab
                .tabItem {
                    Label(AppTab.devices.title, systemImage: AppTab.devices.systemImage)
                }
                .tag(AppTab.devices.rawValue)

            advancedTab
                .tabItem {
                    Label(AppTab.advanced.title, systemImage: AppTab.advanced.systemImage)
                }
                .tag(AppTab.advanced.rawValue)
        }
        .toolbar(.hidden, for: .tabBar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            customTabBar
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .onAppear {
            deviceVM.configureStorage(modelContext: modelContext)

#if DEBUG
            if let debugTab = DebugAppScenario.initialTabSelection {
                selectedTab = debugTab
            }
#endif

            if !hasCheckedInitialDevices {
                hasCheckedInitialDevices = true
                if deviceVM.knownDevices.isEmpty {
                    selectedTab = AppTab.devices.rawValue
                }
            }

            if !hasRegisteredBluetoothReadyCallback {
                hasRegisteredBluetoothReadyCallback = true
                bleManager.whenBluetoothReady {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        deviceVM.autoConnectToLastDevice()
                    }
                }
            }
        }
    }

    private var customTabBar: some View {
        HStack(spacing: 8) {
            ForEach(AppTab.allCases) { tab in
                tabButton(for: tab)
            }
        }
        .padding(.horizontal, AppChrome.customTabBarInnerHorizontalPadding)
        .padding(.vertical, AppChrome.customTabBarInnerVerticalPadding)
        .background(
            .ultraThinMaterial,
            in: RoundedRectangle(cornerRadius: AppChrome.customTabBarCornerRadius, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: AppChrome.customTabBarCornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08))
        }
        .padding(.horizontal, AppChrome.customTabBarOuterHorizontalPadding)
        .padding(.top, AppChrome.customTabBarOuterTopPadding)
        .padding(.bottom, AppChrome.customTabBarOuterBottomPadding)
    }

    private func tabButton(for tab: AppTab) -> some View {
        let isSelected = currentTab == tab

        return Button {
            selectedTab = tab.rawValue
        } label: {
            VStack(spacing: 4) {
                Image(systemName: tab.systemImage)
                    .font(.system(size: 20, weight: .medium))
                    .symbolRenderingMode(.monochrome)

                Text(tab.title)
                    .font(.caption.weight(isSelected ? .semibold : .regular))
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
            .frame(maxWidth: .infinity)
            .frame(height: AppChrome.customTabBarButtonHeight)
            .background(
                isSelected ? Color(.secondarySystemFill) : .clear,
                in: RoundedRectangle(cornerRadius: AppChrome.customTabBarSelectedCornerRadius, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .minimumAccessibleTapTarget()
        .accessibilityIdentifier(accessibilityIdentifier(for: tab))
    }

    private func accessibilityIdentifier(for tab: AppTab) -> String {
        switch tab {
        case .dashboard:
            return "tabDashboard"
        case .data:
            return "tabData"
        case .devices:
            return "tabDevices"
        case .advanced:
            return "tabAdvanced"
        }
    }

    private var dashboardTab: some View {
        NavigationStack {
            DashboardView(selectedTab: $selectedTab)
                .navigationTitle("uCritAir")
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        ConnectButton()
                    }
                    if !dynamicTypeSize.usesAccessibilityLayout {
                        ToolbarItem(placement: .topBarTrailing) {
                            connectedDeviceInfo
                        }
                    }
                }
        }
        .toolbar(.hidden, for: .tabBar)
    }

    private var historyTab: some View {
        NavigationStack {
            HistoryView()
        }
        .toolbar(.hidden, for: .tabBar)
    }

    private var devicesTab: some View {
        NavigationStack {
            DeviceListView(selectedTab: $selectedTab)
        }
        .toolbar(.hidden, for: .tabBar)
    }

    private var advancedTab: some View {
        NavigationStack {
            AdvancedView()
        }
        .toolbar(.hidden, for: .tabBar)
    }

    @ViewBuilder
    private var connectedDeviceInfo: some View {
        if bleManager.connectionState == .connected {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    if let petName = deviceVM.petName, !petName.isEmpty {
                        Text(petName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.blue)
                            .lineLimit(1)
                    }
                    if let deviceName = deviceVM.deviceName, !deviceName.isEmpty {
                        Text(deviceName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color(.systemGray5))
                            .clipShape(Capsule())
                    }
                }

                if let petName = deviceVM.petName, !petName.isEmpty {
                    Text(petName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.blue)
                        .lineLimit(1)
                }
            }
        }
    }
}
