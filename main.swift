// WebAppTabs — a tiny single-site browser: one app per web app, every page is a native macOS tab.
import Cocoa
import WebKit
import CryptoKit
import UserNotifications

// The address the app opens: set in <app> → Home Page…, otherwise the one make-app.sh built it with
let defaultHomeURL = URL(string: Bundle.main.object(forInfoDictionaryKey: "WebAppURL") as? String
                         ?? CommandLine.arguments.dropFirst().first
                         ?? "https://mail.google.com")!
var homeURL: URL {
    UserDefaults.standard.string(forKey: Setting.homeURL).flatMap(URL.init(string:)) ?? defaultHomeURL
}
// Google refuses sign-in from "embedded" browsers, so pretend to be Safari.
let safariUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"

// WKWebView has no web notifications of its own: stand in for the Notification API
// and hand each notification to macOS through the "notify" message handler.
let notificationShim = """
(() => {
  const shown = new Map(); let seq = 0;
  const post = (msg) => window.webkit.messageHandlers.notify.postMessage(msg);
  class Notification extends EventTarget {
    static get permission() { return 'granted'; }
    static requestPermission(callback) { callback && callback('granted'); return Promise.resolve('granted'); }
    constructor(title, options = {}) {
      super();
      Object.assign(this, { title: String(title), body: options.body || '', tag: options.tag || '',
                            data: options.data, icon: options.icon || '',
                            onclick: null, onshow: null, onclose: null, onerror: null });
      this._id = String(++seq);
      shown.set(this._id, this);
      post({ id: this._id, title: this.title, body: this.body, tag: this.tag });
      setTimeout(() => { const e = new Event('show'); this.dispatchEvent(e); this.onshow && this.onshow(e); });
    }
    close() { post({ close: this.tag || this._id }); }
  }
  window.Notification = Notification;
  if (window.ServiceWorkerRegistration) {
    ServiceWorkerRegistration.prototype.showNotification = (title, options) => {
      new Notification(title, options); return Promise.resolve();
    };
  }
  window.__nativeNotificationClicked = (id) => {
    const n = shown.get(id); if (!n) return;
    const e = new Event('click', { cancelable: true });
    n.dispatchEvent(e); n.onclick && n.onclick.call(n, e);
  };
})();
"""

// "Mute Site": stop the page from starting sounds at all, so the Mac never grabs the AirPods.
// window.__siteMuted is set at document start and whenever the setting changes.
let muteShim = """
(() => {
  const play = HTMLMediaElement.prototype.play;
  HTMLMediaElement.prototype.play = function () {
    if (!window.__siteMuted) return play.apply(this, arguments);
    if (this instanceof HTMLVideoElement) { this.muted = true; return play.apply(this, arguments); }
    return Promise.resolve();   // pretend the sound played
  };
  const Original = window.AudioContext;
  if (Original) {
    const resume = Original.prototype.resume;
    Original.prototype.resume = function () {
      return window.__siteMuted ? Promise.resolve() : resume.apply(this, arguments);
    };
    window.AudioContext = window.webkitAudioContext = class extends Original {
      constructor(...args) { super(...args); if (window.__siteMuted) this.suspend(); }
    };
  }
})();
"""

enum Setting {
    static let restoreTabs = "restoreTabs"
    static let muteSite = "muteSite"
    static let session = "session"
    static let windowFrame = "windowFrame"
    static let homeURL = "homeURL"   // also read by Link Router
    static let pinnedPages = "pinnedPages"
    static let quickPages = "quickPages"
    static let quickGroups = "quickGroups"        // [QuickGroup] as JSON
    static let pinnedButtons = "pinnedButtonLabel"   // ButtonLabel of the separate row's buttons
    static let quickButtons = "quickButtonLabel"     // ButtonLabel of the quick tab buttons
    static let groupMenus = "groupMenuLabel"         // ButtonLabel of the items in a group's menu
    static let legacyGroupColors = "quickGroupColors"   // 1.3 drafts: group name → "#RRGGBBAA" (migrated)
    static let outlineColor = "pinnedOutlineColor"
    static let unloadAfter = "unloadIdleMinutes"     // LoadMode.unloadIdle: minutes in the background
    static let reloadAfterSleep = "reloadAfterSleepHours"   // always-loaded tabs reload after sleeping this long
    static let loginPage = "loginPage"               // the site's sign-in address; nil = recognised by its address
    static let pinnedStyle = "pinnedTabStyle"
    static let compactPinned = "compactPinnedTabs"   // older on/off setting, read when pinnedTabStyle isn't set
}

// How pinned tabs look (Settings → Pinned tabs show)
enum PinnedStyle: String, CaseIterable {
    case icon, iconAndNameCompact, iconAndName, name, separateRow
    var title: String {
        switch self {
        case .separateRow: "Separate row above the tabs"
        case .icon: "Icon only (36 px)"
        case .iconAndNameCompact: "Icon and name, compact"
        case .iconAndName: "Icon and name, full width"
        case .name: "Name only, full width"
        }
    }
}

// What the toolbar buttons of pinned tabs (separate row) and quick tabs show
enum ButtonLabel: String, CaseIterable {
    case iconAndName, icon, name
    var title: String {
        switch self {
        case .iconAndName: "Icon and name"
        case .icon: "Icon only"
        case .name: "Name only"
        }
    }
}

// Settings → Load: when a pinned / quick tab's page is loaded. Every loaded tab runs its own copy of the
// site in its own web content process (Gmail: 1 GB+ each), so rarely used ones can wait until opened.
enum LoadMode: String, Codable, CaseIterable {
    case always, whenOpened, unloadIdle
    var title: String {
        switch self {
        case .always: "Always"
        case .whenOpened: "When opened"
        case .unloadIdle: "Unload idle"
        }
    }
    var help: String {
        switch self {
        case .always: "Loaded at launch and stays loaded (needed for notifications)"
        case .whenOpened: "Loaded the first time you open it, then stays loaded until you quit"
        case .unloadIdle: "Loaded when you open it, unloaded again after the idle time in the background"
        }
    }
}

// Icons given as an image file (/path or ~/path) or a web address (e.g. https://client.pl/favicon.ico).
// Files load straight away; web images are downloaded once in the background and kept in the app's caches
// folder, then the tabs and toolbar buttons are redrawn. Kept in memory while the app runs.
@MainActor
final class IconImages {
    static let shared = IconImages()
    private var images: [String: NSImage] = [:]
    private var loading = Set<String>()

    nonisolated static func isReference(_ text: String) -> Bool {
        ["/", "~/", "file://", "http://", "https://"].contains { text.hasPrefix($0) }
    }
    func image(for reference: String) -> NSImage? {
        if let image = images[reference] { return image }
        if reference.hasPrefix("http://") || reference.hasPrefix("https://") {
            if let data = try? Data(contentsOf: cacheFile(for: reference)), let image = NSImage(data: data) {
                images[reference] = image
                return image
            }
            download(reference)
            return nil
        }
        let path = reference.hasPrefix("file://") ? URL(string: reference)?.path ?? reference
            : (reference as NSString).expandingTildeInPath
        guard let image = NSImage(contentsOfFile: path) else { return nil }
        images[reference] = image
        return image
    }
    private func cacheFile(for reference: String) -> URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "WebAppTabs").appendingPathComponent("icons")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = SHA256.hash(data: Data(reference.utf8)).map { String(format: "%02x", $0) }.joined()
        return dir.appendingPathComponent(name)
    }
    private func download(_ reference: String) {
        guard !loading.contains(reference), let url = URL(string: reference) else { return }
        loading.insert(reference)
        let file = cacheFile(for: reference)
        URLSession.shared.dataTask(with: url) { data, _, _ in
            let image = data.flatMap(NSImage.init(data:))
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    IconImages.shared.loading.remove(reference)
                    guard let data, let image else { return }
                    try? data.write(to: file)
                    IconImages.shared.images[reference] = image
                    App.shared.tabs.forEach { $0.applyPinnedLook(); $0.refreshPinnedSwitcher() }
                }
            }
        }.resume()
    }
}

// A group of quick tabs: one toolbar button ("Name ▾") that opens a menu of its pages
struct QuickGroup: Codable, Equatable {
    var id = UUID().uuidString
    var name: String
    var color: String?   // "#RRGGBBAA"; nil = the default colour
    var tint: NSColor? { color.flatMap(NSColor.init(hex:)) }
    var width: Double?   // the button's width in points; nil = automatic
    // its button's icon (letters, emoji or an SF Symbol name, like a tab's); nil = the open page's icon
    var icon: String?
    @MainActor var iconImage: NSImage? {
        icon.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : PinnedPage(name: name, url: "", icon: $0).iconImage }
    }
}

// Settings → Width cells: points, 24…800; empty = automatic
enum WidthInput { case clear, width(Double), invalid }
func parseWidth(_ text: String) -> WidthInput {
    let text = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "px", with: "").replacingOccurrences(of: "pt", with: "")
    if text.isEmpty { return .clear }
    guard let value = Double(text.replacingOccurrences(of: ",", with: ".")) else { return .invalid }
    return .width(min(800, max(24, value.rounded())))
}

// A page that always opens first, as a pinned tab (Settings → Pinned tabs)
struct PinnedPage: Codable, Equatable {
    var id = UUID().uuidString
    var name: String
    var url: String
    // Shown in the compact tab: an SF Symbol name ("checklist"), or 1–2 letters / an emoji.
    // Default: the first letter of the name.
    var icon: String?
    // A quick tab (Settings → Quick tabs): open and locked like a pinned tab, but reached only through its
    // button at the right end of the toolbar – hidden in the tab bar, skipped by ⌃Tab and ⌘1…⌘9
    var quick: Bool?
    var isQuick: Bool { quick == true }
    // The quick tab group (Settings → Quick tab groups) whose toolbar button lists this page
    var groupId: String?
    var group: String?   // earlier drafts stored the group's name here; migrated to groupId at launch
    // Its own outline / button colour ("#RRGGBBAA"); nil = Settings → Default colour
    var color: String?
    var tint: NSColor? { color.flatMap(NSColor.init(hex:)) }
    // Its own width in points (tab in the tab bar / toolbar button); nil = automatic
    var width: Double?
    // When its page is loaded (Settings → Load, quick tabs only; pinned tabs are always loaded); nil = always
    var load: LoadMode?
    var loadMode: LoadMode { isQuick ? load ?? .always : .always }

    var shownIcon: String {
        let text = (icon ?? "").trimmingCharacters(in: .whitespaces)
        if Self.isSymbol(text) || IconImages.isReference(text) { return text }
        return text.isEmpty ? String(name.prefix(1)).uppercased() : String(text.prefix(2))
    }
    // what Settings stores for a typed icon: nil when empty; symbol names and image paths / addresses whole,
    // anything else cut to 2 characters
    static func normalizedIcon(_ text: String) -> String? {
        let icon = text.trimmingCharacters(in: .whitespaces)
        if icon.isEmpty { return nil }
        return isSymbol(icon) || IconImages.isReference(icon) ? icon : String(icon.prefix(2))
    }

    // `size` centred in `rect`, scaled down (keeping its proportions) if it doesn't fit
    static func fit(_ size: NSSize, in rect: NSRect) -> NSRect {
        let scale = min(1, rect.width / max(size.width, 1), rect.height / max(size.height, 1))
        let w = size.width * scale, h = size.height * scale
        return NSRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
    }

    static func isSymbol(_ text: String) -> Bool {
        text.count > 2 && NSImage(systemSymbolName: text, accessibilityDescription: nil) != nil
    }

    // Every icon is drawn into the same 16×16 square, centred on its visible shape (symbols and
    // glyphs come with uneven padding that would otherwise sit them high or low in the tab).
    // Symbols are template images, so the tab bar tints them; text uses the current text colour.
    @MainActor var iconImage: NSImage {
        let canvas = NSSize(width: 16, height: 16)
        // an image file or web address (e.g. a site's favicon), in its own colours; the first letter until loaded
        if IconImages.isReference(shownIcon) {
            if let picture = IconImages.shared.image(for: shownIcon) {
                return NSImage(size: canvas, flipped: false) { rect in
                    picture.draw(in: Self.fit(picture.size, in: rect))
                    return true
                }
            }
            return PinnedPage(name: name, url: url).iconImage
        }
        if Self.isSymbol(shownIcon),
           let symbol = NSImage(systemSymbolName: shownIcon, accessibilityDescription: name)?
               .withSymbolConfiguration(.init(pointSize: 12, weight: .medium)) {
            let image = NSImage(size: canvas, flipped: false) { rect in
                symbol.draw(in: Self.fit(symbol.size, in: rect))   // wide ones (person.3) shrink to fit
                return true
            }
            image.isTemplate = true
            return image
        }
        let text = shownIcon
        let fontSize: CGFloat = text.count > 1 ? 9 : 12
        return NSImage(size: canvas, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold), .foregroundColor: NSColor.labelColor]))
            let ink = CTLineGetImageBounds(line, context)
            context.textPosition = CGPoint(x: (rect.width - ink.width) / 2 - ink.minX,
                                           y: (rect.height - ink.height) / 2 - ink.minY)
            CTLineDraw(line, context)
            return true
        }
    }
}

// Pages of this app's site stay in the app; anything else opens in the default browser
func isOwnSite(_ url: URL) -> Bool { url.host?.lowercased() == homeURL.host?.lowercased() }

// New tabs/windows stay in the app for the site itself and for its sign-in pages on the same domain
// (Gmail's "Sign in" opens accounts.google.com in a new window); Docs, Drive etc. go to the browser.
func belongsInApp(_ url: URL) -> Bool {
    let signInHosts = ["accounts", "login", "auth", "sso", "signin"]
    let firstLabel = url.host?.lowercased().split(separator: ".").first.map(String.init) ?? ""
    return isOwnSite(url) || (isSameDomain(url) && signInHosts.contains(firstLabel))
}

// Same domain, any subdomain: accounts.google.com for mail.google.com, gist.github.com for github.com
func isSameDomain(_ url: URL) -> Bool {
    let domain = { (u: URL) in u.host?.lowercased().split(separator: ".").suffix(2).joined(separator: ".") }
    return domain(url) != nil && domain(url) == domain(homeURL)
}

// The site's sign-in page: Settings → Login page (that address and anything below it), else guessed from the
// address – a sign-in host (accounts.google.com) or a path part like login, sign-in, authentication, sso
func isLoginPage(_ url: URL?) -> Bool {
    guard let url, let host = url.host?.lowercased() else { return false }
    if let custom = UserDefaults.standard.string(forKey: Setting.loginPage).flatMap(URL.init(string:)) {
        let path = custom.path.isEmpty ? "/" : custom.path.lowercased()
        return host == custom.host?.lowercased() && url.path.lowercased().hasPrefix(path)
    }
    if ["accounts", "login", "auth", "sso", "signin"].contains(host.split(separator: ".").first.map(String.init) ?? "") {
        return true
    }
    return url.path.lowercased().split(separator: "/").contains {
        $0.wholeMatch(of: #/(wp-)?(log-?in|sign-?in|authentication|auth|sso)(\.\w+)?/#) != nil
    }
}

// What happened when, for working out problems like "the pages show an expired session in the morning":
// launches, quits, sleep / wake, reloads, unloads, sign-in pages. ~/Library/Logs/WebAppTabs/<app>.log,
// addresses without their query; trimmed to the newest half when it passes 512 KB.
enum Diagnostics {
    static let file: URL = {
        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "WebAppTabs"
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/WebAppTabs/\(name).log")
    }()
    static func log(_ message: String) {
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).timeSeparator(.colon).dateTimeSeparator(.space))
        let line = Data("\(stamp)  \(message)\n".utf8)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let handle = try? FileHandle(forWritingTo: file) else {
            try? line.write(to: file)
            return
        }
        defer { try? handle.close() }
        if let size = try? handle.seekToEnd(), size > 512_000, let data = try? Data(contentsOf: file) {
            try? data.suffix(256_000).write(to: file)
            return log(message)
        }
        handle.write(line)
    }
    // host + path, no query (it can carry tokens)
    static func address(_ url: URL?) -> String { url.map { ($0.host ?? "") + $0.path } ?? "–" }
}

final class WebView: WKWebView {
    // Middle-click on a link → new tab. WebKit would otherwise follow it in the same tab.
    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return super.otherMouseDown(with: event) }
        let point = convert(event.locationInWindow, from: nil)
        let y = isFlipped ? point.y : bounds.height - point.y
        evaluateJavaScript("document.elementFromPoint(\(point.x), \(y))?.closest('a[href]')?.href") { [weak self] result, _ in
            guard let href = result as? String, let url = URL(string: href) else { return }
            (self?.uiDelegate as? Tab)?.openInNewTab(url, inBackground: true)
        }
    }
    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber != 2 { super.otherMouseUp(with: event) }
    }
}

final class Tab: NSWindowController, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate {
    let id = UUID().uuidString
    private(set) var webView: WebView
    private var observations: [NSKeyValueObservation] = []

    // Pinned tabs show their short name and a coloured outline in the tab bar, and can't be closed
    var pinned: PinnedPage? { didSet { updateTabTitle(); applyPinnedLook(); App.shared.outlinePinnedTabs() } }
    func updateTabTitle() {
        guard let window else { return }
        window.tab.title = pinned?.name ?? window.title
        window.tab.toolTip = pinned?.name
    }

    // Pinned tabs use the tab bar's own compact pinned layout (36 px, icon only), like Safari's, or a
    // full-width tab with the icon in the tab's icon slot before the name. Both are internal to macOS
    // (NSWindowTab's tabBarItem); without it they stay full-width tabs with the name.
    func applyPinnedLook() {
        guard let tab = window?.tab, tab.responds(to: NSSelectorFromString("tabBarItem")),
              let item = tab.value(forKey: "tabBarItem") as? NSObject,
              item.responds(to: NSSelectorFromString("setPinned:")),
              item.responds(to: NSSelectorFromString("setShowIcon:")) else { return }
        let style = pinned == nil || pinned?.isQuick == true ? nil : App.shared.pinnedStyle
        let iconAndName = style == .iconAndName || style == .iconAndNameCompact
        item.setValue(style == .icon || iconAndName ? pinned?.iconImage : nil, forKey: "image")
        item.setValue(iconAndName, forKey: "showIcon")
        item.setValue(style == .icon, forKey: "pinned")
    }
    private let titleLabel = NSTextField(labelWithString: "")
    private lazy var pinnedSwitcher: PinnedSwitcher = {
        let switcher = PinnedSwitcher()
        switcher.onSelect = { [weak self] index in self?.selectPinnedPage(App.shared.pinnedPages[safe: index]) }
        return switcher
    }()
    private lazy var quickSwitcher: PinnedSwitcher = {
        let switcher = PinnedSwitcher()
        switcher.onSelect = { [weak self] index in self?.selectPinnedPage(App.shared.quickPages[safe: index]) }
        return switcher
    }()

