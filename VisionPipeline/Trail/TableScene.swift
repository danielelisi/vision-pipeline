import RealityKit
import UIKit

/// Owns the RealityKit entities for the trail table and keeps them in step with `TrailModel`.
///
/// Hierarchy:
///   table   round plinth. Gets the ManipulationComponent in Move mode.
///   └ pivot   turned by the Shape-mode rotate gesture. All map positions are in pivot space.
///     ├ terrain   collision + input target for taps and two-hand gestures
///     │ └ visual  elevation-band meshes, scaled in Y for vertical exaggeration
///     ├ pins      one draggable sphere per waypoint
///     └ route     pooled cylinder segments that follow the ground
@MainActor
final class TableScene {
    static let home = Transform(translation: [0, 0.9, -0.9])
    private static let plinthHeight: Float = 0.02
    private static let pinHeight: Float = 0.05
    private static let routeLift: Float = 0.004

    let table: ModelEntity
    let pivot = Entity()
    let terrain = Entity()

    private let visual = Entity()
    private let routeRoot = Entity()
    private var pins: [UUID: ModelEntity] = [:]
    private var pinColours: [UUID: UIColor] = [:]
    private var segments: [ModelEntity] = []

    private var geometry: TerrainMesh.Geometry?
    private var built = false
    private var appliedMode: TrailModel.Mode?
    private var appliedReset = 0
    private var collisionExaggeration: Float?
    private var wantedExaggeration: Float = 1
    private var collisionTask: Task<Void, Never>?

    private let pinMesh = MeshResource.generateSphere(radius: 0.012)
    private let stemMesh = MeshResource.generateCylinder(height: TableScene.pinHeight, radius: 0.0015)
    private let segmentMesh = MeshResource.generateCylinder(height: 1, radius: 0.003)
    private let routeMaterial = UnlitMaterial(color: .systemOrange)
    private let stemMaterial = SimpleMaterial(color: .white, roughness: 0.4, isMetallic: false)

    init() {
        table = ModelEntity(
            mesh: .generateCylinder(height: TableScene.plinthHeight, radius: 0.6),
            materials: [SimpleMaterial(color: UIColor(white: 0.12, alpha: 1), roughness: 0.6, isMetallic: false)]
        )
        table.name = "table"
        table.transform = TableScene.home

        pivot.position = [0, TableScene.plinthHeight / 2, 0]
        terrain.name = "terrain"
        table.addChild(pivot)
        pivot.addChild(terrain)
        terrain.addChild(visual)
        pivot.addChild(routeRoot)
    }

    // MARK: - Build

    func build(from heightfield: Terrain) async {
        guard !built else { return }
        let geometry = TerrainMesh.geometry(for: heightfield)
        self.geometry = geometry

        do {
            for (band, mesh) in try TerrainMesh.bandMeshes(for: geometry) {
                visual.addChild(ModelEntity(mesh: mesh, materials: [material(for: band)]))
            }
        } catch {
            print("TrailTable: could not build the terrain mesh: \(error)")
        }

        // A flat slab so taps work straight away. The accurate surface replaces it in `refreshCollision`.
        let slab = ShapeResource.generateBox(size: [Terrain.size, 0.02, Terrain.size])
        terrain.components.set(CollisionComponent(shapes: [slab]))
        built = true
    }

    /// Floats a SwiftUI attachment above the far edge of the table.
    func attach(hud: Entity) {
        table.addChild(hud)
        hud.position = [0, 0.5, -0.35]
        hud.components.set(BillboardComponent())
    }

    static func waypointID(of entity: Entity) -> UUID? {
        guard entity.name.hasPrefix("wp:") else { return nil }
        return UUID(uuidString: String(entity.name.dropFirst(3)))
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
        refreshCollision()

        if mode != appliedMode {
            apply(mode)
            appliedMode = mode
        }

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

            let ground = heightfield.modelHeight(x: waypoint.x, z: waypoint.z) * exaggeration
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
            let ground = heightfield.modelHeight(x: sample.x, z: sample.z) * exaggeration
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

        // ManipulationComponent is visionOS 26 only. On older systems Move mode does nothing.
        if #available(visionOS 26.0, *) {
            if mode == .move {
                let grabArea = ShapeResource
                    .generateBox(size: [1.0, 0.5, 1.0])
                    .offsetBy(translation: [0, 0.25, 0])
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
        guard collisionTask == nil, collisionExaggeration != wantedExaggeration, let geometry else { return }
        let target = wantedExaggeration

        collisionTask = Task { [weak self] in
            var shape: ShapeResource?
            if let mesh = try? TerrainMesh.surfaceMesh(for: geometry, yScale: target) {
                shape = try? await ShapeResource.generateStaticMesh(from: mesh)
            }
            guard let self else { return }
            if let shape {
                self.terrain.components.set(CollisionComponent(shapes: [shape]))
            }
            self.collisionExaggeration = target   // also on failure, so it does not retry in a loop
            self.collisionTask = nil
            self.refreshCollision()               // catch up if the value changed meanwhile
        }
    }

    // MARK: - Entities & materials

    private func makePin(id: UUID) -> ModelEntity {
        let pin = ModelEntity(mesh: pinMesh, materials: [])
        pin.name = "wp:\(id.uuidString)"   // gestures resolve the waypoint from this name
        pin.components.set(CollisionComponent(shapes: [.generateSphere(radius: 0.022)]))
        pin.components.set(HoverEffectComponent())

        let stem = ModelEntity(mesh: stemMesh, materials: [stemMaterial])
        stem.position = [0, -TableScene.pinHeight / 2, 0]
        pin.addChild(stem)
        return pin
    }

    private func material(for band: Terrain.Band) -> SimpleMaterial {
        let colour: UIColor
        switch band {
        case .water:  colour = UIColor(red: 0.20, green: 0.45, blue: 0.75, alpha: 1)
        case .meadow: colour = UIColor(red: 0.55, green: 0.70, blue: 0.35, alpha: 1)
        case .forest: colour = UIColor(red: 0.20, green: 0.42, blue: 0.24, alpha: 1)
        case .rock:   colour = UIColor(red: 0.50, green: 0.42, blue: 0.34, alpha: 1)
        case .scree:  colour = UIColor(red: 0.62, green: 0.62, blue: 0.62, alpha: 1)
        case .snow:   colour = UIColor(white: 0.96, alpha: 1)
        }
        let roughness: Float = band == .water ? 0.15 : 0.9
        return SimpleMaterial(color: colour, roughness: .float(roughness), isMetallic: false)
    }
}
