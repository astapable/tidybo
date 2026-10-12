import AppKit

/// Wispr-style trigger: a thin capsule above the Dock that grows upward into a button
/// with a tooltip above it on hover. Lives in a non-activating panel so clicking it keeps Finder's selection.
final class TriggerPanel: NSPanel {
    let pill = TriggerView(frame: CGRect(x: 0, y: 0, width: 480, height: 150))

    init() {
        super.init(contentRect: pill.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isFloatingPanel = true
        level = .statusBar
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        contentView = pill
        acceptsMouseMovedEvents = true
        reposition()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func reposition() {
        guard let s = NSScreen.screens.first else { return }
        let v = s.visibleFrame
        setFrameOrigin(CGPoint(x: v.midX - frame.width / 2, y: v.minY + 4))
    }
}

final class TriggerView: NSView {
    enum Mode: Equatable {
        case ready(count: Int)    // count = cleanable items currently selected on the desktop
        case running
    }

    var mode: Mode = .ready(count: 0) {
        didSet {
            guard mode != oldValue else { return }
            updateContent()
            layoutButton(expanded: expanded, animated: true)
            setExpanded(hovering)
        }
    }
    var onClick: (() -> Void)?
    var onHover: (() -> Void)?
    var menuProvider: (() -> NSMenu)?

    // The button is a little robot head: chrome shell (bezel) around a black screen with a pixel face,
    // and ears on the sides (ears only when expanded).
    private let button = CALayer()          // container: geometry, shadow, press/shake transforms
    private let bezel = makeChrome(dark: false)
    private let screen = CALayer()
    private let icon = PixelFaceLayer()
    private let earL = makeChrome(dark: true), earR = makeChrome(dark: true)
    private let head = CALayer()            // tilts/turns with the gaze (button itself handles press)
    private var gaze: CGPoint = .zero
    private var earTimer: Timer?
    private let tip = SpeechBubble()          // the robot's line, typed like an old JRPG dialog
    private var typeWork: DispatchWorkItem?
    private var expanded = false
    private var collapseWork: DispatchWorkItem?
    private var hoverTimer: Timer?

    private let expandedSize = CGSize(width: 88, height: 68)   // wider than tall, like a helmet
    private let collapsedSize = CGSize(width: 44, height: 10)
    private let baseline: CGFloat = 6 // bottom edge of the pill; it grows upward from here
    private var hovering = false

    private func buttonRect(expanded e: Bool) -> CGRect {
        let s = e ? expandedSize : collapsedSize
        return CGRect(x: bounds.midX - s.width / 2, y: baseline, width: s.width, height: s.height)
    }
    /// Only the button itself reacts to the mouse (with a little slack around the thin capsule).
    private var hotRect: CGRect {
        expanded ? buttonRect(expanded: true).insetBy(dx: -4, dy: -4)
                 : buttonRect(expanded: false).insetBy(dx: -12, dy: -10)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        let scale: CGFloat = 2

        button.contentsScale = scale
        button.shadowColor = NSColor.black.cgColor
        button.shadowOpacity = 0.35
        button.shadowRadius = 5
        button.shadowOffset = CGSize(width: 0, height: -2)
        layer!.addSublayer(button)

        // Back to front: ears peek out from behind the shell.
        for ear in [earL, earR] {
            ear.bounds = CGRect(x: 0, y: 0, width: 12, height: 18)
            ear.cornerRadius = 6        // soft rounded nub
            ear.cornerCurve = .continuous
            ear.masksToBounds = true
        }
        button.addSublayer(head)
        for l in [earL, earR] { l.opacity = 0; head.addSublayer(l) }

        bezel.masksToBounds = true
        bezel.cornerCurve = .continuous
        bezel.borderColor = NSColor.white.withAlphaComponent(0.35).cgColor
        bezel.borderWidth = 0.5
        head.addSublayer(bezel)

        screen.backgroundColor = NSColor.black.cgColor
        screen.cornerCurve = .continuous
        screen.borderColor = NSColor.black.cgColor
        screen.borderWidth = 1
        head.addSublayer(screen)

        icon.opacity = 0
        icon.onGlance = { [weak self] in self?.turnHead(toward: $0) }
        icon.onNod = { [weak self] in self?.happyBop() }
        head.addSublayer(icon)

        tip.opacity = 0
        tip.transform = tipHiddenTransform
        tip.onTalking = { [weak self] in self?.icon.setTalking($0) }
        layer!.addSublayer(tip)

        layoutButton(expanded: false, animated: false)
        updateContent()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        hotRect.contains(convert(point, from: superview)) ? self : nil
    }

    // Hover is computed from the cursor position against `hotRect`, which changes size with the
    // button; a single view-wide tracking area delivers the moves.
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) { setHovering(hotRect.contains(convert(event.locationInWindow, from: nil))) }
    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseExited(with event: NSEvent) { setHovering(false) }

    private func setHovering(_ h: Bool) {
        guard h != hovering else { return }
        hovering = h
        if h {
            collapseWork?.cancel()
            onHover?()
            hoverTimer?.invalidate()
            hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.onHover?() }
            setExpanded(true)
        } else {
            hoverTimer?.invalidate(); hoverTimer = nil
            let work = DispatchWorkItem { [weak self] in self?.setExpanded(false) }
            collapseWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
        }
    }

