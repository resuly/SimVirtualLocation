import CoreLocation
import Darwin
import Foundation

/// Debug-only, local timing trace for cold-start control/API diagnosis.
///
/// The trace deliberately records only event names, command names, epoch time,
/// and elapsed time. It never serializes a request, coordinate, or command
/// argument. Keeping this helper in this file also makes standalone replay
/// regression builds self-contained.
final class ControlTimingTrace {
  static let filePath = (NSHomeDirectory() as NSString)
    .appendingPathComponent("Library/Application Support/SimVirtualLocation/control-timing.jsonl")

  private static let queue = DispatchQueue(
    label: "com.resuly.SimVirtualLocation.control-timing-trace",
    qos: .utility
  )

  static func commandName(from request: [String: Any]) -> String {
    guard let command = request["command"] as? String, !command.isEmpty else {
      return "<missing>"
    }
    let sanitized = command.map { character in
      (character == "\n" || character == "\r") ? "_" : character
    }
    return String(sanitized.prefix(64))
  }

  static func record(
    event: String,
    command: String,
    at: Date = Date(),
    elapsed: TimeInterval? = nil
  ) {
#if DEBUG
    var object: [String: Any] = [
      "command": command,
      "epoch_ms": Int64(at.timeIntervalSince1970 * 1000),
      "event": event,
    ]
    if let elapsed {
      object["elapsed_ms"] = max(0, elapsed * 1000)
    }
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
      return
    }
    var line = data
    line.append(0x0A)
    queue.async {
      do {
        let directory = (filePath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
          atPath: directory,
          withIntermediateDirectories: true,
          attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        _ = chmod(directory, mode_t(0o700))
        if !FileManager.default.fileExists(atPath: filePath) {
          FileManager.default.createFile(
            atPath: filePath,
            contents: nil,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o600))]
          )
        }
        _ = chmod(filePath, mode_t(0o600))
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: filePath))
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
        try handle.close()
      } catch {
        // Diagnostics must never affect control/API behavior.
      }
    }
#endif
  }
}

enum SimulatorRouteReplayError: LocalizedError {
  case invalidDevice
  case invalidCoordinates
  case invalidSpeed
  case invalidInterval
  case invalidMaxGap
  case timeout
  case launch(String)
  case simctl(String)

  var errorDescription: String? {
    switch self {
    case .invalidDevice: return "A single simulator UUID is required."
    case .invalidCoordinates: return "The route must contain at least two finite coordinates within valid ranges."
    case .invalidSpeed: return "Speed must be finite, greater than 0, and no more than 200 km/h."
    case .invalidInterval: return "Interval must be between 0.5 and 2 seconds."
    case .invalidMaxGap: return "max_gap_s must be finite and greater than 0."
    case .timeout: return "simctl location timed out."
    case let .launch(message), let .simctl(message): return message
    }
  }
}

final class SimulatorRouteReplay {
  typealias Completion = (Result<Void, Error>) -> Void
  typealias TimelineProgress = (_ pointIndex: Int, _ coordinate: CLLocationCoordinate2D,
                                _ elapsedSeconds: Double, _ speedMps: Double?, _ speedSource: String) -> Void

  private let queue = DispatchQueue(label: "com.resuly.SimVirtualLocation.simulator-route-replay", qos: .utility)
  private let generationLock = NSLock()
  private let timelineCondition = NSCondition()
  private var generation: UInt64 = 0

  func start(device: String, coordinates: [CLLocationCoordinate2D], speedKmh: Double, interval: Double, completion: @escaping Completion) {
    let requestGeneration = nextGeneration()
    do {
      try Self.validateDevice(device)
      try Self.validateCoordinates(coordinates)
      guard speedKmh.isFinite, speedKmh > 0, speedKmh <= 200 else { throw SimulatorRouteReplayError.invalidSpeed }
      guard interval.isFinite, (0.5...2).contains(interval) else { throw SimulatorRouteReplayError.invalidInterval }
    } catch {
      deliver(requestGeneration, completion: completion, result: .failure(error))
      return
    }

    queue.async { [weak self] in
      guard let self, self.isCurrent(requestGeneration) else { return }
      do {
        let route = coordinates.map { "\($0.latitude),\($0.longitude)" }
          .joined(separator: "\n") + "\n"
        let metersPerSecond = speedKmh / 3.6
        let outcome = try self.run(
          arguments: [
            "simctl", "location", device, "start",
            "--speed=\(String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), metersPerSecond))",
            "--interval=\(String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), interval))", "-",
          ],
          input: Data(route.utf8)
        )
        guard self.isCurrent(requestGeneration) else { return }
        try Self.validateStartOutcome(outcome, waypointCount: coordinates.count)
        self.deliver(requestGeneration, completion: completion, result: .success(()))
      } catch {
        self.deliver(requestGeneration, completion: completion, result: .failure(error))
      }
    }
  }

