import SwiftUI
import UIKit

/// Main 2D window: what the test cluster contains, and a button to open it.
struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    private let topology = ClusterTopology.sample

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Vision Pipeline")
                    .font(.extraLargeTitle)
                Text("Test cluster · \(topology.nodes.count) endpoints · \(topology.connections.count) connections")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .top, spacing: 48) {
                legend("Endpoints", items: Endpoint.Kind.allCases.map { LegendItem(label: $0.label, color: $0.color) })
                legend("Traffic", items: Connection.TrafficProtocol.allCases.map { LegendItem(label: $0.label, color: $0.color) })
            }

            Button(model.isClusterOpen ? "Hide Cluster" : "Show Cluster",
                   systemImage: model.isClusterOpen ? "cube.transparent" : "cube.transparent.fill") {
                if model.isClusterOpen {
                    dismissWindow(id: AppModel.clusterWindowID)
                } else {
                    openWindow(id: AppModel.clusterWindowID)
                }
            }
        }
        .padding(48)
        .task {
            // Open the cluster on launch so it's there straight away.
            if !model.isClusterOpen { openWindow(id: AppModel.clusterWindowID) }
        }
    }

    private struct LegendItem: Identifiable {
        let label: String
        let color: UIColor
        var id: String { label }
    }

    private func legend(_ title: String, items: [LegendItem]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            ForEach(items) { item in
                HStack(spacing: 10) {
                    Circle()
                        .fill(Color(uiColor: item.color))
                        .frame(width: 14, height: 14)
                    Text(item.label)
                }
            }
        }
    }
}
