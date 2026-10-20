// WebAppTabs — a tiny single-site browser: one app per web app, every page is a native macOS tab.
import Cocoa
import WebKit
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
    static let outlineColor = "pinnedOutlineColor"
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

// A page that always opens first, as a pinned tab (Settings → Pinned tabs)
struct PinnedPage: Codable, Equatable {
    var id = UUID().uuidString
    var name: String
    var url: String
    // Shown in the compact tab: an SF Symbol name ("checklist"), or 1–2 letters / an emoji.
    // Default: the first letter of the name.
    var icon: String?

    var shownIcon: String {
        let text = (icon ?? "").trimmingCharacters(in: .whitespaces)
        if Self.isSymbol(text) { return text }
        return text.isEmpty ? String(name.prefix(1)).uppercased() : String(text.prefix(2))
    }

    static func isSymbol(_ text: String) -> Bool {
        text.count > 2 && NSImage(systemSymbolName: text, accessibilityDescription: nil) != nil
    }

    // Every icon is drawn into the same 16×16 square, centred on its visible shape (symbols and
    // glyphs come with uneven padding that would otherwise sit them high or low in the tab).
    // Symbols are template images, so the tab bar tints them; text uses the current text colour.
    var iconImage: NSImage {
        let canvas = NSSize(width: 16, height: 16)
        if Self.isSymbol(shownIcon),
           let symbol = NSImage(systemSymbolName: shownIcon, accessibilityDescription: name)?
               .withSymbolConfiguration(.init(pointSize: 12, weight: .medium)) {
            let image = NSImage(size: canvas, flipped: false) { rect in
                let size = symbol.size
                symbol.draw(in: NSRect(x: (rect.width - size.width) / 2, y: (rect.height - size.height) / 2,
                                       width: size.width, height: size.height))
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

// Same domain, any subdomain: accounts.google.com for mail.google.com, x.netivo.pl for projekty.netivo.pl
func isSameDomain(_ url: URL) -> Bool {
    let domain = { (u: URL) in u.host?.lowercased().split(separator: ".").suffix(2).joined(separator: ".") }
    return domain(url) != nil && domain(url) == domain(homeURL)
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
    let webView: WebView
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
        let style = pinned == nil ? nil : App.shared.pinnedStyle
        let iconAndName = style == .iconAndName || style == .iconAndNameCompact
        item.setValue(style == .icon || iconAndName ? pinned?.iconImage : nil, forKey: "image")
        item.setValue(iconAndName, forKey: "showIcon")
        item.setValue(style == .icon, forKey: "pinned")
    }
    private let titleLabel = NSTextField(labelWithString: "")
    private lazy var pinnedSwitcher: NSSegmentedControl = {
        let control = NSSegmentedControl()
        control.trackingMode = .selectOne
        control.segmentDistribution = .fit
        control.target = self
        control.action = #selector(pinnedSwitcherClicked(_:))
        return control
    }()

    init(load url: URL?, configuration: WKWebViewConfiguration) {
        webView = WebView(frame: .zero, configuration: configuration)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.tabbingMode = .preferred            // ← this line is the whole tab bar
        window.tabbingIdentifier = "webapp"
        window.contentView = webView
        window.initialFirstResponder = webView
        window.center()
        super.init(window: window)
        window.delegate = self
        // Safari web app look: ‹ › on the left, page title centered
        window.titleVisibility = .hidden            // the tab bar still shows window.title
        window.toolbarStyle = .unified
        let toolbar = NSToolbar(identifier: "main")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.centeredItemIdentifiers = [.pageTitle]
        window.toolbar = toolbar
        if let frame = App.shared.savedFrame() { window.setFrame(frame, display: false) }
        titleLabel.font = .titleBarFont(ofSize: 0)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 600).isActive = true
        webView.customUserAgent = safariUA
        webView.allowsBackForwardNavigationGestures = true
        webView.isInspectable = true               // Safari → Develop → <Mac name> → Netivo Tabs
        webView.navigationDelegate = self
        webView.uiDelegate = self
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
        applyMute()
        if let url { webView.load(URLRequest(url: url)) }
    }
    required init?(coder: NSCoder) { fatalError() }

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
    override func newWindowForTab(_ sender: Any?) { App.shared.openTab(url: homeURL, next: self) }

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
        closingInfo = (webView.title, left)
        // Like Safari: closing a tab you came to straight from the tab that opened it goes back there.
        // Otherwise AppKit selects the tab to the right (or left, for the last tab), as Safari does.
        if let back = returnOnClose?.window, App.shared.tabs.contains(where: { $0 === returnOnClose }),
           sender.tabGroup?.selectedWindow === sender, group.contains(back) {
            sender.tabGroup?.selectedWindow = back
            back.makeKeyAndOrderFront(nil)
        }
        return true
    }

    // The tab this one was opened from (link, ⌘-click, middle-click, window.open)
    weak var opener: Tab?
    private weak var returnOnClose: Tab?

    // The user switched to this tab (from `previous`)
    func didGetSelected(after previous: Tab?) {
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
}

extension Tab: NSToolbarDelegate, NSSharingServicePickerToolbarItemDelegate {
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.back, .forward] + (App.shared.pinnedStyle == .separateRow ? [.pinnedSwitcher] : [])
            + [.flexibleSpace, .pageTitle, .flexibleSpace, .share]
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.back, .forward, .pinnedSwitcher, .flexibleSpace, .pageTitle, .share]
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
        default:
            return nil
        }
        return item
    }

    func items(for pickerToolbarItem: NSSharingServicePickerToolbarItem) -> [Any] {
        webView.url.map { [$0] } ?? []
    }

    // "Separate row above the tabs": the pinned pages as one switcher in the toolbar, after ‹ ›.
    // Toolbars with the same identifier share their items, so inserting it in one window adds it to all.
    func updateToolbar() {
        guard let toolbar = window?.toolbar else { return }
        let index = toolbar.items.firstIndex { $0.itemIdentifier == .pinnedSwitcher }
        if App.shared.pinnedStyle == .separateRow, index == nil {
            toolbar.insertItem(withItemIdentifier: .pinnedSwitcher, at: 2)
        } else if App.shared.pinnedStyle != .separateRow, let index {
            toolbar.removeItem(at: index)
        }
    }
    func refreshPinnedSwitcher() {
        let pages = App.shared.pinnedPages
        pinnedSwitcher.segmentCount = pages.count
        for (index, page) in pages.enumerated() {
            pinnedSwitcher.setLabel(page.name, forSegment: index)
            pinnedSwitcher.setImage(page.iconImage, forSegment: index)
            pinnedSwitcher.setWidth(0, forSegment: index)   // fit the content
        }
        let selected = App.shared.selectedTab?.pinned?.id
        pinnedSwitcher.selectedSegment = pages.firstIndex { $0.id == selected } ?? -1
    }
    @objc private func pinnedSwitcherClicked(_ sender: NSSegmentedControl) {
        let pages = App.shared.pinnedPages
        guard pages.indices.contains(sender.selectedSegment),
              let tab = App.shared.tabs.first(where: { $0.pinned?.id == pages[sender.selectedSegment].id }) else { return }
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

    // Settings are per app (UserDefaults is keyed by bundle ID), so Gmail can be muted and Netivo not
    var restoreTabs: Bool { UserDefaults.standard.bool(forKey: Setting.restoreTabs) }
    var isMuted: Bool { UserDefaults.standard.bool(forKey: Setting.muteSite) }
    // Settings → "Pinned tabs show": 36 px icon tabs, or full-width tabs with icon + name or the name
    var pinnedStyle: PinnedStyle {
        get {
            UserDefaults.standard.string(forKey: Setting.pinnedStyle).flatMap(PinnedStyle.init)
                ?? (UserDefaults.standard.object(forKey: Setting.compactPinned) as? Bool == false ? .name : .icon)
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Setting.pinnedStyle)
            tabs.forEach { $0.applyPinnedLook(); $0.updateToolbar() }
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
                app.selectedTab = tab
                app.outlinePinnedTabs()   // the tab bar now lives in the newly selected window
                app.tabs.forEach { $0.refreshPinnedSwitcher() }
            }
        }
        // the tab bar is redrawn when tabs are added, closed or dragged into a new order
        outlineObservers[ObjectIdentifier(group)] = group.observe(\.windows) { _, _ in
            MainActor.assumeIsolated {
                App.shared.outlinePinnedTabs()
                App.shared.keepPinnedTabsInPlace()
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
        for tab in tabs {
            guard let group = tab.window?.tabGroup, done.insert(ObjectIdentifier(group)).inserted,
                  let frameView = (group.selectedWindow ?? tab.window)?.contentView?.superview else { continue }
            guard let buttons = Self.tabButtons(in: frameView, for: group.windows) else { continue }
            for (button, window) in zip(buttons, group.windows) {
                let pinned = tabs.contains { $0.window === window && $0.pinned != nil }
                button.wantsLayer = true
                button.layer?.borderColor = outlineColor.cgColor
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
        refuseDraggingPinnedTabs()
        hideCloseButtonOfPinnedTabs()
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
        let pinnedCount = windows.prefix { w in tabs.contains { $0.window === w && $0.pinned != nil } }.count
        for button in buttons where button.isHidden { button.isHidden = false }
        guard pinnedStyle == .iconAndNameCompact || separateRow, pinnedCount > 0 else { return }
        // the tab's content row is 5 | close-button slot 16 | icon 16 + 6 + name (+4) | right slot 16 | 5
        let fits = buttons.prefix(pinnedCount).map { button -> CGFloat in
            if separateRow { return 0 }   // shown in the toolbar instead
            let spacing = Self.firstStack(in: button)?.spacing ?? 8
            let name = Self.firstLabel(in: button)?.intrinsicContentSize.width ?? 60
            return ceil(2 * (5 + 16 + spacing) + 16 + 6 + name + 4)
        }
        let gap: CGFloat = 1
        let start: CGFloat = 0, end = row.bounds.width
        let others = buttons.count - pinnedCount
        let gaps = gap * CGFloat(buttons.count - 1 - (separateRow ? pinnedCount : 0))
        let rest = others == 0 ? 0 : (end - start - fits.reduce(0, +) - gaps) / CGFloat(others)
        // crowded: native layout (with the separate row, never show the pinned tabs in the bar again)
        guard others == 0 || rest >= (separateRow ? 1 : 100) else { return }
        let barWidth = row.bounds.width, count = row.subviews.count
        var x = start
        for (index, button) in buttons.enumerated() {
            let width = (index < pinnedCount ? fits[index] : rest).rounded(.down)
            Self.keptFrames[ObjectIdentifier(button)] = (x.rounded(), width, barWidth, count)
            if separators.count == buttons.count {
                let line = width == 0 ? 0 : separators[index].frame.width   // no line after a hidden tab
                Self.keptFrames[ObjectIdentifier(separators[index])] = (x.rounded() + width, line, barWidth, count)
                separators[index].frame = separators[index].frame   // the setter applies the kept frame
            }
            x += (index < pinnedCount ? fits[index] : rest) + (width == 0 ? 0 : gap)
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
        let tab = Tab(load: url, configuration: configuration ?? makeConfiguration())
        tab.opener = opener
        tab.pinned = pinned
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
        NSApp.mainMenu = buildMenu()
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let (key, mods, chars) = (event.keyCode, event.modifierFlags, event.charactersIgnoringModifiers)
            return MainActor.assumeIsolated { App.shared.handleTabShortcut(key, mods, chars) } ? nil : event
        }
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            NSLog("notifications granted=\(granted) error=\(String(describing: error))")
        }
        installUserScripts()
        openStartTabs()
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
        saveSession()
        isQuitting = true
        isRestoringOrQuitting = true   // windows closing during quit must not wipe the saved tabs
    }

    // View → Home Page (⌘⇧H): load the home page in the current tab
    @objc func goHome(_ sender: Any?) {
        let tab = tabs.first { $0.window === NSApp.keyWindow } ?? tabs.last
        if let tab { tab.webView.load(URLRequest(url: homeURL)) } else { openTab(url: homeURL) }
    }

    @objc func showSettings(_ sender: Any?) { SettingsWindow.shared.show() }

    @objc func toggleRestoreTabs(_ item: NSMenuItem) {
        UserDefaults.standard.set(!restoreTabs, forKey: Setting.restoreTabs)
        item.state = restoreTabs ? .on : .off
    }
    @objc func toggleMute(_ item: NSMenuItem) {
        UserDefaults.standard.set(!isMuted, forKey: Setting.muteSite)
        item.state = isMuted ? .on : .off
        installUserScripts()
        tabs.forEach { $0.applyMute() }
    }

    // MARK: Pinned tabs
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
        }
    }

    var pinnedPages: [PinnedPage] {
        get {
            UserDefaults.standard.data(forKey: Setting.pinnedPages)
                .flatMap { try? JSONDecoder().decode([PinnedPage].self, from: $0) } ?? []
        }
        set {
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: Setting.pinnedPages)
            applyPinnedPages()
        }
    }

    // Make the open tabs match the list: pin, unpin, rename, open new ones, keep them first and in order
    func applyPinnedPages() {
        let pages = pinnedPages
        let keyWindow = NSApp.keyWindow, selected = selectedTab?.window   // put back afterwards
        for tab in tabs where tab.pinned != nil && !pages.contains(where: { $0.id == tab.pinned?.id }) {
            tab.pinned = nil
        }
        var ordered: [Tab] = []
        for page in pages {
            if let tab = tabs.first(where: { $0.pinned?.id == page.id }) {
                let addressChanged = tab.pinned?.url != page.url
                tab.pinned = page
                if addressChanged, let url = URL(string: page.url) { tab.webView.load(URLRequest(url: url)) }
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
        tabs.forEach { $0.refreshPinnedSwitcher() }
        saveSession()
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
            let pinnedTabs = pinnedPages.compactMap { page in tabs.first { $0.pinned?.id == page.id } }
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
            let pages = group.filter { $0.pinned == nil }.compactMap { t in t.webView.url.map { (tab: t, url: $0.absoluteString) } }
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
        for page in pinnedPages {
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
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { openTab(url: homeURL) }
        return true
    }

    // ⌃Tab / ⌃⇧Tab / ⌘1…⌘9, handled before the web view can swallow them
    func handleTabShortcut(_ keyCode: UInt16, _ flags: NSEvent.ModifierFlags, _ chars: String?) -> Bool {
        guard let window = NSApp.keyWindow, window.attachedSheet == nil else { return false }
        let mods = flags.intersection(.deviceIndependentFlagsMask)
        if keyCode == 48, mods.contains(.control) {
            mods.contains(.shift) ? window.selectPreviousTab(nil) : window.selectNextTab(nil)
            return true
        }
        if mods == .command, let n = Int(chars ?? ""), (1...9).contains(n),
           let group = window.tabbedWindows {
            let target = n == 9 ? group.last : (n <= group.count ? group[n - 1] : nil)
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
        guard !isQuitting, let url = tab.webView.url else { return }
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
        case #selector(closeTab(_:)): NSApp.keyWindow.map { key in !tabs.contains { $0.window === key && $0.pinned != nil } } ?? false
        default: true
        }
    }
    @objc func closeTab(_ sender: Any?) { NSApp.keyWindow?.performClose(sender) }
    // File → Recently Closed lists every tab closed this session, newest first
    func menuNeedsUpdate(_ menu: NSMenu) {
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

extension App: WKScriptMessageHandler, UNUserNotificationCenterDelegate {
    // The page created a Notification → post it to macOS
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let tab = tabs.first(where: { $0.webView === message.webView }) else { return }
        let center = UNUserNotificationCenter.current()
        if let closed = body["close"] as? String {
            center.removeDeliveredNotifications(withIdentifiers: [tab.id + closed])
            return
        }
        let jsID = body["id"] as? String ?? ""
        let tag = body["tag"] as? String ?? ""
        let content = UNMutableNotificationContent()
        content.title = body["title"] as? String ?? ""
        content.body = body["body"] as? String ?? ""
        content.sound = .default
        content.userInfo = ["tab": tab.id, "id": jsID]
        center.add(UNNotificationRequest(identifier: tab.id + (tag.isEmpty ? jsID : tag), content: content, trigger: nil)) {
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

// "projekty.netivo.pl/admin" → https://projekty.netivo.pl/admin; nil if it isn't a web address
func webURL(from text: String) -> URL? {
    var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return nil }
    if !text.contains("://") { text = "https://" + text }
    guard let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil
    else { return nil }
    return url
}

// MARK: Settings window (⌘,): home page and pinned tabs, saved per app
final class SettingsWindow: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate,
                            NSTextFieldDelegate {
    static let shared = SettingsWindow()
    private let homeField = NSTextField()
    private let table = NSTableView()
    private let rowType = NSPasteboard.PasteboardType("local.webapptabs.pinned-row")
    private var pages: [PinnedPage] = []
    private let colorWell = NSColorWell(style: .default)
    private let hexField = NSTextField()
    private let stylePopup = NSPopUpButton()

    init() {
        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "WebAppTabs"
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 480),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "\(name) Settings"
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 480, height: 400)
        super.init(window: window)
        window.delegate = self

        homeField.placeholderString = defaultHomeURL.absoluteString
        homeField.delegate = self

        for (id, title, width) in [("icon", "Icon", 80.0), ("name", "Name", 120.0), ("url", "Address", 350.0)] {
            let column = NSTableColumn(identifier: .init(id))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 24
        table.usesAlternatingRowBackgroundColors = true
        table.registerForDraggedTypes([rowType])
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        let add = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "Add")!,
                           target: self, action: #selector(addPage))
        let remove = NSButton(image: NSImage(systemSymbolName: "minus", accessibilityDescription: "Remove")!,
                              target: self, action: #selector(removePage))
        add.toolTip = "Add the current page"
        remove.toolTip = "Remove the selected page"
        let buttons = NSStackView(views: [add, remove, Self.hint("Drag rows to reorder. Changes apply right away.")])
        // Outline colour of pinned tabs: the well opens the colour picker (with an opacity slider)
        colorWell.target = self
        colorWell.action = #selector(outlineColorChanged)
        NSColorPanel.shared.showsAlpha = true
        let reset = NSButton(title: "Default", target: self, action: #selector(resetOutlineColor))
        reset.controlSize = .small
        hexField.placeholderString = "#RRGGBBAA"
        hexField.toolTip = "#RRGGBB or #RRGGBBAA – the last two digits are the opacity (00 = no outline)"
        hexField.delegate = self
        hexField.widthAnchor.constraint(equalToConstant: 92).isActive = true
        let outlineRow = NSStackView(views: [NSTextField(labelWithString: "Outline colour:"), colorWell, hexField, reset,
                                             Self.hint("AA = opacity, 00 = none")])
        outlineRow.spacing = 8
        stylePopup.addItems(withTitles: PinnedStyle.allCases.map(\.title))
        stylePopup.target = self
        stylePopup.action = #selector(styleChanged)
        let styleRow = NSStackView(views: [NSTextField(labelWithString: "Pinned tabs show:"), stylePopup])
        styleRow.spacing = 8
        buttons.spacing = 6

        let stack = NSStackView(views: [
            Self.heading("Home page"), homeField,
            Self.hint("Opened by New Tab (⌘T) and View → Home Page (⌘⇧H). Leave empty for \(defaultHomeURL.absoluteString)"),
            Self.heading("Pinned tabs"),
            Self.hint("Open first, in this order, every time the app starts, with a coloured outline. "
                      + "Icon: 1–2 letters, an emoji, or an SF Symbol name like checklist (icon-only tabs show the name on hover). "
                      + "They can't be closed (⌘W does nothing on them) or dragged; ⌘1, ⌘2… count them first."),
            scroll, buttons, styleRow, outlineRow,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.setCustomSpacing(18, after: stack.views[2])
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        window.contentView = stack
        for view in [homeField, scroll] + stack.views.filter({ $0 is NSTextField && $0 !== homeField }) {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        }
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 170).isActive = true
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        window.center()
    }
    required init?(coder: NSCoder) { fatalError() }

    private static func heading(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        return label
    }
    private static func hint(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        return label
    }

    @objc private func styleChanged() { App.shared.pinnedStyle = PinnedStyle.allCases[stylePopup.indexOfSelectedItem] }

    func show() {
        pages = App.shared.pinnedPages
        stylePopup.selectItem(at: PinnedStyle.allCases.firstIndex(of: App.shared.pinnedStyle) ?? 0)
        colorWell.color = App.shared.outlineColor
        hexField.stringValue = App.shared.outlineColor.hexString
        homeField.stringValue = UserDefaults.standard.string(forKey: Setting.homeURL) ?? ""
        table.reloadData()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    // Finish an edit that's still in progress when the window closes
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.makeFirstResponder(nil)
        return true
    }

    private func save() { App.shared.pinnedPages = pages }

    @objc private func addPage() {
        let tab = App.shared.frontTab   // start from the page you're on
        let title = tab?.webView.title.map { String($0.prefix(20)) } ?? ""
        pages.append(PinnedPage(name: title.isEmpty ? "New" : title,
                                url: tab?.webView.url?.absoluteString ?? homeURL.absoluteString))
        table.reloadData()
        save()
        let row = pages.count - 1
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.editColumn(1, row: row, with: nil, select: true)
    }

    @objc private func outlineColorChanged() {
        App.shared.outlineColor = colorWell.color
        hexField.stringValue = App.shared.outlineColor.hexString
    }
    @objc private func resetOutlineColor() {
        UserDefaults.standard.removeObject(forKey: Setting.outlineColor)
        colorWell.color = App.shared.outlineColor
        hexField.stringValue = App.shared.outlineColor.hexString
        App.shared.outlinePinnedTabs()
    }

    @objc private func removePage() {
        guard pages.indices.contains(table.selectedRow) else { return NSSound.beep() }
        pages.remove(at: table.selectedRow)
        table.reloadData()
        save()
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        if field === homeField { return saveHome() }
        if field === hexField {
            guard let color = NSColor(hex: field.stringValue) else {
                NSSound.beep()
                field.stringValue = App.shared.outlineColor.hexString
                return
            }
            App.shared.outlineColor = color
            colorWell.color = App.shared.outlineColor
            field.stringValue = App.shared.outlineColor.hexString
            return
        }
        let row = table.row(for: field)
        guard pages.indices.contains(row) else { return }
        if field.identifier?.rawValue == "icon" {
            let icon = field.stringValue.trimmingCharacters(in: .whitespaces)
            pages[row].icon = icon.isEmpty ? nil : PinnedPage.isSymbol(icon) ? icon : String(icon.prefix(2))
        } else if field.identifier?.rawValue == "name" {
            let name = field.stringValue.trimmingCharacters(in: .whitespaces)
            pages[row].name = name.isEmpty ? pages[row].name : name
        } else if let url = webURL(from: field.stringValue) {
            pages[row].url = url.absoluteString
        } else {
            NSSound.beep()
        }
        table.reloadData(forRowIndexes: [row], columnIndexes: [0, 1, 2])
        save()
    }

    private func saveHome() {
        let text = homeField.stringValue.trimmingCharacters(in: .whitespaces)
        if text.isEmpty { return UserDefaults.standard.removeObject(forKey: Setting.homeURL) }
        guard let url = webURL(from: text) else { return NSSound.beep() }
        UserDefaults.standard.set(url.absoluteString, forKey: Setting.homeURL)
        homeField.stringValue = url.absoluteString
    }

    // Table: Name | Address, editable, drag to reorder
    func numberOfRows(in tableView: NSTableView) -> Int { pages.count }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        let id = column?.identifier.rawValue ?? "name"
        let page = pages[row]
        let field = NSTextField(string: id == "icon" ? page.shownIcon : id == "name" ? page.name : page.url)
        if id == "icon" { field.alignment = .center }
        field.identifier = .init(id)
        field.isBordered = false
        field.drawsBackground = false
        field.lineBreakMode = .byTruncatingTail
        field.delegate = self
        return field
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let item = NSPasteboardItem()
        item.setString(String(row), forType: rowType)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
        if operation == .on { tableView.setDropRow(row, dropOperation: .above) }
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        guard let from = info.draggingPasteboard.string(forType: rowType).flatMap(Int.init),
              pages.indices.contains(from) else { return false }
        let page = pages.remove(at: from)
        pages.insert(page, at: from < row ? row - 1 : row)
        tableView.reloadData()
        save()
        return true
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
    let closeTab = item("Close Tab", #selector(App.closeTab(_:)), "w")   // greyed out on a pinned tab
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
    submenu("View", [goHome, item("Reload", #selector(WKWebView.reload(_:)), "r"),
                     item("Back", #selector(WKWebView.goBack(_:)), "["),
                     item("Forward", #selector(WKWebView.goForward(_:)), "]")])
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
