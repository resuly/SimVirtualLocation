//
//  LocationController.swift
//  SimVirtualLocation
//
//  Created by Sergey Shirnin on 21.02.2022.
//

import Combine
import CoreLocation
import MapKit
import MachO

class LocationController: NSObject, ObservableObject, MKMapViewDelegate, CLLocationManagerDelegate {

    // MARK: - Enums

    enum DeviceMode: Int, Identifiable {
        case simulator
        case device

        var id: Int { self.rawValue }
    }

    enum PointsMode: Int, Identifiable {
        case single
        case two
        case direction

        var id: Int { self.rawValue }
    }

    // MARK: - Public

    var alertText: String = ""

    // MARK: - Publishers

    @Published var isSimulating = false
    @Published var isPaused = false
    @Published var currentSimSpeed: Double = 0.0    // m/s, current simulation speed
    @Published var currentSimCourse: Double = -1.0  // degrees 0-360, -1 = unavailable
    @Published var speed: Double = 60.0
    @Published var pointsMode: PointsMode = .direction {
        didSet { handlePointsModeChange() }
    }
    @Published var deviceMode: DeviceMode = .simulator
    @Published var xcodePath: String = "/Applications/Xcode.app" {
        didSet { defaults.set(xcodePath, forKey: Constants.defaultsXcodePathKey) }
    }

    /// For iOS 17+
    @Published var useRSD: Bool = false

    @Published var bootedSimulators: [Simulator] = []
    @Published var selectedSimulator: String = ""

    @Published var connectedDevices: [Device] = []
    @Published var selectedDevice: String = ""

    @Published var showingAlert: Bool = false
    @Published var deviceType: Int = 0
    @Published var adbPath: String = ""
    @Published var adbDeviceId: String = ""
    @Published var isEmulator: Bool = false

    @Published var RSDAddress: String = ""
    @Published var RSDPort: String = ""

    @Published var detectedRSDTunnels: [RSDTunnel] = []
    @Published var selectedRSDTunnel: String = "" // Tunnel ID
    @Published var deviceReady: Bool = false // Device is ready for location simulation
    @Published var deviceStatusMessage: String = "" // Status message for device

    @Published var timeScale: Double = 1.5 {
        didSet { runner.timeDelay = timeScale }
    }

    @Published var logs: [LogEntry] = []
    @Published var showLogs: Bool = false

    // Maximum number of log entries to keep in memory (prevent memory leaks)
    private let maxLogEntries = 500

    // MARK: - Direction Mode

    @Published var waypoints: [MKPointAnnotation] = []

    var directionHintText: String {
        if waypoints.count >= 2 {
            return "Route with \(waypoints.count) points. Click 'Start Simulation' to begin."
        } else if waypoints.count == 1 {
            return "Add at least one more waypoint to create a route"
        } else {
            return "Click map to add waypoints"
        }
    }

