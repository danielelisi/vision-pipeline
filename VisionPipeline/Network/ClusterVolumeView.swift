import RealityKit
import SwiftUI

/// Volumetric window showing the animated cluster.
struct ClusterVolumeView: View {
    @Environment(AppModel.self) private var model
    private let topology = ClusterTopology.sample

    var body: some View {
        RealityView { content, attachments in
            let root = NetworkSceneBuilder.makeRoot(for: topology)
            content.add(root)

            // Floating name tags above each endpoint, always facing the viewer.
            for node in topology.nodes {
                guard let label = attachments.entity(for: node.id) else { continue }
                label.position = node.position + [0, 0.042, 0]
                label.components.set(BillboardComponent())
                root.addChild(label)
            }
        } attachments: {
            ForEach(topology.nodes) { node in
                Attachment(id: node.id) {
                    Text(node.id)
                        .font(.caption)
                        .monospaced()
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .glassBackgroundEffect()
                }
            }
        }
        .onAppear { model.isClusterOpen = true }
        .onDisappear { model.isClusterOpen = false }
    }
}
