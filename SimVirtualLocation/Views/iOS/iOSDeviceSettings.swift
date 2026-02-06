//
//  iOSDeviceSettings.swift
//  SimVirtualLocation
//
//  Created by Sergey Shirnin on 18.04.2022.
//

import SwiftUI

struct iOSDeviceSettings: View {
    @EnvironmentObject var locationController: LocationController
    
    var body: some View {
        GroupBox {
            Picker("Device mode", selection: $locationController.deviceMode) {
                Text("Simulator").tag(LocationController.DeviceMode.simulator)
                Text("Device").tag(LocationController.DeviceMode.device)
            }.labelsHidden().pickerStyle(.segmented)

            if locationController.deviceMode == .simulator {
                Picker("Simulator:", selection: $locationController.selectedSimulator) {
                    ForEach(locationController.bootedSimulators, id: \.id) { simulator in
                        Text(simulator.name)
                    }
                }

                Button(action: {
                    Task {
                        await locationController.refreshDevices()
                    }
                }, label: {
                    Text("Refresh").frame(maxWidth: .infinity)
                })
            }

            if locationController.deviceMode == .device {
                HStack {
                    Text("Device:")
                        .frame(width: 60, alignment: .leading)

                    Picker("", selection: $locationController.selectedDevice) {
                        ForEach(locationController.connectedDevices, id: \.id) { device in
                            Text(device.displayName).tag(device.id)
                        }
                    }
                    .labelsHidden()

                    // Device status indicator
                    if locationController.deviceReady {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    } else if !locationController.deviceStatusMessage.isEmpty {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundColor(.orange)
                    }
                }

                // Connect / Disconnect / Refresh buttons
                HStack(spacing: 8) {
                    if locationController.deviceReady {
                        Button(action: {
                            locationController.disconnectDevice()
                        }, label: {
                            Text("Disconnect").frame(maxWidth: .infinity)
                        })
                    } else {
                        Button(action: {
                            Task {
                                await locationController.autoSetupDevice()
                            }
                        }, label: {
                            Text("Connect").frame(maxWidth: .infinity)
                        })
                        .disabled(locationController.selectedDevice.isEmpty)
                    }

                    Button(action: {
                        Task {
                            await locationController.refreshDevices()
                        }
                    }, label: {
                        Text("Refresh").frame(maxWidth: .infinity)
                    })
                }

                // Show status message
                if !locationController.deviceStatusMessage.isEmpty {
                    Text(locationController.deviceStatusMessage)
                        .font(.caption)
                        .foregroundColor(locationController.deviceReady ? .green : .secondary)
                        .padding(.vertical, 2)
                }

                // Only show advanced options if needed
                if let selectedDev = locationController.connectedDevices.first(where: { $0.id == locationController.selectedDevice }),
                   !selectedDev.requiresRSD {
                    // Pre-iOS 17 devices only
                    Divider()
                        .padding(.vertical, 4)

                    Text("Advanced (iOS 16 and below)")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    TextField("Xcode path", text: $locationController.xcodePath)
                        .font(.system(size: 10))

                    HStack(spacing: 4) {
                        Button(action: {
                            locationController.mountDeveloperImage()
                        }, label: {
                            Text("Mount").font(.caption)
                        })

                        Button(action: {
                            locationController.unmountDeveloperImage()
                        }, label: {
                            Text("Unmount").font(.caption)
                        })
                    }
                }
            }
        }
    }
}

struct iOSDeviceSettings_Previews: PreviewProvider {
    static var previews: some View {
        iOSDeviceSettings()
    }
}
