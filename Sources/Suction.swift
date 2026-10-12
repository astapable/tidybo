import AppKit
import QuickLookThumbnailing

/// Icon images for the copies, looked like Finder draws them: Quick Look icon-style thumbnails
/// (image previews etc.), falling back to the plain workspace icon.
final class IconImages {
    private var images: [String: NSImage] = [:]

    func preload(_ icons: [DesktopIcon], scale: CGFloat) {
        for icon in icons {
            guard let path = icon.path else { continue }
            images[path] = NSWorkspace.shared.icon(forFile: path)
            let req = QLThumbnailGenerator.Request(fileAt: URL(fileURLWithPath: path), size: icon.axFrame.size,
                                                   scale: scale, representationTypes: .icon)
            QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { [weak self] rep, _ in
                guard let rep else { return }
                DispatchQueue.main.async { self?.images[path] = rep.nsImage }
            }
        }
    }

    func image(for icon: DesktopIcon) -> NSImage {
        icon.path.flatMap { images[$0] } ?? NSWorkspace.shared.icon(for: .data)
    }
}

/// A copy of a desktop icon (image + label) placed exactly over the real one.
/// Anchored at the icon center so it scales around it.
func makeIconCopy(_ icon: DesktopIcon, image: NSImage, scale: CGFloat, selected: Bool) -> CALayer {
    let size = icon.axFrame.size
    let copy = CALayer()
    copy.bounds = CGRect(origin: .zero, size: size)
    copy.contentsScale = scale

    // Finder's selection look: translucent rounded box behind the image.
    if selected {
        let box = CALayer()
        box.frame = copy.bounds.insetBy(dx: -4, dy: -4)
        box.backgroundColor = NSColor.black.withAlphaComponent(0.28).cgColor
        box.borderColor = NSColor.white.withAlphaComponent(0.25).cgColor
        box.borderWidth = 1
        box.cornerRadius = 6
        box.cornerCurve = .continuous
        box.name = "selection"
        copy.addSublayer(box)
    }

    let img = CALayer()
    img.frame = copy.bounds
    img.contents = image
    img.contentsGravity = .resizeAspect
    img.contentsScale = scale
    copy.addSublayer(img)

    // Finder draws the name under the icon: up to 2 lines, white with a soft shadow.
    let labelWidth = max(size.width + 40, 104)
    let text = NSAttributedString(string: icon.name, attributes: [
        .font: NSFont.systemFont(ofSize: 12, weight: .medium),
        .foregroundColor: NSColor.white,
    ])
    // Selected names sit on an accent-colored plate.
    if selected {
        let fit = text.boundingRect(with: CGSize(width: labelWidth, height: 31), options: [.usesLineFragmentOrigin])
        let plate = CALayer()
        let w = min(labelWidth, ceil(fit.width) + 8), h = min(31, ceil(fit.height) + 2)
        plate.frame = CGRect(x: (size.width - w) / 2, y: -3 - h, width: w, height: h)
        plate.backgroundColor = NSColor.selectedContentBackgroundColor.cgColor
        plate.cornerRadius = 4
        plate.cornerCurve = .continuous
        plate.name = "selection"
        copy.addSublayer(plate)
    }
    let label = CATextLayer()
    label.string = text
    label.isWrapped = true
    label.truncationMode = .middle
    label.alignmentMode = .center
    label.contentsScale = scale
    label.frame = CGRect(x: (size.width - labelWidth) / 2, y: -34, width: labelWidth, height: 31)
    label.shadowColor = NSColor.black.cgColor
    label.shadowOpacity = 0.8
    label.shadowRadius = 2
    label.shadowOffset = CGSize(width: 0, height: -1)
    label.name = "label"
    copy.addSublayer(label)
    return copy
}

/// Springy wobble and shrink; the position is driven per frame by the controller
/// (the copy follows the moving robot into its center). Total = `suctionDuration`.
let suctionDuration: CFTimeInterval = 0.75

func animateSuction(_ copy: CALayer) {
    // The selection highlight melts away first, as if the robot "took" the item out of the selection.
    for sel in copy.sublayers?.filter({ $0.name == "selection" }) ?? [] {
        let f = CABasicAnimation(keyPath: "opacity")
        f.fromValue = 1
        f.toValue = 0
        f.duration = suctionDuration * 0.25
        f.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1)
        f.fillMode = .forwards
        f.isRemovedOnCompletion = false
        sel.add(f, forKey: "fade")
    }
    let scale = CAKeyframeAnimation(keyPath: "transform.scale")
    scale.values = [1, 1.16, 0.9, 1.05, 0.08]
    scale.keyTimes = [0, 0.18, 0.32, 0.45, 1]
    scale.timingFunctions = [.init(name: .easeOut), .init(name: .easeInEaseOut), .init(name: .easeInEaseOut), .init(name: .easeIn)]

    let wobble = CAKeyframeAnimation(keyPath: "transform.rotation.z")
    wobble.values = [0, 0.08, -0.06, 0.03, 0.5]
    wobble.keyTimes = [0, 0.18, 0.32, 0.45, 1]

    let fade = CAKeyframeAnimation(keyPath: "opacity")
    fade.values = [1, 1, 0]
    fade.keyTimes = [0, 0.82, 1]

    let group = CAAnimationGroup()
    group.animations = [scale, wobble, fade]
    group.duration = suctionDuration
    group.fillMode = .forwards
    group.isRemovedOnCompletion = false
    copy.add(group, forKey: "suck")

    // The name follows the icon like a tail: it holds while the icon wobbles, then is pulled
    // into the icon's center (slightly behind it), shrinking, and fades at the very end.
    if let label = copy.sublayers?.first(where: { $0.name == "label" }) {
        let c = CGPoint(x: copy.bounds.midX, y: copy.bounds.midY)
        let tailMove = CAKeyframeAnimation(keyPath: "position")
        tailMove.values = [label.position, label.position, c].map { NSValue(point: $0) }
        tailMove.keyTimes = [0, 0.38, 1]
        tailMove.timingFunctions = [.init(name: .linear), .init(name: .easeIn)]
        let tailScale = CAKeyframeAnimation(keyPath: "transform.scale")
        tailScale.values = [1, 1, 0.25]
        tailScale.keyTimes = [0, 0.38, 1]
        let tailFade = CAKeyframeAnimation(keyPath: "opacity")
        tailFade.values = [1, 1, 0]
        tailFade.keyTimes = [0, 0.75, 1]
        let tail = CAAnimationGroup()
        tail.animations = [tailMove, tailScale, tailFade]
        tail.duration = suctionDuration
        tail.fillMode = .forwards
        tail.isRemovedOnCompletion = false
        label.add(tail, forKey: "tail")
    }
}
