import AppKit

/// Old-school JRPG dialog box spoken by the robot: double light border, a tail pointing down at the
/// speaker, text revealed letter by letter, and a blinking ▼ when the line is complete.
/// Anchored at the tail's tip (bottom center), so scaling makes it pop out of the robot.
final class SpeechBubble: CALayer {
    var onTalking: ((Bool) -> Void)?

    private let box = CALayer()
    private let innerBorder = CALayer()
    private let tail = CAShapeLayer()
    private let tailJoint = CALayer()       // hides the box border where the tail joins it
    private let text = CATextLayer()
    private let cursor = CATextLayer()
    private var message = NSAttributedString()
    private var shown = 0
    private var typer: Timer?

    private let padX: CGFloat = 14, padY: CGFloat = 9, tailH: CGFloat = 9
    private let charDelay: TimeInterval = 0.032
    static let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold)
    static let boldFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .heavy)

    override init() {
        super.init()
        anchorPoint = CGPoint(x: 0.5, y: 0)
        let fill = NSColor(white: 0.04, alpha: 0.94).cgColor
        let line = NSColor(white: 1, alpha: 0.22).cgColor   // quiet frame: the text is the point

        tail.fillColor = fill
        tail.strokeColor = line
        tail.lineWidth = 1
        tail.lineJoin = .round
        addSublayer(tail)

        box.backgroundColor = fill
        box.borderColor = line
        box.borderWidth = 1
        box.cornerRadius = 7
        box.cornerCurve = .continuous
        box.shadowColor = NSColor.black.cgColor
        box.shadowOpacity = 0.35
        box.shadowRadius = 6
        box.shadowOffset = CGSize(width: 0, height: -2)
        addSublayer(box)

        innerBorder.borderColor = NSColor(white: 1, alpha: 0.07).cgColor
        innerBorder.borderWidth = 1
        innerBorder.cornerRadius = 4
        box.addSublayer(innerBorder)

        tailJoint.backgroundColor = fill
        addSublayer(tailJoint)

        for t in [text, cursor] {
            t.contentsScale = 2
            t.alignmentMode = .left
            box.addSublayer(t)
        }
        cursor.string = NSAttributedString(string: "▼", attributes: [.font: NSFont.systemFont(ofSize: 8), .foregroundColor: NSColor.white])
        cursor.opacity = 0
    }
    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }

    /// Sets the line; the box is sized for the whole line up front (like an RPG text box).
    func setMessage(_ raw: NSAttributedString, typeNow: Bool) {
        let m = Self.wrapped(raw, maxWidth: maxLineWidth)
        guard m != message else { return }
        message = m
        let size = m.boundingRect(with: CGSize(width: 600, height: 100), options: [.usesLineFragmentOrigin]).size
        let w = ceil(size.width) + padX * 2 + 10, h = ceil(size.height) + padY * 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bounds = CGRect(x: 0, y: 0, width: w, height: h + tailH)
        box.frame = CGRect(x: 0, y: tailH, width: w, height: h)
        innerBorder.frame = box.bounds.insetBy(dx: 3, dy: 3)
        text.frame = CGRect(x: padX, y: padY - 1, width: ceil(size.width) + 4, height: ceil(size.height) + 2)
        cursor.frame = CGRect(x: w - padX - 2, y: padY - 2, width: 10, height: 10)
        let p = CGMutablePath()
        p.move(to: CGPoint(x: w / 2 - 7, y: tailH + 1))
        p.addLine(to: CGPoint(x: w / 2, y: 1))
        p.addLine(to: CGPoint(x: w / 2 + 7, y: tailH + 1))
        tail.path = p
        tailJoint.frame = CGRect(x: w / 2 - 6, y: tailH - 0.5, width: 12, height: 2)
        CATransaction.commit()
        if typeNow { startTyping() } else { reset() }
    }

    private let maxLineWidth: CGFloat = 230

    /// Pre-breaks lines at spaces (greedy), so words never jump to the next line mid-typing.
    static func wrapped(_ m: NSAttributedString, maxWidth: CGFloat) -> NSAttributedString {
        let out = NSMutableAttributedString(attributedString: m)
        let ns = m.string as NSString
        var lineStart = 0, lastSpace: Int?
        var i = 0
        while i < ns.length {
            let ch = ns.character(at: i)
            if ch == 0x0A { lineStart = i + 1; lastSpace = nil; i += 1; continue }
            if ch == 0x20 { lastSpace = i }
            let width = out.attributedSubstring(from: NSRange(location: lineStart, length: i - lineStart + 1)).size().width
            if width > maxWidth, let sp = lastSpace, sp > lineStart {
                out.replaceCharacters(in: NSRange(location: sp, length: 1), with: "\n")
                lineStart = sp + 1
                lastSpace = nil
            }
            i += 1
        }
        return out
    }

    func startTyping() {
        reset()
        onTalking?(true)
        typeNext()
    }

    /// Clears the text (box stays sized) and stops typing.
    func reset() {
        typer?.invalidate(); typer = nil
        shown = 0
        render()
        cursor.removeAllAnimations()
        cursor.opacity = 0
        onTalking?(false)
    }

    private func typeNext() {
        guard shown < message.length else { finished(); return }
        shown += 1
        render()
        let ch = (message.string as NSString).substring(with: NSRange(location: shown - 1, length: 1))
        let pause: TimeInterval = ",".contains(ch) ? 0.12 : ".!?…".contains(ch) ? 0.22 : 0
        typer = Timer.scheduledTimer(withTimeInterval: charDelay + pause, repeats: false) { [weak self] _ in self?.typeNext() }
    }

    private func render() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        text.string = message.attributedSubstring(from: NSRange(location: 0, length: min(shown, message.length)))
        CATransaction.commit()
    }

    private func finished() {
        typer = nil
        onTalking?(false)
        cursor.opacity = 1
        let blink = CAKeyframeAnimation(keyPath: "opacity")
        blink.values = [1, 1, 0, 0]
        blink.keyTimes = [0, 0.5, 0.5, 1]
        blink.duration = 0.9
        blink.repeatCount = .infinity
        cursor.add(blink, forKey: "blink")
    }
}
