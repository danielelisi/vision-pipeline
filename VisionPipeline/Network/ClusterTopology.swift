import UIKit

/// Kubernetes-flavoured test data: ingress → services → pods → datastores.
/// Positions are in metres, centred on the volume's origin.
struct ClusterTopology {
    var nodes: [Endpoint]
    var connections: [Connection]

    func node(_ id: String) -> Endpoint? { nodes.first { $0.id == id } }
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
    let position: SIMD3<Float>
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

extension ClusterTopology {
    static let sample = ClusterTopology(
        nodes: [
            Endpoint(id: "ingress-nginx", kind: .ingress, position: [-0.40, 0.00, 0.00]),

            Endpoint(id: "frontend-svc", kind: .service, position: [-0.20, 0.16, 0.00]),
            Endpoint(id: "api-svc", kind: .service, position: [-0.20, 0.00, 0.00]),
            Endpoint(id: "auth-svc", kind: .service, position: [-0.20, -0.16, 0.00]),

            Endpoint(id: "frontend-7d9f-a", kind: .pod, position: [0.02, 0.22, -0.06]),
            Endpoint(id: "frontend-7d9f-b", kind: .pod, position: [0.02, 0.14, 0.08]),
            Endpoint(id: "api-5c4b-a", kind: .pod, position: [0.02, 0.04, -0.12]),
            Endpoint(id: "api-5c4b-b", kind: .pod, position: [0.02, -0.01, 0.02]),
            Endpoint(id: "api-5c4b-c", kind: .pod, position: [0.02, -0.06, 0.14]),
            Endpoint(id: "auth-6f2a-a", kind: .pod, position: [0.02, -0.18, -0.04]),

            Endpoint(id: "redis", kind: .datastore, position: [0.30, 0.10, 0.00]),
            Endpoint(id: "postgres", kind: .datastore, position: [0.30, -0.08, 0.00]),
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
