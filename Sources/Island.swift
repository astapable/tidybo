import AppKit

/// Black "dynamic island" that grows out of the camera notch so the robot can come out of it.
///
/// Split into two windows so app windows still cover it like the desktop:
/// - a thin band at menu-bar height sits above everything (it blends with the notch),
/// - the part below the menu bar lives at desktop level, under app windows.
/// Each pane draws the same island shape and a copy of the robot clipped to it; the robot on the
/// desktop overlay takes over once it drives out.
final class IslandWindow {
    let notch: CGRect               // global AppKit coords; zero-width on screens without a notch
    let robotDiameter: CGFloat
    private let panes: [IslandPane]
    var robots: [RobotLayer] { panes.map(\.robot) }

    private let lip: CGFloat = 10                                  // how far the widened island hangs below the notch
    private var travel: CGFloat { robotDiameter + 24 }             // how far the slot slides out
    // Always visibly wider than the notch, with room around the robot.
    private var expandedWidth: CGFloat { max(notch.width + 40, robotDiameter + 48) }

    private func height(widen w: CGFloat, extension e: CGFloat) -> CGFloat {
        max(0, notch.height + lip * w + travel * e)
    }

    /// Robot center while it rides on the slot floor (global AppKit coords).
    func carriedCenter(extension e: CGFloat) -> CGPoint {
        CGPoint(x: notch.midX, y: notch.maxY - height(widen: 1, extension: e) + 12 + robotDiameter / 2)
    }
    /// First point fully below the extended slot.
    var exitPoint: CGPoint { CGPoint(x: notch.midX, y: notch.maxY - height(widen: 1, extension: 1) - robotDiameter / 2 - 16) }

    init(screen: NSScreen, robotDiameter d: CGFloat) {
        robotDiameter = d
        let f = screen.frame
        let n: CGRect
        if let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea, r.minX > l.maxX {
            n = CGRect(x: f.minX + l.maxX, y: f.maxY - l.height, width: r.minX - l.maxX, height: l.height)
        } else {
            let h = f.maxY - screen.visibleFrame.maxY // menu bar height
            n = CGRect(x: f.midX, y: f.maxY - h, width: 0, height: h)
        }
        notch = n
        let w = max(n.width + 40, d + 48) + 80
        let total = n.height + 10 + d + 24 + 40
        let menuBand = f.maxY - screen.visibleFrame.maxY   // menu bar (incl. notch) height
        let x = n.midX - w / 2
        panes = [
            IslandPane(frame: CGRect(x: x, y: f.maxY - menuBand, width: w, height: menuBand),
                       level: .popUpMenu, scale: screen.backingScaleFactor, diameter: d),
            IslandPane(frame: CGRect(x: x, y: f.maxY - total, width: w, height: total - menuBand),
                       level: NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 2),
                       scale: screen.backingScaleFactor, diameter: d),
        ]
        setShape(widen: 0, extension: 0)
    }

    func show() { panes.forEach { $0.orderFrontRegardless() } }
    func hide() { panes.forEach { $0.orderOut(nil) } }

    /// widen: 0 = notch width, 1 = expanded (may overshoot for a springy feel).
    /// extension: 0 = slot tucked under the notch, 1 = slid out with room for the robot.
    func setShape(widen p: CGFloat, extension e: CGFloat) {
        let w = max(0, notch.width + (expandedWidth - notch.width) * p)
        let h = height(widen: max(0, p), extension: e)
        // Global rect, extended above the screen top so only the bottom corners are rounded.
        let rect = CGRect(x: notch.midX - w / 2, y: notch.maxY - h, width: w, height: h + 40)
        let radius = min(26, w / 2, h / 2)
        panes.forEach { $0.setIsland(rect, radius: radius) }
    }

    func placeRobot(at global: CGPoint, angle: CGFloat) {
        panes.forEach { $0.placeRobot(at: global, angle: angle) }
    }
}

final class IslandPane: NSWindow {
    private let island = CAShapeLayer()
    private let clipMask = CAShapeLayer()
    private let robotHolder = CALayer()
    let robot: RobotLayer

    init(frame: CGRect, level lvl: NSWindow.Level, scale: CGFloat, diameter: CGFloat) {
        robot = RobotLayer(diameter: diameter, scale: scale)
        super.init(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        level = lvl
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        let view = NSView(frame: CGRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        view.layer!.masksToBounds = true
        contentView = view
        island.fillColor = NSColor.black.cgColor
        island.contentsScale = scale
        view.layer!.addSublayer(island)
        robotHolder.frame = view.bounds
        robotHolder.mask = clipMask
        robotHolder.addSublayer(robot)
        view.layer!.addSublayer(robotHolder)
        setFrame(frame, display: false)
    }

    // Menu bar area is off-limits for regular windows; we want to be there.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    private func local(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x - frame.minX, y: p.y - frame.minY) }

    func setIsland(_ global: CGRect, radius: CGFloat) {
        let r = global.offsetBy(dx: -frame.minX, dy: -frame.minY)
        let path = CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        island.path = path
        clipMask.path = path
        CATransaction.commit()
    }

    func placeRobot(at global: CGPoint, angle: CGFloat) {
        robot.place(at: local(global), angle: angle)
    }
}

/// Screen that hosts the island: the one with a notch, otherwise the primary screen.
func islandScreen() -> NSScreen? {
    NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.screens.first
}
