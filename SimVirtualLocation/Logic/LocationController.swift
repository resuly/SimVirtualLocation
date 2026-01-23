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

    @Published var timeScale: Double = 1.5 {
        didSet { runner.timeDelay = timeScale }
    }

    @Published var logs: [LogEntry] = []

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

    private var tracks: [Track] = []
    private var currentTrackIndex: Int = 0
    private var lastTrackLocation: CLLocationCoordinate2D?
    private var tracksTimes: [Track: Double] = [:]

    private var timer: Timer?

    @Published var savedLocations: [Location] = []

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
        }
    }

    // MARK: - Public

    @MainActor
    func refreshDevices() async {
        bootedSimulators = (try? getBootedSimulators()) ?? []
        selectedSimulator = bootedSimulators.first?.id ?? ""

        connectedDevices = (try? await getConnectedDevices()) ?? []
        selectedDevice = connectedDevices.first?.id ?? ""
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

        let directions = MKDirections(request: directionRequest)

        directions.calculate { (response, error) -> Void in
            guard let response = response else {
                if let error = error {
                    self.showAlert(error.localizedDescription)
                }
                return
            }

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
        timer?.invalidate()
        timer = nil
        runner.stop()
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
            marker.isDraggable = true
            marker.dragState = .none
            return marker
        }

        return nil
    }

    // Handle waypoint drag events
    func mapView(_ mapView: MKMapView, annotationView view: MKAnnotationView, didChange newState: MKAnnotationView.DragState, fromOldState oldState: MKAnnotationView.DragState) {
        guard let annotation = view.annotation as? MKPointAnnotation else { return }
        guard waypoints.contains(where: { $0 === annotation }) else { return }

        // When drag ends, update the waypoint and regenerate route
        if newState == .ending {
            // Find the waypoint index
            if let index = waypoints.firstIndex(where: { $0 === annotation }) {
                // Update waypoint coordinate
                waypoints[index].coordinate = annotation.coordinate

                // Regenerate route if we have at least 2 waypoints
                if waypoints.count >= 2 {
                    autoGenerateRoute()
                }
            }
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
            self.alertText = text
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

    private func invalidateState() {
        timer?.invalidate()
        timer = nil
        isSimulating = true
        lastTrackLocation = nil
        currentTrackIndex = 0
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
            case .moveTo(let to, let from, let speed):
                self.lastTrackLocation = to
                self.run(location: to)
                self.currentSimulationAnnotation.coordinate = to
                print("move to - distance=\(CLLocation.distance(from: from, to: to)), speed=\(speed)")

            case .finishTo(let to, let from, let speed):
                self.lastTrackLocation = nil
                self.currentTrackIndex += 1
                self.run(location: to)
                self.currentSimulationAnnotation.coordinate = to
                print("finish to - distance=\(CLLocation.distance(from: from, to: to)), speed=\(speed)")
        }

        self.tracksTimes[track] = (self.tracksTimes[track] ?? 0) + self.timeScale
        self.mapView.mkMapView.addAnnotation(self.currentSimulationAnnotation)
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

    private func run(location: CLLocationCoordinate2D) {
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
            if useRSD {
                Task {
                    try await runner.runOnNewIos(
                        location: location,
                        RSDAddress: RSDAddress,
                        RSDPort: RSDPort,
                        showAlert: showAlert
                    )
                }

            } else {
                Task {
                    try await runner.runOnIos(
                        location: location,
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

        if let route = route {
            mapView.mkMapView.removeOverlay(route.polyline)
        }

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
        var allRoutes: [MKRoute] = []
        let group = DispatchGroup()

        for i in 0..<(waypoints.count - 1) {
            group.enter()

            let start = MKPlacemark(coordinate: waypoints[i].coordinate)
            let end = MKPlacemark(coordinate: waypoints[i + 1].coordinate)

            let request = MKDirections.Request()
            request.source = MKMapItem(placemark: start)
            request.destination = MKMapItem(placemark: end)
            request.transportType = .automobile

            let directions = MKDirections(request: request)
            directions.calculate { [weak self] response, error in
                defer { group.leave() }

                if let route = response?.routes.first {
                    allRoutes.append(route)
                } else if let error = error {
                    self?.log("Route segment \(i+1)→\(i+2) error: \(error.localizedDescription)")
                }
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self = self else { return }

            // Save routes for simulation
            self.directionRoutes = allRoutes

            // Add all route segments to map
            for route in allRoutes {
                self.mapView.mkMapView.addOverlay(route.polyline, level: .aboveRoads)
            }

            // Calculate total distance
            let totalDistance = allRoutes.reduce(0.0) { $0 + $1.distance }
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

        mapView.mkMapView.removeAnnotation(currentSimulationAnnotation)
        currentSimulationAnnotation.coordinate = tracks[0].startPoint.coordinate
        currentSimulationAnnotation.title = "Current location"
        mapView.mkMapView.addAnnotation(currentSimulationAnnotation)

        timer = Timer.scheduledTimer(withTimeInterval: timeScale, repeats: true) { [unowned self] timer in
            self.performMovement()
        }

        log("Started Direction mode simulation with \(tracks.count) track segments")
    }
}

private extension LocationController {

    @MainActor
    private func getConnectedDevices() async throws -> [Device] {
        let task = try await runner.taskForIOS(args: ["usbmux", "list", "--no-color", "-u"], showAlert: showAlert)

        log("getConnectedDevices: \(task.executableURL!.absoluteString) \(task.arguments!.joined(separator: " "))")

        let pipe = Pipe()
        task.standardOutput = pipe

        try task.run()
        task.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        pipe.fileHandleForReading.closeFile()

        if task.terminationStatus != 0 {
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

private enum Constants {

    static let defaultsSavedLocationsPathKey = "saved_locations"
    static let defaultsXcodePathKey = "xcode_path"
}
