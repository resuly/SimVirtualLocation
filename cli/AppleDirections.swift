import CoreFoundation
import CoreLocation
import Darwin
import Foundation
import MapKit

// Apple Maps output is diagnostic only. It must not be treated as legal road-event data.

private let maximumWaypointCount = 25
private let directionsTimeout: TimeInterval = 60

private struct CLIError: LocalizedError {
  let message: String

  var errorDescription: String? { message }
}

private struct Waypoint {
  let longitude: Double
  let latitude: Double

  var coordinate: CLLocationCoordinate2D {
    CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
  }
}

private func readInputData() throws -> Data {
  guard CommandLine.arguments.count == 2 else {
    throw CLIError(message: "Usage: AppleDirections <waypoints.json|->")
  }

  let inputPath = CommandLine.arguments[1]
  if inputPath == "-" {
    return FileHandle.standardInput.readDataToEndOfFile()
  }

  do {
    return try Data(contentsOf: URL(fileURLWithPath: inputPath))
  } catch {
    throw CLIError(message: "Could not read input file: \(error.localizedDescription)")
  }
}

private func parseNumber(_ value: Any, waypointIndex: Int, axis: String) throws -> Double {
  guard
    let number = value as? NSNumber,
    CFGetTypeID(number) != CFBooleanGetTypeID()
  else {
    throw CLIError(message: "Waypoint \(waypointIndex + 1) \(axis) must be a finite number.")
  }

  let result = number.doubleValue
  guard result.isFinite else {
    throw CLIError(message: "Waypoint \(waypointIndex + 1) \(axis) must be a finite number.")
  }
  return result
}

private func parseWaypoints() throws -> [Waypoint] {
  let data = try readInputData()
  guard !data.isEmpty else {
    throw CLIError(message: "Input is empty; expected a JSON array of [longitude, latitude] pairs.")
  }

  let json: Any
  do {
    json = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
  } catch {
    throw CLIError(message: "Input is not valid JSON.")
  }

  guard let rawWaypoints = json as? [Any] else {
    throw CLIError(message: "Input must be a JSON array of [longitude, latitude] pairs.")
  }
  guard rawWaypoints.count >= 2, rawWaypoints.count <= maximumWaypointCount else {
    throw CLIError(message: "Input must contain 2...\(maximumWaypointCount) waypoints.")
  }

  return try rawWaypoints.enumerated().map { index, rawWaypoint in
    guard let pair = rawWaypoint as? [Any], pair.count == 2 else {
      throw CLIError(
        message: "Waypoint \(index + 1) must contain exactly [longitude, latitude]."
      )
    }

    let longitude = try parseNumber(pair[0], waypointIndex: index, axis: "longitude")
    let latitude = try parseNumber(pair[1], waypointIndex: index, axis: "latitude")
    guard (-180...180).contains(longitude) else {
      throw CLIError(message: "Waypoint \(index + 1) longitude must be in -180...180.")
    }
    guard (-90...90).contains(latitude) else {
      throw CLIError(message: "Waypoint \(index + 1) latitude must be in -90...90.")
    }

    return Waypoint(longitude: longitude, latitude: latitude)
  }
}

private func coordinates(from polyline: MKPolyline) -> [[Double]] {
  guard polyline.pointCount > 0 else { return [] }
  let points = polyline.points()
  return (0..<polyline.pointCount).map { index in
    let coordinate = points[index].coordinate
    return [coordinate.longitude, coordinate.latitude]
  }
}

private func stepPayload(_ step: MKRoute.Step) -> [String: Any] {
  var payload: [String: Any] = [
    "instructions": step.instructions,
    "distance": step.distance,
    "coordinates": coordinates(from: step.polyline),
  ]
  if let notice = step.notice {
    payload["notice"] = notice
  } else {
    payload["notice"] = NSNull()
  }
  return payload
}

private func segmentPayload(_ route: MKRoute, polylineCoordinates: [[Double]]) -> [String: Any] {
  let hasTolls: Bool
  let hasHighways: Bool
  if #available(macOS 13.0, *) {
    hasTolls = route.hasTolls
    hasHighways = route.hasHighways
  } else {
    hasTolls = false
    hasHighways = false
  }

  return [
    "name": route.name,
    "distance": route.distance,
    "duration": route.expectedTravelTime,
    "hasTolls": hasTolls,
    "hasHighways": hasHighways,
    "advisoryNotices": route.advisoryNotices,
    "coordinates": polylineCoordinates,
    "steps": route.steps.map(stepPayload),
  ]
}

private struct SegmentResult {
  let route: MKRoute
  let coordinates: [[Double]]
  let payload: [String: Any]
}

private final class DirectionsRunner {
  private let waypoints: [Waypoint]
  private let deadline: Date
  private var results: [SegmentResult?]
  private var currentDirections: MKDirections?
  private var finished = false

  private(set) var output: [String: Any]?

