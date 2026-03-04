import SwiftUI

/// Placeholder view for Phase 3 device settings editor.
///
/// Will eventually provide UI for editing device configuration parameters
/// (sensor wake period, screen brightness, persist flags, etc.).
struct DeviceView: View {
    /// Displays a centered unavailable-content message indicating the feature is coming in Phase 3.
    var body: some View {
        ContentUnavailableView(
            "Device Settings",
            systemImage: "gearshape",
            description: Text("Device configuration editor. Coming in Phase 3.")
        )
    }
}
