//
//  ControlClient.swift
//  SimVirtualLocation control client
//
//  Usage examples:
//    control-client status
//    control-client load-route route.geojson
//    control-client configure '{"simulator":"...","speed_kmh":36}'
//    control-client '{"command":"status"}'
//    echo '{"command":"status"}' | control-client -
//

import Foundation
import Darwin

struct ControlClient {
    private static let maxRequestBytes = 8 * 1024 * 1024
    private static let ioTimeout: TimeInterval = 5.0
    private static let commandNames: Set<String> = [
        "status", "simulators", "start", "start-timeline", "pause", "resume", "stop", "route", "timeline", "debug"
    ]

    static func run() {
        do {
            let (socketPath, request) = try parseArguments(Array(CommandLine.arguments.dropFirst()))
            let response = try send(request: request, to: socketPath)
            let output = try encodedJSONObject(response)
            writeStdout(output)
            if let ok = response["ok"] as? Bool, !ok {
                Darwin.exit(1)
            }
            Darwin.exit(0)
        } catch let error as ClientError {
            writeError(code: error.code, message: error.message, status: 2)
        } catch {
            writeError(code: "client_error", message: String(describing: error), status: 2)
        }
    }

    // MARK: - CLI parsing

    private static func parseArguments(_ arguments: [String]) throws -> (String, [String: Any]) {
        var remaining = arguments
        var socketPath = ProcessInfo.processInfo.environment["SIMVIRTUALLOCATION_CONTROL_SOCKET"]
            ?? ((NSHomeDirectory() as NSString).appendingPathComponent(".simvirtuallocation/control.sock"))

        if remaining.first == "--socket" {
            guard remaining.count >= 2 else {
                throw ClientError(code: "usage", message: "--socket requires a path")
            }
            socketPath = remaining[1]
            remaining.removeFirst(2)
        } else if let first = remaining.first, first.hasPrefix("--socket=") {
            socketPath = String(first.dropFirst("--socket=".count))
            remaining.removeFirst()
        }

        guard socketPath.hasPrefix("/"), !socketPath.utf8.contains(0) else {
            throw ClientError(code: "invalid_socket_path", message: "socket path must be absolute")
        }
        guard socketPath.utf8.count < 104 else {
            throw ClientError(code: "invalid_socket_path", message: "socket path is too long for sockaddr_un")
        }

        let request: [String: Any]
        if remaining.isEmpty || (remaining.count == 1 && remaining[0] == "-") {
            request = try parseJSONObject(try readStdin(maxBytes: maxRequestBytes), context: "stdin")
        } else {
            guard let command = remaining.first else {
                throw ClientError(code: "usage", message: "missing command")
            }
            switch command {
            case let named where commandNames.contains(named):
                guard remaining.count == 1 else {
                    throw ClientError(code: "usage", message: named + " takes no arguments")
                }
                request = ["command": named]
            case "load-route":
                guard remaining.count == 2 else {
                    throw ClientError(code: "usage", message: "load-route requires a JSON/GeoJSON file path")
                }
                let routeData: Data
                if remaining[1] == "-" {
                    routeData = try readStdin(maxBytes: maxRequestBytes)
                } else {
                    routeData = try readFile(remaining[1], maxBytes: maxRequestBytes)
                }
                let route = try parseJSONObject(routeData, context: "route file")
                request = ["command": "load-route", "route": route]
            case "load-timeline":
                guard remaining.count == 2 else {
                    throw ClientError(code: "usage", message: "load-timeline requires one gps_samples JSON file path")
                }
                let timelineData: Data
                if remaining[1] == "-" {
                    timelineData = try readStdin(maxBytes: maxRequestBytes)
                } else {
                    timelineData = try readFile(remaining[1], maxBytes: maxRequestBytes)
                }
                let timeline = try parseJSONObject(timelineData, context: "timeline file")
                request = ["command": "load-timeline", "timeline": timeline]
            case "configure":
                guard remaining.count == 2 else {
                    throw ClientError(code: "usage", message: "configure requires one JSON object")
                }
                var configuration = try parseJSONObject(Data(remaining[1].utf8), context: "configure")
                configuration["command"] = "configure"
                request = configuration
            default:
                guard remaining.count == 1 else {
                    throw ClientError(code: "usage", message: "expected one JSON object, '-' or a named command")
                }
                let raw = remaining[0].trimmingCharacters(in: .whitespacesAndNewlines)
                guard raw.hasPrefix("{") else {
                    throw ClientError(code: "unknown_command", message: "unknown command: " + command)
                }
                request = try parseJSONObject(Data(remaining[0].utf8), context: "argument")
            }
        }

        let encoded = try encodedJSONObject(request)
        guard encoded.count + 1 <= maxRequestBytes else {
            throw ClientError(code: "request_too_large", message: "request exceeds 8 MiB")
        }
        return (socketPath, request)
    }

