//
//  ControlAPI.swift
//  SimVirtualLocation
//
//  Small, local-only control transport.  The application supplies the command
//  dispatch closure; this file deliberately knows nothing about LocationController.
//

import Foundation
import Darwin

/// A newline-delimited JSON API available only through a private Unix socket.
///
/// A handler receives one JSON object and returns one JSON object.  The
/// response is sent with `ok: true` added when the handler did not provide an
/// `ok` field.  A handler can return `ok: false` for an application error.
public final class ControlAPI {
    public typealias Handler = ([String: Any]) -> [String: Any]

    public static var defaultSocketPath: String {
        return (NSHomeDirectory() as NSString).appendingPathComponent(".simvirtuallocation/control.sock")
    }

    public static let maxRequestBytes = 8 * 1024 * 1024
    public static let ioTimeout: TimeInterval = 5.0

    private let handler: Handler
    private let socketPath: String
    private let queue = DispatchQueue(label: "com.resuly.SimVirtualLocation.control", qos: .utility)
    private let stateLock = NSLock()

    private var listenerFD: Int32 = -1
    private var isRunning = false
    private var stopping = false
    private var listenerDevice: dev_t?
    private var listenerInode: ino_t?

    public init(handler: @escaping Handler, socketPath: String = ControlAPI.defaultSocketPath) {
        self.handler = handler
        self.socketPath = socketPath
    }

    deinit {
        stop()
    }

    /// Binds the socket and starts accepting requests on a private serial
    /// queue.  This method does not touch the UI or the controller.
    public func start() throws {
        stateLock.lock()
        if isRunning {
            stateLock.unlock()
            throw ControlAPIError.alreadyRunning
        }
        stopping = false
        stateLock.unlock()

        let socket = try makeListener()

        stateLock.lock()
        listenerFD = socket.fd
        listenerDevice = socket.device
        listenerInode = socket.inode
        isRunning = true
        stateLock.unlock()

        queue.async { [weak self] in
            self?.acceptLoop()
        }
    }

    /// Stops this instance and removes the socket only if it still owns the
    /// inode created by `start()`.
    public func stop() {
        stateLock.lock()
        let fd = listenerFD
        listenerFD = -1
        let wasRunning = isRunning
        isRunning = false
        stopping = true
        let device = listenerDevice
        let inode = listenerInode
        listenerDevice = nil
        listenerInode = nil
        stateLock.unlock()

        if fd >= 0 {
            _ = Darwin.shutdown(fd, SHUT_RDWR)
            _ = Darwin.close(fd)
        }

        // If start failed before the state was published there is no owned
        // path to remove.  For a running listener, identity-check first.
        if wasRunning, let device = device, let inode = inode {
            removeSocketIfOwned(device: device, inode: inode)
        }
    }

    // MARK: - Listener setup

    private struct Listener {
        let fd: Int32
        let device: dev_t
        let inode: ino_t
    }

    private func makeListener() throws -> Listener {
        try validateSocketPath()
        let directory = (socketPath as NSString).deletingLastPathComponent
        try ensurePrivateDirectory(at: directory)
        try removeStaleSocketIfSafe()

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw ControlAPIError.posix(code: "socket_failed", message: posixMessage(errno))
        }
        var shouldClose = true
        var ownedDevice: dev_t?
        var ownedInode: ino_t?
        defer {
            if shouldClose {
                _ = Darwin.close(fd)
                if let ownedDevice = ownedDevice, let ownedInode = ownedInode {
                    removeSocketIfOwned(device: ownedDevice, inode: ownedInode)
                }
            }
        }

        try setNoSIGPIPE(fd)
        try setNonBlocking(fd)