    let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter
    }()

    // MARK: - Private

    private let mapView: MapView
    private let runner = Runner()
    private let currentSimulationAnnotation = MKPointAnnotation()
    private let locationManager = CLLocationManager()
    private let defaults: UserDefaults = UserDefaults.standard
    private let iOSDeveloperImagePath = "/Contents/Developer/Platforms/iPhoneOS.platform/DeviceSupport/"
    private let iOSDeveloperImageDmg = "/DeveloperDiskImage.dmg"
    private let iSODeveloperImageSignature = "/DeveloperDiskImage.dmg.signature"

    private var isMapCentered = false

    private var annotations: [MKAnnotation] = []
    private var route: MKRoute?
    private var directionRoutes: [MKRoute] = []  // For Direction mode multi-segment routes

    // Store all alternate routes for debugging and future route selection
    private var alternateRoutes: [MKRoute] = []  // For Two Points mode

    private var tracks: [Track] = []
    private var currentTrackIndex: Int = 0
    private var lastTrackLocation: CLLocationCoordinate2D?
    private var tracksTimes: [Track: Double] = [:]

    private var timer: Timer?

    @Published var savedLocations: [Location] = []
    @Published var routePresets: [RoutePreset] = []

    // MARK: - Init

    init(mapView: MapView) {
        self.mapView = mapView
        super.init()

        runner.log = { [unowned self] message in
            self.log(message)
        }

        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = kCLDistanceFilterNone
        locationManager.startUpdatingLocation()
        locationManager.requestLocation()

        mapView.mkMapView.delegate = self
        mapView.viewHolder.clickAction = handleMapClick
        mapView.viewHolder.doubleClickAction = handleMapDoubleClick

        Task { @MainActor in
            await refreshDevices()

            deviceType = defaults.integer(forKey: "device_type")
            adbPath = defaults.string(forKey: "adb_path") ?? ""
            adbDeviceId = defaults.string(forKey: "adb_device_id") ?? ""
            isEmulator = defaults.bool(forKey: "is_emulator")
            xcodePath = defaults.string(forKey: Constants.defaultsXcodePathKey) ?? "/Applications/Xcode.app"

            loadLocations()
            loadRoutePresets()
        }
    }

    // MARK: - Public

    @MainActor
    func refreshDevices() async {
        bootedSimulators = (try? getBootedSimulators()) ?? []
        selectedSimulator = bootedSimulators.first?.id ?? ""

        connectedDevices = (try? await getConnectedDevices()) ?? []
        selectedDevice = connectedDevices.first?.id ?? ""

        // Reset device connection state (user must explicitly connect)
        deviceReady = false
        deviceStatusMessage = connectedDevices.isEmpty ? "No devices found" : "Select a device and tap Connect"
    }

    @MainActor
    func autoSetupDevice() async {
        guard !selectedDevice.isEmpty,
              let device = connectedDevices.first(where: { $0.id == selectedDevice }) else {
            deviceReady = false
            deviceStatusMessage = "No device selected"
            return
        }

        if device.requiresRSD {
            // iOS 17+: Start tunnel automatically
            deviceStatusMessage = "Starting tunnel..."
            deviceReady = false

            runner.startTunnel(for: device.id, showAlert: showAlert) { [weak self] result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let tunnelInfo):
                        self?.RSDAddress = tunnelInfo.host
                        self?.RSDPort = tunnelInfo.port
                        self?.deviceStatusMessage = "Ready"
                        self?.deviceReady = true
                        self?.log("Tunnel ready: \(tunnelInfo.host):\(tunnelInfo.port)")
                    case .failure(let error):
                        self?.deviceStatusMessage = "Tunnel failed"
                        self?.deviceReady = false
                        self?.log("Tunnel error: \(error.localizedDescription)")
                        self?.showAlert("Failed to start tunnel: \(error.localizedDescription)")
                    }
                }
            }
        } else {
            // Pre-iOS 17: Ready immediately
            deviceStatusMessage = "Ready"
            deviceReady = true
            log("Device ready (iOS \(device.version))")
        }
    }

    func disconnectDevice() {
        runner.stop()
        deviceReady = false
        deviceStatusMessage = "Disconnected"
        RSDAddress = ""
        RSDPort = ""
        log("Device disconnected")
    }

    func checkIfTunnelRunning() -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "pgrep -f 'pymobiledevice3.*tunneld'"]

        let pipe = Pipe()
        task.standardOutput = pipe

        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            return false
        }
    }

    func showTunneldInstructions() {
        let command = "sudo pymobiledevice3 remote tunneld"

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(command, forType: .string)

        showAlert("""
        iOS 17+ requires tunneld

        Please run this command in Terminal:
        \(command)

        (Command copied to clipboard)

        Then click 'Refresh Devices' in this app.
        """)
    }




    func setCurrentLocation() {
        guard let location = locationManager.location?.coordinate else {
            showAlert("Current location is unavailable")
            return
        }
        run(location: location)
    }

    func setSelectedLocation(toBPoint: Bool = false) {
        if toBPoint {
            guard annotations.count == 2 else {
                showAlert("Point B is not selected")
                return
            }
            run(location: annotations[1].coordinate)
        } else {
            guard let annotation = annotations.first else {
                showAlert("Point A is not selected")
                return
            }
            run(location: annotation.coordinate)
        }
    }

    func makeRoute() {
        guard annotations.count == 2 else {
            showAlert("Route requires two points")
            return
        }

        let startPoint = annotations[0].coordinate
        let endPoint = annotations[1].coordinate

        let sourcePlacemark = MKPlacemark(coordinate: startPoint, addressDictionary: nil)
        let destinationPlacemark = MKPlacemark(coordinate: endPoint, addressDictionary: nil)

        let sourceMapItem = MKMapItem(placemark: sourcePlacemark)
        let destinationMapItem = MKMapItem(placemark: destinationPlacemark)

        let sourceAnnotation = MKPointAnnotation()

        if let location = sourcePlacemark.location {
            sourceAnnotation.coordinate = location.coordinate
        }

        let destinationAnnotation = MKPointAnnotation()

        if let location = destinationPlacemark.location {
            destinationAnnotation.coordinate = location.coordinate
        }

        self.mapView.mkMapView.removeAnnotations(mapView.mkMapView.annotations)
        self.mapView.mkMapView.showAnnotations([sourceAnnotation, destinationAnnotation], animated: true )

        let directionRequest = MKDirections.Request()
        directionRequest.source = sourceMapItem
        directionRequest.destination = destinationMapItem
        directionRequest.transportType = .automobile

        // Request alternate routes to get more options
        directionRequest.requestsAlternateRoutes = true

        // Use current time for accurate traffic-based ETA
        directionRequest.departureDate = Date()

        // iOS 16+: Route preferences
        if #available(macOS 13.0, *) {
            directionRequest.tollPreference = .any      // Allow toll roads
            directionRequest.highwayPreference = .any   // Allow highways
        }

        let directions = MKDirections(request: directionRequest)

        directions.calculate { (response, error) -> Void in
            guard let response = response else {
                if let error = error {
                    self.showAlert(error.localizedDescription)
                }
                return
            }

            // Store all alternate routes for debugging
            self.alternateRoutes = response.routes

            // Log number of routes returned
            self.log("Received \(response.routes.count) route(s) from Apple Maps")
            if response.routes.count > 1 {
                for (idx, route) in response.routes.enumerated() {
                    self.log("  Route \(idx+1): \(String(format: "%.2f", route.distance/1000))km, \(String(format: "%.1f", route.expectedTravelTime/60))min")
                }
            }

            // Use the first route (typically the fastest)
            let route = response.routes[0]

            if let currentRoute = self.route {
                self.mapView.mkMapView.removeOverlay(currentRoute.polyline)
            }
            self.route = route
            self.tracks = []
            self.mapView.mkMapView.addOverlay((route.polyline), level: MKOverlayLevel.aboveRoads)

            let rect = route.polyline.boundingMapRect
            self.mapView.mkMapView.setRegion(MKCoordinateRegion(rect.insetBy(dx: -1000, dy: -1000)), animated: true)
        }
    }

    func simulateRoute() {
        guard let route = route else {
            showAlert("No route for simulation")
            return
        }
        
        let buffer = UnsafeBufferPointer(start: route.polyline.points(), count: route.polyline.pointCount)
        
        for i in 0..<route.polyline.pointCount {
            let trackStartPoint = buffer[i]
            var trackEndPoint: MKMapPoint?
            if i + 1 < route.polyline.pointCount {
                trackEndPoint = buffer[i+1]
            }
            
            if let trackEndPoint = trackEndPoint {
                tracks.append(Track(startPoint: trackStartPoint, endPoint: trackEndPoint))
            }
        }
        
        // prints all tracks distances
        print(tracks.map { CLLocation.distance(from: $0.startPoint.coordinate, to: $0.endPoint.coordinate) })
        
        invalidateState()

        // Set initial position
        let startCoord = tracks[0].startPoint.coordinate
        mapView.mkMapView.removeAnnotation(currentSimulationAnnotation)
        currentSimulationAnnotation.coordinate = startCoord
        currentSimulationAnnotation.title = "Current location"
        mapView.mkMapView.addAnnotation(currentSimulationAnnotation)
        run(location: startCoord)

        // Center map on start position
        let region = MKCoordinateRegion(center: startCoord, latitudinalMeters: 1000, longitudinalMeters: 1000)
        mapView.mkMapView.setRegion(region, animated: true)

        let timer = Timer.scheduledTimer(withTimeInterval: timeScale, repeats: true) { [unowned self] timer in
            self.performMovement()
        }

        self.timer = timer
    }

    func simulateFromAToB() {
        guard annotations.count == 2 else {
            showAlert("Route requires two points")
            return
        }

        let startPoint = annotations[0]
        let endPoint = annotations[1]

        stopSimulation()
        tracks = [Track(startPoint: MKMapPoint(startPoint.coordinate), endPoint: MKMapPoint(endPoint.coordinate))]

        invalidateState()

        // Set initial position
        let startCoord = tracks[0].startPoint.coordinate
        mapView.mkMapView.removeAnnotation(currentSimulationAnnotation)
        currentSimulationAnnotation.coordinate = startCoord
        currentSimulationAnnotation.title = "Current location"
        mapView.mkMapView.addAnnotation(currentSimulationAnnotation)
        run(location: startCoord)

        // Center map on start position
        let region = MKCoordinateRegion(center: startCoord, latitudinalMeters: 1000, longitudinalMeters: 1000)
        mapView.mkMapView.setRegion(region, animated: true)

        let timer = Timer.scheduledTimer(withTimeInterval: timeScale, repeats: true) { [unowned self] timer in
            self.performMovement()
        }

        self.timer = timer
    }

    func updateMapRegion(force: Bool = false) {
        if locationManager.authorizationStatus == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
            return
        }
        
        guard !isMapCentered || force, let location = locationManager.location else {
            locationManager.requestAlwaysAuthorization()
            return
        }

        isMapCentered = true

        mapView.mkMapView.showsUserLocation = true

        let viewRegion = MKCoordinateRegion(center: location.coordinate, latitudinalMeters: 1000, longitudinalMeters: 1000)
        let adjustedRegion = mapView.mkMapView.regionThatFits(viewRegion)

        mapView.mkMapView.setRegion(adjustedRegion, animated: true)
        
        mapView.mkMapView.showsUserLocation = true
    }
    
    func prepareEmulator() {
        if adbDeviceId.isEmpty {
            showAlert("Please specify device id")
            return
        }
        
        if adbPath.isEmpty {
            showAlert("Please specify path to adb")
            return
        }
        
        executeAdbCommand(args: ["shell", "settings", "put", "secure", "location_providers_allowed", "+gps"])
        executeAdbCommand(
            args: ["shell", "settings", "put", "secure", "location_providers_allowed", "+network"],
            successMessage: "Emulator is ready"
        )
    }

    func installHelperApp() {
        if adbDeviceId.isEmpty {
            showAlert("Please specify device id")
            return
        }

        if adbPath.isEmpty {
            showAlert("Please specify path to adb")
            return
        }

        let apkPath = Bundle.main.url(forResource: "helper-app", withExtension: "apk")!.path
        let args = ["-s", adbDeviceId, "install", apkPath]

        executeAdbCommand(
            args: args,
            successMessage: "Helper app successfully installed. Please open MockLocationForDeveloper app on your phone and grant all required permissions"
        )
    }

    func pauseSimulation() {
        guard isSimulating && !isPaused else { return }
        isPaused = true
        timer?.invalidate()
        timer = nil
        log("Simulation paused")
    }

    func resumeSimulation() {
        guard isSimulating && isPaused else { return }
        isPaused = false

        // Restart timer
        timer = Timer.scheduledTimer(withTimeInterval: timeScale, repeats: true) { [unowned self] timer in
            self.performMovement()
        }
        log("Simulation resumed")
    }

    func stopSimulation() {
        isSimulating = false
        isPaused = false
        currentSimSpeed = 0.0
        currentSimCourse = -1.0
        timer?.invalidate()
        timer = nil
        runner.stop()
        tracksTimes.removeAll() // Clear simulation tracking data
        log("Simulation stopped")
    }

    func reset() {
        resetAll()
    }

    // MARK: - MKMapViewDelegate

    func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
        let renderer = MKPolylineRenderer(overlay: overlay)
        renderer.strokeColor = NSColor(red: 17.0/255.0, green: 147.0/255.0, blue: 255.0/255.0, alpha: 1)
        renderer.lineWidth = 5.0
        return renderer
    }

    func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
        if annotation === currentSimulationAnnotation {
            let marker = mapView.dequeueReusableAnnotationView(
                withIdentifier: "simulationMarker"
            ) as? MKMarkerAnnotationView ?? MKMarkerAnnotationView(
                annotation: annotation,
                reuseIdentifier: "simulationMarker"
            )
            marker.annotation = annotation
            marker.markerTintColor = .orange
            marker.isDraggable = false
            return marker
        }

        // Check if annotation is a waypoint
        if waypoints.contains(where: { $0 === annotation }) {
            let marker = mapView.dequeueReusableAnnotationView(
                withIdentifier: "waypointMarker"
            ) as? MKMarkerAnnotationView ?? MKMarkerAnnotationView(
                annotation: annotation,
                reuseIdentifier: "waypointMarker"
            )
            marker.annotation = annotation
            marker.markerTintColor = .red
            marker.isDraggable = !isSimulating  // Disable drag during simulation
            marker.canShowCallout = false  // Disable callout to prevent interference
            marker.dragState = .none

            // Find the waypoint index for the title
            if let index = waypoints.firstIndex(where: { $0 === annotation }) {
                marker.glyphText = "\(index + 1)"
            }

            return marker
        }

        return nil
    }

    // Handle waypoint drag events
    func mapView(_ mapView: MKMapView, annotationView view: MKAnnotationView, didChange newState: MKAnnotationView.DragState, fromOldState oldState: MKAnnotationView.DragState) {
        guard let annotation = view.annotation as? MKPointAnnotation else { return }
        guard let index = waypoints.firstIndex(where: { $0 === annotation }) else { return }

        switch newState {
        case .starting:
            log("Started dragging waypoint \(index + 1)")

        case .dragging:
            // Update coordinate during drag
            waypoints[index].coordinate = annotation.coordinate

        case .ending, .canceling:
            // Update final coordinate
            waypoints[index].coordinate = annotation.coordinate
            log("Moved waypoint \(index + 1) to: \(annotation.coordinate.latitude), \(annotation.coordinate.longitude)")

            // Force UI update by reassigning the array
            let updatedWaypoints = waypoints
            waypoints = []
            DispatchQueue.main.async {
                self.waypoints = updatedWaypoints

                // Regenerate route if we have at least 2 waypoints
                if self.waypoints.count >= 2 {
                    self.autoGenerateRoute()
                }
            }

        case .none:
            break

        @unknown default:
            break
        }
    }

    // MARK: - CLLocationManagerDelegate

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        updateMapRegion()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        updateMapRegion()
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print(error.localizedDescription)
    }

    func mountDeveloperImage() {
        guard let device = connectedDevices.first(where: { $0.id == selectedDevice }) else {
            showAlert("No selected device")
            return
        }

        Task { @MainActor in
            let mountTask = try await runner.taskForIOS(
                args: [
                    "mounter",
                    "mount-developer",
                    "--udid",
                    device.id,
                    makeDeveloperImageDmgPath(iOSVersion: device.version),
                    makeDeveloperImageSignaturePath(iOSVersion: device.version)
                ],
                showAlert: showAlert
            )

            let pipe = Pipe()
            mountTask.standardOutput = pipe

            let errorPipe = Pipe()
            mountTask.standardError = errorPipe

            do {
                try mountTask.run()
                mountTask.waitUntilExit()

                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                pipe.fileHandleForReading.closeFile()

                if
                    let errorData = try? errorPipe.fileHandleForReading.readToEnd(),
                    let errorText = String(data: errorData, encoding: .utf8),
                    !errorText.isEmpty {
                    if errorText.range(of: "{'Error': 'DeviceLocked'}") != nil {
                        showAlert("Error: Device is locked")
                    } else {
                        showAlert(errorText)
                    }
                }

                if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                    showAlert(text)
                }
            } catch {
                showAlert(error.localizedDescription)
            }
        }
    }

    func unmountDeveloperImage() {
        Task { @MainActor in
            let mountTask = try await runner.taskForIOS(
                args: [
                    "mounter",
                    "umount-developer"
                ],
                showAlert: showAlert
            )

            let pipe = Pipe()
            mountTask.standardOutput = pipe

            let errorPipe = Pipe()
            mountTask.standardError = errorPipe

            do {
                try mountTask.run()
                mountTask.waitUntilExit()

                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                pipe.fileHandleForReading.closeFile()

                if
                    let errorData = try? errorPipe.fileHandleForReading.readToEnd(),
                    let errorText = String(data: errorData, encoding: .utf8),
                    !errorText.isEmpty {
                    if errorText.range(of: "{'Error': 'DeviceLocked'}") != nil {
                        showAlert("Error: Device is locked")
                    } else {
                        showAlert(errorText)
                    }
                }

                if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                    showAlert(text)
                }
            } catch {
                showAlert(error.localizedDescription)
            }
        }
    }

    func savePointA() {
        guard let point = annotations.first?.coordinate else {
            showAlert("Point A is not selected")
            return
        }

        savedLocations.append(
            Location(
                name: "Point A (\(point.latitude) - \(point.longitude))",
                latitude: point.latitude,
                longitude: point.longitude
            )
        )

        saveSavedLocations()
    }

    func savePointB() {
        guard annotations.count == 2, let point = annotations.last?.coordinate else {
            showAlert("Point B is not selected")
            return
        }

        savedLocations.append(
            Location(
                name: "Point B (\(point.latitude) - \(point.longitude))",
                latitude: point.latitude,
                longitude: point.longitude
            )
        )

        saveSavedLocations()
    }

    func removeLocation(location: Location) {
        savedLocations.removeAll { $0.id == location.id }

        saveSavedLocations()
    }

    func update(_ location: Location, with name: String) {
        guard let locationIndex = savedLocations.firstIndex(where: { $0.id == location.id }) else {
            return
        }

        savedLocations.remove(at: locationIndex)
        savedLocations.insert(
            Location(
                name: name,
                latitude: location.latitude,
                longitude: location.longitude
            ),
            at: locationIndex
        )

        saveSavedLocations()
    }

    func putLocationOnMap(location: Location) {
        addLocation(coordinate: CLLocationCoordinate2D(latitude: location.latitude, longitude: location.longitude))
    }

    func showAlert(_ text: String) {
        DispatchQueue.main.async {
            // Truncate long error messages (like Python tracebacks)
            var displayText = text

            // Check for common errors and show friendly messages
            if text.contains("TimeoutError") || text.contains("timeout") {
                displayText = "⏱ Connection timeout.\n\nMake sure your iPhone is:\n• Unlocked\n• Connected via USB\n• Trusted on this Mac\n\nReconnecting..."
            } else if text.contains("ConnectionError") || text.contains("connection") {
                displayText = "⚠️ Connection lost.\n\nPlease check:\n• iPhone is connected\n• Cable is secure\n\nReconnecting..."
            } else if text.contains("Traceback") {
                // Python traceback - extract the error type
                displayText = "Python error occurred.\n\nCheck logs at bottom for details."
            } else if displayText.count > 300 {
                // Long error message - truncate
                displayText = String(displayText.prefix(300)) + "...\n\n📋 See logs below for full error"
            }

            self.alertText = displayText
            self.showingAlert = true
            self.isSimulating = false
        }
        log("Alert: \(text)")
    }

    func importLocations(from data: Data) {
        let locations = (try? JSONDecoder().decode([Location].self, from: data)) ?? []

        savedLocations.append(contentsOf: locations)
        saveSavedLocations()
    }
    
    func setToCoordinate(latString: String = "", lngString: String = "") {
        var lat: Double = 0
        var lng: Double = 0
        
        lat = Double(latString) ?? 0
        lng = Double(lngString) ?? 0
        
        guard lat > 0, lng > 0 else {
            showAlert("Current location is unavailable")
            return
        }
        
        putLocationOnMap(location: .init(name: "", latitude: lat, longitude: lng))
        run(location: .init(latitude: lat, longitude: lng))
    }
    
    func setToCoordinate(latLngString: String = "") {
        let splitValue = latLngString.components(separatedBy: ",")
     
        guard latLngString.contains(","), splitValue.count == 2 else {
            showAlert("Current location is unavailable")
            return
        }
        
        let latSplitString = splitValue[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let lngSplitString = splitValue[1].trimmingCharacters(in: .whitespacesAndNewlines)
        
        setToCoordinate(latString: latSplitString, lngString: lngSplitString)
    }

    // MARK: - Private

    private func loadLocations() {
        guard let data = defaults.data(forKey: Constants.defaultsSavedLocationsPathKey) else {
            return
        }

        savedLocations = (try? JSONDecoder().decode([Location].self, from: data)) ?? []
    }

    private func saveSavedLocations() {
        if let data = try? JSONEncoder().encode(savedLocations) {
            defaults.set(data, forKey: Constants.defaultsSavedLocationsPathKey)
        }
    }

    private func loadRoutePresets() {
        var presets = RoutePreset.builtIn
        if let data = defaults.data(forKey: Constants.defaultsRoutePresetsKey),
           let userPresets = try? JSONDecoder().decode([RoutePreset].self, from: data) {
            presets.append(contentsOf: userPresets)
        }
        routePresets = presets
    }

    private func saveUserRoutePresets() {
        // Only save user-created presets (exclude built-in)
        let builtInNames = Set(RoutePreset.builtIn.map { $0.name })
        let userPresets = routePresets.filter { !builtInNames.contains($0.name) }
        if let data = try? JSONEncoder().encode(userPresets) {
            defaults.set(data, forKey: Constants.defaultsRoutePresetsKey)
        }
    }

    private func invalidateState() {
        timer?.invalidate()
        timer = nil
        isSimulating = true
        lastTrackLocation = nil
        currentTrackIndex = 0
        tracksTimes.removeAll() // Clear previous simulation data
    }

    private func performMovement() {
        guard self.isSimulating, !self.isPaused, self.tracks.count > 0, self.currentTrackIndex < self.tracks.count else {
            if self.isPaused {
                return // Keep paused state
            }
            self.isSimulating = false
            self.isPaused = false
            self.timer?.invalidate()
            self.timer = nil
            self.currentTrackIndex = 0
            self.printTimes()
            return
        }

        let track = self.tracks[self.currentTrackIndex]
        let trackMove = track.getNextLocation(
            from: self.lastTrackLocation,
            speed: (self.speed / 3.6) * self.timeScale
        )

        self.mapView.mkMapView.removeAnnotation(self.currentSimulationAnnotation)

        switch trackMove {
            case .moveTo(let to, let from, let withSpeed):
                self.lastTrackLocation = to
                let bearing = from.bearing(to: to)
                let actualSpeed = withSpeed / self.timeScale  // Convert distance-per-tick to m/s
                self.currentSimSpeed = actualSpeed
                self.currentSimCourse = bearing
                self.run(location: to, speed: actualSpeed, course: bearing)
                self.currentSimulationAnnotation.coordinate = to
                print("move to - distance=\(CLLocation.distance(from: from, to: to)), speed=\(actualSpeed), course=\(bearing)")

            case .finishTo(let to, let from, let withSpeed):
                self.lastTrackLocation = nil
                self.currentTrackIndex += 1
                let bearing = from.bearing(to: to)
                let actualSpeed = withSpeed / self.timeScale  // Convert distance-per-tick to m/s
                self.currentSimSpeed = actualSpeed
                self.currentSimCourse = bearing
                self.run(location: to, speed: actualSpeed, course: bearing)
                self.currentSimulationAnnotation.coordinate = to
                print("finish to - distance=\(CLLocation.distance(from: from, to: to)), speed=\(actualSpeed), course=\(bearing)")
        }

        self.tracksTimes[track] = (self.tracksTimes[track] ?? 0) + self.timeScale
        self.mapView.mkMapView.addAnnotation(self.currentSimulationAnnotation)

        // Keep map centered on current simulation position
        let region = MKCoordinateRegion(
            center: self.currentSimulationAnnotation.coordinate,
            span: self.mapView.mkMapView.region.span
        )
        self.mapView.mkMapView.setRegion(region, animated: true)
    }
    
    private func executeAdbCommand(args: [String], successMessage: String? = nil) {
        if adbDeviceId.isEmpty {
            showAlert("Please specify device id")
            return
        }
        
        if adbPath.isEmpty {
            showAlert("Please specify path to adb")
            return
        }
        
        let task = Process()
        task.executableURL = URL(string: "file://\(adbPath)")!
        task.arguments = args

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
        } else if let successMessage = successMessage {
            showAlert(successMessage)
        }
    }

    private func printTimes() {
        tracksTimes.forEach { track, time in
            let distance = CLLocation.distance(from: track.startPoint.coordinate, to: track.endPoint.coordinate)
            let speed = distance / time
            print("Track result: speed=\(speed * 3.6), distance=\(distance), time=\(time)")
        }
    }

    private func handlePointsModeChange() {
        // Switching away from Direction mode
        if pointsMode != .direction && !waypoints.isEmpty {
            clearAllWaypoints()
        }

        // Switching to Direction mode
        if pointsMode == .direction {
            // Clear existing annotations from Single/Two mode
            if !annotations.isEmpty {
                mapView.mkMapView.removeAnnotations(annotations)
                annotations = []
            }
            if let route = route {
                mapView.mkMapView.removeOverlay(route.polyline)
            }
        }

        // Original Single mode logic
        if pointsMode == .single && annotations.count == 2, let second = annotations.last {
            mapView.mkMapView.removeAnnotation(second)

            if let route = route {
                mapView.mkMapView.removeOverlay(route.polyline)
            }

            annotations = [annotations[0]]
        }
    }

    private func handleMapClick(_ sender: NSClickGestureRecognizer) {
        let point = sender.location(in: mapView.mkMapView)

        // In Direction mode, check if clicking on an existing waypoint (for dragging)
        if pointsMode == .direction {
            let view = mapView.mkMapView.hitTest(point)
            if let annotationView = view as? MKAnnotationView,
               let annotation = annotationView.annotation as? MKPointAnnotation,
               waypoints.contains(where: { $0 === annotation }) {
                // Clicking on a waypoint - let the drag gesture handle it
                return
            }
        }

        handleSet(point: point)
    }

    private func handleMapDoubleClick(_ sender: NSClickGestureRecognizer) {
        // Double click disabled for Direction mode - using single click only
    }

    private func handleSet(point: CGPoint) {
        guard !isSimulating else { return }

        let clickLocation = mapView.mkMapView.convert(point, toCoordinateFrom: mapView.mkMapView)

        if pointsMode == .direction {
            addWaypoint(coordinate: clickLocation)
        } else {
            addLocation(coordinate: clickLocation)
        }
    }

    private func addLocation(coordinate: CLLocationCoordinate2D) {
        if pointsMode == .single {
            mapView.mkMapView.removeAnnotations(annotations)
            annotations = []
        }

        if annotations.count == 2 {
            mapView.mkMapView.removeAnnotations(mapView.mkMapView.annotations)
            annotations = []
            return
        }

        let annotation = MKPointAnnotation()
        annotation.coordinate = coordinate
        annotation.title = annotations.count == 0 ? "A" : "B"

        annotations.append(annotation)
        self.mapView.mkMapView.addAnnotation(annotation)
    }

    private func run(location: CLLocationCoordinate2D, speed: Double? = nil, course: Double? = nil) {
        defaults.set(deviceType, forKey: "device_type")
        defaults.set(adbPath, forKey: "adb_path")
        defaults.set(adbDeviceId, forKey: "adb_device_id")
        defaults.set(isEmulator, forKey: "is_emulator")

        if deviceType != 0 {
            do {
                try runOnAndroid(location: location)
            } catch {
                showAlert("\(error)")
            }
            return
        }
        if deviceMode == .device {
            // Auto-detect if device requires RSD based on iOS version
            if let device = connectedDevices.first(where: { $0.id == selectedDevice }),
               device.requiresRSD {
                // iOS 17+: Use RSD tunnel connection
                if !deviceReady || RSDAddress.isEmpty || RSDPort.isEmpty {
                    showAlert("Device not ready. Please click 'Refresh Devices' to establish tunnel.")
                    return
                }

                Task {
                    do {
                        try await runner.runOnNewIos(
                            location: location,
                            deviceId: selectedDevice,
                            rsdHost: RSDAddress,
                            rsdPort: RSDPort,
                            showAlert: showAlert
                        )
                    } catch {
                        let errorMsg = error.localizedDescription
                        // If tunnel error, try to reconnect
                        if errorMsg.contains("Timeout") || errorMsg.contains("timeout") ||
                           errorMsg.contains("Connection") || errorMsg.contains("connection") {
                            log("Tunnel error detected: \(errorMsg)")
                            deviceReady = false
                            deviceStatusMessage = "Reconnecting..."
                            showAlert("Tunnel connection lost. Reconnecting...")
                            await autoSetupDevice()
                        } else {
                            showAlert(errorMsg)
                        }
                    }
                }
            } else {
                // Pre-iOS 17: Use traditional method
                Task {
                    try await runner.runOnIos(
                        location: location,
                        deviceId: selectedDevice,
                        showAlert: showAlert
                    )
                }
            }
        } else {
            if bootedSimulators.isEmpty {
                isSimulating = false
                showAlert(SimulatorFetchError.noBootedSimulators.description)
            }
            runner.runOnSimulator(
                location: location,
                selectedSimulator: selectedSimulator,
                bootedSimulators: bootedSimulators,
                speed: speed,
                course: course,
                showAlert: showAlert
            )
        }
    }
    
    private func runOnAndroid(location: CLLocationCoordinate2D) throws {
        if adbDeviceId.isEmpty {
            showAlert("Please specify device id")
            return
        }
        
        if adbPath.isEmpty {
            showAlert("Please specify path to adb")
            return
        }
        
        log("""
        Run on android 
        - location: \(location)
        - adbDeviceId: \(adbDeviceId)
        - adbPath: \(adbPath)
        - isEmulator: \(isEmulator)
        """)
        runner.runOnAndroid(
            location: location,
            adbDeviceId: adbDeviceId,
            adbPath: adbPath,
            isEmulator: isEmulator,
            showAlert: showAlert
        )
    }

    private func resetAll() {
        mapView.mkMapView.removeAnnotations(mapView.mkMapView.annotations)
        annotations = []

        // Clear waypoints and direction routes
        waypoints = []
        directionRoutes = []

        if let route = route {
            mapView.mkMapView.removeOverlay(route.polyline)
        }

        clearRouteOverlays()

        if deviceType == 0 {
            runner.resetIos(showAlert: showAlert)
        } else {
            runner.resetAndroid(adbDeviceId: adbDeviceId, adbPath: adbPath, showAlert: showAlert)
        }
    }

    private func makeDeveloperImageDmgPath(iOSVersion: String) -> String {
        return "\(xcodePath)\(iOSDeveloperImagePath)\(iOSVersion)\(iOSDeveloperImageDmg)"
    }

    private func makeDeveloperImageSignaturePath(iOSVersion: String) -> String {
        return "\(xcodePath)\(iOSDeveloperImagePath)\(iOSVersion)\(iSODeveloperImageSignature)"
    }

    private func log(_ message: String) {
        logs.insert(LogEntry(date: Date(), message: message), at: 0)

        // Limit log size to prevent memory issues during long simulations
        if logs.count > maxLogEntries {
            logs.removeLast(logs.count - maxLogEntries)
        }
    }

    func clearLogs() {
        logs.removeAll()
        log("Logs cleared")
    }

    // MARK: - Route Presets

    func loadPreset(_ preset: RoutePreset) {
        if pointsMode != .direction {
            pointsMode = .direction
        }

        // Clear existing waypoints
        clearAllWaypoints()

        // Add waypoints from preset
        for coord in preset.coordinates {
            addWaypoint(coordinate: coord.clCoordinate)
        }

        log("Loaded preset: \(preset.name) (\(preset.coordinates.count) points)")
    }

    func saveCurrentRouteAsPreset(name: String) {
        guard !waypoints.isEmpty else {
            showAlert("No waypoints to save")
            return
        }

        let coordinates = waypoints.map {
            RoutePreset.Coordinate(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude)
        }
        let preset = RoutePreset(name: name, coordinates: coordinates)

        // Replace if same name exists (among user presets)
        let builtInNames = Set(RoutePreset.builtIn.map { $0.name })
        if !builtInNames.contains(name) {
            routePresets.removeAll { $0.name == name }
        }
        routePresets.append(preset)
        saveUserRoutePresets()
        log("Saved preset: \(name)")
    }

    func deletePreset(_ preset: RoutePreset) {
        let builtInNames = Set(RoutePreset.builtIn.map { $0.name })
        guard !builtInNames.contains(preset.name) else {
            showAlert("Cannot delete built-in preset")
            return
        }
        routePresets.removeAll { $0.name == preset.name }
        saveUserRoutePresets()
        log("Deleted preset: \(preset.name)")
    }

    // MARK: - Direction Mode Methods

    func addWaypoint(coordinate: CLLocationCoordinate2D) {
        guard pointsMode == .direction else { return }

        let annotation = MKPointAnnotation()
        annotation.coordinate = coordinate
        annotation.title = "\(waypoints.count + 1)"

        waypoints.append(annotation)
        mapView.mkMapView.addAnnotation(annotation)

        log("Added waypoint \(waypoints.count): \(coordinate.latitude), \(coordinate.longitude)")

        // Auto-generate route if we have 2 or more waypoints
        if waypoints.count >= 2 {
            autoGenerateRoute()
        }
    }

    func deleteWaypoint(at index: Int) {
        guard index < waypoints.count else { return }

        let waypoint = waypoints[index]
        mapView.mkMapView.removeAnnotation(waypoint)
        waypoints.remove(at: index)

        // Renumber remaining waypoints
        for (idx, point) in waypoints.enumerated() {
            point.title = "\(idx + 1)"
        }

        log("Deleted waypoint \(index + 1)")

        // Clear route overlays
        clearRouteOverlays()

        // Regenerate route if we still have 2+ points
        if waypoints.count >= 2 {
            autoGenerateRoute()
        }
    }

    func moveWaypoint(from source: IndexSet, to destination: Int) {
        waypoints.move(fromOffsets: source, toOffset: destination)

        // Renumber all waypoints
        for (idx, point) in waypoints.enumerated() {
            point.title = "\(idx + 1)"
        }

        log("Reordered waypoints")

        // Clear and regenerate route
        clearRouteOverlays()
        if waypoints.count >= 2 {
            autoGenerateRoute()
        }
    }

    func clearAllWaypoints() {
        mapView.mkMapView.removeAnnotations(waypoints)
        waypoints = []
        clearRouteOverlays()
        log("Cleared all waypoints")
    }

    private func autoGenerateRoute() {
        guard waypoints.count >= 2 else { return }

        // Clear existing route overlays
        clearRouteOverlays()

        // Calculate routes between each pair of consecutive waypoints
        let segmentCount = waypoints.count - 1
        var allRoutes: [MKRoute?] = Array(repeating: nil, count: segmentCount)
        let group = DispatchGroup()

        for i in 0..<segmentCount {
            group.enter()

            let start = MKPlacemark(coordinate: waypoints[i].coordinate)
            let end = MKPlacemark(coordinate: waypoints[i + 1].coordinate)

            let request = MKDirections.Request()
            request.source = MKMapItem(placemark: start)
            request.destination = MKMapItem(placemark: end)
            request.transportType = .automobile

            // Request alternate routes for better options
            request.requestsAlternateRoutes = true

            // Use current time for accurate ETA
            request.departureDate = Date()

            // iOS 16+: Route preferences
            if #available(macOS 13.0, *) {
                request.tollPreference = .any
                request.highwayPreference = .any
            }

            let directions = MKDirections(request: request)
            directions.calculate { [weak self] response, error in
                defer { group.leave() }

                if let route = response?.routes.first {
                    allRoutes[i] = route
                    // Log alternate routes if available
                    if let routeCount = response?.routes.count, routeCount > 1 {
                        self?.log("Segment \(i+1): \(routeCount) route options available")
                    }
                } else if let error = error {
                    self?.log("Route segment \(i+1)→\(i+2) error: \(error.localizedDescription)")
                }
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self = self else { return }

            // Save routes for simulation, filtering out any failed segments
            let orderedRoutes = allRoutes.compactMap { $0 }
            self.directionRoutes = orderedRoutes

            // Add all route segments to map
            for route in orderedRoutes {
                self.mapView.mkMapView.addOverlay(route.polyline, level: .aboveRoads)
            }

            // Calculate total distance
            let totalDistance = orderedRoutes.reduce(0.0) { $0 + $1.distance }
            self.log("Route generated: \(String(format: "%.1f", totalDistance / 1000)) km")

            // Adjust map to show all waypoints
            if !self.waypoints.isEmpty {
                self.mapView.mkMapView.showAnnotations(self.waypoints, animated: true)
            }
        }
    }

    private func clearRouteOverlays() {
        let overlays = mapView.mkMapView.overlays
        mapView.mkMapView.removeOverlays(overlays)
        directionRoutes = []
    }

    func simulateDirectionRoute() {
        guard waypoints.count >= 2 else {
            showAlert("Need at least 2 waypoints to start simulation")
            return
        }

        guard !directionRoutes.isEmpty else {
            showAlert("Route not ready. Please wait for route generation to complete.")
            return
        }

        // Build tracks from all route segments
        tracks = []
        tracksTimes = [:]

        for route in directionRoutes {
            let buffer = UnsafeBufferPointer(start: route.polyline.points(), count: route.polyline.pointCount)

            for i in 0..<route.polyline.pointCount {
                let trackStartPoint = buffer[i]
                var trackEndPoint: MKMapPoint?
                if i + 1 < route.polyline.pointCount {
                    trackEndPoint = buffer[i+1]
                }

                if let trackEndPoint = trackEndPoint {
                    let track = Track(startPoint: trackStartPoint, endPoint: trackEndPoint)
                    tracks.append(track)
                }
            }
        }

        if tracks.isEmpty {
            showAlert("No route for simulation")
            return
        }

        // Start simulation
        currentTrackIndex = 0
        lastTrackLocation = nil
        isSimulating = true

        // Set initial position and send to device
        let startCoord = tracks[0].startPoint.coordinate
        mapView.mkMapView.removeAnnotation(currentSimulationAnnotation)
        currentSimulationAnnotation.coordinate = startCoord
        currentSimulationAnnotation.title = "Current location"
        mapView.mkMapView.addAnnotation(currentSimulationAnnotation)
        run(location: startCoord)

        // Center map on start position
        let region = MKCoordinateRegion(center: startCoord, latitudinalMeters: 1000, longitudinalMeters: 1000)
        mapView.mkMapView.setRegion(region, animated: true)

        timer = Timer.scheduledTimer(withTimeInterval: timeScale, repeats: true) { [unowned self] timer in
            self.performMovement()
        }

        log("Started Direction mode simulation with \(tracks.count) track segments")
    }
}