    // deferred: don't load `url` until the tab is selected (Settings → Load: When opened / Unload idle)
    init(load url: URL?, configuration: WKWebViewConfiguration, deferred: Bool = false) {
        webView = WebView(frame: .zero, configuration: configuration)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.tabbingMode = .preferred            // ← this line is the whole tab bar
        window.tabbingIdentifier = "webapp"
        window.center()
        super.init(window: window)
        window.delegate = self
        // Safari web app look: ‹ › on the left, page title centered
        window.titleVisibility = .hidden            // the tab bar still shows window.title
        window.toolbarStyle = .unified
        // its own identifier: toolbars sharing one mirror item changes, which breaks adding an item to a
        // window that already has it (updateToolbar manages each window's items itself)
        let toolbar = NSToolbar(identifier: "main-\(id)")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.centeredItemIdentifiers = [.pageTitle]
        window.toolbar = toolbar
        if let frame = App.shared.savedFrame() { window.setFrame(frame, display: false) }
        titleLabel.font = .titleBarFont(ofSize: 0)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 600).isActive = true
        attach(webView)
        if deferred {
            unloadedURL = url
            isUnloaded = true
        } else {
            hasLoaded = true
            applyMute()
            if let url { webView.load(URLRequest(url: url)) }
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    // Puts a web view in the window and wires it up (at init, and when unloading swaps in an empty one)
    private func attach(_ webView: WebView) {
        self.webView = webView
        window?.contentView = webView
        window?.initialFirstResponder = webView
        webView.customUserAgent = safariUA
        webView.allowsBackForwardNavigationGestures = true
        webView.isInspectable = true               // Safari → Develop → <Mac name> → Gmail Tabs
        webView.navigationDelegate = self
        webView.uiDelegate = self
        for item in window?.toolbar?.items ?? [] where [.back, .forward].contains(item.itemIdentifier) {
            item.target = webView
        }
        observations = [
            webView.observe(\.title) { [weak self] web, _ in
                MainActor.assumeIsolated {
                    let title = web.title.flatMap { $0.isEmpty ? nil : $0 } ?? homeURL.host ?? ""
                    self?.window?.title = title
                    self?.titleLabel.stringValue = title
                    self?.updateTabTitle()
                    App.shared.updateBadge()
                }
            },
            webView.observe(\.url) { _, _ in
                MainActor.assumeIsolated { App.shared.saveSession() }
            },
            webView.observe(\.canGoBack) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.updateNavigationButtons() }
            },
            webView.observe(\.canGoForward) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.updateNavigationButtons() }
            },
        ]
        updateNavigationButtons()
    }

    // Settings → Load. An unloaded tab has an empty web view: WebKit starts no web content process for it
    // until it loads something, so it takes no memory. Its title and place stay; selecting it loads the
    // page again, back where it was (history included).
    private(set) var isUnloaded = false
    private(set) var hasLoaded = false   // false: not loaded yet (Load "When opened", never opened)
    private var unloadedURL: URL?
    private var unloadedState: Any?   // WKWebView.interactionState: back/forward list + current page
    var backgroundSince: Date?        // since when it's not the selected tab of its window (idle unloading)
    // its page, also while unloaded (saved session, Recently Closed, Tab Memory)
    var pageURL: URL? { isUnloaded ? unloadedURL : webView.url }
    var displayName: String { pinned?.name ?? window?.title ?? "" }

    // reason: for the diagnostics log ("idle", "by hand")
    func unload(_ reason: String) {
        guard !isUnloaded else { return }
        Diagnostics.log("unload (\(reason)): \(displayName) – \(Diagnostics.address(webView.url))")
        let old = webView
        unloadedState = old.interactionState
        unloadedURL = old.url ?? pinned.flatMap { URL(string: $0.url) }
        isUnloaded = true
        old.stopLoading()
        old.navigationDelegate = nil
        old.uiDelegate = nil
        observations = []
        attach(WebView(frame: old.frame, configuration: App.shared.makeConfiguration()))
        old.removeFromSuperview()
        App.shared.loadStateChanged()
    }
    func loadIfNeeded() {
        guard isUnloaded else { return }
        isUnloaded = false
        hasLoaded = true
        applyMute()
        if let state = unloadedState {
            webView.interactionState = state
        } else if let url = unloadedURL ?? pinned.flatMap({ URL(string: $0.url) }) {
            webView.load(URLRequest(url: url))
        }
        unloadedState = nil
        unloadedURL = nil
        App.shared.loadStateChanged()
    }
    // Loads a page in this tab, also when it's unloaded (⌘W on a pinned tab, a changed address, Home Page)
    func open(_ url: URL) {
        let wasUnloaded = isUnloaded
        hasLoaded = true
        isUnloaded = false
        unloadedState = nil
        unloadedURL = nil
        webView.load(URLRequest(url: url))
        if wasUnloaded { App.shared.loadStateChanged() }
    }

    // Besides the JS shim, mute the whole page (every frame) in WebKit itself.
    // _setPageMuted: is private API; the public one only covers microphone and camera.
    func applyMute() {
        let muted = App.shared.isMuted
        webView.evaluateJavaScript("window.__siteMuted = \(muted)")
        let selector = NSSelectorFromString("_setPageMuted:")
        guard webView.responds(to: selector) else { return }
        typealias SetPageMuted = @convention(c) (AnyObject, Selector, UInt) -> Void
        unsafeBitCast(webView.method(for: selector), to: SetPageMuted.self)(webView, selector, muted ? 1 : 0)
    }

    // ⌘T and the "+" button in the tab bar
    override func newWindowForTab(_ sender: Any?) {
        // the tab bar also sends this for a click on its empty space – only its + button should open a tab
        if let event = NSApp.currentEvent, [.leftMouseDown, .leftMouseUp].contains(event.type),
           let hit = event.window?.contentView?.superview?.hitTest(event.locationInWindow) {
            let names = sequence(first: hit, next: \.superview).map { String(describing: type(of: $0)) }
            if names.contains("NSTabBar"), !names.contains("NSTabBarNewTabButton") { return }
        }
        App.shared.openTab(url: homeURL, next: self)
    }

    // Like Safari: background tabs opened from this tab line up after each other, in click order,
    // until you switch tabs
    private weak var lastOpenedInBackground: Tab?

    func openInNewTab(_ url: URL, inBackground: Bool = false) {
        if belongsInApp(url) {
            let anchor = lastOpenedInBackground.flatMap {
                App.shared.tabs.contains($0) && $0.window?.tabGroup === window?.tabGroup ? $0 : nil
            }
            let tab = App.shared.openTab(url: url, next: self, after: inBackground ? anchor : nil,
                                         opener: self, inBackground: inBackground)
            if inBackground { lastOpenedInBackground = tab }
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    // Remember the tab's place before it leaves the tab bar (for reopening it there)
    private(set) var closingInfo: (title: String?, leftNeighbour: Tab?)?
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // A pinned tab doesn't close (⌘W, the window's ×, Close Other Tabs…)
        if pinned != nil, !App.shared.isQuitting { return false }
        let group = sender.tabbedWindows ?? []
        let index = group.firstIndex(of: sender) ?? 0
        let left = index > 0 ? App.shared.tabs.first { $0.window === group[index - 1] } : nil
        closingInfo = (isUnloaded ? sender.title : webView.title, left)
        // Like Safari: closing a tab you came to straight from the tab that opened it goes back there.
        // Otherwise AppKit selects the tab to the right (or left, for the last tab), as Safari does.
        // Quick tabs count as sitting before the pinned ones: if AppKit would land on one (closing the last
        // tab right after them), go to the first pinned tab instead.
        let isQuick = { (w: NSWindow) in App.shared.tabs.contains { $0.window === w && $0.pinned?.isQuick == true } }
        if let back = returnOnClose?.window, App.shared.tabs.contains(where: { $0 === returnOnClose }),
           sender.tabGroup?.selectedWindow === sender, group.contains(back) {
            sender.tabGroup?.selectedWindow = back
            back.makeKeyAndOrderFront(nil)
        } else if sender.tabGroup?.selectedWindow === sender,
                  let next = group[safe: index + 1] ?? group[safe: index - 1], isQuick(next),
                  let first = group.first(where: { $0 !== sender && !isQuick($0) }) {
            sender.tabGroup?.selectedWindow = first
            first.makeKeyAndOrderFront(nil)
        }
        return true
    }

    // The tab this one was opened from (link, ⌘-click, middle-click, window.open)
    weak var opener: Tab?
    private weak var returnOnClose: Tab?

    // The user switched to this tab (from `previous`)
    func didGetSelected(after previous: Tab?) {
        backgroundSince = nil
        // Came straight from the opener → closing returns to it; from anywhere else → normal order
        returnOnClose = previous != nil && previous === opener ? opener : nil
        lastOpenedInBackground = nil
    }

    func windowWillClose(_ notification: Notification) {
        App.shared.rememberClosed(self)
        App.shared.tabs.removeAll { $0 === self }
        App.shared.saveSession()
    }

    // Keep keyboard focus in the page, not on the tab bar
    // Remember the size and position for the next window and the next launch
    func windowDidResize(_ notification: Notification) { rememberFrame() }
    func windowDidMove(_ notification: Notification) { rememberFrame() }
    private func rememberFrame() {
        guard let window, window.isVisible, !window.styleMask.contains(.fullScreen),
              window.tabGroup?.selectedWindow ?? window === window else { return }
        UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: Setting.windowFrame)
        App.shared.saveSession()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if window?.firstResponder === window { window?.makeFirstResponder(webView) }
        if let window { App.shared.observeSelection(of: window) }   // e.g. a tab dragged out into its own window
        App.shared.saveSession()   // remembers which tab is selected
    }

    // target=_blank / window.open(): same site → new tab, other sites → default browser
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url, url.host != nil, !belongsInApp(url) {
            NSWorkspace.shared.open(url)
            return nil
        }
        return App.shared.openTab(url: nil, configuration: configuration, next: self, opener: self).webView
    }

    // window.close()
    func webViewDidClose(_ webView: WKWebView) { window?.performClose(nil) }

    // alert() / confirm() / prompt() — WKWebView shows nothing unless the app does it
    private func showDialog(_ message: String, cancellable: Bool, input: String? = nil,
                            done: @escaping (Bool, String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = homeURL.host ?? ""
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        if cancellable { alert.addButton(withTitle: "Cancel") }
        let field = input.map { NSTextField(string: $0) }
        field?.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        alert.accessoryView = field
        window?.makeKeyAndOrderFront(nil)          // bring the tab forward if it's in the background
        alert.beginSheetModal(for: window!) { done($0 == .alertFirstButtonReturn, field?.stringValue) }
        if let field { alert.window.makeFirstResponder(field) }
    }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        showDialog(message, cancellable: false) { _, _ in completionHandler() }
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        showDialog(message, cancellable: true) { ok, _ in completionHandler(ok) }
    }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        showDialog(prompt, cancellable: true, input: defaultText ?? "") { ok, text in completionHandler(ok ? text : nil) }
    }

    // <input type="file"> does nothing on macOS unless you show the panel yourself
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.beginSheetModal(for: window!) { completionHandler($0 == .OK ? panel.urls : nil) }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { return decisionHandler(.allow) }
        // mailto:, tel:, zoommtg: … → the app that handles them (WebKit would silently do nothing)
        if !["http", "https", "about", "blob", "data", "file"].contains(url.scheme?.lowercased() ?? "") {
            NSWorkspace.shared.open(url)
            return decisionHandler(.cancel)
        }
        if action.navigationType == .linkActivated {
            // ⌘-click on a link → new tab, like a browser
            if action.modifierFlags.contains(.command) {
                openInNewTab(url)
                return decisionHandler(.cancel)
            }
            // A clicked link to another domain → default browser (Link Router), like a Safari web app.
            // The same domain stays, so signing in works (workspace.google.com → accounts.google.com).
            // Scripted navigation and redirects started by the page (e.g. a login elsewhere) stay too.
            if action.targetFrame?.isMainFrame == true, !isSameDomain(url), !action.shouldPerformDownload {
                NSWorkspace.shared.open(url)
                return decisionHandler(.cancel)
            }
        }
        decisionHandler(action.shouldPerformDownload ? .download : .allow)
    }

    // Downloads → ~/Downloads. "Content-Disposition: attachment" means save it, even for a PDF or image
    // WebKit could display (sites often load those in a hidden frame, which otherwise does nothing).
    // Sign-in detection: a page that lands on the site's login page (also via a redirect), then leaves it for
    // the site again = signed in again → App.didSignIn reloads the always-loaded tabs
    private var sawLoginPage = false
    private func noteLoginPage() {
        guard !sawLoginPage, isLoginPage(webView.url) else { return }
        sawLoginPage = true
        Diagnostics.log("login page: \(displayName) – \(Diagnostics.address(webView.url))")
    }
    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        noteLoginPage()
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { noteLoginPage() }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard sawLoginPage, let url = webView.url, !isLoginPage(url), isOwnSite(url) || isSameDomain(url) else { return }
        sawLoginPage = false
        App.shared.didSignIn(in: self)
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let disposition = (response.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition")
        let isAttachment = disposition?.lowercased().hasPrefix("attachment") == true
        decisionHandler(response.canShowMIMEType && !isAttachment ? .allow : .download)
    }
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        startDownload(download)
    }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        startDownload(download)
    }
    private func startDownload(_ download: WKDownload) {
        download.delegate = App.shared   // the app, not this tab: the tab may close below
        // A tab opened only to fetch a file (target=_blank / window.open) would stay empty, so close it
        if webView.backForwardList.currentItem == nil, App.shared.tabs.count > 1 {
            DispatchQueue.main.async { self.window?.performClose(nil) }   // performClose: returns to the opener
        }
    }
}

extension NSToolbarItem.Identifier {
    static let back = Self("back")
    static let forward = Self("forward")
    static let pageTitle = Self("pageTitle")
    static let share = Self("share")
    static let pinnedSwitcher = Self("pinnedSwitcher")
    static let quickSwitcher = Self("quickSwitcher")
}

extension Tab: NSToolbarDelegate, NSSharingServicePickerToolbarItemDelegate {
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.back, .forward] + (App.shared.pinnedStyle == .separateRow ? [.pinnedSwitcher] : [])
            + [.flexibleSpace, .pageTitle, .flexibleSpace]
            + (App.shared.quickPages.isEmpty ? [] : [.quickSwitcher]) + [.share]
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.back, .forward, .pinnedSwitcher, .flexibleSpace, .pageTitle, .quickSwitcher, .share]
    }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        // Share button (Messages, Mail, AirDrop, Copy Link, Notes…), like the Safari web app
        if id == .share {
            let share = NSSharingServicePickerToolbarItem(itemIdentifier: id)
            share.label = "Share"
            share.delegate = self
            return share
        }
        let item = NSToolbarItem(itemIdentifier: id)
        switch id {
        case .back, .forward:
            let back = id == .back
            item.label = back ? "Back" : "Forward"
            item.image = NSImage(systemSymbolName: back ? "chevron.left" : "chevron.right",
                                 accessibilityDescription: item.label)
            item.isBordered = true
            item.target = webView
            item.action = back ? #selector(WKWebView.goBack(_:)) : #selector(WKWebView.goForward(_:))
            item.autovalidates = false
            item.isEnabled = back ? webView.canGoBack : webView.canGoForward
        case .pageTitle:
            item.view = titleLabel
        case .pinnedSwitcher:
            item.label = "Pinned Tabs"
            item.view = pinnedSwitcher
            refreshPinnedSwitcher()
        case .quickSwitcher:
            item.label = "Quick Tabs"
            item.view = quickSwitcher
            refreshPinnedSwitcher()
        default:
            return nil
        }
        return item
    }

    func items(for pickerToolbarItem: NSSharingServicePickerToolbarItem) -> [Any] {
        webView.url.map { [$0] } ?? []
    }

    // "Separate row above the tabs": the pinned pages as one switcher in the toolbar, after ‹ ›; quick tabs:
    // their switcher at the right end, before Share. Called for every tab's toolbar.
    func updateToolbar() {
        guard let toolbar = window?.toolbar else { return }
        let pinnedIndex = toolbar.items.firstIndex { $0.itemIdentifier == .pinnedSwitcher }
        if App.shared.pinnedStyle == .separateRow, pinnedIndex == nil {
            toolbar.insertItem(withItemIdentifier: .pinnedSwitcher, at: 2)
        } else if App.shared.pinnedStyle != .separateRow, let pinnedIndex {
            toolbar.removeItem(at: pinnedIndex)
        }
        let quickIndex = toolbar.items.firstIndex { $0.itemIdentifier == .quickSwitcher }
        if !App.shared.quickPages.isEmpty, quickIndex == nil {
            toolbar.insertItem(withItemIdentifier: .quickSwitcher,
                               at: toolbar.items.firstIndex { $0.itemIdentifier == .share } ?? toolbar.items.count)
        } else if App.shared.quickPages.isEmpty, let quickIndex {
            toolbar.removeItem(at: quickIndex)
        }
    }
    func refreshPinnedSwitcher() {
        let selected = App.shared.selectedTab?.pinned?.id, color = App.shared.outlineColor
        let pinned = App.shared.pinnedPages, quick = App.shared.quickPages
        let unloaded = Set(App.shared.tabs.filter(\.isUnloaded).compactMap { $0.pinned?.id })
        pinnedSwitcher.update(pages: pinned, selected: pinned.firstIndex { $0.id == selected }, color: color,
                              show: App.shared.pinnedButtonLabel)
        quickSwitcher.update(pages: quick, selected: quick.firstIndex { $0.id == selected }, color: color,
                             groups: App.shared.quickGroups, show: App.shared.quickButtonLabel,
                             menus: App.shared.groupMenuLabel, unloaded: unloaded)
        // when the window is too narrow the toolbar moves them into its » menu, which uses these
        for item in window?.toolbar?.items ?? [] {
            guard let switcher = item.view as? PinnedSwitcher else { continue }
            let menuItem = NSMenuItem(title: item.label, action: nil, keyEquivalent: "")
            menuItem.submenu = switcher.overflowMenu()
            item.menuFormRepresentation = menuItem
        }
    }
    private func selectPinnedPage(_ page: PinnedPage?) {
        guard let page, let tab = App.shared.tabs.first(where: { $0.pinned?.id == page.id }) else { return }
        tab.window?.tabGroup?.selectedWindow = tab.window
        tab.window?.makeKeyAndOrderFront(nil)
    }

    func updateNavigationButtons() {
        for item in window?.toolbar?.items ?? [] {
            if item.itemIdentifier == .back { item.isEnabled = webView.canGoBack }
            if item.itemIdentifier == .forward { item.isEnabled = webView.canGoForward }
        }
    }
}

@MainActor
final class App: NSObject, NSApplicationDelegate {
    static let shared = App()
    var tabs: [Tab] = []
    var closedTabs: [ClosedTab] = []
    var downloads: [ObjectIdentifier: URL] = [:]
    private(set) var isQuitting = false

