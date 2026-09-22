//
//  GeoJSONRoute.swift
//  SimVirtualLocation
//

import Foundation
import CoreLocation

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

/// A timestamped location sample exported from a historical GPS recording.
/// The optional fields are retained for diagnostics even though simctl can only
/// inject latitude/longitude and one speed value for a running segment.
struct GPSSample: Hashable {
    let elapsedSeconds: Double
    let latitude: Double
    let longitude: Double
    let speedMps: Double?
    let horizontalAccuracyMeters: Double?
    let courseDegrees: Double?

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// A versioned, relative-time GPS recording. `points` remain in their source
/// order and are never map-matched or resampled during import.
struct GPSSamplesTimeline {
    static let defaultMaxGapSeconds = 10.0

    let version: Int
    let name: String?
    let maxGapSeconds: Double
    let points: [GPSSample]

    var displayName: String { name ?? "GPS samples" }
    var durationSeconds: Double { points.last?.elapsedSeconds ?? 0 }
    var pointCount: Int { points.count }
}

enum GPSSamplesTimelineError: LocalizedError {
    case invalidJSON
    case invalidType
    case unsupportedVersion(Int)
    case missingPoints
    case tooFewPoints
    case tooManyPoints(maximum: Int)
    case invalidElapsed(index: Int)
    case invalidCoordinate(index: Int)
    case invalidSpeed(index: Int)
    case invalidAccuracy(index: Int)
    case invalidCourse(index: Int)
    case invalidMaxGap

    var errorDescription: String? {
        switch self {
        case .invalidJSON:
            return "The GPS samples file is not valid JSON."
        case .invalidType:
            return "Expected a version 1 gps_samples document with a points array."
        case .unsupportedVersion(let version):
            return "Unsupported gps_samples version: \(version)."
        case .missingPoints:
            return "The gps_samples document has no points array."
        case .tooFewPoints:
            return "The GPS timeline must contain at least two points."
        case .tooManyPoints(let maximum):
            return "The GPS timeline contains too many points (maximum \(maximum))."
        case .invalidElapsed(let index):
            return "Point \(index + 1) elapsed_s must start at 0 and increase strictly."
        case .invalidCoordinate(let index):
            return "Point \(index + 1) latitude/longitude must be finite and in range."
        case .invalidSpeed(let index):
            return "Point \(index + 1) speed_mps must be finite and at least -1."
        case .invalidAccuracy(let index):
            return "Point \(index + 1) horizontal_accuracy_m must be finite and at least -1."
        case .invalidCourse(let index):
            return "Point \(index + 1) course_deg must be finite and between -1 and 360."
        case .invalidMaxGap:
            return "max_gap_s must be finite and greater than 0."
        }
    }
}

enum GPSSamplesTimelineParser {
    static let maximumPointCount = 100_000

    private struct Document: Decodable {
        let type: String?
        let version: Int
        let name: String?
        let maxGapSeconds: Double?
        let points: [RawPoint]?

        enum CodingKeys: String, CodingKey {
            case type
            case version
            case name
            case maxGapSeconds = "max_gap_s"
            case points
        }
    }

    private struct RawPoint: Decodable {
        let elapsedSeconds: Double
        let latitude: Double
        let longitude: Double
        let speedMps: Double?
        let horizontalAccuracyMeters: Double?
        let courseDegrees: Double?

        enum CodingKeys: String, CodingKey {
            case elapsedSeconds = "elapsed_s"
            case latitude
            case longitude
            case speedMps = "speed_mps"
            case horizontalAccuracyMeters = "horizontal_accuracy_m"
            case courseDegrees = "course_deg"
        }
    }

    static func parse(data: Data) throws -> GPSSamplesTimeline {
        let document: Document
        do {
            document = try JSONDecoder().decode(Document.self, from: data)
        } catch {
            throw GPSSamplesTimelineError.invalidJSON
        }

        guard document.type == nil || document.type == "gps_samples" else {
            throw GPSSamplesTimelineError.invalidType
        }
        guard document.version == 1 else {
            throw GPSSamplesTimelineError.unsupportedVersion(document.version)
        }
        let maxGapSeconds = document.maxGapSeconds ?? GPSSamplesTimeline.defaultMaxGapSeconds
        guard maxGapSeconds.isFinite, maxGapSeconds > 0 else {
            throw GPSSamplesTimelineError.invalidMaxGap
        }
        guard let rawPoints = document.points else {
            throw GPSSamplesTimelineError.missingPoints
        }
        guard rawPoints.count >= 2 else {
            throw GPSSamplesTimelineError.tooFewPoints
        }
        guard rawPoints.count <= maximumPointCount else {
            throw GPSSamplesTimelineError.tooManyPoints(maximum: maximumPointCount)
        }

        var points: [GPSSample] = []
        points.reserveCapacity(rawPoints.count)
        var previousElapsed: Double?

        for (index, raw) in rawPoints.enumerated() {
            guard raw.elapsedSeconds.isFinite,
                  raw.elapsedSeconds >= 0,
                  (index > 0 || raw.elapsedSeconds == 0),
                  previousElapsed.map({ raw.elapsedSeconds > $0 }) ?? true else {
                throw GPSSamplesTimelineError.invalidElapsed(index: index)
            }
            guard raw.latitude.isFinite,
                  raw.longitude.isFinite,
                  (-90.0...90.0).contains(raw.latitude),
                  (-180.0...180.0).contains(raw.longitude) else {
                throw GPSSamplesTimelineError.invalidCoordinate(index: index)
            }
            if let speed = raw.speedMps,
               (!speed.isFinite || speed < -1) {
                throw GPSSamplesTimelineError.invalidSpeed(index: index)
            }
            if let accuracy = raw.horizontalAccuracyMeters,
               (!accuracy.isFinite || accuracy < -1) {
                throw GPSSamplesTimelineError.invalidAccuracy(index: index)
            }
            if let course = raw.courseDegrees,
               (!course.isFinite || course < -1 || course > 360) {
                throw GPSSamplesTimelineError.invalidCourse(index: index)
            }

            points.append(GPSSample(
                elapsedSeconds: raw.elapsedSeconds,
                latitude: raw.latitude,
                longitude: raw.longitude,
                speedMps: raw.speedMps,
                horizontalAccuracyMeters: raw.horizontalAccuracyMeters,
                courseDegrees: raw.courseDegrees
            ))
            previousElapsed = raw.elapsedSeconds
        }

        let trimmedName = document.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        return GPSSamplesTimeline(
            version: document.version,
            name: trimmedName?.isEmpty == false ? trimmedName : nil,
            maxGapSeconds: maxGapSeconds,
            points: points
        )
    }
}
