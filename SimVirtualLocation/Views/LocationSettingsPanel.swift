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

            // Show Direction panel when Direction mode is selected
            if locationController.pointsMode == .direction {
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

                    Button(action: {
                        locationController.stopSimulation()
                    }, label: {
                        Text("Stop simulation").frame(maxWidth: .infinity)
                    })
                }

                GroupBox {
                    VStack(alignment: .leading) {
                        Slider(value: $locationController.speed, in: 5...200, step: 5) {
                            Text("Speed")
                        }
                        Text("\(Int(locationController.speed.rounded(.up))) km/h")
                    }
                }

                GroupBox {
                    if locationController.useRSD {
                        Picker("Location update frequency", selection: $locationController.timeScale) {
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
                        Picker("Location update frequency", selection: $locationController.timeScale) {
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

// MARK: - Direction Panel

struct DirectionPanel: View {
    @EnvironmentObject var locationController: LocationController

    var body: some View {
        VStack {
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
                                ForEach(Array(locationController.waypoints.enumerated()), id: \.offset) { index, waypoint in
                                    WaypointRow(
                                        index: index,
                                        waypoint: waypoint,
                                        onDelete: {
                                            locationController.deleteWaypoint(at: index)
                                        }
                                    )
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
            .disabled(locationController.waypoints.isEmpty)

            // Speed control
            GroupBox {
                VStack(alignment: .leading) {
                    Slider(value: $locationController.speed, in: 5...200, step: 5) {
                        Text("Speed")
                    }
                    Text("\(Int(locationController.speed.rounded(.up))) km/h")
                }
            }

            // Location update frequency
            GroupBox {
                if locationController.useRSD {
                    Picker("Location update frequency", selection: $locationController.timeScale) {
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
                    Picker("Location update frequency", selection: $locationController.timeScale) {
                        Text("1s").tag(1.0)
                        Text("1.5s").tag(1.5)
                        Text("2s").tag(2.0)
                    }
                    .pickerStyle(.segmented)
                    .disabled(locationController.isSimulating)
                }
            }

            // Simulation controls
            Button(action: {
                if locationController.isSimulating {
                    locationController.stopSimulation()
                } else {
                    locationController.simulateDirectionRoute()
                }
            }, label: {
                Text(locationController.isSimulating ? "Stop Simulation" : "Start Simulation")
                    .frame(maxWidth: .infinity)
            })
            .disabled(locationController.waypoints.count < 2)

            Spacer()
        }
    }
}

// Waypoint row view
struct WaypointRow: View {
    let index: Int
    let waypoint: MKPointAnnotation
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            // Drag handle icon
            Image(systemName: "line.3.horizontal")
                .foregroundColor(.secondary)
                .font(.caption)

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
                    .foregroundColor(.red)
            }
            .buttonStyle(.plain)
        }
        .padding(6)
        .background(Color.gray.opacity(0.1))
        .cornerRadius(6)
    }
}
