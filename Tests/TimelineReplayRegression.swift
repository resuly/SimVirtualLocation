import CoreLocation
import Foundation

/// A simulator-free regression executable. It checks the command shape that
/// protects negative coordinates and the default long-gap decision without
/// invoking xcrun or writing to any simulator.
@main
struct TimelineReplayRegression {
    static func main() {
        let device = "00000000-0000-0000-0000-000000000000"
        let start = CLLocationCoordinate2D(latitude: -10.5, longitude: 20.25)
        let end = CLLocationCoordinate2D(latitude: -10.4999, longitude: 20.2501)

        let command = SimulatorRouteReplay.timelineStartCommand(
            device: device,
            start: start,
            end: end,
            speedMps: 4.0,
            interval: 1.0
        )
        precondition(command.arguments.last == "-", "moving coordinates must use simctl stdin")
        precondition(!command.arguments.contains { $0.contains("-10.5") },
                     "negative coordinates must not be positional start arguments")
        let inputLines = String(decoding: command.input, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        precondition(inputLines == ["-10.5,20.25", "-10.4999,20.2501"],
                     "stdin must preserve both original coordinates")

        let setArguments = SimulatorRouteReplay.timelineSetArguments(device: device, coordinate: start)
        precondition(Array(setArguments.suffix(2)) == ["set", "-10.5,20.25"],
                     "set must pass the coordinate directly; simctl parses -- as a coordinate")

        let first = GPSSample(
            elapsedSeconds: 0,
            latitude: start.latitude,
            longitude: start.longitude,
            speedMps: nil,
            horizontalAccuracyMeters: nil,
            courseDegrees: nil
        )
        let next = GPSSample(
            elapsedSeconds: 11,
            latitude: end.latitude,
            longitude: end.longitude,
            speedMps: nil,
            horizontalAccuracyMeters: nil,
            courseDegrees: nil
        )
        precondition(SimulatorRouteReplay.isTimelineGap(start: first, end: next, maxGapSeconds: 10),
                     "an 11 second interval must enter the default gap policy")
        precondition(!SimulatorRouteReplay.isTimelineGap(start: first, end: next, maxGapSeconds: 11),
                     "an explicit larger max_gap_s must allow the interval")

        let document = Data(#"{"version":1,"points":[{"elapsed_s":0,"latitude":0,"longitude":0},{"elapsed_s":11,"latitude":0.001,"longitude":0}]}"#.utf8)
        let timeline = try! GPSSamplesTimelineParser.parse(data: document)
        precondition(timeline.maxGapSeconds == GPSSamplesTimeline.defaultMaxGapSeconds,
                     "missing max_gap_s must default to 10 seconds")
        let explicitDocument = Data(#"{"version":1,"max_gap_s":20,"points":[{"elapsed_s":0,"latitude":0,"longitude":0},{"elapsed_s":11,"latitude":0.001,"longitude":0}]}"#.utf8)
        let explicitTimeline = try! GPSSamplesTimelineParser.parse(data: explicitDocument)
        precondition(explicitTimeline.maxGapSeconds == 20,
                     "explicit max_gap_s must be retained")
        print("timeline replay regressions passed")
    }
}
