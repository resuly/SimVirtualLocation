//
//  RouteDebugWindow.swift
//  SimVirtualLocation
//
//  Created by Claude Code
//

import SwiftUI
import MapKit

struct RouteDebugWindow: View {
    let debugData: RouteDebugData

    @State private var expandedSections: Set<String> = []
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "map.fill")
                    .foregroundColor(.blue)
                Text("Apple Maps Route Debug Info")
                    .font(.headline)
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.gray)
                        .imageScale(.large)
                }
                .buttonStyle(.plain)
            }
            .padding()
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Summary Section
                    DebugSection(
                        title: "Summary",
                        icon: "info.circle.fill",
                        color: .blue,
                        content: debugData.summary,
                        isExpanded: expandedSections.contains("summary")
                    ) {
                        toggleSection("summary")
                    }

                    // Route Details Section
                    if !debugData.routeDetails.isEmpty {
                        DebugSection(
                            title: "Route Details",
                            icon: "road.lanes",
                            color: .green,
                            content: debugData.routeDetails,
                            isExpanded: expandedSections.contains("details")
                        ) {
                            toggleSection("details")
                        }
                    }

                    // Navigation Steps Section
                    if !debugData.navigationSteps.isEmpty {
                        DebugSection(
                            title: "Navigation Steps",
                            icon: "arrow.triangle.turn.up.right.circle.fill",
                            color: .orange,
                            content: debugData.navigationSteps,
                            isExpanded: expandedSections.contains("steps")
                        ) {
                            toggleSection("steps")
                        }
                    }

                    // Polyline Data Section
                    if !debugData.polylineData.isEmpty {
                        DebugSection(
                            title: "Polyline Data",
                            icon: "point.3.connected.trianglepath.dotted",
                            color: .purple,
                            content: debugData.polylineData,
                            isExpanded: expandedSections.contains("polyline")
                        ) {
                            toggleSection("polyline")
                        }
                    }

                    // Raw JSON Section
                    if !debugData.rawJSON.isEmpty {
                        DebugSection(
                            title: "Raw Data (JSON)",
                            icon: "doc.text.fill",
                            color: .gray,
                            content: debugData.rawJSON,
                            isExpanded: expandedSections.contains("json"),
                            isMonospace: true
                        ) {
                            toggleSection("json")
                        }
                    }
                }
                .padding()
            }

            Divider()

            // Footer buttons
            HStack {
                Button("Copy All") {
                    copyToClipboard(debugData.fullText)
                }
                .keyboardShortcut("c", modifiers: [.command])

                Spacer()

                Button("Close") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding()
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(width: 700, height: 600)
        .onAppear {
            // Expand summary by default
            expandedSections.insert("summary")
        }
    }

    private func toggleSection(_ id: String) {
        if expandedSections.contains(id) {
            expandedSections.remove(id)
        } else {
            expandedSections.insert(id)
        }
    }

    private func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

struct DebugSection: View {
    let title: String
    let icon: String
    let color: Color
    let content: String
    let isExpanded: Bool
    var isMonospace: Bool = false
    let onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Section header
            Button(action: onToggle) {
                HStack {
                    Image(systemName: icon)
                        .foregroundColor(color)
                        .imageScale(.medium)

                    Text(title)
                        .font(.headline)
                        .foregroundColor(.primary)

                    Spacer()

                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .foregroundColor(.secondary)
                        .imageScale(.small)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                // Section content
                VStack(alignment: .leading, spacing: 8) {
                    ScrollView(.horizontal, showsIndicators: true) {
                        Text(content)
                            .font(isMonospace ? .system(.body, design: .monospaced) : .body)
                            .textSelection(.enabled)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .background(Color(nsColor: .textBackgroundColor))
                    .cornerRadius(6)

                    // Copy button for this section
                    Button(action: {
                        copyToClipboard(content)
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "doc.on.doc")
                                .imageScale(.small)
                            Text("Copy")
                                .font(.caption)
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.blue)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
    }

    private func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

#Preview {
    RouteDebugWindow(debugData: RouteDebugData(
        summary: "Mode: Two Points\nDistance: 5.2 km\nTime: 8 minutes",
        routeDetails: "Route Name: Main Street Route\nTransport: Automobile\nHas Tolls: No",
        navigationSteps: "1. Head north\n2. Turn left\n3. Arrive at destination",
        polylineData: "[0]: (37.7749, -122.4194)\n[1]: (37.7750, -122.4195)",
        rawJSON: "{\n  \"distance\": 5200,\n  \"time\": 480\n}",
        fullText: "Full debug text..."
    ))
}
