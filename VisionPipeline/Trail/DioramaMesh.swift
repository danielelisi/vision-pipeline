import RealityKit

/// Meshes for the diorama block: the terrain surface, the cut sides, the base,
/// the pool, and a lighter surface for collision.
///
/// Spaces:
/// - *visual* space: the terrain's own space, scaled in Y for vertical exaggeration.
///   y = 0 is the top of the solid base. Surface, upper walls and water live here.
/// - *pivot* space: y = 0 is the bottom of the block. The base (soil band) lives here,
///   unscaled, from y = 0 up to `baseDepth`.
///
/// Texture coordinates use RealityKit's convention (origin at the image's bottom left).
/// Top surface: u = x, v = 1 - z (image row 0 is the far edge).
/// Walls: u runs once around the perimeter (near, right, far, left), v = height / `wallSpan`.
@MainActor
enum DioramaMesh {
    // Constants are nonisolated: the texture baker reads them off the main thread.
    /// Height of the unscaled base under the terrain, in metres. Holds the soil band.
    nonisolated static let baseDepth: Float = 0.04
    /// Wall height that the wall texture covers top to bottom, at exaggeration 1.
    nonisolated static let wallSpan: Float = baseDepth + Terrain.heightScale
    /// Ripple texture repeats every this many metres on the water.
    nonisolated static let rippleTile: Float = 0.08

    private struct Builder {
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var uvs: [SIMD2<Float>] = []
        var tangents: [SIMD3<Float>] = []
        var bitangents: [SIMD3<Float>] = []
        var indices: [UInt32] = []

        mutating func vertex(_ p: SIMD3<Float>, _ n: SIMD3<Float>, _ uv: SIMD2<Float>,
                             tangent: SIMD3<Float>, bitangent: SIMD3<Float>) -> UInt32 {
            positions.append(p)
            normals.append(n)
            uvs.append(uv)
            tangents.append(tangent)
            bitangents.append(bitangent)
            return UInt32(positions.count - 1)
        }

        /// Quad a-b-d-c, front face where (b - a) × (c - a) points.
        mutating func quad(_ a: UInt32, _ b: UInt32, _ c: UInt32, _ d: UInt32) {
            indices.append(contentsOf: [a, b, d, a, d, c])
        }

        @MainActor
        func mesh(named name: String) throws -> MeshResource {
            var descriptor = MeshDescriptor(name: name)
            descriptor.positions = MeshBuffer(positions)
            descriptor.normals = MeshBuffer(normals)
            descriptor.textureCoordinates = MeshBuffer(uvs)
            descriptor[MeshBuffers.tangents] = MeshBuffer(tangents)
            descriptor[MeshBuffers.bitangents] = MeshBuffer(bitangents)
            descriptor.primitives = .triangles(indices)
            return try MeshResource.generate(from: [descriptor])
        }
    }

    // MARK: - Grid helpers

    private static func cell(_ terrain: Terrain) -> Float { Terrain.size / Float(terrain.resolution - 1) }

    private static func coordinate(_ index: Int, _ terrain: Terrain) -> Float {
        Float(index) * cell(terrain) - Terrain.size / 2
    }

    private static func ground(_ terrain: Terrain, _ x: Int, _ z: Int) -> Float {
        let n = terrain.resolution
        return terrain.ground[min(max(z, 0), n - 1) * n + min(max(x, 0), n - 1)]
    }

    /// One side of the block: grid index of sample `i`, the direction the wall runs, and its outward normal.
    private struct Side {
        let index: (Int) -> (x: Int, z: Int)
        let along: SIMD3<Float>
        let outward: SIMD3<Float>
    }

    private static func sides(_ n: Int) -> [Side] {
        [
            Side(index: { (x: $0, z: n - 1) }, along: [1, 0, 0], outward: [0, 0, 1]),         // near
            Side(index: { (x: n - 1, z: n - 1 - $0) }, along: [0, 0, -1], outward: [1, 0, 0]), // right
            Side(index: { (x: n - 1 - $0, z: 0) }, along: [-1, 0, 0], outward: [0, 0, -1]),    // far
            Side(index: { (x: 0, z: $0) }, along: [0, 0, 1], outward: [-1, 0, 0]),             // left
        ]
    }

    // MARK: - Terrain surface

