//
//  LocationsView.swift
//  SimVirtualLocation
//
//  Created by Sergey Shirnin on 19.11.2023.
//

import SwiftUI

struct LocationsView: View {

    @EnvironmentObject var locationController: LocationController

    @State private var renameAlertShowing = false
    @State private var updatedName = ""
    @State private var selectedLocation = Location(name: "", latitude: .zero, longitude: .zero)

    var body: some View {
        VStack {
            Text("Locations")

            List {
                ForEach(locationController.savedLocations, id: \.id) { location in
                    VStack(alignment: .leading) {
                        Text(location.name)
                        HStack {
                            Button("To map") {
                                locationController.putLocationOnMap(location: location)
                            }

                            Button("Delete") {
                                locationController.removeLocation(location: location)
                            }

                            Button("Rename") {
                                updatedName = ""
                                selectedLocation = location
                                renameAlertShowing.toggle()
                            }

                            Spacer()
                        }
                    }
                }
                .padding()
                .background(Color.gray.opacity(0.25))
                .cornerRadius(8)
            }
            .cornerRadius(16)
            .alert("Rename \(selectedLocation.name)", isPresented: $renameAlertShowing) {
                TextField("Enter new name", text: $updatedName)
                Button("Rename") {
                    locationController.update(selectedLocation, with: updatedName)
                }
                Button("Cancel") {
                    renameAlertShowing.toggle()
                }
            }
        }
    }
}

struct LocationsView_Previews: PreviewProvider {
    static var previews: some View {
        LocationsView()
    }
}
