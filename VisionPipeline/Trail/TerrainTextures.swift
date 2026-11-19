import CoreGraphics
import Foundation
import RealityKit
import UIKit

/// Colours sampled from the reference diorama image (sRGB), used as albedo.
/// Each material has a dark (shadowed), mid and light (sunlit tips) tone.
enum DioramaPalette {
    typealias RGB = SIMD3<Float>
    private static func rgb(_ r: Float, _ g: Float, _ b: Float) -> RGB { RGB(r, g, b) / 255 }

    static let mossDark = rgb(48, 60, 14)
    static let mossMid = rgb(118, 128, 38)
    static let mossLight = rgb(165, 172, 62)
    static let basaltDark = rgb(30, 36, 34)
    static let basaltMid = rgb(62, 65, 60)
    static let basaltLight = rgb(100, 100, 91)
    static let strataDark = rgb(24, 27, 27)
    static let strataMid = rgb(58, 58, 56)
    static let strataLight = rgb(96, 91, 84)
    static let strataWarm = rgb(78, 68, 58)
    static let soilDark = rgb(66, 57, 45)
    static let soilMid = rgb(108, 91, 72)
    static let soilLight = rgb(141, 119, 94)
    static let bedDark = rgb(20, 24, 22)
    static let bedLight = rgb(52, 50, 38)
    static let stream = rgb(30, 60, 62)
    static let water = rgb(14, 44, 48)
    static let waterSide = rgb(40, 78, 77)
}

/// An RGBA8 image filled from many threads at once (each thread writes its own rows).
final class PixelBuffer: @unchecked Sendable {
    let width: Int
    let height: Int
    private let bytes: UnsafeMutablePointer<UInt8>

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        bytes = .allocate(capacity: width * height * 4)
        bytes.initialize(repeating: 255, count: width * height * 4)
    }

    deinit { bytes.deallocate() }

    private static func byte(_ value: Float) -> UInt8 {
        guard value.isFinite else { return 0 }
        return UInt8(min(max(value, 0), 1) * 255 + 0.5)
    }

    func set(_ x: Int, _ y: Int, _ rgb: SIMD3<Float>) {
        let i = (y * width + x) * 4
        bytes[i] = Self.byte(rgb.x)
        bytes[i + 1] = Self.byte(rgb.y)
        bytes[i + 2] = Self.byte(rgb.z)
    }

    func set(_ x: Int, _ y: Int, gray: Float) {
        set(x, y, SIMD3(repeating: gray))
    }

    /// `srgb`: colour data (gamma-encoded). Otherwise linear data such as normals or roughness.
    func makeImage(srgb: Bool) -> CGImage? {
        let space = srgb ? CGColorSpace(name: CGColorSpace.sRGB) : CGColorSpace(name: CGColorSpace.linearSRGB)
        guard let space,
              let provider = CGDataProvider(data: Data(bytes: bytes, count: width * height * 4) as CFData)
        else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }
}

/// A float image, for the detail height a normal map is derived from.
final class FloatBuffer: @unchecked Sendable {
    let width: Int
    let height: Int
    private let values: UnsafeMutablePointer<Float>

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        values = .allocate(capacity: width * height)
        values.initialize(repeating: 0, count: width * height)
    }

    deinit { values.deallocate() }

    subscript(x: Int, y: Int) -> Float {
        get { values[y * width + x] }
        set { values[y * width + x] = newValue }
    }

    /// Writes a tangent-space normal map (z out of the surface) from this height into `target`.
    /// `wrapX` / `wrapY`: the image tiles in that direction (walls run around the block; ripples tile).
    func writeNormals(into target: PixelBuffer, strength: Float, wrapX: Bool, wrapY: Bool = false) {
        DispatchQueue.concurrentPerform(iterations: height) { y in
            let up = wrapY ? (y - 1 + height) % height : max(y - 1, 0)
            let down = wrapY ? (y + 1) % height : min(y + 1, height - 1)
            for x in 0..<width {
                let left = wrapX ? (x - 1 + width) % width : max(x - 1, 0)
                let right = wrapX ? (x + 1) % width : min(x + 1, width - 1)
                let dx = (self[right, y] - self[left, y]) * strength
                // Image rows run down while +v runs up, so a height rise down the image tilts toward -v.
                let dv = (self[x, up] - self[x, down]) * strength
                let n = simd_normalize(SIMD3<Float>(-dx, -dv, 1))
                target.set(x, y, n * 0.5 + 0.5)
            }
        }
    }
}

/// Bakes the diorama's textures from the heightfield, off the main thread.
enum TerrainTextures {
    struct Maps: Sendable {
        let color: PixelBuffer
        let normal: PixelBuffer
        let roughness: PixelBuffer
    }

