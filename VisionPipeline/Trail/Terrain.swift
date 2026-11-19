import Foundation
import simd

/// A procedural mountain diorama, so the app needs no map data or network.
///
/// The shape follows the reference diorama: a ridged peak at the back, a mossy
/// plateau, a V-shaped valley down to a notch in the cliff, and a waterfall into
/// a pool cut into the near-right corner of the block.
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
    /// Steep on purpose: the reference diorama's peak is nearly as tall as the block is wide.
    static let relief: Float = 3_000
    /// Normalised height of the pool surface (about a third of the way up the cut side).
    static let waterLevel: Float = 0.075
    /// Model metres per unit of normalised height, before vertical exaggeration.
    static let heightScale: Float = relief / metresPerUnit

    // Layout in normalised map coordinates (u: left → right, v: far → near).
    /// Valley from the mountain's foot (start) to the notch in the pool cliff (end).
    static let valleyStart = SIMD2<Float>(0.40, 0.34)
    static let valleyEnd = SIMD2<Float>(0.515, 0.676)
    /// Inner corner of the pool, which fills everything right of and nearer than this.
    static let poolCorner = SIMD2<Float>(0.50, 0.66)
    static let poolCornerRadius: Float = 0.06

    /// Where the waterfall leaves the cliff, in table space, and how high (normalised).
    struct Waterfall {
        var lip: SIMD2<Float>
        var lipHeight: Float
        /// Where it lands in the pool, in table space.
        var impact: SIMD2<Float>
    }

    let resolution: Int
    /// The walkable surface: ground, or the water surface over the pool.
    /// Row-major, `heights[z * resolution + x]`.
    let heights: [Float]
    /// The ground itself, including the pool bed.
    let ground: [Float]
    let waterfall: Waterfall
    let seed: UInt32

    init(resolution: Int = 257, seed: UInt32 = 11) {
        self.resolution = resolution
        self.seed = seed
        let n = resolution
        let last = Float(n - 1)

        // Pass 1: the mountain on its own, so it can be normalised to reach exactly 1.
        var mountain = [Float](repeating: 0, count: n * n)
        var highest: Float = 0.0001
        for z in 0..<n {
            for x in 0..<n {
                let m = Terrain.mountain(u: Float(x) / last, v: Float(z) / last, seed: seed)
                mountain[z * n + x] = m
                highest = max(highest, m)
            }
        }

        // Pass 2: plateau + mountain, then carve the valley and the pool.
        var ground = [Float](repeating: 0, count: n * n)
        for z in 0..<n {
            for x in 0..<n {
                let u = Float(x) / last
                let v = Float(z) / last
                let plateau = Terrain.plateau(u: u, v: v, seed: seed)
                var h = plateau + (1 - 0.40) * mountain[z * n + x] / highest
                h = Terrain.carveValley(h, u: u, v: v, seed: seed)
                h = Terrain.carvePool(h, u: u, v: v, seed: seed)
                ground[z * n + x] = h
            }
        }
        self.ground = ground
        heights = ground.map { max($0, Terrain.waterLevel) }

        waterfall = Terrain.findWaterfall(ground: ground, resolution: n, seed: seed)
    }

    // MARK: - Sampling

    static func clamp(_ value: Float) -> Float {
        min(max(value, -size / 2), size / 2)
    }

    /// Bilinear sample of the normalised surface height at a table-space position.
    func normalisedHeight(x: Float, z: Float) -> Float {
        Terrain.bilinear(heights, resolution, u: (Terrain.clamp(x) + Terrain.size / 2) / Terrain.size,
                         v: (Terrain.clamp(z) + Terrain.size / 2) / Terrain.size)
    }

    /// Bilinear sample of the normalised ground height (pool bed included) at map coordinates 0...1.
    func groundHeight(u: Float, v: Float) -> Float {
        Terrain.bilinear(ground, resolution, u: u, v: v)
    }

    /// Height above the terrain base in model metres (before vertical exaggeration).
    func modelHeight(x: Float, z: Float) -> Float {
        normalisedHeight(x: x, z: z) * Terrain.heightScale
    }

    /// Real-world elevation in metres.
    func elevation(x: Float, z: Float) -> Float {
        Terrain.baseElevation + normalisedHeight(x: x, z: z) * Terrain.relief
    }

    static func bilinear(_ grid: [Float], _ n: Int, u: Float, v: Float) -> Float {
        let last = Float(n - 1)
        let gx = min(max(u, 0), 1) * last
        let gz = min(max(v, 0), 1) * last
        let x0 = min(Int(gx), n - 2)
        let z0 = min(Int(gz), n - 2)
        let tx = gx - Float(x0)
        let tz = gz - Float(z0)
        let a = grid[z0 * n + x0]
        let b = grid[z0 * n + x0 + 1]
        let c = grid[(z0 + 1) * n + x0]
        let d = grid[(z0 + 1) * n + x0 + 1]
        return lerp(lerp(a, b, tx), lerp(c, d, tx), tz)
    }

    /// Table-space position for map coordinates 0...1.
    static func tablePosition(u: Float, v: Float) -> SIMD2<Float> {
        SIMD2((u - 0.5) * size, (v - 0.5) * size)
    }

    // MARK: - Shape

    /// Rolling moss plateau, rising gently toward the mountain.
    private static func plateau(u: Float, v: Float, seed: UInt32) -> Float {
        0.355 + 0.03 * (1 - v) + 0.02 * (fbm(u * 5, v * 5, seed: seed &+ 7) - 0.5)
    }

    /// Ridged massif: main peak left of centre at the back, shoulders to either side.
    private static func mountain(u: Float, v: Float, seed: UInt32) -> Float {
        let mask = max(
            cone(u, v, centre: [0.40, 0.22], radius: 0.50),
            0.80 * cone(u, v, centre: [0.80, 0.26], radius: 0.36),
            0.62 * cone(u, v, centre: [0.12, 0.30], radius: 0.32)
        )
        guard mask > 0 else { return 0 }
        let ridges = ridged(u * 3.0, v * 3.0, seed: seed &+ 3)
        let crags = ridged(u * 9, v * 9, seed: seed &+ 5)
        let m = mask * (0.30 + 0.95 * ridges) + 0.16 * mask * crags
        return powf(max(m, 0), 1.15)
    }

    /// V-shaped valley that drains the plateau toward the notch in the pool cliff.
    private static func carveValley(_ h: Float, u: Float, v: Float, seed: UInt32) -> Float {
        let (distance, t) = segment(SIMD2(u, v), valleyStart, valleyEnd)
        let floor = lerp(0.46, 0.325, t) + 0.006 * (noise(u * 30, v * 30, seed: seed &+ 9) - 0.5)
        // Gentle mossy floor, then rocky, gullied flanks.
        let flank = 0.30 * distance + 1.1 * max(distance - 0.05, 0)
            + 0.07 * smoothstep(0.02, 0.08, distance) * (ridged(u * 14, v * 14, seed: seed &+ 21) - 0.3)
        return min(h, floor + flank)
    }

    /// Signed distance to the pool's edge in map units: negative inside the pool.
    static func poolDistance(u: Float, v: Float, seed: UInt32) -> Float {
        let r = poolCornerRadius
        let p = SIMD2<Float>(poolCorner.x - u, poolCorner.y - v) // > 0 on the plateau side
        let outside = simd_length(simd_max(p + r, .zero))
        let inside = min(max(p.x + r, p.y + r), 0)
        let wobble = 0.010 * (fbm(u * 14, v * 14, seed: seed &+ 13) - 0.5)
        return outside + inside - r + wobble
    }

    /// Sheer cliff from the plateau down to the pool bed.
    private static func carvePool(_ h: Float, u: Float, v: Float, seed: UInt32) -> Float {
        let d = poolDistance(u: u, v: v, seed: seed)
        let cliff = smoothstep(0.0, 0.016, d)
        guard cliff < 1 else { return h }
        let bed = 0.008 + 0.02 * fbm(u * 8, v * 8, seed: seed &+ 17)
        // A little jagged rock on the cliff face itself.
        let jag = 0.03 * cliff * (1 - cliff) * 4 * (ridged(u * 40, v * 40, seed: seed &+ 19) - 0.5)
        return bed + (h - bed) * cliff + jag
    }

    /// Walks down the valley to the last point still on the cliff top: the waterfall lip.
    private static func findWaterfall(ground: [Float], resolution n: Int, seed: UInt32) -> Waterfall {
        var lipUV = valleyEnd
        for step in 0...200 {
            let t = Float(step) / 200
            let p = valleyStart + (valleyEnd - valleyStart) * (t * 1.2)
            if poolDistance(u: p.x, v: p.y, seed: seed) < 0.014 { break }
            lipUV = p
        }
        let lipHeight = bilinear(ground, n, u: lipUV.x, v: lipUV.y)
        return Waterfall(
            lip: tablePosition(u: lipUV.x, v: lipUV.y),
            lipHeight: lipHeight,
            impact: tablePosition(u: lipUV.x, v: lipUV.y + 0.03)
        )
    }

    /// Distance from a point to the valley line, and how far along it (0...1) the nearest point is.
    static func valleyDistance(u: Float, v: Float) -> (distance: Float, along: Float) {
        segment(SIMD2(u, v), valleyStart, valleyEnd)
    }

    // MARK: - Noise

    static func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float {
        a + (b - a) * t
    }

    static func smoothstep(_ edge0: Float, _ edge1: Float, _ x: Float) -> Float {
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// Smooth cone: 1 at the centre, 0 at `radius`. Steeper than a dome, for craggy peaks.
    private static func cone(_ u: Float, _ v: Float, centre: SIMD2<Float>, radius: Float) -> Float {
        let d = simd_length(SIMD2(u, v) - centre) / radius
        let f = max(0, 1 - d)
        return f * f * (3 - 2 * f)
    }

    private static func segment(_ p: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>) -> (Float, Float) {
        let ab = b - a
        let t = min(max(simd_dot(p - a, ab) / simd_dot(ab, ab), 0), 1)
        return (simd_length(p - (a + ab * t)), t)
    }

    private static func lattice(_ x: Int, _ y: Int, _ seed: UInt32) -> Float {
        var h = UInt32(truncatingIfNeeded: x) &* 374_761_393
        h = h &+ UInt32(truncatingIfNeeded: y) &* 668_265_263
        h = h &+ seed &* 2_246_822_519
        h = (h ^ (h >> 13)) &* 1_274_126_177
        h ^= h >> 16
        return Float(h & 0xFFFF) / 65_535
    }

    /// Smooth value noise in 0...1. With `period`, it tiles every `period` units.
    static func noise(_ x: Float, _ y: Float, seed: UInt32, period: Int = 0) -> Float {
        var x0 = Int(x.rounded(.down))
        var y0 = Int(y.rounded(.down))
        let fx = x - Float(x0)
        let fy = y - Float(y0)
        var x1 = x0 + 1
        var y1 = y0 + 1
        if period > 0 {
            x0 = ((x0 % period) + period) % period
            y0 = ((y0 % period) + period) % period
            x1 = (x0 + 1) % period
            y1 = (y0 + 1) % period
        }
        let sx = fx * fx * (3 - 2 * fx)
        let sy = fy * fy * (3 - 2 * fy)
        let top = lerp(lattice(x0, y0, seed), lattice(x1, y0, seed), sx)
        let bottom = lerp(lattice(x0, y1, seed), lattice(x1, y1, seed), sx)
        return lerp(top, bottom, sy)
    }

    /// Fractal value noise in roughly 0...1.
    static func fbm(_ x: Float, _ y: Float, seed: UInt32, octaves: Int = 5) -> Float {
        var sum: Float = 0
        var amplitude: Float = 0.5
        var frequency: Float = 1
        var norm: Float = 0
        for octave in 0..<octaves {
            sum += amplitude * noise(x * frequency, y * frequency, seed: seed &+ UInt32(octave) &* 101)
            norm += amplitude
            amplitude *= 0.5
            frequency *= 2
        }
        return sum / norm
    }

    /// Ridged multifractal noise in roughly 0...1: sharp crests and gullies, for cliffs.
    /// Each octave is rotated so the crests do not line up with the noise lattice.
    static func ridged(_ x: Float, _ y: Float, seed: UInt32, octaves: Int = 6) -> Float {
        var sum: Float = 0
        var norm: Float = 0
        var amplitude: Float = 0.5
        var weight: Float = 1
        var px = x
        var py = y
        for octave in 0..<octaves {
            let n = noise(px, py, seed: seed &+ UInt32(octave) &* 131)
            var ridge = 1 - abs(2 * n - 1)
            ridge *= ridge
            ridge *= weight
            weight = min(max(ridge * 1.8, 0), 1)
            sum += ridge * amplitude
            norm += amplitude
            amplitude *= 0.5
            // Rotate by ~37° and double the frequency.
            let rx = (px * 0.8 - py * 0.6) * 2.02
            let ry = (px * 0.6 + py * 0.8) * 2.02
            px = rx + 17.3
            py = ry + 9.1
        }
        return sum / norm
    }
}