  func clear(device: String, completion: Completion? = nil) {
    let requestGeneration = nextGeneration()
    do {
      try Self.validateDevice(device)
    } catch {
      if let completion {
        deliver(requestGeneration, completion: completion, result: .failure(error))
      }
      return
    }

    queue.async { [weak self] in
      // A later start may supersede a callback, but must never cancel cleanup
      // of the old device. The serial queue makes clear a fence before start.
      guard let self else { return }
      do {
        let outcome = try self.run(arguments: ["simctl", "location", device, "clear"])
        guard self.isCurrent(requestGeneration) else { return }
        try Self.validateClearOutcome(outcome)
        if let completion {
          self.deliver(requestGeneration, completion: completion, result: .success(()))
        }
      } catch {
        if let completion {
          self.deliver(requestGeneration, completion: completion, result: .failure(error))
        }
      }
    }
  }

  /// Replays timestamped GPS samples by scheduling one simctl scenario per
  /// moving segment.  simctl has no timestamp, course, or accuracy arguments;
  /// the caller receives the selected speed source so the API can report that
  /// limitation instead of presenting derived values as recorded telemetry.
  func startTimeline(
    device: String,
    points: [GPSSample],
    maxGapSeconds: Double,
    progress: @escaping TimelineProgress,
    completion: @escaping Completion
  ) {
    let requestGeneration = nextGeneration()
    do {
      try Self.validateDevice(device)
      try Self.validateTimeline(points)
      guard maxGapSeconds.isFinite, maxGapSeconds > 0 else {
        throw SimulatorRouteReplayError.invalidMaxGap
      }
    } catch {
      deliver(requestGeneration, completion: completion, result: .failure(error))
      return
    }

    queue.async { [weak self] in
      guard let self, self.isCurrent(requestGeneration) else { return }
      do {
        let first = points[0]
        let firstSetStartedAt = Date()
        ControlTimingTrace.record(event: "timeline_first_set_start", command: "simctl.location.set", at: firstSetStartedAt)
        let firstOutcome: Outcome
        do {
          firstOutcome = try self.run(arguments: Self.timelineSetArguments(
            device: device,
            coordinate: first.coordinate
          ))
        } catch {
          ControlTimingTrace.record(
            event: "timeline_first_set_end",
            command: "simctl.location.set",
            elapsed: Date().timeIntervalSince(firstSetStartedAt)
          )
          throw error
        }
        ControlTimingTrace.record(
          event: "timeline_first_set_end",
          command: "simctl.location.set",
          elapsed: Date().timeIntervalSince(firstSetStartedAt)
        )
        try Self.validateSetOutcome(firstOutcome)
        // The first point is the replay origin. Start the relative clock after
        // simctl has accepted that origin, so command startup latency does not
        // shorten the first recorded interval.
        let startedAt = Date()
        self.deliverTimelineProgress(
          requestGeneration,
          progress: progress,
          pointIndex: 0,
          point: first,
          speedMps: nil,
          speedSource: "none"
        )

        for index in 1..<points.count {
          let start = points[index - 1]
          let end = points[index]
          guard self.waitUntil(
            startedAt.addingTimeInterval(start.elapsedSeconds),
            generation: requestGeneration
          ) else { return }

          if Self.isTimelineGap(start: start, end: end, maxGapSeconds: maxGapSeconds) {
            let clearOutcome = try self.run(arguments: ["simctl", "location", device, "clear"])
            try Self.validateClearOutcome(clearOutcome)
            self.deliverTimelineProgress(
              requestGeneration,
              progress: progress,
              pointIndex: index - 1,
              point: start,
              speedMps: nil,
              speedSource: "gap_unknown"
            )
            guard self.waitUntil(
              startedAt.addingTimeInterval(end.elapsedSeconds),
              generation: requestGeneration
            ) else { return }
            let endpointOutcome = try self.run(arguments: Self.timelineSetArguments(
              device: device,
              coordinate: end.coordinate
            ))
            try Self.validateSetOutcome(endpointOutcome)
            self.deliverTimelineProgress(
              requestGeneration,
              progress: progress,
              pointIndex: index,
              point: end,
              speedMps: nil,
              speedSource: "gap_endpoint"
            )
            continue
          }

          let distance = Self.distanceMeters(from: start.coordinate, to: end.coordinate)
          var progressSpeedMps: Double? = nil
          var progressSpeedSource = "stationary_unknown"
          if distance < 0.001 {
            let outcome = try self.run(arguments: Self.timelineSetArguments(
              device: device,
              coordinate: end.coordinate
            ))
            try Self.validateSetOutcome(outcome)
            // The command is accepted immediately. Publish the segment clock
            // at its origin before waiting for the recorded endpoint time.
            self.deliverTimelineProgress(
              requestGeneration,
              progress: progress,
              pointIndex: index - 1,
              point: start,
              speedMps: nil,
              speedSource: progressSpeedSource
            )
          } else {
            let segment = try Self.segmentSpeed(start: start, end: end, distance: distance)
            let interval = min(2.0, max(0.1, (end.elapsedSeconds - start.elapsedSeconds) / 2.0))
            let command = Self.timelineStartCommand(
              device: device,
              start: start.coordinate,
              end: end.coordinate,
              speedMps: segment.speedMps,
              interval: interval
            )
            let outcome = try self.run(arguments: command.arguments, input: command.input)
            try Self.validateStartOutcome(outcome, waypointCount: 2)
            progressSpeedMps = segment.speedMps
            progressSpeedSource = segment.source
            // simctl accepted the moving scenario. Report its source and
            // requested segment speed while the source clock is running.
            self.deliverTimelineProgress(
              requestGeneration,
              progress: progress,
              pointIndex: index - 1,
              point: start,
              speedMps: progressSpeedMps,
              speedSource: progressSpeedSource
            )
          }

          guard self.waitUntil(
            startedAt.addingTimeInterval(end.elapsedSeconds),
            generation: requestGeneration
          ) else { return }
          self.deliverTimelineProgress(
            requestGeneration,
            progress: progress,
            pointIndex: index,
            point: end,
            speedMps: progressSpeedMps,
            speedSource: progressSpeedSource
          )
        }

        // This only means the scheduler issued the final command and elapsed
        // through the source timeline. There is no simctl completion callback.
        self.deliver(requestGeneration, completion: completion, result: .success(()))
      } catch {
        self.deliver(requestGeneration, completion: completion, result: .failure(error))
      }
    }
  }

