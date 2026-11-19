import Foundation

/// A procedural mountain heightfield, so the app needs no map data or network.
///
/// Table space: x runs left to right, z runs far (-) to near (+), both within
/// `-size/2 ... size/2`. Heights are stored normalised to 0...1.
struct Terrain {
    /// Edge length of the table model, in metres.
    static let size: Float = 0.8
    /// Map scale 1:10,000, so the table covers an 8 km x 8 km area.
    static let metresPerUnit: Float = 10_000
    /// Real-world elevation of the lowest point, in metres.
    static let baseElevation: Float = 200
    /// Real-world height difference between lowest and highest point, in metres.
    static let relief: Float = 2_000
    /// Normalised height of the lake surface.
    static let waterLevel: Float = 0.14

    enum Band: Int, CaseIterable {
        case water, meadow, forest, rock, scree, snow
    }

    let resolution: Int
    /// Row-major, `heights[z * resolution + x]`.
    let heights: [Float]

    init(resolution: Int = 97, seed: UInt32 = 11) {
        self.resolution = resolution
        var raw = [Float](repeating: 0, count: resolution * resolution)
        var lowest = Float.greatestFiniteMagnitude
        var highest = -Float.greatestFiniteMagnitude

        for z in 0..<resolution {
            for x in 0..<resolution {
                let u = Float(x) / Float(resolution - 1)
                let v = Float(z) / Float(resolution - 1)
                // Noise plus a tilt, so the summit is at the far side and the trailhead near you.
                let h = Terrain.fbm(u * 3.2, v * 3.2, seed: seed) + 0.35 * (1 - v) + 0.1 * u
                raw[z * resolution + x] = h
                lowest = min(lowest, h)
                highest = max(highest, h)
            }
        }

        let span = max(highest - lowest, 0.0001)
        heights = raw.map { value in
            let normalised = (value - lowest) / span
            return max(powf(normalised, 1.4), Terrain.waterLevel) // flatten valleys, fill the lake
        }
    }

    // MARK: - Sampling

    static func clamp(_ value: Float) -> Float {
        min(max(value, -size / 2), size / 2)
    }

    /// Bilinear sample of the normalised height at a table-space position.
    func normalisedHeight(x: Float, z: Float) -> Float {
        let last = Float(resolution - 1)
        let gx = (Terrain.clamp(x) + Terrain.size / 2) / Terrain.size * last
        let gz = (Terrain.clamp(z) + Terrain.size / 2) / Terrain.size * last
        let x0 = min(Int(gx), resolution - 2)
        let z0 = min(Int(gz), resolution - 2)
        let tx = gx - Float(x0)
        let tz = gz - Float(z0)

        let a = heights[z0 * resolution + x0]
        let b = heights[z0 * resolution + x0 + 1]
        let c = heights[(z0 + 1) * resolution + x0]
        let d = heights[(z0 + 1) * resolution + x0 + 1]
        return Terrain.lerp(Terrain.lerp(a, b, tx), Terrain.lerp(c, d, tx), tz)
    }

    /// Height above the table surface in model metres (before vertical exaggeration).
    func modelHeight(x: Float, z: Float) -> Float {
        normalisedHeight(x: x, z: z) * Terrain.relief / Terrain.metresPerUnit
    }

    /// Real-world elevation in metres.
    func elevation(x: Float, z: Float) -> Float {
        Terrain.baseElevation + normalisedHeight(x: x, z: z) * Terrain.relief
    }

    static func band(for normalisedHeight: Float) -> Band {
        switch normalisedHeight {
        case ...(waterLevel + 0.002): return .water
        case ..<0.30: return .meadow
        case ..<0.50: return .forest
        case ..<0.68: return .rock
        case ..<0.84: return .scree
        default: return .snow
        }
    }

    // MARK: - Noise

    private static func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float {
        a + (b - a) * t
    }

    private static func lattice(_ x: Int, _ y: Int, _ seed: UInt32) -> Float {
        var h = UInt32(truncatingIfNeeded: x) &* 374_761_393
        h = h &+ UInt32(truncatingIfNeeded: y) &* 668_265_263
        h = h &+ seed &* 2_246_822_519
        h = (h ^ (h >> 13)) &* 1_274_126_177
        h ^= h >> 16
        return Float(h & 0xFFFF) / 65_535
    }

    private static func noise(_ x: Float, _ y: Float, seed: UInt32) -> Float {
        let x0 = Int(x.rounded(.down))
        let y0 = Int(y.rounded(.down))
        let fx = x - Float(x0)
        let fy = y - Float(y0)
        let sx = fx * fx * (3 - 2 * fx)
        let sy = fy * fy * (3 - 2 * fy)
        let top = lerp(lattice(x0, y0, seed), lattice(x0 + 1, y0, seed), sx)
        let bottom = lerp(lattice(x0, y0 + 1, seed), lattice(x0 + 1, y0 + 1, seed), sx)
        return lerp(top, bottom, sy)
    }

    private static func fbm(_ x: Float, _ y: Float, seed: UInt32) -> Float {
        var sum: Float = 0
        var amplitude: Float = 0.5
        var frequency: Float = 1
        for octave in 0..<5 {
            sum += amplitude * noise(x * frequency, y * frequency, seed: seed &+ UInt32(octave) &* 101)
            amplitude *= 0.5
            frequency *= 2
        }
        return sum
    }
}
