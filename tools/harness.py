# Makes a test copy of main.swift: removes the notification-permission prompt and appends helper
# functions plus the `steps` from a steps file, run on a timer after launch. Used by tools/test.sh.
# usage: python3 harness.py <outdir> <steps.swift>
import sys

out, steps_file = sys.argv[1], sys.argv[2]
steps = open(steps_file).read()
s = open(sys.path[0] + '/../main.swift').read()

# these lines must stay as they are in main.swift (the test copy can't ask for notification permission)
for old, new in [
    ('UNUserNotificationCenter.current().delegate = self', ''),
    ('UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in',
     '_ = { (granted: Bool, error: Error?) in'),
]:
    assert old in s, 'harness.py: main.swift changed, update the patch for: ' + old
    s = s.replace(old, new)

marker = "UserDefaults.standard.register(defaults: [Setting.restoreTabs: true])"
assert marker in s, 'harness.py: main.swift changed, update the marker'

helpers = '''
// ---- test helpers (tools/harness.py) ----
func log(_ line: String) {
    let url = URL(fileURLWithPath: "%(out)s/test.log")
    let old = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    try? (old + line + "\\n").write(to: url, atomically: true, encoding: .utf8)
}
// Window snapshot (own window, no Screen Recording permission). Glass (selected tab, toolbar buttons)
// renders as white shapes; text and outlines are accurate.
@MainActor func snap(_ window: NSWindow?, _ name: String) {
    guard let v = window?.contentView?.superview, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
    v.cacheDisplay(in: v.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "%(out)s/\\(name).png"))
}
@MainActor func selectedWindow() -> NSWindow? { App.shared.tabs.first?.window?.tabGroup?.selectedWindow }
@MainActor func tabButtons() -> [NSView] {
    guard let w0 = App.shared.tabs.first?.window, let frameView = (w0.tabGroup?.selectedWindow ?? w0).contentView?.superview else { return [] }
    func find(_ v: NSView) -> [NSView] { String(describing: type(of: v)) == "NSTabButton" ? [v] : v.subviews.flatMap(find) }
    return find(frameView).sorted { $0.frame.minX < $1.frame.minX }
}
@MainActor func widths() -> String { tabButtons().map { "\\(Int($0.frame.width))" }.joined(separator: ", ") }
// Tab bar order: pinned as [icon], others by their URL query (use https://example.com/?name pages), [selected]
@MainActor func bar() -> String {
    guard let w = App.shared.tabs.first?.window else { return "-" }
    let selected = w.tabGroup?.selectedWindow
    return (w.tabbedWindows ?? [w]).compactMap { win in App.shared.tabs.first { $0.window === win } }
        .map { t in
            let label = t.pinned.map { "pin:\\($0.shownIcon)" } ?? (t.webView.url?.query ?? "home")
            return t.window === selected ? "[\\(label)]" : label
        }.joined(separator: " ")
}
@MainActor func tab(_ query: String) -> Tab? { App.shared.tabs.first { ($0.webView.url?.query ?? "home") == query } }
// A real mouse click on a page element (WebKit treats script clicks differently: no popups, no downloads)
@MainActor func realClick(_ elementID: String, in web: WKWebView) {
    web.evaluateJavaScript("(r => [r.x + r.width / 2, r.y + r.height / 2])(document.getElementById('\\(elementID)').getBoundingClientRect())") { result, _ in
        MainActor.assumeIsolated {
            guard let xy = result as? [Double], let window = web.window else { return log("realClick: no #\\(elementID)") }
            let p = web.convert(NSPoint(x: xy[0], y: web.isFlipped ? xy[1] : web.bounds.height - xy[1]), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                window.sendEvent(NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
            }
        }
    }
}
''' % {'out': out}

run = '\nfor (t, f) in steps { DispatchQueue.main.asyncAfter(deadline: .now() + t) { MainActor.assumeIsolated { f() } } }\n'
s = s.replace(marker, marker + '\n' + helpers + '\n' + steps + run)
open(out + '/main.swift', 'w').write(s)