    private static func parseJSONObject(_ data: Data, context: String) throws -> [String: Any] {
        guard !data.isEmpty else {
            throw ClientError(code: "invalid_json", message: context + " is empty")
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw ClientError(code: "invalid_json", message: context + " is not valid JSON: " + error.localizedDescription)
        }
        guard let dictionary = object as? [String: Any] else {
            throw ClientError(code: "invalid_json", message: context + " must be one JSON object")
        }
        return dictionary
    }

    private static func readStdin(maxBytes: Int) throws -> Data {
        var result = Data()
        result.reserveCapacity(min(maxBytes, 64 * 1024))
        while true {
            let chunk: Data
            do {
                chunk = try FileHandle.standardInput.read(upToCount: min(64 * 1024, maxBytes + 1 - result.count)) ?? Data()
            } catch {
                throw ClientError(code: "stdin_read_failed", message: error.localizedDescription)
            }
            if chunk.isEmpty { break }
            result.append(chunk)
            if result.count > maxBytes {
                throw ClientError(code: "request_too_large", message: "stdin exceeds 8 MiB")
            }
        }
        return result
    }

    private static func readFile(_ path: String, maxBytes: Int) throws -> Data {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        } catch {
            throw ClientError(code: "route_read_failed", message: error.localizedDescription)
        }
        defer { try? handle.close() }

