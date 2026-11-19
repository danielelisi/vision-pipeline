import RealityKit
import UIKit

/// Turns a `ClusterTopology` into a RealityKit entity tree:
/// root (sways) ├─ endpoints (pulse) ├─ connections (static tubes) └─ packets (move).
enum NetworkSceneBuilder {
    static func makeRoot(for topology: ClusterTopology) -> Entity {
        let root = Entity()
        root.name = "cluster"
        root.components.set(SwayComponent())

        var endpoints: [String: Entity] = [:]
        for node in topology.nodes {
            let entity = makeEndpoint(node)
            endpoints[node.id] = entity
            root.addChild(entity)
        }

        for connection in topology.connections {
            guard let from = topology.node(connection.from),
                  let to = topology.node(connection.to) else { continue }

            root.addChild(makeTube(from: from.position, to: to.position))

            let count = max(1, min(connection.load, 4))
            // Vary speed a little per connection so the traffic doesn't move in lockstep.
            let seed = connection.id.utf8.reduce(0) { ($0 &* 31 &+ Int($1)) & 0xFFFF }
            let speed = 0.35 + 0.1 * Float(seed % 5)
            for i in 0..<count {
                root.addChild(makePacket(
                    from: from.position,
                    to: to.position,
                    color: connection.traffic.color,
                    phase: Float(i) / Float(count),
                    speed: speed,
                    target: endpoints[to.id]
                ))
            }
        }
        return root
    }

    private static func makeEndpoint(_ node: Endpoint) -> Entity {
        let mesh: MeshResource = switch node.kind {
        case .ingress: .generateBox(size: 0.055, cornerRadius: 0.012)
        case .service: .generateSphere(radius: 0.026)
        case .pod: .generateBox(size: 0.032, cornerRadius: 0.006)
        case .datastore: .generateCylinder(height: 0.05, radius: 0.024)
        }
        let material = SimpleMaterial(color: node.kind.color, roughness: 0.35, isMetallic: false)
        let entity = ModelEntity(mesh: mesh, materials: [material])
        entity.name = node.id
        entity.position = node.position
        entity.components.set(PulseComponent())
        entity.components.set(GroundingShadowComponent(castsShadow: true))
        return entity
    }

    private static func makeTube(from a: SIMD3<Float>, to b: SIMD3<Float>) -> Entity {
        let delta = b - a
        let length = simd_length(delta)
        var material = UnlitMaterial(color: UIColor(white: 1, alpha: 1))
        material.blending = .transparent(opacity: 0.22)
        let tube = ModelEntity(
            mesh: .generateCylinder(height: length, radius: 0.0022),
            materials: [material]
        )
        tube.position = (a + b) / 2
        // Cylinders are generated along +Y; rotate onto the connection.
        tube.orientation = simd_quatf(from: [0, 1, 0], to: delta / length)
        return tube
    }

    private static func makePacket(
        from: SIMD3<Float>, to: SIMD3<Float>, color: UIColor,
        phase: Float, speed: Float, target: Entity?
    ) -> Entity {
        let packet = ModelEntity(
            mesh: .generateSphere(radius: 0.007),
            materials: [UnlitMaterial(color: color)]
        )
        packet.position = from + (to - from) * phase
        packet.components.set(PacketComponent(
            from: from, to: to, progress: phase, speed: speed, target: target
        ))
        return packet
    }
}
