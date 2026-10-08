//
//  CursorSection.swift
//  SlackowWall
//

import DefaultCodable
import SwiftUI

extension Preferences {
    @DefaultCodable
    struct CursorSection: Codable, Hashable {
        var style: CursorStyle = .system
        var size: Double = 24
        var crosshairColor: CodableColor = .white
        var crosshairThickness: Double = 2
        var customImage: URL? = nil
        var customImageHotspot: CursorHotspot = .center

        var trailEnabled: Bool = false
        var trailColor: CodableColor = .init(red: 0.3, green: 0.7, blue: 1, alpha: 1)
        var trailWidth: Double = 6
        var trailLength: Double = 0.25

        /// The overlay window only needs to exist if it has something to draw.
        var overlayNeeded: Bool {
            trailEnabled || style == .crosshair || (style == .custom && customImage != nil)
        }

        init() {}
    }
}

enum CursorStyle: String, SettingsOption {
    case system = "Default"
    case crosshair = "Crosshair"
    case custom = "Custom Image"

    var id: Self { self }
    var label: String { rawValue }
}

enum CursorHotspot: String, SettingsOption {
    case center = "Center"
    case topLeft = "Top Left"

    var id: Self { self }
    var label: String { rawValue }
}

/// A `Color` that can be stored in a profile's JSON.
struct CodableColor: Codable, Hashable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    static let white = CodableColor(red: 1, green: 1, blue: 1, alpha: 1)

    init(red: Double, green: Double, blue: Double, alpha: Double) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .white
        self.init(
            red: ns.redComponent, green: ns.greenComponent, blue: ns.blueComponent,
            alpha: ns.alphaComponent)
    }

    var color: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }

    var cgColor: CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}
