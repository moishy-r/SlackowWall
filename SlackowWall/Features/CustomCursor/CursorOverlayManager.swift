//
//  CursorOverlayManager.swift
//  SlackowWall
//

import AppKit
import Combine
import QuartzCore
import UniformTypeIdentifiers

/// Draws a custom cursor (crosshair or image) and an optional trail in a
/// transparent, click-through window above everything else on every screen.
final class CursorOverlayManager {
    static let shared = CursorOverlayManager()

    private var settings = Preferences.CursorSection()
    private var settingsObserver: AnyCancellable?
    private var screenObserver: NSObjectProtocol?
    private var mouseMonitors: [Any] = []
    private var timer: Timer?

    private var overlays: [OverlayWindow] = []
    private var customImage: NSImage?

    private var trail: [(point: CGPoint, time: TimeInterval)] = []
    private var lastLocation: CGPoint = .zero
    private var needsRedraw = true

    /// True while a game has grabbed the mouse (cursor frozen but the mouse is moving),
    /// e.g. Minecraft gameplay. Nothing is drawn then, so it doesn't sit on screen.
    private var mouseCaptured = false
    /// Consecutive mouse-move events that didn't move the cursor.
    private var stuckMoveEvents = 0
    private var lastEventLocation: CGPoint?
    private var activationObserver: NSObjectProtocol?
    private var systemCursorHidden = false

    private init() {}

    var cursorsFolder: URL {
        SlackowWallApp.appPath.appending(path: "Cursors/")
    }

