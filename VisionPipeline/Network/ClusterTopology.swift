import UIKit

/// Kubernetes-flavoured test data: ingress → services → pods → datastores.
/// Positions are in metres, centred on the volume's origin. Status and metrics
/// here are the starting values; `AppModel` owns the live, changing copies.
struct ClusterTopology {
    var nodes: [Endpoint]
    var connections: [Connection]

    func node(_ id: String) -> Endpoint? { nodes.first { $0.id == id } }

    /// IDs of endpoints directly connected to `id`, in either direction.
    func neighbours(of id: String) -> Set<String> {
        var result = Set<String>()
        for c in connections {
            if c.from == id { result.insert(c.to) }
            if c.to == id { result.insert(c.from) }
        }
        return result
    }
}

enum EndpointStatus: String {
    case running = "Running"
    case pending = "Pending"
    case crashLoop = "CrashLoopBackOff"
    case terminating = "Terminating"
    case creating = "ContainerCreating"

    /// Whether the endpoint accepts traffic.
    var isServing: Bool { self == .running }

    /// Override colour for unhealthy states; `nil` keeps the kind's colour.
    var tint: UIColor? {
        switch self {
        case .running: nil
        case .crashLoop: UIColor(red: 1.00, green: 0.25, blue: 0.25, alpha: 1)
        case .pending, .terminating, .creating: UIColor(red: 1.00, green: 0.70, blue: 0.20, alpha: 1)
        }
    }
}

struct EndpointMetrics {
    var cpuMillicores: Int
    var memoryMiB: Int
    var requestsPerSecond: Int
    var restarts: Int
}

struct Endpoint: Identifiable {
    enum Kind: CaseIterable {
        case ingress, service, pod, datastore

        var label: String {
            switch self {
            case .ingress: "Ingress"
            case .service: "Service"
            case .pod: "Pod"
            case .datastore: "Datastore"
            }
        }

        var color: UIColor {
            switch self {
            case .ingress: UIColor(red: 0.98, green: 0.80, blue: 0.20, alpha: 1)
            case .service: UIColor(red: 0.33, green: 0.55, blue: 0.98, alpha: 1)
            case .pod: UIColor(red: 0.55, green: 0.85, blue: 0.95, alpha: 1)
            case .datastore: UIColor(red: 0.75, green: 0.45, blue: 0.95, alpha: 1)
            }
        }
    }

    let id: String
    let kind: Kind
    let namespace: String
    /// Owning workload / resource, e.g. "Deployment/api" or "Service ClusterIP :80".
    let workload: String
    let position: SIMD3<Float>
    let status: EndpointStatus
    let metrics: EndpointMetrics
}

struct Connection: Identifiable {
    enum TrafficProtocol: CaseIterable {
        case http, grpc, sql, cache

        var label: String {
            switch self {
            case .http: "HTTP"
            case .grpc: "gRPC"
            case .sql: "SQL"
            case .cache: "Cache"
            }
        }

        var color: UIColor {
            switch self {
            case .http: UIColor(red: 0.20, green: 0.95, blue: 0.95, alpha: 1)
            case .grpc: UIColor(red: 0.30, green: 1.00, blue: 0.45, alpha: 1)
            case .sql: UIColor(red: 1.00, green: 0.60, blue: 0.20, alpha: 1)
            case .cache: UIColor(red: 1.00, green: 0.35, blue: 0.70, alpha: 1)
            }
        }
    }

    var id: String { "\(from)->\(to)" }
    let from: String
    let to: String
    let traffic: TrafficProtocol
    /// Relative load, 1...4: number of packets in flight on this connection.
    let load: Int
}

private func ep(
    _ id: String, _ kind: Endpoint.Kind, ns: String, _ workload: String,
    _ position: SIMD3<Float>, status: EndpointStatus = .running,
    cpu: Int, mem: Int, rps: Int, restarts: Int = 0
) -> Endpoint {
    Endpoint(
        id: id, kind: kind, namespace: ns, workload: workload, position: position,
        status: status,
        metrics: EndpointMetrics(cpuMillicores: cpu, memoryMiB: mem, requestsPerSecond: rps, restarts: restarts)
    )
}

