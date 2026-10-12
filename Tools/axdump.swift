// axdump — recursively prints Finder's Accessibility tree (read-only).
// Usage: axdump [maxDepth] [maxChildrenPerNode]
import AppKit
import ApplicationServices

let args = CommandLine.arguments
let maxDepth = args.count > 1 ? Int(args[1]) ?? 8 : 8
let maxChildren = args.count > 2 ? Int(args[2]) ?? 200 : 200

guard AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary) else {
    print("NO ACCESSIBILITY PERMISSION for the host process (terminal). Grant it in System Settings → Privacy & Security → Accessibility, then re-run.")
    exit(1)
}
guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else {
    print("Finder not running"); exit(1)
}
let app = AXUIElementCreateApplication(finder.processIdentifier)
AXUIElementSetMessagingTimeout(app, 3)

func attr(_ e: AXUIElement, _ name: String) -> AnyObject? {
    var v: AnyObject?
    return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
}
func str(_ e: AXUIElement, _ n: String) -> String? { attr(e, n) as? String }
func point(_ e: AXUIElement) -> CGPoint? {
    guard let v = attr(e, kAXPositionAttribute), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
    var p = CGPoint.zero; AXValueGetValue(v as! AXValue, .cgPoint, &p); return p
}
func size(_ e: AXUIElement) -> CGSize? {
    guard let v = attr(e, kAXSizeAttribute), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
    var s = CGSize.zero; AXValueGetValue(v as! AXValue, .cgSize, &s); return s
}
func names(_ e: AXUIElement) -> [String] {
    var a: CFArray?; AXUIElementCopyAttributeNames(e, &a); return (a as? [String]) ?? []
}

func dump(_ e: AXUIElement, _ depth: Int) {
    let ind = String(repeating: "  ", count: depth)
    var parts = [str(e, kAXRoleAttribute) ?? "?"]
    if let s = str(e, kAXSubroleAttribute) { parts.append("sub=\(s)") }
    if let t = str(e, kAXTitleAttribute), !t.isEmpty { parts.append("title=\"\(t)\"") }
    if let d = str(e, kAXDescriptionAttribute), !d.isEmpty { parts.append("desc=\"\(d)\"") }
    if let i = str(e, kAXIdentifierAttribute), !i.isEmpty { parts.append("id=\(i)") }
    if let f = str(e, "AXFilename") { parts.append("filename=\"\(f)\"") }
    if let u = attr(e, kAXURLAttribute) { parts.append("url=\(u)") }
    if let p = point(e) { parts.append("pos=(\(Int(p.x)),\(Int(p.y)))") }
    if let s = size(e) { parts.append("size=\(Int(s.width))x\(Int(s.height))") }
    if let sel = attr(e, kAXSelectedAttribute) as? Bool { parts.append("selected=\(sel)") }
    if let sc = attr(e, kAXSelectedChildrenAttribute) as? [AXUIElement] { parts.append("selectedChildren=\(sc.count)") }
    let children = (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    parts.append("children=\(children.count)")
    if depth <= 3 { parts.append("attrs=[\(names(e).joined(separator: ","))]") }
    print(ind + parts.joined(separator: " "))
    guard depth < maxDepth else { return }
    for c in children.prefix(maxChildren) { dump(c, depth + 1) }
    if children.count > maxChildren { print(ind + "  … \(children.count - maxChildren) more") }
}

print("Screens (NSScreen, AppKit coords):")
for s in NSScreen.screens { print("  \(s.localizedName) frame=\(s.frame) scale=\(s.backingScaleFactor)") }
print("Finder pid=\(finder.processIdentifier)\n")
dump(app, 0)
