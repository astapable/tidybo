import AppKit

/// Pixel-art face (eyes + mouth) in glowing cyan, for the trigger button's black screen.
/// While "alive" it blinks and glances around; in `.busy` the eyes become a sweeping scanner.
final class PixelFaceLayer: CALayer {
    enum Expression: Equatable {
        case idle      // tall elongated eyes, small smile — nothing selected
        case happy     // ◠ ◠ eyes, smile
        case ok        // "OK" in pixel letters, no mouth, bopping — files selected, waiting for a click
        case busy      // processing scanner instead of eyes — cleaning
        case squint    // > < eyes — "nothing to clean" shake
    }

    static let glow = NSColor(calibratedRed: 0.38, green: 0.86, blue: 1, alpha: 1)

    private let eyeRig = CALayer()          // moved around for glances
    private let mouthRig = CALayer()        // follows the glance a bit less: reads as a head turn
    private let eyeL = CAShapeLayer(), eyeR = CAShapeLayer()   // separate, so one can wink
    private let mouth = CAShapeLayer()
    private let scanner = CALayer()
    private let pixel: CGFloat = 2.5
    private let eyeGap: CGFloat = 17     // still leaves a comfortable margin to the visor edges
    private(set) var expression: Expression?
    /// Called on every glance so the owner can turn the head along with the eyes.
    var onGlance: ((CGPoint) -> Void)?
    /// Called instead of glancing while showing "OK?": the owner does a happy head bop.
    var onNod: (() -> Void)?
    private var restMouth: CGPath?
    private var talkTimer: Timer?
    private var mouthOpen = false
    private var blinkTimer: Timer?
    private var glanceTimer: Timer?
    private var anticTimer: Timer?
    private var base: (l: [String], r: [String], m: [String]) = ([], [], [])
    private var inAntic = false

