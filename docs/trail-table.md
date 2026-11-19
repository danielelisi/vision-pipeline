# Trail Table (work in progress)

A second experience for this app: a mountain diorama — a square block cut out of the landscape,
with a waterfall into a pool — where you plan a hiking route with your hands. Sources are in `VisionPipeline/Trail/`.

## How it is wired

- The app opens on a chooser (`Launcher.swift`): **Cluster Network** or **Trail Table**.
  Going back to the chooser closes the other experience's window or space.
- `VisionPipelineApp` owns one `TrailModel` and puts it in the environment.
- `ImmersiveSpace(id: TrailModel.immersiveSpaceID) { TableView() }` uses mixed immersion.
- Picking Trail Table shows `TrailPanel` in the main window; its toggle opens the space.

## Gestures

| Mode | Do this | What happens | API |
|---|---|---|---|
| Plan | Look at the terrain and pinch | Drops a waypoint | `SpatialTapGesture` |
| Plan | Pinch a waypoint and drag | Moves it, and the route re-drapes over the ground | `DragGesture` |
| Plan | Pinch a waypoint and hold still for 1 s | Deletes it | `LongPressGesture` |
| Shape | Pinch with both hands, pull apart | Changes vertical exaggeration | `MagnifyGesture` |
| Shape | Pinch with both hands, turn like a wheel | Spins the block | `RotateGesture3D` |
| Move | Pinch the table with one or two hands | Carry, turn, resize | `ManipulationComponent` (visionOS 26) |

## Look

Styled after a reference diorama: dark basalt cliffs, bright moss, layered rock on the cut sides,
a soil band at the bottom, and a translucent pool you can see through the side.

- Colours are sampled from the reference image (`DioramaPalette`).
- Terrain colour follows slope, not height: basalt on steep faces, moss on gentle ground.
- No Reality Composer Pro, so no `ShaderGraphMaterial`: every surface is a `PhysicallyBasedMaterial`
  with base colour, normal and roughness maps generated in code from the heightfield at launch.
- Slope colouring is baked at the default 2x exaggeration; changing it later does not recolour.

## Files

| File | What it does |
|---|---|
| `Terrain.swift` | Procedural heightfield, 257 x 257 (8 km square at 1:10,000, 200 m to 3,200 m): ridged peak, plateau, valley, pool, waterfall lip |
| `DioramaMesh.swift` | Meshes: surface, cut sides, base, pool surface and sides, collision |
| `TerrainTextures.swift` | Palette, and the baked base colour / normal / roughness maps |
| `Waterfall.swift` | Waterfall, splash and mist emitters; scrolling water ripples |
| `TrailModel.swift` | Waypoints, mode, route sampling, stats (Naismith time estimate) |
| `TableScene.swift` | Entities, light, pins, route line, collision, Move-mode manipulation |
| `TableView.swift` | The immersive `RealityView` and all SwiftUI gestures |
| `TrailPanel.swift` | Mode picker, stats and elevation chart |
