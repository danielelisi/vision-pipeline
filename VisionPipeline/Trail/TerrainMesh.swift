import RealityKit

/// Turns a `Terrain` heightfield into RealityKit meshes.
@MainActor
enum TerrainMesh {
    struct Geometry {
        var positions: [SIMD3<Float>]
        var normals: [SIMD3<Float>]
        var indices: [UInt32]        // triangle list
        var bands: [Terrain.Band]    // one per triangle
    }

    static func geometry(for terrain: Terrain) -> Geometry {
        let n = terrain.resolution
        let cell = Terrain.size / Float(n - 1)
        let heightScale = Terrain.relief / Terrain.metresPerUnit

        func height(_ x: Int, _ z: Int) -> Float {
            terrain.heights[min(max(z, 0), n - 1) * n + min(max(x, 0), n - 1)] * heightScale
        }

        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        positions.reserveCapacity(n * n)
        normals.reserveCapacity(n * n)

        for z in 0..<n {
            for x in 0..<n {
                positions.append([
                    Float(x) * cell - Terrain.size / 2,
                    height(x, z),
                    Float(z) * cell - Terrain.size / 2,
                ])
                let slopeX = (height(x + 1, z) - height(x - 1, z)) / (2 * cell)
                let slopeZ = (height(x, z + 1) - height(x, z - 1)) / (2 * cell)
                normals.append(simd_normalize(SIMD3<Float>(-slopeX, 1, -slopeZ)))
            }
        }

        var indices: [UInt32] = []
        var bands: [Terrain.Band] = []
        indices.reserveCapacity((n - 1) * (n - 1) * 6)
        bands.reserveCapacity((n - 1) * (n - 1) * 2)

        for z in 0..<(n - 1) {
            for x in 0..<(n - 1) {
                let i0 = UInt32(z * n + x)
                let i1 = i0 + 1
                let i2 = i0 + UInt32(n)
                let i3 = i2 + 1
                // Counter-clockwise when seen from above.
                for triangle in [[i0, i2, i1], [i1, i2, i3]] {
                    indices.append(contentsOf: triangle)
                    let mean = triangle.reduce(Float(0)) { $0 + terrain.heights[Int($1)] } / 3
                    bands.append(Terrain.band(for: mean))
                }
            }
        }

        return Geometry(positions: positions, normals: normals, indices: indices, bands: bands)
    }

    /// One mesh per elevation band, so each band can use its own plain material.
    static func bandMeshes(for geometry: Geometry) throws -> [(band: Terrain.Band, mesh: MeshResource)] {
        var result: [(band: Terrain.Band, mesh: MeshResource)] = []

        for band in Terrain.Band.allCases {
            var remap: [UInt32: UInt32] = [:]
            var positions: [SIMD3<Float>] = []
            var normals: [SIMD3<Float>] = []
            var indices: [UInt32] = []

            for (triangle, triangleBand) in geometry.bands.enumerated() where triangleBand == band {
                for corner in 0..<3 {
                    let source = geometry.indices[triangle * 3 + corner]
                    if let existing = remap[source] {
                        indices.append(existing)
                    } else {
                        let new = UInt32(positions.count)
                        remap[source] = new
                        positions.append(geometry.positions[Int(source)])
                        normals.append(geometry.normals[Int(source)])
                        indices.append(new)
                    }
                }
            }
            guard !indices.isEmpty else { continue }

            var descriptor = MeshDescriptor(name: "terrain-\(band)")
            descriptor.positions = MeshBuffer(positions)
            descriptor.normals = MeshBuffer(normals)
            descriptor.primitives = .triangles(indices)
            let mesh = try MeshResource.generate(from: [descriptor])
            result.append((band: band, mesh: mesh))
        }
        return result
    }

    /// The whole surface as one mesh, with heights multiplied by `yScale`. Used for collision.
    static func surfaceMesh(for geometry: Geometry, yScale: Float) throws -> MeshResource {
        var descriptor = MeshDescriptor(name: "terrain-surface")
        descriptor.positions = MeshBuffer(geometry.positions.map { SIMD3<Float>($0.x, $0.y * yScale, $0.z) })
        descriptor.primitives = .triangles(geometry.indices)
        return try MeshResource.generate(from: [descriptor])
    }
}
