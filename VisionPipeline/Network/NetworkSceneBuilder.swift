import RealityKit
import UIKit

/// Turns a `ClusterTopology` into a RealityKit entity tree:
///
///     cluster (sways, scales, rotates)
///     ├─ <endpoint id>   input target: tap / long-press / drag / manipulation
///     │   └─ <id>-body   visible mesh, pulses
///     ├─ tube            follows its two endpoints (LinkComponent)
///     └─ packet          moves between its two endpoints (PacketComponent)
enum NetworkSceneBuilder {
    static let rootName = "cluster"

    static func makeRoot(for topology: ClusterTopology) -> Entity {
        let root = Entity()
        root.name = rootName
        root.components.set(SwayComponent())

        var endpoints: [String: Entity] = [:]
        for node in topology.nodes {
            let entity = makeEndpoint(node)
            endpoints[node.id] = entity
            root.addChild(entity)
        }

        let tubeMesh = MeshResource.generateCylinder(height: 1, radius: 0.0022)
        let packetMesh = MeshResource.generateSphere(radius: 0.007)

        for connection in topology.connections {
            guard let from = endpoints[connection.from], let to = endpoints[connection.to] else { continue }

            var tubeMaterial = UnlitMaterial(color: .white)
            tubeMaterial.blending = .transparent(opacity: 0.22)
            let tube = ModelEntity(mesh: tubeMesh, materials: [tubeMaterial])
            tube.components.set(LinkComponent(connectionID: connection.id, from: from, to: to))
            root.addChild(tube)

            let count = max(1, min(connection.load, 4))
            // Vary speed a little per connection so the traffic doesn't move in lockstep.
            let seed = connection.id.utf8.reduce(0) { ($0 &* 31 &+ Int($1)) & 0xFFFF }
            let speed = 0.35 + 0.1 * Float(seed % 5)
            let packetMaterial = UnlitMaterial(color: connection.traffic.color)
            for i in 0..<count {
                let packet = ModelEntity(mesh: packetMesh, materials: [packetMaterial])
                packet.components.set(PacketComponent(
                    connectionID: connection.id,
                    from: from,
                    to: to,
                    targetBody: body(of: to),
                    progress: Float(i) / Float(count),
                    speed: speed
                ))
                root.addChild(packet)
            }
        }
        return root
    }

    static func body(of endpoint: Entity) -> ModelEntity? {
        endpoint.findEntity(named: "\(endpoint.name)-body") as? ModelEntity
    }

    static func color(for kind: Endpoint.Kind, status: EndpointStatus) -> UIColor {
        status.tint ?? kind.color
    }

    static func material(_ color: UIColor) -> SimpleMaterial {
        SimpleMaterial(color: color, roughness: 0.35, isMetallic: false)
    }

    private static func makeEndpoint(_ node: Endpoint) -> Entity {
        let mesh: MeshResource
        // Collision shapes are a little larger than the meshes so they're easy to target.
        let shape: ShapeResource
        switch node.kind {
        case .ingress:
            mesh = .generateBox(size: 0.055, cornerRadius: 0.012)
            shape = .generateBox(size: [0.07, 0.07, 0.07])
        case .service:
            mesh = .generateSphere(radius: 0.026)
            shape = .generateSphere(radius: 0.034)
        case .pod:
            mesh = .generateBox(size: 0.032, cornerRadius: 0.006)
            shape = .generateBox(size: [0.045, 0.045, 0.045])
        case .datastore:
            mesh = .generateCylinder(height: 0.05, radius: 0.024)
            shape = .generateBox(size: [0.06, 0.06, 0.06])
        }

        let endpoint = Entity()
        endpoint.name = node.id
        endpoint.position = node.position
        endpoint.components.set(EndpointComponent(id: node.id, isServing: node.status.isServing))

        // Layer 1: SwiftUI gestures need an input target plus a collision shape;
        // HoverEffectComponent gives the gaze highlight.
        endpoint.components.set(InputTargetComponent())
        endpoint.components.set(CollisionComponent(shapes: [shape]))
        endpoint.components.set(HoverEffectComponent())

        if node.kind == .datastore, #available(visionOS 26.0, *) {
            // Layer 2: grab, move, rotate and scale with natural hand motion.
            var manipulation = ManipulationComponent()
            manipulation.releaseBehavior = .stay
            endpoint.components.set(manipulation)
        } else {
            endpoint.components.set(DraggableComponent())
        }

        let body = ModelEntity(mesh: mesh, materials: [material(color(for: node.kind, status: node.status))])
        body.name = "\(node.id)-body"
        body.components.set(PulseComponent())
        body.components.set(GroundingShadowComponent(castsShadow: true))
        endpoint.addChild(body)

        return endpoint
    }
}