private extension LocationController {

    @MainActor
    private func getConnectedDevices() async throws -> [Device] {
        // Fixed: --no-color must be before subcommand
        let task = try await runner.taskForIOS(args: ["--no-color", "usbmux", "list", "-u"], showAlert: showAlert)

        log("getConnectedDevices: \(task.executableURL!.absoluteString) \(task.arguments!.joined(separator: " "))")

        let pipe = Pipe()
        task.standardOutput = pipe

        let errorPipe = Pipe()
        task.standardError = errorPipe

        try task.run()
        task.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        pipe.fileHandleForReading.closeFile()

        if task.terminationStatus != 0 {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorText = String(decoding: errorData, as: UTF8.self)
            log("Device detection error: \(errorText)")
            throw SimulatorFetchError.simctlFailed
        }

        let devices = try JSONDecoder().decode([Device].self, from: data)

        log("connected devices: [\(devices.map { "\($0.id) \($0.name) \($0.version)" }.joined(separator: ", "))]")

        return devices
    }

    private func getBootedSimulators() throws -> [Simulator] {
        let task = Process()
        task.launchPath = "/usr/bin/xcrun"
        task.arguments = ["simctl", "list", "-j", "devices"]

        log("getBootedSimulators: \(task.executableURL!.absoluteString) \(task.arguments!.joined(separator: " "))")

        let pipe = Pipe()
        task.standardOutput = pipe

        task.launch()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        pipe.fileHandleForReading.closeFile()

        if task.terminationStatus != 0 {
            throw SimulatorFetchError.simctlFailed
        }

        let bootedSimulators: [Simulator]

        do {
            bootedSimulators = try JSONDecoder().decode(Simulators.self, from: data).bootedSimulators
        } catch {
            throw SimulatorFetchError.failedToReadOutput
        }

        if bootedSimulators.isEmpty {
            throw SimulatorFetchError.noBootedSimulators
        }

        log("booted simulators: [\(bootedSimulators.map { "\($0.id) \($0.name)" }.joined(separator: ", "))]")

        return [Simulator.empty()] + bootedSimulators
    }