    // Settings are per app (UserDefaults is keyed by bundle ID), so Gmail can be muted and GitHub not
    // app menu and Settings → General; the menu items' ticks follow in validateMenuItem
    var restoreTabs: Bool {
        get { UserDefaults.standard.bool(forKey: Setting.restoreTabs) }
        set { UserDefaults.standard.set(newValue, forKey: Setting.restoreTabs) }
    }
    var isMuted: Bool {
        get { UserDefaults.standard.bool(forKey: Setting.muteSite) }
        set {
            UserDefaults.standard.set(newValue, forKey: Setting.muteSite)
            installUserScripts()
            tabs.forEach { $0.applyMute() }
        }
    }
    // Settings → "Pinned tabs show": 36 px icon tabs, or full-width tabs with icon + name or the name
    var pinnedStyle: PinnedStyle {
        get {
            UserDefaults.standard.string(forKey: Setting.pinnedStyle).flatMap(PinnedStyle.init)
                ?? (UserDefaults.standard.object(forKey: Setting.compactPinned) as? Bool == false ? .name : .icon)
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Setting.pinnedStyle)
            tabs.forEach { $0.applyPinnedLook(); $0.updateToolbar() }
            updateTabBarVisibility()
            layOutTabBars()
            // once tabs that were 36 px have finished growing back
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.layOutTabBars() }
            outlinePinnedTabs()
        }
    }

    // Shared by every tab, so the page scripts and the notification handler are installed once
    lazy var contentController: WKUserContentController = {
        let controller = WKUserContentController()
        controller.add(self, name: "notify")
        return controller
    }()

    // Re-run when "Mute Site" changes so pages loaded afterwards get the new value
    func installUserScripts() {
        contentController.removeAllUserScripts()
        for source in [notificationShim, muteShim, "window.__siteMuted = \(isMuted);"] {
            contentController.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart,
                                                         forMainFrameOnly: false))
        }
    }

    func makeConfiguration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.preferences.isElementFullscreenEnabled = true
        // Let the site open tabs from scripts (e.g. window.open(fileURL) after a fetch); WebKit blocks that by default
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        config.userContentController = contentController
        return config
    }

    private(set) var isOpeningTab = false
    private var isOpeningInBackground = false

    // Tab selection changes (clicks, ⌃Tab, closing a tab…), observed on the tab bar itself so it
    // also works while the app is in the background
    private var selectionObservers: [ObjectIdentifier: NSKeyValueObservation] = [:]
    private(set) weak var selectedTab: Tab?
    func observeSelection(of window: NSWindow) {
        guard let group = window.tabGroup, selectionObservers[ObjectIdentifier(group)] == nil else { return }
        selectionObservers[ObjectIdentifier(group)] = group.observe(\.selectedWindow, options: [.initial, .new]) { group, _ in
            MainActor.assumeIsolated {
                let app = App.shared
                guard !app.isOpeningInBackground, let window = group.selectedWindow,
                      let tab = app.tabs.first(where: { $0.window === window }), tab !== app.selectedTab else { return }
                tab.didGetSelected(after: app.selectedTab)
                tab.loadIfNeeded()
                app.selectedTab = tab
                app.outlinePinnedTabs()   // the tab bar now lives in the newly selected window
                app.tabs.forEach { $0.refreshPinnedSwitcher() }
                app.updateTabBarVisibility()
            }
        }
        // the tab bar is redrawn when tabs are added, closed or dragged into a new order
        outlineObservers[ObjectIdentifier(group)] = group.observe(\.windows) { _, _ in
            MainActor.assumeIsolated {
                App.shared.outlinePinnedTabs()
                App.shared.keepPinnedTabsInPlace()
                App.shared.updateTabBarVisibility()
                DispatchQueue.main.async { App.shared.updateTabBarVisibility() }
            }
        }
    }
    private var outlineObservers: [ObjectIdentifier: NSKeyValueObservation] = [:]

    // Pinned tabs get a coloured outline (Settings → Outline colour). macOS has no API for tab colours, so this finds the tab bar's
    // buttons (private NSTabButton views, in tab order) and draws a border on their layer. If a future
    // macOS changes those views, the outline just doesn't appear. Runs now and once the tab bar has
    // finished redrawing.
    func outlinePinnedTabs() {
        drawPinnedOutlines()
        DispatchQueue.main.async { self.drawPinnedOutlines() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.drawPinnedOutlines() }
    }
    private func drawPinnedOutlines() {
        var done = Set<ObjectIdentifier>()
        Self.dimmedTabButtons = []   // worked out again below, for the buttons there are now
        for tab in tabs {
            guard let group = tab.window?.tabGroup, done.insert(ObjectIdentifier(group)).inserted,
                  let frameView = (group.selectedWindow ?? tab.window)?.contentView?.superview else { continue }
            guard let buttons = Self.tabButtons(in: frameView, for: group.windows) else { continue }
            for (button, window) in zip(buttons, group.windows) {
                let tab = tabs.first { $0.window === window }
                if tab?.isUnloaded == true { Self.dimmedTabButtons.insert(ObjectIdentifier(button)) }   // unloaded: dimmed
                button.alphaValue = tab?.isUnloaded == true ? Self.dimmedAlpha : 1
                let page = tab?.pinned
                let pinned = page != nil
                button.wantsLayer = true
                button.layer?.borderColor = (page?.tint ?? outlineColor).cgColor
                button.layer?.borderWidth = pinned ? 1.5 : 0
                button.layer?.cornerRadius = button.bounds.height / 2
                centerPinnedIcon(in: button, pinned: pinned && pinnedStyle == .icon)
            }
        }
    }
    // macOS bug: a pinned (36 px) tab still reserves room for its hidden close button, which pushes the
    // icon to the right edge and clips it. Let the button's content row skip hidden items and pad the
    // icon into the middle; a tab that's no longer pinned gets the row's original settings back.
    private var originalRowLayout: [ObjectIdentifier: (detaches: Bool, insets: NSEdgeInsets)] = [:]
    private func centerPinnedIcon(in button: NSView, pinned: Bool) {
        guard let row = Self.firstStack(in: button) else { return }
        let key = ObjectIdentifier(row)
        if pinned {
            if originalRowLayout[key] == nil { originalRowLayout[key] = (row.detachesHiddenViews, row.edgeInsets) }
            row.detachesHiddenViews = true
            var insets = row.edgeInsets
            insets.left = max(0, (button.bounds.width - 16) / 2)
            row.edgeInsets = insets
        } else if let original = originalRowLayout.removeValue(forKey: key) {
            row.detachesHiddenViews = original.detaches
            row.edgeInsets = original.insets
        }
    }
    private static func firstStack(in view: NSView) -> NSStackView? {
        (view as? NSStackView) ?? view.subviews.lazy.compactMap(firstStack).first
    }

    private static func firstLabel(in view: NSView) -> NSTextField? {
        (view as? NSTextField) ?? view.subviews.lazy.compactMap(firstLabel).first
    }

    private static func tabButtons(in view: NSView) -> [NSView] {
        String(describing: type(of: view)) == "NSTabButton" ? [view] : view.subviews.flatMap(tabButtons)
    }
    // The tab bar's buttons in the order of `windows` (each button knows its NSTabBarItem, the same object
    // as the window's tab.tabBarItem); by position if that's not available. nil if they don't match up.
    static func tabButtons(in view: NSView, for windows: [NSWindow]) -> [NSView]? {
        let buttons = tabButtons(in: view)
        guard buttons.count == windows.count else { return nil }
        let itemKey = "tabBarViewItem"
        guard buttons.allSatisfy({ $0.responds(to: NSSelectorFromString(itemKey)) }),
              windows.allSatisfy({ $0.tab.responds(to: NSSelectorFromString("tabBarItem")) }) else {
            return buttons.sorted { $0.frame.minX < $1.frame.minX }
        }
        let ordered = windows.compactMap { window -> NSView? in
            let item = window.tab.value(forKey: "tabBarItem") as AnyObject?
            return buttons.first { $0.value(forKey: itemKey) as AnyObject? === item }
        }
        return ordered.count == windows.count ? ordered : nil
    }

    // "Icon and name, compact": macOS gives every normal tab the same width. Right after the tab bar lays
    // itself out (private NSTabBar._layOutButtonsAnimated:) the pinned tabs' frames are worked out to fit
    // their icon + name, the other tabs share what's left, and those frames are kept: the tab bar also
    // sets frames later (animation steps), so setFrame: on its buttons and separators is overridden to
    // apply the kept frame while the tab count and bar width are unchanged and no tab is being dragged.
    // Pinned tabs lose their close button (⌘W only sends them back to their page). When the other tabs
    // would get narrower than 100 px, the native layout is left alone.
    private static var keptFrames: [ObjectIdentifier: (x: CGFloat, width: CGFloat, barWidth: CGFloat, count: Int)] = [:]
    static func hookTabBarLayout() {
        let selector = NSSelectorFromString("_layOutButtonsAnimated:")
        guard let tabBar = NSClassFromString("NSTabBar"), let method = class_getInstanceMethod(tabBar, selector) else { return }
        typealias LayOut = @convention(c) (NSView, Selector, Bool) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: LayOut.self)
        let replacement: @convention(block) (NSView, Bool) -> Void = { bar, animated in
            original(bar, selector, animated)
            MainActor.assumeIsolated { App.shared.narrowPinnedTabs(in: bar) }
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
        for name in ["NSTabButton", "NSTabSeparator"] { keepFrames(of: name) }
        keepDimming()
        refuseDraggingPinnedTabs()
        hideCloseButtonOfPinnedTabs()
        hitTestTabsByTheirFrames()
    }
    // The tab bar finds the clicked tab by arithmetic on its equal-width layout, so with our widths a click
    // would land on the wrong tab (or on a hidden pinned one) – answer from the buttons' real frames
    private static func hitTestTabsByTheirFrames() {
        let selector = NSSelectorFromString("_visibleTabIndexAtPoint:stackingRegion:ignorePointsOutsideOfLayoutBounds:")
        guard let tabBar = NSClassFromString("NSTabBar"), let method = class_getInstanceMethod(tabBar, selector) else { return }
        typealias IndexAt = @convention(c) (NSView, Selector, NSPoint, UnsafeMutablePointer<UInt>?, Bool) -> UInt
        let original = unsafeBitCast(method_getImplementation(method), to: IndexAt.self)
        let replacement: @convention(block) (NSView, NSPoint, UnsafeMutablePointer<UInt>?, Bool) -> UInt = { bar, point, region, ignore in
            let index = original(bar, selector, point, region, ignore)
            return MainActor.assumeIsolated { App.shared.tabIndex(at: point, in: bar) } ?? index
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
    }
    // nil while the tab bar uses its own layout; `point` is in the buttons' row coordinates
    func tabIndex(at point: NSPoint, in bar: NSView) -> UInt? {
        guard let windows = bar.window?.tabGroup?.windows, let buttons = Self.tabButtons(in: bar, for: windows),
              buttons.contains(where: { Self.keptFrames[ObjectIdentifier($0)] != nil }) else { return nil }
        let hit = buttons.indices.first { i in
            !buttons[i].isHidden && point.x >= buttons[i].frame.minX && point.x < buttons[i].frame.maxX + 1   // + the 1 px gap
        }
        return hit.map(UInt.init) ?? UInt(NSNotFound)   // empty space: no tab
    }
    // Pinned tabs can't be closed, so they get no close button (the tab bar asks per tab item)
    private static func hideCloseButtonOfPinnedTabs() {
        let selector = NSSelectorFromString("_shouldShowCloseButtonForTabBarViewItem:")
        guard let tabBar = NSClassFromString("NSTabBar"), let method = class_getInstanceMethod(tabBar, selector) else { return }
        typealias ShouldShow = @convention(c) (NSView, Selector, AnyObject) -> Bool
        let original = unsafeBitCast(method_getImplementation(method), to: ShouldShow.self)
        let replacement: @convention(block) (NSView, AnyObject) -> Bool = { bar, item in
            original(bar, selector, item) && !MainActor.assumeIsolated {
                App.shared.tabs.contains { $0.pinned != nil && $0.window?.tab.value(forKey: "tabBarItem") as AnyObject? === item }
            }
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
    }
    static func ivar(_ name: String, of object: AnyObject) -> Any? {
        class_getInstanceVariable(type(of: object), name).flatMap { object_getIvar(object, $0) }
    }
    // The tab bar asks this once the mouse has moved far enough from a mouse-down on a tab; a pinned
    // tab answers no, so the press stays a click
    private static func refuseDraggingPinnedTabs() {
        let selector = NSSelectorFromString("_dragShouldBeginFromMouseDown:withExpiration:xHysteresis:yHysteresis:")
        guard let tabBar = NSClassFromString("NSTabBar"), let method = class_getInstanceMethod(tabBar, selector) else { return }
        typealias ShouldDrag = @convention(c) (NSView, Selector, NSEvent, AnyObject?, CGFloat, CGFloat) -> Bool
        let original = unsafeBitCast(method_getImplementation(method), to: ShouldDrag.self)
        let replacement: @convention(block) (NSView, NSEvent, AnyObject?, CGFloat, CGFloat) -> Bool = { bar, event, expiration, x, y in
            original(bar, selector, event, expiration, x, y)
                && !MainActor.assumeIsolated { App.shared.isPinnedTab(at: event.locationInWindow, in: bar) }
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
    }
    func isPinnedTab(at point: NSPoint, in bar: NSView) -> Bool {
        guard let windows = bar.window?.tabGroup?.windows else { return false }
        guard let buttons = Self.tabButtons(in: bar, for: windows),
              let index = buttons.firstIndex(where: { !$0.isHidden && $0.convert($0.bounds, to: nil).contains(point) }) else { return false }
        return tabs.contains { $0.window === windows[index] && $0.pinned != nil }
    }
    private static func keepFrames(of className: String) {
        let selector = #selector(setter: NSView.frame)
        guard let cls = NSClassFromString(className), let method = class_getInstanceMethod(cls, selector) else { return }
        typealias SetFrame = @convention(c) (NSView, Selector, NSRect) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: SetFrame.self)   // own or NSView's
        let replacement: @convention(block) (NSView, NSRect) -> Void = { view, frame in
            original(view, selector, MainActor.assumeIsolated { keptFrame(for: view, proposed: frame) })
        }
        let imp = imp_implementationWithBlock(replacement)
        if !class_addMethod(cls, selector, imp, method_getTypeEncoding(method)) { method_setImplementation(method, imp) }
    }
    // Unloaded tabs are dimmed (alphaValue, in the outline pass), but the tab bar sets every button back to
    // fully opaque when the pointer moves over it – so NSTabButton's alphaValue setter keeps a button in
    // `dimmedTabButtons` at no more than the dimmed value
    static let dimmedAlpha: CGFloat = 0.45
    static var dimmedTabButtons = Set<ObjectIdentifier>()
    private static func keepDimming() {
        let selector = #selector(setter: NSView.alphaValue)
        guard let cls = NSClassFromString("NSTabButton"), let method = class_getInstanceMethod(cls, selector) else { return }
        typealias SetAlpha = @convention(c) (NSView, Selector, CGFloat) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: SetAlpha.self)   // own or NSView's
        let replacement: @convention(block) (NSView, CGFloat) -> Void = { view, alpha in
            let dimmed = MainActor.assumeIsolated { dimmedTabButtons.contains(ObjectIdentifier(view)) }
            original(view, selector, dimmed ? min(alpha, dimmedAlpha) : alpha)
        }
        let imp = imp_implementationWithBlock(replacement)
        if !class_addMethod(cls, selector, imp, method_getTypeEncoding(method)) { method_setImplementation(method, imp) }
    }
    private static func keptFrame(for view: NSView, proposed: NSRect) -> NSRect {
        guard let kept = keptFrames[ObjectIdentifier(view)], let row = view.superview else { return proposed }
        guard row.bounds.width == kept.barWidth, row.subviews.count == kept.count else {
            relayOut(row)   // resized or tabs changed outside a full layout pass: work the frames out again
            return proposed
        }
        guard !isDraggingTab(above: row) else { return proposed }
        var frame = proposed
        frame.origin.x = kept.x
        frame.size.width = kept.width
        return frame
    }
    private static func isDraggingTab(above view: NSView) -> Bool {
        guard let bar = enclosingTabBar(of: view) else { return false }
        return ivar("_draggedTabButton", of: bar) != nil
    }
    private static func enclosingTabBar(of view: NSView) -> NSView? {
        var bar: NSView? = view
        while let v = bar, String(describing: type(of: v)) != "NSTabBar" { bar = v.superview }
        return bar
    }
    private static var pendingRelayOut = false
    private static func relayOut(_ view: NSView) {
        guard !pendingRelayOut, let bar = enclosingTabBar(of: view) else { return }
        pendingRelayOut = true
        DispatchQueue.main.async { [weak bar] in
            pendingRelayOut = false
            if let bar { App.shared.narrowPinnedTabs(in: bar) }
        }
    }
    // Lays the tab bars out again (after a style change: back to native widths, or narrowed)
    func layOutTabBars() {
        Self.keptFrames.removeAll()
        let selector = NSSelectorFromString("_layOutButtonsAnimated:")
        typealias LayOut = @convention(c) (NSView, Selector, Bool) -> Void
        var done = Set<ObjectIdentifier>()
        for tab in tabs {
            guard let group = tab.window?.tabGroup, done.insert(ObjectIdentifier(group)).inserted,
                  let frameView = (group.selectedWindow ?? tab.window)?.contentView?.superview,
                  let bar = Self.tabBar(in: frameView), bar.responds(to: selector) else { continue }
            unsafeBitCast(bar.method(for: selector), to: LayOut.self)(bar, selector, false)
        }
    }
    private static func tabBar(in view: NSView) -> NSView? {
        String(describing: type(of: view)) == "NSTabBar" ? view : view.subviews.lazy.compactMap(tabBar).first
    }
    private func narrowPinnedTabs(in bar: NSView) {
        guard let windows = bar.window?.tabGroup?.windows, !Self.isDraggingTab(above: bar) else { return }
        guard let buttons = Self.tabButtons(in: bar, for: windows), let row = buttons.first?.superview else { return }   // siblings
        // one separator per tab; the bar keeps them in tab order (_tabBarViewItemsToTabSeparators)
        let separatorMap = Self.ivar("_tabBarViewItemsToTabSeparators", of: bar) as? NSMapTable<AnyObject, NSView>
        let separators: [NSView] = windows.compactMap { window in
            (window.tab.value(forKey: "tabBarItem") as AnyObject?).flatMap { separatorMap?.object(forKey: $0) }
        }
        for view in buttons + separators { Self.keptFrames[ObjectIdentifier(view)] = nil }
        let separateRow = pinnedStyle == .separateRow
        let pages = windows.map { w in tabs.first { $0.window === w }?.pinned }
        let pinnedCount = pages.prefix { $0 != nil }.count
        let hasQuick = pages.contains { $0?.isQuick == true }
        for button in buttons where button.isHidden { button.isHidden = false }
        let hasOwnWidth = !separateRow && pages.contains { $0?.width != nil && $0?.isQuick == false }
        guard pinnedStyle == .iconAndNameCompact || separateRow || hasQuick || hasOwnWidth, pinnedCount > 0 else { return }
        // fixed widths: quick tabs and the separate row's pinned tabs 0 (hidden), icon-only 36, compact
        // icon + name: what the tab's content row needs (5 | close slot 16 | icon 16 + 6 + name (+4) | slot 16 | 5);
        // nil = shares what's left (normal tabs, full-width pinned tabs)
        let fixed = buttons.indices.map { index -> CGFloat? in
            guard index < pinnedCount, let page = pages[index] else { return nil }
            if page.isQuick || separateRow { return 0 }
            if let width = page.width { return CGFloat(width) }   // Settings → Width
            switch pinnedStyle {
            case .icon: return 36
            case .iconAndNameCompact:
                let spacing = Self.firstStack(in: buttons[index])?.spacing ?? 8
                let name = Self.firstLabel(in: buttons[index])?.intrinsicContentSize.width ?? 60
                return ceil(2 * (5 + 16 + spacing) + 16 + 6 + name + 4)
            default: return nil
            }
        }
        let gap: CGFloat = 1
        let start: CGFloat = 0, end = row.bounds.width
        let flexible = fixed.filter { $0 == nil }.count
        let visible = fixed.filter { $0 != 0 }.count
        let rest = flexible == 0 ? 0
            : (end - start - fixed.reduce(0) { $0 + ($1 ?? 0) } - gap * CGFloat(max(0, visible - 1))) / CGFloat(flexible)
        // crowded: native layout – unless that would show hidden tabs in the bar again
        guard flexible == 0 || rest >= (separateRow || hasQuick ? 1 : 100) else { return }
        let fits = fixed.map { $0 ?? rest }
        let barWidth = row.bounds.width, count = row.subviews.count
        var x = start
        for (index, button) in buttons.enumerated() {
            let width = fits[index].rounded(.down)
            Self.keptFrames[ObjectIdentifier(button)] = (x.rounded(), width, barWidth, count)
            if separators.count == buttons.count {
                let line = width == 0 ? 0 : separators[index].frame.width   // no line after a hidden tab
                Self.keptFrames[ObjectIdentifier(separators[index])] = (x.rounded() + width, line, barWidth, count)
                separators[index].frame = separators[index].frame   // the setter applies the kept frame
            }
            x += fits[index] + (width == 0 ? 0 : gap)
            if button.isHidden != (width == 0) { button.isHidden = width == 0 }   // the separate row's pinned tabs
            button.frame = button.frame
            if width > 0, button.responds(to: NSSelectorFromString("setButtonWidthForTitleLayout:")),
               (button.value(forKey: "buttonWidthForTitleLayout") as? CGFloat) != width {
                button.setValue(width, forKey: "buttonWidthForTitleLayout")
                button.needsLayout = true
            }
        }
    }

    // `next`: the tab it's opened from (stays selected if inBackground); `after`: where it goes in the tab bar
    @discardableResult
    func openTab(url: URL?, configuration: WKWebViewConfiguration? = nil, next to: Tab? = nil, after: Tab? = nil,
                 opener: Tab? = nil, newWindow: Bool = false, inBackground: Bool = false,
                 pinned: PinnedPage? = nil) -> Tab {
        isOpeningTab = true
        isOpeningInBackground = inBackground
        defer { isOpeningTab = false; isOpeningInBackground = false }
        let deferred = (pinned?.loadMode ?? .always) != .always
        let tab = Tab(load: url, configuration: configuration ?? makeConfiguration(), deferred: deferred)
        tab.opener = opener
        tab.pinned = pinned
        if deferred, let pinned { tab.window?.title = pinned.name }   // until it loads (Window menu)
        let current = newWindow ? nil : (to ?? tabs.last)?.window
        if let current, let window = tab.window {
            // Insert right after `after` (or the opener) by index; addTabbedWindow(_:ordered:) doesn't
            // reliably place it next to a tab that isn't selected
            let anchor = after?.window ?? current
            if let group = anchor.tabGroup, let index = group.windows.firstIndex(of: anchor) {
                // ordinary tabs never go in between the pinned ones
                let pinnedCount = pinned == nil ? group.windows.prefix { w in tabs.contains { $0.window === w && $0.pinned != nil } }.count : 0
                group.insertWindow(window, at: max(index + 1, pinnedCount))
            } else {
                anchor.addTabbedWindow(window, ordered: .above)
            }
        }
        tabs.append(tab)
        if let window = tab.window { observeSelection(of: window) }
        if inBackground, let current {
            current.tabGroup?.selectedWindow = current   // keep the current tab in front
            current.makeKeyAndOrderFront(nil)
        } else {
            tab.showWindow(nil)
        }
        return tab
    }

    // "(3) Inbox – Gmail" → red 3 on the Dock icon
    func updateBadge() {
        let counts = tabs.compactMap { tab in
            tab.webView.title?.firstMatch(of: #/\((\d+)\)/#).flatMap { Int($0.1) }
        }
        NSApp.dockTile.badgeLabel = (counts.max() ?? 0) > 0 ? "\(counts.max()!)" : nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        migrateQuickGroups()
        NSApp.mainMenu = buildMenu()
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let (key, mods, chars) = (event.keyCode, event.modifierFlags, event.charactersIgnoringModifiers)
            return MainActor.assumeIsolated { App.shared.handleTabShortcut(key, mods, chars) } ? nil : event
        }
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            NSLog("notifications granted=\(granted) error=\(String(describing: error))")
        }
        Diagnostics.log("launch")
        installUserScripts()
        openStartTabs()
        Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
            MainActor.assumeIsolated { App.shared.unloadIdleTabs() }
        }
        observeSleep()
        didLaunch = true
        pendingURLs.forEach(openFromOutside)
        pendingURLs = []
        NSApp.activate()
    }

    // Links sent from other apps (via Link Router or `open -a`) → new tab in the front window
    private var didLaunch = false
    private var pendingURLs: [URL] = []
    func application(_ application: NSApplication, open urls: [URL]) {
        if didLaunch { urls.forEach(openFromOutside) } else { pendingURLs += urls }
    }
    private func openFromOutside(_ url: URL) {
        let front = tabs.first { $0.window === NSApp.keyWindow } ?? tabs.last
        openTab(url: url, next: front)
        NSApp.activate()
    }
    func applicationWillTerminate(_ notification: Notification) {
        Diagnostics.log("quit")
        saveSession()
        isQuitting = true
        isRestoringOrQuitting = true   // windows closing during quit must not wipe the saved tabs
    }

    // View → Home Page (⌘⇧H): load the home page in the current tab
    @objc func goHome(_ sender: Any?) {
        let tab = tabs.first { $0.window === NSApp.keyWindow } ?? tabs.last
        if let tab { tab.open(homeURL) } else { openTab(url: homeURL) }
    }

    @objc func showSettings(_ sender: Any?) { SettingsWindow.shared.show() }
    @objc func showTabMemory(_ sender: Any?) { TabMemoryWindow.show() }

    @objc func toggleRestoreTabs(_ item: NSMenuItem) {
        restoreTabs.toggle()
        SettingsWindow.shared.general.refresh()
    }
    @objc func toggleMute(_ item: NSMenuItem) {
        isMuted.toggle()
        SettingsWindow.shared.general.refresh()
    }

    // MARK: Pinned tabs
    // Settings → Load "Unload idle": a tab that has been in the background this long gets unloaded
    var unloadAfterMinutes: Double {
        get { UserDefaults.standard.object(forKey: Setting.unloadAfter) as? Double ?? 10 }
        set { UserDefaults.standard.set(newValue, forKey: Setting.unloadAfter) }
    }
    func unloadIdleTabs() {
        let now = Date()
        for tab in tabs where tab.pinned?.loadMode == .unloadIdle && !tab.isUnloaded {
            guard let window = tab.window, (window.tabGroup?.selectedWindow ?? window) !== window else {
                tab.backgroundSince = nil   // in front
                continue
            }
            let since = tab.backgroundSince ?? now
            tab.backgroundSince = since
            if now.timeIntervalSince(since) >= unloadAfterMinutes * 60 { tab.unload("idle") }
        }
    }

    // Tabs shown dimmed while unloaded (toolbar buttons, their menus, the tab bar), and the Tab Memory list
    func loadStateChanged() {
        tabs.forEach { $0.refreshPinnedSwitcher() }
        outlinePinnedTabs()
        TabMemoryWindow.shared?.refresh()
    }

    // View → Unload Background Tabs / Unload Tab ▸: frees a tab's memory now. "Background" = everything except
    // pinned tabs (always loaded) and the tab each window shows. Opening it again loads it (where it was).
    func isBackground(_ tab: Tab) -> Bool {
        guard tab.pinned?.isQuick ?? true, let window = tab.window else { return false }
        return (window.tabGroup?.selectedWindow ?? window) !== window
    }
    var unloadableTabs: [Tab] { tabsInOrder.filter { isBackground($0) && !$0.isUnloaded } }
    // pinned, quick, then the other tabs as they sit in their windows
    var tabsInOrder: [Tab] {
        var ordered = allPinnedPages.compactMap { page in tabs.first { $0.pinned?.id == page.id } }
        var windows: [NSWindow] = []
        for tab in tabs { (tab.window?.tabbedWindows ?? tab.window.map { [$0] } ?? []).forEach { w in if !windows.contains(w) { windows.append(w) } } }
        for window in windows { if let tab = tabs.first(where: { $0.window === window }), !ordered.contains(tab) { ordered.append(tab) } }
        return ordered + tabs.filter { !ordered.contains($0) }
    }
    @objc func unloadBackgroundTabs(_ sender: Any?) { unloadableTabs.forEach { $0.unload("by hand") } }
    @objc func unloadTabFromMenu(_ item: NSMenuItem) {
        if let tab = item.representedObject as? Tab, tabs.contains(tab), isBackground(tab) { tab.unload("by hand") }
    }
    // View → Reload All Tabs (⌘⇧R): every loaded tab; unloaded ones load fresh when opened anyway
    @objc func reloadAllTabs(_ sender: Any?) { reloadLoadedTabs("by hand") }
    func reloadLoadedTabs(_ reason: String) {
        let loaded = tabs.filter { !$0.isUnloaded }
        Diagnostics.log("reload \(loaded.count) tabs (\(reason))")
        loaded.forEach { $0.webView.reload() }
    }

    // pinned tabs and quick tabs on Always, while loaded: the ones kept signed in (sign-in, waking)
    var alwaysLoadedTabs: [Tab] { tabs.filter { !$0.isUnloaded && $0.pinned?.loadMode == .always } }

    // Signed in again in `tab` (it had landed on the site's login page): the other always-loaded tabs –
    // pinned, and quick ones on Always – are signed out or about to fail too, so they're reloaded; the tab
    // itself goes back to its pinned page (sites send you to their start page after signing in)
    private var lastSignInReload = Date.distantPast
    func didSignIn(in tab: Tab) {
        guard Date().timeIntervalSince(lastSignInReload) > 30 else { return }   // no reload loops
        lastSignInReload = Date()
        let others = alwaysLoadedTabs.filter { $0 !== tab }
        Diagnostics.log("signed in: \(tab.displayName) – reload \(others.count) always-loaded tabs")
        others.forEach { $0.webView.reload() }
        if let page = tab.pinned, let url = URL(string: page.url), tab.webView.url != url { tab.open(url) }
    }

    // After the Mac (or just its screens) slept for a while (Settings, default 2 h), pages loaded before are out
    // of date: the site's session ran out, and the next click fails with "session expired" without a sign-in
    // page. So the always-loaded tabs (pinned, quick on Always) reload on waking; other tabs are left alone.
    var awaySince: Date?
    var reloadAfterSleepHours: Double {
        get { UserDefaults.standard.object(forKey: Setting.reloadAfterSleep) as? Double ?? 2 }
        set { UserDefaults.standard.set(newValue, forKey: Setting.reloadAfterSleep) }
    }
    func observeSleep() {
        let center = NSWorkspace.shared.notificationCenter
        for (name, label) in [(NSWorkspace.willSleepNotification, "sleep"), (NSWorkspace.screensDidSleepNotification, "screens sleep")] {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    Diagnostics.log(label)
                    if App.shared.awaySince == nil { App.shared.awaySince = Date() }
                }
            }
        }
        for (name, label) in [(NSWorkspace.didWakeNotification, "wake"), (NSWorkspace.screensDidWakeNotification, "screens wake")] {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { App.shared.didWake(label) }
            }
        }
    }
    func didWake(_ label: String) {
        guard let since = awaySince else { return Diagnostics.log(label) }
        awaySince = nil
        let away = Date().timeIntervalSince(since)
        Diagnostics.log("\(label) after \(Int(away / 60)) min")
        guard away >= reloadAfterSleepHours * 3600 else { return }
        let reloading = alwaysLoadedTabs
        Diagnostics.log("reload \(reloading.count) always-loaded tabs (after waking)")
        reloading.forEach { $0.webView.reload() }
    }

    // The tab you're on, also while another window (e.g. Settings) is in front
    var frontTab: Tab? { tabs.first { $0.window === NSApp.keyWindow } ?? selectedTab ?? tabs.last }

    // Pinned tab outline colour (Settings), stored as "r g b a" in sRGB; a = 0 hides the outline
    static let defaultOutlineColor = NSColor(srgbRed: 0.85, green: 0.35, blue: 0.35, alpha: 0.45)
    var outlineColor: NSColor {
        get {
            let parts = (UserDefaults.standard.string(forKey: Setting.outlineColor) ?? "")
                .split(separator: " ").compactMap { Double($0) }
            guard parts.count == 4 else { return Self.defaultOutlineColor }
            return NSColor(srgbRed: parts[0], green: parts[1], blue: parts[2], alpha: parts[3])
        }
        set {
            let c = newValue.usingColorSpace(.sRGB) ?? Self.defaultOutlineColor
            let value = [c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent]
                .map { String(format: "%.3f", $0) }.joined(separator: " ")
            UserDefaults.standard.set(value, forKey: Setting.outlineColor)
            outlinePinnedTabs()
            tabs.forEach { $0.refreshPinnedSwitcher() }
        }
    }

    var pinnedPages: [PinnedPage] {
        get { Self.pages(Setting.pinnedPages, quick: nil) }
        set { Self.store(newValue, Setting.pinnedPages, quick: nil); applyPinnedPages() }
    }
    var quickPages: [PinnedPage] {
        get { Self.pages(Setting.quickPages, quick: true) }
        set { Self.store(newValue, Setting.quickPages, quick: true); applyPinnedPages() }
    }
    // Settings: what the separate row's pinned buttons and the quick tab buttons show
    var pinnedButtonLabel: ButtonLabel {
        get { UserDefaults.standard.string(forKey: Setting.pinnedButtons).flatMap(ButtonLabel.init) ?? .iconAndName }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Setting.pinnedButtons); tabs.forEach { $0.refreshPinnedSwitcher() } }
    }
    var groupMenuLabel: ButtonLabel {
        get { UserDefaults.standard.string(forKey: Setting.groupMenus).flatMap(ButtonLabel.init) ?? .iconAndName }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Setting.groupMenus); tabs.forEach { $0.refreshPinnedSwitcher() } }
    }
    var quickButtonLabel: ButtonLabel {
        get { UserDefaults.standard.string(forKey: Setting.quickButtons).flatMap(ButtonLabel.init) ?? .iconAndName }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Setting.quickButtons); tabs.forEach { $0.refreshPinnedSwitcher() } }
    }

    // Settings → Quick tab groups; quick pages point at one by id
    var quickGroups: [QuickGroup] {
        get {
            UserDefaults.standard.data(forKey: Setting.quickGroups)
                .flatMap { try? JSONDecoder().decode([QuickGroup].self, from: $0) } ?? []
        }
        set {
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: Setting.quickGroups)
            tabs.forEach { $0.refreshPinnedSwitcher() }
        }
    }
    // Earlier drafts kept a group as a name on each quick page (+ a name → colour map): make real groups
    func migrateQuickGroups() {
        var pages = quickPages
        guard pages.contains(where: { $0.group != nil }) else { return }
        var groups = quickGroups
        let colors = UserDefaults.standard.dictionary(forKey: Setting.legacyGroupColors) as? [String: String] ?? [:]
        for index in pages.indices {
            defer { pages[index].group = nil }
            guard pages[index].groupId == nil,
                  let name = pages[index].group?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { continue }
            if let group = groups.first(where: { $0.name == name }) {
                pages[index].groupId = group.id
            } else {
                let group = QuickGroup(name: name, color: colors[name])
                groups.append(group)
                pages[index].groupId = group.id
            }
        }
        UserDefaults.standard.set(try? JSONEncoder().encode(groups), forKey: Setting.quickGroups)
        Self.store(pages, Setting.quickPages, quick: true)
        UserDefaults.standard.removeObject(forKey: Setting.legacyGroupColors)
    }
    // the order the tabs keep: pinned first, then the quick tabs
    var allPinnedPages: [PinnedPage] { pinnedPages + quickPages }
    private static func pages(_ key: String, quick: Bool?) -> [PinnedPage] {
        (UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode([PinnedPage].self, from: $0) } ?? [])
            .map { var page = $0; page.quick = quick; return page }
    }
    private static func store(_ pages: [PinnedPage], _ key: String, quick: Bool?) {
        let pages = pages.map { var page = $0; page.quick = quick; return page }
        UserDefaults.standard.set(try? JSONEncoder().encode(pages), forKey: key)
    }

    // Make the open tabs match the list: pin, unpin, rename, open new ones, keep them first and in order
    func applyPinnedPages() {
        let pages = allPinnedPages
        let keyWindow = NSApp.keyWindow, selected = selectedTab?.window   // put back afterwards
        for tab in tabs where tab.pinned != nil && !pages.contains(where: { $0.id == tab.pinned?.id }) {
            tab.pinned = nil
        }
        var ordered: [Tab] = []
        for page in pages {
            if let tab = tabs.first(where: { $0.pinned?.id == page.id }) {
                let addressChanged = tab.pinned?.url != page.url
                tab.pinned = page
                if addressChanged, let url = URL(string: page.url) { tab.open(url) }
                if page.loadMode == .always { tab.loadIfNeeded() }
                ordered.append(tab)
            } else if let url = URL(string: page.url) {
                let anchor = ordered.last ?? frontTab
                ordered.append(openTab(url: url, next: anchor, after: anchor, inBackground: anchor != nil, pinned: page))
            }
        }
        // Move them to the front of their window's tab bar, in list order
        if let group = ordered.first?.window?.tabGroup {
            for (index, tab) in ordered.enumerated() {
                guard let window = tab.window, let at = group.windows.firstIndex(of: window), at != index else { continue }
                group.removeWindow(window)
                group.insertWindow(window, at: index)
            }
        }
        if let selected { selected.tabGroup?.selectedWindow = selected }
        keyWindow?.makeKeyAndOrderFront(nil)
        tabs.forEach { $0.updateToolbar(); $0.refreshPinnedSwitcher() }
        updateTabBarVisibility()
        saveSession()
    }

    // "Separate row above the tabs": the tab bar (with its +) stays hidden until a tab besides the pinned
    // ones is open. It's a titlebar accessory of the tabbed windows, which can be hidden (toggleTabBar
    // can't hide it while a window has 2+ tabs). Every tab window has that accessory, but the tab bar
    // view inside it moves to whichever tab is selected – so all of them are hidden/shown together
    // (this app adds no accessories of its own). Otherwise switching tabs resizes the page each time.
    func updateTabBarVisibility() {
        for tab in tabs {
            guard let window = tab.window, let group = window.tabGroup else { continue }
            // tabs the bar shows: quick tabs never, pinned ones unless they're in the separate row
            let pages = group.windows.map { w in tabs.first { $0.window === w }?.pinned }
            let pinnedShown = pages.filter { $0 != nil && $0?.isQuick == false && pinnedStyle != .separateRow }.count
            let shown = pinnedShown + pages.filter { $0 == nil }.count
            // hidden only when it would show nothing, or (like macOS) when the window is a single ordinary tab;
            // next to pinned / quick tabs, even one opened tab shows
            let hide = shown == 0 || group.windows.count == 1 && pinnedShown == 0
            for accessory in window.titlebarAccessoryViewControllers where accessory.isHidden != hide {
                accessory.isHidden = hide
            }
            // a window with a single tab (only a pinned one) has no tab bar unless it's toggled on
            // (View → Show Tab Bar); that only works for a single tab, so it's used just here
            if group.windows.count == 1, group.isTabBarVisible == hide, window.tabGroup?.selectedWindow === window {
                window.toggleTabBar(nil)
            }
        }
    }

    // Pinned tabs are locked: first, in list order, together in one window. Drags from a pinned tab are
    // refused (see hookTabBarLayout); whatever still moves them – a tab dropped in between, a pinned tab
    // pulled out into its own window – is put back once the mouse is up. Other tabs move freely.
    private var isKeepingPinnedInPlace = false
    func keepPinnedTabsInPlace() {
        guard !isKeepingPinnedInPlace, !isQuitting else { return }
        isKeepingPinnedInPlace = true
        DispatchQueue.main.async { [self] in
            guard NSEvent.pressedMouseButtons == 0 else {   // still dragging: look again in a moment
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.isKeepingPinnedInPlace = false; self.keepPinnedTabsInPlace() }
                return
            }
            defer { isKeepingPinnedInPlace = false }
            let pinnedTabs = allPinnedPages.compactMap { page in tabs.first { $0.pinned?.id == page.id } }
            // home: the window holding most pinned tabs (then the one with most tabs)
            let groups = pinnedTabs.compactMap { $0.window?.tabGroup }
            guard let home = groups.max(by: { a, b in
                let (pa, pb) = (groups.filter { $0 === a }.count, groups.filter { $0 === b }.count)
                return pa != pb ? pa < pb : a.windows.count < b.windows.count
            }) else { return }
            let inPlace = pinnedTabs.enumerated().allSatisfy { index, tab in
                home.windows.indices.contains(index) && home.windows[index] === tab.window
            }
            guard !inPlace else { return }
            let keyWindow = NSApp.keyWindow, selected = home.selectedWindow
            for (index, tab) in pinnedTabs.enumerated() {
                guard let window = tab.window, home.windows.firstIndex(of: window) != index else { continue }
                window.tabGroup?.removeWindow(window)
                home.insertWindow(window, at: min(index, home.windows.count))
            }
            if let selected, home.windows.contains(selected) { home.selectedWindow = selected }
            keyWindow?.makeKeyAndOrderFront(nil)
            tabs.forEach { $0.applyPinnedLook() }   // a tab dropped into macOS's pinned area gets unpinned again
            saveSession()
        }
    }


    // MARK: Restore tabs — saved on every page/tab change, so it survives crashes and force quits too
    struct SavedWindow: Codable { var urls: [String]; var selected: Int; var frame: String?; var pinnedSelected: Int? }
    private var isRestoringOrQuitting = false

    // Last window size/position, ignored if that spot is no longer on any screen (e.g. monitor unplugged)
    func savedFrame(_ string: String? = UserDefaults.standard.string(forKey: Setting.windowFrame)) -> NSRect? {
        guard let string else { return nil }
        let frame = NSRectFromString(string)
        let visible = frame.width >= 300 && frame.height >= 200
            && NSScreen.screens.contains { $0.visibleFrame.intersects(frame) }
        return visible ? frame : nil
    }

    func saveSession() {
        guard !isRestoringOrQuitting else { return }
        var seen = Set<ObjectIdentifier>(), saved: [SavedWindow] = []
        for tab in tabs {
            guard let window = tab.window, !seen.contains(ObjectIdentifier(window)) else { continue }
            let group = (window.tabbedWindows ?? [window]).compactMap { w in tabs.first { $0.window === w } }
            group.forEach { if let w = $0.window { seen.insert(ObjectIdentifier(w)) } }
            let pinnedTabs = group.filter { $0.pinned != nil }
            let pages = group.filter { $0.pinned == nil }.compactMap { t in t.pageURL.map { (tab: t, url: $0.absoluteString) } }
            let selectedWindow = window.tabGroup?.selectedWindow
            let selected = pages.firstIndex { $0.tab.window === selectedWindow } ?? 0
            let pinnedSelected = pinnedTabs.firstIndex { $0.window === selectedWindow }
            let frame = (selectedWindow ?? window).frame
            if !pages.isEmpty || pinnedSelected != nil {
                saved.append(SavedWindow(urls: pages.map(\.url), selected: selected, frame: NSStringFromRect(frame),
                                         pinnedSelected: pinnedSelected))
            }
        }
        UserDefaults.standard.set(try? JSONEncoder().encode(saved), forKey: Setting.session)
    }

    // On launch: the pinned tabs, then (if Restore Tabs is on) the other tabs from last time, or the home page
    func openStartTabs() {
        isRestoringOrQuitting = true
        var pinnedTabs: [Tab] = []
        for page in allPinnedPages {
            guard let url = URL(string: page.url) else { continue }
            pinnedTabs.append(openTab(url: url, next: pinnedTabs.last, newWindow: pinnedTabs.isEmpty,
                                      inBackground: !pinnedTabs.isEmpty, pinned: page))
        }
        var saved: [SavedWindow] = []
        if restoreTabs, let data = UserDefaults.standard.data(forKey: Setting.session) {
            saved = (try? JSONDecoder().decode([SavedWindow].self, from: data)) ?? []
        }
        for (index, window) in saved.enumerated() {
            var group = index == 0 ? pinnedTabs : []   // the first window continues after the pinned tabs
            let first = group.count
            for url in window.urls.compactMap(URL.init(string:)) {
                group.append(openTab(url: url, next: group.last, newWindow: group.isEmpty, inBackground: !group.isEmpty))
            }
            // With a single window, the last moved/resized position wins over the copy in the session
            let frame = saved.count == 1 ? savedFrame() ?? savedFrame(window.frame) : savedFrame(window.frame)
            if let frame, first == 0 { group.first?.window?.setFrame(frame, display: true) }
            let selected = window.pinnedSelected.map { $0 } ?? first + window.selected
            if group.indices.contains(selected) { group[selected].window?.makeKeyAndOrderFront(nil) }
        }
        if saved.isEmpty || saved[0].pinnedSelected == nil && saved[0].urls.isEmpty {
            pinnedTabs.first?.window?.makeKeyAndOrderFront(nil)
        }
        isRestoringOrQuitting = false
        if tabs.isEmpty && pendingURLs.isEmpty { openTab(url: homeURL) }
        saveSession()
        loadStateChanged()   // each toolbar was drawn while its tab opened, before the later tabs existed
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { openTab(url: homeURL) }
        return true
    }

    // ⌃Tab / ⌃⇧Tab / ⌘1…⌘9, handled before the web view can swallow them
    func handleTabShortcut(_ keyCode: UInt16, _ flags: NSEvent.ModifierFlags, _ chars: String?) -> Bool {
        guard let window = NSApp.keyWindow ?? selectedTab?.window, window.attachedSheet == nil else { return false }
        let mods = flags.intersection(.deviceIndependentFlagsMask)
        let group = window.tabbedWindows ?? [window]
        // quick tabs are left out: they're reached through their toolbar buttons only
        let isQuick = { (w: NSWindow) in self.tabs.contains { $0.window === w && $0.pinned?.isQuick == true } }
        if keyCode == 48, mods.contains(.control) {
            // the cycle skips quick tabs; on one, they count as sitting before the first pinned tab:
            // ⌃Tab goes to the first tab, ⌃⇧Tab to the last
            let cycle = group.filter { !isQuick($0) }
            let backwards = mods.contains(.shift)
            let selected = window.tabGroup?.selectedWindow ?? window
            let target: NSWindow?
            if let current = cycle.firstIndex(of: selected) {
                target = cycle[safe: ((current + (backwards ? -1 : 1)) % cycle.count + cycle.count) % cycle.count]
            } else {
                target = backwards ? cycle.last : cycle.first
            }
            target?.makeKeyAndOrderFront(nil)
            return true
        }
        if mods == .command, let n = Int(chars ?? ""), (1...9).contains(n) {
            let tabsInOrder = group.filter { !isQuick($0) }
            let target = n == 9 ? tabsInOrder.last : tabsInOrder[safe: n - 1]
            target?.makeKeyAndOrderFront(nil)
            return true
        }
        return false
    }
}

