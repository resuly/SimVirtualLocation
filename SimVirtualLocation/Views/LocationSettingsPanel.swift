//
//  LocationSettingsPanel.swift
//  SimVirtualLocation
//
//  Created by Sergey Shirnin on 18.04.2022.
//

import SwiftUI
import Foundation
import MapKit

struct LocationSettingsPanel: View {
    @EnvironmentObject var locationController: LocationController
    
    @State private var isPresentedSetToCoordinate = false
    @State private var latitude = ""
    @State private var longitude = ""
    @State private var latitudeLongitude = ""
    
    var body: some View {
        VStack {
            GroupBox {
                Picker("Points mode", selection: $locationController.pointsMode) {
                    Text("Single").tag(LocationController.PointsMode.single)
                    Text("Two").tag(LocationController.PointsMode.two)
                    Text("Direction").tag(LocationController.PointsMode.direction)
                }.pickerStyle(.segmented)
            }

            if let importedRoute = locationController.importedRoute {
                ImportedRoutePanel(route: importedRoute)
                    .environmentObject(locationController)
            } else if locationController.pointsMode == .direction {
                // Show Direction panel when Direction mode is selected
                DirectionPanel()
                    .environmentObject(locationController)
            } else {
                // Original Single/Two mode controls
                GroupBox {
                    Button(action: {
                        locationController.setCurrentLocation()
                    }, label: {
                        Text("Set to current location").frame(maxWidth: .infinity)
                    })

                    Button(action: {
                        latitude = ""
                        longitude = ""
                        latitudeLongitude = ""
                        isPresentedSetToCoordinate = true
                    }, label: {
                        Text("Set to Coordinate").frame(maxWidth: .infinity)
                    })
                    .alert("Enter your coordinate", isPresented: $isPresentedSetToCoordinate) {
                        TextField("Latitude", text: $latitude)
                        TextField("Longitude", text: $longitude)
                        TextField("Latitude, Longitude", text: $latitudeLongitude)
                        Button("Move"){
                            if latitude.isEmpty || longitude.isEmpty {
                                locationController.setToCoordinate(latLngString: latitudeLongitude)
                            } else {
                                locationController.setToCoordinate(latString: latitude, lngString: longitude)
                            }
                        }
                        Button("Cancel", role: .cancel) { }
                    }

                    HStack {
                        Button(action: {
                            locationController.setSelectedLocation()
                        }, label: {
                            Text("Set to A").frame(maxWidth: .infinity)
                        })
                        Button(action: {
                            locationController.savePointA()
                        }, label: {
                            Text("Save point A").frame(maxWidth: .infinity)
                        })
                    }

                    HStack {
                        Button(action: {
                            locationController.setSelectedLocation(toBPoint: true)
                        }, label: {
                            Text("Set to B").frame(maxWidth: .infinity)
                        })
                        Button(action: {
                            locationController.savePointB()
                        }, label: {
                            Text("Save point B").frame(maxWidth: .infinity)
                        })
                    }

                    Button(action: {
                        locationController.makeRoute()
                    }, label: {
                        Text("Make route").frame(maxWidth: .infinity)
                    })

                    Button(action: {
                        locationController.simulateRoute()
                    }, label: {
                        Text("Simulate route").frame(maxWidth: .infinity)
                    })

                    Button(action: {
                        locationController.simulateFromAToB()
                    }, label: {
                        Text("Simulate from A to B").frame(maxWidth: .infinity)
                    })

                    // Simulation controls with Pause/Resume
                    HStack {
                        if locationController.isSimulating {
                            Button(action: {
                                if locationController.isPaused {
                                    locationController.resumeSimulation()
                                } else {
                                    locationController.pauseSimulation()
                                }
                            }, label: {
                                Text(locationController.isPaused ? "Resume" : "Pause")
                                    .frame(maxWidth: .infinity)
                            })

                            Button(action: {
                                locationController.stopSimulation()
                            }, label: {
                                Text("Stop")
                                    .frame(maxWidth: .infinity)
                            })
                        } else {
                            Button(action: {
                                locationController.stopSimulation()
                            }, label: {
                                Text("Stop simulation").frame(maxWidth: .infinity)
                            })
                        }
                    }
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Speed")
                            .font(.headline)
                        Slider(value: $locationController.speed, in: 0...200, step: 5)
                        Text("\(Int(locationController.speed.rounded(.up))) km/h")
                            .font(.subheadline)
                    }
                    .padding(.vertical, 4)
                }

                if locationController.isSimulating {
                    SimulationInfoPanel()
                        .environmentObject(locationController)
                }

                GroupBox {
                    if locationController.useRSD {
                        Picker("Frequency", selection: $locationController.timeScale) {
                            Text("5s").tag(5.0)
                            Text("10s").tag(10.0)
                            Text("15s").tag(15.0)
                        }
                        .pickerStyle(.segmented)
                        .disabled(locationController.isSimulating)
                        .onAppear {
                            locationController.timeScale = 5.0
                        }
                    } else {
                        Picker("Frequency", selection: $locationController.timeScale) {
                            Text("0.5s").tag(0.5)
                            Text("1s").tag(1.0)
                            Text("1.5s").tag(1.5)
                            Text("2s").tag(2.0)
                        }
                        .pickerStyle(.segmented)
                        .disabled(locationController.isSimulating)
                    }
                }

                Spacer()

                GroupBox {
                    Button(action: {
                        locationController.reset()
                    }, label: {
                        Text("Reset").frame(maxWidth: .infinity)
                    })
                }
            }
        }
    }
}

