# Trail Table (work in progress)

A second experience for this app: a 3D mountain on a round table, where you plan a hiking
route with your hands. Sources are in `VisionPipeline/Trail/`.

**Status: not wired into the app and never compiled.** Nothing references these types yet.

## To wire it up

- Create one `TrailModel` in `VisionPipelineApp` and put it in the environment.
- Add `ImmersiveSpace(id: TrailModel.immersiveSpaceID) { TableView() }` with a mixed immersion style.
- Show `TrailPanel` somewhere reachable (its own window, or a section of `ContentView`).

## Gestures

| Mode | Do this | What happens | API |
|---|---|---|---|
| Plan | Look at the terrain and pinch | Drops a waypoint | `SpatialTapGesture` |
| Plan | Pinch a waypoint and drag | Moves it, and the route re-drapes over the ground | `DragGesture` |
| Plan | Pinch a waypoint and hold still for 1 s | Deletes it | `LongPressGesture` |
| Shape | Pinch with both hands, pull apart | Changes vertical exaggeration | `MagnifyGesture` |
| Shape | Pinch with both hands, turn like a wheel | Spins the map on its plinth | `RotateGesture3D` |
| Move | Pinch the table with one or two hands | Carry, turn, resize | `ManipulationComponent` (visionOS 26) |

## Files

| File | What it does |
|---|---|
| `Terrain.swift` | Procedural heightfield (8 km square at 1:10,000, 200 m to 2,200 m) |
| `TerrainMesh.swift` | Heightfield to RealityKit meshes, one per elevation band |
| `TrailModel.swift` | Waypoints, mode, route sampling, stats (Naismith time estimate) |
| `TableScene.swift` | Entities, pins, route line, collision, Move-mode manipulation |
| `TableView.swift` | The immersive `RealityView` and all SwiftUI gestures |
| `TrailPanel.swift` | Mode picker, stats and elevation chart |