  /// NSApplication's termination notification cannot wait for an async callback.
  /// Drain the serial worker and clear its scenario before the owning app exits.
  func shutdown(device: String) {
    guard (try? Self.validateDevice(device)) != nil else { return }
    _ = nextGeneration()
    queue.sync {
      _ = try? self.run(arguments: ["simctl", "location", device, "clear"])
    }
  }

  private func nextGeneration() -> UInt64 {
    generationLock.lock()
    generation &+= 1
    let value = generation
    generationLock.unlock()
    timelineCondition.lock()
    timelineCondition.broadcast()
    timelineCondition.unlock()
    return value
  }

  private func isCurrent(_ value: UInt64) -> Bool {
    generationLock.lock(); defer { generationLock.unlock() }
    return generation == value
  }

  private func deliver(_ value: UInt64, completion: @escaping Completion, result: Result<Void, Error>) {
    guard isCurrent(value) else { return }
    DispatchQueue.main.async { [weak self] in
      guard self?.isCurrent(value) == true else { return }
      completion(result)
    }
  }

  private func deliverTimelineProgress(
    _ value: UInt64,
    progress: @escaping TimelineProgress,
    pointIndex: Int,
    point: GPSSample,
    speedMps: Double?,
    speedSource: String
  ) {
    guard isCurrent(value) else { return }
    DispatchQueue.main.async { [weak self] in
      guard self?.isCurrent(value) == true else { return }
      progress(pointIndex, point.coordinate, point.elapsedSeconds, speedMps, speedSource)
    }
  }

