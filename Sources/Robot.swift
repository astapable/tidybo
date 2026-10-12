import AppKit

/// Top-down robot vacuum, closer to a real one but in the trigger's style: dark graphite skirt,
/// brushed-metal lid lit from the top, a front bumper with seams and a sensor with a cyan glint
/// (shows the heading), and a round pixel display in the middle.
///
/// The skirt, lid and display stay upright (light from the top, readable display); the bumper,
/// sensor sit on turntables that rotate with the heading. Forward is +x at angle 0.
final class RobotLayer: CALayer {
    let display: RobotDisplay
    private let back = CALayer()        // under the body (currently empty, kept for parts that peek out)
    private let front = CALayer()       // on the body: bumper, sensor

    init(diameter d: CGFloat, scale: CGFloat) {
        let r = d / 2
        display = RobotDisplay(diameter: r * 0.98, scale: scale)
        super.init()
        bounds = CGRect(x: 0, y: 0, width: d, height: d)
        contentsScale = scale
        let c = CGPoint(x: r, y: r)
        shadowColor = NSColor.black.cgColor
        shadowOpacity = 0.4
        shadowRadius = 9
        shadowOffset = CGSize(width: 0, height: -3)
        for t in [back, front] { t.bounds = bounds; t.position = c }

        addSublayer(back)

        // Skirt: dark graphite, top-lit.
        let skirt = gradient([0xA3AAB4, 0x747B86, 0x4C525B, 0x626973], [0, 0.4, 0.85, 1])
        skirt.frame = bounds
        skirt.cornerRadius = r
        skirt.masksToBounds = true
        skirt.contentsScale = scale
        addSublayer(skirt)

        // Front bumper: a slightly lighter segment of the skirt with dark seams (rotates).
        let lidR = r * 0.84
        let span = CGFloat.pi * 0.4
        let bumper = CAShapeLayer()
        let bp = CGMutablePath()
        bp.addArc(center: c, radius: r - 1, startAngle: -span, endAngle: span, clockwise: false)
        bp.addArc(center: c, radius: lidR, startAngle: span, endAngle: -span, clockwise: true)
        bp.closeSubpath()
        bumper.path = bp
        bumper.fillColor = NSColor(white: 1, alpha: 0.16).cgColor
        bumper.strokeColor = NSColor(white: 0, alpha: 0.45).cgColor
        bumper.lineWidth = 1
        bumper.contentsScale = scale
        front.addSublayer(bumper)
        addSublayer(front)

        // Lid: brushed metal with a soft highlight from the top-left and faint concentric rings.
        let lid = CAGradientLayer()
        lid.type = .radial
        lid.colors = [0xFFFFFF, 0xE4E8ED, 0xB8BFC8, 0x949CA7].map(Self.color)
        lid.locations = [0, 0.35, 0.8, 1]
        lid.startPoint = CGPoint(x: 0.38, y: 0.72)
        lid.endPoint = CGPoint(x: 1.15, y: -0.1)
        lid.bounds = CGRect(x: 0, y: 0, width: lidR * 2, height: lidR * 2)
        lid.position = c
        lid.cornerRadius = lidR
        lid.masksToBounds = true
        lid.borderColor = NSColor(white: 0, alpha: 0.28).cgColor
        lid.borderWidth = 1
        lid.contentsScale = scale
        for k in stride(from: CGFloat(0.55), through: 0.95, by: 0.1) {
            let ring = CAShapeLayer()
            let rr = lidR * k
            ring.path = CGPath(ellipseIn: CGRect(x: lidR - rr, y: lidR - rr, width: rr * 2, height: rr * 2), transform: nil)
            ring.fillColor = nil
            ring.strokeColor = NSColor(white: 0, alpha: 0.05).cgColor
            ring.lineWidth = 0.75
            ring.contentsScale = scale
            lid.addSublayer(ring)
        }
        addSublayer(lid)

        // Front sensor window with a cyan glint (rotates with the heading, above the lid).
        let sensorHolder = CALayer()
        sensorHolder.bounds = bounds
        sensorHolder.position = c
        let sensor = CALayer()
        let sr = r * 0.075
        sensor.bounds = CGRect(x: 0, y: 0, width: sr * 2.6, height: sr * 2)
        sensor.position = CGPoint(x: r + lidR * 0.8, y: r)
        sensor.cornerRadius = sr
        sensor.backgroundColor = NSColor.black.cgColor
        sensor.borderColor = NSColor(white: 1, alpha: 0.25).cgColor
        sensor.borderWidth = 0.5
        let glint = CALayer()
        glint.bounds = CGRect(x: 0, y: 0, width: sr * 0.7, height: sr * 0.7)
        glint.position = CGPoint(x: sensor.bounds.midX, y: sensor.bounds.midY)
        glint.cornerRadius = sr * 0.35
        glint.backgroundColor = PixelFaceLayer.glow.cgColor
        glint.shadowColor = PixelFaceLayer.glow.cgColor
        glint.shadowOpacity = 1
        glint.shadowRadius = 3
        glint.shadowOffset = .zero
        sensor.addSublayer(glint)
        sensorHolder.addSublayer(sensor)

        // Soft halo around the glint; both pulse periodically like a status LED.
        let halo = CAGradientLayer()
        halo.type = .radial
        halo.colors = [PixelFaceLayer.glow.withAlphaComponent(0.6).cgColor, PixelFaceLayer.glow.withAlphaComponent(0).cgColor]
        halo.startPoint = CGPoint(x: 0.5, y: 0.5)
        halo.endPoint = CGPoint(x: 1, y: 1)
        halo.bounds = CGRect(x: 0, y: 0, width: sr * 3.4, height: sr * 3.4)
        halo.position = sensor.position
        halo.contentsScale = scale
        sensorHolder.addSublayer(halo)
        Self.pulse(glint: glint, halo: halo)
        addSublayer(sensorHolder)
        sensorTurntable = sensorHolder

        // Round pixel display in the middle (content stays upright).
        display.position = c
        addSublayer(display)
    }
    private var sensorTurntable: CALayer?

