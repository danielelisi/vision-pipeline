import Charts
import SwiftUI

/// The window: opens the table, switches gesture mode, shows route stats.
struct TrailPanel: View {
    @Environment(TrailModel.self) private var model
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @State private var showingTable = false

    var body: some View {
        @Bindable var model = model
        let stats = model.stats

        NavigationStack {
            Form {
                Section {
                    Toggle("Show the trail table", isOn: $showingTable)
                }

                Section {
                    Label("In the space, turn your left palm up to switch mode.", systemImage: "hand.raised")
                        .font(.callout)
                }

                Section("Gesture mode") {
                    Picker("Mode", selection: $model.mode) {
                        ForEach(TrailModel.Mode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    ForEach(model.mode.hints, id: \.self) { hint in
                        Label(hint, systemImage: "hand.pinch")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Route") {
                    LabeledContent("Waypoints", value: "\(model.waypoints.count)")
                    LabeledContent("Distance", value: String(format: "%.1f km", stats.distanceKm))
                    LabeledContent("Ascent", value: String(format: "%.0f m", stats.ascent))
                    LabeledContent("Descent", value: String(format: "%.0f m", stats.descent))
                    LabeledContent("Estimated time", value: stats.timeText)

                    if model.waypoints.count > 1 {
                        Chart(model.profile) { point in
                            LineMark(
                                x: .value("Distance (km)", point.km),
                                y: .value("Elevation (m)", point.elevation)
                            )
                        }
                        .chartYScale(domain: .automatic(includesZero: false))
                        .frame(height: 140)
                    }

                    HStack {
                        Button("Undo last") { model.undo() }
                        Spacer()
                        Button("Clear route", role: .destructive) { model.clear() }
                    }
                    .disabled(model.waypoints.isEmpty)
                }

                Section("Terrain") {
                    LabeledContent("Vertical exaggeration", value: String(format: "%.1fx", model.exaggeration))
                    Slider(value: $model.exaggeration, in: TrailModel.exaggerationRange)
                    Button("Reset table position") { model.resetTable() }
                }
            }
            .navigationTitle("Trail Table")
        }
        .onChange(of: showingTable) { _, wantsTable in
            Task {
                if wantsTable {
                    switch await openImmersiveSpace(id: TrailModel.immersiveSpaceID) {
                    case .opened: break
                    default: showingTable = false
                    }
                } else {
                    await dismissImmersiveSpace()
                }
            }
        }
    }
}
