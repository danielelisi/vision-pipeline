import Foundation
import Observation
import simd

/// App state: the route being planned and how the table is being viewed.
@MainActor
@Observable
final class TrailModel {
    enum Mode: String, CaseIterable, Identifiable {
        case plan, move, shape

        var id: String { rawValue }

        var title: String {
            switch self {
            case .plan: "Plan"
            case .move: "Move"
            case .shape: "Shape"
            }
        }

        /// What to try in each mode.
        var hints: [String] {
            switch self {
            case .plan: [
                "Look at the terrain and pinch to drop a waypoint.",
                "Pinch a waypoint and drag to move it. The route follows the ground.",
                "Pinch a waypoint and hold still for a second to delete it.",
            ]
            case .move: [
                "Pinch the table with one hand to carry and turn it.",
                "Pinch with both hands and pull apart to resize it.",
                "Pass it from one hand to the other.",
            ]
            case .shape: [
                "Pinch with both hands and pull apart to exaggerate the mountains.",
                "Pinch with both hands and turn them like a wheel to spin the map.",
            ]
            }
        }
    }

    struct Waypoint: Identifiable, Equatable {
        let id: UUID
        var x: Float
        var z: Float
    }

    /// A point along the route, sampled about every 100 m of map distance.
    struct RouteSample {
        var x: Float
        var z: Float
        var distance: Float   // metres from the start
        var elevation: Float  // metres above sea level
    }

    struct Stats {
        var distanceKm: Double = 0
        var ascent: Double = 0
        var descent: Double = 0
        var hours: Double = 0

        var timeText: String {
            let minutes = Int((hours * 60).rounded())
            return minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h \(minutes % 60) min"
        }
    }

    struct ProfilePoint: Identifiable {
        let id: Int
        let km: Double
        let elevation: Double
    }

    static let immersiveSpaceID = "trailTable"
    static let exaggerationRange: ClosedRange<Float> = 0.5...3

    let terrain = Terrain()
    var waypoints: [Waypoint] = []
    var mode: Mode = .plan
    /// Vertical exaggeration of the terrain.
    var exaggeration: Float = 1.5
    /// Rotation of the map on its plinth, in radians.
    var heading: Float = 0
    /// Bumped to send the table back to its starting place.
    var resetToken = 0

    // MARK: - Editing

    func addWaypoint(x: Float, z: Float) {
        waypoints.append(Waypoint(id: UUID(), x: Terrain.clamp(x), z: Terrain.clamp(z)))
    }

    func moveWaypoint(_ id: UUID, x: Float, z: Float) {
        guard let index = waypoints.firstIndex(where: { $0.id == id }) else { return }
        waypoints[index].x = Terrain.clamp(x)
        waypoints[index].z = Terrain.clamp(z)
    }

    func removeWaypoint(_ id: UUID) {
        waypoints.removeAll { $0.id == id }
    }

    func undo() {
        if !waypoints.isEmpty { waypoints.removeLast() }
    }

    func clear() {
        waypoints.removeAll()
    }

    func resetTable() {
        heading = 0
        exaggeration = 1.5
        resetToken += 1
    }

    // MARK: - Derived route data

    var route: [RouteSample] {
        guard waypoints.count > 1 else { return [] }
        var samples: [RouteSample] = []
        var travelled: Float = 0
        var previous = SIMD2<Float>(waypoints[0].x, waypoints[0].z)

        for index in 1..<waypoints.count {
            let from = SIMD2<Float>(waypoints[index - 1].x, waypoints[index - 1].z)
            let to = SIMD2<Float>(waypoints[index].x, waypoints[index].z)
            let steps = max(1, Int((simd_distance(from, to) / 0.01).rounded(.up)))

            for step in (index == 1 ? 0 : 1)...steps {
                let point = from + (to - from) * (Float(step) / Float(steps))
                travelled += simd_distance(previous, point) * Terrain.metresPerUnit
                previous = point
                samples.append(RouteSample(
                    x: point.x,
                    z: point.y,
                    distance: travelled,
                    elevation: terrain.elevation(x: point.x, z: point.y)
                ))
            }
        }
        return samples
    }

    var stats: Stats {
        let samples = route
        guard let last = samples.last else { return Stats() }
        var result = Stats(distanceKm: Double(last.distance) / 1000)
        for index in 1..<samples.count {
            let change = Double(samples[index].elevation - samples[index - 1].elevation)
            if change > 0 { result.ascent += change } else { result.descent -= change }
        }
        // Naismith's rule: 5 km/h, plus one hour per 600 m of ascent. A rough estimate only.
        result.hours = result.distanceKm / 5 + result.ascent / 600
        return result
    }

    var profile: [ProfilePoint] {
        route.enumerated().map { index, sample in
            ProfilePoint(id: index, km: Double(sample.distance) / 1000, elevation: Double(sample.elevation))
        }
    }
}
