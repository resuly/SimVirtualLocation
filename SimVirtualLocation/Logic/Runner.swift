//
//  Runner.swift
//  SimVirtualLocation
//
//  Created by Sergey Shirnin on 19.05.2022.
//

import Foundation
import CoreLocation

class Runner {

    // MARK: - Internal Properties

    var timeDelay: TimeInterval = 0.5
    var log: ((String) -> Void)?
    var pymobiledevicePath: String?

    // MARK: - Private Properties

    private let runnerQueue = DispatchQueue(label: "runnerQueue", qos: .background)
    private let executionQueue = DispatchQueue(label: "executionQueue", qos: .background, attributes: .concurrent)
    private var idevicelocationPath: URL?

    private var currentTask: Process?
    private var tasks: [Process] = []
    private let maxTasksCount = 10

    private var isStopped: Bool = false

    // MARK: - Internal Methods

    func stop() {
        tasks.forEach { $0.terminate() }
        tasks = []

        isStopped = true
    }
    
    func runOnSimulator(
        location: CLLocationCoordinate2D,
        selectedSimulator: String,
        bootedSimulators: [Simulator],
        showAlert: @escaping (String) -> Void
    ) {
        let simulators = bootedSimulators
            .filter { $0.id == selectedSimulator || selectedSimulator == "" }
            .map { $0.id }

        log?("set simulator location \(location.description)")

        NotificationSender.postNotification(for: location, to: simulators)
    }
    
    func runOnIos(
        location: CLLocationCoordinate2D,
        showAlert: @escaping (String) -> Void
    ) async throws {
        self.isStopped = false

        guard !self.isStopped else {
            return
        }

        let task = try await self.taskForIOS(
            args: [
                "developer",
                "simulate-location",
                "set",
                "--",
                "\(String(format: "%.5f", location.latitude))",
                "\(String(format: "%.5f", location.longitude))"
            ],
            showAlert: showAlert
        )

        self.log?("set iOS location \(location.description)")
        self.log?("task: \(task.logDescription)")

        self.currentTask = task

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        task.standardInput = inputPipe
        task.standardOutput = outputPipe
        task.standardError = errorPipe

        do {
            try task.run()
            self.runnerQueue.async {
                if self.tasks.count > self.maxTasksCount {
                    self.stop()
                }
                self.tasks.append(task)
            }

            task.waitUntilExit()

            if let errorData = try errorPipe.fileHandleForReading.readToEnd() {
                let error = String(decoding: errorData, as: UTF8.self)

                if !error.isEmpty {
                    showAlert(error)
                }
            }
        } catch {
            showAlert(error.localizedDescription)
            return
        }
    }

    func runOnNewIos(
        location: CLLocationCoordinate2D,
        RSDAddress: String,
        RSDPort: String,
        showAlert: @escaping (String) -> Void
    ) async throws {
        guard !RSDAddress.isEmpty, !RSDPort.isEmpty else {
            showAlert("Please specify RSD ID and Port")
            return
        }

        self.isStopped = false

        guard !self.isStopped else {
            return
        }

        let task = try await self.taskForIOS(
            args: [
                "developer",
                "dvt",
                "simulate-location",
                "set",
                "--rsd",
                RSDAddress,
                RSDPort,
                "--",
                "\(location.latitude)",
                "\(location.longitude)"
            ],
            showAlert: showAlert
        )

        self.log?("set iOS location \(location.description)")
        self.log?("task: \(task.logDescription)")

        self.currentTask = task

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        task.standardInput = inputPipe
        task.standardOutput = outputPipe
        task.standardError = errorPipe

        do {
            try task.run()
            self.runnerQueue.async {
                if self.tasks.count > self.maxTasksCount {
                    self.stop()
                }
                self.tasks.append(task)
            }

            task.waitUntilExit()

            if let errorData = try errorPipe.fileHandleForReading.readToEnd() {
                let error = String(decoding: errorData, as: UTF8.self)

                if !error.isEmpty {
                    showAlert(error)
                }
            }
        } catch {
            showAlert(error.localizedDescription)
            return
        }
    }
    
    func runOnAndroid(
        location: CLLocationCoordinate2D,
        adbDeviceId: String,
        adbPath: String,
        isEmulator: Bool,
        showAlert: @escaping (String) -> Void
    ) {
        executionQueue.async {
            let task: Process
            
            if isEmulator {
                task = self.taskForAndroid(
                    args: [
                        "-s", adbDeviceId,
                        "emu", "geo", "fix",
                        "\(location.longitude)",
                        "\(location.latitude)"
                    ],
                    adbPath: adbPath
                )
            } else {
                task = self.taskForAndroid(
                    args: [
                        "-s", adbDeviceId,
                        "shell", "am", "broadcast",
                        "-a", "send.mock",
                        "-e", "lat", "\(location.latitude)",
                        "-e", "lon", "\(location.longitude)"
                    ],
                    adbPath: adbPath
                )
            }
            
            self.log?("set Android location \(location.description)")
            self.log?("task: \(task.logDescription)")

            let errorPipe = Pipe()
            
            task.standardError = errorPipe
            
            do {
                try task.run()
                task.waitUntilExit()
            } catch {
                showAlert(error.localizedDescription)
                return
            }
            
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let error = String(decoding: errorData, as: UTF8.self)
            
            if !error.isEmpty {
                showAlert(error)
            }
        }
    }
    
