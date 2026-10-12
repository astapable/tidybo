import AppKit

/// Robot diameter in icon widths.
let robotSizeInIcons: CGFloat = 2.75

struct Pose { var p: CGPoint; var a: CGFloat }

/// One step of the robot's script. `update` returns true when finished.
protocol RobotTask: AnyObject {
    func update(_ c: CleanupController, dt: CGFloat) -> Bool
}

/// Rotate in place (like a real robot vacuum), eased in and out.
final class RotateTask: RobotTask {
    private let target: CGFloat
    private var from: CGFloat?, delta: CGFloat = 0, duration: CGFloat = 0, t: CGFloat = 0
    init(to angle: CGFloat) { target = angle }
    func update(_ c: CleanupController, dt: CGFloat) -> Bool {
        if from == nil {
            from = c.pose.a
            delta = atan2(sin(target - c.pose.a), cos(target - c.pose.a))
            duration = abs(delta) < 0.01 ? 0 : 0.18 + abs(delta) / 3.4
        }
        t += dt
        let k = duration == 0 ? 1 : min(1, t / duration)
        c.pose.a = from! + delta * easeInOutCubic(k)
        return k >= 1
    }
}

/// Straight drive with a trapezoidal velocity profile: smooth acceleration, cruise, braking.
final class DriveTask: RobotTask {
    private let target: CGPoint
    private let vmax: CGFloat = 340, acc: CGFloat = 650
    private var start: CGPoint?, dist: CGFloat = 0, ta: CGFloat = 0, cruise: CGFloat = 0, t: CGFloat = 0
    init(to p: CGPoint) { target = p }
    func update(_ c: CleanupController, dt: CGFloat) -> Bool {
        if start == nil {
            start = c.pose.p
            dist = hypot(target.x - start!.x, target.y - start!.y)
            ta = min(vmax / acc, sqrt(dist / acc))
            cruise = max(0, (dist - acc * ta * ta) / (acc * ta + .ulpOfOne))
        }
        t += dt
        let total = 2 * ta + cruise
        let vpk = acc * ta
        let s: CGFloat
        if t >= total { s = dist }
        else if t < ta { s = 0.5 * acc * t * t }
        else if t < ta + cruise { s = 0.5 * acc * ta * ta + vpk * (t - ta) }
        else { let td = total - t; s = dist - 0.5 * acc * td * td }
        let k = dist == 0 ? 1 : s / dist
        c.pose.p = CGPoint(x: start!.x + (target.x - start!.x) * k, y: start!.y + (target.y - start!.y) * k)
        return t >= total
    }
}

final class WaitTask: RobotTask {
    private var left: CGFloat
    init(_ seconds: CGFloat) { left = seconds }
    func update(_ c: CleanupController, dt: CGFloat) -> Bool { left -= dt; return left <= 0 }
}

final class WaitUntilTask: RobotTask {
    private let condition: (CleanupController) -> Bool
    init(_ c: @escaping (CleanupController) -> Bool) { condition = c }
    func update(_ c: CleanupController, dt: CGFloat) -> Bool { condition(c) }
}

final class ActionTask: RobotTask {
    private let action: (CleanupController) -> Void
    init(_ a: @escaping (CleanupController) -> Void) { action = a }
    func update(_ c: CleanupController, dt: CGFloat) -> Bool { action(c); return true }
}

/// Animates one island axis in parallel; optionally blocks the script until done.
final class IslandTask: RobotTask {
    enum Axis { case widen, extend }
    private let axis: Axis, to: CGFloat, duration: CGFloat, wait: Bool
    private var started = false
    init(_ axis: Axis, to: CGFloat, duration: CGFloat, wait: Bool = true) {
        self.axis = axis; self.to = to; self.duration = duration; self.wait = wait
    }
    func update(_ c: CleanupController, dt: CGFloat) -> Bool {
        let tween = axis == .widen ? c.widen : c.extend
        if !started { started = true; tween.start(to: to, duration: duration); return !wait }
        return !tween.busy
    }
}

final class Tween {
    private(set) var value: CGFloat = 0
    private var from: CGFloat = 0, to: CGFloat = 0, t: CGFloat = 1, duration: CGFloat = 1
    private let ease: (CGFloat) -> CGFloat
    init(ease: @escaping (CGFloat) -> CGFloat) { self.ease = ease }
    var busy: Bool { t < duration }
    func start(to v: CGFloat, duration d: CGFloat) { from = value; to = v; t = 0; duration = d }
    func step(_ dt: CGFloat) {
        guard busy else { return }
        t = min(duration, t + dt)
        value = from + (to - from) * ease(t / duration)
    }
}

