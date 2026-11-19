import SwiftUI

/// Floating card next to the selected endpoint with its live details.
struct InspectorCard: View {
    let model: AppModel

    var body: some View {
        if let id = model.selectedID, let node = model.topology.node(id) {
            let status = model.status[id] ?? node.status
            let metrics = model.metrics[id] ?? node.metrics

            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(id).font(.headline).monospaced()
                    Text("\(node.kind.label) · \(node.namespace)")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(node.workload)
                        .font(.caption).foregroundStyle(.secondary)
                }

                HStack(spacing: 6) {
                    Circle()
                        .fill(Color(uiColor: status.tint ?? .systemGreen))
                        .frame(width: 10, height: 10)
                    Text(status.rawValue).font(.callout.weight(.semibold))
                }

                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    if node.kind != .service {
                        row("CPU", "\(metrics.cpuMillicores)m")
                        row("Memory", "\(metrics.memoryMiB) Mi")
                    }
                    row("Requests", "\(metrics.requestsPerSecond)/s")
                    if node.kind == .pod {
                        row("Restarts", "\(metrics.restarts)")
                    }
                }
                .font(.callout)
                .monospacedDigit()

                HStack {
                    if node.kind == .pod {
                        Button("Restart", systemImage: "arrow.clockwise") { model.restart(id) }
                            .disabled(!model.canRestart(id))
                    }
                    Button("Close", systemImage: "xmark") { model.selectedID = nil }
                        .labelStyle(.iconOnly)
                }
                .controlSize(.small)
            }
            .padding(16)
            .frame(width: 240, alignment: .leading)
            .glassBackgroundEffect()
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value)
        }
    }
}
