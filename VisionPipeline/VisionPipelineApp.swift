import SwiftUI

@main
struct VisionPipelineApp: App {
    @State private var model = AppModel()
    @State private var trailModel = TrailModel()
    @State private var trailImmersion: ImmersionStyle = .mixed

    init() {
        NetworkAnimation.register()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(trailModel)
        }
        .windowResizability(.contentSize)

        // Cluster Network
        WindowGroup(id: AppModel.clusterWindowID) {
            ClusterVolumeView()
                .environment(model)
        }
        .windowStyle(.volumetric)
        .defaultSize(width: 1.0, height: 0.6, depth: 0.5, in: .meters)

        // Trail Table
        ImmersiveSpace(id: TrailModel.immersiveSpaceID) {
            TableView()
                .environment(trailModel)
        }
        .immersionStyle(selection: $trailImmersion, in: .mixed)
    }
}
