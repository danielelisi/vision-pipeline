import ARKit
import QuartzCore
import RealityKit
import SwiftUI

/// Switch modes without looking away from the table: turn your left palm up and the
/// mode buttons appear just above it. Pinch one with your right hand, or touch it.
///
/// Uses ARKit hand tracking, which needs the app in a Full Space (the trail table's
/// immersive space) and `NSHandsTrackingUsageDescription` in Info.plist. Where hand
/// tracking is unavailable (the simulator, or permission denied) the window's mode
/// picker is the fallback.
@MainActor
final class PalmMenu {
    /// World-space entity that follows the left palm. Holds the SwiftUI menu attachment.
    let root = Entity()

    private let session = ARKitSession()
    private let hands = HandTrackingProvider()
    private var palmUpSince: TimeInterval?
    private var lastPalmUp: TimeInterval = 0

    /// Palm must face up this much (cosine with world up) to open, and stay above the lower value to stay open.
    private static let openThreshold: Float = 0.7
    private static let closeThreshold: Float = 0.45
    /// Hold the palm up this long before the menu opens, so it does not flash during other gestures.
    private static let openDelay: TimeInterval = 0.15
    /// Keep the menu this long after the palm turns away, so the other hand can still reach it.
    private static let closeDelay: TimeInterval = 0.5
    /// How far above the palm the menu floats, in metres.
    private static let lift: Float = 0.07

    init() {
        root.name = "palmMenu"
        root.isEnabled = false
    }

    func attach(menu: Entity) {
        menu.components.set(BillboardComponent())
        root.addChild(menu)
    }

    /// Runs hand tracking until the space closes. Returns straight away if it is not supported.
    func run() async {
        guard HandTrackingProvider.isSupported else { return }
        do {
            try await session.run([hands])
        } catch {
            print("TrailTable: hand tracking unavailable: \(error)")
            return
        }
        for await update in hands.anchorUpdates where update.anchor.chirality == .left {
            handle(update.anchor)
        }
    }

    private func handle(_ anchor: HandAnchor) {
        let now = CACurrentMediaTime()
        guard anchor.isTracked, let skeleton = anchor.handSkeleton else {
            palmUpSince = nil
            root.isEnabled = root.isEnabled && now - lastPalmUp < Self.closeDelay
            return
        }

        func world(_ joint: HandSkeleton.JointName) -> SIMD3<Float> {
            let m = anchor.originFromAnchorTransform * skeleton.joint(joint).anchorFromJointTransform
            return SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
        }
        let wrist = world(.wrist)
        let indexKnuckle = world(.indexFingerKnuckle)
        let middleKnuckle = world(.middleFingerKnuckle)
        let littleKnuckle = world(.littleFingerKnuckle)

        // For a left hand, (index - wrist) × (little - wrist) points out of the back of the hand.
        let cross = simd_cross(indexKnuckle - wrist, littleKnuckle - wrist)
        guard simd_length(cross) > 0.000001 else { return }
        let palmNormal = -simd_normalize(cross)
        let facingUp = simd_dot(palmNormal, [0, 1, 0])

        // Not while the left hand is pinching (for example during a two-hand Shape gesture).
        let pinching = simd_distance(world(.thumbTip), world(.indexFingerTip)) < 0.025
        let threshold = root.isEnabled ? Self.closeThreshold : Self.openThreshold
        let palmUp = !pinching && facingUp > threshold

        if palmUp {
            lastPalmUp = now
            if palmUpSince == nil { palmUpSince = now }
        } else {
            palmUpSince = nil
        }
        let opening = palmUpSince.map { now - $0 >= Self.openDelay } ?? false
        let staying = root.isEnabled && now - lastPalmUp < Self.closeDelay
        let show = opening || staying

        if show {
            let target = (wrist + middleKnuckle) / 2 + palmNormal * Self.lift
            // Ease toward the palm so tracking jitter does not shake the buttons.
            root.position = root.isEnabled ? root.position + (target - root.position) * 0.5 : target
        }
        root.isEnabled = show
    }
}

/// The buttons shown above the palm.
struct ModeMenu: View {
    @Environment(TrailModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            ForEach(TrailModel.Mode.allCases) { mode in
                Button {
                    model.mode = mode
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: mode.systemImage)
                            .font(.title2)
                        Text(mode.title)
                            .font(.callout.weight(.semibold))
                    }
                    .frame(width: 92, height: 76)
                    .background(mode == model.mode ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear),
                                in: .rect(cornerRadius: 18))
                    .contentShape(.rect(cornerRadius: 18))
                }
                .buttonStyle(.plain)
                .hoverEffect()
            }
        }
        .padding(10)
        .glassBackgroundEffect()
    }
}
