import SwiftUI

/// The separate experiences in this app. Each owns its own model, scenes and gestures.
enum Experience: String, CaseIterable, Identifiable {
    case cluster, trail

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cluster: "Cluster Network"
        case .trail: "Trail Table"
        }
    }

    var subtitle: String {
        switch self {
        case .cluster: "An animated Kubernetes test cluster in a volume. Tap, drag, restart pods, grab datastores."
        case .trail: "A mountain diorama in your room. Plan a hiking route with your hands."
        }
    }

    var systemImage: String {
        switch self {
        case .cluster: "point.3.connected.trianglepath.dotted"
        case .trail: "mountain.2"
        }
    }
}

/// Main window: pick an experience at launch, and get back to the picker from either one.
struct RootView: View {
    @State private var experience: Experience?
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    var body: some View {
        switch experience {
        case nil:
            LauncherView { experience = $0 }
        case .cluster:
            ContentView()
                .ornament(attachmentAnchor: .scene(.top), contentAlignment: .bottom) { backButton }
        case .trail:
            TrailPanel()
                .frame(width: 480, height: 760)
                .ornament(attachmentAnchor: .scene(.top), contentAlignment: .bottom) { backButton }
        }
    }

    private var backButton: some View {
        Button("All experiences", systemImage: "chevron.left") {
            Task {
                // Close whatever the current experience opened, so the two never overlap.
                dismissWindow(id: AppModel.clusterWindowID)
                await dismissImmersiveSpace()
                experience = nil
            }
        }
        .padding(12)
        .glassBackgroundEffect()
    }
}

private struct LauncherView: View {
    let choose: (Experience) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Vision Pipeline").font(.extraLargeTitle)
                Text("Choose an experience").font(.title3).foregroundStyle(.secondary)
            }

            HStack(spacing: 24) {
                ForEach(Experience.allCases) { experience in
                    Button {
                        choose(experience)
                    } label: {
                        VStack(alignment: .leading, spacing: 14) {
                            Image(systemName: experience.systemImage)
                                .font(.system(size: 44))
                            Text(experience.title).font(.title2.weight(.semibold))
                            Text(experience.subtitle)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .padding(24)
                        .frame(width: 320, height: 240, alignment: .topLeading)
                    }
                    .buttonStyle(.plain)
                    .background(.regularMaterial, in: .rect(cornerRadius: 28))
                    .hoverEffect()
                }
            }
        }
        .padding(48)
    }
}
