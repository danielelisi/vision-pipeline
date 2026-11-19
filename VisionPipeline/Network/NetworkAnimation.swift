import Foundation
import RealityKit

/// Marks an endpoint entity (the input target). Its visible mesh is a child
/// carrying `PulseComponent`, so pulses never fight gestures over `scale`.
struct EndpointComponent: Component {
    var id: String
    /// False while the endpoint is down: traffic to it is hidden.
    var isServing = true
}

/// Endpoints that can be moved with a SwiftUI `DragGesture`.
/// (Datastores use `ManipulationComponent` instead on visionOS 26.)
struct DraggableComponent: Component {}

/// A tube that follows two endpoints wherever they are moved.
struct LinkComponent: Component {
    var connectionID: String
    weak var from: Entity?
    weak var to: Entity?
    var isDimmed = false
}

/// A packet travelling between two endpoints, looping forever.
struct PacketComponent: Component {
    var connectionID: String
    weak var from: Entity?
    weak var to: Entity?
    /// Mesh to pulse when the packet arrives.
    weak var targetBody: Entity?
    /// 0...1 along the connection.
    var progress: Float
    /// Fraction of the connection travelled per second.
    var speed: Float
    var isDimmed = false
}

/// Endpoint meshes briefly swell when traffic reaches them.
struct PulseComponent: Component {
    var baseScale: Float = 1
    var energy: Float = 0
}

/// Slow side-to-side sway of the whole cluster. Removed once the user
/// rotates or scales the cluster themselves.
struct SwayComponent: Component {
    var elapsed: Float = 0
    var amplitude: Float = 0.35 // radians
    var frequency: Float = 0.25
}

struct NetworkAnimationSystem: System {
    private static let links = EntityQuery(where: .has(LinkComponent.self))
    private static let packets = EntityQuery(where: .has(PacketComponent.self))
    private static let pulses = EntityQuery(where: .has(PulseComponent.self))
    private static let sways = EntityQuery(where: .has(SwayComponent.self))

    init(scene: RealityKit.Scene) {}

    func update(context: SceneUpdateContext) {
        let dt = Float(context.deltaTime)

        for entity in context.entities(matching: Self.links, updatingSystemWhen: .rendering) {
            guard let link = entity.components[LinkComponent.self],
                  let a = link.from?.position, let b = link.to?.position else { continue }
            let delta = b - a
            let length = simd_length(delta)
            guard length > 0.0001 else { continue }
            // Tube mesh is a unit-height cylinder along +Y: stretch, aim, centre.
            entity.transform = Transform(
                scale: [1, length, 1],
                rotation: simd_quatf(from: [0, 1, 0], to: delta / length),
                translation: (a + b) / 2
            )
            setOpacity(entity, link.isDimmed ? 0.25 : 1)
        }

        for entity in context.entities(matching: Self.packets, updatingSystemWhen: .rendering) {
            guard var packet = entity.components[PacketComponent.self],
                  let a = packet.from?.position, let b = packet.to?.position else { continue }
            let serving = packet.to?.components[EndpointComponent.self]?.isServing ?? true
            packet.progress += packet.speed * dt
            if packet.progress >= 1 {
                packet.progress -= 1
                if serving, let body = packet.targetBody, var pulse = body.components[PulseComponent.self] {
                    pulse.energy = 1
                    body.components.set(pulse)
                }
            }
            entity.position = a + (b - a) * packet.progress
            entity.components.set(packet)
            setOpacity(entity, !serving ? 0 : (packet.isDimmed ? 0.12 : 1))
        }

        for entity in context.entities(matching: Self.pulses, updatingSystemWhen: .rendering) {
            guard var pulse = entity.components[PulseComponent.self] else { continue }
            pulse.energy *= exp(-dt * 5)
            entity.scale = SIMD3(repeating: pulse.baseScale * (1 + 0.35 * pulse.energy))
            entity.components.set(pulse)
        }

        for entity in context.entities(matching: Self.sways, updatingSystemWhen: .rendering) {
            guard var sway = entity.components[SwayComponent.self] else { continue }
            sway.elapsed += dt
            let angle = sin(sway.elapsed * sway.frequency) * sway.amplitude
            entity.orientation = simd_quatf(angle: angle, axis: [0, 1, 0])
            entity.components.set(sway)
        }
    }

    private func setOpacity(_ entity: Entity, _ value: Float) {
        if entity.components[OpacityComponent.self]?.opacity != value {
            entity.components.set(OpacityComponent(opacity: value))
        }
    }
}

enum NetworkAnimation {
    /// Call once at launch, before any RealityView is created.
    static func register() {
        EndpointComponent.registerComponent()
        DraggableComponent.registerComponent()
        LinkComponent.registerComponent()
        PacketComponent.registerComponent()
        PulseComponent.registerComponent()
        SwayComponent.registerComponent()
        NetworkAnimationSystem.registerSystem()
    }
}