    override init() {
        super.init()
        bounds = CGRect(x: 0, y: 0, width: 66, height: 44)
        for rig in [eyeRig, mouthRig] { rig.frame = bounds; addSublayer(rig) }
        for (l, parent) in [(eyeL, eyeRig), (eyeR, eyeRig), (mouth, mouthRig)] {
            l.frame = bounds
            style(l)
            parent.addSublayer(l)
        }
        // Blinks/winks squash each eye around its own center.
        for (eye, x) in [(eyeL, bounds.midX - eyeGap), (eyeR, bounds.midX + eyeGap)] {
            eye.anchorPoint = CGPoint(x: x / bounds.width, y: eyeCenterY / bounds.height)
            eye.position = CGPoint(x: x, y: eyeCenterY)
        }
        buildScanner()
        set(.idle)
    }
    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }

    private var eyeCenterY: CGFloat { bounds.midY + 1 }

    private var renderScale: CGFloat = 2

    /// Raster scale for the pixel shapes (raise it when the face is drawn scaled up).
    func setRenderScale(_ s: CGFloat) {
        renderScale = s
        func apply(_ l: CALayer) { l.contentsScale = s; l.sublayers?.forEach(apply) }
        sublayers?.forEach(apply)
    }

    private func style(_ l: CALayer) {
        if let s = l as? CAShapeLayer { s.fillColor = Self.glow.cgColor }
        l.shadowColor = Self.glow.cgColor
        l.shadowOpacity = 1
        l.shadowRadius = 3.5
        l.shadowOffset = .zero
        l.contentsScale = renderScale
    }

    func set(_ e: Expression) {
        guard e != expression else { return }
        expression = e
        let (l, r, m): ([String], [String], [String])
        switch e {
        case .idle:   l = Self.round; r = Self.round; m = Self.smallSmile
        case .happy:  l = Self.arc; r = Self.arc; m = Self.smile
        case .ok:     l = []; r = []; m = []
        case .busy:   l = []; r = []; m = ["##"]
        case .squint: l = Self.chevronRight; r = Self.chevronRight.map { String($0.reversed()) }; m = ["###"]
        }
        base = (l, r, m)
        inAntic = false
        draw(l, r, m)
        drawText(e == .ok ? Self.okText : [])
        setScanning(e == .busy)
        if e == .busy || e == .squint || e == .ok { look(at: .zero) }
    }

    /// Draws a face from pixel bitmaps, cross-fading from the previous one.
    private func draw(_ l: [String], _ r: [String], _ m: [String]) {
        let pl = CGMutablePath(), pr = CGMutablePath(), pm = CGMutablePath()
        add(l, centeredAt: CGPoint(x: bounds.midX - eyeGap, y: eyeCenterY), to: pl, origin: .zero)
        add(r, centeredAt: CGPoint(x: bounds.midX + eyeGap, y: eyeCenterY), to: pr, origin: .zero)
        add(m, centeredAt: mouthCenter(rows: m.count), to: pm, origin: .zero)
        restMouth = pm
        for (layer, p) in [(eyeL, pl as CGPath), (eyeR, pr as CGPath), (mouth, pm as CGPath)] {
            let t = CATransition()
            t.type = .fade
            t.duration = 0.13
            layer.add(t, forKey: "expr")
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.path = p
            CATransaction.commit()
        }
    }

    /// Pixel text across the visor (drawn in the left-eye layer, which spans the whole face).
    private let textLayer = CAShapeLayer()
    private func drawText(_ rows: [String]) {
        if textLayer.superlayer == nil {
            textLayer.frame = bounds
            style(textLayer)
            eyeRig.addSublayer(textLayer)
        }
        let p = CGMutablePath()
        add(rows, centeredAt: CGPoint(x: bounds.midX, y: bounds.midY + 1), to: p, origin: .zero, px: 3.2)
        let t = CATransition()
        t.type = .fade
        t.duration = 0.13
        textLayer.add(t, forKey: "expr")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        textLayer.path = p
        CATransaction.commit()
    }

    /// Small mouth below the eyes, between them, with a clear gap.
    private func mouthCenter(rows: Int) -> CGPoint { CGPoint(x: bounds.midX, y: bounds.midY - 10) }

    // MARK: Life: blinking and glancing

    func setAlive(_ on: Bool) {
        blinkTimer?.invalidate(); blinkTimer = nil
        glanceTimer?.invalidate(); glanceTimer = nil
        anticTimer?.invalidate(); anticTimer = nil
        guard on else { endAntic(); look(at: .zero); return }
        scheduleBlink()
        scheduleGlance()
        scheduleAntic()
    }

    private func scheduleBlink() {
        blinkTimer = Timer.scheduledTimer(withTimeInterval: .random(in: 1.2...3.0), repeats: false) { [weak self] _ in
            guard let self else { return }
            self.blink()
            if Double.random(in: 0...1) < 0.25 {   // occasional double blink
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { self.blink() }
            }
            self.scheduleBlink()
        }
    }

    private func scheduleGlance() {
        glanceTimer = Timer.scheduledTimer(withTimeInterval: .random(in: 1.0...2.6), repeats: false) { [weak self] _ in
            guard let self else { return }
            if self.expression == .ok {
                self.onNod?()
            } else if self.expression != .busy, self.expression != .squint {
                let spots: [CGPoint] = [.zero, .zero, CGPoint(x: -4, y: 0), CGPoint(x: 4, y: 0),
                                        CGPoint(x: -3, y: 2.5), CGPoint(x: 3, y: 2.5), CGPoint(x: 0, y: -2)]
                self.look(at: spots.randomElement()!)
            }
            self.scheduleGlance()
        }
    }

    /// Moves the eyes by `offset` with a quick, slightly bouncy saccade; the mouth follows by 60%.
    func look(at offset: CGPoint) {
        onGlance?(offset)
        for (rig, k, stiffness) in [(eyeRig, CGFloat(1), CGFloat(420)), (mouthRig, 0.6, 340)] {
            let target = CGPoint(x: bounds.midX + offset.x * k, y: bounds.midY + offset.y * k)
            let from = rig.presentation()?.position ?? rig.position
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            rig.position = target
            CATransaction.commit()
            let a = CASpringAnimation(keyPath: "position")
            a.fromValue = NSValue(point: from)
            a.toValue = NSValue(point: target)
            a.stiffness = stiffness
            a.damping = 22
            a.duration = a.settlingDuration
            rig.add(a, forKey: "glance")
        }
    }

    func blink() {
        guard expression == .idle, !inAntic else { return } // arcs/chevrons are already "closed", busy has no eyes
        for eye in [eyeL, eyeR] { squash(eye, hold: 0, key: "blink") }
    }

    private func squash(_ eye: CALayer, hold: CFTimeInterval, key: String) {
        let a = CAKeyframeAnimation(keyPath: "transform.scale.y")
        a.values = [1, 0.1, 0.1, 1]
        let total = 0.16 + hold
        a.keyTimes = [0, NSNumber(value: 0.07 / total), NSNumber(value: (0.07 + hold) / total), 1]
        a.duration = total
        a.timingFunctions = [.init(name: .easeIn), .init(name: .linear), .init(name: .easeOut)]
        eye.add(a, forKey: key)
    }

    // MARK: Antics — little faces it pulls while you just hover

    private func scheduleAntic() {
        anticTimer = Timer.scheduledTimer(withTimeInterval: .random(in: 2.5...4.5), repeats: false) { [weak self] _ in
            guard let self else { return }
            if self.expression == .idle, !self.inAntic { self.doAntic() }
            self.scheduleAntic()
        }
    }

    private func doAntic() {
        let b = base
        switch Int.random(in: 0..<9) {
        case 0, 1:  // wink (most common), with a grin
            inAntic = true
            draw(b.l, b.r, Self.smile)
            squash(Bool.random() ? eyeL : eyeR, hold: 0.35, key: "wink")
            finishAntic(after: 0.7)
        case 2: pull(Self.bigRound, Self.bigRound, Self.oMouth, for: 1.0)                 // surprised
        case 3: pull(Self.arc, ["######"], Self.tongue, for: 1.2)                         // :P
        case 4: pull(Self.heart, Self.heart, Self.smile, for: 1.3)                        // in love
        case 5: pull(Self.star, Self.star, Self.smallSmile, for: 1.2)                     // starry-eyed
        case 6: pull(Self.uEye, Self.uEye, Self.wMouth, for: 1.2)                         // uwu
        case 7: pull(Self.lid, Self.lid, ["###"], for: 1.1); look(at: CGPoint(x: Bool.random() ? 4 : -4, y: -1)) // suspicious
        default:                                                                           // joyful hop
            pull(Self.arc, Self.arc, Self.bigSmile, for: 0.9)
            let hop = CAKeyframeAnimation(keyPath: "position.y")
            hop.values = [0, 3.5, 0, 1.5, 0]
            hop.keyTimes = [0, 0.25, 0.5, 0.72, 1]
            hop.duration = 0.6
            hop.isAdditive = true
            hop.timingFunctions = [.init(name: .easeOut), .init(name: .easeIn), .init(name: .easeOut), .init(name: .easeIn)]
            add(hop, forKey: "hop")
        }
    }

    private func pull(_ l: [String], _ r: [String], _ m: [String], for seconds: TimeInterval) {
        inAntic = true
        draw(l, r, m)
        finishAntic(after: seconds)
    }

    private func finishAntic(after seconds: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in self?.endAntic() }
    }

    private func endAntic() {
        guard inAntic else { return }
        inAntic = false
        draw(base.l, base.r, base.m)
    }

    // MARK: Processing scanner

    /// A row of pixels where a bright dot sweeps back and forth with a fading trail.
    private func buildScanner() {
        let count = 9
        let step = pixel + 1.2
        scanner.frame = CGRect(x: bounds.midX - CGFloat(count) * step / 2, y: eyeCenterY - pixel / 2, width: CGFloat(count) * step, height: pixel)
        for i in 0..<count {
            let dot = CALayer()
            dot.frame = CGRect(x: CGFloat(i) * step, y: 0, width: pixel, height: pixel)
            dot.cornerRadius = 0.5
            dot.backgroundColor = Self.glow.cgColor
            style(dot)
            dot.opacity = 0.15
            scanner.addSublayer(dot)
        }
        scanner.isHidden = true
        addSublayer(scanner)
    }

    private func setScanning(_ on: Bool) {
        scanner.isHidden = !on
        let dots = scanner.sublayers ?? []
        guard on else { dots.forEach { $0.removeAllAnimations() }; return }
        let period: CFTimeInterval = 1.1
        let now = CACurrentMediaTime()
        for (i, dot) in dots.enumerated() {
            let a = CAKeyframeAnimation(keyPath: "opacity")
            a.values = [0.15, 1, 0.15]
            a.keyTimes = [0, 0.18, 0.6]
            a.duration = period
            a.repeatCount = .infinity
            a.autoreverses = false
            // Sweep left→right then right→left: a ping-pong delay per dot.
            let k = Double(i) / Double(max(1, dots.count - 1))
            let fwd = CAAnimationGroup()
            fwd.animations = [a]
            a.beginTime = 0
            fwd.duration = period * 2
            fwd.repeatCount = .infinity
            let second = a.copy() as! CAKeyframeAnimation
            second.beginTime = period + (1 - k) * period * 0.8
            a.beginTime = k * period * 0.8
            a.repeatCount = 1
            second.repeatCount = 1
            fwd.animations = [a, second]
            fwd.beginTime = now
            dot.add(fwd, forKey: "scan")
        }
    }

    // MARK: Talking

    /// Mouth flaps open/closed while the robot "speaks" its line.
    func setTalking(_ on: Bool) {
        talkTimer?.invalidate(); talkTimer = nil
        mouthOpen = false
        setMouth(restMouth)
        guard on, expression != .ok else { return }   // the "OK" face has no mouth
        let rows = [".##.", "#..#", ".##."]
        let open = CGMutablePath()
        add(rows, centeredAt: mouthCenter(rows: rows.count), to: open, origin: .zero)
        talkTimer = Timer.scheduledTimer(withTimeInterval: 0.09, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.mouthOpen.toggle()
            self.setMouth(self.mouthOpen ? open : self.restMouth)
        }
    }

    private func setMouth(_ p: CGPath?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mouth.path = p
        CATransaction.commit()
    }

    /// Adds one pixel bitmap ("#" = lit), rows top-to-bottom, centered at `c` (in this layer's coords).
    private func add(_ rows: [String], centeredAt c: CGPoint, to path: CGMutablePath, origin: CGPoint, px: CGFloat? = nil) {
        let pixel = px ?? self.pixel
        let w = CGFloat(rows.map(\.count).max() ?? 0) * pixel
        let h = CGFloat(rows.count) * pixel
        let x0 = c.x - w / 2 - origin.x, yTop = c.y + h / 2 - origin.y
        for (ri, row) in rows.enumerated() {
            for (ci, ch) in row.enumerated() where ch == "#" {
                let r = CGRect(x: x0 + CGFloat(ci) * pixel, y: yTop - CGFloat(ri + 1) * pixel, width: pixel, height: pixel)
                path.addRoundedRect(in: r.insetBy(dx: 0.25, dy: 0.25), cornerWidth: 0.6, cornerHeight: 0.6)
            }
        }
    }

    // Big round eyes and a small cup-shaped smile, like the reference mascot.
    private static let round = [".##.", "####", "####", "####", "####", ".##."]   // tall, vertically elongated
    private static let arc = [".####.", "#....#", "#....#"]
    private static let smallSmile = ["####", ".##."]
    private static let smile = ["######", ".####."]
    private static let bigSmile = ["########", "#......#", ".######."]
    private static let bigRound = [".####.", "######", "######", "######", "######", ".####."]
    private static let oMouth = [".##.", "#..#", ".##."]
    private static let tongue = ["######", "..##..", "..##.."]
    private static let heart = [".##.##.", "#######", "#######", ".#####.", "..###..", "...#..."]
    private static let star = ["..#..", "..#..", "#####", ".###.", ".#.#."]
    private static let uEye = ["#..#", "#..#", ".##."]
    private static let wMouth = ["#.#.#", ".#.#."]
    private static let lid = ["######", "######"]
    //                              O       K
    private static let okText = [".##.  #..#",
                                 "#..#  #.#.",
                                 "#..#  ##..",
                                 "#..#  #.#.",
                                 ".##.  #..#"]
    private static let chevronRight = ["#...", ".#..", "..#.", ".#..", "#..."]
}