    /// The ground (pool bed included), in visual space.
    static func surface(_ terrain: Terrain) throws -> MeshResource {
        let n = terrain.resolution
        let c = cell(terrain)
        let hs = Terrain.heightScale
        var b = Builder()
        b.positions.reserveCapacity(n * n)

        for z in 0..<n {
            for x in 0..<n {
                let h = ground(terrain, x, z) * hs
                let dx = (ground(terrain, x + 1, z) - ground(terrain, x - 1, z)) * hs
                let dz = (ground(terrain, x, z + 1) - ground(terrain, x, z - 1)) * hs
                let normal = simd_normalize(SIMD3<Float>(-dx / (2 * c), 1, -dz / (2 * c)))
                let tangent = simd_normalize(SIMD3<Float>(2 * c, dx, 0))       // +u
                let bitangent = simd_normalize(SIMD3<Float>(0, -dz, -2 * c))   // +v, which is -z
                _ = b.vertex(
                    [coordinate(x, terrain), h, coordinate(z, terrain)], normal,
                    [Float(x) / Float(n - 1), 1 - Float(z) / Float(n - 1)],
                    tangent: tangent, bitangent: bitangent
                )
            }
        }
        b.indices.reserveCapacity((n - 1) * (n - 1) * 6)
        for z in 0..<(n - 1) {
            for x in 0..<(n - 1) {
                let i0 = UInt32(z * n + x)
                let i1 = i0 + 1
                let i2 = i0 + UInt32(n)
                let i3 = i2 + 1
                // Counter-clockwise when seen from above.
                b.indices.append(contentsOf: [i0, i2, i1, i1, i2, i3])
            }
        }
        return try b.mesh(named: "diorama-surface")
    }

    // MARK: - Cut sides

    /// The cut sides from the terrain's edge down to the top of the base, in visual space.
    static func upperWalls(_ terrain: Terrain) throws -> MeshResource {
        let n = terrain.resolution
        let hs = Terrain.heightScale
        var b = Builder()
        for (k, side) in sides(n).enumerated() {
            var previous: (bottom: UInt32, top: UInt32)?
            for i in 0..<n {
                let (x, z) = side.index(i)
                let p = SIMD3<Float>(coordinate(x, terrain), 0, coordinate(z, terrain))
                let top = ground(terrain, x, z) * hs
                let u = (Float(k) + Float(i) / Float(n - 1)) / 4
                let bottom = b.vertex(p, side.outward, [u, baseDepth / wallSpan],
                                      tangent: side.along, bitangent: [0, 1, 0])
                let upper = b.vertex(p + [0, top, 0], side.outward, [u, (baseDepth + top) / wallSpan],
                                     tangent: side.along, bitangent: [0, 1, 0])
                if let previous {
                    b.quad(previous.bottom, bottom, previous.top, upper)
                }
                previous = (bottom, upper)
            }
        }
        return try b.mesh(named: "diorama-walls")
    }

    /// The unscaled base (soil band and lower rock) plus the bottom face, in pivot space.
    static func base(_ terrain: Terrain) throws -> MeshResource {
        let n = terrain.resolution
        var b = Builder()
        let half = Terrain.size / 2
        for (k, side) in sides(n).enumerated() {
            let (x0, z0) = side.index(0)
            let (x1, z1) = side.index(n - 1)
            let p0 = SIMD3<Float>(coordinate(x0, terrain), 0, coordinate(z0, terrain))
            let p1 = SIMD3<Float>(coordinate(x1, terrain), 0, coordinate(z1, terrain))
            let u0 = Float(k) / 4
            let u1 = Float(k + 1) / 4
            let a = b.vertex(p0, side.outward, [u0, 0], tangent: side.along, bitangent: [0, 1, 0])
            let bb = b.vertex(p1, side.outward, [u1, 0], tangent: side.along, bitangent: [0, 1, 0])
            let c = b.vertex(p0 + [0, baseDepth, 0], side.outward, [u0, baseDepth / wallSpan],
                             tangent: side.along, bitangent: [0, 1, 0])
            let d = b.vertex(p1 + [0, baseDepth, 0], side.outward, [u1, baseDepth / wallSpan],
                             tangent: side.along, bitangent: [0, 1, 0])
            b.quad(a, bb, c, d)
        }
        // Bottom face, facing down. Samples the darkest soil row.
        let down = SIMD3<Float>(0, -1, 0)
        let uv = SIMD2<Float>(0.5, 0.004)
        let a = b.vertex([-half, 0, -half], down, uv, tangent: [1, 0, 0], bitangent: [0, 0, 1])
        let bb = b.vertex([half, 0, -half], down, uv, tangent: [1, 0, 0], bitangent: [0, 0, 1])
        let c = b.vertex([-half, 0, half], down, uv, tangent: [1, 0, 0], bitangent: [0, 0, 1])
        let d = b.vertex([half, 0, half], down, uv, tangent: [1, 0, 0], bitangent: [0, 0, 1])
        b.quad(a, bb, c, d) // (b - a) × (c - a) = +x × +z = -y: faces down
        return try b.mesh(named: "diorama-base")
    }

    // MARK: - Water