        var address = try makeAddress(path: socketPath)
        let bindLength = addressLength(address)
        let bindResult: Int32 = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, bindLength)
            }
        }
        guard bindResult == 0 else {
            let code = errno
            if code == EADDRINUSE {
                throw ControlAPIError.listenerAlreadyRunning
            }
            throw ControlAPIError.posix(code: "bind_failed", message: posixMessage(code))
        }

        // On macOS an AF_UNIX descriptor's fstat inode is not necessarily the
        // inode of its filesystem pathname.  Record the pathname identity
        // after bind and use that identity for all later unlink decisions.
        var boundPathStat = stat()
        guard lstatPath(socketPath, &boundPathStat) == 0 else {
            throw ControlAPIError.posix(code: "socket_missing", message: posixMessage(errno))
        }
        guard boundPathStat.st_uid == getuid() else {
            throw ControlAPIError.socketOwner
        }
        ownedDevice = boundPathStat.st_dev
        ownedInode = boundPathStat.st_ino

        // Bind creates a filesystem socket entry.  Enforce the mode on the
        // descriptor and path; the parent directory is already 0700.
        let mode: mode_t = 0o600
        guard Darwin.chmod(socketPath, mode) == 0 else {
            throw ControlAPIError.posix(code: "chmod_failed", message: posixMessage(errno))
        }

        guard Darwin.listen(fd, 16) == 0 else {
            throw ControlAPIError.posix(code: "listen_failed", message: posixMessage(errno))
        }

        var pathStat = stat()
        guard lstatPath(socketPath, &pathStat) == 0 else {
            throw ControlAPIError.posix(code: "socket_missing", message: posixMessage(errno))
        }
        guard pathStat.st_dev == boundPathStat.st_dev,
              pathStat.st_ino == boundPathStat.st_ino,
              pathStat.st_uid == getuid() else {
            throw ControlAPIError.posix(code: "socket_identity_changed", message: "socket identity changed while binding")
        }

        shouldClose = false
        return Listener(fd: fd, device: boundPathStat.st_dev, inode: boundPathStat.st_ino)
    }

    private func validateSocketPath() throws {
        guard socketPath.hasPrefix("/"), !socketPath.utf8.contains(0) else {
            throw ControlAPIError.invalidPath
        }
        let bytes = Array(socketPath.utf8)
        // sockaddr_un has a 104-byte sun_path on macOS.  One byte is needed
        // for the terminating NUL.
        guard bytes.count < 104 else {
            throw ControlAPIError.pathTooLong
        }
    }

    private func ensurePrivateDirectory(at path: String) throws {
        var directoryStat = stat()
        if lstatPath(path, &directoryStat) != 0 {
            let code = errno
            if code != ENOENT {
                throw ControlAPIError.posix(code: "directory_stat_failed", message: posixMessage(code))
            }
            if Darwin.mkdir(path, 0o700) != 0 {
                let mkdirCode = errno
                if mkdirCode != EEXIST {
                    throw ControlAPIError.posix(code: "directory_create_failed", message: posixMessage(mkdirCode))
                }
            }
            guard lstatPath(path, &directoryStat) == 0 else {
                throw ControlAPIError.posix(code: "directory_stat_failed", message: posixMessage(errno))
            }
        }

        guard (directoryStat.st_mode & S_IFMT) == S_IFDIR else {
            throw ControlAPIError.directoryNotDirectory
        }
        guard directoryStat.st_uid == getuid() else {
            throw ControlAPIError.directoryOwner
        }
        let mode: mode_t = 0o700
        guard Darwin.chmod(path, mode) == 0 else {
            throw ControlAPIError.posix(code: "directory_chmod_failed", message: posixMessage(errno))
        }

        // lstat after chmod intentionally verifies the path itself, rather
        // than following a symlink that could have replaced the directory.
        var finalStat = stat()
        guard lstatPath(path, &finalStat) == 0,
              (finalStat.st_mode & S_IFMT) == S_IFDIR,
              finalStat.st_uid == getuid() else {
            throw ControlAPIError.directoryChanged
        }
    }

    private func removeStaleSocketIfSafe() throws {
        var existing = stat()
        guard lstatPath(socketPath, &existing) == 0 else {
            let code = errno
            if code == ENOENT {
                return
            }
            throw ControlAPIError.posix(code: "socket_stat_failed", message: posixMessage(code))
        }

        guard (existing.st_mode & S_IFMT) == S_IFSOCK else {
            throw ControlAPIError.socketPathOccupied
        }
        guard existing.st_uid == getuid() else {
            throw ControlAPIError.socketOwner
        }

        switch probeExistingSocket() {
        case .active:
            throw ControlAPIError.listenerAlreadyRunning
        case .stale:
            break
        case .unknown(let message):
            throw ControlAPIError.posix(code: "existing_socket_unverified", message: message)
        }

        // Do not unlink a path that changed while the probe was running.
        var unchanged = stat()
        if lstatPath(socketPath, &unchanged) != 0 {
            if errno == ENOENT {
                return
            }
            throw ControlAPIError.posix(code: "socket_stat_failed", message: posixMessage(errno))
        }
        guard unchanged.st_dev == existing.st_dev, unchanged.st_ino == existing.st_ino else {
            throw ControlAPIError.listenerAlreadyRunning
        }
        if Darwin.unlink(socketPath) != 0 {
            let code = errno
            if code != ENOENT {
                throw ControlAPIError.posix(code: "stale_socket_remove_failed", message: posixMessage(code))
            }
        }
    }

    private enum ExistingSocketState {
        case active
        case stale
        case unknown(String)
    }

    private func probeExistingSocket() -> ExistingSocketState {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            return .unknown(posixMessage(errno))
        }
        defer { _ = Darwin.close(fd) }

        do {
            try setNonBlocking(fd)
        } catch {
            return .unknown(errorMessage(error))
        }

        var address: sockaddr_un
        do {
            address = try makeAddress(path: socketPath)
        } catch {
            return .unknown(errorMessage(error))
        }
        let connectLength = addressLength(address)
        let result: Int32 = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, connectLength)
            }
        }
        if result == 0 { return .active }

        let connectCode = errno
        if connectCode == EINPROGRESS {
            var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let pollResult = Darwin.poll(&descriptor, 1, 250)
            if pollResult > 0 {
                var socketError: Int32 = 0
                var socketErrorLength = socklen_t(MemoryLayout<Int32>.size)
                if getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &socketErrorLength) == 0 {
                    if socketError == 0 { return .active }
                    if socketError == ECONNREFUSED { return .stale }
                    return .unknown(posixMessage(socketError))
                }
                return .unknown(posixMessage(errno))
            }
            // A listener that cannot be verified is treated as active.  This
            // avoids unlinking a live socket when its backlog is unavailable.
            return .unknown("timed out while checking existing listener")
        }

        switch connectCode {
        case ECONNREFUSED, ENOENT:
            return .stale
        default:
            return .unknown(posixMessage(connectCode))
        }
    }

    // MARK: - Accept and request handling

    private func acceptLoop() {
        while isRunningNow() {
            guard let fd = currentListenerFD() else { return }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let result = Darwin.poll(&descriptor, 1, 250)
            if result < 0 {
                if errno == EINTR { continue }
                if isRunningNow() { stop() }
                return
            }
            if result == 0 { continue }
            if !isRunningNow() { return }
            if descriptor.revents & Int16(POLLNVAL) != 0 {
                if isRunningNow() { stop() }
                return
            }

            while isRunningNow() {
                let client = Darwin.accept(fd, nil, nil)
                if client < 0 {
                    let code = errno
                    if code == EINTR { continue }
                    if code == EAGAIN || code == EWOULDBLOCK { break }
                    if isRunningNow() { stop() }
                    return
                }
                handle(clientFD: client, acceptedAt: Date())
            }
        }
    }

    private func handle(clientFD: Int32, acceptedAt: Date) {
        defer { _ = Darwin.shutdown(clientFD, SHUT_RDWR); _ = Darwin.close(clientFD) }
        ControlTimingTrace.record(event: "accept", command: "<pending>", at: acceptedAt)
        var command = "<unknown>"
        do {
            try setNoSIGPIPE(clientFD)
            try setSocketTimeout(clientFD, seconds: ControlAPI.ioTimeout)
        } catch {
            _ = sendResponse(["ok": false, "error": errorObject(code: "socket_setup_failed", message: errorMessage(error))], on: clientFD)
            return
        }

        do {
            let request = try readRequest(from: clientFD)
            command = ControlTimingTrace.commandName(from: request)
            ControlTimingTrace.record(
                event: "request_received",
                command: command,
                elapsed: Date().timeIntervalSince(acceptedAt)
            )
            let response = makeResponse(for: request)
            let responseStartedAt = Date()
            ControlTimingTrace.record(event: "response_write_start", command: command, at: responseStartedAt)
            _ = sendResponse(response, on: clientFD)
            ControlTimingTrace.record(
                event: "response_write_end",
                command: command,
                elapsed: Date().timeIntervalSince(responseStartedAt)
            )
        } catch let error as RequestError {
            ControlTimingTrace.record(event: "request_error", command: command)
            let responseStartedAt = Date()
            ControlTimingTrace.record(event: "response_write_start", command: command, at: responseStartedAt)
            _ = sendResponse(["ok": false, "error": errorObject(code: error.code, message: error.message)], on: clientFD)
            ControlTimingTrace.record(
                event: "response_write_end",
                command: command,
                elapsed: Date().timeIntervalSince(responseStartedAt)
            )
        } catch {
            ControlTimingTrace.record(event: "request_error", command: command)
            let responseStartedAt = Date()
            ControlTimingTrace.record(event: "response_write_start", command: command, at: responseStartedAt)
            _ = sendResponse(["ok": false, "error": errorObject(code: "internal_error", message: errorMessage(error))], on: clientFD)
            ControlTimingTrace.record(
                event: "response_write_end",
                command: command,
                elapsed: Date().timeIntervalSince(responseStartedAt)
            )
        }
    }

    private func readRequest(from fd: Int32) throws -> [String: Any] {
        var bytes = Data()
        bytes.reserveCapacity(4096)
        let deadline = Date().addingTimeInterval(ControlAPI.ioTimeout)
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)

        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw RequestError(code: "read_timeout", message: "request read timed out") }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let timeoutMS = Int32(max(1, min(Double(Int32.max), ceil(remaining * 1000))))
            let pollResult = Darwin.poll(&descriptor, 1, timeoutMS)
            if pollResult < 0 {
                if errno == EINTR { continue }
                throw RequestError(code: "read_failed", message: posixMessage(errno))
            }
            if pollResult == 0 { throw RequestError(code: "read_timeout", message: "request read timed out") }

            let received = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
                guard let base = rawBuffer.baseAddress else { return 0 }
                return Darwin.recv(fd, base, rawBuffer.count, MSG_DONTWAIT)
            }
            if received > 0 {
                bytes.append(buffer, count: received)
                if let newline = bytes.firstIndex(of: 0x0A) {
                    let line = bytes.prefix(upTo: newline)
                    guard line.count <= ControlAPI.maxRequestBytes else {
                        throw RequestError(code: "request_too_large", message: "request exceeds 8 MiB")
                    }
                    guard !line.isEmpty else {
                        throw RequestError(code: "invalid_json", message: "request must be one JSON object")
                    }
                    let lineData = Data(line)
                    let object: Any
                    do {
                        object = try JSONSerialization.jsonObject(with: lineData, options: [.fragmentsAllowed])
                    } catch {
                        throw RequestError(code: "invalid_json", message: "request is not valid JSON: " + error.localizedDescription)
                    }
                    guard let request = object as? [String: Any] else {
                        throw RequestError(code: "invalid_json", message: "request must be one JSON object")
                    }
                    return request
                }
                if bytes.count > ControlAPI.maxRequestBytes {
                    throw RequestError(code: "request_too_large", message: "request exceeds 8 MiB")
                }
                continue
            }
            if received == 0 {
                throw RequestError(code: "unexpected_eof", message: "connection closed before a newline-delimited request")
            }
            let code = errno
            if code == EINTR || code == EAGAIN || code == EWOULDBLOCK { continue }
            throw RequestError(code: "read_failed", message: posixMessage(code))
        }
    }

    private func makeResponse(for request: [String: Any]) -> [String: Any] {
        var response: [String: Any]
        let command = ControlTimingTrace.commandName(from: request)
        ControlTimingTrace.record(event: "handler_start", command: command)
        response = invokeHandlerOnMain(request, command: command)
        ControlTimingTrace.record(event: "handler_end", command: command)
        if let existingOK = response["ok"] {
            guard existingOK is Bool else {
                return ["ok": false, "error": errorObject(code: "invalid_response", message: "handler ok field must be boolean")]
            }
        } else {
            response["ok"] = true
        }
        guard JSONSerialization.isValidJSONObject(response) else {
            return ["ok": false, "error": errorObject(code: "invalid_response", message: "handler returned values that are not JSON")]
        }
        return response
    }

    private func invokeHandlerOnMain(_ request: [String: Any], command: String) -> [String: Any] {
        if Thread.isMainThread {
            ControlTimingTrace.record(event: "main_direct_start", command: command)
            let response = handler(request)
            ControlTimingTrace.record(event: "main_direct_end", command: command)
            return response
        }
        let startedAt = Date()
        ControlTimingTrace.record(event: "main_sync_start", command: command, at: startedAt)
        let response = DispatchQueue.main.sync {
            handler(request)
        }
        ControlTimingTrace.record(
            event: "main_sync_end",
            command: command,
            elapsed: Date().timeIntervalSince(startedAt)
        )
        return response
    }

    @discardableResult
    private func sendResponse(_ response: [String: Any], on fd: Int32) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: response, options: [.sortedKeys]) else {
            return false
        }
        var payload = data
        payload.append(0x0A)
        return sendAll(payload, on: fd)
    }

    private func sendAll(_ data: Data, on fd: Int32) -> Bool {
        var offset = 0
        while offset < data.count {
            let count = data.count - offset
            let sent = data.withUnsafeBytes { rawBuffer -> Int in
                guard let base = rawBuffer.baseAddress else { return -1 }
                return Darwin.send(fd, base.advanced(by: offset), count, 0)
            }
            if sent > 0 {
                offset += sent
                continue
            }
            if sent == 0 { return false }
            let code = errno
            if code == EINTR { continue }
            return false
        }
        return true
    }

    // MARK: - Socket identity and helpers

    private func isRunningNow() -> Bool {
        stateLock.lock()
        let running = isRunning && !stopping
        stateLock.unlock()
        return running
    }

    private func currentListenerFD() -> Int32? {
        stateLock.lock()
        let fd = listenerFD
        stateLock.unlock()
        return fd >= 0 ? fd : nil
    }

    private func removeSocketIfOwned(device: dev_t, inode: ino_t) {
        var pathStat = stat()
        guard lstatPath(socketPath, &pathStat) == 0,
              pathStat.st_dev == device,
              pathStat.st_ino == inode,
              pathStat.st_uid == getuid() else {
            return
        }
        _ = Darwin.unlink(socketPath)
    }

    private func setNoSIGPIPE(_ fd: Int32) throws {
        var value: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &value, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw ControlAPIError.posix(code: "setsockopt_failed", message: posixMessage(errno))
        }
    }

    private func setNonBlocking(_ fd: Int32) throws {
        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw ControlAPIError.posix(code: "fcntl_failed", message: posixMessage(errno))
        }
    }

    private func setSocketTimeout(_ fd: Int32, seconds: TimeInterval) throws {
        var timeout = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - floor(seconds)) * 1_000_000))
        guard setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0,
              setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0 else {
            throw ControlAPIError.posix(code: "setsockopt_failed", message: posixMessage(errno))
        }
    }

    private func makeAddress(path: String) throws -> sockaddr_un {
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < 104 else { throw ControlAPIError.pathTooLong }
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

    private func addressLength(_ address: sockaddr_un) -> socklen_t {
        // Darwin's SUN_LEN is the struct prefix plus the path bytes, without
        // the unused tail of sun_path.
        return socklen_t(MemoryLayout<sockaddr_un>.size - MemoryLayout.size(ofValue: address.sun_path) + socketPath.utf8.count)
    }

    private func lstatPath(_ path: String, _ output: UnsafeMutablePointer<stat>) -> Int32 {
        path.withCString { Darwin.lstat($0, output) }
    }

    private func posixMessage(_ code: Int32) -> String {
        String(cString: Darwin.strerror(code))
    }

    private func errorMessage(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return String(describing: error)
    }

    private func errorObject(code: String, message: String) -> [String: Any] {
        return ["code": code, "message": message]
    }
}

private struct RequestError: Error {
    let code: String
    let message: String
}

public enum ControlAPIError: Error, LocalizedError {
    case alreadyRunning
    case listenerAlreadyRunning
    case invalidPath
    case pathTooLong
    case directoryNotDirectory
    case directoryOwner
    case directoryChanged
    case socketPathOccupied
    case socketOwner
    case posix(code: String, message: String)

    public var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            return "control API is already running"
        case .listenerAlreadyRunning:
            return "another control API listener is already using the socket"
        case .invalidPath:
            return "socket path must be an absolute path without NUL bytes"
        case .pathTooLong:
            return "socket path is too long for sockaddr_un"
        case .directoryNotDirectory:
            return "control socket parent is not a directory"
        case .directoryOwner:
            return "control socket parent is not owned by the current user"
        case .directoryChanged:
            return "control socket parent changed while it was being checked"
        case .socketPathOccupied:
            return "control socket path is occupied by a non-socket"
        case .socketOwner:
            return "control socket is not owned by the current user"
        case .posix(let code, let message):
            return code + ": " + message
        }
    }
}