struct LocationSettingsPanel_Previews: PreviewProvider {
    static var previews: some View {
        LocationSettingsPanel()
    }
}

// MARK: - Imported Route Panel

struct ImportedRoutePanel: View {
    @EnvironmentObject var locationController: LocationController
    let route: GeoJSONRoute

    var body: some View {
        VStack {
            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Imported route")
                        .font(.headline)
                    Text(route.displayName)
                        .font(.subheadline)
                    Text(String(format: "%d points • %.2f km", route.pointCount, route.distanceMeters / 1000.0))
                        .font(.subheadline)
                    Text("Original geometry; Apple Maps routing is not used")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Speed")
                        .font(.headline)
                    Slider(value: $locationController.speed, in: 0...200, step: 5)
                    Text("\(Int(locationController.speed.rounded(.up))) km/h")
                        .font(.subheadline)
                }
                .padding(.vertical, 4)
            }

            if locationController.isSimulating {
                SimulationInfoPanel()
                    .environmentObject(locationController)
            }

            GroupBox {
                if locationController.useRSD {
                    Picker("Frequency", selection: $locationController.timeScale) {
                        Text("5s").tag(5.0)
                        Text("10s").tag(10.0)
                        Text("15s").tag(15.0)
                    }
                    .pickerStyle(.segmented)
                    .disabled(locationController.isSimulating)
                    .onAppear {
                        locationController.timeScale = 5.0
                    }
                } else {
                    Picker("Frequency", selection: $locationController.timeScale) {
                        Text("0.5s").tag(0.5)
                        Text("1s").tag(1.0)
                        Text("1.5s").tag(1.5)
                        Text("2s").tag(2.0)
                    }
                    .pickerStyle(.segmented)
                    .disabled(locationController.isSimulating)
                }
            }

            HStack {
                if locationController.isSimulating {
                    Button(action: {
                        if locationController.isPaused {
                            locationController.resumeSimulation()
                        } else {
                            locationController.pauseSimulation()
                        }
                    }) {
                        Text(locationController.isPaused ? "Resume" : "Pause")
                            .frame(maxWidth: .infinity)
                    }

                    Button(action: {
                        locationController.stopSimulation()
                    }) {
                        Text("Stop")
                            .frame(maxWidth: .infinity)
                    }
                } else {
                    Button(action: {
                        locationController.simulateImportedRoute()
                    }) {
                        Text("Start Simulation")
                            .frame(maxWidth: .infinity)
                    }
                }
            }