    struct Baked: Sendable {
        let top: Maps
        let walls: Maps
        let ripples: PixelBuffer
    }

    static let topSize = 2048
    static let wallWidth = 4096
    static let wallHeight = 512
    static let rippleSize = 512

    static func bake(_ terrain: Terrain, exaggeration: Float) -> Baked {
        let fields = Fields(terrain, exaggeration: exaggeration)
        return Baked(
            top: bakeTop(terrain, fields: fields),
            walls: bakeWalls(terrain, fields: fields),
            ripples: bakeRipples()
        )
    }

    // MARK: - Grid fields

    /// Per-grid-point slope, curvature and ambient occlusion, at the exaggeration the textures are baked for.
    struct Fields {
        let n: Int
        /// Slope angle, 0 (flat) ... 1 (vertical).
        var slope: [Float]
        /// Discrete Laplacian of height: > 0 in hollows and gullies, < 0 on ridges.
        var curvature: [Float]
        /// 1 = open sky, lower in gullies and at the foot of cliffs.
        var occlusion: [Float]

        init(_ terrain: Terrain, exaggeration: Float) {
            let n = terrain.resolution
            self.n = n
            let cell = Terrain.size / Float(n - 1)
            let scale = Terrain.heightScale * exaggeration
            let ground = terrain.ground
            func h(_ x: Int, _ z: Int) -> Float {
                ground[min(max(z, 0), n - 1) * n + min(max(x, 0), n - 1)] * scale
            }

            var slope = [Float](repeating: 0, count: n * n)
            var curvature = [Float](repeating: 0, count: n * n)
            var occlusion = [Float](repeating: 1, count: n * n)
            let directions: [SIMD2<Float>] = (0..<8).map { i in
                let a = Float(i) * .pi / 4
                return [cos(a), sin(a)]
            }
            let steps = [1, 2, 3, 5, 8, 12, 18, 26, 36]

            slope.withUnsafeMutableBufferPointer { slopeBuffer in
                curvature.withUnsafeMutableBufferPointer { curvatureBuffer in
                    occlusion.withUnsafeMutableBufferPointer { occlusionBuffer in
                        let slopeOut = slopeBuffer.baseAddress!
                        let curvatureOut = curvatureBuffer.baseAddress!
                        let occlusionOut = occlusionBuffer.baseAddress!
                        DispatchQueue.concurrentPerform(iterations: n) { z in
                            for x in 0..<n {
                                let dx = (h(x + 1, z) - h(x - 1, z)) / (2 * cell)
                                let dz = (h(x, z + 1) - h(x, z - 1)) / (2 * cell)
                                slopeOut[z * n + x] = atan((dx * dx + dz * dz).squareRoot()) / (.pi / 2)
                                curvatureOut[z * n + x] =
                                    (h(x + 1, z) + h(x - 1, z) + h(x, z + 1) + h(x, z - 1) - 4 * h(x, z)) / cell

                                // Horizon-based ambient occlusion over 8 directions.
                                let h0 = h(x, z)
                                var occluded: Float = 0
                                for direction in directions {
                                    var steepest: Float = 0
                                    for k in steps {
                                        let sx = Int((Float(x) + direction.x * Float(k)).rounded())
                                        let sz = Int((Float(z) + direction.y * Float(k)).rounded())
                                        guard sx >= 0, sx < n, sz >= 0, sz < n else { break }
                                        steepest = max(steepest, (h(sx, sz) - h0) / (Float(k) * cell))
                                    }
                                    occluded += sin(atan(steepest))
                                }
                                occlusionOut[z * n + x] = 1 - occluded / Float(directions.count)
                            }
                        }
                    }
                }
            }
            self.slope = slope
            self.curvature = curvature
            self.occlusion = occlusion
        }

        func sample(_ grid: [Float], u: Float, v: Float) -> Float {
            Terrain.bilinear(grid, n, u: u, v: v)
        }
    }

    // MARK: - Top surface

    private static func mix(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ t: Float) -> SIMD3<Float> {
        a + (b - a) * min(max(t, 0), 1)
    }

    private static func noise(_ x: Float, _ y: Float, _ seed: UInt32) -> Float {
        Terrain.noise(x, y, seed: seed)
    }