/// Re-reads icon positions and plans the trip to the nearest remaining icon.
final class NextIconTask: RobotTask {
    func update(_ c: CleanupController, dt: CGFloat) -> Bool { c.planNext(); return true }
}

struct CleanupResult {
    var folder: URL?
    var moved: Int
    var failed: [(name: String, reason: String)]
}

/// Drives the robot over the selected icons and (unless dry-run) moves each file into the cleanup folder
/// at the moment it is sucked in. Every move is journaled first.
final class CleanupController {
    var pose: Pose
    let widen = Tween(ease: easeOutBack)          // island grows sideways around the notch
    let extend = Tween(ease: easeInOutCubic)      // the slot slides down/up like a drawer
    private var remaining: [DesktopIcon]
    private let island: IslandWindow
    private let overlays: [OverlayWindow]
    private let journal: Journal?                 // nil = dry run, files untouched
    private var tasks: [RobotTask] = []
    private var timer: Timer?
    private var lastTick = CACurrentMediaTime()
    private var carried = true      // robot rides on the slot's floor (inside the island only)
    private let robotRadius: CGFloat
    private let images = IconImages()
    private var bumpT: CGFloat = 1  // 0…1 while the robot does a small "gulp" pulse

    /// The icon being sucked in. When the robot gets close, its file is moved and a still copy laid
    /// exactly over it; the copy starts moving only after Finder has really removed the original.
    private struct Grab {
        let icon: DesktopIcon
        var copies: [(layer: CALayer, window: OverlayWindow)]
        var failure: String?
    }
    /// Everything taken in one go: the icon the robot drove to plus neighbours under its body.
    private var grabs: [Grab] = []
    private var copies: [(layer: CALayer, window: OverlayWindow, start: CGPoint, t: CGFloat)] = []
    private var waitingGone: [String: CFTimeInterval] = [:]   // path → deadline
    private var nextGonePoll: CFTimeInterval = 0
    fileprivate var isBusyWithIcon: Bool { approaching != nil || !grabs.isEmpty || !copies.isEmpty }
    fileprivate var approaching: DesktopIcon?
    // Start while the icon is still in front of the bumper, so the wobble is visible before it goes under.
    private var approachDistance: CGFloat { robotRadius + 24 }
    private var folderAXRect: CGRect?
    private var movedCount = 0
    private var failed: [(icon: DesktopIcon, reason: String)] = []
    var onFinish: ((CleanupResult) -> Void)?

    init(icons: [DesktopIcon], overlays: [OverlayWindow], journal: Journal?) {
        let iconSize = icons.map(\.axFrame.width).max() ?? 64
        let d = (iconSize * robotSizeInIcons).rounded()
        island = IslandWindow(screen: islandScreen()!, robotDiameter: d)
        self.overlays = overlays
        self.journal = journal
        remaining = icons
        robotRadius = d / 2
        images.preload(icons, scale: islandScreen()?.backingScaleFactor ?? 2)
        pose = Pose(p: island.carriedCenter(extension: 0), a: -.pi / 2) // facing down, out of the notch
        for o in overlays { o.overlayView.installRobot(diameter: d) }
        // Slot slides out with the robot on it, robot drives off, slot slides back.
        tasks = [
            IslandTask(.widen, to: 1, duration: 0.35),
            IslandTask(.extend, to: 1, duration: 0.7),
            WaitTask(0.15),
            ActionTask { $0.setCarried(false) },
            DriveTask(to: island.exitPoint),
            IslandTask(.extend, to: 0, duration: 0.5),
            IslandTask(.widen, to: 0, duration: 0.3, wait: false),
            NextIconTask(),
        ]
    }

    // MARK: Route

    private func insertNext(_ q: [RobotTask]) { tasks.insert(contentsOf: q, at: 0) }

