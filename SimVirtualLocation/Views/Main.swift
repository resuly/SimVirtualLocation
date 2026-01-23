//
//  Main.swift
//  SimVirtualLocation
//
//  Created by Sergey Shirnin on 20.02.2022.
//

import SwiftUI
import UniformTypeIdentifiers

@main
struct SimVirtualLocationApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            if let controller = appState.locationController {
                ContentView(mapView: appState.mapView, locationController: controller)
            } else {
                Text("Initializing...")
                    .onAppear {
                        appState.initialize()
                    }
            }
        }
        .commands {
            // Remove default Edit menu items
            CommandGroup(replacing: .undoRedo) { }
            CommandGroup(replacing: .pasteboard) { }
            CommandGroup(replacing: .textEditing) { }

            // Add custom Locations menu
            CommandMenu("Locations") {
                Button("Import Locations...") {
                    importLocations()
                }
                .keyboardShortcut("i", modifiers: [.command])

                Button("Export Locations...") {
                    exportLocations()
                }
                .keyboardShortcut("e", modifiers: [.command])
                .disabled(appState.locationController?.savedLocations.isEmpty ?? true)
            }

            // Add Debug menu
            CommandMenu("Debug") {
                Button("View Apple Maps Route Info") {
                    appState.openDebugWindow()
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            }
        }
    }

    private func importLocations() {
        let panel = NSOpenPanel()
        panel.title = "Import Locations"
        panel.message = "Select a JSON file containing saved locations"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }

            do {
                let data = try Data(contentsOf: url)
                appState.locationController?.importLocations(from: data)
            } catch {
                appState.locationController?.showAlert("Failed to import: \(error.localizedDescription)")
            }
        }
    }

    private func exportLocations() {
        guard let controller = appState.locationController,
              !controller.savedLocations.isEmpty else { return }

        let panel = NSSavePanel()
        panel.title = "Export Locations"
        panel.message = "Save your locations to a JSON file"
        panel.nameFieldStringValue = "locations.json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }

            do {
                let data = try JSONEncoder().encode(controller.savedLocations)
                try data.write(to: url)
            } catch {
                controller.showAlert("Failed to export: \(error.localizedDescription)")
            }
        }
    }

}

// MARK: - AppState

class AppState: ObservableObject {
    let mapView: MapView
    @Published var locationController: LocationController?

    init() {
        self.mapView = MapView()
    }

    func initialize() {
        if locationController == nil {
            locationController = LocationController(mapView: mapView)
        }
    }

    func openDebugWindow() {
        guard let controller = locationController else { return }
        let debugData = controller.getRouteDebugData()

        // Use NSAlert as a temporary solution until RouteDebugWindow is added to project
        let alert = NSAlert()
        alert.messageText = "Apple Maps Route Info"
        alert.informativeText = debugData.summary + "\n\nUse menu to copy full details."
        alert.alertStyle = .informational

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 650, height: 400))
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.borderType = .noBorder

        let textView = NSTextView(frame: scrollView.bounds)
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = NSFont.systemFont(ofSize: 11)

        // Build full text with sections
        var fullText = "=== SUMMARY ===\n\n\(debugData.summary)\n\n"
        if !debugData.routeDetails.isEmpty {
            fullText += "=== ROUTE DETAILS ===\n\n\(debugData.routeDetails)\n\n"
        }
        if !debugData.navigationSteps.isEmpty {
            fullText += "=== NAVIGATION STEPS ===\n\n\(debugData.navigationSteps)\n\n"
        }
        if !debugData.polylineData.isEmpty {
            fullText += "=== POLYLINE DATA ===\n\n\(debugData.polylineData)\n\n"
        }
        if !debugData.rawJSON.isEmpty {
            fullText += "=== RAW JSON ===\n\n\(debugData.rawJSON)"
        }

        textView.string = fullText
        scrollView.documentView = textView

        alert.accessoryView = scrollView
        alert.addButton(withTitle: "Copy All")
        alert.addButton(withTitle: "Close")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(debugData.fullText, forType: .string)
        }
    }
}