extension ClusterTopology {
    static let sample = ClusterTopology(
        nodes: [
            ep("ingress-nginx", .ingress, ns: "ingress-nginx", "Deployment/ingress-nginx-controller",
               [-0.40, 0.00, 0.00], cpu: 180, mem: 210, rps: 940),

            ep("frontend-svc", .service, ns: "shop", "Service ClusterIP :80",
               [-0.20, 0.16, 0.00], cpu: 0, mem: 0, rps: 520),
            ep("api-svc", .service, ns: "shop", "Service ClusterIP :8080",
               [-0.20, 0.00, 0.00], cpu: 0, mem: 0, rps: 310),
            ep("auth-svc", .service, ns: "shop", "Service ClusterIP :9000",
               [-0.20, -0.16, 0.00], cpu: 0, mem: 0, rps: 110),

            ep("frontend-7d9f-a", .pod, ns: "shop", "Deployment/frontend",
               [0.02, 0.22, -0.06], cpu: 120, mem: 180, rps: 260),
            ep("frontend-7d9f-b", .pod, ns: "shop", "Deployment/frontend",
               [0.02, 0.14, 0.08], cpu: 135, mem: 176, rps: 260),
            ep("api-5c4b-a", .pod, ns: "shop", "Deployment/api",
               [0.02, 0.04, -0.12], cpu: 340, mem: 420, rps: 160),
            ep("api-5c4b-b", .pod, ns: "shop", "Deployment/api",
               [0.02, -0.01, 0.02], cpu: 310, mem: 405, rps: 150, restarts: 1),
            // Broken on purpose: long-press it (or use Restart) to recover it.
            ep("api-5c4b-c", .pod, ns: "shop", "Deployment/api",
               [0.02, -0.06, 0.14], status: .crashLoop, cpu: 5, mem: 60, rps: 0, restarts: 7),
            ep("auth-6f2a-a", .pod, ns: "shop", "Deployment/auth",
               [0.02, -0.18, -0.04], cpu: 90, mem: 140, rps: 110),

            ep("redis", .datastore, ns: "data", "StatefulSet/redis",
               [0.30, 0.10, 0.00], cpu: 60, mem: 512, rps: 780),
            ep("postgres", .datastore, ns: "data", "StatefulSet/postgres",
               [0.30, -0.08, 0.00], cpu: 450, mem: 2048, rps: 240),
        ],
        connections: [
            Connection(from: "ingress-nginx", to: "frontend-svc", traffic: .http, load: 4),
            Connection(from: "ingress-nginx", to: "api-svc", traffic: .http, load: 3),
            Connection(from: "ingress-nginx", to: "auth-svc", traffic: .http, load: 2),

            Connection(from: "frontend-svc", to: "frontend-7d9f-a", traffic: .http, load: 2),
            Connection(from: "frontend-svc", to: "frontend-7d9f-b", traffic: .http, load: 2),
            Connection(from: "api-svc", to: "api-5c4b-a", traffic: .grpc, load: 2),
            Connection(from: "api-svc", to: "api-5c4b-b", traffic: .grpc, load: 1),
            Connection(from: "api-svc", to: "api-5c4b-c", traffic: .grpc, load: 2),
            Connection(from: "auth-svc", to: "auth-6f2a-a", traffic: .grpc, load: 2),

            Connection(from: "api-5c4b-a", to: "postgres", traffic: .sql, load: 1),
            Connection(from: "api-5c4b-b", to: "postgres", traffic: .sql, load: 2),
            Connection(from: "api-5c4b-c", to: "postgres", traffic: .sql, load: 1),
            Connection(from: "api-5c4b-a", to: "redis", traffic: .cache, load: 3),
            Connection(from: "api-5c4b-b", to: "redis", traffic: .cache, load: 2),
            Connection(from: "auth-6f2a-a", to: "redis", traffic: .cache, load: 3),
        ]
    )
}
