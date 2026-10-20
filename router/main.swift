// Link Router — set as the default browser: a link for a site that has a "Tabs" app opens there,
// everything else goes on to Safari (which still sends links to its own web apps as before).
import Cocoa

let fallbackBrowser = "com.apple.Safari"

@MainActor
final class Router: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        let apps = tabApps()
        for url in urls {
            let (link, app) = resolve(url, apps)
            guard let target = app ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: fallbackBrowser)
            else { continue }
            NSWorkspace.shared.open([link], withApplicationAt: target, configuration: NSWorkspace.OpenConfiguration())
        }
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
}

MainActor.assumeIsolated {
    let router = Router()                  // NSApplication.delegate is weak, so keep a reference
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)    // no Dock icon (LSUIElement), still receives links
    app.delegate = router
    app.run()
}
