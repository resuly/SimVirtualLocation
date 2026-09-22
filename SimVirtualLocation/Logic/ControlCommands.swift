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
            if importedTimeline != nil && isSimulating && (requestedSpeed != nil || requestedInterval != nil) {
                return failure("Stop the GPS timeline before changing constant replay settings")
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
        case "load-timeline":
            guard let object = request["timeline"], JSONSerialization.isValidJSONObject(object),
                  let data = try? JSONSerialization.data(withJSONObject: object) else {
                return failure("timeline must be a version 1 gps_samples document")
            }
            do { _ = try GPSSamplesTimelineParser.parse(data: data) }
            catch { return failure(error.localizedDescription) }
            importGPSSamplesTimeline(from: data)
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
        case "start-timeline":
            guard deviceMode == .simulator, deviceType == 0, !selectedSimulator.isEmpty,
                  bootedSimulators.contains(where: { $0.id == selectedSimulator }) else {
                return failure("Configure one booted iOS simulator before starting through the API")
            }
            guard importedTimeline != nil else { return failure("Load a gps_samples timeline first") }
            guard !isSimulating else { return failure("Already running; use resume for a paused replay") }
            simulateGPSSamplesTimeline()
            guard isSimulating else { return failure("Could not start GPS timeline replay") }
        case "pause":
            guard isSimulating else { return failure("No active replay") }
            guard !timelineScheduleComplete else { return failure("GPS timeline schedule is already complete; use stop") }
            pauseSimulation()
        case "resume":
            guard isSimulating && isPaused else { return failure("No paused replay") }
            if importedTimeline != nil, let timeline = importedTimeline,
               timelineReplayIndex >= timeline.points.count - 1 {
                return failure("GPS timeline schedule is already complete; use stop")
            }
            if importedTimeline == nil {
                guard speed > 0 else { return failure("Set a positive speed before resuming") }
            }
            resumeSimulation()
        case "stop": stopSimulation()
        case "route":
            guard let route = importedRoute else { return failure("No imported route") }
            return ["ok": true, "source": "imported_geometry", "name": route.displayName,
                    "point_count": route.pointCount, "distance_m": route.distanceMeters,
                    "coordinates": route.coordinates.map { [$0.longitude, $0.latitude] }]
        case "timeline":
            guard let timeline = importedTimeline else { return failure("No GPS timeline imported") }
            return ["ok": true, "source": "gps_samples", "version": timeline.version,
                    "name": timeline.displayName, "duration_s": timeline.durationSeconds,
                    "point_count": timeline.pointCount, "max_gap_s": timeline.maxGapSeconds,
                    "points": timeline.points.map { timelinePointPayload($0) }]
        case "debug":
            let data = getRouteDebugData()
            return ["ok": true, "source": importedTimeline != nil ? "gps_samples" : (importedRoute == nil ? "apple_maps" : "imported_geometry"),
                    "summary": data.summary, "details": data.routeDetails,
                    "steps": data.navigationSteps, "polyline": data.polylineData]
        default: return failure("Unknown command: \(command)")
        }
        var state: [String: Any] = [
            "ok": true, "running": isSimulating, "paused": isPaused,
            "simulator": selectedSimulator, "speed_kmh": speed, "interval_s": timeScale,
            "requested_speed_mps": currentSimSpeed, "requested_course_deg": currentSimCourse,
            "injection_status": replayInjectionStatus,
            "source": importedTimeline != nil ? "gps_samples" : (importedRoute == nil ? "apple_maps" : "imported_geometry")
        ]
        if let error = replayError { state["injection_error"] = error }
        if let position = estimatedReplayPosition { state["estimated_position"] = position }
        if let route = importedRoute {
            state["route"] = ["name": route.displayName, "point_count": route.pointCount,
                              "distance_m": route.distanceMeters]
        }
        if let timeline = importedTimeline {
            state["timeline"] = ["name": timeline.displayName, "version": timeline.version,
                                  "point_count": timeline.pointCount,
                                  "duration_s": timeline.durationSeconds,
                                  "max_gap_s": timeline.maxGapSeconds]
            state["timeline_status"] = timelineReplayStatus
            state["timeline_index"] = timelineReplayIndex
            state["timeline_elapsed_s"] = timelineElapsedSeconds
            state["timeline_schedule_complete"] = timelineScheduleComplete
            state["timeline_injection_speed_source"] = timelineInjectionSpeedSource
            state["timeline_injection_speed_mode"] = timelineGapActive || timelineInjectionSpeedSource == "gap_unknown"
                ? "gap_unknown"
                : ((timelineInjectionSpeedSource == "stationary_unknown" || timelineInjectionSpeedSource == "gap_endpoint")
                    ? "stationary_unknown"
                    : (timelineUsedRecordedSpeed && timelineUsedGeometrySpeed
                    ? "mixed"
                    : (timelineUsedGeometrySpeed ? "geometry_derived" : (timelineUsedRecordedSpeed ? "recorded_speed_mps" : "none"))))
            state["timeline_injection_course_supported"] = false
            state["timeline_injection_accuracy_supported"] = false
            state["timeline_gap_active"] = timelineGapActive
            state["timeline_gap_status"] = timelineGapActive
                ? "unknown"
                : (timelineReplayStatus == "paused" && timelineGapStartIndex != nil ? "paused" : "none")
            if let index = timelineGapStartIndex { state["timeline_gap_start_index"] = index }
            if let index = timelineGapEndIndex { state["timeline_gap_end_index"] = index }
            if let duration = timelineGapDurationSeconds { state["timeline_gap_duration_s"] = duration }
            if let speed = timelineInjectionSpeedMps { state["timeline_injection_speed_mps"] = speed }
            if let speed = timelineRecordedSpeedMps { state["timeline_recorded_speed_mps"] = speed }
            if let accuracy = timelineRecordedAccuracyM { state["timeline_recorded_horizontal_accuracy_m"] = accuracy }
            if let course = timelineRecordedCourseDeg { state["timeline_recorded_course_deg"] = course }
        }
        return state
    }

    private func timelinePointPayload(_ point: GPSSample) -> [String: Any] {
        var payload: [String: Any] = [
            "elapsed_s": point.elapsedSeconds,
            "latitude": point.latitude,
            "longitude": point.longitude,
        ]
        payload["speed_mps"] = point.speedMps.map { $0 as Any } ?? NSNull()
        payload["horizontal_accuracy_m"] = point.horizontalAccuracyMeters.map { $0 as Any } ?? NSNull()
        payload["course_deg"] = point.courseDegrees.map { $0 as Any } ?? NSNull()
        return payload
    }
}
