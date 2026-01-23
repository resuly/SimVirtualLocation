//
//  MapView.swift
//  SimVirtualLocation
//
//  Created by Sergey Shirnin on 20.02.2022.
//

import MapKit
import SwiftUI

struct MapView: NSViewRepresentable {

    typealias NSViewType = MKMapView

    var mkMapView: MKMapView { viewHolder.mkMapView }

    let viewHolder = MapViewHolder()

    func makeNSView(context: Context) -> MKMapView {
        return viewHolder.makeNSView()
    }

    func updateNSView(_ nsView: MKMapView, context: Context) {}
}

class MapViewHolder {
    private let mapView = MKMapView()
    var mkMapView: MKMapView { mapView }

    var clickAction: (NSClickGestureRecognizer) -> Void = {_ in }
    var doubleClickAction: (NSClickGestureRecognizer) -> Void = {_ in }

    func makeNSView() -> MKMapView {
        // Single click gesture
        let clickGesture = NSClickGestureRecognizer(
            target: self,
            action: #selector(self.handleClickGesture(_:)))
        clickGesture.numberOfClicksRequired = 1
        clickGesture.delaysPrimaryMouseButtonEvents = true  // Allow drag gestures to take priority

        // Double click gesture
        let doubleClickGesture = NSClickGestureRecognizer(
            target: self,
            action: #selector(self.handleDoubleClickGesture(_:)))
        doubleClickGesture.numberOfClicksRequired = 2

        mapView.addGestureRecognizer(clickGesture)
        mapView.addGestureRecognizer(doubleClickGesture)

        return mapView
    }

    @objc private func handleClickGesture(_ sender: NSClickGestureRecognizer) {
        clickAction(sender)
    }

    @objc private func handleDoubleClickGesture(_ sender: NSClickGestureRecognizer) {
        doubleClickAction(sender)
    }
}