    override init(layer: Any) {
        display = (layer as? RobotLayer)?.display ?? RobotDisplay(diameter: 10, scale: 2)
        super.init(layer: layer)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Slow "breathing" like a sleep indicator: smooth ease-in-out up and down, no size jumps.
    private static func pulse(glint: CALayer, halo: CALayer) {
        let half: CFTimeInterval = 0.8
        let now = CACurrentMediaTime()
        let start = now - fmod(now, half * 2)   // shared clock: every copy of the robot breathes together
        func breathe(_ l: CALayer, _ key: String, from: Any, to: Any) {
            let a = CABasicAnimation(keyPath: key)
            a.fromValue = from
            a.toValue = to
            a.duration = half
            a.autoreverses = true
            a.repeatCount = .infinity
            a.timingFunction = CAMediaTimingFunction(controlPoints: 0.45, 0, 0.55, 1)   // sine-like
            a.beginTime = start
            a.fillMode = .backwards
            l.add(a, forKey: key)
        }
        breathe(glint, "opacity", from: 0.45, to: 1)
        breathe(glint, "shadowRadius", from: 1.5, to: 4)
        breathe(halo, "opacity", from: 0.05, to: 0.4)
    }

    private static func color(_ hex: UInt32) -> CGColor {
        NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1).cgColor
    }

    private func gradient(_ hex: [UInt32], _ locations: [NSNumber]) -> CAGradientLayer {
        let g = CAGradientLayer()
        g.colors = hex.map(Self.color)
        g.locations = locations
        g.startPoint = CGPoint(x: 0.5, y: 1)
        g.endPoint = CGPoint(x: 0.5, y: 0)
        return g
    }

    /// Driving on the desktop (vs. parked in the slot): the display's arrows march.
    func setBrushSpinning(_ on: Bool) {
        display.setDriving(on)
    }

    /// Places the robot without implicit animations. `point` is in the superlayer's coordinates.
    func place(at point: CGPoint, angle: CGFloat, scale s: CGFloat = 1) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        position = point
        setAffineTransform(CGAffineTransform(scaleX: s, y: s))
        let rot = CATransform3DMakeRotation(angle, 0, 0, 1)
        back.transform = rot
        front.transform = rot
        sensorTurntable?.transform = rot
        display.heading = angle
        CATransaction.commit()
    }
}