// MARK: Reopen closed tabs (⌘⇧T and File → Recently Closed), for this session
extension App: NSMenuItemValidation, NSMenuDelegate {
    struct ClosedTab { let url: URL; let title: String; weak var after: Tab? }

    func rememberClosed(_ tab: Tab) {
        guard !isQuitting, let url = tab.pageURL else { return }
        let title = (tab.closingInfo?.title ?? tab.webView.title).flatMap { $0.isEmpty ? nil : $0 } ?? url.absoluteString
        closedTabs.append(ClosedTab(url: url, title: title, after: tab.closingInfo?.leftNeighbour))
    }

    @objc func reopenClosedTab(_ sender: Any?) {
        if let closed = closedTabs.popLast() { reopen(closed) }
    }
    @objc func reopenFromMenu(_ item: NSMenuItem) {
        guard let index = item.representedObject as? Int, closedTabs.indices.contains(index) else { return }
        reopen(closedTabs.remove(at: index))
    }
    // Back where it was (after its old left neighbour) if that tab is still open, else after the current tab
    private func reopen(_ closed: ClosedTab) {
        let anchor = closed.after.flatMap { tabs.contains($0) ? $0 : nil }
        openTab(url: closed.url, next: anchor ?? tabs.first { $0.window === NSApp.keyWindow } ?? tabs.last)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(reopenClosedTab(_:)): !closedTabs.isEmpty
        case #selector(closeTab(_:)): NSApp.keyWindow != nil
        case #selector(unloadBackgroundTabs(_:)): !unloadableTabs.isEmpty
        case #selector(toggleRestoreTabs(_:)): { item.state = restoreTabs ? .on : .off; return true }()
        case #selector(toggleMute(_:)): { item.state = isMuted ? .on : .off; return true }()
        default: true
        }
    }
    // ⌘W: closes a tab, but takes a pinned tab back to its pinned page (pinned tabs never close)
    @objc func closeTab(_ sender: Any?) {
        let window = (NSApp.keyWindow ?? selectedTab?.window).map { $0.tabGroup?.selectedWindow ?? $0 }   // the tab you're looking at
        if let tab = tabs.first(where: { $0.window === window }), let page = tab.pinned {
            if let url = URL(string: page.url) { tab.open(url) }
        } else {
            window?.performClose(sender)
        }
    }
    // View → Unload Tab ▸: the background tabs that are loaded
    // Clicking one unloads it and takes it off the list, with the menu still open for the next one
    private func fillUnloadMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let imageColumn = unloadableTabs.contains { $0.pinned != nil }   // quick tabs have icons: titles line up after them
        for tab in unloadableTabs {
            let title = tab.displayName.count > 60 ? tab.displayName.prefix(59) + "…" : tab.displayName
            let item = NSMenuItem(title: title, action: #selector(unloadTabFromMenu(_:)), keyEquivalent: "")
            item.target = self   // the action is for the keyboard (Return), which closes the menu as usual
            item.representedObject = tab
            item.image = tab.pinned?.iconImage
            item.toolTip = tab.pageURL?.absoluteString
            item.view = StayOpenMenuItemView(title: title, image: item.image, imageColumn: imageColumn) { [weak self, weak item, weak menu] in
                guard let self, let item, let menu else { return }
                self.unloadTabFromMenu(item)
                menu.removeItem(item)
                if menu.items.isEmpty { menu.addItem(Self.noBackgroundTabsItem()) }
                menu.supermenu?.update()   // Unload Background Tabs: disabled once nothing's left…
                menu.supermenu?.items.forEach { $0.view?.needsDisplay = true }   // …and drawn so right away
            }
            menu.addItem(item)
        }
        if menu.items.isEmpty { menu.addItem(Self.noBackgroundTabsItem()) }
    }
    // the submenu sets its items' enabled state itself (autoenablesItems off): an item added while the menu
    // is open isn't validated, so this one stayed clickable
    private static func noBackgroundTabsItem() -> NSMenuItem {
        let item = NSMenuItem(title: "No Background Tabs", action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }
    // after Unload Background Tabs, with the menu still open: the list is empty now
    func refreshUnloadMenu() {
        let view = NSApp.mainMenu?.items.first { $0.submenu?.title == "View" }?.submenu
        guard let menu = view?.items.first(where: { $0.submenu?.title == "Unload Tab" })?.submenu else { return }
        fillUnloadMenu(menu)
    }
    // File → Recently Closed lists every tab closed this session, newest first
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu.title == "Unload Tab" { return fillUnloadMenu(menu) }
        menu.removeAllItems()
        for (index, closed) in closedTabs.enumerated().reversed() {
            let title = closed.title.count > 60 ? closed.title.prefix(59) + "…" : closed.title
            let item = NSMenuItem(title: title, action: #selector(reopenFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = index
            item.toolTip = closed.url.absoluteString
            menu.addItem(item)
        }
        if closedTabs.isEmpty { menu.addItem(withTitle: "No Closed Tabs", action: nil, keyEquivalent: "") }
    }
}