  private static func validateDevice(_ device: String) throws {
    let shape = device.split(separator: "-", omittingEmptySubsequences: false).map(\.count)
    guard shape == [8, 4, 4, 4, 12], UUID(uuidString: device) != nil else { throw SimulatorRouteReplayError.invalidDevice }
  }

  private static func validateCoordinates(_ coordinates: [CLLocationCoordinate2D]) throws {
    guard coordinates.count >= 2 else { throw SimulatorRouteReplayError.invalidCoordinates }
    for coordinate in coordinates {
      guard coordinate.latitude.isFinite, coordinate.longitude.isFinite,
            (-90...90).contains(coordinate.latitude), (-180...180).contains(coordinate.longitude)
      else { throw SimulatorRouteReplayError.invalidCoordinates }
    }
  }

  private static func validateTimeline(_ points: [GPSSample]) throws {
    guard points.count >= 2 else { throw SimulatorRouteReplayError.invalidCoordinates }
    var previousElapsed: Double?
    for point in points {
      guard point.elapsedSeconds.isFinite,
            point.elapsedSeconds >= 0,
            previousElapsed.map({ point.elapsedSeconds > $0 }) ?? (point.elapsedSeconds == 0),
            point.latitude.isFinite,
            point.longitude.isFinite,
            (-90...90).contains(point.latitude),
            (-180...180).contains(point.longitude) else {
        throw SimulatorRouteReplayError.invalidCoordinates
      }
      previousElapsed = point.elapsedSeconds
    }
  }

  static func isTimelineGap(start: GPSSample, end: GPSSample, maxGapSeconds: Double) -> Bool {
    end.elapsedSeconds - start.elapsedSeconds > maxGapSeconds
  }

  private struct TimelineSegmentSpeed {
    let speedMps: Double
    let source: String
  }

  private static func segmentSpeed(
    start: GPSSample,
    end: GPSSample,
    distance: Double
  ) throws -> TimelineSegmentSpeed {
    let duration = end.elapsedSeconds - start.elapsedSeconds
    let derived = distance / duration
    guard derived.isFinite, derived > 0 else {
      throw SimulatorRouteReplayError.invalidSpeed
    }

    // A single simctl segment must reach the next source point at its
    // timestamp. Keep a recorded speed only when it is close enough to the
    // geometric speed to satisfy that timing; otherwise use the geometric
    // speed and expose the recorded value through the API for comparison.
    let recordedSpeed: Double? = [end.speedMps, start.speedMps].compactMap { value -> Double? in
      guard let value, value.isFinite, value > 0 else { return nil }
      return value
    }.first
    if let recordedSpeed,
       abs(recordedSpeed - derived) / max(derived, 0.1) <= 0.10 {
      return TimelineSegmentSpeed(speedMps: recordedSpeed, source: "recorded_speed_mps")
    }
    return TimelineSegmentSpeed(speedMps: derived, source: "geometry_derived")
  }