    // MARK: - Debug Methods

    public func getRouteDebugData() -> RouteDebugData {
        var summary = ""
        var details = ""
        var steps = ""
        var polyline = ""
        var json = ""

        if pointsMode == .direction {
            // Summary
            summary += "Mode: Direction (Multi-waypoint)\n"
            summary += "Waypoints: \(waypoints.count)\n"
            summary += "Route Segments: \(directionRoutes.count)\n"
            summary += "Total Distance: \(String(format: "%.2f", directionRoutes.reduce(0) { $0 + $1.distance } / 1000)) km\n"
            summary += "Total Expected Time: \(String(format: "%.1f", directionRoutes.reduce(0) { $0 + $1.expectedTravelTime } / 60)) min\n\n"

            for (idx, waypoint) in waypoints.enumerated() {
                summary += "Waypoint \(idx + 1): (\(waypoint.coordinate.latitude), \(waypoint.coordinate.longitude))\n"
            }

            // Details, steps, and polyline for each segment
            for (idx, route) in directionRoutes.enumerated() {
                details += "--- Segment \(idx + 1) ---\n"
                details += formatRouteBasicInfo(route)
                details += "\n\n"

                steps += "--- Segment \(idx + 1) Steps ---\n"
                steps += formatRouteSteps(route)
                steps += "\n\n"

                polyline += "--- Segment \(idx + 1) Polyline ---\n"
                polyline += formatRoutePolyline(route, sampleCount: 5)
                polyline += "\n\n"

                json += formatRouteJSON(route, segmentIndex: idx + 1)
            }

        } else if pointsMode == .two, let currentRoute = route {
            // Summary
            summary += "Mode: Two Points (A to B)\n"
            summary += "Alternate Routes: \(alternateRoutes.count)\n"
            summary += "Currently Using: Route 1 (Primary)\n\n"

            // Show summary of all alternate routes
            if alternateRoutes.count > 1 {
                summary += "Route Comparison:\n"
                for (idx, route) in alternateRoutes.enumerated() {
                    summary += "  Route \(idx+1): \(String(format: "%.2f", route.distance / 1000)) km, "
                    summary += "\(String(format: "%.1f", route.expectedTravelTime / 60)) min"
                    if #available(macOS 13.0, *) {
                        if route.hasTolls { summary += " [Tolls]" }
                        if route.hasHighways { summary += " [Highway]" }
                    }
                    summary += "\n"
                }
                summary += "\n"
            }

            summary += "Primary Route:\n"
            summary += "  Distance: \(String(format: "%.2f", currentRoute.distance / 1000)) km\n"
            summary += "  Time: \(String(format: "%.1f", currentRoute.expectedTravelTime / 60)) min\n"

            // Details - show all routes
            if alternateRoutes.count > 1 {
                for (idx, route) in alternateRoutes.enumerated() {
                    details += "═══ Route \(idx+1) ═══\n"
                    details += formatRouteBasicInfo(route)
                    details += "\n\n"
                }
            } else {
                details = formatRouteBasicInfo(currentRoute)
            }

            // Steps - primary route only
            steps = formatRouteSteps(currentRoute)

            // Polyline - primary route only
            polyline = formatRoutePolyline(currentRoute, sampleCount: 10)

            // JSON - all routes
            if alternateRoutes.count > 1 {
                json = "[\n"
                for (idx, route) in alternateRoutes.enumerated() {
                    json += formatRouteJSON(route, segmentIndex: idx + 1)
                    if idx < alternateRoutes.count - 1 {
                        json += ",\n"
                    }
                }
                json += "\n]"
            } else {
                json = formatRouteJSON(currentRoute, segmentIndex: nil)
            }

        } else {
            summary = "Mode: Single Point (no route)\nNo route data available."
        }

