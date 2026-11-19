import Foundation
import RealityKit

/// A packet travelling from `from` to `to`, looping forever.
struct PacketComponent: Component {
    var from: SIMD3<Float>
    var to: SIMD3<Float>
    /// 0...1 along the connection.
    var progress: Float
    /// Fraction of the connection travelled per second.
    var speed: Float
    /// Endpoint to pulse when the packet arrives.
    weak var target: Entity?
}

/// Endpoints briefly swell when traffic reaches them.
struct PulseComponent: Component {
    var baseScale: Float = 1
    var energy: Float = 0
}

/// Slow side-to-side sway of the whole cluster so the depth reads clearly.
struct SwayComponent: Component {
    var elapsed: Float = 0
    var amplitude: Float = 0.35 // radians
    var frequency: Float = 0.25 // rad/s of the sine
}

struct NetworkAnimationSystem: System {
    private static let packets = EntityQuery(where: .has(PacketComponent.self))
    private static let pulses = EntityQuery(where: .has(PulseComponent.self))
    private static let sways = EntityQuery(where: .has(SwayComponent.self))

    init(scene: RealityKit.Scene) {}

    func update(context: SceneUpdateContext) {
        let dt = Float(context.deltaTime)

        for entity in context.entities(matching: Self.packets, updatingSystemWhen: .rendering) {
            guard var packet = entity.components[PacketComponent.self] else { continue }
            packet.progress += packet.speed * dt
            if packet.progress >= 1 {
                packet.progress -= 1
                if let target = packet.target, var pulse = target.components[PulseComponent.self] {
                    pulse.energy = 1
                    target.components.set(pulse)
                }
            }
            entity.position = packet.from + (packet.to - packet.from) * packet.progress
            entity.components.set(packet)
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
}

enum NetworkAnimation {
    /// Call once at launch, before any RealityView is created.
    static func register() {
        PacketComponent.registerComponent()
        PulseComponent.registerComponent()
        SwayComponent.registerComponent()
        NetworkAnimationSystem.registerSystem()
    }
}