    /// The pool surface over every flooded cell, in visual space. Parts under the cliff are hidden by the ground.
    static func waterSurface(_ terrain: Terrain) throws -> MeshResource? {
        let n = terrain.resolution
        let y = Terrain.waterLevel * Terrain.heightScale
        var b = Builder()
        for z in 0..<(n - 1) {
            for x in 0..<(n - 1) {
                let lowest = min(ground(terrain, x, z), ground(terrain, x + 1, z),
                                 ground(terrain, x, z + 1), ground(terrain, x + 1, z + 1))
                guard lowest < Terrain.waterLevel else { continue }
                func corner(_ cx: Int, _ cz: Int) -> UInt32 {
                    let px = coordinate(cx, terrain)
                    let pz = coordinate(cz, terrain)
                    return b.vertex([px, y, pz], [0, 1, 0],
                                    [px / rippleTile, -pz / rippleTile],
                                    tangent: [1, 0, 0], bitangent: [0, 0, -1])
                }
                let i0 = corner(x, z)
                let i1 = corner(x + 1, z)
                let i2 = corner(x, z + 1)
                let i3 = corner(x + 1, z + 1)
                b.indices.append(contentsOf: [i0, i2, i1, i1, i2, i3])
            }
        }
        return b.indices.isEmpty ? nil : try b.mesh(named: "diorama-water")
    }

    /// The water seen through the cut sides: from the pool bed up to the surface, in visual space.
    static func waterSides(_ terrain: Terrain) throws -> MeshResource? {
        let n = terrain.resolution
        let hs = Terrain.heightScale
        let surface = Terrain.waterLevel * hs
        var b = Builder()
        for (k, side) in sides(n).enumerated() {
            for i in 0..<(n - 1) {
                let (x0, z0) = side.index(i)
                let (x1, z1) = side.index(i + 1)
                let g0 = ground(terrain, x0, z0)
                let g1 = ground(terrain, x1, z1)
                guard min(g0, g1) < Terrain.waterLevel else { continue }
                let p0 = SIMD3<Float>(coordinate(x0, terrain), 0, coordinate(z0, terrain))
                let p1 = SIMD3<Float>(coordinate(x1, terrain), 0, coordinate(z1, terrain))
                let s0 = (Float(k) * Terrain.size + Float(i) * cell(terrain)) / rippleTile
                let s1 = s0 + cell(terrain) / rippleTile
                let bottom0 = min(g0 * hs, surface)
                let bottom1 = min(g1 * hs, surface)
                let a = b.vertex(p0 + [0, bottom0, 0], side.outward, [s0, bottom0 / rippleTile],
                                 tangent: side.along, bitangent: [0, 1, 0])
                let bb = b.vertex(p1 + [0, bottom1, 0], side.outward, [s1, bottom1 / rippleTile],
                                  tangent: side.along, bitangent: [0, 1, 0])
                let c = b.vertex(p0 + [0, surface, 0], side.outward, [s0, surface / rippleTile],
                                 tangent: side.along, bitangent: [0, 1, 0])
                let d = b.vertex(p1 + [0, surface, 0], side.outward, [s1, surface / rippleTile],
                                 tangent: side.along, bitangent: [0, 1, 0])
                b.quad(a, bb, c, d)
            }
        }
        return b.indices.isEmpty ? nil : try b.mesh(named: "diorama-water-sides")
    }

    // MARK: - Collision

    /// The walkable surface (water over the pool) at half resolution, with heights times `yScale`.
    /// In the terrain entity's space. Kept light so the static-mesh collision builds quickly.
    static func collisionSurface(_ terrain: Terrain, yScale: Float, step: Int = 2) throws -> MeshResource {
        let n = terrain.resolution
        let samples = (n - 1) / step + 1
        var positions: [SIMD3<Float>] = []
        positions.reserveCapacity(samples * samples)
        for zi in 0..<samples {
            for xi in 0..<samples {
                let x = min(xi * step, n - 1)
                let z = min(zi * step, n - 1)
                let h = terrain.heights[z * n + x] * Terrain.heightScale * yScale
                positions.append([coordinate(x, terrain), h, coordinate(z, terrain)])
            }
        }
        var indices: [UInt32] = []
        indices.reserveCapacity((samples - 1) * (samples - 1) * 6)
        for z in 0..<(samples - 1) {
            for x in 0..<(samples - 1) {
                let i0 = UInt32(z * samples + x)
                let i1 = i0 + 1
                let i2 = i0 + UInt32(samples)
                let i3 = i2 + 1
                indices.append(contentsOf: [i0, i2, i1, i1, i2, i3])
            }
        }
        var descriptor = MeshDescriptor(name: "diorama-collision")
        descriptor.positions = MeshBuffer(positions)
        descriptor.primitives = .triangles(indices)
        return try MeshResource.generate(from: [descriptor])
    }
}
