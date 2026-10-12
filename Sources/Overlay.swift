import AppKit

/// One transparent, click-through window per display, just above the desktop icons.
final class OverlayWindow: NSWindow {
    let overlayView = OverlayView()

    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        contentView = overlayView
        setFrame(screen.frame, display: false)
    }
}

final class OverlayView: NSView {
    /// Debug frames; empty when the debug overlay is off.
    var icons: [DesktopIcon] = [] { didSet { needsDisplay = true } }
    private(set) var robot: RobotLayer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }
    required init?(coder: NSCoder) { fatalError() }

    func installRobot(diameter: CGFloat) {
        removeRobot()
        let r = RobotLayer(diameter: diameter, scale: window?.backingScaleFactor ?? 2)
        r.isHidden = true
        layer?.addSublayer(r)
        robot = r
    }

    /// Icon copies go under the robot: they are pulled beneath it into its center.
    func addIconCopy(_ copy: CALayer, at local: CGPoint) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        copy.position = local
        if let robot { layer?.insertSublayer(copy, below: robot) } else { layer?.addSublayer(copy) }
        CATransaction.commit()
    }

    // MARK: Effects

    private var badge: CALayer?
    private var badgeText: CATextLayer?

    /// Apple-like "fast out, long settle" curve.
    private static let appleEaseOut = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)

    /// iOS-style count badge on the cleanup folder's corner; `bounce` = something just went in.
    func setFolderBadge(rect global: CGRect, window: NSWindow, count: Int, bounce: Bool) {
        let r = global.offsetBy(dx: -window.frame.minX, dy: -window.frame.minY)
        guard r.intersects(bounds), count > 0 else { return }
        let scale = window.backingScaleFactor
        let font = NSFont(descriptor: NSFont.systemFont(ofSize: 14, weight: .semibold).fontDescriptor.withDesign(.rounded)!, size: 14)!
        let appearing = badge == nil
        if appearing {
            let b = CALayer()
            b.backgroundColor = NSColor.systemRed.cgColor
            b.shadowColor = NSColor.black.cgColor
            b.shadowOpacity = 0.25
            b.shadowRadius = 4
            b.shadowOffset = CGSize(width: 0, height: -1)
            b.contentsScale = scale
            let t = CATextLayer()
            t.alignmentMode = .center
            t.contentsScale = scale
            t.foregroundColor = NSColor.white.cgColor
            t.font = font
            t.fontSize = 14
            b.addSublayer(t)
            layer?.addSublayer(b)
            badge = b; badgeText = t
        }
        guard let badge, let badgeText else { return }

        let text = "\(count)"
        let textW = ceil((text as NSString).size(withAttributes: [.font: font]).width)
        let h: CGFloat = 22
        let w = max(h, textW + 14)
        let lineH = ceil(font.ascender - font.descender)
        CATransaction.begin()
        CATransaction.setDisableActions(appearing)
        CATransaction.setAnimationDuration(0.3)
        CATransaction.setAnimationTimingFunction(Self.appleEaseOut)
        badge.bounds = CGRect(x: 0, y: 0, width: w, height: h)
        badge.cornerRadius = h / 2
        badge.shadowPath = CGPath(roundedRect: badge.bounds, cornerWidth: h / 2, cornerHeight: h / 2, transform: nil)
        // The folder artwork sits lower than the icon frame's top edge: put the badge on its corner.
        badge.position = CGPoint(x: r.maxX - 6, y: r.maxY - 14)
        badgeText.frame = CGRect(x: 0, y: (h - lineH) / 2, width: w, height: lineH)
        CATransaction.commit()

        if badgeText.string as? String != text {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.18
            badgeText.add(fade, forKey: "text")
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            badgeText.string = text
            CATransaction.commit()
        }

        if appearing { spring(badge, from: 0.2, damping: 13) }
        guard bounce else { return }
        if !appearing { spring(badge, from: 1.32, damping: 10) }
        ripple(from: r)
    }

    private func spring(_ l: CALayer, from: CGFloat, damping: CGFloat) {
        let s = CASpringAnimation(keyPath: "transform.scale")
        s.fromValue = from
        s.toValue = 1
        s.mass = 1
        s.stiffness = 280
        s.damping = damping
        s.duration = s.settlingDuration
        l.add(s, forKey: "spring")
    }

    /// Soft white wave spreading out from behind the folder and fading to nothing.
    private func ripple(from r: CGRect) {
        let center = CGPoint(x: r.midX, y: r.midY - 3)
        let base = r.width * 0.95
        // Container masked so the wave never washes over the folder itself: it comes from behind it.
        let holder = CALayer()
        holder.frame = bounds
        let mask = CAShapeLayer()
        let m = CGMutablePath()
        m.addRect(bounds)
        m.addRoundedRect(in: r.insetBy(dx: 4, dy: 6).offsetBy(dx: 0, dy: -3), cornerWidth: 10, cornerHeight: 10)
        mask.path = m
        mask.fillRule = .evenOdd
        holder.mask = mask
        if let robot { layer?.insertSublayer(holder, below: robot) } else { layer?.addSublayer(holder) }

        CATransaction.begin()
        CATransaction.setCompletionBlock { holder.removeFromSuperlayer() }
        // Radial gradient instead of a hard outline: faint white haze inside, a soft glowing rim,
        // and a feathered falloff to nothing at the edge.
        let white = { (a: CGFloat) in NSColor.white.withAlphaComponent(a).cgColor }
        for (i, peak) in [(0, Float(0.85)), (1, Float(0.45))] {
            let wave = CAGradientLayer()
            wave.type = .radial
            wave.startPoint = CGPoint(x: 0.5, y: 0.5)
            wave.endPoint = CGPoint(x: 1, y: 1)
            wave.colors = [white(0.16), white(0.22), white(0.5), white(0.28), white(0)]
            wave.locations = [0, 0.55, 0.8, 0.9, 1]
            wave.bounds = CGRect(x: 0, y: 0, width: base, height: base)
            wave.position = center
            wave.contentsScale = window?.backingScaleFactor ?? 2
            wave.opacity = 0
            holder.addSublayer(wave)

            let grow = CABasicAnimation(keyPath: "transform.scale")
            grow.fromValue = 0.85
            grow.toValue = 2.3
            grow.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0, peak, 0]
            fade.keyTimes = [0, 0.1, 1]
            fade.timingFunctions = [.init(name: .easeOut), CAMediaTimingFunction(controlPoints: 0.33, 0, 0.25, 1)]
            let g = CAAnimationGroup()
            g.animations = [grow, fade]
            g.duration = 1.4
            g.beginTime = CACurrentMediaTime() + Double(i) * 0.18
            g.fillMode = .backwards
            wave.add(g, forKey: "wave")
        }
        CATransaction.commit()
    }

    /// Red ring on an icon that could not be cleaned up.
    func flashFailure(rect global: CGRect, window: NSWindow) {
        let r = global.offsetBy(dx: -window.frame.minX, dy: -window.frame.minY)
        guard r.intersects(bounds) else { return }
        let ring = CAShapeLayer()
        let side = max(r.width, r.height) + 12
        ring.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        ring.position = CGPoint(x: r.midX, y: r.midY)
        ring.path = CGPath(roundedRect: ring.bounds, cornerWidth: 14, cornerHeight: 14, transform: nil)
        ring.fillColor = nil
        ring.strokeColor = NSColor.systemRed.cgColor
        ring.lineWidth = 3
        ring.opacity = 0
        if let robot { layer?.insertSublayer(ring, below: robot) } else { layer?.addSublayer(ring) }
        CATransaction.begin()
        CATransaction.setCompletionBlock { ring.removeFromSuperlayer() }
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.85
        grow.toValue = 1.25
        grow.timingFunction = Self.appleEaseOut
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 0]
        fade.keyTimes = [0, 0.2, 1]
        let g = CAAnimationGroup()
        g.animations = [grow, fade]
        g.duration = 0.7
        ring.add(g, forKey: "ring")
        CATransaction.commit()
    }

    /// Ends a run: the robot goes away now, the badge fades out after `badgeDelay`.
    /// Only this run's layers are touched, so a run started in the meantime is unaffected.
    func retireRun(badgeDelay: TimeInterval) {
        removeRobot()
        guard let b = badge else { return }
        badge = nil; badgeText = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + badgeDelay) {
            CATransaction.begin()
            CATransaction.setCompletionBlock { b.removeFromSuperlayer() }
            CATransaction.setAnimationDuration(0.25)
            b.opacity = 0
            b.setAffineTransform(CGAffineTransform(scaleX: 0.6, y: 0.6))
            CATransaction.commit()
        }
    }

    func removeRobot() {
        robot?.removeFromSuperlayer()
        robot = nil
    }

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let window else { return }
        let origin = window.frame.origin
        let font = NSFont.systemFont(ofSize: 10, weight: .semibold)

        for icon in icons {
            let global = appKitRect(fromAX: icon.axFrame)
            let r = global.offsetBy(dx: -origin.x, dy: -origin.y)
            guard r.intersects(bounds) else { continue }

            let color: NSColor = icon.isSelected ? .systemGreen : .systemRed
            color.setStroke()
            let box = NSBezierPath(rect: r.insetBy(dx: 0.5, dy: 0.5))
            box.lineWidth = icon.isSelected ? 3 : 1.5
            box.stroke()

            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: r.midX - 3, y: r.midY - 3, width: 6, height: 6)).fill()

            let label = NSAttributedString(string: icon.name, attributes: [
                .font: font,
                .foregroundColor: NSColor.white,
                .backgroundColor: color.withAlphaComponent(0.85),
            ])
            let size = label.size()
            label.draw(at: NSPoint(x: r.midX - size.width / 2, y: r.maxY + 2))
        }
    }
}
