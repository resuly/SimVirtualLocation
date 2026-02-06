//
//  RoutePreset.swift
//  SimVirtualLocation
//

import Foundation
import CoreLocation

struct RoutePreset: Codable, Identifiable {
    var id: String { name }
    let name: String
    let coordinates: [Coordinate]

    struct Coordinate: Codable {
        let latitude: Double
        let longitude: Double

        var clCoordinate: CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }
    }

    static let builtIn: [RoutePreset] = [
        RoutePreset(
            name: "Heatherton 1",
            coordinates: [
                Coordinate(latitude: -37.9482, longitude: 145.0808),
                Coordinate(latitude: -37.9373, longitude: 145.0869),
                Coordinate(latitude: -37.9534, longitude: 145.0714),
                Coordinate(latitude: -37.9485, longitude: 145.0810),
            ]
        ),
    ]
}
