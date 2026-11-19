import RealityKit
import SwiftUI

/// Volumetric window showing the animated, interactive cluster.
///
/// Layer 1 — SwiftUI gestures targeted at entities:
///   tap = select · long-press = restart pod · drag = move endpoint ·
///   two-hand magnify / rotate = scale / turn the whole cluster.
/// Layer 2 — `ManipulationComponent` on datastores (visionOS 26): grab them directly.
struct ClusterVolumeView: View {
    @Environment(AppModel.self) private var model

    @State private var dragStart: SIMD3<Float>?
    @State private var scaleStart: Float?
    @State private var rotationStart: simd_quatf?
    @State private var subscriptions: [EventSubscription] = []

    private static let inspectorID = "inspector"

    var body: some View {
        RealityView { content, attachments in
            let root = NetworkSceneBuilder.makeRoot(for: model.topology)
            content.add(root)

            // Floating name tags, parented to each endpoint so they follow drags.
            for node in model.topology.nodes {
                guard let endpoint = root.findEntity(named: node.id),
                      let label = attachments.entity(for: node.id) else { continue }
                label.position = [0, 0.042, 0]
                label.components.set(BillboardComponent())
                endpoint.addChild(label)
            }

            if let card = attachments.entity(for: Self.inspectorID) {
                card.components.set(BillboardComponent())
                card.isEnabled = false
                root.addChild(card)
            }

            if #available(visionOS 26.0, *) {
                subscriptions = [
                    content.subscribe(to: ManipulationEvents.WillBegin.self) { event in
                        model.log("Grabbed \(event.entity.name)")
                    },
                    content.subscribe(to: ManipulationEvents.WillEnd.self) { event in
                        model.log("Released \(event.entity.name)")
                    },
                ]
            }
        } update: { content, attachments in
            guard let root = content.entities.first(where: { $0.name == NetworkSceneBuilder.rootName }) else { return }
            apply(to: root, inspector: attachments.entity(for: Self.inspectorID))
        } attachments: {
            ForEach(model.topology.nodes) { node in
                Attachment(id: node.id) {
                    Text(node.id)
                        .font(.caption)
                        .monospaced()
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .glassBackgroundEffect()
                }
            }
            Attachment(id: Self.inspectorID) {
                InspectorCard(model: model)
            }
        }
        .id(model.layoutGeneration)
        .gesture(tapToSelect)
        .gesture(longPressToRestart)
        .gesture(dragToMove)
        .simultaneousGesture(magnifyCluster)
        .simultaneousGesture(rotateCluster)
        .onAppear { model.isClusterOpen = true }
        .onDisappear { model.isClusterOpen = false }
    }

    // MARK: Gestures (layer 1)

    private var tapToSelect: some Gesture {
        SpatialTapGesture()
            .targetedToEntity(where: .has(EndpointComponent.self))
            .onEnded { value in
                guard let id = value.entity.components[EndpointComponent.self]?.id else { return }
                model.toggleSelection(id)
            }
    }

    private var longPressToRestart: some Gesture {
        LongPressGesture(minimumDuration: 0.6)
            .targetedToEntity(where: .has(EndpointComponent.self))
            .onEnded { value in
                guard let id = value.entity.components[EndpointComponent.self]?.id else { return }
                if model.canRestart(id) {
                    model.selectedID = id
                    model.restart(id)
                }
            }
    }

    private var dragToMove: some Gesture {
        DragGesture()
            .targetedToEntity(where: .has(DraggableComponent.self))
            .onChanged { value in
                let entity = value.entity
                guard let parent = entity.parent else { return }
                let start = dragStart ?? entity.position
                if dragStart == nil { dragStart = start }
                let now = value.convert(value.location3D, from: .local, to: parent)
                let began = value.convert(value.startLocation3D, from: .local, to: parent)
                entity.position = start + (now - began)
            }
            .onEnded { value in
                dragStart = nil
                model.log("Moved \(value.entity.name)")
            }
    }

    private var magnifyCluster: some Gesture {
        MagnifyGesture()
            .targetedToAnyEntity()
            .onChanged { value in
                guard let root = clusterRoot(of: value.entity) else { return }
                stopSway(root)
                let start = scaleStart ?? root.scale.x
                if scaleStart == nil { scaleStart = start }
                let scale = min(max(start * Float(value.magnification), 0.4), 2.5)
                root.scale = SIMD3(repeating: scale)
            }
            .onEnded { _ in scaleStart = nil }
    }

    private var rotateCluster: some Gesture {
        RotateGesture3D(constrainedToAxis: .y)
            .targetedToAnyEntity()
            .onChanged { value in
                guard let root = clusterRoot(of: value.entity) else { return }
                stopSway(root)
                let start = rotationStart ?? root.orientation
                if rotationStart == nil { rotationStart = start }
                let sign: Float = value.rotation.axis.y < 0 ? -1 : 1
                let angle = Float(value.rotation.angle.radians) * sign
                root.orientation = simd_quatf(angle: angle, axis: [0, 1, 0]) * start
            }
            .onEnded { _ in rotationStart = nil }
    }

    // MARK: State → scene

    /// Pushes selection and live status from the model onto the entities.
    private func apply(to root: Entity, inspector: Entity?) {
        let topology = model.topology
        let selected = model.selectedID
        let related = selected.map { topology.neighbours(of: $0).union([$0]) }

        for node in topology.nodes {
            guard let endpoint = root.findEntity(named: node.id) else { continue }
            let status = model.status[node.id] ?? node.status

            if var info = endpoint.components[EndpointComponent.self], info.isServing != status.isServing {
                info.isServing = status.isServing
                endpoint.components.set(info)
            }
            let dimmed = related.map { !$0.contains(node.id) } ?? false
            endpoint.components.set(OpacityComponent(opacity: dimmed ? 0.25 : 1))

            if let body = NetworkSceneBuilder.body(of: endpoint) {
                let color = NetworkSceneBuilder.color(for: node.kind, status: status)
                body.model?.materials = [NetworkSceneBuilder.material(color)]
                if var pulse = body.components[PulseComponent.self] {
                    pulse.baseScale = node.id == selected ? 1.3 : 1
                    body.components.set(pulse)
                }
            }
        }

        for child in root.children {
            if var link = child.components[LinkComponent.self] {
                link.isDimmed = isDimmed(link.connectionID, selected: selected)
                child.components.set(link)
            }
            if var packet = child.components[PacketComponent.self] {
                packet.isDimmed = isDimmed(packet.connectionID, selected: selected)
                child.components.set(packet)
            }
        }

        // Inspector rides along with the selected endpoint.
        if let inspector {
            if let selected, let endpoint = root.findEntity(named: selected) {
                endpoint.addChild(inspector)
                inspector.position = [0.16, 0.0, 0.0]
                inspector.isEnabled = true
            } else {
                root.addChild(inspector)
                inspector.isEnabled = false
            }
        }
    }

    private func isDimmed(_ connectionID: String, selected: String?) -> Bool {
        guard let selected,
              let connection = model.topology.connections.first(where: { $0.id == connectionID }) else { return false }
        return connection.from != selected && connection.to != selected
    }

    private func clusterRoot(of entity: Entity) -> Entity? {
        var current: Entity? = entity
        while let e = current, e.name != NetworkSceneBuilder.rootName { current = e.parent }
        return current
    }

    private func stopSway(_ root: Entity) {
        guard root.components.has(SwayComponent.self) else { return }
        root.components.remove(SwayComponent.self)
    }
}