            Text("Switch Points mode to leave the imported route")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Spacer()
        }
    }
}

// MARK: - Direction Panel

struct DirectionPanel: View {
    @EnvironmentObject var locationController: LocationController
    @State private var showSavePreset = false
    @State private var presetName = ""

    var body: some View {
        VStack {
            // Route presets
            GroupBox {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Route Presets")
                        .font(.headline)

                    ForEach(locationController.routePresets) { preset in
                        HStack {
                            Button(action: {
                                locationController.loadPreset(preset)
                            }, label: {
                                HStack {
                                    Image(systemName: "mappin.and.ellipse")
                                    Text(preset.name)
                                    Spacer()
                                    Text("\(preset.coordinates.count) pts")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                .frame(maxWidth: .infinity)
                            })
                            .disabled(locationController.isSimulating)

                            // Delete button (only for user presets)
                            if !RoutePreset.builtIn.contains(where: { $0.name == preset.name }) {
                                Button(action: {
                                    locationController.deletePreset(preset)
                                }) {
                                    Image(systemName: "trash")
                                        .foregroundColor(.red)
                                        .font(.caption)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    // Save current route as preset
                    if !locationController.waypoints.isEmpty && !locationController.isSimulating {
                        Divider()
                        Button(action: {
                            presetName = ""
                            showSavePreset = true
                        }, label: {
                            HStack {
                                Image(systemName: "plus.circle")
                                Text("Save Current Route")
                            }
                            .frame(maxWidth: .infinity)
                        })
                        .alert("Save Route Preset", isPresented: $showSavePreset) {
                            TextField("Preset name", text: $presetName)
                            Button("Save") {
                                if !presetName.isEmpty {
                                    locationController.saveCurrentRouteAsPreset(name: presetName)
                                }
                            }
                            Button("Cancel", role: .cancel) { }
                        }
                    }
                }
            }

            // Operation hint
            Text(locationController.directionHintText)
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.vertical, 4)
                .multilineTextAlignment(.center)

            // Waypoints list
            GroupBox {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Selected Waypoints")
                            .font(.headline)
                        Spacer()
                        Text("(\(locationController.waypoints.count))")
                            .foregroundColor(.secondary)
                    }

                    Divider()

                    if locationController.waypoints.isEmpty {
                        Text("Click map to add waypoints")
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 100)
                    } else {
                        ScrollView {
                            VStack(spacing: 4) {
                                ForEach(0..<locationController.waypoints.count, id: \.self) { index in
                                    let waypoint = locationController.waypoints[index]
                                    WaypointRow(
                                        index: index,
                                        waypoint: waypoint,
                                        isSimulating: locationController.isSimulating,
                                        onDelete: {
                                            locationController.deleteWaypoint(at: index)
                                        }
                                    )
                                    .id("\(waypoint.coordinate.latitude)_\(waypoint.coordinate.longitude)_\(index)")
                                }
                            }
                        }
                        .frame(height: 200)
                    }
                }
            }

            // Clear All button
            Button(action: {
                locationController.clearAllWaypoints()
            }, label: {
                Text("Clear All").frame(maxWidth: .infinity)
            })
            .disabled(locationController.waypoints.isEmpty || locationController.isSimulating)

            // Speed control
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Speed")
                        .font(.headline)
                    Slider(value: $locationController.speed, in: 0...200, step: 5)
                    Text("\(Int(locationController.speed.rounded(.up))) km/h")
                        .font(.subheadline)
                }
                .padding(.vertical, 4)
            }

            if locationController.isSimulating {
                SimulationInfoPanel()
                    .environmentObject(locationController)
            }

