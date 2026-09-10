import CoreLocation
import Darwin
import Foundation

enum SimulatorRouteReplayError: LocalizedError {
  case invalidDevice
  case invalidCoordinates
  case invalidSpeed
  case invalidInterval
  case timeout
  case launch(String)
  case simctl(String)

  var errorDescription: String? {
    switch self {
    case .invalidDevice: return "A single simulator UUID is required."
    case .invalidCoordinates: return "The route must contain at least two finite coordinates within valid ranges."
    case .invalidSpeed: return "Speed must be finite, greater than 0, and no more than 200 km/h."
    case .invalidInterval: return "Interval must be between 0.5 and 2 seconds."
    case .timeout: return "simctl location timed out."
    case let .launch(message), let .simctl(message): return message
    }
  }
}

final class SimulatorRouteReplay {
  typealias Completion = (Result<Void, Error>) -> Void

  private let queue = DispatchQueue(label: "com.resuly.SimVirtualLocation.simulator-route-replay", qos: .utility)
  private let generationLock = NSLock()
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
    generationLock.lock(); defer { generationLock.unlock() }
    generation &+= 1
    return generation
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
}
