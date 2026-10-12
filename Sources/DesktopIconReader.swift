import AppKit
import ApplicationServices

/// One desktop icon as reported by Finder's Accessibility tree.
struct DesktopIcon {
    let name: String          // AXTitle (what Finder displays; may lack extension, ":" shown as "/")
    let axFrame: CGRect       // global AX coords: origin top-left of the primary screen, y down
    let isSelected: Bool
    let path: String?         // resolved real file path, nil if it could not be resolved
}

/// Read-only access to the Finder desktop icons.
///
/// Structure found in step 1 (macOS 26):
///   AXApplication "Finder"
///     AXScrollArea (desc = localized "desktop")   ← direct child of the app, not inside an AXWindow
///       AXGroup (has AXSelectedChildren)
///         AXImage × N  (AXTitle, AXFilename, AXURL, AXPosition, AXSize, AXSelected)
enum DesktopIconReader {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func readIcons() -> [DesktopIcon] {
        guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first
        else { return [] }
        let app = AXUIElementCreateApplication(finder.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 1)

        var icons: [DesktopIcon] = []
        // There may be one desktop scroll area per display; take every scroll area that is a direct app child.
        for area in children(app) where role(area) == kAXScrollAreaRole as String {
            for group in children(area) where role(group) == kAXGroupRole as String {
                for item in children(group) where role(item) == kAXImageRole as String {
                    if let icon = makeIcon(item) { icons.append(icon) }
                }
            }
        }
        return icons
    }

    /// Only real files/folders that live directly in a Desktop folder; no disks, volumes or servers.
    static func isCleanable(_ icon: DesktopIcon) -> Bool {
        guard let path = icon.path else { return false }
        let url = URL(fileURLWithPath: path)
        let v = try? url.resourceValues(forKeys: [.isVolumeKey])
        if v?.isVolume == true { return false }
        return url.deletingLastPathComponent().lastPathComponent == "Desktop"
    }

    private static func makeIcon(_ e: AXUIElement) -> DesktopIcon? {
        let attrs = [kAXTitleAttribute, kAXPositionAttribute, kAXSizeAttribute,
                     kAXSelectedAttribute, kAXURLAttribute, "AXFilename"] as CFArray
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(e, attrs, AXCopyMultipleAttributeOptions(), &values) == .success,
              let v = values as? [AnyObject], v.count == 6 else { return nil }

        guard let pos = point(v[1]), let size = size(v[2]) else { return nil }
        let title = (v[0] as? String) ?? (v[5] as? String) ?? "?"
        let selected = (v[3] as? Bool) ?? false
        return DesktopIcon(name: title,
                           axFrame: CGRect(origin: pos, size: size),
                           isSelected: selected,
                           path: resolvePath(url: v[4], displayName: title))
    }

    /// AXURL is a file *reference* URL (file:///.file/id=…), which survives hidden extensions and
    /// the ":"↔"/" display swap. Fall back to ~/Desktop/<name> only if it is missing.
    private static func resolvePath(url: AnyObject, displayName: String) -> String? {
        if let u = url as? URL, let resolved = (u as NSURL).filePathURL { return resolved.path }
        let guess = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop")
            .appendingPathComponent(displayName.replacingOccurrences(of: "/", with: ":"))
        return FileManager.default.fileExists(atPath: guess.path) ? guess.path : nil
    }

    // MARK: AX helpers

    private static func attr(_ e: AXUIElement, _ name: String) -> AnyObject? {
        var v: AnyObject?
        return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
    }
    private static func role(_ e: AXUIElement) -> String? { attr(e, kAXRoleAttribute) as? String }
    private static func children(_ e: AXUIElement) -> [AXUIElement] {
        (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }
    private static func point(_ obj: AnyObject) -> CGPoint? {
        guard CFGetTypeID(obj) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(obj as! AXValue, .cgPoint, &p) ? p : nil
    }
    private static func size(_ obj: AnyObject) -> CGSize? {
        guard CFGetTypeID(obj) == AXValueGetTypeID() else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(obj as! AXValue, .cgSize, &s) ? s : nil
    }
}

/// AX/CG global coordinates: origin at top-left of the primary screen, y grows down.
/// AppKit global coordinates: origin at bottom-left of the primary screen, y grows up.
/// The primary screen (NSScreen.screens[0]) is the one whose AppKit frame origin is (0,0);
/// screens left of / above it simply have negative x / larger y — the flip is the same for all.
func appKitRect(fromAX r: CGRect) -> CGRect {
    let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
    return CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
}
