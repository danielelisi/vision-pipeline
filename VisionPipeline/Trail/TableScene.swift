import RealityKit
import UIKit

/// Marks the terrain as the target of the tap and two-hand Shape gestures.
struct TerrainTargetComponent: Component {}
/// Marks waypoint pins as the target of the drag and long-press gestures.
struct PinTargetComponent: Component {}

/// Owns the RealityKit entities for the trail table and keeps them in step with `TrailModel`.
///
/// The map is a square diorama block cut out of the landscape (no plinth). Hierarchy:
///   table     the whole block. Gets the ManipulationComponent in Move mode.
///   ├ sun     directional light with shadows, fixed to the block
///   └ pivot   turned by the Shape-mode rotate gesture. All map positions are in pivot space.
///     ├ base      unscaled soil band and bottom, y 0 ... baseDepth
///     ├ terrain   at y = baseDepth. Collision + input target for taps and two-hand gestures
///     │ ├ visual    surface, cut sides and pool, scaled in Y for vertical exaggeration
///     │ └ waterfall, splash, mist   particle emitters, placed for the current exaggeration
///     ├ pins      one draggable sphere per waypoint
///     └ route     pooled cylinder segments that follow the ground
@MainActor
final class TableScene {
    static let home = Transform(translation: [0, 0.8, -0.9])
    private static let pinHeight: Float = 0.05
    private static let routeLift: Float = 0.004

    let table = Entity()
    let pivot = Entity()
    let terrain = Entity()

    private let visual = Entity()
    private let routeRoot = Entity()
    private let fall = WaterfallEffect.makeFall()
    private let splash = WaterfallEffect.makeSplash()
    private let mist = WaterfallEffect.makeMist()
    private var surface: ModelEntity?
    private var walls: ModelEntity?
    private var base: ModelEntity?
    private var water: ModelEntity?
    private var waterSides: ModelEntity?

    private var pins: [UUID: ModelEntity] = [:]
    private var pinColours: [UUID: UIColor] = [:]
    private var segments: [ModelEntity] = []

    private var heightfield: Terrain?
    private var built = false
    private var appliedMode: TrailModel.Mode?
    private var appliedReset = 0
    private var placedEffects: Float?
    private var collisionExaggeration: Float?
    private var wantedExaggeration: Float = 1
    private var collisionTask: Task<Void, Never>?

    private let pinMesh = MeshResource.generateSphere(radius: 0.012)
    private let stemMesh = MeshResource.generateCylinder(height: TableScene.pinHeight, radius: 0.0015)
    private let segmentMesh = MeshResource.generateCylinder(height: 1, radius: 0.003)
    private let routeMaterial = UnlitMaterial(color: .systemOrange)
    private let stemMaterial = SimpleMaterial(color: .white, roughness: 0.4, isMetallic: false)

    init() {
        table.name = "table"
        table.transform = TableScene.home

        terrain.name = "terrain"
        terrain.position = [0, DioramaMesh.baseDepth, 0]
        terrain.components.set(TerrainTargetComponent())
        table.addChild(pivot)
        pivot.addChild(terrain)
        terrain.addChild(visual)
        terrain.addChild(fall)
        terrain.addChild(splash)
        terrain.addChild(mist)
        pivot.addChild(routeRoot)
    }

    // MARK: - Build

    func build(from heightfield: Terrain) async {
        guard !built else { return }
        self.heightfield = heightfield

        // Plain colours first, so the block appears straight away. Baked textures replace them.
        let moss = SimpleMaterial(color: UIColor(red: 0.46, green: 0.50, blue: 0.15, alpha: 1), roughness: 0.9, isMetallic: false)
        let rock = SimpleMaterial(color: UIColor(red: 0.20, green: 0.20, blue: 0.19, alpha: 1), roughness: 0.8, isMetallic: false)
        do {
            let surface = ModelEntity(mesh: try DioramaMesh.surface(heightfield), materials: [moss])
            let walls = ModelEntity(mesh: try DioramaMesh.upperWalls(heightfield), materials: [rock])
            let base = ModelEntity(mesh: try DioramaMesh.base(heightfield), materials: [rock])
            visual.addChild(surface)
            visual.addChild(walls)
            pivot.addChild(base)
            self.surface = surface
            self.walls = walls
            self.base = base

            if let mesh = try DioramaMesh.waterSurface(heightfield) {
                let water = ModelEntity(mesh: mesh, materials: [TerrainTextures.waterMaterial(side: false, ripples: nil)])
                water.components.set(WaterRippleComponent())
                visual.addChild(water)
                self.water = water
            }
            if let mesh = try DioramaMesh.waterSides(heightfield) {
                let sides = ModelEntity(mesh: mesh, materials: [TerrainTextures.waterMaterial(side: true, ripples: nil)])
                visual.addChild(sides)
                waterSides = sides
            }
        } catch {
            print("TrailTable: could not build the diorama meshes: \(error)")
        }

        addSun()

        // A flat slab at plateau height so taps work straight away. The accurate surface replaces it in `refreshCollision`.
        let slab = ShapeResource
            .generateBox(size: [Terrain.size, 0.02, Terrain.size])
            .offsetBy(translation: [0, 0.36 * Terrain.heightScale * TrailModel.defaultExaggeration, 0])
        terrain.components.set(CollisionComponent(shapes: [slab]))
        built = true

        Task { await applyTextures(heightfield) }
    }