        let fullText = getRouteDebugInfo()

        return RouteDebugData(
            summary: summary,
            routeDetails: details,
            navigationSteps: steps,
            polylineData: polyline,
            rawJSON: json,
            fullText: fullText
        )
    }

    private func formatRouteBasicInfo(_ route: MKRoute) -> String {
        var info = ""
        info += "Route Name: \(route.name.isEmpty ? "(unnamed)" : route.name)\n"
        info += "Distance: \(String(format: "%.2f", route.distance / 1000)) km (\(String(format: "%.0f", route.distance)) m)\n"
        info += "Expected Travel Time: \(String(format: "%.1f", route.expectedTravelTime / 60)) min (\(String(format: "%.0f", route.expectedTravelTime)) s)\n"
        info += "Transport Type: \(transportTypeName(route.transportType)) (raw: \(route.transportType.rawValue))\n"

        if #available(macOS 13.0, *) {
            info += "Has Tolls: \(route.hasTolls ? "Yes" : "No")\n"
            info += "Has Highways: \(route.hasHighways ? "Yes" : "No")\n"
        }

        if !route.advisoryNotices.isEmpty {
            info += "\nAdvisory Notices (\(route.advisoryNotices.count)):\n"
            for (idx, notice) in route.advisoryNotices.enumerated() {
                info += "  \(idx + 1). \(notice)\n"
            }
        }

        info += "\nPolyline Points: \(route.polyline.pointCount)\n"
        let boundingRect = route.polyline.boundingMapRect
        let topLeft = MKMapPoint(x: boundingRect.minX, y: boundingRect.minY).coordinate
        let bottomRight = MKMapPoint(x: boundingRect.maxX, y: boundingRect.maxY).coordinate
        info += "Bounding Box:\n"
        info += "  Top-Left: (\(topLeft.latitude), \(topLeft.longitude))\n"
        info += "  Bottom-Right: (\(bottomRight.latitude), \(bottomRight.longitude))\n"

        return info
    }

    private func formatRouteSteps(_ route: MKRoute) -> String {
        guard !route.steps.isEmpty else {
            return "No navigation steps available"
        }

        var info = "Total Steps: \(route.steps.count)\n\n"
        for (stepIdx, step) in route.steps.enumerated() {
            info += "\(stepIdx + 1). "
            info += step.instructions.isEmpty ? "(No instruction)" : step.instructions
            info += "\n"
            info += "   Distance: \(String(format: "%.0f", step.distance)) m\n"
            info += "   Transport Type: \(transportTypeName(step.transportType))\n"
            if let notice = step.notice, !notice.isEmpty {
                info += "   Notice: \(notice)\n"
            }
            info += "   Polyline Points: \(step.polyline.pointCount)\n"
            if stepIdx < route.steps.count - 1 {
                info += "\n"
            }
        }
        return info
    }

    private func formatRoutePolyline(_ route: MKRoute, sampleCount: Int) -> String {
        guard route.polyline.pointCount > 0 else {
            return "No polyline data available"
        }

        var info = "Total Points: \(route.polyline.pointCount)\n\n"
        let buffer = UnsafeBufferPointer(start: route.polyline.points(), count: route.polyline.pointCount)
        let count = min(sampleCount, route.polyline.pointCount)

        info += "First \(count) points:\n"
        for i in 0..<count {
            let point = buffer[i]
            let coord = point.coordinate
            info += "[\(i)]: (\(coord.latitude), \(coord.longitude))\n"
        }

        if route.polyline.pointCount > count {
            info += "\n... and \(route.polyline.pointCount - count) more points"
        }

        return info
    }

    private func formatRouteJSON(_ route: MKRoute, segmentIndex: Int?) -> String {
        var json = "{\n"

        if let idx = segmentIndex {
            json += "  \"segment\": \(idx),\n"
        }

        json += "  \"name\": \"\(route.name)\",\n"
        json += "  \"distance\": \(route.distance),\n"
        json += "  \"expectedTravelTime\": \(route.expectedTravelTime),\n"
        json += "  \"transportType\": \(route.transportType.rawValue),\n"

        if #available(macOS 13.0, *) {
            json += "  \"hasTolls\": \(route.hasTolls),\n"
            json += "  \"hasHighways\": \(route.hasHighways),\n"
        }

        json += "  \"advisoryNotices\": [\n"
        for (idx, notice) in route.advisoryNotices.enumerated() {
            json += "    \"\(notice)\"\(idx < route.advisoryNotices.count - 1 ? "," : "")\n"
        }
        json += "  ],\n"

        json += "  \"polyline\": {\n"
        json += "    \"pointCount\": \(route.polyline.pointCount),\n"

        let boundingRect = route.polyline.boundingMapRect
        let topLeft = MKMapPoint(x: boundingRect.minX, y: boundingRect.minY).coordinate
        let bottomRight = MKMapPoint(x: boundingRect.maxX, y: boundingRect.maxY).coordinate

        json += "    \"boundingBox\": {\n"
        json += "      \"topLeft\": { \"latitude\": \(topLeft.latitude), \"longitude\": \(topLeft.longitude) },\n"
        json += "      \"bottomRight\": { \"latitude\": \(bottomRight.latitude), \"longitude\": \(bottomRight.longitude) }\n"
        json += "    }\n"
        json += "  },\n"

        json += "  \"steps\": [\n"
        for (idx, step) in route.steps.enumerated() {
            json += "    {\n"
            json += "      \"instructions\": \"\(step.instructions.replacingOccurrences(of: "\"", with: "\\\""))\",\n"
            json += "      \"distance\": \(step.distance),\n"
            json += "      \"transportType\": \(step.transportType.rawValue),\n"
            if let notice = step.notice {
                json += "      \"notice\": \"\(notice.replacingOccurrences(of: "\"", with: "\\\""))\",\n"
            }
            json += "      \"polylinePointCount\": \(step.polyline.pointCount)\n"
            json += "    }\(idx < route.steps.count - 1 ? "," : "")\n"
        }
        json += "  ]\n"

        json += "}\n"

        return json
    }

    public func getRouteDebugInfo() -> String {
        var info = "=== Apple Maps Route Debug Info ===\n\n"

        if pointsMode == .direction {
            info += "Mode: Direction (Multi-waypoint)\n"
            info += "Waypoints: \(waypoints.count)\n\n"

            for (idx, waypoint) in waypoints.enumerated() {
                info += "Waypoint \(idx + 1): (\(waypoint.coordinate.latitude), \(waypoint.coordinate.longitude))\n"
            }

            info += "\nRoute Segments: \(directionRoutes.count)\n\n"

            for (idx, route) in directionRoutes.enumerated() {
                info += "--- Segment \(idx + 1) ---\n"
                info += formatRouteDetails(route, detailed: true)
                info += "\n"
            }

            info += "Total Distance: \(String(format: "%.2f", directionRoutes.reduce(0) { $0 + $1.distance } / 1000)) km\n"
            info += "Total Expected Time: \(String(format: "%.1f", directionRoutes.reduce(0) { $0 + $1.expectedTravelTime } / 60)) min\n"

        } else if pointsMode == .two, let currentRoute = route {
            info += "Mode: Two Points (A to B)\n\n"
            info += formatRouteDetails(currentRoute, detailed: true)
        } else {
            info += "Mode: Single Point (no route)\n"
            info += "No route data available.\n"
        }

        return info
    }

    private func formatRouteDetails(_ route: MKRoute, detailed: Bool) -> String {
        var info = ""

        // Basic route information
        info += "Route Name: \(route.name.isEmpty ? "(unnamed)" : route.name)\n"
        info += "Distance: \(String(format: "%.2f", route.distance / 1000)) km (\(String(format: "%.0f", route.distance)) m)\n"
        info += "Expected Travel Time: \(String(format: "%.1f", route.expectedTravelTime / 60)) min (\(String(format: "%.0f", route.expectedTravelTime)) s)\n"
        info += "Transport Type: \(transportTypeName(route.transportType)) (raw: \(route.transportType.rawValue))\n"

        // iOS 16+ properties
        if #available(macOS 13.0, *) {
            info += "Has Tolls: \(route.hasTolls ? "Yes" : "No")\n"
            info += "Has Highways: \(route.hasHighways ? "Yes" : "No")\n"
        }

        // Advisory notices
        if !route.advisoryNotices.isEmpty {
            info += "\nAdvisory Notices (\(route.advisoryNotices.count)):\n"
            for (idx, notice) in route.advisoryNotices.enumerated() {
                info += "  \(idx + 1). \(notice)\n"
            }
        } else {
            info += "Advisory Notices: None\n"
        }

        // Polyline information
        info += "\nPolyline Points: \(route.polyline.pointCount)\n"
        info += "Polyline Bounding Box:\n"
        let boundingRect = route.polyline.boundingMapRect
        let topLeft = MKMapPoint(x: boundingRect.minX, y: boundingRect.minY).coordinate
        let bottomRight = MKMapPoint(x: boundingRect.maxX, y: boundingRect.maxY).coordinate
        info += "  Top-Left: (\(topLeft.latitude), \(topLeft.longitude))\n"
        info += "  Bottom-Right: (\(bottomRight.latitude), \(bottomRight.longitude))\n"

        // Navigation steps with full details
        if !route.steps.isEmpty {
            info += "\nNavigation Steps (\(route.steps.count)):\n"
            for (stepIdx, step) in route.steps.enumerated() {
                info += "  \(stepIdx + 1). "
                if step.instructions.isEmpty {
                    info += "(No instruction)\n"
                } else {
                    info += "\(step.instructions)\n"
                }
                info += "     Distance: \(String(format: "%.0f", step.distance)) m\n"
                info += "     Transport Type: \(transportTypeName(step.transportType))\n"
                if let notice = step.notice, !notice.isEmpty {
                    info += "     Notice: \(notice)\n"
                }
                info += "     Polyline Points: \(step.polyline.pointCount)\n"
            }
        } else {
            info += "\nNavigation Steps: None\n"
        }

        // Polyline sample
        if detailed {
            let sampleCount = min(pointsMode == .direction ? 5 : 10, route.polyline.pointCount)
            info += "\nPolyline Sample (first \(sampleCount) points):\n"
            let buffer = UnsafeBufferPointer(start: route.polyline.points(), count: route.polyline.pointCount)
            for i in 0..<sampleCount {
                let point = buffer[i]
                let coord = point.coordinate
                info += "  [\(i)]: (\(coord.latitude), \(coord.longitude))\n"
            }
        }

        return info
    }

    private func transportTypeName(_ type: MKDirectionsTransportType) -> String {
        switch type {
        case .automobile:
            return "Automobile"
        case .walking:
            return "Walking"
        case .transit:
            return "Transit"
        case .any:
            return "Any"
        default:
            return "Unknown"
        }
    }

    enum SimulatorFetchError: Error, CustomStringConvertible {
        case simctlFailed
        case failedToReadOutput
        case noBootedSimulators
        case noMatchingSimulators(name: String)
        case noMatchingUDID(udid: UUID)

        var description: String {
            switch self {
            case .simctlFailed:
                return "Running `simctl list` failed"
            case .failedToReadOutput:
                return "Failed to read output from simctl"
            case .noBootedSimulators:
                return "No simulators are currently booted"
            case .noMatchingSimulators(let name):
                return "No booted simulators named '\(name)'"
            case .noMatchingUDID(let udid):
                return "No booted simulators with udid: \(udid.uuidString)"
            }
        }
    }
}

