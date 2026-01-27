//
//  Device.swift
//  SimVirtualLocation
//
//  Created by Sergey Shirnin on 21.02.2022.
//

import Foundation

struct Device: Hashable, Identifiable, Decodable {

    private enum CodingKeys: String, CodingKey {
        case id = "Identifier"
        case name = "DeviceName"
        case version = "ProductVersion"
    }

    let id: String
    let name: String
    let version: String

    /// Check if device requires RSD (Remote Service Discovery) for iOS 17+
    var requiresRSD: Bool {
        // Parse version string (e.g., "17.0", "16.5", "18.2")
        if let majorVersion = version.split(separator: ".").first,
           let versionNumber = Int(majorVersion) {
            return versionNumber >= 17
        }
        return false
    }

    var displayName: String {
        "\(name) (iOS \(version))"
    }
}

struct RSDTunnel: Hashable, Identifiable {
    let id: String // Device UDID
    let deviceName: String
    let address: String
    let port: String

    var displayName: String {
        "\(deviceName) (\(address):\(port))"
    }
}