// MARK: Downloads — the app is the delegate so a download outlives the tab that started it
extension App: WKDownloadDelegate {
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        // Never fail because the file exists: "name.pdf" → "name (1).pdf", like Safari
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let name = (suggestedFilename as NSString).deletingPathExtension
        let ext = (suggestedFilename as NSString).pathExtension
        var destination = dir.appendingPathComponent(suggestedFilename)
        var n = 1
        let inProgress = Set(downloads.values)   // not on disk until they finish
        while FileManager.default.fileExists(atPath: destination.path) || inProgress.contains(destination) {
            destination = dir.appendingPathComponent("\(name) (\(n))" + (ext.isEmpty ? "" : ".\(ext)"))
            n += 1
        }
        downloads[ObjectIdentifier(download)] = destination
        completionHandler(destination)
    }

    // Bounce the Downloads stack in the Dock and post a notification; clicking it shows the file in Finder
    func downloadDidFinish(_ download: WKDownload) {
        guard let file = downloads.removeValue(forKey: ObjectIdentifier(download)) else { return }
        DistributedNotificationCenter.default().post(name: .init("com.apple.DownloadFileFinished"), object: file.path)
        let content = UNMutableNotificationContent()
        content.title = "Downloaded"
        content.body = file.lastPathComponent
        content.userInfo = ["file": file.path]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: file.path, content: content, trigger: nil))
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let file = downloads.removeValue(forKey: ObjectIdentifier(download))
        let alert = NSAlert()
        alert.messageText = "Download failed"
        alert.informativeText = [file?.lastPathComponent, error.localizedDescription].compactMap { $0 }.joined(separator: "\n")
        alert.runModal()
    }
}

// notification key (tag + title + body) → when it was shown, to drop the copies other tabs post
@MainActor private var recentNotifications: [String: Date] = [:]

extension App: WKScriptMessageHandler, UNUserNotificationCenterDelegate {
    // The page created a Notification → post it to macOS
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let tab = tabs.first(where: { $0.webView === message.webView }) else { return }
        let center = UNUserNotificationCenter.current()
        if let closed = body["close"] as? String {
            center.removeDeliveredNotifications(withIdentifiers: [tab.id + closed, "tag:" + closed])
            return
        }
        let jsID = body["id"] as? String ?? ""
        let tag = body["tag"] as? String ?? ""
        let title = body["title"] as? String ?? "", text = body["body"] as? String ?? ""
        // Every pinned / quick tab runs its own copy of the site, and each posts the same notification
        // (Gmail: one per open Gmail page). Show it once: skip a repeat of the same one within 10 s.
        let key = [tag, title, text].joined(separator: "\u{1}")
        let now = Date()
        recentNotifications = recentNotifications.filter { now.timeIntervalSince($0.value) < 10 }
        guard recentNotifications[key] == nil else { return }
        recentNotifications[key] = now
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = text
        content.sound = .default
        content.userInfo = ["tab": tab.id, "id": jsID]
        // a tagged notification replaces the earlier one with that tag, as in browsers (one per app, not per tab)
        center.add(UNNotificationRequest(identifier: tag.isEmpty ? tab.id + jsID : "tag:" + tag, content: content, trigger: nil)) {
            if let error = $0 { NSLog("notification failed: \(error)") }
        }
    }

    // Show banners even while the app is in front
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions { [.banner, .sound] }

    // Clicked a notification → bring its tab forward and fire the page's onclick
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        if let file = info["file"] as? String {
            await MainActor.run { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file)]) }
            return
        }
        let tabID = info["tab"] as? String ?? ""
        let jsID = (info["id"] as? String ?? "").filter(\.isNumber)
        await MainActor.run {
            guard let tab = App.shared.tabs.first(where: { $0.id == tabID }) else { return }
            NSApp.activate()
            tab.window?.makeKeyAndOrderFront(nil)
            tab.webView.evaluateJavaScript("window.__nativeNotificationClicked && window.__nativeNotificationClicked('\(jsID)')")
        }
    }
}

// Hex colours for the Settings colour field: "#RRGGBB" or "#RRGGBBAA" (AA = opacity), "#" optional,
// "#RGB" shorthand too; sRGB
extension NSColor {
    convenience init?(hex text: String) {
        var hex = text.trimmingCharacters(in: .whitespaces).uppercased()
        if hex.hasPrefix("#") { hex.removeFirst() }
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard [6, 8].contains(hex.count), let value = UInt64(hex, radix: 16) else { return nil }
        let rgba = hex.count == 8 ? value : value << 8 | 0xFF
        self.init(srgbRed: CGFloat(rgba >> 24 & 0xFF) / 255, green: CGFloat(rgba >> 16 & 0xFF) / 255,
                  blue: CGFloat(rgba >> 8 & 0xFF) / 255, alpha: CGFloat(rgba & 0xFF) / 255)
    }

    // "#RRGGBB", plus "AA" when not fully opaque
    var hexString: String {
        let c = usingColorSpace(.sRGB) ?? self
        let parts = [c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent].map { Int(($0 * 255).rounded()) }
        let rgb = String(format: "#%02X%02X%02X", parts[0], parts[1], parts[2])
        return parts[3] == 255 ? rgb : rgb + String(format: "%02X", parts[3])
    }
}

// "github.com/settings" → https://github.com/settings; nil if it isn't a web address
func webURL(from text: String) -> URL? {
    var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return nil }
    if !text.contains("://") { text = "https://" + text }
    guard let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil
    else { return nil }
    return url
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

// "Separate row above the tabs" and quick tabs: the pages as pills in the toolbar, tinted with the outline colour
// (Settings → Outline colour): faint when not selected, stronger when selected, outlined like the tabs.
final class PinnedSwitcher: NSStackView {
    var onSelect: ((Int) -> Void)?

    // icon + name with fixed padding; the background is the view's own layer, so it always fits the content
    final class Pill: NSView {
        let icon = NSImageView()
        let label = NSTextField(labelWithString: "")
        let chevron = NSImageView(image: Pill.chevronImage)   // group buttons: opens a menu
        // chevron.down drawn centred (on its own size) in a 12×16 canvas, the icons' height – as a plain symbol
        // image the view placed it by the symbol's alignment rect, a little above the text's middle
        static let chevronImage: NSImage = {
            let symbol = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "menu")!
                .withSymbolConfiguration(.init(pointSize: 10, weight: .bold))!
            let image = NSImage(size: NSSize(width: 12, height: 16), flipped: false) { rect in
                let size = symbol.size
                symbol.draw(in: NSRect(x: (rect.width - size.width) / 2, y: (rect.height - size.height) / 2,
                                       width: size.width, height: size.height))
                return true
            }
            image.isTemplate = true
            return image
        }()
        var onPress: (() -> Void)?
        // Settings → Width; nil = as wide as the content
        var fixedWidth: CGFloat? {
            didSet {
                widthConstraint.constant = fixedWidth ?? 0
                widthConstraint.isActive = fixedWidth != nil
            }
        }
        private lazy var widthConstraint = widthAnchor.constraint(equalToConstant: 0)