    func resetIos(showAlert: (String) -> Void) {
        stop()
    }
    
    func resetAndroid(adbDeviceId: String, adbPath: String, showAlert: (String) -> Void) {
        let task = taskForAndroid(
            args: [
                "-s", adbDeviceId,
                "shell", "am", "broadcast",
                "-a", "stop.mock"
            ],
            adbPath: adbPath
        )
        
        let errorPipe = Pipe()
        
        task.standardError = errorPipe
        
        do {
            try task.run()
        } catch {
            showAlert(error.localizedDescription)
        }
        
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let error = String(decoding: errorData, as: UTF8.self)
        
        if !error.isEmpty {
            showAlert(error)
        }
        
        task.waitUntilExit()
    }

    func taskForIOS(args: [String], showAlert: (String) -> Void) async throws -> Process {
        // Check cache
        if pymobiledevicePath == nil || pymobiledevicePath == "" {
            pymobiledevicePath = findPymobiledevice3Path()

            if pymobiledevicePath == nil {
                showAlert("""
                pymobiledevice3 not found. Searched the following locations:
                • System PATH (using 'which' command)
                • /opt/homebrew/bin/
                • /usr/local/bin/
                • /Applications/anaconda3/bin/
                • ~/.local/bin/
                • ~/Library/Python/*/bin/

                Installation command:
                brew install python3 && python3 -m pip install -U pymobiledevice3 --break-system-packages --user

                After installation, verify with: which pymobiledevice3
                """)
                pymobiledevicePath = ""
            }
        }

        guard let validPath = pymobiledevicePath, !validPath.isEmpty else {
            throw NSError(domain: "Runner", code: 1, userInfo: [NSLocalizedDescriptionKey: "pymobiledevice3 not found"])
        }

        let path = URL(fileURLWithPath: validPath)
        let task = Process()
        task.executableURL = path
        task.arguments = args

        return task
    }

    // MARK: - Private Methods

    private func findPymobiledevice3Path() -> String? {
        let fileManager = FileManager.default

        // Strategy 1: Use 'which' to find pymobiledevice3 in PATH (fastest and most reliable)
        let whichTask = Process()
        whichTask.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        whichTask.arguments = ["pymobiledevice3"]

        let whichPipe = Pipe()
        whichTask.standardOutput = whichPipe
        whichTask.standardError = Pipe() // Suppress errors

        do {
            try whichTask.run()
            whichTask.waitUntilExit()

            if whichTask.terminationStatus == 0 {
                let data = whichPipe.fileHandleForReading.readDataToEndOfFile()
                let pathString = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)

                if !pathString.isEmpty && fileManager.fileExists(atPath: pathString) {
                    return pathString
                }
            }
        } catch {
            // Fall through to manual search
        }

        // Strategy 2: Check common installation paths
        let commonPaths = [
            "/opt/homebrew/bin/pymobiledevice3",              // ARM64 homebrew
            "/usr/local/bin/pymobiledevice3",                 // Intel homebrew
            "/Applications/anaconda3/bin/pymobiledevice3",    // Anaconda
            "\(NSHomeDirectory())/.local/bin/pymobiledevice3" // pip user local
        ]

        for path in commonPaths {
            if fileManager.fileExists(atPath: path) {
                return path
            }
        }

        // Strategy 3: Search ~/Library/Python/*/bin/pymobiledevice3
        let libraryPath = "\(NSHomeDirectory())/Library/Python"

        guard fileManager.fileExists(atPath: libraryPath) else {
            return nil
        }

        do {
            let pythonVersions = try fileManager.contentsOfDirectory(atPath: libraryPath)
            let sortedVersions = pythonVersions.sorted().reversed() // Prefer newer versions

            for version in sortedVersions {
                let binPath = "\(libraryPath)/\(version)/bin/pymobiledevice3"
                if fileManager.fileExists(atPath: binPath) {
                    return binPath
                }
            }
        } catch {
            return nil
        }

        return nil
    }

    private func taskForAndroid(args: [String], adbPath: String) -> Process {
        let path = adbPath
        let task = Process()
        task.executableURL = URL(string: "file://\(path)")!
        task.arguments = args

        return task
    }
}

extension CLLocationCoordinate2D {

    var description: String { "\(latitude) \(longitude)" }
}

extension Process {

    var logDescription: String {
        var description: String = ""
        if let executableURL {
            description += "\(executableURL.absoluteString) "
        }

        if let arguments {
            description += "\(arguments.joined(separator: " "))"
        }

        return description
    }
}