    /// Bakes base colour, normal and roughness maps from the heightfield off the main thread, then swaps them in.
    private func applyTextures(_ heightfield: Terrain) async {
        let exaggeration = TrailModel.defaultExaggeration
        let baked = await Task.detached(priority: .userInitiated) {
            TerrainTextures.bake(heightfield, exaggeration: exaggeration)
        }.value
        do {
            let top = try await TerrainTextures.material(for: baked.top)
            let side = try await TerrainTextures.material(for: baked.walls)
            let ripples = try await TerrainTextures.rippleTexture(baked)
            surface?.model?.materials = [top]
            walls?.model?.materials = [side]
            base?.model?.materials = [side]
            water?.model?.materials = [TerrainTextures.waterMaterial(side: false, ripples: ripples)]
            waterSides?.model?.materials = [TerrainTextures.waterMaterial(side: true, ripples: ripples)]
        } catch {
            print("TrailTable: could not create the terrain textures: \(error)")
        }
    }

    /// A key light from the front left, fixed to the block, so the cliffs shade themselves.
    private func addSun() {
        let sun = Entity()
        sun.name = "sun"
        sun.components.set(DirectionalLightComponent(color: .white, intensity: 2600))
        sun.components.set(DirectionalLightComponent.Shadow())
        table.addChild(sun)
        sun.look(at: [0, 0.2, 0], from: [-0.7, 1.4, 0.9], relativeTo: table)
    }

    /// Floats a SwiftUI attachment above the far edge of the table.
    func attach(hud: Entity) {
        table.addChild(hud)
        hud.position = [0, 0.78, -0.42]
        hud.components.set(BillboardComponent())
    }

    static func waypointID(of entity: Entity) -> UUID? {
        guard entity.name.hasPrefix("wp:") else { return nil }
        return UUID(uuidString: String(entity.name.dropFirst(3)))
    }

    /// Pivot-space height of the walkable surface at a map position.
    private func groundY(_ heightfield: Terrain, x: Float, z: Float, exaggeration: Float) -> Float {
        DioramaMesh.baseDepth + heightfield.modelHeight(x: x, z: z) * exaggeration
    }

    // MARK: - Sync

    func sync(with model: TrailModel) {
        // Read the model first, so SwiftUI tracks these even while the scene is still building.
        let waypoints = model.waypoints
        let route = model.route
        let exaggeration = model.exaggeration
        let heading = model.heading
        let mode = model.mode
        let reset = model.resetToken
        guard built else { return }

        if reset != appliedReset {
            table.transform = TableScene.home
            appliedReset = reset
        }

        pivot.orientation = simd_quatf(angle: heading, axis: [0, 1, 0])
        visual.scale = [1, exaggeration, 1]
        wantedExaggeration = exaggeration

        if placedEffects != exaggeration {
            WaterfallEffect.place(fall: fall, splash: splash, mist: mist,
                                  waterfall: model.terrain.waterfall, exaggeration: exaggeration)
            placedEffects = exaggeration
        }

        if mode != appliedMode {
            appliedMode = mode
            apply(mode)
        }
        // The exact surface is only needed for placing waypoints. Rebuilding it while a Shape
        // gesture runs would swap the collision under the hands and cancel the gesture.
        if mode == .plan { refreshCollision() }

        syncPins(waypoints, terrain: model.terrain, exaggeration: exaggeration, mode: mode)
        syncRoute(route, terrain: model.terrain, exaggeration: exaggeration)
    }

    private func syncPins(_ waypoints: [TrailModel.Waypoint], terrain heightfield: Terrain,
                          exaggeration: Float, mode: TrailModel.Mode) {
        let live = Set(waypoints.map(\.id))
        for (id, pin) in pins where !live.contains(id) {
            pin.removeFromParent()
            pins[id] = nil
            pinColours[id] = nil
        }

        for (index, waypoint) in waypoints.enumerated() {
            let pin: ModelEntity
            if let existing = pins[waypoint.id] {
                pin = existing
            } else {
                pin = makePin(id: waypoint.id)
                setInput(pin, enabled: mode == .plan)
                pivot.addChild(pin)
                pins[waypoint.id] = pin
            }

            let ground = groundY(heightfield, x: waypoint.x, z: waypoint.z, exaggeration: exaggeration)
            pin.position = [waypoint.x, ground + TableScene.pinHeight, waypoint.z]

            // Green start, red finish, white in between.
            let colour: UIColor = index == 0 ? .systemGreen : (index == waypoints.count - 1 ? .systemRed : .white)
            if pinColours[waypoint.id] != colour {
                pin.model?.materials = [SimpleMaterial(color: colour, roughness: 0.3, isMetallic: false)]
                pinColours[waypoint.id] = colour
            }
        }
    }