        init() {
            super.init(frame: .zero)
            wantsLayer = true
            layer?.cornerRadius = 13
            layer?.borderWidth = 1
            icon.contentTintColor = .labelColor
            label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
            label.lineBreakMode = .byTruncatingTail   // a narrow fixed width shortens the name…
            label.setContentCompressionResistancePriority(.init(100), for: .horizontal)
            let row = NSStackView()
            row.setViews([icon, label, chevron], in: .center)   // centred when a set Width is wider than the content
            chevron.isHidden = true
            row.spacing = 5
            row.edgeInsets = NSEdgeInsets(top: 0, left: 11, bottom: 0, right: 12)
            row.translatesAutoresizingMaskIntoConstraints = false
            addSubview(row)
            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: leadingAnchor), row.trailingAnchor.constraint(equalTo: trailingAnchor),
                row.topAnchor.constraint(equalTo: topAnchor), row.bottomAnchor.constraint(equalTo: bottomAnchor),
                heightAnchor.constraint(equalToConstant: 26),
                icon.widthAnchor.constraint(equalToConstant: 16), icon.heightAnchor.constraint(equalToConstant: 16),
                chevron.widthAnchor.constraint(equalToConstant: 12), chevron.heightAnchor.constraint(equalToConstant: 16),
            ])
            setAccessibilityElement(true)
            setAccessibilityRole(.button)
        }
        required init?(coder: NSCoder) { fatalError() }
        override func mouseDown(with event: NSEvent) {}
        override func mouseUp(with event: NSEvent) {
            if bounds.contains(convert(event.locationInWindow, from: nil)) { onPress?() }
        }
        override func accessibilityPerformPress() -> Bool { onPress?(); return true }
        // …and when even that doesn't fit next to the icon, only the icon shows (the name is in the tooltip)
        func fitLabel() {
            guard let width = fixedWidth, !icon.isHidden, !label.isHidden else { return }
            let needed = 11 + 16 + 5 + label.intrinsicContentSize.width + 12 + (chevron.isHidden ? 0 : 5 + 10)
            if width < needed { label.isHidden = true }
        }
    }

    private var pages: [PinnedPage] = []
    private var selected: Int?
    private var groups: [QuickGroup] = []
    private var menuLabel = ButtonLabel.iconAndName   // what a group's menu items show
    private var unloaded: Set<String> = []            // ids of pages whose tab is unloaded: shown dimmed
    // one entry per page, or per group: its pages, at the place of the first of them
    private var entries: [(group: QuickGroup?, indices: [Int])] {
        var entries: [(group: QuickGroup?, indices: [Int])] = []
        for (index, page) in pages.enumerated() {
            let group = page.groupId.flatMap { id in groups.first { $0.id == id } }
            if let group, let at = entries.firstIndex(where: { $0.group?.id == group.id }) {
                entries[at].indices.append(index)
            } else {
                entries.append((group, [index]))
            }
        }
        return entries
    }

    // color: the default; a page's own colour, or its group's, wins
    func update(pages: [PinnedPage], selected: Int?, color: NSColor, groups: [QuickGroup] = [],
                show: ButtonLabel = .iconAndName, menus: ButtonLabel = .iconAndName, unloaded: Set<String> = []) {
        self.pages = pages
        self.unloaded = unloaded
        self.selected = selected
        self.groups = groups
        self.menuLabel = menus
        spacing = 6
        // the toolbar's glass capsule ends exactly at the item's edge – keep the pills inside its rounded
        // end (26 px pills in a 36 px capsule → 5 px all round)
        edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 5)
        let entries = entries
        while arrangedSubviews.count > entries.count { arrangedSubviews.last?.removeFromSuperview() }
        while arrangedSubviews.count < entries.count { addArrangedSubview(Pill()) }
        for (view, entry) in zip(arrangedSubviews, entries) {
            guard let pill = view as? Pill else { continue }
            let isSelected = selected.map(entry.indices.contains) ?? false
            let own = entry.group.map(\.tint) ?? pages[entry.indices[0]].tint
            let rgb = (own ?? color).usingColorSpace(.sRGB) ?? color
            let alpha = rgb.alphaComponent
            if let group = entry.group {
                // a group: the open page's icon (or the first one's), its name ▾, and a menu on click
                let shown = pages[isSelected ? selected! : entry.indices[0]]
                pill.icon.image = group.iconImage ?? shown.iconImage   // its own icon, else the open page's
                pill.label.stringValue = group.name
                pill.label.isHidden = show == .icon
                pill.icon.isHidden = show == .name
                pill.chevron.isHidden = false
                let names = entry.indices.map { pages[$0].name }.joined(separator: ", ")
                pill.toolTip = show == .icon ? "\(group.name): \(names)" : names
                pill.fixedWidth = group.width.map { CGFloat($0) }
                pill.fitLabel()
                pill.setAccessibilityLabel(group.name)
                pill.onPress = { [weak self, weak pill] in
                    guard let self, let pill else { return }
                    self.menu(for: entry.indices).popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: pill)
                }
            } else {
                let index = entry.indices[0], page = pages[index]
                pill.icon.image = page.iconImage
                pill.label.stringValue = page.name
                pill.icon.isHidden = show == .name
                pill.label.isHidden = show == .icon
                pill.chevron.isHidden = true
                pill.toolTip = show == .icon ? "\(page.name) – \(page.url)" : page.url
                pill.fixedWidth = page.width.map { CGFloat($0) }
                pill.fitLabel()
                pill.setAccessibilityLabel(page.name)
                pill.onPress = { [weak self] in self?.onSelect?(index) }
            }
            // unloaded (a group: all of its pages) → dimmed
            pill.alphaValue = entry.indices.allSatisfy { unloaded.contains(pages[$0].id) } ? 0.45 : 1
            pill.label.textColor = isSelected ? .labelColor : .secondaryLabelColor
            pill.chevron.contentTintColor = pill.label.textColor
            pill.setAccessibilityValue(isSelected ? "selected" : nil)
            // with no colour (opacity 0) the selected one still gets a neutral background
            let background = alpha < 0.05 ? (isSelected ? NSColor.quaternaryLabelColor : .clear)
                : rgb.withAlphaComponent(isSelected ? max(alpha, 0.6) : alpha * 0.35)
            pill.effectiveAppearance.performAsCurrentDrawingAppearance {
                pill.layer?.backgroundColor = background.cgColor
                pill.layer?.borderColor = rgb.withAlphaComponent(alpha < 0.05 ? 0 : max(alpha, 0.5)).cgColor
            }
        }
    }

    // the pages at `indices` (a group's dropdown, items as Settings → "Menus show"), the open one ticked
    func menu(for indices: [Int], show: ButtonLabel? = nil) -> NSMenu {
        let show = show ?? menuLabel
        let menu = NSMenu()
        for index in indices {
            let item = NSMenuItem(title: show == .icon ? "" : pages[index].name, action: #selector(picked(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.image = show == .name ? nil : pages[index].iconImage
            item.toolTip = show == .icon ? pages[index].name : nil
            if unloaded.contains(pages[index].id) {   // dimmed, like its button
                if !item.title.isEmpty {
                    item.attributedTitle = NSAttributedString(string: item.title, attributes: [
                        .foregroundColor: NSColor.tertiaryLabelColor, .font: NSFont.menuFont(ofSize: 0)])
                }
                item.image = item.image.map(Self.dimmed)
                item.toolTip = (item.toolTip.map { $0 + " – " } ?? "") + "not loaded"
            }
            item.state = index == selected ? .on : .off
            menu.addItem(item)
        }
        return menu
    }
    // Everything, for the toolbar's » overflow menu when the window is too narrow: groups as submenus
    func overflowMenu() -> NSMenu {
        let menu = NSMenu()
        for entry in entries {
            if let group = entry.group {
                let item = NSMenuItem(title: group.name, action: nil, keyEquivalent: "")
                item.image = group.iconImage
                    ?? pages[selected.flatMap { entry.indices.contains($0) ? $0 : nil } ?? entry.indices[0]].iconImage
                item.submenu = self.menu(for: entry.indices, show: .iconAndName)
                menu.addItem(item)
            } else {
                self.menu(for: entry.indices, show: .iconAndName).items.forEach { $0.menu?.removeItem($0); menu.addItem($0) }
            }
        }
        return menu
    }
    @objc private func picked(_ item: NSMenuItem) { onSelect?(item.tag) }
    private static func dimmed(_ image: NSImage) -> NSImage {
        let copy = NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 0.4)
            return true
        }
        copy.isTemplate = image.isTemplate
        return copy
    }
}

// View → Tab Memory: every tab with its state and memory (what Activity Monitor shows for its web content
// process), Unload / Reload, and the total. Refreshed every 2 s while open; double-click a row to go there.
@MainActor
final class TabMemoryWindow: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private(set) static var shared: TabMemoryWindow?
    static func show() {
        let controller = shared ?? TabMemoryWindow()
        shared = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.refresh()
    }

    private let table = NSTableView()
    private let total = NSTextField(labelWithString: "")
    private var rows: [(tab: Tab, memory: UInt64?)] = []
    private var timer: Timer?

    init() {
        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "WebAppTabs"
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 380),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "\(name) – Tab Memory"
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 640, height: 220)
        window.setFrameAutosaveName("tabMemory")
        super.init(window: window)
        window.delegate = self
        for (id, title, width) in [("tab", "Tab", 250.0), ("kind", "Kind", 56.0), ("state", "State", 104.0),
                                   ("memory", "Memory", 76.0), ("actions", "", 150.0)] {
            let column = NSTableColumn(identifier: .init(id))
            column.title = title
            column.width = width
            if id == "memory" { column.headerCell.alignment = .right }
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 24
        table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle   // the Tab column takes the window's width
        table.doubleAction = #selector(goToTab)
        table.target = self
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let unloadAll = NSButton(title: "Unload Background Tabs", target: App.shared, action: #selector(App.unloadBackgroundTabs(_:)))
        let reloadAll = NSButton(title: "Reload All Tabs", target: App.shared, action: #selector(App.reloadAllTabs(_:)))
        total.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        total.textColor = .secondaryLabelColor
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let bottom = NSStackView(views: [total, spacer, reloadAll, unloadAll])
        let root = NSView()
        for view in [scroll, bottom] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            bottom.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 10),
            bottom.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            bottom.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            bottom.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
        ])
        window.contentView = root
        window.center()
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let isEscape = event.keyCode == 53, windowNumber = event.windowNumber
            let handled = isEscape && MainActor.assumeIsolated {
                guard let window = self?.window, window.windowNumber == windowNumber else { return false }
                window.performClose(nil)   // Esc, as in Settings
                return true
            }
            return handled ? nil : event
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    func windowDidBecomeKey(_ notification: Notification) { startTimer() }
    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
    }
    private func startTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated { TabMemoryWindow.shared?.refresh() }
        }
    }

    // Each tab's web content process ID is private API (`_webProcessIdentifier`; 0 = none); its memory is
    // the process's footprint – Activity Monitor's "Memory" column
    static func processID(of tab: Tab) -> pid_t? {
        guard !tab.isUnloaded, tab.webView.responds(to: NSSelectorFromString("_webProcessIdentifier")),
              let pid = tab.webView.value(forKey: "_webProcessIdentifier") as? pid_t, pid > 0 else { return nil }
        return pid
    }
    static func footprint(of pid: pid_t) -> UInt64? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        return result == 0 ? info.ri_phys_footprint : nil
    }
    static func format(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }

    func refresh() {
        guard window?.isVisible == true || rows.isEmpty else { return }
        let selected = table.selectedRow >= 0 && table.selectedRow < rows.count ? rows[table.selectedRow].tab : nil
        var seen = Set<pid_t>(), sum: UInt64 = 0
        rows = App.shared.tabsInOrder.map { tab in
            let pid = Self.processID(of: tab)
            let memory = pid.flatMap(Self.footprint)
            if let pid, let memory, seen.insert(pid).inserted { sum += memory }   // a process shared by tabs counts once
            return (tab, memory)
        }
        table.reloadData()
        if let selected, let row = rows.firstIndex(where: { $0.tab === selected }) {
            table.selectRowIndexes([row], byExtendingSelection: false)
        }
        let loaded = rows.filter { !$0.tab.isUnloaded }.count
        let app = Self.footprint(of: getpid()).map { " · the app itself: \(Self.format($0))" } ?? ""
        total.stringValue = "\(loaded) of \(rows.count) tabs loaded: \(Self.format(sum))\(app)"
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        let (tab, memory) = rows[row]
        let shown = tab.window.map { ($0.tabGroup?.selectedWindow ?? $0) === $0 } ?? false
        switch column?.identifier.rawValue {
        case "tab":
            let label = NSTextField(labelWithString: tab.displayName)
            label.lineBreakMode = .byTruncatingTail
            label.toolTip = tab.pageURL?.absoluteString
            let icon = NSImageView(image: tab.pinned?.iconImage ?? NSImage(systemSymbolName: "doc", accessibilityDescription: nil)!)
            icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
            let cell = NSStackView(views: [icon, label])
            cell.spacing = 6
            cell.alphaValue = tab.isUnloaded ? 0.45 : 1
            return cell
        case "kind":
            return NSTextField(labelWithString: tab.pinned.map { $0.isQuick ? "Quick" : "Pinned" } ?? "Tab")
        case "state":
            let state = tab.isUnloaded ? (tab.hasLoaded ? "Unloaded" : "Not loaded yet") : shown ? "Loaded, shown" : "Loaded"
            return NSTextField(labelWithString: state)
        case "memory":
            let label = NSTextField(labelWithString: memory.map(Self.format) ?? "–")
            label.alignment = .right
            return label
        default:
            let unload = NSButton(title: "Unload", target: self, action: #selector(unloadRow(_:)))
            let reload = NSButton(title: "Reload", target: self, action: #selector(reloadRow(_:)))
            for button in [unload, reload] {
                button.controlSize = .small
                button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
                button.tag = row
            }
            unload.isEnabled = App.shared.isBackground(tab) && !tab.isUnloaded
            unload.toolTip = tab.pinned?.isQuick == false ? "Pinned tabs are always loaded"
                : shown ? "The tab you're looking at stays loaded" : nil
            reload.isEnabled = !tab.isUnloaded
            return NSStackView(views: [unload, reload])
        }
    }
    @objc private func unloadRow(_ sender: NSButton) {
        guard rows.indices.contains(sender.tag) else { return }
        let tab = rows[sender.tag].tab
        if App.shared.tabs.contains(tab), App.shared.isBackground(tab) { tab.unload("by hand") }
    }
    @objc private func reloadRow(_ sender: NSButton) {
        guard rows.indices.contains(sender.tag), !rows[sender.tag].tab.isUnloaded else { return }
        rows[sender.tag].tab.webView.reload()
    }
    @objc private func goToTab() {
        guard rows.indices.contains(table.clickedRow), let window = rows[table.clickedRow].tab.window else { return }
        window.tabGroup?.selectedWindow = window
        window.makeKeyAndOrderFront(nil)
    }
}

// The shared colour panel, driven by one colour cell at a time (Settings lists). The Default colour well
// uses the same panel; while it's active, changes are left to it.
@MainActor
final class ColorPicker: NSObject {
    static let shared = ColorPicker()
    var willPick: () -> Void = {}            // e.g. deactivate the Default colour well
    var isBlocked: () -> Bool = { false }    // the Default colour well took the panel over
    private var onChange: ((NSColor) -> Void)?

    func pick(_ color: NSColor, onChange: @escaping (NSColor) -> Void) {
        willPick()
        let panel = NSColorPanel.shared
        panel.showsAlpha = true
        self.onChange = nil
        panel.color = color
        self.onChange = onChange
        panel.setTarget(self)
        panel.setAction(#selector(changed(_:)))
        panel.orderFront(nil)
    }
    func stop() {
        onChange = nil
        NSColorPanel.shared.setTarget(nil)
        NSColorPanel.shared.setAction(nil)
    }
    @objc private func changed(_ panel: NSColorPanel) {
        if isBlocked() { return stop() }
        onChange?(panel.color)
    }
}

/// "" → nil (default), a valid colour → its hex, anything else → .invalid
enum ColorInput { case clear, color(String), invalid }
func parseColor(_ text: String) -> ColorInput {
    let text = text.trimmingCharacters(in: .whitespaces)
    if text.isEmpty { return .clear }
    return NSColor(hex: text).map { .color($0.hexString) } ?? .invalid
}

// MARK: Settings window (⌘,): toolbar tabs General / Pinned Tabs / Quick Tabs / Loading, saved per app.
// Every change is saved and applied right away (App.pinnedPages / quickPages / quickGroups setters).

// Building blocks of the Settings panes
@MainActor
enum Form {
    static func heading(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        return label
    }
    static func hint(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        return label
    }
    // one short line, and an ⓘ with the full explanation (tooltip, or a popover on click)
    static func hint(_ text: String, more: String) -> NSView {
        let label = hint(text)
        label.setContentCompressionResistancePriority(.init(100), for: .horizontal)
        let row = NSStackView(views: [label, InfoButton(more)])
        row.spacing = 4
        row.alignment = .centerY
        return row
    }
    static func label(_ text: String) -> NSTextField { NSTextField(labelWithString: text) }
    static func field(width: CGFloat? = nil, placeholder: String? = nil, delegate: NSTextFieldDelegate) -> NSTextField {
        let field = NSTextField()
        field.placeholderString = placeholder
        field.delegate = delegate
        field.lineBreakMode = .byTruncatingTail
        if let width { field.widthAnchor.constraint(equalToConstant: width).isActive = true }
        return field
    }
    static func row(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
        let row = NSStackView(views: views)
        row.spacing = spacing
        return row
    }
    // label | control rows; labels right-aligned; `wide` rows stretch to the grid's width
    static func grid(_ rows: [[NSView]]) -> NSGridView {
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 10
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        return grid
    }
    // a vertical stack of sections, top-left, with the window's margins
    static func page(_ views: [NSView]) -> NSView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        let root = NSView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -20),
        ])
        return root
    }
    // a single-column list (icon + name rows), scrolling, in a rounded box
    static func list(style: NSTableView.Style = .inset) -> (NSView, NSTableView) {
        let table = NSTableView()
        table.addTableColumn(NSTableColumn(identifier: .init("item")))
        table.headerView = nil
        table.style = style
        table.rowHeight = 26
        table.backgroundColor = .clear
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let box = NSBox()
        box.boxType = .custom
        box.cornerRadius = 9
        box.borderWidth = 1
        box.borderColor = .separatorColor
        box.fillColor = NSColor.labelColor.withAlphaComponent(0.04)
        box.contentViewMargins = .zero
        box.contentView = scroll
        return (box, table)
    }
    static func cell(_ image: NSImage?, _ text: String, detail: String? = nil) -> NSView {
        let icon = NSImageView(image: image ?? NSImage())
        icon.contentTintColor = .labelColor
        icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 16).isActive = true
        let label = NSTextField(labelWithString: text)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.init(100), for: .horizontal)
        var views: [NSView] = [icon, label]
        if let detail {
            let spacer = NSView()
            spacer.setContentHuggingPriority(.init(1), for: .horizontal)
            let count = NSTextField(labelWithString: detail)
            count.textColor = .secondaryLabelColor
            views += [spacer, count]
        }
        let row = NSStackView(views: views)
        row.spacing = 7
        row.edgeInsets = NSEdgeInsets(top: 0, left: 2, bottom: 0, right: 4)
        return row
    }
    static func plusMinus(target: AnyObject, add: Selector, remove: Selector, addTip: String, removeTip: String) -> NSStackView {
        let plus = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "Add")!, target: target, action: add)
        let minus = NSButton(image: NSImage(systemSymbolName: "minus", accessibilityDescription: "Remove")!, target: target, action: remove)
        plus.toolTip = addTip
        minus.toolTip = removeTip
        for button in [plus, minus] {   // rounded squares
            button.bezelStyle = .flexiblePush
            button.widthAnchor.constraint(equalToConstant: 26).isActive = true
            button.heightAnchor.constraint(equalToConstant: 26).isActive = true
        }
        return row([plus, minus], spacing: 4)
    }
    static func popup(_ titles: [String], target: AnyObject, action: Selector) -> NSPopUpButton {
        let popup = NSPopUpButton()
        popup.addItems(withTitles: titles)
        popup.target = target
        popup.action = action
        return popup
    }
    // "10" for whole numbers, "1.5" otherwise
    static func number(_ value: Double) -> String { value == value.rounded() ? String(Int(value)) : String(value) }
}

// A menu item that does its action without closing the menu (View → Unload Tab ▸ / Unload Background Tabs, so
// you can unload one tab after another). A standard item always closes the menu when clicked; an item with a
// view gets the clicks itself, but then has to draw its title, image and highlight too.
@MainActor
final class StayOpenMenuItemView: NSView {
    private let title: String
    private let image: NSImage?
    private let titleX: CGFloat
    private let onClick: () -> Void
    private static let font = NSFont.menuFont(ofSize: 0)
    // where AppKit draws (measured on macOS 26): a title at 16, or at 36 when the menu section has images
    // (which then sit at 18); `imageColumn` = this item's section has images
    init(title: String, image: NSImage?, imageColumn: Bool, onClick: @escaping () -> Void) {
        self.title = title
        self.image = image
        self.titleX = imageColumn || image != nil ? 36 : 16
        self.onClick = onClick
        let width = titleX + (title as NSString).size(withAttributes: [.font: Self.font]).width + 24
        super.init(frame: NSRect(x: 0, y: 0, width: ceil(width), height: 24))
        autoresizingMask = .width
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        let item = enclosingMenuItem
        let enabled = item?.isEnabled ?? true
        let highlighted = enabled && item?.isHighlighted == true
        if highlighted {
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 1), xRadius: 6, yRadius: 6).fill()
        }
        let color: NSColor = !enabled ? .disabledControlTextColor : highlighted ? .selectedMenuItemTextColor : .controlTextColor
        if let image {
            let tinted = NSImage(size: image.size, flipped: false) { rect in
                image.draw(in: rect)
                if image.isTemplate { color.set(); rect.fill(using: .sourceAtop) }
                return true
            }
            tinted.draw(in: NSRect(x: 18, y: (bounds.height - 16) / 2, width: 16, height: 16))
        }
        let text = NSAttributedString(string: title, attributes: [.font: Self.font, .foregroundColor: color])
        text.draw(at: NSPoint(x: titleX, y: (bounds.height - text.size().height) / 2))
    }
    override func mouseUp(with event: NSEvent) {
        guard enclosingMenuItem?.isEnabled ?? true, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick()
        needsDisplay = true
    }
}

// The ⓘ after a hint: hover for the full text as a tooltip, click for it in a popover
@MainActor
final class InfoButton: NSButton {
    private let text: String
    init(_ text: String) {
        self.text = text
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: "More information")
        imagePosition = .imageOnly
        isBordered = false
        contentTintColor = .secondaryLabelColor
        toolTip = text
        target = self
        action = #selector(showText)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func showText() {
        // the text 300 pt wide (without a width the popover shrank it to a sliver), the popover sized to fit it
        let width: CGFloat = 300
        let label = NSTextField(wrappingLabelWithString: text)
        label.preferredMaxLayoutWidth = width
        let height = ceil(label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 10_000)).height ?? 40)
        let box = NSView(frame: NSRect(x: 0, y: 0, width: width + 28, height: height + 24))
        label.frame = NSRect(x: 14, y: 12, width: width, height: height)
        box.addSubview(label)
        let controller = NSViewController()
        controller.view = box
        controller.preferredContentSize = box.frame.size
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        popover.contentSize = box.frame.size
        popover.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
    }
}

