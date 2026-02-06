//
//  Runner.swift
//  SimVirtualLocation
//
//  Created by Sergey Shirnin on 19.05.2022.
//

import Foundation
import CoreLocation
import AppKit

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
        speed: Double? = nil,
        course: Double? = nil,
        showAlert: @escaping (String) -> Void
    ) {
        let simulators = bootedSimulators
            .filter { $0.id == selectedSimulator || selectedSimulator == "" }
            .map { $0.id }

        log?("set simulator location \(location.description)")

        NotificationSender.postNotification(
            for: location,
            to: simulators,
            speed: speed,
            course: course
        )
    }
    
    func runOnIos(
        location: CLLocationCoordinate2D,
        deviceId: String? = nil,
        showAlert: @escaping (String) -> Void
    ) async throws {
        self.isStopped = false

        guard !self.isStopped else {
            return
        }

        var args = ["developer", "simulate-location", "set"]

        // Add device ID if specified
        if let deviceId = deviceId, !deviceId.isEmpty {
            args.append(contentsOf: ["--udid", deviceId])
        }

        args.append(contentsOf: [
            "--",
            "\(String(format: "%.5f", location.latitude))",
            "\(String(format: "%.5f", location.longitude))"
        ])

        let task = try await self.taskForIOS(
            args: args,
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

        // Execute on background queue to avoid blocking
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            executionQueue.async {
                do {
                    try task.run()
                    self.runnerQueue.async {
                        if self.tasks.count > self.maxTasksCount {
                            self.stop()
                        }
                        self.tasks.append(task)
                    }

                    // Wait on background thread
                    task.waitUntilExit()

                    if let errorData = try? errorPipe.fileHandleForReading.readToEnd() {
                        let error = String(decoding: errorData, as: UTF8.self)

                        if !error.isEmpty {
                            DispatchQueue.main.async {
                                showAlert(error)
                            }
                        }
                    }

                    continuation.resume()
                } catch {
                    DispatchQueue.main.async {
                        showAlert(error.localizedDescription)
                    }
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func runOnNewIos(
        location: CLLocationCoordinate2D,
        deviceId: String,
        rsdHost: String,
        rsdPort: String,
        showAlert: @escaping (String) -> Void,
        retryCount: Int = 0
    ) async throws {
        self.isStopped = false

        guard !self.isStopped else {
            return
        }

        // Use --rsd to connect via start-tunnel
        let task = try await self.taskForIOS(
            args: [
                "developer",
                "dvt",
                "simulate-location",
                "set",
                "--rsd", rsdHost, rsdPort,
                "--",
                "\(location.latitude)",
                "\(location.longitude)"
            ],
            showAlert: showAlert
        )

        self.log?("set iOS 17+ location \(location.description) via RSD tunnel \(rsdHost):\(rsdPort)")
        self.log?("task: \(task.logDescription)")

        self.currentTask = task

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        task.standardInput = inputPipe
        task.standardOutput = outputPipe
        task.standardError = errorPipe

        // Execute on background queue to avoid blocking
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            executionQueue.async {
                do {
                    try task.run()
                    self.runnerQueue.async {
                        if self.tasks.count > self.maxTasksCount {
                            self.stop()
                        }
                        self.tasks.append(task)
                    }

                    // Wait on background thread
                    task.waitUntilExit()

                    if let errorData = try? errorPipe.fileHandleForReading.readToEnd() {
                        let error = String(decoding: errorData, as: UTF8.self)

                        if !error.isEmpty {
                            // Check if it's a timeout/connection error that should trigger reconnect
                            if error.contains("TimeoutError") || error.contains("timeout") ||
                               error.contains("ConnectionError") || error.contains("connection") {
                                // Throw error so LocationController can handle reconnect
                                let nsError = NSError(
                                    domain: "RSDTunnel",
                                    code: -1,
                                    userInfo: [NSLocalizedDescriptionKey: error]
                                )
                                continuation.resume(throwing: nsError)
                                return
                            }

                            // For other errors, just show alert but don't reconnect
                            DispatchQueue.main.async {
                                showAlert(error)
                            }
                        }
                    }

                    continuation.resume()
                } catch {
                    DispatchQueue.main.async {
                        showAlert(error.localizedDescription)
                    }
                    continuation.resume(throwing: error)
                }
            }
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
                • Homebrew Python: /opt/homebrew/bin/python3 -m pymobiledevice3
                • System PATH (using 'which' command)
                • /usr/local/bin/
                • ~/.local/bin/
                • ~/Library/Python/*/bin/

                Installation command:
                /opt/homebrew/bin/python3 -m pip install -U pymobiledevice3 --break-system-packages

                After installation, restart the app.
                """)
                pymobiledevicePath = ""
            }
        }

        guard let validPath = pymobiledevicePath, !validPath.isEmpty else {
            throw NSError(domain: "Runner", code: 1, userInfo: [NSLocalizedDescriptionKey: "pymobiledevice3 not found"])
        }

        let task = Process()

        // Check if we should use Python module mode
        if validPath.hasPrefix("PYTHON_MODULE:") {
            let pythonPath = String(validPath.dropFirst("PYTHON_MODULE:".count))
            task.executableURL = URL(fileURLWithPath: pythonPath)
            task.arguments = ["-m", "pymobiledevice3"] + args
        } else {
            task.executableURL = URL(fileURLWithPath: validPath)
            task.arguments = args
        }

        return task
    }

    // MARK: - RSD Tunnel (iOS 17+)

    private var tunnelProcess: Process?
    private var tunnelHost: String?
    private var tunnelPort: String?

    /// Start RSD tunnel for a specific device and return HOST:PORT
    func startTunnel(
        for deviceId: String,
        showAlert: @escaping (String) -> Void,
        completion: @escaping (Result<(host: String, port: String), Error>) -> Void
    ) {
        log?("Starting tunnel for device: \(deviceId)")

        guard let pymobilePath = pymobiledevicePath, !pymobilePath.isEmpty else {
            log?("✗ pymobiledevice3 not found")
            completion(.failure(NSError(domain: "Runner", code: 1, userInfo: [NSLocalizedDescriptionKey: "pymobiledevice3 not installed"])))
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            // Prepare Python module command
            let pythonPath: String
            let baseArgs: [String]

            if pymobilePath.hasPrefix("PYTHON_MODULE:") {
                pythonPath = String(pymobilePath.dropFirst("PYTHON_MODULE:".count))
                baseArgs = ["-m", "pymobiledevice3"]
            } else {
                pythonPath = pymobilePath
                baseArgs = []
            }

            // Build osascript command - run in BACKGROUND and check process
            let logPath = "\(NSHomeDirectory())/Library/Logs/tunnel_\(deviceId).log"
            let pidPath = "/tmp/tunnel_\(deviceId).pid"

            // Create a wrapper script that FIRST cleans up, THEN starts tunnel
            let tmpScript = "/tmp/start_tunnel_\(deviceId).sh"
            let scriptContent = """
            #!/bin/bash
            # Clean up any existing tunnels
            pkill -9 -f 'pymobiledevice3.*start-tunnel' 2>/dev/null
            sleep 1

            # Start new tunnel
            cd /tmp
            \(pythonPath) \(baseArgs.joined(separator: " ")) remote start-tunnel --udid \(deviceId) --script-mode > "\(logPath)" 2>&1 &
            echo $! > "\(pidPath)"
            """

            do {
                try scriptContent.write(toFile: tmpScript, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmpScript)
            } catch {
                self.log?("✗ Failed to create wrapper script: \(error)")
                completion(.failure(error))
                return
            }

            self.log?("🔐 Requesting administrator permission...")
            self.log?("Script: \(tmpScript)")
            self.log?("Log: \(logPath)")

            // Run the script with sudo (cleanup + start in one go)
            let script = """
            do shell script "\(tmpScript)" with administrator privileges
            """

            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            task.arguments = ["-e", script]
            task.standardOutput = Pipe()
            task.standardError = Pipe()

            do {
                try task.run()
                task.waitUntilExit()

                if task.terminationStatus == 0 {
                    self.log?("✓ Tunnel start command executed")

                    // Wait for tunnel to initialize
                    self.log?("Waiting for tunnel to start...")
                    for attempt in 1...10 {
                        Thread.sleep(forTimeInterval: 1.0)

                        // Check if log file has "tunnel created"
                        if let logContent = try? String(contentsOf: URL(fileURLWithPath: logPath), encoding: .utf8) {
                            if logContent.contains("tunnel created") {
                                self.log?("✓ Tunnel created (attempt \(attempt))")

                                // Parse HOST and PORT
                                let lines = logContent.components(separatedBy: .newlines)
                                for (index, line) in lines.enumerated() {
                                    if line.contains("tunnel created") && index + 1 < lines.count {
                                        let hostPortLine = lines[index + 1].trimmingCharacters(in: .whitespaces)
                                        let parts = hostPortLine.components(separatedBy: .whitespaces)
                                        if parts.count >= 2 {
                                            let host = parts[0]
                                            let port = parts[1]
                                            self.tunnelHost = host
                                            self.tunnelPort = port
                                            self.log?("✓ Tunnel ready: \(host):\(port)")
                                            completion(.success((host: host, port: port)))
                                            return
                                        }
                                    }
                                }
                            } else if attempt == 10 {
                                self.log?("Tunnel output so far: \(logContent)")
                            }
                        } else if attempt == 10 {
                            self.log?("✗ Could not read log file: \(logPath)")
                        }
                    }

                    // Timeout
                    self.log?("✗ Tunnel creation timeout (no 'tunnel created' message after 10s)")
                    completion(.failure(NSError(domain: "Runner", code: 2, userInfo: [NSLocalizedDescriptionKey: "Tunnel timeout. Check log: \(logPath)"])))
                } else {
                    self.log?("✗ osascript failed (status: \(task.terminationStatus))")
                    completion(.failure(NSError(domain: "Runner", code: 3, userInfo: [NSLocalizedDescriptionKey: "Permission denied or script failed"])))
                }
            } catch {
                self.log?("✗ Error starting tunnel: \(error.localizedDescription)")
                completion(.failure(error))
            }
        }
    }

    /// Check if tunnel is still running
    func isTunnelRunning(completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/ps")
            task.arguments = ["aux"]
            let pipe = Pipe()
            task.standardOutput = pipe

            do {
                try task.run()
                task.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(decoding: data, as: UTF8.self)
                let isRunning = output.contains("pymobiledevice3") && output.contains("start-tunnel")
                completion(isRunning)
            } catch {
                completion(false)
            }
        }
    }

    // MARK: - Private Methods

    private func findPymobiledevice3Path() -> String? {
        let fileManager = FileManager.default

        // Strategy 1: Try Homebrew Python (most reliable, avoids Anaconda bugs)
        let brewPython = "/opt/homebrew/bin/python3"
        if fileManager.fileExists(atPath: brewPython) {
            // Test if pymobiledevice3 module is installed
            let testTask = Process()
            testTask.executableURL = URL(fileURLWithPath: brewPython)
            testTask.arguments = ["-m", "pymobiledevice3", "--help"]
            testTask.standardOutput = Pipe()
            testTask.standardError = Pipe()

            do {
                try testTask.run()
                testTask.waitUntilExit()
                if testTask.terminationStatus == 0 {
                    // Return special marker indicating to use Python module
                    return "PYTHON_MODULE:\(brewPython)"
                }
            } catch {
                // Continue to next strategy
            }
        }

        // Strategy 2: Use 'which' to find pymobiledevice3 in PATH
        let whichTask = Process()
        whichTask.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        whichTask.arguments = ["pymobiledevice3"]

        let whichPipe = Pipe()
        whichTask.standardOutput = whichPipe
        whichTask.standardError = Pipe()

        do {
            try whichTask.run()
            whichTask.waitUntilExit()

            if whichTask.terminationStatus == 0 {
                let data = whichPipe.fileHandleForReading.readDataToEndOfFile()
                let pathString = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)

                if !pathString.isEmpty && fileManager.fileExists(atPath: pathString) && !pathString.contains("anaconda") {
                    // Avoid Anaconda version (has bugs)
                    return pathString
                }
            }
        } catch {
            // Fall through to manual search
        }

        // Strategy 3: Check common installation paths (skip Anaconda)
        let commonPaths = [
            "/usr/local/bin/pymobiledevice3",                 // Intel homebrew
            "\(NSHomeDirectory())/.local/bin/pymobiledevice3" // pip user local
        ]

        for path in commonPaths {
            if fileManager.fileExists(atPath: path) {
                return path
            }
        }

        // Strategy 4: Search ~/Library/Python/*/bin/pymobiledevice3
        let libraryPath = "\(NSHomeDirectory())/Library/Python"

        guard fileManager.fileExists(atPath: libraryPath) else {
            return nil
        }

        do {
            let pythonVersions = try fileManager.contentsOfDirectory(atPath: libraryPath)
            let sortedVersions = pythonVersions.sorted().reversed()

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
