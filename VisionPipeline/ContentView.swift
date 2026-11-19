import SwiftUI
import UIKit

/// Main 2D window: legend, gesture cheat sheet, live event log and controls.
struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Vision Pipeline")
                    .font(.extraLargeTitle)
                Text("Test cluster · \(model.topology.nodes.count) endpoints · \(model.topology.connections.count) connections")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .top, spacing: 48) {
                legend("Endpoints", items: Endpoint.Kind.allCases.map { LegendItem(label: $0.label, color: $0.color) })
                legend("Traffic", items: Connection.TrafficProtocol.allCases.map { LegendItem(label: $0.label, color: $0.color) })
                gestures
            }

            eventLog

            HStack(spacing: 16) {
                Button(model.isClusterOpen ? "Hide Cluster" : "Show Cluster",
                       systemImage: model.isClusterOpen ? "cube.transparent" : "cube.transparent.fill") {
                    if model.isClusterOpen {
                        dismissWindow(id: AppModel.clusterWindowID)
                    } else {
                        openWindow(id: AppModel.clusterWindowID)
                    }
                }
                Button("Reset Layout", systemImage: "arrow.counterclockwise") {
                    model.resetLayout()
                }
                .disabled(!model.isClusterOpen)
            }
        }
        .padding(48)
        .frame(width: 900)
        .task {
            model.startSimulation()
            // Open the cluster on launch so it's there straight away.
            if !model.isClusterOpen { openWindow(id: AppModel.clusterWindowID) }
        }
    }

    private var gestures: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Gestures").font(.headline)
            Group {
                Label("Tap: select and inspect", systemImage: "hand.tap")
                Label("Long-press a pod: restart it", systemImage: "hand.point.up.left")
                Label("Drag: move an endpoint", systemImage: "hand.draw")
                Label("Two hands: scale and rotate", systemImage: "arrow.up.left.and.arrow.down.right")
                Label("Grab a datastore: move, turn, resize", systemImage: "hand.raised")
            }
            .font(.callout)
        }
    }

    private var eventLog: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Events").font(.headline)
            if model.events.isEmpty {
                Text("Interact with the cluster to see events here.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.events.prefix(6)) { event in
                    HStack(spacing: 12) {
                        Text(event.date, format: .dateTime.hour().minute().second())
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Text(event.message)
                    }
                    .font(.callout)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
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