/// Round black screen with glowing cyan pixels, same style as the trigger's face.
/// Driving: `>>` chevrons marching toward the heading. Sucking files: each file drops in and flies
/// into a folder, which bounces per file (several fly at once if several were taken). Failure: "!".
final class RobotDisplay: CALayer {
    private let px: CGFloat
    private let arrows = CALayer()
    private let chevA = CAShapeLayer(), chevB = CAShapeLayer()
    private let folder = CAShapeLayer(), bang = CAShapeLayer()
    private var inFlight = 0
    private var renderScale: CGFloat = 2

    var heading: CGFloat = 0 {
        didSet { arrows.setAffineTransform(CGAffineTransform(rotationAngle: heading)) }
    }

    init(diameter d: CGFloat, scale: CGFloat) {
        px = max(2, (d / 22).rounded(.down))
        super.init()
        bounds = CGRect(x: 0, y: 0, width: d, height: d)
        cornerRadius = d / 2
        backgroundColor = NSColor.black.cgColor
        borderColor = NSColor(white: 0, alpha: 1).cgColor
        borderWidth = 1.5
        masksToBounds = false
        // Faint glass ring so it reads as a screen set into the lid.
        let rim = CAShapeLayer()
        rim.path = CGPath(ellipseIn: bounds.insetBy(dx: 1.5, dy: 1.5), transform: nil)
        rim.fillColor = nil
        rim.strokeColor = NSColor(white: 1, alpha: 0.12).cgColor
        rim.lineWidth = 1
        rim.contentsScale = scale
        addSublayer(rim)

        arrows.bounds = bounds
        arrows.position = CGPoint(x: d / 2, y: d / 2)
        addSublayer(arrows)
        let c = CGPoint(x: d / 2, y: d / 2)
        for (l, dx) in [(chevA, -px * 2.2), (chevB, px * 2.2)] {
            l.path = path(Self.chevron, center: CGPoint(x: c.x + dx, y: c.y))
            glow(l, scale)
            arrows.addSublayer(l)
        }
        renderScale = scale
        for (l, rows) in [(folder, Self.folderIcon), (bang, Self.bangIcon)] {
            l.bounds = bounds
            l.position = c
            l.path = path(rows, center: c)
            glow(l, scale)
            l.opacity = 0
            addSublayer(l)
        }
    }
    override init(layer: Any) { px = (layer as? RobotDisplay)?.px ?? 2; super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }

    private func glow(_ l: CAShapeLayer, _ scale: CGFloat) {
        l.fillColor = PixelFaceLayer.glow.cgColor
        l.shadowColor = PixelFaceLayer.glow.cgColor
        l.shadowOpacity = 1
        l.shadowRadius = 3
        l.shadowOffset = .zero
        l.contentsScale = scale
    }

    /// Marching chevrons while driving; static (dim) when parked.
    func setDriving(_ on: Bool) {
        for (i, l) in [chevA, chevB].enumerated() {
            l.removeAnimation(forKey: "march")
            guard on else { l.opacity = 0.35; continue }
            l.opacity = 1
            let a = CAKeyframeAnimation(keyPath: "opacity")
            a.values = [0.25, 1, 0.25]
            a.keyTimes = [0, 0.3, 1]
            a.duration = 0.7
            a.repeatCount = .infinity
            a.beginTime = CACurrentMediaTime() + Double(i) * 0.18
            a.fillMode = .backwards
            l.add(a, forKey: "march")
        }
    }

    private var fileAt: CGPoint { CGPoint(x: bounds.midX - bounds.width * 0.16, y: bounds.midY) }
    private var folderAt: CGPoint { CGPoint(x: bounds.midX + bounds.width * 0.17, y: bounds.midY - px * 0.5) }

