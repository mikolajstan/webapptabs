// Link Router — set as the default browser: a link for a site that has a "Tabs" app opens there,
// everything else goes on to the browser chosen in its window (Safari unless changed; Safari still sends links
// to its own web apps as before). Started by itself (Finder, Spotlight), it shows that window.
import Cocoa

let browserKey = "fallbackBrowser"   // bundle ID of the browser for all other links
let defaultBrowser = "com.apple.Safari"

@MainActor
final class Router: NSObject, NSApplicationDelegate {
    // the chosen browser, or Safari if it's gone (uninstalled)
    var browser: URL? {
        let chosen = UserDefaults.standard.string(forKey: browserKey) ?? defaultBrowser
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: chosen)
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: defaultBrowser)
    }

    private var openedLinks = false
    func application(_ application: NSApplication, open urls: [URL]) {
        openedLinks = true
        let apps = tabApps()
        for url in urls {
            let (link, app) = resolve(url, apps)
            guard let target = app ?? browser else { continue }
            NSWorkspace.shared.open([link], withApplicationAt: target, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    // Started to open a link, the links arrive right after launch; started by itself, none do → the window
    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if !self.openedLinks { SettingsWindow.shared.show(router: self) }
        }
    }
    // started again while running (e.g. from Finder)
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        SettingsWindow.shared.show(router: self)
        return true
    }

    // Gmail, Messenger, Outlook etc. wrap links in a redirect (google.com/url?q=<link>), so also look
    // inside the query for a link to a Tabs app. Anything else is passed on untouched.
    func resolve(_ url: URL, _ apps: [String: URL]) -> (URL, URL?) {
        if let app = url.host.flatMap({ apps[$0] }) { return (url, app) }
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
            if let inner = item.value.flatMap(URL.init(string:)), inner.scheme?.hasPrefix("http") == true,
               let app = inner.host.flatMap({ apps[$0] }) {
                return (inner, app)
            }
        }
        return (url, nil)
    }

    // host → app, read from every app made by make-app.sh, so new Tabs apps are picked up automatically
    func tabApps() -> [String: URL] {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
        var result: [String: URL] = [:]
        for app in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
            guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
                  let id = info["CFBundleIdentifier"] as? String, id.hasPrefix("local.webapptabs."),
                  // the app's own Home Page setting wins over the address it was built with
                  let home = (UserDefaults(suiteName: id)?.string(forKey: "homeURL") ?? info["WebAppURL"] as? String)
                      .flatMap(URL.init(string:)),
                  let host = home.host else { continue }
            result[host] = app
        }
        return result
    }

    // Browsers that can take the other links: every app that opens https links, except Link Router and the
    // Tabs apps (they only take their own site)
    func browsers() -> [(id: String, name: String, url: URL)] {
        let candidates = NSWorkspace.shared.urlsForApplications(toOpen: URL(string: "https://example.com")!)
        var seen = Set<String>(), result: [(id: String, name: String, url: URL)] = []
        for url in candidates {
            guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier, id != Bundle.main.bundleIdentifier,
                  !id.hasPrefix("local.webapptabs."), seen.insert(id).inserted else { continue }
            result.append((id, FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""), url))
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

// The window shown when Link Router is started by itself: the browser for all other links, and the Tabs apps
// it sends links to
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    static let shared = SettingsWindow()
    private var window: NSWindow?
    private let popup = NSPopUpButton()
    private var browsers: [(id: String, name: String, url: URL)] = []

    func show(router: Router) {
        browsers = router.browsers()
        popup.removeAllItems()
        let chosen = UserDefaults.standard.string(forKey: browserKey) ?? defaultBrowser
        for browser in browsers {
            popup.addItem(withTitle: browser.name)
            let icon = NSWorkspace.shared.icon(forFile: browser.url.path)
            icon.size = NSSize(width: 16, height: 16)
            popup.lastItem?.image = icon
            popup.lastItem?.representedObject = browser.id
        }
        popup.selectItem(at: browsers.firstIndex { $0.id == chosen } ?? browsers.firstIndex { $0.id == defaultBrowser } ?? 0)
        popup.target = self
        popup.action = #selector(chosen(_:))

        let tabApps = router.tabApps().sorted { $0.value.lastPathComponent < $1.value.lastPathComponent }
        let list = tabApps.isEmpty ? "No Tabs apps in ~/Applications yet."
            : tabApps.map { "\($0.value.deletingPathExtension().lastPathComponent)  –  \($0.key)" }.joined(separator: "\n")
        let appsLabel = NSTextField(wrappingLabelWithString: list)
        appsLabel.textColor = .secondaryLabelColor

        let browserRow = NSStackView(views: [NSTextField(labelWithString: "Open other links in:"), popup])
        browserRow.spacing = 10
        let appsHeading = NSTextField(labelWithString: "Links to these sites open in their Tabs apps:")
        let appsList = NSStackView(views: [appsLabel])
        appsList.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 0, right: 0)
        let apps = NSStackView(views: [appsHeading, appsList])
        apps.orientation = .vertical
        apps.alignment = .leading
        apps.spacing = 6
        let hint = NSTextField(wrappingLabelWithString: "Link Router must be the default web browser (System Settings → "
            + "Desktop & Dock → Default web browser). New Tabs apps are picked up by themselves.")
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hint.textColor = .secondaryLabelColor
        hint.preferredMaxLayoutWidth = 380
        let stack = NSStackView(views: [browserRow, apps, hint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)

        let window = self.window ?? NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Link Router"
        window.contentView = stack
        window.delegate = self
        window.isReleasedWhenClosed = false
        self.window = window
        window.setContentSize(stack.fittingSize)
        window.center()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }
    @objc private func chosen(_ popup: NSPopUpButton) {
        guard let id = popup.selectedItem?.representedObject as? String else { return }
        UserDefaults.standard.set(id, forKey: browserKey)
    }
}

MainActor.assumeIsolated {
    // `LinkRouter --resolve <url>…` prints where each link would open, without opening it (for tests)
    if let index = CommandLine.arguments.firstIndex(of: "--resolve") {
        let router = Router(), apps = router.tabApps()
        for text in CommandLine.arguments[(index + 1)...] {
            guard let url = URL(string: text) else { continue }
            let (link, app) = router.resolve(url, apps)
            print("\(text) → \(link.absoluteString) in \((app ?? router.browser)?.lastPathComponent ?? "nothing")")
        }
        exit(0)
    }
    let router = Router()                  // NSApplication.delegate is weak, so keep a reference
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)    // no Dock icon (LSUIElement), still receives links
    app.delegate = router
    app.run()
}