    private func syncRoute(_ route: [TrailModel.RouteSample], terrain heightfield: Terrain, exaggeration: Float) {
        let points: [SIMD3<Float>] = route.map { sample in
            let ground = groundY(heightfield, x: sample.x, z: sample.z, exaggeration: exaggeration)
            return [sample.x, ground + TableScene.routeLift, sample.z]
        }
        let needed = max(points.count - 1, 0)

        while segments.count < needed {
            let segment = ModelEntity(mesh: segmentMesh, materials: [routeMaterial])
            routeRoot.addChild(segment)
            segments.append(segment)
        }

        for (index, segment) in segments.enumerated() {
            guard index < needed else {
                segment.isEnabled = false
                continue
            }
            let delta = points[index + 1] - points[index]
            let length = simd_length(delta)
            guard length > 0.00001 else {
                segment.isEnabled = false
                continue
            }
            segment.isEnabled = true
            segment.position = (points[index] + points[index + 1]) / 2
            segment.orientation = simd_quatf(from: [0, 1, 0], to: delta / length)
            segment.scale = [1, length, 1]
        }
    }

    // MARK: - Modes

    /// Plan: terrain and pins take input. Shape: terrain only. Move: the whole table is one grabbable object.
    private func apply(_ mode: TrailModel.Mode) {
        setInput(terrain, enabled: mode != .move)
        for pin in pins.values {
            setInput(pin, enabled: mode == .plan)
        }

        if mode == .shape {
            // A steady box around the whole block: easy to aim both hands at, and it never
            // changes mid-gesture. The exact surface comes back when returning to Plan.
            let block = ShapeResource
                .generateBox(size: [Terrain.size, 0.72, Terrain.size])
                .offsetBy(translation: [0, 0.36, 0])
            terrain.components.set(CollisionComponent(shapes: [block]))
            collisionExaggeration = nil
        }

        // ManipulationComponent is visionOS 26 only. On older systems Move mode does nothing.
        if #available(visionOS 26.0, *) {
            if mode == .move {
                // Covers the whole block up to the tallest exaggeration.
                let grabArea = ShapeResource
                    .generateBox(size: [0.86, 0.75, 0.86])
                    .offsetBy(translation: [0, 0.375, 0])
                ManipulationComponent.configureEntity(table, collisionShapes: [grabArea])
                var manipulation = ManipulationComponent()
                manipulation.releaseBehavior = .stay   // stay where it is put, do not spring back
                table.components.set(manipulation)
            } else {
                table.components.remove(ManipulationComponent.self)
                table.components.remove(InputTargetComponent.self)
                table.components.remove(CollisionComponent.self)
                table.components.remove(HoverEffectComponent.self)
            }
        }
    }

    private func setInput(_ entity: Entity, enabled: Bool) {
        if enabled {
            entity.components.set(InputTargetComponent())
        } else {
            entity.components.remove(InputTargetComponent.self)
        }
    }

    // MARK: - Collision

    /// Rebuilds the terrain's collision surface to match the current exaggeration, one build at a time.
    private func refreshCollision() {
        guard collisionTask == nil, collisionExaggeration != wantedExaggeration, let heightfield else { return }
        let target = wantedExaggeration

        collisionTask = Task { [weak self] in
            var shape: ShapeResource?
            if let mesh = try? DioramaMesh.collisionSurface(heightfield, yScale: target) {
                shape = try? await ShapeResource.generateStaticMesh(from: mesh)
            }
            guard let self else { return }
            // Only Plan uses the exact surface; if the mode changed meanwhile, keep its collision.
            if let shape, self.appliedMode == .plan {
                self.terrain.components.set(CollisionComponent(shapes: [shape]))
            } else if self.appliedMode != .plan {
                self.collisionExaggeration = nil
                self.collisionTask = nil
                return
            }
            self.collisionExaggeration = target   // also on failure, so it does not retry in a loop
            self.collisionTask = nil
            self.refreshCollision()               // catch up if the value changed meanwhile
        }
    }

    // MARK: - Entities

    private func makePin(id: UUID) -> ModelEntity {
        let pin = ModelEntity(mesh: pinMesh, materials: [])
        pin.name = "wp:\(id.uuidString)"   // gestures resolve the waypoint from this name
        pin.components.set(PinTargetComponent())
        pin.components.set(CollisionComponent(shapes: [.generateSphere(radius: 0.022)]))
        pin.components.set(HoverEffectComponent())

        let stem = ModelEntity(mesh: stemMesh, materials: [stemMaterial])
        stem.position = [0, -TableScene.pinHeight / 2, 0]
        pin.addChild(stem)
        return pin
    }
}