    private static func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
        Terrain.smoothstep(a, b, x)
    }

    /// Slope-based colouring: basalt on steep faces, moss on gentle ground, blended with noise.
    private static func bakeTop(_ terrain: Terrain, fields: Fields) -> Maps {
        let size = topSize
        let color = PixelBuffer(width: size, height: size)
        let roughness = PixelBuffer(width: size, height: size)
        let detail = FloatBuffer(width: size, height: size)
        let water = Terrain.waterLevel
        let fall = terrain.waterfall
        let splashCentre = SIMD2<Float>(fall.impact.x / Terrain.size + 0.5, fall.impact.y / Terrain.size + 0.5)

        DispatchQueue.concurrentPerform(iterations: size) { py in
            let v = (Float(py) + 0.5) / Float(size) // image row 0 = far edge = v 0 in map space
            for px in 0..<size {
                let u = (Float(px) + 0.5) / Float(size)
                let g = terrain.groundHeight(u: u, v: v)
                let occlusion = fields.sample(fields.occlusion, u: u, v: v)
                var rgb: SIMD3<Float>
                var rough: Float
                var bump: Float

                if g < water - 0.002 {
                    // Pool bed: darker with depth.
                    let depth = (water - g) / water
                    rgb = mix(DioramaPalette.bedLight, DioramaPalette.bedDark,
                              smoothstep(0.1, 0.8, depth) + 0.3 * (noise(u * 60, v * 60, 61) - 0.5))
                    rgb *= 0.6 + 0.4 * occlusion
                    rough = 0.5
                    bump = 0.3 * noise(u * 400, v * 400, 62)
                } else {
                    let slope = fields.sample(fields.slope, u: u, v: v)
                    let curvature = fields.sample(fields.curvature, u: u, v: v)

                    // Basalt where it is steep, on sharp ridges, and toward the summit.
                    let rockiness = smoothstep(
                        0.40, 0.60,
                        slope + 0.22 * (noise(u * 40, v * 40, 23) - 0.5)
                            + 0.5 * max(-curvature, 0) + 0.12 * max(g - 0.75, 0) / 0.25
                    )

                    // Moss: soft cushions, brighter on their tops, dark in the hollows between.
                    let clumps = 0.6 * noise(u * 140, v * 140, 29) + 0.4 * noise(u * 60, v * 60, 30)
                    let cushion = smoothstep(0.35, 0.75, clumps)
                    var moss = mix(DioramaPalette.mossMid, DioramaPalette.mossLight,
                                   cushion * 0.75 + 0.25 * noise(u * 25, v * 25, 31))
                    moss = mix(DioramaPalette.mossDark, moss, smoothstep(-0.10, 0.35, -curvature * 2 + cushion * 0.5))
                    let mossBump = 0.55 * cushion + 0.3 * noise(u * 520, v * 520, 32) + 0.15 * noise(u * 1100, v * 1100, 33)

                    // Basalt: streaky (it stretches down steep faces into column-like streaks), with lichen.
                    let streak = 0.6 * noise(u * 170, v * 170, 37) + 0.4 * noise(u * 420, v * 420, 38)
                    var rock = mix(DioramaPalette.basaltDark, DioramaPalette.basaltMid, streak)
                    if 0.7 * noise(u * 90, v * 90, 41) + 0.3 * noise(u * 500, v * 500, 42) > 0.72 {
                        rock = mix(rock, DioramaPalette.basaltLight, 0.55)
                    }
                    let rockBump = 0.6 * streak + 0.4 * noise(u * 900, v * 900, 39)

                    rgb = mix(moss, rock, rockiness)
                    rough = Terrain.lerp(0.92, 0.72 - 0.12 * streak, rockiness)
                    bump = Terrain.lerp(mossBump, rockBump * 1.4, rockiness)

                    // Wet: the shoreline, the stream down the valley floor, and the splash zone.
                    let shore = 1 - smoothstep(water, water + 0.025, g)
                    let (valleyDistance, along) = Terrain.valleyDistance(u: u, v: v)
                    let stream = (1 - smoothstep(0.0025, 0.005, valleyDistance)) * smoothstep(0.25, 0.5, along)
                    let splash = 1 - smoothstep(0.02, 0.06, simd_length(SIMD2(u, v) - splashCentre))
                    rgb = mix(rgb, rgb * 0.55, max(shore, splash * 0.6))
                    rgb = mix(rgb, DioramaPalette.stream, stream * 0.85)
                    rough = min(rough, Terrain.lerp(1, 0.3, max(shore, stream, splash)))
                    bump *= 1 - stream

                    rgb *= 0.45 + 0.55 * occlusion
                }

                color.set(px, py, rgb)
                roughness.set(px, py, gray: rough)
                detail[px, py] = bump
            }
        }

        let normal = PixelBuffer(width: size, height: size)
        detail.writeNormals(into: normal, strength: 3, wrapX: false)
        return Maps(color: color, normal: normal, roughness: roughness)
    }

    // MARK: - Cut sides

    /// Horizontal strata with a moss fringe under the edge, a basalt cliff band, and a soil band at the bottom.
    /// x runs once around the block (near, right, far, left); row 0 is `wallSpan` above the bottom.
    private static func bakeWalls(_ terrain: Terrain, fields: Fields) -> Maps {
        let width = wallWidth
        let height = wallHeight
        let color = PixelBuffer(width: width, height: height)
        let roughness = PixelBuffer(width: width, height: height)
        let detail = FloatBuffer(width: width, height: height)
        let span = DioramaMesh.wallSpan
        let base = DioramaMesh.baseDepth
        let water = Terrain.waterLevel

        // The terrain profile along the perimeter, one value per column.
        var tops = [Float](repeating: 0, count: width)
        var flooded = [Bool](repeating: false, count: width)
        for px in 0..<width {
            let p = (Float(px) + 0.5) / Float(width) * 4
            let side = min(Int(p), 3)
            let f = p - Float(side)
            let (u, v): (Float, Float) = switch side {
            case 0: (f, 1)
            case 1: (1, 1 - f)
            case 2: (1 - f, 0)
            default: (0, f)
            }
            let g = terrain.groundHeight(u: u, v: v)
            tops[px] = base + g * Terrain.heightScale
            flooded[px] = g < water
        }

        DispatchQueue.concurrentPerform(iterations: height) { py in
            let y = (1 - (Float(py) + 0.5) / Float(height)) * span // metres above the bottom, at exaggeration 1
            for px in 0..<width {
                let q = Float(px) / Float(width) * 4                 // perimeter coordinate for noise
                let depth = tops[px] - y                              // metres below this column's top edge
                var rgb: SIMD3<Float>
                var rough: Float = 0.82
                var bump: Float = 0

                let soilTop = 0.034 + 0.006 * (Terrain.fbm(q * 10, 0.5, seed: 43) - 0.5)
                if y < soilTop {
                    // Soil band: light at the very bottom, darker and wetter up toward the rock.
                    rgb = mix(DioramaPalette.soilLight, DioramaPalette.soilDark, smoothstep(0, soilTop, y) * 0.9)
                    rgb = mix(rgb, DioramaPalette.soilMid, 0.4 * noise(q * 80, y * 300, 44))
                    let pebble = noise(q * 260, y * 900, 47)
                    if pebble > 0.80 { rgb = mix(rgb, DioramaPalette.soilLight, 0.7) }
                    rough = 0.95
                    bump = 0.4 * noise(q * 700, y * 2000, 45) + (pebble > 0.80 ? 0.6 : 0)
                } else {
                    // Strata: wavy layers of differing tone, with dark partings between them.
                    let layer = y * 95 + 0.9 * Terrain.fbm(q * 6, y * 14, seed: 53)
                    let band = layer - layer.rounded(.down)
                    let id = Int(layer.rounded(.down))
                    let tone = Terrain.noise(Float(id) * 7.31, 0.5, seed: 59)
                    rgb = mix(DioramaPalette.strataDark, DioramaPalette.strataMid, 0.15 + 0.85 * tone)
                    if Terrain.noise(Float(id) * 3.7, 2.5, seed: 60) > 0.7 {
                        rgb = mix(rgb, DioramaPalette.strataWarm, 0.6)
                    }
                    rgb = mix(rgb, DioramaPalette.strataLight, 0.45 * max(0, noise(q * 140, y * 700, 57) - 0.55) / 0.45)
                    bump = 0.5 * tone + 0.3 * noise(q * 600, y * 1500, 58)
                    if band < 0.07 {
                        rgb = mix(rgb, DioramaPalette.strataDark, 0.8)
                        bump -= 0.6
                    }
                    if y < soilTop + 0.012 { rgb = mix(rgb, DioramaPalette.soilDark, 0.5) }

                    // Basalt cliff with vertical joints just under the edge.
                    let cliff = 0.05 + 0.02 * (noise(q * 12, 0.3, 63) - 0.5)
                    if depth < cliff && !flooded[px] {
                        let joint = noise(q * 700, y * 25, 67)
                        rgb = mix(DioramaPalette.basaltDark, DioramaPalette.basaltMid, noise(q * 300, y * 90, 68))
                        bump = 0.6 * noise(q * 300, y * 90, 68)
                        if abs(joint - 0.5) < 0.05 {
                            rgb = mix(rgb, DioramaPalette.strataDark, 0.8)
                            bump -= 0.7
                        }
                        rough = 0.75
                    }

                    // Mossy ledges here and there.
                    if y > soilTop + 0.02 && noise(q * 30, y * 40, 77) > 0.80 {
                        rgb = mix(rgb, DioramaPalette.mossDark, 0.7)
                        rough = 0.9
                    }
                }

                if flooded[px] {
                    // Under the pool: wet, dark sediment at the top of the cut.
                    if depth < 0.01 { rgb = mix(rgb, DioramaPalette.bedDark, 0.7) }
                    rough = min(rough, 0.45)
                } else {
                    // Moss hanging over the cut edge, with drips, and its shadow below.
                    let fringe = 0.006 + 0.016 * Terrain.fbm(q * 90, 0.7, seed: 71)
                        + 0.02 * max(0, noise(q * 45, 0.2, 72) - 0.7) / 0.3
                    if depth < fringe {
                        let cushion = noise(q * 500, y * 500, 73)
                        rgb = mix(DioramaPalette.mossMid, DioramaPalette.mossLight, cushion)
                        rough = 0.95
                        bump = 0.8 * cushion + 0.4
                    } else if depth < fringe + 0.008 {
                        rgb *= 0.6
                    }
                }

                // Above every wall top: never shown, but keep it rock-coloured so mipmaps do not bleed.
                if depth < -0.002 {
                    rgb = DioramaPalette.basaltDark
                    bump = 0
                }

                color.set(px, py, rgb)
                roughness.set(px, py, gray: rough)
                detail[px, py] = bump
            }
        }

        let normal = PixelBuffer(width: width, height: height)
        detail.writeNormals(into: normal, strength: 2.5, wrapX: true)
        return Maps(color: color, normal: normal, roughness: roughness)
    }

    // MARK: - Water ripples

    /// A tiling ripple height, as a normal map that scrolls across the pool.
    private static func bakeRipples() -> PixelBuffer {
        let size = rippleSize
        let height = FloatBuffer(width: size, height: size)
        DispatchQueue.concurrentPerform(iterations: size) { py in
            for px in 0..<size {
                let u = Float(px) / Float(size)
                let v = Float(py) / Float(size)
                height[px, py] = 0.5 * Terrain.noise(u * 8, v * 8, seed: 81, period: 8)
                    + 0.3 * Terrain.noise(u * 16, v * 16, seed: 82, period: 16)
                    + 0.2 * Terrain.noise(u * 32, v * 32, seed: 83, period: 32)
            }
        }
        let normal = PixelBuffer(width: size, height: size)
        height.writeNormals(into: normal, strength: 6, wrapX: true, wrapY: true)
        return normal
    }

    // MARK: - Materials

    enum TextureError: Error { case image }

    @MainActor
    private static func texture(_ buffer: PixelBuffer, semantic: TextureResource.Semantic, srgb: Bool) async throws -> TextureResource {
        guard let image = buffer.makeImage(srgb: srgb) else { throw TextureError.image }
        return try await TextureResource(image: image, options: .init(semantic: semantic))
    }

    @MainActor
    static func material(for maps: Maps) async throws -> PhysicallyBasedMaterial {
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: .white, texture: .init(try await texture(maps.color, semantic: .color, srgb: true)))
        material.normal = .init(texture: .init(try await texture(maps.normal, semantic: .normal, srgb: false)))
        material.roughness = .init(scale: 1, texture: .init(try await texture(maps.roughness, semantic: .scalar, srgb: false)))
        material.metallic = .init(floatLiteral: 0)
        return material
    }

    @MainActor
    static func rippleTexture(_ baked: Baked) async throws -> TextureResource {
        try await texture(baked.ripples, semantic: .normal, srgb: false)
    }

    /// Translucent, glossy water. `side`: the denser, lighter face seen through the cut.
    @MainActor
    static func waterMaterial(side: Bool, ripples: TextureResource?) -> PhysicallyBasedMaterial {
        var material = PhysicallyBasedMaterial()
        let tint = side ? DioramaPalette.waterSide : DioramaPalette.water
        material.baseColor = .init(tint: UIColor(red: CGFloat(tint.x), green: CGFloat(tint.y), blue: CGFloat(tint.z), alpha: 1))
        material.roughness = .init(floatLiteral: side ? 0.12 : 0.04)
        material.metallic = .init(floatLiteral: 0)
        material.specular = .init(floatLiteral: 1)
        material.clearcoat = .init(floatLiteral: 1)
        material.clearcoatRoughness = .init(floatLiteral: 0.02)
        material.blending = .transparent(opacity: .init(floatLiteral: side ? 0.78 : 0.62))
        if let ripples {
            material.normal = .init(texture: .init(ripples))
        }
        return material
    }
}