    override func mouseDown(with event: NSEvent) {
        setPressed(true)
    }

    override func mouseUp(with event: NSEvent) {
        setPressed(false)
        guard hotRect.contains(convert(event.locationInWindow, from: nil)) else { return }
        if case .ready(let n) = mode, n == 0 { shake(); return }
        onClick?()
    }

    override func rightMouseDown(with event: NSEvent) {
        if let menu = menuProvider?() { NSMenu.popUpContextMenu(menu, with: event, for: self) }
    }

    /// Short horizontal shake: "nothing selected".
    func shake() {
        let a = CAKeyframeAnimation(keyPath: "position.x")
        let x = button.position.x
        a.values = [x, x - 6, x + 6, x - 4, x + 4, x]
        a.duration = 0.35
        a.timingFunction = CAMediaTimingFunction(name: .easeOut)
        button.add(a, forKey: "shake")
        icon.set(.squint)
        say(line("Hmm… nothing is selected."), typeNow: expanded)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in
            guard let self else { return }
            self.icon.set(self.faceExpression)
            self.updateContent()
        }
    }

    // MARK: Layout (springs tuned like SwiftUI `.spring(response:dampingFraction:)`)

    private var tipHiddenTransform: CATransform3D {
        CATransform3DConcat(CATransform3DMakeScale(0.6, 0.6, 1), CATransform3DMakeTranslation(0, -6, 0))
    }

    private var isRunning: Bool { mode == .running }

    private func setExpanded(_ e: Bool) {
        let e = e || isRunning          // stays open while cleaning to show it's working
        guard e != expanded else { return }
        expanded = e
        if !e { gaze = .zero }
        layoutButton(expanded: e, animated: true)
        icon.setAlive(e)
        scheduleEarWiggle()
    }

    // MARK: Head & ears body language

    private func earPosition(left: Bool, in r: CGRect) -> CGPoint {
        // Ears shift opposite to where the head turns: a cheap sense of volume.
        CGPoint(x: (left ? -3 : r.width + 3) - gaze.x * 0.35, y: r.height * 0.40 + gaze.y * 0.2)
    }

    /// Head follows the eyes a little: slight tilt and shift toward the gaze.
    private func turnHead(toward off: CGPoint) {
        guard expanded else { return }
        gaze = off
        let t = CATransform3DConcat(CATransform3DMakeRotation(-off.x * 0.014, 0, 0, 1),
                                    CATransform3DMakeTranslation(off.x * 0.4, off.y * 0.25, 0))
        spring(head, "transform", NSValue(caTransform3D: t), response: 0.55, damping: 0.62)
        let r = buttonRect(expanded: true)
        spring(earL, "position", NSValue(point: earPosition(left: true, in: r)), response: 0.5, damping: 0.6)
        spring(earR, "position", NSValue(point: earPosition(left: false, in: r)), response: 0.5, damping: 0.6)
    }

    /// Positive little bop: two soft nods with a gentle side-to-side sway; ears bounce along.
    private func happyBop() {
        guard expanded else { return }
        let nod = CAKeyframeAnimation(keyPath: "position.y")
        nod.values = [0, -2.5, 0, -1.8, 0]
        nod.keyTimes = [0, 0.22, 0.48, 0.7, 1]
        let sway = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        sway.values = [0, 0.05, -0.04, 0.025, 0]
        sway.keyTimes = [0, 0.22, 0.48, 0.7, 1]
        for a in [nod, sway] {
            a.duration = 0.8
            a.isAdditive = true
            a.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: 4)
        }
        head.add(nod, forKey: "bopNod")
        head.add(sway, forKey: "bopSway")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            self.flick(self.earL, sign: 1)
            self.flick(self.earR, sign: -1)
        }
    }

    private func scheduleEarWiggle() {
        earTimer?.invalidate(); earTimer = nil
        guard expanded else { return }
        earTimer = Timer.scheduledTimer(withTimeInterval: .random(in: 2.0...5.0), repeats: false) { [weak self] _ in
            guard let self else { return }
            let both = Double.random(in: 0...1) < 0.3
            let ears: [(CALayer, CGFloat)] = both ? [(self.earL, 1), (self.earR, -1)]
                : [Bool.random() ? (self.earL, 1) : (self.earR, -1)]
            for (ear, sign) in ears { self.flick(ear, sign: sign) }
            self.scheduleEarWiggle()
        }
    }

    /// Quick springy flick added on top of the ear's current transform.
    private func flick(_ ear: CALayer, sign: CGFloat) {
        let a = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        a.values = [0, 0.32, -0.14, 0.06, 0].map { $0 * sign }
        a.keyTimes = [0, 0.22, 0.5, 0.75, 1]
        a.duration = 0.45
        a.isAdditive = true
        a.timingFunctions = [.init(name: .easeOut), .init(name: .easeInEaseOut), .init(name: .easeInEaseOut), .init(name: .easeOut)]
        ear.add(a, forKey: "flick")
    }

    private func setPressed(_ p: Bool) {
        let t = p ? CATransform3DMakeScale(0.94, 0.94, 1) : CATransform3DIdentity
        spring(button, "transform", NSValue(caTransform3D: t), response: 0.25, damping: p ? 0.9 : 0.55)
    }

    /// Animates `key` from its current on-screen value, so interrupted animations never jump.
    private func spring(_ l: CALayer, _ key: String, _ value: Any, response: CGFloat, damping zeta: CGFloat,
                        delay: CFTimeInterval = 0, animated: Bool = true) {
        let from = l.presentation()?.value(forKeyPath: key) ?? l.value(forKeyPath: key)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        l.setValue(value, forKeyPath: key)
        CATransaction.commit()
        guard animated else { l.removeAnimation(forKey: key); return }
        let a = CASpringAnimation(keyPath: key)
        a.mass = 1
        a.stiffness = pow(2 * .pi / response, 2)
        a.damping = 4 * .pi * zeta / response
        a.fromValue = from
        a.toValue = value
        a.duration = a.settlingDuration
        if delay > 0 { a.beginTime = CACurrentMediaTime() + delay; a.fillMode = .backwards }
        l.add(a, forKey: key)
    }

    private func fade(_ l: CALayer, _ key: String, _ value: Any, duration: CFTimeInterval, delay: CFTimeInterval = 0, animated: Bool = true) {
        let from = l.presentation()?.value(forKeyPath: key) ?? l.value(forKeyPath: key)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        l.setValue(value, forKeyPath: key)
        CATransaction.commit()
        guard animated else { l.removeAnimation(forKey: key); return }
        let a = CABasicAnimation(keyPath: key)
        a.fromValue = from
        a.toValue = value
        a.duration = duration
        a.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1)
        if delay > 0 { a.beginTime = CACurrentMediaTime() + delay; a.fillMode = .backwards }
        l.add(a, forKey: key)
    }

    private func layoutButton(expanded e: Bool, animated: Bool) {
        let r = buttonRect(expanded: e)
        // Expanding: lively spring with a hint of overshoot. Collapsing: quicker, no bounce.
        let response: CGFloat = e ? 0.38 : 0.3
        let zeta: CGFloat = e ? 0.72 : 0.95
        spring(button, "bounds", NSValue(rect: CGRect(origin: .zero, size: r.size)), response: response, damping: zeta, animated: animated)
        spring(button, "position", NSValue(point: CGPoint(x: r.midX, y: r.midY)), response: response, damping: zeta, animated: animated)
        let local = CGRect(origin: .zero, size: r.size)
        let corner: CGFloat = e ? 30 : r.height / 2
        // Wide visor: thin shell on the sides/top, a thicker "chin" below.
        let screenRect = e ? CGRect(x: 5, y: 10, width: r.width - 10, height: r.height - 15)
                           : local.insetBy(dx: 2, dy: 2)
        let screenCorner: CGFloat = e ? 24 : screenRect.height / 2
        let center = CGPoint(x: r.width / 2, y: r.height / 2)
        func springAll(_ l: CALayer, bounds b: CGRect, position p: CGPoint, corner c: CGFloat? = nil) {
            spring(l, "bounds", NSValue(rect: b), response: response, damping: zeta, animated: animated)
            spring(l, "position", NSValue(point: p), response: response, damping: zeta, animated: animated)
            if let c { spring(l, "cornerRadius", c, response: response, damping: zeta, animated: animated) }
        }
        spring(button, "cornerRadius", corner, response: response, damping: zeta, animated: animated)
        springAll(head, bounds: local, position: center)
        if !e { spring(head, "transform", NSValue(caTransform3D: CATransform3DIdentity), response: response, damping: zeta, animated: animated) }
        springAll(bezel, bounds: local, position: center, corner: corner)
        let screenCenter = CGPoint(x: screenRect.midX, y: screenRect.midY)
        springAll(screen, bounds: CGRect(origin: .zero, size: screenRect.size), position: screenCenter, corner: screenCorner)
        spring(icon, "position", NSValue(point: screenCenter), response: response, damping: zeta, animated: animated)

        // Ears pop out from behind the shell after it has grown a bit.
        let extraDelay: CFTimeInterval = e ? 0.08 : 0
        let hidden = CATransform3DMakeScale(0.3, 0.3, 1)
        for (ear, left) in [(earL, true), (earR, false)] {
            spring(ear, "position", NSValue(point: earPosition(left: left, in: r)), response: response, damping: zeta, animated: animated)
            spring(ear, "transform", NSValue(caTransform3D: e ? CATransform3DIdentity : hidden), response: 0.4, damping: 0.6, delay: extraDelay, animated: animated)
            fade(ear, "opacity", e ? 1 : 0, duration: e ? 0.18 : 0.08, delay: extraDelay, animated: animated)
        }

        // Icon pops in just after the button starts growing; vanishes fast on collapse.
        fade(icon, "opacity", e ? iconOpacity : 0, duration: e ? 0.22 : 0.1, delay: e ? 0.06 : 0, animated: animated)
        spring(icon, "transform", NSValue(caTransform3D: e ? CATransform3DIdentity : CATransform3DMakeScale(0.6, 0.6, 1)),
               response: 0.4, damping: 0.65, delay: e ? 0.06 : 0, animated: animated)

        // Dialog box pops out of the robot, then the line starts typing.
        // While cleaning there is no line: the face's scanner says it all.
        let talk = e && !isRunning
        tip.position = tipPosition
        fade(tip, "opacity", talk ? 1 : 0, duration: talk ? 0.18 : 0.12, delay: talk ? 0.04 : 0, animated: animated)
        spring(tip, "transform", NSValue(caTransform3D: talk ? CATransform3DIdentity : tipHiddenTransform),
               response: talk ? 0.36 : 0.3, damping: talk ? 0.7 : 1, delay: talk ? 0.04 : 0, animated: animated)
        typeWork?.cancel()
        if talk {
            let w = DispatchWorkItem { [weak self] in self?.tip.startTyping() }
            typeWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: w)
        } else {
            tip.reset()
        }
    }

    private var iconOpacity: Float {
        if case .ready(let n) = mode, n == 0 { return 0.6 }
        return 1
    }

    private var faceExpression: PixelFaceLayer.Expression {
        switch mode {
        case .ready(let n): return n > 0 ? .ok : .idle
        case .running: return .busy
        }
    }


    /// Tail tip of the dialog box, just above the robot's head.
    private var tipPosition: CGPoint {
        CGPoint(x: bounds.midX, y: baseline + expandedSize.height + 6)
    }

    /// Polished-metal gradient (light top highlight → dark bottom with a soft reflection).
    private static func makeChrome(dark: Bool) -> CAGradientLayer {
        let g = CAGradientLayer()
        let hex: [UInt32] = dark ? [0x5A606B, 0x2A2E35, 0x15171B, 0x3A3F48]
                                 : [0xF7F9FC, 0xD3DAE3, 0x8A94A2, 0x3A4049, 0x1E2228, 0x5C636E]
        g.colors = hex.map { NSColor(srgbRed: CGFloat($0 >> 16 & 0xFF) / 255, green: CGFloat($0 >> 8 & 0xFF) / 255,
                                     blue: CGFloat($0 & 0xFF) / 255, alpha: 1).cgColor }
        g.locations = dark ? [0, 0.35, 0.8, 1] : [0, 0.12, 0.45, 0.75, 0.92, 1]
        g.startPoint = CGPoint(x: 0.5, y: 1)   // top (layers are y-up on macOS)
        g.endPoint = CGPoint(x: 0.5, y: 0)
        g.contentsScale = 2
        return g
    }


    private func updateContent() {
        let m: NSAttributedString
        switch mode {
        case .ready(let n) where n > 0:
            m = line("", bold: filesCount(n), " selected,\nclick me to tidy up")
        case .ready:
            m = line("Select some files,\nand I'll tidy them up")
        case .running:
            m = line("Vroom! Cleaning up…")
        }
        say(m, typeNow: expanded)
        icon.set(faceExpression)
    }

    private func say(_ m: NSAttributedString, typeNow: Bool) {
        tip.setMessage(m, typeNow: typeNow)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tip.position = tipPosition
        CATransaction.commit()
    }

    /// Robot's line: white mono text, the highlighted part in the face's glowing cyan.
    private func line(_ a: String, bold: String? = nil, _ b: String = "") -> NSAttributedString {
        let s = NSMutableAttributedString(string: a, attributes: [.font: SpeechBubble.font, .foregroundColor: NSColor.white])
        if let bold {
            s.append(NSAttributedString(string: bold, attributes: [.font: SpeechBubble.boldFont, .foregroundColor: PixelFaceLayer.glow]))
        }
        s.append(NSAttributedString(string: b, attributes: [.font: SpeechBubble.font, .foregroundColor: NSColor.white]))
        return s
    }
}

/// "1 file", "3 files" — folders count as files for brevity.
func filesCount(_ n: Int) -> String { n == 1 ? "1 file" : "\(n) files" }
