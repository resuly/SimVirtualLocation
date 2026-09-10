//
//  GeoJSONRoute.swift
//  SimVirtualLocation
//

import Foundation

/// A two-dimensional GeoJSON position. GeoJSON stores positions as [longitude, latitude].
struct GeoJSONCoordinate: Hashable {
    let longitude: Double
    let latitude: Double
}

/// A route imported from a GeoJSON LineString. The coordinates are kept in the
/// exact order supplied by the file; no map matching or route calculation is done.
struct GeoJSONRoute {
    let name: String?
    let coordinates: [GeoJSONCoordinate]
    let distanceMeters: Double

    var pointCount: Int { coordinates.count }
    var displayName: String { name ?? "Imported route" }
}

enum GeoJSONRouteError: LocalizedError {
    case invalidJSON
    case invalidStructure
    case unsupportedType(String)
    case missingCoordinates
    case tooFewPoints
    case tooManyPoints(maximum: Int)
    case invalidCoordinate(index: Int)
    case notEnoughDistinctPoints

    var errorDescription: String? {
        switch self {
        case .invalidJSON:
            return "The file is not valid JSON."
        case .invalidStructure:
            return "Expected a GeoJSON LineString or Feature with a LineString geometry."
        case .unsupportedType(let type):
            return "Unsupported GeoJSON type: \(type). Only LineString is accepted."
        case .missingCoordinates:
            return "The GeoJSON LineString has no coordinates."
        case .tooFewPoints:
            return "The route must contain at least two coordinates."
        case .tooManyPoints(let maximum):
            return "The route contains too many points (maximum \(maximum))."
        case .invalidCoordinate(let index):
            return "Coordinate \(index + 1) must be [longitude, latitude] with finite values in range."
        case .notEnoughDistinctPoints:
            return "The route must contain at least two different coordinates."
        }
    }
}

enum GeoJSONRouteParser {
    /// Keep the import bounded so a malformed or accidental huge file cannot
    /// allocate an unbounded number of Track segments in the UI.
    static let maximumPointCount = 100_000

    private struct Document: Decodable {
        let type: String
        let coordinates: [[Double]]?
        let geometry: Geometry?
        let properties: Properties?
    }

    private struct Geometry: Decodable {
        let type: String
        let coordinates: [[Double]]?
    }

    private struct Properties: Decodable {
        let name: String?
    }

    static func parse(data: Data) throws -> GeoJSONRoute {
        let document: Document
        do {
            document = try JSONDecoder().decode(Document.self, from: data)
        } catch {
            throw GeoJSONRouteError.invalidJSON
        }

        let positions: [[Double]]
        let name: String?

        switch document.type {
        case "LineString":
            guard document.geometry == nil else {
                throw GeoJSONRouteError.invalidStructure
            }
            guard let coordinates = document.coordinates else {
                throw GeoJSONRouteError.missingCoordinates
            }
            positions = coordinates
            name = nil

        case "Feature":
            guard let geometry = document.geometry else {
                throw GeoJSONRouteError.invalidStructure
            }
            guard geometry.type == "LineString" else {
                throw GeoJSONRouteError.unsupportedType(geometry.type)
            }
            guard let coordinates = geometry.coordinates else {
                throw GeoJSONRouteError.missingCoordinates
            }
            positions = coordinates
            let trimmedName = document.properties?.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            name = trimmedName?.isEmpty == false ? trimmedName : nil

        default:
            throw GeoJSONRouteError.unsupportedType(document.type)
        }

        guard positions.count >= 2 else {
            throw GeoJSONRouteError.tooFewPoints
        }
        guard positions.count <= maximumPointCount else {
            throw GeoJSONRouteError.tooManyPoints(maximum: maximumPointCount)
        }

        var coordinates: [GeoJSONCoordinate] = []
        coordinates.reserveCapacity(positions.count)

        for (index, position) in positions.enumerated() {
            guard position.count >= 2 else {
                throw GeoJSONRouteError.invalidCoordinate(index: index)
            }

            let longitude = position[0]
            let latitude = position[1]
            guard longitude.isFinite,
                  latitude.isFinite,
                  (-180.0...180.0).contains(longitude),
                  (-90.0...90.0).contains(latitude) else {
                throw GeoJSONRouteError.invalidCoordinate(index: index)
            }

            coordinates.append(GeoJSONCoordinate(longitude: longitude, latitude: latitude))
        }

        guard Set(coordinates).count >= 2 else {
            throw GeoJSONRouteError.notEnoughDistinctPoints
        }

        let totalDistanceMeters = zip(coordinates, coordinates.dropFirst()).reduce(0.0) { total, pair in
            total + distanceMeters(from: pair.0, to: pair.1)
        }

        return GeoJSONRoute(name: name, coordinates: coordinates, distanceMeters: totalDistanceMeters)
    }

    private static func distanceMeters(from: GeoJSONCoordinate, to: GeoJSONCoordinate) -> Double {
        let earthRadiusMeters = 6_371_000.0
        let latitude1 = from.latitude * .pi / 180.0
        let latitude2 = to.latitude * .pi / 180.0
        let deltaLatitude = (to.latitude - from.latitude) * .pi / 180.0
        let deltaLongitude = (to.longitude - from.longitude) * .pi / 180.0

        let a = sin(deltaLatitude / 2.0) * sin(deltaLatitude / 2.0)
            + cos(latitude1) * cos(latitude2)
            * sin(deltaLongitude / 2.0) * sin(deltaLongitude / 2.0)
        let centralAngle = 2.0 * atan2(sqrt(a), sqrt(max(0.0, 1.0 - a)))
        return earthRadiusMeters * centralAngle
    }
}