extension CLLocation {

    static func distance(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> CLLocationDistance {
        let from = CLLocation(latitude: from.latitude, longitude: from.longitude)
        let to = CLLocation(latitude: to.latitude, longitude: to.longitude)
        return from.distance(from: to)
    }
}

extension CLLocationCoordinate2D {

    /// Calculates geodesic bearing from this coordinate to another, in degrees (0-360).
    func bearing(to destination: CLLocationCoordinate2D) -> Double {
        let lat1 = self.latitude * .pi / 180.0
        let lat2 = destination.latitude * .pi / 180.0
        let dLon = (destination.longitude - self.longitude) * .pi / 180.0

        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let radiansBearing = atan2(y, x)

        return (radiansBearing * 180.0 / .pi + 360.0).truncatingRemainder(dividingBy: 360.0)
    }
}

private enum Constants {

    static let defaultsSavedLocationsPathKey = "saved_locations"
    static let defaultsXcodePathKey = "xcode_path"
    static let defaultsRoutePresetsKey = "route_presets"
}

// MARK: - Route Debug Data

public struct RouteDebugData {
    public let summary: String
    public let routeDetails: String
    public let navigationSteps: String
    public let polylineData: String
    public let rawJSON: String
    public let fullText: String

    public init(summary: String, routeDetails: String, navigationSteps: String, polylineData: String, rawJSON: String, fullText: String) {
        self.summary = summary
        self.routeDetails = routeDetails
        self.navigationSteps = navigationSteps
        self.polylineData = polylineData
        self.rawJSON = rawJSON
        self.fullText = fullText
    }
}
