//
//  Echo_WidgetBundle.swift
//  Echo Widget
//
//  Created by Dan Fakkeldy on 2026-05-02.
//

import WidgetKit
import SwiftUI

@main
struct Echo_WidgetBundle: WidgetBundle {
    var body: some Widget {
        Echo_Widget()
        #if !os(watchOS)
        Echo_WidgetControl()
        #endif
    }
}