        var result = Data()
        result.reserveCapacity(min(maxBytes, 64 * 1024))
        while true {
            let chunk: Data
            do {
                chunk = try handle.read(upToCount: min(64 * 1024, maxBytes + 1 - result.count)) ?? Data()
            } catch {
                throw ClientError(code: "route_read_failed", message: error.localizedDescription)
            }
            if chunk.isEmpty { break }
            result.append(chunk)
            if result.count > maxBytes {
                throw ClientError(code: "request_too_large", message: "route file exceeds 8 MiB")
            }
        }
        return result
    }

    // MARK: - Unix socket transport

    private static func send(request: [String: Any], to path: String) throws -> [String: Any] {
        let requestData = try encodedJSONObject(request)
        var payload = requestData
        payload.append(0x0A)

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw ClientError(code: "socket_failed", message: posixMessage(errno))
        }
        defer {
            _ = Darwin.shutdown(fd, SHUT_RDWR)
            _ = Darwin.close(fd)
        }
        try setNoSIGPIPE(fd)
        try setNonBlocking(fd)

        var address = try makeAddress(path: path)
        let length = addressLength(address)
        let result: Int32 = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, length)
            }
        }
        if result != 0 {
            let code = errno
            if code != EINPROGRESS {
                throw ClientError(code: "connect_failed", message: posixMessage(code))
            }
            try waitFor(fd: fd, events: Int16(POLLOUT), deadline: Date().addingTimeInterval(ioTimeout))
            var socketError: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0 else {
                throw ClientError(code: "connect_failed", message: posixMessage(errno))
            }
            guard socketError == 0 else {
                throw ClientError(code: "connect_failed", message: posixMessage(socketError))
            }
        }

        try sendAll(payload, on: fd, deadline: Date().addingTimeInterval(ioTimeout))
        _ = Darwin.shutdown(fd, SHUT_WR)
        let line = try readResponse(from: fd, deadline: Date().addingTimeInterval(ioTimeout))
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: line, options: [.fragmentsAllowed])
        } catch {
            throw ClientError(code: "invalid_response", message: "server response is not valid JSON: " + error.localizedDescription)
        }
        guard let response = object as? [String: Any] else {
            throw ClientError(code: "invalid_response", message: "server response must be one JSON object")
        }
        if let ok = response["ok"], !(ok is Bool) {
            throw ClientError(code: "invalid_response", message: "server ok field must be boolean")
        }
        return response
    }

    private static func encodedJSONObject(_ object: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw ClientError(code: "invalid_json", message: "request contains values that are not JSON")
        }
        do {
            return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        } catch {
            throw ClientError(code: "invalid_json", message: "failed to encode JSON: " + error.localizedDescription)
        }
    }

    private static func readResponse(from fd: Int32, deadline: Date) throws -> Data {
        var bytes = Data()
        bytes.reserveCapacity(4096)
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            try waitFor(fd: fd, events: Int16(POLLIN), deadline: deadline)
            let received = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
                guard let base = rawBuffer.baseAddress else { return 0 }
                return Darwin.recv(fd, base, rawBuffer.count, MSG_DONTWAIT)
            }
            if received > 0 {
                bytes.append(buffer, count: received)
                if let newline = bytes.firstIndex(of: 0x0A) {
                    let line = bytes.prefix(upTo: newline)
                    guard line.count <= maxRequestBytes else {
                        throw ClientError(code: "response_too_large", message: "server response exceeds 8 MiB")
                    }
                    return Data(line)
                }
                if bytes.count > maxRequestBytes {
                    throw ClientError(code: "response_too_large", message: "server response exceeds 8 MiB")
                }
                continue
            }
            if received == 0 {
                throw ClientError(code: "unexpected_eof", message: "server closed before a newline-delimited response")
            }
            let code = errno
            if code == EINTR || code == EAGAIN || code == EWOULDBLOCK { continue }
            throw ClientError(code: "read_failed", message: posixMessage(code))
        }
    }

    private static func sendAll(_ data: Data, on fd: Int32, deadline: Date) throws {
        var offset = 0
        while offset < data.count {
            let sent = data.withUnsafeBytes { rawBuffer -> Int in
                guard let base = rawBuffer.baseAddress else { return -1 }
                return Darwin.send(fd, base.advanced(by: offset), data.count - offset, 0)
            }
            if sent > 0 {
                offset += sent
                continue
            }
            if sent == 0 {
                throw ClientError(code: "write_failed", message: "socket write returned zero")
            }
            let code = errno
            if code == EINTR { continue }
            if code == EAGAIN || code == EWOULDBLOCK {
                try waitFor(fd: fd, events: Int16(POLLOUT), deadline: deadline)
                continue
            }
            throw ClientError(code: "write_failed", message: posixMessage(code))
        }
    }

    private static func waitFor(fd: Int32, events: Int16, deadline: Date) throws {
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else {
                throw ClientError(code: "io_timeout", message: "socket I/O timed out")
            }
            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            let timeoutMS = Int32(max(1, min(Double(Int32.max), ceil(remaining * 1000))))
            let result = Darwin.poll(&descriptor, 1, timeoutMS)
            if result < 0 {
                if errno == EINTR { continue }
                throw ClientError(code: "poll_failed", message: posixMessage(errno))
            }
            if result == 0 { throw ClientError(code: "io_timeout", message: "socket I/O timed out") }
            if descriptor.revents & Int16(POLLNVAL) != 0 {
                throw ClientError(code: "socket_closed", message: "socket descriptor is closed")
            }
            if descriptor.revents & (events | Int16(POLLERR) | Int16(POLLHUP)) != 0 {
                return
            }
        }
    }

    // MARK: - Darwin helpers

    private static func makeAddress(path: String) throws -> sockaddr_un {
        let pathBytes = Array(path.utf8)
        guard path.hasPrefix("/"), pathBytes.count < 104 else {
            throw ClientError(code: "invalid_socket_path", message: "socket path is invalid or too long")
        }
        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sa_family_t>.size + pathBytes.count)
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { rawBuffer in
            for (index, byte) in pathBytes.enumerated() {
                rawBuffer[index] = byte
            }
        }
        return address
    }

    private static func addressLength(_ address: sockaddr_un) -> socklen_t {
        let prefix = MemoryLayout<sockaddr_un>.size - MemoryLayout.size(ofValue: address.sun_path)
        let pathLength = Int(address.sun_len) - MemoryLayout<sa_family_t>.size
        return socklen_t(prefix + pathLength)
    }

    private static func setNoSIGPIPE(_ fd: Int32) throws {
        var value: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &value, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw ClientError(code: "setsockopt_failed", message: posixMessage(errno))
        }
    }

    private static func setNonBlocking(_ fd: Int32) throws {
        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw ClientError(code: "fcntl_failed", message: posixMessage(errno))
        }
    }

    private static func posixMessage(_ code: Int32) -> String {
        String(cString: Darwin.strerror(code))
    }

    // MARK: - Output

    private static func writeStdout(_ data: Data) {
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))
    }

    private static func writeError(code: String, message: String, status: Int32) -> Never {
        let object: [String: Any] = [
            "ok": false,
            "error": ["code": code, "message": message]
        ]
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) {
            writeStdout(data)
        }
        Darwin.exit(status)
    }
}

private struct ClientError: Error {
    let code: String
    let message: String
}

ControlClient.run()