  private static func distanceMeters(
    from: CLLocationCoordinate2D,
    to: CLLocationCoordinate2D
  ) -> Double {
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

  private static func coordinateArgument(_ coordinate: CLLocationCoordinate2D) -> String {
    "\(coordinate.latitude),\(coordinate.longitude)"
  }

  static func timelineSetArguments(device: String, coordinate: CLLocationCoordinate2D) -> [String] {
    ["simctl", "location", device, "set", coordinateArgument(coordinate)]
  }

  static func timelineStartCommand(
    device: String,
    start: CLLocationCoordinate2D,
    end: CLLocationCoordinate2D,
    speedMps: Double,
    interval: Double
  ) -> (arguments: [String], input: Data) {
    let route = coordinateArgument(start) + "\n" + coordinateArgument(end) + "\n"
    return (
      [
        "simctl", "location", device, "start",
        "--speed=\(format(speedMps))",
        "--interval=\(format(interval))",
        "-",
      ],
      Data(route.utf8)
    )
  }

  private static func format(_ value: Double) -> String {
    String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), value)
  }

  private func waitUntil(_ deadline: Date, generation: UInt64) -> Bool {
    while isCurrent(generation) {
      let remaining = deadline.timeIntervalSinceNow
      if remaining <= 0 { return true }
      timelineCondition.lock()
      timelineCondition.wait(until: Date().addingTimeInterval(min(remaining, 0.25)))
      timelineCondition.unlock()
    }
    return false
  }

  private struct Outcome {
    let status: Int32
    let stdout: String
    let stderr: String
    let timedOut: Bool

    var text: String { [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n") }
    var lowercasedText: String { text.lowercased() }
  }

  private final class DataBox { var data = Data() }

  private func run(arguments: [String], input: Data? = nil) throws -> Outcome {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = arguments
    let outputPipe = Pipe(), errorPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = errorPipe

    let stdout = DataBox()
    let stderr = DataBox()
    let outputReaders = DispatchGroup()
    for (pipe, box) in [(outputPipe, stdout), (errorPipe, stderr)] {
      outputReaders.enter()
      DispatchQueue.global(qos: .utility).async {
        box.data = pipe.fileHandleForReading.readDataToEndOfFile()
        outputReaders.leave()
      }
    }

    let inputPipe = input.map { _ in Pipe() }
    if let inputPipe { process.standardInput = inputPipe }

    do {
      try process.run()
    } catch {
      outputPipe.fileHandleForWriting.closeFile(); errorPipe.fileHandleForWriting.closeFile()
      inputPipe?.fileHandleForWriting.closeFile()
      outputPipe.fileHandleForReading.closeFile(); errorPipe.fileHandleForReading.closeFile()
      _ = outputReaders.wait(timeout: .now() + 1)
      throw SimulatorRouteReplayError.launch(error.localizedDescription)
    }

    if let input, let inputPipe {
      DispatchQueue.global(qos: .utility).async {
        try? inputPipe.fileHandleForWriting.write(contentsOf: input); try? inputPipe.fileHandleForWriting.close()
      }
    }

    let waiter = DispatchGroup()
    waiter.enter()
    DispatchQueue.global(qos: .utility).async {
      process.waitUntilExit()
      waiter.leave()
    }

    var timedOut = waiter.wait(timeout: .now() + 5) == .timedOut
    if timedOut {
      process.terminate()
      if waiter.wait(timeout: .now() + 5) == .timedOut {
        _ = kill(process.processIdentifier, SIGKILL)
        _ = waiter.wait(timeout: .now() + 1)
      }
    }
    if outputReaders.wait(timeout: .now() + 1) == .timedOut {
      outputPipe.fileHandleForReading.closeFile(); errorPipe.fileHandleForReading.closeFile()
      _ = outputReaders.wait(timeout: .now() + 1)
    }

    if !timedOut, process.isRunning {
      timedOut = true
    }
    return Outcome(status: process.terminationStatus,
                   stdout: String(decoding: stdout.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
                   stderr: String(decoding: stderr.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
                   timedOut: timedOut)
  }

  private static func validateStartOutcome(_ outcome: Outcome, waypointCount: Int) throws {
    guard !outcome.timedOut else { throw SimulatorRouteReplayError.timeout }
    let text = outcome.lowercasedText
    if text.contains("invalid") || text.contains("error") {
      throw SimulatorRouteReplayError.simctl(outcome.text)
    }
    guard outcome.status == 0, text.contains("parsed \(waypointCount) waypoints") else {
      throw SimulatorRouteReplayError.simctl(outcome.text.isEmpty ? "simctl returned no success marker." : outcome.text)
    }
  }

  private static func validateClearOutcome(_ outcome: Outcome) throws {
    guard !outcome.timedOut else { throw SimulatorRouteReplayError.timeout }
    let text = outcome.lowercasedText
    guard outcome.status == 0, !text.contains("invalid"), !text.contains("error") else {
      throw SimulatorRouteReplayError.simctl(outcome.text)
    }
  }

  private static func validateSetOutcome(_ outcome: Outcome) throws {
    guard !outcome.timedOut else { throw SimulatorRouteReplayError.timeout }
    let text = outcome.lowercasedText
    guard outcome.status == 0, !text.contains("invalid"), !text.contains("error") else {
      throw SimulatorRouteReplayError.simctl(outcome.text)
    }
  }
}
