import SwiftUI

@Observable
final class AppModel {
    static let clusterWindowID = "cluster"
    var isClusterOpen = false
}

@main
struct VisionPipelineApp: App {
    @State private var model = AppModel()

    init() {
        NetworkAnimation.register()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
        }
        .windowResizability(.contentSize)

        WindowGroup(id: AppModel.clusterWindowID) {
            ClusterVolumeView()
                .environment(model)
        }
        .windowStyle(.volumetric)
        .defaultSize(width: 1.0, height: 0.6, depth: 0.5, in: .meters)
    }
}