    fileprivate func planNext() {
        // Finder may rearrange icons (sorting, grid) as files leave: refresh positions every leg.
        let fresh = DesktopIconReader.readIcons()
        var byPath: [String: DesktopIcon] = [:]
        for i in fresh { if let p = i.path { byPath[p] = i } }
        remaining = remaining.map { i in i.path.flatMap { byPath[$0] } ?? i }
        if let folder = journal?.session.folder, let f = byPath[folder] {
            folderAXRect = f.axFrame
            overlays.forEach { $0.overlayView.setFolderBadge(rect: appKitRect(fromAX: f.axFrame), window: $0, count: movedCount, bounce: false) }
        }

        guard !remaining.isEmpty else { insertNext(returnHome()); return }
        let here = pose.p
        let i = remaining.indices.min { distance(here, center(remaining[$0])) < distance(here, center(remaining[$1])) }!
        let icon = remaining.remove(at: i)
        let p = center(icon)

        var q: [RobotTask] = [ActionTask { $0.approaching = icon }]
        var from = here
        if let w = detour(from: here, to: p) {
            q.append(RotateTask(to: atan2(w.y - from.y, w.x - from.x)))
            q.append(DriveTask(to: w))
            from = w
        }
        if distance(from, p) > 1 { q.append(RotateTask(to: atan2(p.y - from.y, p.x - from.x))) }
        q.append(DriveTask(to: p))
        q.append(ActionTask { $0.arrive() })   // in case it started close
        q.append(WaitUntilTask { !$0.isBusyWithIcon })
        q.append(WaitTask(0.1))
        q.append(NextIconTask())
        insertNext(q)
    }

    /// Steer around icons that could not be cleaned up (the robot already bumped into them once).
    private func detour(from a: CGPoint, to b: CGPoint) -> CGPoint? {
        let clearance = robotRadius + 36
        for f in failed {
            let c = center(f.icon)
            let ab = CGPoint(x: b.x - a.x, y: b.y - a.y)
            let len2 = ab.x * ab.x + ab.y * ab.y
            guard len2 > 1 else { continue }
            let t = max(0, min(1, ((c.x - a.x) * ab.x + (c.y - a.y) * ab.y) / len2))
            let closest = CGPoint(x: a.x + ab.x * t, y: a.y + ab.y * t)
            guard distance(closest, c) < clearance, t > 0.05, t < 0.95 else { continue }
            let len = sqrt(len2)
            var n = CGPoint(x: -ab.y / len, y: ab.x / len)
            if (closest.x - c.x) * n.x + (closest.y - c.y) * n.y < 0 { n = CGPoint(x: -n.x, y: -n.y) }
            return CGPoint(x: c.x + n.x * (clearance + 12), y: c.y + n.y * (clearance + 12))
        }
        return nil
    }

    /// Empty slot slides out to meet the robot, robot drives in, slot slides back up with it.
    private func returnHome() -> [RobotTask] {
        let exit = island.exitPoint
        var q: [RobotTask] = []
        if let w = detour(from: pose.p, to: exit) {
            q.append(RotateTask(to: atan2(w.y - pose.p.y, w.x - pose.p.x)))
            q.append(DriveTask(to: w))
            q.append(ActionTask { c in c.insertNext([RotateTask(to: atan2(exit.y - c.pose.p.y, exit.x - c.pose.p.x))]) })
        } else {
            q.append(RotateTask(to: atan2(exit.y - pose.p.y, exit.x - pose.p.x)))
        }
        q += [
            IslandTask(.widen, to: 1, duration: 0.35, wait: false),
            DriveTask(to: exit),
            IslandTask(.extend, to: 1, duration: 0.5),
            RotateTask(to: .pi / 2),
            DriveTask(to: island.carriedCenter(extension: 1)),
            ActionTask { $0.setCarried(true) },
            WaitTask(0.15),
            IslandTask(.extend, to: 0, duration: 0.7),
            IslandTask(.widen, to: 0, duration: 0.3),
        ]
        return q
    }

    func start() {
        island.show()
        overlays.forEach { $0.orderFrontRegardless() }
        render()
        lastTick = CACurrentMediaTime()
        let t = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = CGFloat(min(now - lastTick, 1.0 / 30))
        lastTick = now

        widen.step(dt)
        extend.step(dt)
        island.setShape(widen: widen.value, extension: extend.value)
        // Run finished tasks back-to-back within a frame; stop at the first one still in progress.
        // Tasks may insert new tasks at the front, so remove the finished one by identity.
        while let task = tasks.first, task.update(self, dt: dt) {
            if let i = tasks.firstIndex(where: { $0 === task }) { tasks.remove(at: i) }
        }
        if carried { pose.p = island.carriedCenter(extension: extend.value) }
        bumpT = min(1, bumpT + dt / 0.22)
        if let icon = approaching, distance(pose.p, center(icon)) <= approachDistance { arrive() }
        if !grabs.isEmpty { suckWhenReady() }
        updateCopies(dt)
        pollGone(now)
        render()
        if tasks.isEmpty && !widen.busy && !extend.busy { finish() }
    }