  init(waypoints: [Waypoint]) {
    self.waypoints = waypoints
    deadline = Date().addingTimeInterval(directionsTimeout)
    results = Array(repeating: nil, count: waypoints.count - 1)
  }

  func start() {
    DispatchQueue.main.asyncAfter(deadline: .now() + directionsTimeout) { [weak self] in
      self?.finishFailure("Apple Maps request timed out after 60 seconds.")
    }
    requestSegment(at: 0)
  }

  private func requestSegment(at index: Int) {
    guard !finished else { return }
    guard Date() < deadline else {
      finishFailure("Apple Maps request timed out after 60 seconds.")
      return
    }

    let request = MKDirections.Request()
    request.source = MKMapItem(placemark: MKPlacemark(coordinate: waypoints[index].coordinate))
    request.destination = MKMapItem(
      placemark: MKPlacemark(coordinate: waypoints[index + 1].coordinate)
    )
    request.transportType = .automobile

    let directions = MKDirections(request: request)
    currentDirections = directions
    directions.calculate { [weak self] response, error in
      DispatchQueue.main.async { [weak self] in
        self?.handle(
          segmentIndex: index,
          response: response,
          error: error
        )
      }
    }
  }

  private func handle(
    segmentIndex: Int,
    response: MKDirections.Response?,
    error: Error?
  ) {
    guard !finished else { return }
    currentDirections = nil

    if Date() >= deadline {
      finishFailure("Apple Maps request timed out after 60 seconds.")
      return
    }
    if let error {
      finishFailure("Segment \(segmentIndex + 1) failed: \(error.localizedDescription)")
      return
    }
    guard let route = response?.routes.first else {
      finishFailure("Segment \(segmentIndex + 1) failed: Apple Maps returned no route.")
      return
    }

    let polylineCoordinates = coordinates(from: route.polyline)
    guard !polylineCoordinates.isEmpty else {
      finishFailure("Segment \(segmentIndex + 1) failed: Apple Maps returned no polyline.")
      return
    }
    guard route.distance.isFinite, route.distance >= 0,
          route.expectedTravelTime.isFinite, route.expectedTravelTime >= 0 else {
      finishFailure("Segment \(segmentIndex + 1) failed: Apple Maps returned invalid metrics.")
      return
    }

    results[segmentIndex] = SegmentResult(
      route: route,
      coordinates: polylineCoordinates,
      payload: segmentPayload(route, polylineCoordinates: polylineCoordinates)
    )

    if segmentIndex + 1 < results.count {
      requestSegment(at: segmentIndex + 1)
    } else {
      finishSuccess()
    }
  }

  private func finishSuccess() {
    guard !finished else { return }
    let completeResults = results.compactMap { $0 }
    guard completeResults.count == results.count else {
      finishFailure("Apple Maps returned only a partial route.")
      return
    }

    var mergedCoordinates: [[Double]] = []
    for result in completeResults {
      var segmentCoordinates = result.coordinates
      if
        let first = segmentCoordinates.first,
        let last = mergedCoordinates.last,
        first.count == 2,
        last.count == 2,
        first[0] == last[0],
        first[1] == last[1]
      {
        segmentCoordinates.removeFirst()
      }
      mergedCoordinates.append(contentsOf: segmentCoordinates)
    }
    guard !mergedCoordinates.isEmpty else {
      finishFailure("Apple Maps returned an empty route polyline.")
      return
    }

    output = [
      "source": "apple_maps",
      "distance_m": completeResults.reduce(0) { $0 + $1.route.distance },
      "duration_s": completeResults.reduce(0) { $0 + $1.route.expectedTravelTime },
      "coordinates": mergedCoordinates,
      "segments": completeResults.map(\.payload),
    ]
    finish()
  }

  private func finishFailure(_ message: String) {
    guard !finished else { return }
    output = [
      "source": "apple_maps",
      "error": message,
    ]
    finish()
  }

  private func finish() {
    guard !finished else { return }
    finished = true
    currentDirections?.cancel()
    currentDirections = nil
    CFRunLoopStop(CFRunLoopGetMain())
  }
}

private func emitJSON(_ object: [String: Any], status: Int32) -> Never {
  do {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0A]))
  } catch {
    let fallback = "{\"source\":\"apple_maps\",\"error\":\"Output serialization failed.\"}\n"
    FileHandle.standardOutput.write(Data(fallback.utf8))
    exit(1)
  }
  exit(status)
}

do {
  let waypoints = try parseWaypoints()
  let runner = DirectionsRunner(waypoints: waypoints)
  runner.start()
  CFRunLoopRun()

  guard let output = runner.output else {
    emitJSON(
      ["source": "apple_maps", "error": "Apple Maps request ended without a result."],
      status: 1
    )
  }
  emitJSON(output, status: output["error"] == nil ? 0 : 1)
} catch {
  emitJSON(["source": "apple_maps", "error": error.localizedDescription], status: 1)
}
