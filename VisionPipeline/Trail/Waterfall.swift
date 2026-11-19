import Foundation
import RealityKit
import UIKit

/// The waterfall from the notch in the cliff: a falling sheet of drops, a splash where
/// it lands, and a little mist. All are particle emitters on the terrain entity.
@MainActor
enum WaterfallEffect {
    /// Downward acceleration of the falling water, in m/s² (the model is small, so less than g).
    static let gravity: Float = 1.2
    /// Speed the water leaves the lip with, toward the pool, in m/s.
    static let launchSpeed: Float = 0.05

    static func makeFall() -> Entity {
        var emitter = ParticleEmitterComponent()
        emitter.emitterShape = .box
        emitter.emitterShapeSize = [0.014, 0.001, 0.003]
        emitter.birthLocation = .volume
        emitter.birthDirection = .local
        emitter.emissionDirection = [0, 0, 1]
        emitter.speed = launchSpeed
        emitter.speedVariation = 0.01
        emitter.mainEmitter.birthRate = 1200
        emitter.mainEmitter.lifeSpan = 0.4
        emitter.mainEmitter.size = 0.0028
        emitter.mainEmitter.sizeVariation = 0.001
        emitter.mainEmitter.spreadingAngle = 0.04
        emitter.mainEmitter.acceleration = [0, -gravity, 0]
        emitter.mainEmitter.color = .constant(.single(UIColor(white: 0.96, alpha: 0.85)))
        emitter.mainEmitter.opacityCurve = .linearFadeOut
        emitter.mainEmitter.blendMode = .alpha
        emitter.mainEmitter.isLightingEnabled = false
        let entity = Entity()
        entity.name = "waterfall"
        entity.components.set(emitter)
        return entity
    }

    static func makeSplash() -> Entity {
        var emitter = ParticleEmitterComponent()
        emitter.emitterShape = .sphere
        emitter.emitterShapeSize = [0.008, 0.002, 0.008]
        emitter.birthLocation = .surface
        emitter.birthDirection = .normal
        emitter.speed = 0.04
        emitter.speedVariation = 0.02
        emitter.mainEmitter.birthRate = 600
        emitter.mainEmitter.lifeSpan = 0.45
        emitter.mainEmitter.size = 0.002
        emitter.mainEmitter.sizeMultiplierAtEndOfLifespan = 2
        emitter.mainEmitter.acceleration = [0, -0.8, 0]
        emitter.mainEmitter.color = .constant(.single(UIColor(white: 1, alpha: 0.7)))
        emitter.mainEmitter.opacityCurve = .linearFadeOut
        emitter.mainEmitter.blendMode = .alpha
        emitter.mainEmitter.isLightingEnabled = false
        let entity = Entity()
        entity.name = "splash"
        entity.components.set(emitter)
        return entity
    }

    static func makeMist() -> Entity {
        var emitter = ParticleEmitterComponent()
        emitter.emitterShape = .sphere
        emitter.emitterShapeSize = [0.015, 0.004, 0.015]
        emitter.birthLocation = .volume
        emitter.birthDirection = .normal
        emitter.speed = 0.01
        emitter.mainEmitter.birthRate = 40
        emitter.mainEmitter.lifeSpan = 1.4
        emitter.mainEmitter.size = 0.012
        emitter.mainEmitter.sizeMultiplierAtEndOfLifespan = 3
        emitter.mainEmitter.acceleration = [0, 0.02, 0]
        emitter.mainEmitter.color = .constant(.single(UIColor(white: 1, alpha: 0.12)))
        emitter.mainEmitter.opacityCurve = .gradualFadeInOut
        emitter.mainEmitter.blendMode = .alpha
        emitter.mainEmitter.isLightingEnabled = false
        let entity = Entity()
        entity.name = "mist"
        entity.components.set(emitter)
        return entity
    }

    /// Puts the emitters at the lip and the landing point for the current vertical exaggeration,
    /// and times the fall so drops vanish as they reach the water.
    static func place(fall: Entity, splash: Entity, mist: Entity,
                      waterfall: Terrain.Waterfall, exaggeration: Float) {
        let lipY = waterfall.lipHeight * Terrain.heightScale * exaggeration
        let waterY = Terrain.waterLevel * Terrain.heightScale * exaggeration
        let drop = max(lipY - waterY, 0.005)
        let fallTime = (2 * drop / gravity).squareRoot()

        let towardPool = waterfall.impact - waterfall.lip
        let direction = simd_length(towardPool) > 0 ? simd_normalize(towardPool) : SIMD2<Float>(0, 1)
        let landing = waterfall.lip + direction * launchSpeed * fallTime

        fall.position = [waterfall.lip.x, lipY + 0.002, waterfall.lip.y]
        // Face the emitter's +z toward the pool so the water leaves the lip outward.
        fall.orientation = simd_quatf(from: [0, 0, 1], to: [direction.x, 0, direction.y])
        if var emitter = fall.components[ParticleEmitterComponent.self] {
            emitter.mainEmitter.lifeSpan = Double(fallTime)
            fall.components.set(emitter)
        }

        splash.position = [landing.x, waterY + 0.002, landing.y]
        mist.position = [landing.x, waterY + 0.01, landing.y]
    }
}

/// Scrolls the water's ripple normal map so the pool surface moves.
struct WaterRippleComponent: Component {
    var velocity: SIMD2<Float> = [0.018, 0.011]
    var offset: SIMD2<Float> = .zero
}

struct WaterRippleSystem: System {
    private static let query = EntityQuery(where: .has(WaterRippleComponent.self) && .has(ModelComponent.self))

    init(scene: RealityKit.Scene) {}

    func update(context: SceneUpdateContext) {
        let dt = Float(context.deltaTime)
        for entity in context.entities(matching: Self.query, updatingSystemWhen: .rendering) {
            guard var ripple = entity.components[WaterRippleComponent.self],
                  var model = entity.components[ModelComponent.self],
                  var material = model.materials.first as? PhysicallyBasedMaterial else { continue }
            ripple.offset += ripple.velocity * dt
            ripple.offset -= ripple.offset.rounded(.down) // keep it in 0...1
            material.textureCoordinateTransform.offset = ripple.offset
            model.materials = [material]
            entity.components.set(model)
            entity.components.set(ripple)
        }
    }
}

enum TrailEffects {
    /// Call once at launch, before any RealityView is created.
    static func register() {
        WaterRippleComponent.registerComponent()
        WaterRippleSystem.registerSystem()
    }
}