    /// Carried: robot exists only inside the island (clipped by it). Otherwise it is also on the desktop.
    fileprivate func setCarried(_ c: Bool) {
        carried = c
        overlays.forEach { $0.overlayView.robot?.isHidden = c }
        island.robots.forEach { $0.setBrushSpinning(!c) }
        overlays.forEach { $0.overlayView.robot?.setBrushSpinning(!c) }
        if !c {
            for o in overlays {
                let r = o.overlayView.robot
                print("Robot on desktop: window visible=\(o.isVisible) onActiveSpace=\(o.isOnActiveSpace) level=\(o.level.rawValue) robot=\(r != nil) attached=\(r?.superlayer != nil) hidden=\(r?.isHidden ?? true)")
            }
        }
    }

    /// Every copy of the robot (island + desktop overlays) shows the same display.
    private var robots: [RobotLayer] {
        island.robots + overlays.compactMap { $0.overlayView.robot }
    }

    private func render() {
        island.placeRobot(at: pose.p, angle: pose.a)
        guard !carried else { return }
        let gulp = 1 + 0.05 * sin(.pi * bumpT)
        for o in overlays {
            let origin = o.frame.origin
            o.overlayView.robot?.place(at: CGPoint(x: pose.p.x - origin.x, y: pose.p.y - origin.y), angle: pose.a, scale: gulp)
        }
    }

    // MARK: Suction + move

    private func center(_ icon: DesktopIcon) -> CGPoint {
        let r = appKitRect(fromAX: icon.axFrame)
        return CGPoint(x: r.midX, y: r.midY)
    }

    /// Robot reached the icon: move the file and cover the icon with a copy (or stumble on failure).
    fileprivate func arrive() {
        guard let icon = approaching else { return }
        approaching = nil
        // Neighbours lying under the robot's body go in the same gulp.
        let c = center(icon)
        let near = remaining.filter { distance(center($0), c) < robotRadius * 0.85 }
        remaining.removeAll { r in near.contains { $0.path == r.path } }
        for i in [icon] + near { grab(i) }
    }

    /// Moves the real file and covers its (soon to vanish) icon with an identical,
    /// still-selected-looking copy.
    private func grab(_ icon: DesktopIcon) {
        var g = Grab(icon: icon, copies: [], failure: nil)
        defer { grabs.append(g) }
        if let journal, let path = icon.path, let idx = journal.session.items.firstIndex(where: { $0.source == path }) {
            let dest = journal.session.items[idx].destination
            do {
                try FileMover.move(path, to: dest)
                journal.update { $0.items[idx].status = .moved }
                movedCount += 1
                waitingGone[path] = CACurrentMediaTime() + 3
                nextGonePoll = CACurrentMediaTime() + 0.15
                print("Moved: \(path) → \(dest)")
            } catch {
                let reason = (error as NSError).localizedDescription
                journal.update { $0.items[idx].status = .failed; $0.items[idx].error = reason }
                print("FAILED: \(path): \(reason)")
                g.failure = reason
                return
            }
        }
        let c = center(icon)
        let image = images.image(for: icon)
        for o in overlays where o.frame.intersects(appKitRect(fromAX: icon.axFrame)) {
            let copy = makeIconCopy(icon, image: image, scale: o.backingScaleFactor, selected: icon.isSelected)
            o.overlayView.addIconCopy(copy, at: CGPoint(x: c.x - o.frame.minX, y: c.y - o.frame.minY))
            g.copies.append((copy, o))
        }
    }

