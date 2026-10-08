//
//  CursorSettings.swift
//  SlackowWall
//

import SwiftUI

struct CursorSettings: View {
    @AppSettings(\.cursor) private var settings

    var body: some View {
        SettingsPageView(title: "Custom Cursor") {
            SettingsLabel(
                title: "Cursor",
                description:
                    "Replaces your mouse cursor everywhere while SlackowWall is open. It's hidden automatically while Minecraft has captured the mouse during gameplay."
            )

            SettingsCardView {
                VStack {
                    SettingsPickerView(
                        title: "Style", width: 140, selection: $settings.style)

                    if settings.style != .system {
                        Divider()
                            .padding(.bottom, 4)

                        SettingsSliderView(
                            title: "Size (\(Int(settings.size)))", leftIcon: "smallcircle.filled.circle",
                            rightIcon: "largecircle.fill.circle", value: $settings.size,
                            range: 8...96, step: 2)
                    }

                    if settings.style == .crosshair {
                        Divider()
                            .padding(.bottom, 4)

                        SettingsSliderView(
                            title: "Thickness (\(Int(settings.crosshairThickness)))",
                            leftIcon: "minus", rightIcon: "equal",
                            value: $settings.crosshairThickness, range: 1...8, step: 1)

                        Divider()

                        colorRow(title: "Crosshair Color", color: $settings.crosshairColor)
                    }

                    if settings.style == .custom {
                        Divider()

                        SettingsButtonView(
                            title: "Cursor Image",
                            description: settings.customImage == nil
                                ? "Choose a PNG or other image to use as your cursor."
                                : settings.customImage?.lastPathComponent,
                            action: CursorOverlayManager.shared.selectCustomImage
                        ) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 5)
                                    .stroke(.gray)

                                if let url = settings.customImage, let image = NSImage(contentsOf: url) {
                                    Image(nsImage: image)
                                        .resizable()
                                        .scaledToFit()
                                        .padding(4)
                                } else {
                                    Image(systemName: "photo.badge.plus")
                                }
                            }
                            .frame(width: 42, height: 42)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)

                        Divider()

                        SettingsPickerView(
                            title: "Click Point",
                            description: "Which part of the image lines up with the mouse position.",
                            width: 140, selection: $settings.customImageHotspot)
                    }
                }
            }

            SettingsLabel(title: "Trail")
                .padding(.top, 5)

            SettingsCardView {
                VStack {
                    SettingsToggleView(
                        title: "Cursor Trail",
                        description: "Draw a fading trail behind the mouse.",
                        option: $settings.trailEnabled)

                    if settings.trailEnabled {
                        Divider()

                        colorRow(title: "Trail Color", color: $settings.trailColor)

                        Divider()
                            .padding(.bottom, 4)

                        SettingsSliderView(
                            title: "Width (\(Int(settings.trailWidth)))", leftIcon: "scribble",
                            rightIcon: "scribble.variable", value: $settings.trailWidth,
                            range: 1...20, step: 1)

                        Divider()
                            .padding(.bottom, 4)

                        SettingsSliderView(
                            title: "Length (\(String(format: "%.2f", settings.trailLength))s)",
                            leftIcon: "hare", rightIcon: "tortoise",
                            value: $settings.trailLength, range: 0.05...1, step: 0.05)
                    }
                }
            }
        }
    }

    private func colorRow(title: String, color: Binding<CodableColor>) -> some View {
        HStack {
            Text(title)
                .frame(maxWidth: .infinity, alignment: .leading)

            ColorPicker(
                "",
                selection: Binding(
                    get: { color.wrappedValue.color },
                    set: { color.wrappedValue = CodableColor($0) }),
                supportsOpacity: true
            )
            .labelsHidden()
        }
    }
}

#Preview {
    CursorSettings()
        .frame(width: 500, height: 600)
}
