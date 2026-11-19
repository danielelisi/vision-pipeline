import RealityKit
import SwiftUI

/// The immersive scene, and every gesture in the playground.
///
/// | Mode  | Gesture                         | API                                   |
/// |-------|---------------------------------|---------------------------------------|
/// | Plan  | pinch terrain: add waypoint     | SpatialTapGesture                     |
/// | Plan  | pinch + drag pin: move it       | DragGesture                           |
/// | Plan  | pinch + hold pin: delete it     | LongPressGesture                      |
/// | Shape | two hands apart: exaggeration   | MagnifyGesture                        |
/// | Shape | two hands turning: spin the map | RotateGesture3D                       |
/// | Move  | grab, carry, turn, resize       | ManipulationComponent (in TableScene) |
struct TableView: View {
    @Environment(TrailModel.self) private var model
    @State private var scene = TableScene()
    @State private var exaggerationAtStart: Float?
    @State private var headingAtStart: Float?

    var body: some View {
        RealityView { content, attachments in
            content.add(scene.table)
            await scene.build(from: model.terrain)
            if let hud = attachments.entity(for: "hud") {
                scene.attach(hud: hud)
            }
            scene.sync(with: model)
        } update: { _, _ in
            scene.sync(with: model)
        } attachments: {
            Attachment(id: "hud") {
                RouteHUD().environment(model)
            }
        }
        .gesture(dragPin)
        .simultaneousGesture(dropWaypoint)
        .simultaneousGesture(deletePin)
        .simultaneousGesture(exaggerate)
        .simultaneousGesture(spin)
    }

    // MARK: - Plan mode

    private var dropWaypoint: some Gesture {
        SpatialTapGesture()
            .targetedToAnyEntity()
            .onEnded { value in
                guard model.mode == .plan, value.entity === scene.terrain else { return }
                let point = value.convert(value.location3D, from: .local, to: scene.pivot)
                model.addWaypoint(x: point.x, z: point.z)
            }
    }

    private var dragPin: some Gesture {
        DragGesture()
            .targetedToAnyEntity()
            .onChanged { value in
                guard model.mode == .plan, let id = TableScene.waypointID(of: value.entity) else { return }
                // Follow the hand in x and z. The model snaps the pin to the ground.
                let point = value.convert(value.location3D, from: .local, to: scene.pivot)
                model.moveWaypoint(id, x: point.x, z: point.z)
            }
    }

    private var deletePin: some Gesture {
        LongPressGesture(minimumDuration: 1.0)
            .targetedToAnyEntity()
            .onEnded { value in
                guard model.mode == .plan, let id = TableScene.waypointID(of: value.entity) else { return }
                model.removeWaypoint(id)
            }
    }

    // MARK: - Shape mode

    private var exaggerate: some Gesture {
        MagnifyGesture()
            .targetedToAnyEntity()
            .onChanged { value in
                guard model.mode == .shape else { return }
                let start = exaggerationAtStart ?? model.exaggeration
                exaggerationAtStart = start
                let range = TrailModel.exaggerationRange
                model.exaggeration = min(max(start * Float(value.magnification), range.lowerBound), range.upperBound)
            }
            .onEnded { _ in exaggerationAtStart = nil }
    }

    private var spin: some Gesture {
        RotateGesture3D(constrainedToAxis: .y)
            .targetedToAnyEntity()
            .onChanged { value in
                guard model.mode == .shape else { return }
                let start = headingAtStart ?? model.heading
                headingAtStart = start
                let rotation = value.rotation
                let direction: Float = rotation.axis.y < 0 ? -1 : 1
                model.heading = start + Float(rotation.angle.radians) * direction
            }
            .onEnded { _ in headingAtStart = nil }
    }
}

/// Route summary that floats above the table.
private struct RouteHUD: View {
    @Environment(TrailModel.self) private var model

    var body: some View {
        let stats = model.stats
        Group {
            if model.waypoints.count < 2 {
                Text(model.mode == .plan ? "Pinch the terrain to drop waypoints" : "\(model.mode.title) mode")
            } else {
                HStack(spacing: 18) {
                    Label(String(format: "%.1f km", stats.distanceKm), systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                    Label(String(format: "%.0f m up", stats.ascent), systemImage: "arrow.up.right")
                    Label(stats.timeText, systemImage: "clock")
                }
            }
        }
        .font(.title3)
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
        .glassBackgroundEffect()
    }
}
