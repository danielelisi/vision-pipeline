import Foundation
import Observation

/// Live cluster state shared by both windows: selection, per-endpoint status
/// and metrics (simulated), and an event log of what the user did.
@MainActor
@Observable
final class AppModel {
    static let clusterWindowID = "cluster"

    struct Event: Identifiable {
        let id = UUID()
        let date = Date()
        let message: String
    }

    let topology = ClusterTopology.sample

    var isClusterOpen = false
    var selectedID: String?
    var status: [String: EndpointStatus]
    var metrics: [String: EndpointMetrics]
    private(set) var events: [Event] = []
    /// Bump to rebuild the cluster scene from scratch (resets positions, scale, sway).
    private(set) var layoutGeneration = 0

    private var simulation: Task<Void, Never>?

    init() {
        status = Dictionary(uniqueKeysWithValues: topology.nodes.map { ($0.id, $0.status) })
        metrics = Dictionary(uniqueKeysWithValues: topology.nodes.map { ($0.id, $0.metrics) })
    }

    // MARK: Interactions

    func toggleSelection(_ id: String) {
        selectedID = selectedID == id ? nil : id
        if let selectedID { log("Selected \(selectedID)") }
    }

    func canRestart(_ id: String) -> Bool {
        topology.node(id)?.kind == .pod && status[id] != .terminating && status[id] != .creating
    }

    /// Simulates `kubectl delete pod`: the pod goes down, comes back, and its
    /// restart count increases. Traffic to it stops in the meantime.
    func restart(_ id: String) {
        guard canRestart(id) else { return }
        log("Restarting \(id)")
        status[id] = .terminating
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            status[id] = .creating
            try? await Task.sleep(for: .seconds(1.8))
            status[id] = .running
            if var m = metrics[id] {
                m.restarts += 1
                m.cpuMillicores = 280
                m.memoryMiB = 390
                m.requestsPerSecond = 140
                metrics[id] = m
            }
            log("\(id) is Running")
        }
    }

    func resetLayout() {
        selectedID = nil
        layoutGeneration += 1
        log("Layout reset")
    }

    func log(_ message: String) {
        events.insert(Event(message: message), at: 0)
        if events.count > 30 { events.removeLast(events.count - 30) }
    }

    // MARK: Simulated metrics

    func startSimulation() {
        guard simulation == nil else { return }
        simulation = Task {
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                tick += 1
                jitterMetrics(tick: tick)
            }
        }
    }

    private func jitterMetrics(tick: Int) {
        for node in topology.nodes {
            guard var m = metrics[node.id] else { continue }
            switch status[node.id] {
            case .running:
                if node.kind != .service {
                    m.cpuMillicores = max(10, m.cpuMillicores + Int.random(in: -25...25))
                    m.memoryMiB = max(32, m.memoryMiB + Int.random(in: -6...6))
                }
                m.requestsPerSecond = max(0, m.requestsPerSecond + Int.random(in: -15...15))
            case .crashLoop:
                m.requestsPerSecond = 0
                // A crash-looping container restarts roughly every 10 s.
                if tick % 10 == 0 {
                    m.restarts += 1
                    log("\(node.id) restarted (CrashLoopBackOff)")
                }
            default:
                m.requestsPerSecond = 0
            }
            metrics[node.id] = m
        }
    }
}
