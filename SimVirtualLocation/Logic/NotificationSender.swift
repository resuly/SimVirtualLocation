import Foundation
import CoreLocation

private let kNotificationName = "com.apple.iphonesimulator.simulateLocation"

enum NotificationSender {
    static func postNotification(
        for coordinate: CLLocationCoordinate2D,
        to simulators: [String],
        speed: Double? = nil,
        course: Double? = nil,
        altitude: Double? = nil
    ) {
        var userInfo: [AnyHashable: Any] = [
            "simulateLocationLatitude": coordinate.latitude,
            "simulateLocationLongitude": coordinate.longitude,
            "simulateLocationDevices": simulators,
        ]

        // Experimental: undocumented keys that may be picked up by the simulator
        if let speed = speed {
            userInfo["simulateLocationSpeed"] = speed
        }
        if let course = course {
            userInfo["simulateLocationCourse"] = course
        }
        if let altitude = altitude {
            userInfo["simulateLocationAltitude"] = altitude
        }

        let notification = Notification(name: Notification.Name(rawValue: kNotificationName), object: nil,
                                        userInfo: userInfo)

        DistributedNotificationCenter.default().post(notification)
    }
}