// Colour: swatch (click → colour panel) + "#RRGGBBAA" field + Default; nil = the default colour
@MainActor
final class ColorField: NSStackView, NSTextFieldDelegate {
    var onChange: (String?) -> Void = { _ in }
    var hex: String? { didSet { refresh() } }
    private let swatch = NSButton(title: "", target: nil, action: nil)
    private let hexField = NSTextField()
    init() {
        super.init(frame: .zero)
        swatch.target = self
        swatch.action = #selector(pick)
        swatch.isBordered = false
        swatch.wantsLayer = true
        swatch.layer?.cornerRadius = 5
        swatch.layer?.borderWidth = 1
        swatch.layer?.borderColor = NSColor.separatorColor.cgColor
        swatch.toolTip = "Pick a colour"
        swatch.widthAnchor.constraint(equalToConstant: 34).isActive = true
        swatch.heightAnchor.constraint(equalToConstant: 20).isActive = true
        hexField.placeholderString = "default"
        hexField.delegate = self
        hexField.toolTip = "#RRGGBB or #RRGGBBAA (AA = opacity); empty = the default colour"
        hexField.widthAnchor.constraint(equalToConstant: 96).isActive = true
        let reset = NSButton(title: "Default", target: self, action: #selector(clear))
        reset.controlSize = .small
        setViews([swatch, hexField, reset], in: .leading)
        spacing = 8
    }
    required init?(coder: NSCoder) { fatalError() }
    func refresh() {
        let color = hex.flatMap(NSColor.init(hex:))
        swatch.layer?.backgroundColor = (color ?? App.shared.outlineColor.withAlphaComponent(0.25)).cgColor
        hexField.stringValue = color?.hexString ?? ""
    }
    @objc private func pick() {
        ColorPicker.shared.pick(hex.flatMap(NSColor.init(hex:)) ?? App.shared.outlineColor) { [weak self] color in
            self?.hex = color.hexString
            self?.onChange(self?.hex)
        }
    }
    @objc private func clear() {
        ColorPicker.shared.stop()
        hex = nil
        onChange(nil)
    }
    func controlTextDidEndEditing(_ notification: Notification) {
        switch parseColor(hexField.stringValue) {
        case .clear: hex = nil
        case .color(let value): hex = value
        case .invalid: NSSound.beep(); return refresh()
        }
        onChange(hex)
    }
}

// Icon: the text (letters, emoji, SF Symbol name, image path / address) and a large preview of what it shows
@MainActor
final class IconField: NSStackView {
    let field: NSTextField
    private let preview = NSImageView()
    init(delegate: NSTextFieldDelegate) {
        field = Form.field(width: 170, delegate: delegate)
        super.init(frame: .zero)
        field.toolTip = "1–2 letters, an emoji, an SF Symbol name like checklist, or an image file path / web address "
            + "(e.g. a site's favicon.ico)"
        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.contentTintColor = .labelColor
        preview.wantsLayer = true
        preview.layer?.cornerRadius = 6
        preview.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.15).cgColor
        preview.widthAnchor.constraint(equalToConstant: 32).isActive = true
        preview.heightAnchor.constraint(equalToConstant: 32).isActive = true
        setViews([field, preview, InfoButton("1–2 letters, an emoji, an SF Symbol name like checklist, or an image file path / "
                                             + "web address (e.g. a site's favicon.ico). The preview shows how it looks.")], in: .leading)
        spacing = 10
    }
    required init?(coder: NSCoder) { fatalError() }
    func show(_ text: String, image: NSImage?) {
        field.stringValue = text
        preview.image = image
    }
}

// The selected pinned / quick tab's settings
@MainActor
final class PageForm: NSView, NSTextFieldDelegate {
    var onChange: (PinnedPage) -> Void = { _ in }
    private(set) var page: PinnedPage?
    private let quick: Bool
    private lazy var icon = IconField(delegate: self)
    private lazy var name = Form.field(width: 260, delegate: self)
    private lazy var address = Form.field(width: 320, placeholder: "https://…", delegate: self)
    private let color = ColorField()
    private lazy var width = Form.field(width: 60, placeholder: "auto", delegate: self)
    private lazy var group = Form.popup([], target: self, action: #selector(groupChosen))
    private lazy var load = Form.popup(LoadMode.allCases.map(\.title), target: self, action: #selector(loadChosen))
    private let loadHelp = Form.hint("")
    private let empty = Form.hint("Select a page, or add one with +")

    init(quick: Bool) {
        self.quick = quick
        super.init(frame: .zero)
        width.alignment = .right
        width.toolTip = "Width in points (24–800); empty = automatic"
        color.onChange = { [weak self] hex in self?.change { $0.color = hex } }
        var rows: [[NSView]] = [
            [Form.label("Icon:"), icon],
            [Form.label("Name:"), name],
            [Form.label("Address:"), address],
            [Form.label("Colour:"), color],
            [Form.label("Width:"), Form.row([width, Form.hint(quick ? "points; its toolbar button" : "points; its tab or button")])],
        ]
        if quick {
            group.toolTip = "The group whose toolbar button lists this page (Quick tab groups, on the left)"
            rows += [[Form.label("Group:"), group], [Form.label("Load:"), load], [NSGridCell.emptyContentView, loadHelp]]
            loadHelp.preferredMaxLayoutWidth = 320
        }
        let grid = Form.grid(rows)
        for view in [grid, empty] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: topAnchor),
            grid.leadingAnchor.constraint(equalTo: leadingAnchor),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            empty.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            empty.leadingAnchor.constraint(equalTo: leadingAnchor),
        ])
        show(nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(_ page: PinnedPage?, groups: [QuickGroup] = []) {
        if page?.id != self.page?.id { ColorPicker.shared.stop() }   // the panel was editing another page
        self.page = page
        subviews.first { $0 is NSGridView }?.isHidden = page == nil
        empty.isHidden = page != nil
        guard let page else { return }
        icon.show(page.icon ?? "", image: page.iconImage)
        icon.field.placeholderString = page.shownIcon
        name.stringValue = page.name
        address.stringValue = page.url
        color.hex = page.color
        width.stringValue = page.width.map { String(Int($0)) } ?? ""
        if quick {
            group.removeAllItems()
            group.addItem(withTitle: "None")
            for item in groups {
                group.addItem(withTitle: item.name)
                group.lastItem?.representedObject = item.id
            }
            group.selectItem(at: groups.firstIndex { $0.id == page.groupId }.map { $0 + 1 } ?? 0)
            load.selectItem(at: LoadMode.allCases.firstIndex(of: page.loadMode) ?? 0)
            loadHelp.stringValue = page.loadMode.help
        }
    }
    private func change(_ edit: (inout PinnedPage) -> Void) {
        guard var page else { return }
        edit(&page)
        self.page = page
        icon.show(page.icon ?? "", image: page.iconImage)
        icon.field.placeholderString = page.shownIcon
        onChange(page)
    }
    func focusName() { window?.makeFirstResponder(name) }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, let page else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespaces)
        switch field {
        case icon.field: change { $0.icon = PinnedPage.normalizedIcon(text) }
        case name: if text.isEmpty { name.stringValue = page.name } else { change { $0.name = text } }
        case address:
            guard let url = webURL(from: text) else { NSSound.beep(); address.stringValue = page.url; return }
            address.stringValue = url.absoluteString
            change { $0.url = url.absoluteString }
        case width:
            switch parseWidth(text) {
            case .clear: change { $0.width = nil }
            case .width(let value): change { $0.width = value }
            case .invalid: NSSound.beep(); width.stringValue = page.width.map { String(Int($0)) } ?? ""
            }
        default: break
        }
    }
    @objc private func groupChosen() { change { $0.groupId = group.selectedItem?.representedObject as? String } }
    @objc private func loadChosen() {
        let mode = LoadMode.allCases[load.indexOfSelectedItem]
        loadHelp.stringValue = mode.help
        change { $0.load = mode == .always ? nil : mode }
    }
}

// The selected quick tab group's settings
@MainActor
final class GroupForm: NSView, NSTextFieldDelegate {
    var onChange: (QuickGroup) -> Void = { _ in }
    private(set) var group: QuickGroup?
    private lazy var icon = IconField(delegate: self)
    private lazy var name = Form.field(width: 260, delegate: self)
    private let color = ColorField()
    private lazy var width = Form.field(width: 60, placeholder: "auto", delegate: self)

    override init(frame: NSRect) {
        super.init(frame: frame)
        width.alignment = .right
        width.toolTip = "Width in points (24–800); empty = automatic"
        icon.field.placeholderString = "open page's icon"
        color.onChange = { [weak self] hex in self?.change { $0.color = hex } }
        let grid = Form.grid([
            [Form.label("Icon:"), icon],
            [NSGridCell.emptyContentView, Form.hint("Empty: the icon of the group's open page")],
            [Form.label("Name:"), name],
            [Form.label("Colour:"), color],
            [Form.label("Width:"), Form.row([width, Form.hint("points; the group's toolbar button")])],
            [NSGridCell.emptyContentView, Form.hint("Add quick tabs with their Group menu, or drag them onto the group.")],
        ])
        grid.translatesAutoresizingMaskIntoConstraints = false
        addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: topAnchor),
            grid.leadingAnchor.constraint(equalTo: leadingAnchor),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(_ group: QuickGroup) {
        if group.id != self.group?.id { ColorPicker.shared.stop() }
        self.group = group
        icon.show(group.icon ?? "", image: group.iconImage)
        name.stringValue = group.name
        color.hex = group.color
        width.stringValue = group.width.map { String(Int($0)) } ?? ""
    }
    private func change(_ edit: (inout QuickGroup) -> Void) {
        guard var group else { return }
        edit(&group)
        self.group = group
        icon.show(group.icon ?? "", image: group.iconImage)
        onChange(group)
    }
    func focusName() { window?.makeFirstResponder(name) }
    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, let group else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespaces)
        switch field {
        case icon.field: change { $0.icon = PinnedPage.normalizedIcon(text) }
        case name: if text.isEmpty { name.stringValue = group.name } else { change { $0.name = text } }
        case width:
            switch parseWidth(text) {
            case .clear: change { $0.width = nil }
            case .width(let value): change { $0.width = value }
            case .invalid: NSSound.beep(); width.stringValue = group.width.map { String(Int($0)) } ?? ""
            }
        default: break
        }
    }
}

// A new page starts from the one you're on
@MainActor
func pageFromFrontTab(quick: Bool, groupId: String? = nil) -> PinnedPage {
    let tab = App.shared.frontTab
    let title = tab?.webView.title.map { String($0.prefix(20)) } ?? ""
    var page = PinnedPage(name: title.isEmpty ? "New" : title, url: tab?.pageURL?.absoluteString ?? homeURL.absoluteString)
    page.quick = quick ? true : nil
    page.groupId = groupId
    return page
}

private let pageRowType = NSPasteboard.PasteboardType("local.webapptabs.page-row")

// Settings → General
@MainActor
final class GeneralPane: NSObject, NSTextFieldDelegate {
    lazy var view: NSView = build()
    let home = NSTextField()
    let colorWell = NSColorWell(style: .default)
    let hexField = NSTextField()
    let restore = NSButton(checkboxWithTitle: "Restore tabs on launch", target: nil, action: nil)
    let mute = NSButton(checkboxWithTitle: "Mute site", target: nil, action: nil)

    private func build() -> NSView {
        home.placeholderString = defaultHomeURL.absoluteString
        home.delegate = self
        home.widthAnchor.constraint(equalToConstant: 420).isActive = true
        colorWell.target = self
        colorWell.action = #selector(colorChanged)
        NSColorPanel.shared.showsAlpha = true
        hexField.placeholderString = "#RRGGBBAA"
        hexField.toolTip = "#RRGGBB or #RRGGBBAA – the last two digits are the opacity (00 = no outline)"
        hexField.delegate = self
        hexField.widthAnchor.constraint(equalToConstant: 96).isActive = true
        let reset = NSButton(title: "Default", target: self, action: #selector(resetColor))
        reset.controlSize = .small
        ColorPicker.shared.willPick = { [weak self] in self?.colorWell.deactivate() }
        ColorPicker.shared.isBlocked = { [weak self] in self?.colorWell.isActive ?? false }
        restore.target = self
        restore.action = #selector(toggled(_:))
        mute.target = self
        mute.action = #selector(toggled(_:))
        let grid = Form.grid([
            [Form.label("Home page:"), home],
            [NSGridCell.emptyContentView, Form.hint("Opened by New Tab (⌘T) and View → Home Page (⌘⇧H). Empty: \(defaultHomeURL.absoluteString)")],
            [Form.label("Default colour:"), Form.row([colorWell, hexField, reset])],
            [NSGridCell.emptyContentView, Form.hint("Outlines and buttons of tabs without their own colour",
                                                    more: "Opacity 0 (…00) = no outline")],
            [Form.label("Tabs:"), restore],
            [NSGridCell.emptyContentView, Form.hint("Reopens the tabs you had open, and the window's size and place")],
            [Form.label("Sound:"), mute],
            [NSGridCell.emptyContentView, Form.hint("Stops the site from playing sounds")],
        ])
        return Form.page([grid])
    }
    func refresh() {
        _ = view
        home.stringValue = UserDefaults.standard.string(forKey: Setting.homeURL) ?? ""
        colorWell.color = App.shared.outlineColor
        hexField.stringValue = App.shared.outlineColor.hexString
        restore.state = App.shared.restoreTabs ? .on : .off
        mute.state = App.shared.isMuted ? .on : .off
    }
    @objc private func toggled(_ box: NSButton) {
        if box === restore { App.shared.restoreTabs = box.state == .on } else { App.shared.isMuted = box.state == .on }
    }
    @objc private func colorChanged() {
        App.shared.outlineColor = colorWell.color
        hexField.stringValue = App.shared.outlineColor.hexString
        SettingsWindow.shared.defaultColorChanged()
    }
    @objc private func resetColor() {
        UserDefaults.standard.removeObject(forKey: Setting.outlineColor)
        App.shared.outlinePinnedTabs()
        App.shared.tabs.forEach { $0.refreshPinnedSwitcher() }
        refresh()
        SettingsWindow.shared.defaultColorChanged()
    }
    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        if field === home {
            let text = home.stringValue.trimmingCharacters(in: .whitespaces)
            if text.isEmpty { return UserDefaults.standard.removeObject(forKey: Setting.homeURL) }
            guard let url = webURL(from: text) else { return NSSound.beep() }
            UserDefaults.standard.set(url.absoluteString, forKey: Setting.homeURL)
            home.stringValue = url.absoluteString
        } else if field === hexField {
            guard let color = NSColor(hex: field.stringValue) else { NSSound.beep(); return refresh() }
            App.shared.outlineColor = color
            refresh()
            SettingsWindow.shared.defaultColorChanged()
        }
    }
}

// Settings → Pinned Tabs: style, then the list (left) and the selected page's settings (right)
@MainActor
final class PinnedPane: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    lazy var view: NSView = build()
    let style = NSPopUpButton()
    let buttons = NSPopUpButton()
    let (scroll, table) = Form.list()
    let form = PageForm(quick: false)
    private(set) var pages: [PinnedPage] = []

    private func build() -> NSView {
        style.addItems(withTitles: PinnedStyle.allCases.map(\.title))
        style.target = self
        style.action = #selector(styleChanged)
        buttons.addItems(withTitles: ButtonLabel.allCases.map(\.title))
        buttons.target = self
        buttons.action = #selector(buttonsChanged)
        buttons.toolTip = "What the separate row's buttons show"
        table.dataSource = self
        table.delegate = self
        table.registerForDraggedTypes([pageRowType])
        form.onChange = { [weak self] page in self?.update(page) }
        let add = Form.plusMinus(target: self, add: #selector(addPage), remove: #selector(removePage),
                                 addTip: "Add the page you're on", removeTip: "Remove the selected page")
        let top = Form.row([Form.label("Pinned tabs show:"), style, Form.label("  Buttons:"), buttons])
        let intro = Form.hint("Open first at every launch and always loaded. They can't be closed or moved; ⌘W takes one back to its page.",
                              more: "⌘1, ⌘2… count them first. Drag the list to reorder.")
        return SettingsWindow.listAndForm(top: [top, intro], list: scroll, below: add, form: form)
    }
    func reload() {
        _ = view
        pages = App.shared.pinnedPages
        style.selectItem(at: PinnedStyle.allCases.firstIndex(of: App.shared.pinnedStyle) ?? 0)
        buttons.selectItem(at: ButtonLabel.allCases.firstIndex(of: App.shared.pinnedButtonLabel) ?? 0)
        buttons.isEnabled = App.shared.pinnedStyle == .separateRow   // only the separate row has buttons
        let selected = form.page?.id
        table.reloadData()
        select(pages.firstIndex { $0.id == selected } ?? (pages.isEmpty ? nil : 0))
    }
    private func select(_ row: Int?) {
        if let row { table.selectRowIndexes([row], byExtendingSelection: false) } else { table.deselectAll(nil) }
        form.show(row.flatMap { pages[safe: $0] })
    }
    private func save() { App.shared.pinnedPages = pages }
    private func update(_ page: PinnedPage) {
        guard let row = pages.firstIndex(where: { $0.id == page.id }) else { return }
        pages[row] = page
        table.reloadData(forRowIndexes: [row], columnIndexes: [0])
        save()
    }
    @objc private func styleChanged() {
        App.shared.pinnedStyle = PinnedStyle.allCases[style.indexOfSelectedItem]
        buttons.isEnabled = App.shared.pinnedStyle == .separateRow
    }
    @objc private func buttonsChanged() { App.shared.pinnedButtonLabel = ButtonLabel.allCases[buttons.indexOfSelectedItem] }
    @objc private func addPage() {
        pages.append(pageFromFrontTab(quick: false))
        table.reloadData()
        save()
        select(pages.count - 1)
        form.focusName()
    }
    @objc private func removePage() {
        guard pages.indices.contains(table.selectedRow) else { return NSSound.beep() }
        let row = table.selectedRow
        pages.remove(at: row)
        table.reloadData()
        save()
        select(pages.isEmpty ? nil : min(row, pages.count - 1))
    }

    func numberOfRows(in tableView: NSTableView) -> Int { pages.count }
    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        Form.cell(pages[row].iconImage, pages[row].name)
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        form.show(pages[safe: table.selectedRow])
    }
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let item = NSPasteboardItem()
        item.setString(pages[row].id, forType: pageRowType)
        return item
    }
    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
        guard info.draggingPasteboard.string(forType: pageRowType) != nil else { return [] }
        if operation == .on { tableView.setDropRow(row, dropOperation: .above) }
        return .move
    }
    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        guard let id = info.draggingPasteboard.string(forType: pageRowType),
              let from = pages.firstIndex(where: { $0.id == id }) else { return false }
        let page = pages.remove(at: from)
        let to = from < row ? row - 1 : row
        pages.insert(page, at: to)
        table.reloadData()
        save()
        select(to)
        return true
    }
}

// Settings → Quick Tabs: on the left the groups (top) and the quick tabs (below), with a divider between them;
// on the right the selected quick tab's or group's settings
@MainActor
final class QuickPane: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSplitViewDelegate {
    lazy var view: NSView = build()
    let buttons = NSPopUpButton()
    let menus = NSPopUpButton()
    let (groupScroll, groupTable) = Form.list()
    let (pageScroll, pageTable) = Form.list()
    let pageForm = PageForm(quick: true)
    let groupForm = GroupForm()
    private let empty = Form.hint("Select a group or a quick tab, or add one with +")
    private(set) var pages: [PinnedPage] = []
    private(set) var groups: [QuickGroup] = []
    private var syncing = false   // selecting in one list clears the other