            // Frequency
            GroupBox {
                if locationController.useRSD {
                    Picker("Frequency", selection: $locationController.timeScale) {
                        Text("5s").tag(5.0)
                        Text("10s").tag(10.0)
                        Text("15s").tag(15.0)
                    }
                    .pickerStyle(.segmented)
                    .disabled(locationController.isSimulating)
                    .onAppear {
                        locationController.timeScale = 5.0
                    }
                } else {
                    Picker("Frequency", selection: $locationController.timeScale) {
                        Text("0.5s").tag(0.5)
                        Text("1s").tag(1.0)
                        Text("1.5s").tag(1.5)
                        Text("2s").tag(2.0)
                    }
                    .pickerStyle(.segmented)
                    .disabled(locationController.isSimulating)
                }
            }

            // Simulation controls
            HStack {
                if locationController.isSimulating {
                    // Pause/Resume button
                    Button(action: {
                        if locationController.isPaused {
                            locationController.resumeSimulation()
                        } else {
                            locationController.pauseSimulation()
                        }
                    }, label: {
                        Text(locationController.isPaused ? "Resume" : "Pause")
                            .frame(maxWidth: .infinity)
                    })

                    // Stop button
                    Button(action: {
                        locationController.stopSimulation()
                    }, label: {
                        Text("Stop")
                            .frame(maxWidth: .infinity)
                    })
                } else {
                    // Start button
                    Button(action: {
                        locationController.simulateDirectionRoute()
                    }, label: {
                        Text("Start Simulation")
                            .frame(maxWidth: .infinity)
                    })
                    .disabled(locationController.waypoints.count < 2)
                }
            }

            Spacer()
        }
    }
}

// MARK: - Simulation Info Panel

struct SimulationInfoPanel: View {
    @EnvironmentObject var locationController: LocationController

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                Text("Simulation")
                    .font(.headline)

                HStack {
                    Image(systemName: "speedometer")
                        .foregroundColor(.blue)
                    Text("Speed:")
                        .font(.subheadline)
                    Spacer()
                    Text(String(format: "%.1f km/h", locationController.currentSimSpeed * 3.6))
                        .font(.subheadline)
                        .monospacedDigit()
                }

                HStack {
                    Image(systemName: "location.north.fill")
                        .foregroundColor(.blue)
                        .rotationEffect(.degrees(locationController.currentSimCourse >= 0 ? locationController.currentSimCourse : 0))
                    Text("Heading:")
                        .font(.subheadline)
                    Spacer()
                    if locationController.currentSimCourse >= 0 {
                        Text(String(format: "%.0f\u{00B0} %@", locationController.currentSimCourse, compassDirection(for: locationController.currentSimCourse)))
                            .font(.subheadline)
                            .monospacedDigit()
                    } else {
                        Text("--")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func compassDirection(for degrees: Double) -> String {
        let directions = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        let index = Int(((degrees + 22.5) / 45.0).truncatingRemainder(dividingBy: 8))
        return directions[index]
    }
}

// Waypoint row view
struct WaypointRow: View {
    let index: Int
    let waypoint: MKPointAnnotation
    let isSimulating: Bool
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            // Drag handle icon
            Image(systemName: "line.3.horizontal")
                .foregroundColor(.secondary)
                .font(.caption)
                .opacity(isSimulating ? 0.3 : 1.0)  // Dim during simulation

            // Waypoint number
            Text("\(index + 1).")
                .font(.headline)
                .foregroundColor(.blue)
                .frame(width: 30, alignment: .leading)

            // Coordinates
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Lat:")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(String(format: "%.4f", waypoint.coordinate.latitude))
                        .font(.caption)
                }
                HStack {
                    Text("Lng:")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(String(format: "%.4f", waypoint.coordinate.longitude))
                        .font(.caption)
                }
            }

            Spacer()

            // Delete button
            Button(action: onDelete) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(isSimulating ? .gray : .red)
            }
            .buttonStyle(.plain)
            .disabled(isSimulating)  // Disable during simulation
        }
        .padding(6)
        .background(Color.gray.opacity(0.1))
        .cornerRadius(6)
    }
}
