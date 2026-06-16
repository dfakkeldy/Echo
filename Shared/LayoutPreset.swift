// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

public struct WatchPreset: Codable, Identifiable, Hashable {
    public let id: UUID
    public var name: String
    public var page1: [WatchAction]
    public var page2: [WatchAction]
    public var page3: [WatchAction]?
    public var page4: [WatchAction]?
    public var page5: [WatchAction]?

    public init(id: UUID = UUID(), name: String, page1: [WatchAction], page2: [WatchAction], page3: [WatchAction]? = nil, page4: [WatchAction]? = nil, page5: [WatchAction]? = nil) {
        self.id = id
        self.name = name
        self.page1 = page1
        self.page2 = page2
        self.page3 = page3
        self.page4 = page4
        self.page5 = page5
    }
}

public struct PhonePreset: Codable, Identifiable, Hashable {
    public let id: UUID
    public var name: String
    public var slots: [WatchAction]
    public var longPressSlots: [WatchAction]?

    public init(id: UUID = UUID(), name: String, slots: [WatchAction], longPressSlots: [WatchAction]? = nil) {
        self.id = id
        self.name = name
        self.slots = slots
        self.longPressSlots = longPressSlots
    }
}