    func start() {
        settingsObserver = Settings.shared.$preferences
            .map(\.cursor)
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.apply($0) }

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, !overlays.isEmpty else { return }
            rebuildWindows()
        }
    }

    /// Lets the user pick an image and copies it into SlackowWall's support folder.
    func selectCustomImage() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.png, .jpeg, .gif, .tiff, .heic]

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: cursorsFolder, withIntermediateDirectories: true)
        let destination = cursorsFolder.appending(
            path: "\(UUID().uuidString).\(url.pathExtension)")
        do {
            try fileManager.copyItem(at: url, to: destination)
            if let old = Settings[\.cursor].customImage,
                old.path.hasPrefix(cursorsFolder.path)
            {
                try? fileManager.removeItem(at: old)
            }
            Settings[\.cursor].customImage = destination
            Settings[\.cursor].style = .custom
        } catch {
            LogManager.shared.appendLog("Custom Cursor: failed to copy image:", error)
        }
    }

    // MARK: - Lifecycle

    private func apply(_ section: Preferences.CursorSection) {
        settings = section
        customImage = section.customImage.flatMap { NSImage(contentsOf: $0) }

        guard section.overlayNeeded else {
            teardown()
            return
        }

        if overlays.isEmpty {
            rebuildWindows()
            startTracking()
        }
        for overlay in overlays {
            overlay.configure(settings: section, image: customImage)
        }
        needsRedraw = true
        tick()
    }

    private func rebuildWindows() {
        overlays.forEach { $0.close() }
        overlays = NSScreen.screens.map { OverlayWindow(screen: $0) }
        for overlay in overlays {
            overlay.configure(settings: settings, image: customImage)
            overlay.orderFrontRegardless()
        }
        needsRedraw = true
    }

    private func startTracking() {
        let handler: (NSEvent) -> Void = { [weak self] event in
            self?.handleMouseMove(event)
        }
        let mask: NSEvent.EventTypeMask = [
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
        ]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handler) {
            mouseMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(
            matching: mask,
            handler: {
                handler($0)
                return $0
            })
        {
            mouseMonitors.append(local)
        }

        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        // Switching apps can make macOS show the cursor again; hide it once more.
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, systemCursorHidden else { return }
            CGDisplayShowCursor(CGMainDisplayID())
            CGDisplayHideCursor(CGMainDisplayID())
        }
    }

    /// Detects a game grabbing the mouse: it keeps sending movement while the cursor
    /// position stays frozen. Uses each event's own position, so a mouse that simply
    /// stopped moving never counts, and pushing against a screen edge is ignored.
    private func handleMouseMove(_ event: NSEvent) {
        guard event.deltaX != 0 || event.deltaY != 0 else { return }
        let location =
            event.window.map { $0.convertPoint(toScreen: event.locationInWindow) }
            ?? event.locationInWindow
        defer { lastEventLocation = location }

        if location == lastEventLocation && !Self.isAtScreenEdge(location) {
            stuckMoveEvents += 1
            if stuckMoveEvents >= 4 && !mouseCaptured {
                mouseCaptured = true
                needsRedraw = true
            }
        } else {
            stuckMoveEvents = 0
            if mouseCaptured {
                mouseCaptured = false
                needsRedraw = true
            }
        }
    }

    private static func isAtScreenEdge(_ point: CGPoint) -> Bool {
        guard let frame = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) })?.frame
        else { return true }
        return point.x <= frame.minX + 1 || point.x >= frame.maxX - 2
            || point.y <= frame.minY + 1 || point.y >= frame.maxY - 2
    }

    private func teardown() {
        timer?.invalidate()
        timer = nil
        mouseMonitors.forEach(NSEvent.removeMonitor)
        mouseMonitors = []
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        activationObserver = nil
        mouseCaptured = false
        stuckMoveEvents = 0
        overlays.forEach { $0.close() }
        overlays = []
        trail = []
        setSystemCursorHidden(false)
    }

    // MARK: - Frame updates

    private func tick() {
        guard !overlays.isEmpty else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let location = NSEvent.mouseLocation
        let moved = location != lastLocation
        if moved && mouseCaptured {
            // The game let go of the mouse (e.g. opened a menu and re-centered it).
            mouseCaptured = false
            stuckMoveEvents = 0
        }
        lastLocation = location

        if settings.trailEnabled && !mouseCaptured {
            if moved || trail.isEmpty {
                trail.append((location, now))
                needsRedraw = true
            }
            let cutoff = now - settings.trailLength
            if let firstFresh = trail.firstIndex(where: { $0.time >= cutoff }), firstFresh > 0 {
                trail.removeFirst(firstFresh)
                needsRedraw = true
            } else if trail.count > 1, trail.allSatisfy({ $0.time < cutoff }) {
                trail = [trail[trail.count - 1]]
                needsRedraw = true
            }
        } else if !trail.isEmpty {
            trail = []
            needsRedraw = true
        }

        let drawsCursor =
            settings.style != .system && !mouseCaptured
            && (settings.style != .custom || customImage != nil)
        setSystemCursorHidden(drawsCursor)

        guard needsRedraw || moved else { return }
        needsRedraw = false

        let points = trail.map(\.point)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for overlay in overlays {
            overlay.update(location: location, showCursor: drawsCursor, trail: points)
        }
        CATransaction.commit()
    }

    // MARK: - System cursor

    /// Hides the real cursor even while another app (Minecraft) is in front.
    /// Normally macOS only lets the frontmost app hide the cursor, so this uses the
    /// "SetsCursorInBackground" connection property that cursor utilities rely on.
    private func setSystemCursorHidden(_ hidden: Bool) {
        guard hidden != systemCursorHidden else { return }
        systemCursorHidden = hidden
        if hidden {
            _ = Self.backgroundCursorControlEnabled
            CGDisplayHideCursor(CGMainDisplayID())
        } else {
            CGDisplayShowCursor(CGMainDisplayID())
        }
    }

    private static let backgroundCursorControlEnabled: Bool = {
        typealias DefaultConnection = @convention(c) () -> Int32
        typealias SetProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32

        guard let handle = dlopen(nil, RTLD_NOW),
            let connSym = dlsym(handle, "_CGSDefaultConnection"),
            let setSym = dlsym(handle, "CGSSetConnectionProperty")
        else {
            LogManager.shared.appendLog("Custom Cursor: background cursor hiding unavailable")
            return false
        }
        let connection = unsafeBitCast(connSym, to: DefaultConnection.self)()
        let setProperty = unsafeBitCast(setSym, to: SetProperty.self)
        return setProperty(
            connection, connection, "SetsCursorInBackground" as CFString, kCFBooleanTrue) == 0
    }()
}

// MARK: - Overlay window

private final class OverlayWindow: NSWindow {
    private let cursorLayer = CALayer()
    private let crosshairLayer = CAShapeLayer()
    private let trailLayer = TrailLayer()

    private var settings = Preferences.CursorSection()
    private var cursorSize: CGSize = .zero
    private var hotspot: CGPoint = .zero