    /// Robot is at the icon: stumble if the move failed; otherwise start the suction once Finder
    /// has really removed the original (waits at most until the 3 s deadline set in `grab`).
    private func suckWhenReady() {
        guard !grabs.isEmpty, waitingGone.isEmpty else { return }
        let taken = grabs.filter { $0.failure == nil }
        let failures = grabs.filter { $0.failure != nil }
        grabs = []
        for g in taken {
            let c = center(g.icon)
            for (layer, window) in g.copies {
                animateSuction(layer)
                copies.append((layer, window, c, 0))
            }
        }
        if !taken.isEmpty { robots.forEach { $0.display.showReceive(count: taken.count) } }
        if let first = failures.first {
            failures.dropFirst().forEach { failed.append(($0.icon, $0.failure!)) }
            stumble(on: first.icon, reason: first.failure!)
        }
    }

    /// The file could not be moved: the robot bumps into the icon, backs off, shakes its head,
    /// and later routes around it.
    private func stumble(on icon: DesktopIcon, reason: String) {
        failed.append((icon, reason))
        // Drop the rest of this icon's plan (up to the next NextIconTask), keep the remainder.
        if let next = tasks.firstIndex(where: { $0 is NextIconTask }) { tasks.removeSubrange(0..<next) }
        let a = pose.a
        let back = CGPoint(x: pose.p.x - cos(a) * 36, y: pose.p.y - sin(a) * 36)
        insertNext([WaitTask(0.08), DriveTask(to: back), RotateTask(to: a + 0.35), RotateTask(to: a - 0.35), RotateTask(to: a), WaitTask(0.15)])
        bumpT = 0
        robots.forEach { $0.display.showError() }
        let r = appKitRect(fromAX: icon.axFrame)
        overlays.forEach { $0.overlayView.flashFailure(rect: r, window: $0) }
    }

    /// Before driving on, make sure Finder really removed the icon (it can lag a bit).
    private func pollGone(_ now: CFTimeInterval) {
        guard !waitingGone.isEmpty, now >= nextGonePoll else { return }
        let shown = Set(DesktopIconReader.readIcons().compactMap(\.path))
        for (path, deadline) in waitingGone {
            if !shown.contains(path) {
                waitingGone[path] = nil
            } else if now >= deadline {
                print("Warning: Finder still shows \(path) after 3 s, continuing")
                waitingGone[path] = nil
            }
        }
        nextGonePoll = now + 0.15
    }

    private func updateCopies(_ dt: CGFloat) {
        guard !copies.isEmpty else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for i in copies.indices {
            copies[i].t += dt
            let k = min(1, copies[i].t / CGFloat(suctionDuration))
            // Stays put while it wobbles, then accelerates into the (possibly still moving) robot center.
            let pull = k < 0.3 ? 0 : easeInCubic((k - 0.3) / 0.7)
            let s = copies[i].start, w = copies[i].window.frame.origin
            copies[i].layer.position = CGPoint(x: s.x + (pose.p.x - s.x) * pull - w.x, y: s.y + (pose.p.y - s.y) * pull - w.y)
        }
        CATransaction.commit()
        let done = copies.filter { $0.t >= CGFloat(suctionDuration) }
        if !done.isEmpty {
            done.forEach { $0.layer.removeFromSuperlayer() }
            copies.removeAll { $0.t >= CGFloat(suctionDuration) }
            bumpT = 0   // gulp
            if let f = folderAXRect, journal != nil {
                overlays.forEach { $0.overlayView.setFolderBadge(rect: appKitRect(fromAX: f), window: $0, count: movedCount, bounce: true) }
            }
        }
    }

    private func finish() {
        timer?.invalidate(); timer = nil
        island.hide()
        journal?.update { $0.state = .done }
        let result = CleanupResult(folder: journal.map { URL(fileURLWithPath: $0.session.folder) },
                                   moved: movedCount,
                                   failed: failed.map { ($0.icon.name, $0.reason) })
        // Detach this run's robot and badge right away (so a new run starts clean), but keep the
        // badge on screen a moment so the final count is visible.
        overlays.forEach { $0.overlayView.retireRun(badgeDelay: 1.2) }
        onFinish?(result)
    }
}

func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

func easeInCubic(_ t: CGFloat) -> CGFloat { t * t * t }
func easeInOutCubic(_ t: CGFloat) -> CGFloat { t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2 }
func easeOutBack(_ t: CGFloat) -> CGFloat {
    let c1: CGFloat = 1.4, c3 = c1 + 1
    return 1 + c3 * pow(t - 1, 3) + c1 * pow(t - 1, 2)
}
