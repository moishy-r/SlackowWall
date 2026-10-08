//
//  RemapSection.swift
//  SlackowWall
//

import DefaultCodable
import SwiftUI

extension Preferences {
    @DefaultCodable
    struct RemapSection: Codable, Hashable {
        var enabled: Bool = false
        var onlyInMinecraft: Bool = true
        var remaps: [KeyRemap] = []

        init() {}
    }
}

/// A one-to-one key remap: pressing `from` sends `to` instead.
struct KeyRemap: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var from: KeyCode? = nil
    var to: KeyCode? = nil
    var enabled: Bool = true

    var isValid: Bool {
        enabled && from != nil && to != nil && from != to
    }
}