    init(screen: NSScreen) {
        super.init(
            contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        contentView = view
        guard let root = view.layer else { return }

        trailLayer.frame = root.bounds
        root.addSublayer(trailLayer)
        cursorLayer.contentsGravity = .resizeAspect
        root.addSublayer(cursorLayer)
        root.addSublayer(crosshairLayer)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func configure(settings: Preferences.CursorSection, image: NSImage?) {
        self.settings = settings
        let size = settings.size
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        switch settings.style {
            case .crosshair:
                cursorSize = CGSize(width: size, height: size)
                hotspot = CGPoint(x: size / 2, y: size / 2)
                let t = settings.crosshairThickness
                let path = CGMutablePath()
                path.addRect(CGRect(x: 0, y: (size - t) / 2, width: size, height: t))
                path.addRect(CGRect(x: (size - t) / 2, y: 0, width: t, height: size))
                crosshairLayer.path = path
                crosshairLayer.fillColor = settings.crosshairColor.cgColor
                crosshairLayer.fillRule = .nonZero
                cursorLayer.contents = nil
            case .custom:
                crosshairLayer.path = nil
                if let image, image.size.width > 0, image.size.height > 0 {
                    let scale = size / max(image.size.width, image.size.height)
                    cursorSize = CGSize(
                        width: image.size.width * scale, height: image.size.height * scale)
                    cursorLayer.contents = image
                } else {
                    cursorSize = .zero
                    cursorLayer.contents = nil
                }
                hotspot =
                    settings.customImageHotspot == .center
                    ? CGPoint(x: cursorSize.width / 2, y: cursorSize.height / 2)
                    : CGPoint(x: 0, y: cursorSize.height)
            case .system:
                crosshairLayer.path = nil
                cursorLayer.contents = nil
                cursorSize = .zero
        }
        cursorLayer.bounds = CGRect(origin: .zero, size: cursorSize)
        crosshairLayer.bounds = CGRect(origin: .zero, size: cursorSize)

        trailLayer.color = settings.trailColor
        trailLayer.width = settings.trailWidth
        CATransaction.commit()
    }

    func update(location: CGPoint, showCursor: Bool, trail: [CGPoint]) {
        let origin = frame.origin
        let local = CGPoint(x: location.x - origin.x, y: location.y - origin.y)

        // Anchor the hotspot on the mouse position.
        let position = CGPoint(
            x: local.x - hotspot.x + cursorSize.width / 2,
            y: local.y + (cursorSize.height - hotspot.y) - cursorSize.height / 2)
        cursorLayer.position = position
        crosshairLayer.position = position
        let visible = showCursor && frame.contains(location)
        cursorLayer.isHidden = !visible || settings.style != .custom
        crosshairLayer.isHidden = !visible || settings.style != .crosshair

        trailLayer.update(points: trail.map { CGPoint(x: $0.x - origin.x, y: $0.y - origin.y) })
    }
}

// MARK: - Trail

/// The trail's ribbon shape (see `TrailPath`) used as a mask over a gradient that fades
/// from clear at the tail to the trail color at the cursor. Both are drawn by the GPU,
/// so nothing is redrawn or stretched on the CPU each frame.
private final class TrailLayer: CAGradientLayer {
    private let shape = CAShapeLayer()

    var width: Double = 6

    var color = CodableColor.white {
        didSet {
            colors = [
                CGColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 0),
                color.cgColor,
            ]
        }
    }

    override init() {
        super.init()
        shape.fillColor = CGColor(gray: 1, alpha: 1)
        shape.fillRule = .nonZero
        mask = shape
        isHidden = true
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSublayers() {
        super.layoutSublayers()
        shape.frame = bounds
    }

    func update(points: [CGPoint]) {
        guard points.count > 1, bounds.width > 0, bounds.height > 0,
            let path = TrailPath.ribbon(points: points, width: width)
        else {
            isHidden = true
            shape.path = nil
            return
        }
        shape.frame = bounds
        shape.path = path

        // Gradient runs from the oldest point to the cursor, in unit coordinates.
        let tail = points[0]
        var head = points[points.count - 1]
        if hypot(head.x - tail.x, head.y - tail.y) < 1 {
            head.x += 1
        }
        startPoint = CGPoint(x: tail.x / bounds.width, y: tail.y / bounds.height)
        endPoint = CGPoint(x: head.x / bounds.width, y: head.y / bounds.height)
        isHidden = false
    }
}