    private func build() -> NSView {
        buttons.addItems(withTitles: ButtonLabel.allCases.map(\.title))
        menus.addItems(withTitles: ButtonLabel.allCases.map(\.title))
        for popup in [buttons, menus] {
            popup.target = self
            popup.action = #selector(labelsChanged(_:))
        }
        for table in [groupTable, pageTable] {
            table.dataSource = self
            table.delegate = self
            table.registerForDraggedTypes([pageRowType])
        }
        pageForm.onChange = { [weak self] page in self?.update(page) }
        groupForm.onChange = { [weak self] group in self?.update(group) }
        let top = Form.row([Form.label("Buttons show:"), buttons, Form.label("  Group menus:"), menus])
        let intro = Form.hint("Buttons at the right end of the toolbar, for pages you open now and then.",
                              more: "Quick tabs aren't in the tab bar, and ⌃Tab / ⌘1… skip them. Like pinned tabs they're locked "
                                + "and ⌘W takes one back to its page. A group is one toolbar button, \u{201C}Name ⌄\u{201D}, with a "
                                + "menu of its quick tabs: put a quick tab in a group with its Group menu, or drag it onto the group.")
        let groupButtons = Form.plusMinus(target: self, add: #selector(addGroup), remove: #selector(removeGroup),
                                          addTip: "Add a group", removeTip: "Remove the selected group (its quick tabs stay, without a group)")
        let pageButtons = Form.plusMinus(target: self, add: #selector(addPage), remove: #selector(removePage),
                                         addTip: "Add the page you're on", removeTip: "Remove the selected quick tab")
        // the two lists, one above the other; the divider between them can be dragged (remembered)
        let split = NSSplitView()
        split.isVertical = false
        split.dividerStyle = .thin
        split.delegate = self
        for pane in [Self.listPane("Groups", groupScroll, groupButtons), Self.listPane("Quick tabs", pageScroll, pageButtons)] {
            pane.translatesAutoresizingMaskIntoConstraints = true   // frames set by the split view
            pane.autoresizingMask = [.width, .height]
            split.addSubview(pane)
        }
        split.autosaveName = "quickTabsLists"
        split.widthAnchor.constraint(equalToConstant: 240).isActive = true
        let forms = NSView()
        for view in [pageForm, groupForm, empty] {
            view.translatesAutoresizingMaskIntoConstraints = false
            forms.addSubview(view)
            NSLayoutConstraint.activate([   // the whole height, so every field can be clicked
                view.topAnchor.constraint(equalTo: forms.topAnchor, constant: view === empty ? 4 : 0),
                view.leadingAnchor.constraint(equalTo: forms.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: forms.trailingAnchor),
            ])
            if view !== empty { view.bottomAnchor.constraint(equalTo: forms.bottomAnchor).isActive = true }
        }
        return SettingsWindow.columns(top: [top, intro], [split], form: forms)
    }
    // a heading, the list taking the spare height, + / − below
    private static func listPane(_ title: String, _ list: NSView, _ buttons: NSView) -> NSView {
        let label = Form.label(title)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        label.textColor = .secondaryLabelColor
        let pane = NSStackView(views: [label, list, buttons])
        pane.orientation = .vertical
        pane.alignment = .leading
        pane.spacing = 6
        pane.distribution = .fill
        pane.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 8, right: 0)
        list.widthAnchor.constraint(equalTo: pane.widthAnchor).isActive = true
        list.setContentHuggingPriority(.init(1), for: .vertical)
        list.setContentCompressionResistancePriority(.init(1), for: .vertical)
        return pane
    }
    // each list keeps a few rows; resizing the window shares the height in proportion
    static let minListPane: CGFloat = 130
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposed: CGFloat, ofSubviewAt index: Int) -> CGFloat {
        splitView.subviews[index].frame.minY + Self.minListPane
    }
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposed: CGFloat, ofSubviewAt index: Int) -> CGFloat {
        splitView.subviews[index + 1].frame.maxY - Self.minListPane - splitView.dividerThickness
    }
    func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
        let panes = splitView.subviews, divider = splitView.dividerThickness
        guard panes.count == 2 else { return splitView.adjustSubviews() }
        let available = splitView.bounds.height - divider
        let oldTotal = panes[0].frame.height + panes[1].frame.height
        let share = oldTotal > 1 ? panes[0].frame.height / oldTotal : 0.35   // first layout: groups ~1/3
        let top = min(max(Self.minListPane, (available * share).rounded()), max(Self.minListPane, available - Self.minListPane))
        panes[0].frame = NSRect(x: 0, y: 0, width: splitView.bounds.width, height: top)
        panes[1].frame = NSRect(x: 0, y: top + divider, width: splitView.bounds.width, height: max(0, available - top))
    }

    func reload() {
        _ = view
        pages = App.shared.quickPages
        groups = App.shared.quickGroups
        buttons.selectItem(at: ButtonLabel.allCases.firstIndex(of: App.shared.quickButtonLabel) ?? 0)
        menus.selectItem(at: ButtonLabel.allCases.firstIndex(of: App.shared.groupMenuLabel) ?? 0)
        let page = pageForm.page?.id, group = pageForm.page == nil ? groupForm.group?.id : nil
        groupTable.reloadData()
        pageTable.reloadData()
        if let row = groups.firstIndex(where: { $0.id == group }) {
            select(group: row)
        } else {
            select(page: pages.firstIndex { $0.id == page } ?? (pages.isEmpty ? nil : 0))
        }
    }
    private func select(page row: Int?) {
        syncing = true
        groupTable.deselectAll(nil)
        if let row { pageTable.selectRowIndexes([row], byExtendingSelection: false) } else { pageTable.deselectAll(nil) }
        syncing = false
        showForm()
    }
    private func select(group row: Int) {
        syncing = true
        pageTable.deselectAll(nil)
        groupTable.selectRowIndexes([row], byExtendingSelection: false)
        syncing = false
        showForm()
    }
    // the right side: the selected quick tab, or the selected group, or a hint
    private func showForm() {
        let page = pages[safe: pageTable.selectedRow]
        let group = page == nil ? groups[safe: groupTable.selectedRow] : nil
        pageForm.show(page, groups: groups)
        pageForm.isHidden = page == nil
        if let group { groupForm.show(group) }
        groupForm.isHidden = group == nil
        empty.isHidden = page != nil || group != nil
    }
    private func savePages() { App.shared.quickPages = pages }
    private func saveGroups() { App.shared.quickGroups = groups }
    private func refreshRows() {   // group counts and the quick tabs' group names
        groupTable.reloadData(forRowIndexes: IndexSet(0..<groupTable.numberOfRows), columnIndexes: [0])
        pageTable.reloadData(forRowIndexes: IndexSet(0..<pageTable.numberOfRows), columnIndexes: [0])
    }
    private func update(_ page: PinnedPage) {
        guard let index = pages.firstIndex(where: { $0.id == page.id }) else { return }
        pages[index] = page
        savePages()
        refreshRows()
    }
    private func update(_ group: QuickGroup) {
        guard let index = groups.firstIndex(where: { $0.id == group.id }) else { return }
        groups[index] = group
        saveGroups()
        refreshRows()
    }
    @objc private func labelsChanged(_ popup: NSPopUpButton) {
        let label = ButtonLabel.allCases[popup.indexOfSelectedItem]
        if popup === buttons { App.shared.quickButtonLabel = label } else { App.shared.groupMenuLabel = label }
    }
    @objc private func addPage() {
        pages.append(pageFromFrontTab(quick: true))
        savePages()
        pageTable.reloadData()
        refreshRows()
        select(page: pages.count - 1)
        pageForm.focusName()
    }
    @objc private func removePage() {
        guard pages.indices.contains(pageTable.selectedRow) else { return NSSound.beep() }
        let row = pageTable.selectedRow
        pages.remove(at: row)
        savePages()
        pageTable.reloadData()
        refreshRows()
        select(page: pages.isEmpty ? nil : min(row, pages.count - 1))
    }
    @objc private func addGroup() {
        groups.append(QuickGroup(name: "Group \(groups.count + 1)"))
        saveGroups()
        groupTable.reloadData()
        select(group: groups.count - 1)
        groupForm.focusName()
    }
    @objc private func removeGroup() {
        guard let group = groups[safe: groupTable.selectedRow] else { return NSSound.beep() }
        groups.remove(at: groupTable.selectedRow)
        // its quick tabs stay, as separate buttons
        pages = pages.map { var page = $0; if page.groupId == group.id { page.groupId = nil }; return page }
        savePages()
        saveGroups()
        groupTable.reloadData()
        pageTable.reloadData()
        select(page: nil)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { tableView === groupTable ? groups.count : pages.count }
    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        if tableView === groupTable {
            let group = groups[row]
            let image = group.iconImage ?? NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
            return Form.cell(image, group.name, detail: String(pages.filter { $0.groupId == group.id }.count))
        }
        let page = pages[row]
        return Form.cell(page.iconImage, page.name, detail: groups.first { $0.id == page.groupId }?.name)
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !syncing, let table = notification.object as? NSTableView else { return }
        if table.selectedRow >= 0 {
            syncing = true
            (table === groupTable ? pageTable : groupTable).deselectAll(nil)
            syncing = false
        }
        showForm()
    }
    // drag quick tabs to reorder them, or onto a group to put them in it
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard tableView === pageTable else { return nil }
        let item = NSPasteboardItem()
        item.setString(pages[row].id, forType: pageRowType)
        return item
    }
    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
        guard info.draggingPasteboard.string(forType: pageRowType) != nil else { return [] }
        if tableView === groupTable { return operation == .on && groups.indices.contains(row) ? .move : [] }
        if operation == .on { tableView.setDropRow(row, dropOperation: .above) }
        return .move
    }
    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        guard let id = info.draggingPasteboard.string(forType: pageRowType),
              let from = pages.firstIndex(where: { $0.id == id }) else { return false }
        if tableView === groupTable {
            guard let group = groups[safe: row] else { return false }
            pages[from].groupId = group.id
        } else {
            let page = pages.remove(at: from)
            pages.insert(page, at: from < row ? row - 1 : row)
        }
        savePages()
        pageTable.reloadData()
        refreshRows()
        select(page: pages.firstIndex { $0.id == id })
        return true
    }
}

// Settings → Loading
@MainActor
final class LoadingPane: NSObject, NSTextFieldDelegate {
    lazy var view: NSView = build()
    let idle = NSTextField()
    let sleep = NSTextField()
    let login = NSTextField()

    private func build() -> NSView {
        for field in [idle, sleep] {
            field.alignment = .right
            field.delegate = self
            field.widthAnchor.constraint(equalToConstant: 50).isActive = true
        }
        idle.toolTip = "Minutes (1–1440)"
        sleep.toolTip = "Hours (1–48)"
        login.placeholderString = "automatic"
        login.delegate = self
        login.widthAnchor.constraint(equalToConstant: 360).isActive = true
        let memory = NSButton(title: "Show Tab Memory", target: App.shared, action: #selector(App.showTabMemory(_:)))
        let grid = Form.grid([
            [Form.label("Unload idle tabs after:"), Form.row([idle, Form.label("minutes in the background")])],
            [NSGridCell.emptyContentView, Form.hint("Quick tabs whose Load is \u{201C}Unload idle\u{201D}")],
            [Form.label("Reload after sleeping:"), Form.row([sleep, Form.label("hours or more")])],
            [NSGridCell.emptyContentView, Form.hint("Pinned tabs and quick tabs on Always, so their session isn\u{2019}t expired")],
            [Form.label("Login page:"), login],
            [NSGridCell.emptyContentView, Form.hint("After you sign in there, pinned tabs and quick tabs on Always reload",
                                                    more: "Empty: recognised by the address – login, sign-in, authentication, sso… "
                                                      + "or a sign-in host like accounts.google.com")],
            [Form.label("Memory:"), memory],
            [NSGridCell.emptyContentView, Form.hint("Every tab's memory; unload or reload tabs (also in the View menu)")],
        ])
        return Form.page([grid])
    }
    func refresh() {
        _ = view
        idle.stringValue = Form.number(App.shared.unloadAfterMinutes)
        sleep.stringValue = Form.number(App.shared.reloadAfterSleepHours)
        login.stringValue = UserDefaults.standard.string(forKey: Setting.loginPage) ?? ""
    }
    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        switch field {
        case idle:
            if let minutes = Double(text) { App.shared.unloadAfterMinutes = min(1440, max(1, minutes.rounded())) } else { NSSound.beep() }
        case sleep:
            if let hours = Double(text) { App.shared.reloadAfterSleepHours = min(48, max(1, (hours * 2).rounded() / 2)) } else { NSSound.beep() }
        case login:
            if text.isEmpty {
                UserDefaults.standard.removeObject(forKey: Setting.loginPage)
            } else if let url = webURL(from: text) {
                UserDefaults.standard.set(url.absoluteString, forKey: Setting.loginPage)
            } else {
                NSSound.beep()
            }
        default: break
        }
        refresh()
    }
}

@MainActor
final class SettingsWindow: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    static let shared = SettingsWindow()
    let general = GeneralPane()
    let pinned = PinnedPane()
    let quick = QuickPane()
    let loading = LoadingPane()
    private let content = NSView()
    private static let panes: [(id: String, title: String, symbol: String)] = [
        ("general", "General", "gearshape"), ("pinned", "Pinned Tabs", "pin"),
        ("quick", "Quick Tabs", "bolt"), ("loading", "Loading", "memorychip"),
    ]
    private(set) var pane = UserDefaults.standard.string(forKey: "settingsPane") ?? "general"

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 560),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 780, height: 460)
        window.toolbarStyle = .preference
        super.init(window: window)
        window.delegate = self
        let toolbar = NSToolbar(identifier: "settings")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        window.toolbar = toolbar
        window.contentView = content
        window.center()
        window.setFrameAutosaveName("settingsWindow")   // one size for every pane, remembered
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let isEscape = event.keyCode == 53, windowNumber = event.windowNumber
            let handled = isEscape && MainActor.assumeIsolated {
                guard let window = self?.window, window.windowNumber == windowNumber else { return false }
                window.performClose(nil)   // Esc
                return true
            }
            return handled ? nil : event
        }
        if !Self.panes.contains(where: { $0.id == pane }) { pane = "general" }
        showPane(pane)
    }
    required init?(coder: NSCoder) { fatalError() }

    func show() {
        general.refresh()
        pinned.reload()
        quick.reload()
        loading.refresh()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
    func showPane(_ id: String) {
        guard let entry = Self.panes.first(where: { $0.id == id }) else { return }
        window?.makeFirstResponder(nil)   // finish an edit in the pane being left
        pane = id
        UserDefaults.standard.set(id, forKey: "settingsPane")
        let view: NSView = switch id {
        case "pinned": pinned.view
        case "quick": quick.view
        case "loading": loading.view
        default: general.view
        }
        content.subviews.forEach { $0.removeFromSuperview() }
        view.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: content.topAnchor), view.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: content.leadingAnchor), view.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])
        window?.toolbar?.selectedItemIdentifier = .init(id)
        window?.title = entry.title
    }
    // rows without their own colour show the default one
    func defaultColorChanged() {
        pinned.reload()
        quick.reload()
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.makeFirstResponder(nil)   // finish an edit that's still in progress
        ColorPicker.shared.stop()
        return true
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { Self.panes.map { .init($0.id) } }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { Self.panes.map { .init($0.id) } }
    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { Self.panes.map { .init($0.id) } }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let entry = Self.panes.first(where: { $0.id == id.rawValue }) else { return nil }
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = entry.title
        item.image = NSImage(systemSymbolName: entry.symbol, accessibilityDescription: entry.title)
        item.target = self
        item.action = #selector(toolbarPicked(_:))
        return item
    }
    @objc private func toolbarPicked(_ item: NSToolbarItem) { showPane(item.itemIdentifier.rawValue) }

    // Layout helpers for the list panes
    // a list with its + / − below, at a fixed width
    static func column(_ list: NSView, below: NSView, width: CGFloat) -> NSView {
        let column = NSStackView(views: [list, below])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 6
        column.distribution = .fill
        list.widthAnchor.constraint(equalToConstant: width).isActive = true
        list.setContentHuggingPriority(.init(1), for: .vertical)
        return column
    }
    // the top rows, then list column(s) on the left and the form filling the rest, down to the bottom
    static func columns(top: [NSView], _ columns: [NSView], form: NSView) -> NSView {
        let header = NSStackView(views: top)
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 8
        let body = NSStackView(views: columns + [form])
        body.alignment = .top
        body.spacing = 16
        body.distribution = .fill
        for column in columns { column.heightAnchor.constraint(equalTo: body.heightAnchor).isActive = true }
        form.setContentHuggingPriority(.init(1), for: .horizontal)
        form.heightAnchor.constraint(equalTo: body.heightAnchor).isActive = true
        let root = NSView()
        for view in [header, body] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            header.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -24),
            body.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 16),
            body.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            body.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            body.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
        ])
        for view in top {
            view.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor, constant: -48).isActive = true
        }
        return root
    }
    static func listAndForm(top: [NSView], list: NSView, below: NSView, form: NSView) -> NSView {
        columns(top: top, [column(list, below: below, width: 220)], form: form)
    }
}

// Without an Edit menu, ⌘C/⌘V don't work in a web view.
@MainActor
func buildMenu() -> NSMenu {
    let main = NSMenu()
    @discardableResult func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
        let menu = NSMenu(title: title)
        items.forEach(menu.addItem)
        let holder = NSMenuItem()
        holder.submenu = menu
        main.addItem(holder)
        return menu
    }
    func item(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        NSMenuItem(title: title, action: action, keyEquivalent: key)
    }
    let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "WebAppTabs"
    let restore = item("Restore Tabs on Launch", #selector(App.toggleRestoreTabs(_:)), "")
    let mute = item("Mute Site", #selector(App.toggleMute(_:)), "")
    restore.target = App.shared
    restore.state = App.shared.restoreTabs ? .on : .off
    mute.target = App.shared
    mute.state = App.shared.isMuted ? .on : .off
    let settings = item("Settings…", #selector(App.showSettings(_:)), ",")
    settings.target = App.shared
    submenu(name, [settings, .separator(), restore, mute, .separator(),
                   item("Hide \(name)", #selector(NSApplication.hide(_:)), "h"),
                   item("Quit \(name)", #selector(NSApplication.terminate(_:)), "q")])
    let closeTab = item("Close Tab", #selector(App.closeTab(_:)), "w")   // on a pinned tab: back to its page
    closeTab.target = App.shared
    let reopen = item("Reopen Closed Tab", #selector(App.reopenClosedTab(_:)), "T")
    reopen.target = App.shared
    let recentlyClosed = NSMenuItem(title: "Recently Closed", action: nil, keyEquivalent: "")
    recentlyClosed.submenu = NSMenu(title: "Recently Closed")
    recentlyClosed.submenu?.delegate = App.shared
    submenu("File", [item("New Tab", #selector(NSResponder.newWindowForTab(_:)), "t"),
                     closeTab, .separator(),
                     reopen, recentlyClosed])
    submenu("Edit", [item("Undo", Selector(("undo:")), "z"), item("Redo", Selector(("redo:")), "Z"), .separator(),
                     item("Cut", #selector(NSText.cut(_:)), "x"), item("Copy", #selector(NSText.copy(_:)), "c"),
                     item("Paste", #selector(NSText.paste(_:)), "v"),
                     item("Select All", #selector(NSText.selectAll(_:)), "a")])
    let goHome = item("Home Page", #selector(App.goHome(_:)), "H")
    goHome.target = App.shared
    let reloadAll = item("Reload All Tabs", #selector(App.reloadAllTabs(_:)), "R")
    let unloadTab = NSMenuItem(title: "Unload Tab", action: nil, keyEquivalent: "")
    unloadTab.submenu = NSMenu(title: "Unload Tab")
    unloadTab.submenu?.delegate = App.shared
    unloadTab.submenu?.autoenablesItems = false   // fillUnloadMenu sets each item's enabled state
    let unloadBackground = item("Unload Background Tabs", #selector(App.unloadBackgroundTabs(_:)), "")
    // the menu stays open after it (then it's disabled: nothing left to unload)
    // its section has images (Enter Full Screen), so its title sits in line with theirs
    unloadBackground.view = StayOpenMenuItemView(title: unloadBackground.title, image: nil, imageColumn: true) { [weak unloadBackground] in
        App.shared.unloadBackgroundTabs(nil)
        App.shared.refreshUnloadMenu()
        unloadBackground?.menu?.update()
    }
    let memory = item("Tab Memory", #selector(App.showTabMemory(_:)), "")
    [reloadAll, unloadBackground, memory].forEach { $0.target = App.shared }
    submenu("View", [goHome, item("Reload", #selector(WKWebView.reload(_:)), "r"), reloadAll,
                     item("Back", #selector(WKWebView.goBack(_:)), "["),
                     item("Forward", #selector(WKWebView.goForward(_:)), "]"), .separator(),
                     unloadTab, unloadBackground, memory])
    // AppKit adds "Show Next Tab", "Merge All Windows", etc. here automatically
    NSApp.windowsMenu = submenu("Window", [item("Minimize", #selector(NSWindow.miniaturize(_:)), "m")])
    return main
}

UserDefaults.standard.register(defaults: [Setting.restoreTabs: true])
MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    app.delegate = App.shared
    App.hookTabBarLayout()
    app.run()
}
