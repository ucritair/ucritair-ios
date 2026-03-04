import SwiftUI

struct AboutView: View {

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    Image("AppIcon")
                        .resizable()
                        .frame(width: 60, height: 60)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("uCritAir")
                            .font(.title3.weight(.semibold))
                        Text("Version \(appVersion) (\(buildNumber))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section {
                if let url = URL(string: "https://ucritter.com/privacy") {
                    Link(destination: url) {
                        Label("Privacy Policy", systemImage: "hand.raised")
                    }
                }
                if let url = URL(string: "https://ucritter.com") {
                    Link(destination: url) {
                        Label("Website", systemImage: "globe")
                    }
                }
            }

            Section {
                HStack {
                    Spacer()
                    Text("Made by Osluv")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }
}
