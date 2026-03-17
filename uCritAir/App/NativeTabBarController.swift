import SwiftUI
import SwiftData
import UIKit

struct NativeTabBarController: UIViewControllerRepresentable {

    struct Tab: Identifiable {
        let id: Int
        let title: String
        let systemImage: String
        let accessibilityIdentifier: String
        let rootView: AnyView
    }

    @Binding var selectedTab: Int

    let tabs: [Tab]
    let bleManager: BLEManager
    let deviceViewModel: DeviceViewModel
    let sensorViewModel: SensorViewModel
    let historyViewModel: HistoryViewModel
    let modelContext: ModelContext

    func makeCoordinator() -> Coordinator {
        Coordinator(selectedTab: $selectedTab)
    }

    func makeUIViewController(context: Context) -> StableTabBarController {
        let controller = StableTabBarController()
        controller.delegate = context.coordinator
        controller.view.backgroundColor = .systemBackground
        controller.setViewControllers(makeHostingControllers(), animated: false)
        controller.selectedIndex = clampedSelection
        return controller
    }

    func updateUIViewController(_ controller: StableTabBarController, context: Context) {
        context.coordinator.selectedTab = $selectedTab

        let updatedControllers = makeHostingControllers()
        if controller.viewControllers?.count != updatedControllers.count {
            controller.setViewControllers(updatedControllers, animated: false)
        } else if let existingControllers = controller.viewControllers as? [UIHostingController<AnyView>] {
            for (index, hostingController) in existingControllers.enumerated() where index < updatedControllers.count {
                hostingController.rootView = wrappedRootView(for: tabs[index])
            }
        } else {
            controller.setViewControllers(updatedControllers, animated: false)
        }

        if controller.selectedIndex != clampedSelection {
            controller.setSelectedIndexWithoutAnimation(clampedSelection)
        }
    }

    private var clampedSelection: Int {
        tabs.indices.contains(selectedTab) ? selectedTab : 0
    }

    private func makeHostingControllers() -> [UIViewController] {
        tabs.map { tab in
            let controller = UIHostingController(rootView: wrappedRootView(for: tab))
            controller.view.backgroundColor = .systemBackground
            controller.tabBarItem = UITabBarItem(
                title: tab.title,
                image: UIImage(systemName: tab.systemImage),
                tag: tab.id
            )
            controller.tabBarItem.accessibilityIdentifier = tab.accessibilityIdentifier
            return controller
        }
    }

    private func wrappedRootView(for tab: Tab) -> AnyView {
        AnyView(
            tab.rootView
                .environment(bleManager)
                .environment(deviceViewModel)
                .environment(sensorViewModel)
                .environment(historyViewModel)
                .environment(\.modelContext, modelContext)
        )
    }
}

final class StableTabBarController: UITabBarController {

    override func viewDidLoad() {
        super.viewDidLoad()
        configureAppearance()
    }

    func setSelectedIndexWithoutAnimation(_ index: Int) {
        UIView.performWithoutAnimation {
            selectedIndex = index
            view.layoutIfNeeded()
        }
    }

    private func configureAppearance() {
        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor.secondarySystemBackground
        appearance.shadowColor = UIColor.separator.withAlphaComponent(0.3)

        configure(itemAppearance: appearance.stackedLayoutAppearance)
        configure(itemAppearance: appearance.inlineLayoutAppearance)
        configure(itemAppearance: appearance.compactInlineLayoutAppearance)

        tabBar.standardAppearance = appearance
        tabBar.scrollEdgeAppearance = appearance
        tabBar.selectionIndicatorImage = UIImage()
        tabBar.itemPositioning = .fill
        tabBar.isTranslucent = false
    }

    private func configure(itemAppearance: UITabBarItemAppearance) {
        let normalColor = UIColor.secondaryLabel
        let selectedColor = UIColor.systemBlue

        itemAppearance.normal.iconColor = normalColor
        itemAppearance.normal.titleTextAttributes = [.foregroundColor: normalColor]
        itemAppearance.selected.iconColor = selectedColor
        itemAppearance.selected.titleTextAttributes = [.foregroundColor: selectedColor]
    }
}

extension NativeTabBarController {
    final class Coordinator: NSObject, UITabBarControllerDelegate {
        var selectedTab: Binding<Int>

        init(selectedTab: Binding<Int>) {
            self.selectedTab = selectedTab
        }

        func tabBarController(_ tabBarController: UITabBarController, didSelect viewController: UIViewController) {
            selectedTab.wrappedValue = tabBarController.selectedIndex
        }

        func tabBarController(
            _ tabBarController: UITabBarController,
            animationControllerForTransitionFrom fromVC: UIViewController,
            to toVC: UIViewController
        ) -> (any UIViewControllerAnimatedTransitioning)? {
            NoAnimationTabTransitionAnimator()
        }
    }
}

private final class NoAnimationTabTransitionAnimator: NSObject, UIViewControllerAnimatedTransitioning {
    func transitionDuration(using transitionContext: (any UIViewControllerContextTransitioning)?) -> TimeInterval {
        0
    }

    func animateTransition(using transitionContext: any UIViewControllerContextTransitioning) {
        let containerView = transitionContext.containerView
        guard
            let toView = transitionContext.view(forKey: .to),
            let toController = transitionContext.viewController(forKey: .to)
        else {
            transitionContext.completeTransition(!transitionContext.transitionWasCancelled)
            return
        }

        if toView.superview !== containerView {
            containerView.addSubview(toView)
        }
        toView.frame = transitionContext.finalFrame(for: toController)
        transitionContext.completeTransition(!transitionContext.transitionWasCancelled)
    }
}
