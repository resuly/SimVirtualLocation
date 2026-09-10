import Foundation
import CoreFoundation

/// The CLI and the app operate on the same controller, exclusively on the main queue.
extension LocationController {
    func handleControlRequest(_ request: [String: Any]) -> [String: Any] {
        dispatchPrecondition(condition: .onQueue(.main))
        func failure(_ message: String) -> [String: Any] { ["ok": false, "error": message] }
        func number(_ key: String, range: ClosedRange<Double>) -> Double? {
            guard let value = request[key] as? NSNumber,
                  CFGetTypeID(value) != CFBooleanGetTypeID(),
                  value.doubleValue.isFinite, range.contains(value.doubleValue) else { return nil }
            return value.doubleValue
        }
        guard let command = request["command"] as? String else { return failure("Missing command") }
        switch command {
        case "status": break
        case "simulators":
            return ["ok": true, "simulators": bootedSimulators.filter { !$0.id.isEmpty }.map {
                ["udid": $0.id, "name": $0.name]
            }]
        case "configure":
            let requestedSimulator = request["simulator"] as? String
            if request["simulator"] != nil {
                guard let id = requestedSimulator, !id.isEmpty,
                      bootedSimulators.contains(where: { $0.id == id }) else {
                    return failure("simulator must identify one booted simulator; use simulators first")
                }
                guard !isSimulating else { return failure("Stop simulation before changing the target") }
            }
            let requestedSpeed = number("speed_kmh", range: 0...200)
            if request["speed_kmh"] != nil && requestedSpeed == nil {
                return failure("speed_kmh must be a number between 0 and 200")
            }
            let requestedInterval = number("interval_s", range: 0.5...2)
            if request["interval_s"] != nil {
                guard requestedInterval != nil else { return failure("interval_s must be between 0.5 and 2") }
                guard !isSimulating else { return failure("Stop simulation before changing the interval") }
            }
            // Validate everything before mutating state.
            if let id = requestedSimulator { selectedSimulator = id; deviceMode = .simulator; deviceType = 0 }
            if let value = requestedSpeed { speed = value }
            if let value = requestedInterval { timeScale = value }
        case "load-route":
            guard let object = request["route"], JSONSerialization.isValidJSONObject(object),
                  let data = try? JSONSerialization.data(withJSONObject: object) else {
                return failure("route must be a GeoJSON LineString or Feature")
            }
            do { _ = try GeoJSONRouteParser.parse(data: data) }
            catch { return failure(error.localizedDescription) }
            importGeoJSONRoute(from: data)
        case "start":
            guard deviceMode == .simulator, deviceType == 0, !selectedSimulator.isEmpty,
                  bootedSimulators.contains(where: { $0.id == selectedSimulator }) else {
                return failure("Configure one booted iOS simulator before starting through the API")
            }
            guard importedRoute != nil else { return failure("Load an original GeoJSON route first") }
            guard speed > 0 else { return failure("Set a positive speed; use pause to stop moving") }
            guard !isSimulating else { return failure("Already running; use resume for a paused replay") }
            simulateImportedRoute()
            guard isSimulating else { return failure("Could not start replay") }
        case "pause":
            guard isSimulating else { return failure("No active replay") }
            pauseSimulation()
        case "resume":
            guard isSimulating && isPaused else { return failure("No paused replay") }
            guard speed > 0 else { return failure("Set a positive speed before resuming") }
            resumeSimulation()
        case "stop": stopSimulation()
        case "route":
            guard let route = importedRoute else { return failure("No imported route") }
            return ["ok": true, "source": "imported_geometry", "name": route.displayName,
                    "point_count": route.pointCount, "distance_m": route.distanceMeters,
                    "coordinates": route.coordinates.map { [$0.longitude, $0.latitude] }]
        case "debug":
            let data = getRouteDebugData()
            return ["ok": true, "source": importedRoute == nil ? "apple_maps" : "imported_geometry",
                    "summary": data.summary, "details": data.routeDetails,
                    "steps": data.navigationSteps, "polyline": data.polylineData]
        default: return failure("Unknown command: \(command)")
        }
        var state: [String: Any] = [
            "ok": true, "running": isSimulating, "paused": isPaused,
            "simulator": selectedSimulator, "speed_kmh": speed, "interval_s": timeScale,
            "requested_speed_mps": currentSimSpeed, "requested_course_deg": currentSimCourse,
            "injection_status": replayInjectionStatus,
            "source": importedRoute == nil ? "apple_maps" : "imported_geometry"
        ]
        if let error = replayError { state["injection_error"] = error }
        if let position = estimatedReplayPosition { state["estimated_position"] = position }
        if let route = importedRoute {
            state["route"] = ["name": route.displayName, "point_count": route.pointCount,
                              "distance_m": route.distanceMeters]
        }
        return state
    }
}
