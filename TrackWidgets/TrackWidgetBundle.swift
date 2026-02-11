//
//  TrackWidgetBundle.swift
//  TrackWidgets
//
//  Entry point for the Widget Extension.
//  Registers the "Next Train" widget and the Live Activity.
//

import SwiftUI
import WidgetKit

@main
struct TrackWidgetBundle: WidgetBundle {
    var body: some Widget {
        TrackWidget()
        TrackWidgetLiveActivity()
    }
}