    /// `count` files drop in one after another and fly into the folder.
    func showReceive(count: Int = 1) {
        let n = max(1, min(count, 3))
        for i in 0..<n {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.2) { [weak self] in
                self?.flyFile(index: i, of: n)
            }
        }
    }

    private func flyFile(index i: Int, of n: Int) {
        inFlight += 1
        if inFlight == 1 {
            folder.removeAllAnimations()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            folder.position = folderAt
            CATransaction.commit()
            set(arrows, opacity: 0, duration: 0.12)
            set(folder, opacity: 1, duration: 0.15)
        }
        let start = CGPoint(x: fileAt.x + (CGFloat(i) - CGFloat(n - 1) / 2) * px * 3, y: fileAt.y)
        let f = CAShapeLayer()
        f.bounds = bounds
        f.position = start
        f.path = path(Self.fileIcon, center: CGPoint(x: bounds.midX, y: bounds.midY))
        glow(f, renderScale)
        addSublayer(f)

        let d = bounds.width
        let drop = CAKeyframeAnimation(keyPath: "position")
        drop.values = [CGPoint(x: start.x, y: start.y + d * 0.45), start, CGPoint(x: start.x, y: start.y + px), start,
                       folderAt].map { NSValue(point: $0) }
        drop.keyTimes = [0, 0.3, 0.4, 0.5, 0.85]
        drop.timingFunctions = [.init(name: .easeIn), .init(name: .easeOut), .init(name: .easeIn), .init(name: .easeIn)]
        let shrink = CAKeyframeAnimation(keyPath: "transform.scale")
        shrink.values = [1, 1, 1, 0.3]
        shrink.keyTimes = [0, 0.5, 0.6, 0.85]
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 1, 0]
        fade.keyTimes = [0, 0.1, 0.8, 0.86]
        let g = CAAnimationGroup()
        g.animations = [drop, shrink, fade]
        g.duration = 1.0
        g.fillMode = .forwards
        g.isRemovedOnCompletion = false

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            f.removeFromSuperlayer()
            self?.fileLanded()
        }
        f.add(g, forKey: "fly")
        CATransaction.commit()
        // Folder bounces the moment the file reaches it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.85) { [weak self] in self?.popFolder() }
    }

    private func popFolder() {
        let pop = CAKeyframeAnimation(keyPath: "transform.scale")
        pop.values = [1, 1.3, 0.92, 1.05, 1]
        pop.keyTimes = [0, 0.3, 0.6, 0.85, 1]
        pop.duration = 0.3
        folder.add(pop, forKey: "pop")
    }

    private func fileLanded() {
        inFlight -= 1
        guard inFlight == 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.inFlight == 0 else { return }
            self.set(self.folder, opacity: 0, duration: 0.18)
            self.set(self.arrows, opacity: 1, duration: 0.18)
        }
    }

    /// Blinking "!" — the file could not be taken.
    func showError() {
        set(arrows, opacity: 0, duration: 0.1)
        bang.opacity = 1
        let b = CAKeyframeAnimation(keyPath: "opacity")
        b.values = [1, 0.15, 1, 0.15, 1]
        b.duration = 0.9
        bang.add(b, forKey: "blink")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { [weak self] in
            guard let self else { return }
            self.set(self.bang, opacity: 0, duration: 0.15)
            if self.inFlight == 0 { self.set(self.arrows, opacity: 1, duration: 0.15) }
        }
    }

    private func set(_ l: CALayer, opacity: Float, duration: CFTimeInterval) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        l.opacity = opacity
        CATransaction.commit()
    }

    private func path(_ rows: [String], center c: CGPoint) -> CGPath {
        let p = CGMutablePath()
        let w = CGFloat(rows.map(\.count).max() ?? 0) * px, h = CGFloat(rows.count) * px
        let x0 = c.x - w / 2, yTop = c.y + h / 2
        for (ri, row) in rows.enumerated() {
            for (ci, ch) in row.enumerated() where ch == "#" {
                let r = CGRect(x: x0 + CGFloat(ci) * px, y: yTop - CGFloat(ri + 1) * px, width: px, height: px)
                p.addRoundedRect(in: r.insetBy(dx: 0.25, dy: 0.25), cornerWidth: 0.6, cornerHeight: 0.6)
            }
        }
        return p
    }

    private static let chevron = ["##...", ".##..", "..##.", ".##..", "##..."]
    private static let fileIcon = ["###..", "#.##.", "#..##", "#...#", "#...#", "#...#", "#####"]
    private static let folderIcon = ["###....", "#######", "#.....#", "#.....#", "#.....#", "#######"]
    private static let bangIcon = ["##", "##", "##", "##", "..", "##"]
}
