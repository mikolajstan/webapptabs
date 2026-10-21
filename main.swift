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
    static let quickPages = "quickPages"
    static let quickGroups = "quickGroups"        // [QuickGroup] as JSON
    static let pinnedButtons = "pinnedButtonLabel"   // ButtonLabel of the separate row's buttons
    static let quickButtons = "quickButtonLabel"     // ButtonLabel of the quick tab buttons
    static let legacyGroupColors = "quickGroupColors"   // 1.3 drafts: group name → "#RRGGBBAA" (migrated)
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

// A group of quick tabs: one toolbar button ("Name ▾") that opens a menu of its pages
struct QuickGroup: Codable, Equatable {
    var id = UUID().uuidString
    var name: String
    var color: String?   // "#RRGGBBAA"; nil = the default colour
    var tint: NSColor? { color.flatMap(NSColor.init(hex:)) }
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
        closingInfo = (webView.title, left)
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
        pinnedSwitcher.update(pages: pinned, selected: pinned.firstIndex { $0.id == selected }, color: color,
                              show: App.shared.pinnedButtonLabel)
        quickSwitcher.update(pages: quick, selected: quick.firstIndex { $0.id == selected }, color: color,
                             groups: App.shared.quickGroups, show: App.shared.quickButtonLabel)
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
        for tab in tabs {
            guard let group = tab.window?.tabGroup, done.insert(ObjectIdentifier(group)).inserted,
                  let frameView = (group.selectedWindow ?? tab.window)?.contentView?.superview else { continue }
            guard let buttons = Self.tabButtons(in: frameView, for: group.windows) else { continue }
            for (button, window) in zip(buttons, group.windows) {
                let page = tabs.first { $0.window === window }?.pinned
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
        guard pinnedStyle == .iconAndNameCompact || separateRow || hasQuick, pinnedCount > 0 else { return }
        // fixed widths: quick tabs and the separate row's pinned tabs 0 (hidden), icon-only 36, compact
        // icon + name: what the tab's content row needs (5 | close slot 16 | icon 16 + 6 + name (+4) | slot 16 | 5);
        // nil = shares what's left (normal tabs, full-width pinned tabs)
        let fixed = buttons.indices.map { index -> CGFloat? in
            guard index < pinnedCount, let page = pages[index] else { return nil }
            if page.isQuick || separateRow { return 0 }
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
        case #selector(closeTab(_:)): NSApp.keyWindow != nil
        default: true
        }
    }
    // ⌘W: closes a tab, but takes a pinned tab back to its pinned page (pinned tabs never close)
    @objc func closeTab(_ sender: Any?) {
        let window = (NSApp.keyWindow ?? selectedTab?.window).map { $0.tabGroup?.selectedWindow ?? $0 }   // the tab you're looking at
        if let tab = tabs.first(where: { $0.window === window }), let page = tab.pinned {
            if let url = URL(string: page.url) { tab.webView.load(URLRequest(url: url)) }
        } else {
            window?.performClose(sender)
        }
    }
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
        var onPress: (() -> Void)?

        init() {
            super.init(frame: .zero)
            wantsLayer = true
            layer?.cornerRadius = 13
            layer?.borderWidth = 1
            icon.contentTintColor = .labelColor
            label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
            let row = NSStackView(views: [icon, label])
            row.spacing = 5
            row.edgeInsets = NSEdgeInsets(top: 0, left: 11, bottom: 0, right: 12)
            row.translatesAutoresizingMaskIntoConstraints = false
            addSubview(row)
            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: leadingAnchor), row.trailingAnchor.constraint(equalTo: trailingAnchor),
                row.topAnchor.constraint(equalTo: topAnchor), row.bottomAnchor.constraint(equalTo: bottomAnchor),
                heightAnchor.constraint(equalToConstant: 26),
                icon.widthAnchor.constraint(equalToConstant: 16), icon.heightAnchor.constraint(equalToConstant: 16),
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
    }

    private var pages: [PinnedPage] = []
    private var selected: Int?
    private var groups: [QuickGroup] = []
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
                show: ButtonLabel = .iconAndName) {
        self.pages = pages
        self.selected = selected
        self.groups = groups
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
                pill.icon.image = shown.iconImage
                pill.label.stringValue = show == .icon ? "▾" : group.name + " ▾"
                pill.label.isHidden = false
                pill.icon.isHidden = show == .name
                let names = entry.indices.map { pages[$0].name }.joined(separator: ", ")
                pill.toolTip = show == .icon ? "\(group.name): \(names)" : names
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
                pill.toolTip = show == .icon ? "\(page.name) – \(page.url)" : page.url
                pill.setAccessibilityLabel(page.name)
                pill.onPress = { [weak self] in self?.onSelect?(index) }
            }
            pill.label.textColor = isSelected ? .labelColor : .secondaryLabelColor
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

    // the pages at `indices` (a group's dropdown), the open one ticked
    func menu(for indices: [Int]) -> NSMenu {
        let menu = NSMenu()
        for index in indices {
            let item = NSMenuItem(title: pages[index].name, action: #selector(picked(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.image = pages[index].iconImage
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
                item.image = pages[selected.flatMap { entry.indices.contains($0) ? $0 : nil } ?? entry.indices[0]].iconImage
                item.submenu = self.menu(for: entry.indices)
                menu.addItem(item)
            } else {
                self.menu(for: entry.indices).items.forEach { $0.menu?.removeItem($0); menu.addItem($0) }
            }
        }
        return menu
    }
    @objc private func picked(_ item: NSMenuItem) { onSelect?(item.tag) }
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

// A colour cell: swatch (click → colour panel) + "#RRGGBBAA" field; empty = the default colour
@MainActor
func colorCell(hex: String?, row: Int, target: AnyObject, swatchAction: Selector, delegate: NSTextFieldDelegate) -> NSView {
    let swatch = NSButton(title: "", target: target, action: swatchAction)
    swatch.isBordered = false
    swatch.tag = row
    swatch.wantsLayer = true
    swatch.layer?.cornerRadius = 4
    swatch.layer?.borderWidth = 1
    swatch.layer?.borderColor = NSColor.separatorColor.cgColor
    let color = hex.flatMap(NSColor.init(hex:))
    swatch.layer?.backgroundColor = (color ?? App.shared.outlineColor.withAlphaComponent(0.25)).cgColor
    swatch.toolTip = "Pick a colour"
    swatch.widthAnchor.constraint(equalToConstant: 22).isActive = true
    swatch.heightAnchor.constraint(equalToConstant: 14).isActive = true
    let field = NSTextField(string: color?.hexString ?? "")
    field.placeholderString = "default"
    field.identifier = .init("color")
    field.isBordered = false
    field.drawsBackground = false
    field.delegate = delegate
    field.toolTip = "#RRGGBB or #RRGGBBAA; empty = the default colour"
    let cell = NSStackView(views: [swatch, field])
    cell.spacing = 5
    cell.alignment = .top   // text on the same line as the other columns' text
    cell.edgeInsets = NSEdgeInsets(top: 1, left: 0, bottom: 0, right: 0)
    return cell
}
/// "" → nil (default), a valid colour → its hex, anything else → .invalid
enum ColorInput { case clear, color(String), invalid }
func parseColor(_ text: String) -> ColorInput {
    let text = text.trimmingCharacters(in: .whitespaces)
    if text.isEmpty { return .clear }
    return NSColor(hex: text).map { .color($0.hexString) } ?? .invalid
}

// A list of pages (Icon | Name | Address) with + / − and drag to reorder; every change is saved right away.
// Used twice in Settings: pinned tabs and quick tabs.
@MainActor
final class PagesEditor: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    let table = NSTableView()
    let scroll = NSScrollView()
    let buttons = NSStackView()
    private let rowType: NSPasteboard.PasteboardType
    private let load: () -> [PinnedPage]
    private let store: ([PinnedPage]) -> Void
    private var pages: [PinnedPage] = []

    // groups: the quick tab groups for the Group column (none: no column)
    private let groups: (() -> [QuickGroup])?
    init(id: String, groups: (() -> [QuickGroup])? = nil, load: @escaping () -> [PinnedPage],
         store: @escaping ([PinnedPage]) -> Void) {
        self.load = load
        self.store = store
        self.groups = groups
        rowType = NSPasteboard.PasteboardType("local.webapptabs.\(id)-row")
        super.init()
        let columns = groups != nil
            ? [("icon", "Icon", 64.0), ("name", "Name", 100.0), ("group", "Group", 110.0), ("color", "Colour", 110.0),
               ("url", "Address", 220.0)]
            : [("icon", "Icon", 64.0), ("name", "Name", 110.0), ("color", "Colour", 110.0), ("url", "Address", 300.0)]
        for (id, title, width) in columns {
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
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let add = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "Add")!,
                           target: self, action: #selector(addPage))
        let remove = NSButton(image: NSImage(systemSymbolName: "minus", accessibilityDescription: "Remove")!,
                              target: self, action: #selector(removePage))
        add.toolTip = "Add the current page"
        remove.toolTip = "Remove the selected page"
        let hint = NSTextField(labelWithString: "Drag rows to reorder. Changes apply right away.")
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hint.textColor = .secondaryLabelColor
        [add, remove, hint].forEach(buttons.addArrangedSubview)
        buttons.spacing = 6
    }

    var onSave: (() -> Void)?
    var isEditing: Bool { table.editedRow >= 0 }
    func reload() {
        pages = load()
        table.reloadData()
    }
    private func save() { store(pages); onSave?() }

    @objc private func pickColor(_ swatch: NSButton) {
        let row = swatch.tag
        guard pages.indices.contains(row) else { return }
        let id = pages[row].id
        ColorPicker.shared.pick(pages[row].tint ?? App.shared.outlineColor) { [weak self] color in
            guard let self, let row = self.pages.firstIndex(where: { $0.id == id }) else { return }
            self.pages[row].color = color.hexString
            self.table.reloadData(forRowIndexes: [row], columnIndexes: IndexSet(0..<self.table.numberOfColumns))
            self.save()
        }
    }

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
    @objc private func removePage() {
        guard pages.indices.contains(table.selectedRow) else { return NSSound.beep() }
        pages.remove(at: table.selectedRow)
        table.reloadData()
        save()
    }

    @objc private func groupChosen(_ popup: NSPopUpButton) {
        guard pages.indices.contains(popup.tag) else { return }
        pages[popup.tag].groupId = popup.selectedItem?.representedObject as? String
        save()
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        let row = table.row(for: field)
        guard pages.indices.contains(row) else { return }
        if field.identifier?.rawValue == "icon" {
            let icon = field.stringValue.trimmingCharacters(in: .whitespaces)
            pages[row].icon = icon.isEmpty ? nil : PinnedPage.isSymbol(icon) ? icon : String(icon.prefix(2))
        } else if field.identifier?.rawValue == "name" {
            let name = field.stringValue.trimmingCharacters(in: .whitespaces)
            pages[row].name = name.isEmpty ? pages[row].name : name
        } else if field.identifier?.rawValue == "color" {
            switch parseColor(field.stringValue) {
            case .clear: pages[row].color = nil
            case .color(let hex): pages[row].color = hex
            case .invalid: NSSound.beep()
            }
        } else if let url = webURL(from: field.stringValue) {
            pages[row].url = url.absoluteString
        } else {
            NSSound.beep()
        }
        table.reloadData(forRowIndexes: [row], columnIndexes: IndexSet(0..<table.numberOfColumns))
        save()
    }

    // Icon | Name | Address, editable, drag to reorder (within this list only)
    func numberOfRows(in tableView: NSTableView) -> Int { pages.count }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        let id = column?.identifier.rawValue ?? "name"
        let page = pages[row]
        if id == "color" {
            return colorCell(hex: page.color, row: row, target: self, swatchAction: #selector(pickColor(_:)), delegate: self)
        }
        if id == "group", let groups = groups?() {
            // "–" or one of the groups made in Settings → Quick tab groups
            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            popup.controlSize = .small
            popup.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            popup.addItem(withTitle: "–")
            for group in groups {
                popup.addItem(withTitle: group.name)
                popup.lastItem?.representedObject = group.id
            }
            popup.selectItem(at: groups.firstIndex { $0.id == page.groupId }.map { $0 + 1 } ?? 0)
            popup.tag = row
            popup.target = self
            popup.action = #selector(groupChosen(_:))
            return popup
        }
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
        guard info.draggingPasteboard.string(forType: rowType) != nil else { return [] }
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

// Settings → Quick tab groups: Name | Colour, + / −. Quick tabs pick their group in the Quick tabs list.
@MainActor
final class GroupsEditor: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    let table = NSTableView()
    let scroll = NSScrollView()
    let buttons = NSStackView()
    var onSave: (() -> Void)?   // the quick tabs' Group menus list the groups
    private var groups: [QuickGroup] = []

    override init() {
        super.init()
        for (id, title, width) in [("name", "Name", 200.0), ("color", "Colour", 140.0)] {
            let column = NSTableColumn(identifier: .init(id))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 24
        table.usesAlternatingRowBackgroundColors = true
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let add = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "Add")!,
                           target: self, action: #selector(addGroup))
        let remove = NSButton(image: NSImage(systemSymbolName: "minus", accessibilityDescription: "Remove")!,
                              target: self, action: #selector(removeGroup))
        add.toolTip = "Add a group"
        remove.toolTip = "Remove the selected group (its quick tabs become separate buttons)"
        let hint = NSTextField(labelWithString: "Then choose the group for quick tabs in the Group column below.")
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hint.textColor = .secondaryLabelColor
        [add, remove, hint].forEach(buttons.addArrangedSubview)
        buttons.spacing = 6
    }
    var isEditing: Bool { table.editedRow >= 0 }
    func reload() {
        groups = App.shared.quickGroups
        table.reloadData()
    }
    private func save() {
        App.shared.quickGroups = groups
        onSave?()
    }

    @objc private func addGroup() {
        groups.append(QuickGroup(name: "Group \(groups.count + 1)"))
        table.reloadData()
        save()
        let row = groups.count - 1
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.editColumn(0, row: row, with: nil, select: true)
    }
    @objc private func removeGroup() {
        guard groups.indices.contains(table.selectedRow) else { return NSSound.beep() }
        let removed = groups.remove(at: table.selectedRow)
        // its quick tabs go back to separate buttons
        App.shared.quickPages = App.shared.quickPages.map { var page = $0; if page.groupId == removed.id { page.groupId = nil }; return page }
        table.reloadData()
        save()
    }
    @objc private func pickColor(_ swatch: NSButton) {
        guard let group = groups[safe: swatch.tag] else { return }
        ColorPicker.shared.pick(group.tint ?? App.shared.outlineColor) { [weak self] color in
            guard let self, let row = self.groups.firstIndex(where: { $0.id == group.id }) else { return }
            self.groups[row].color = color.hexString
            self.table.reloadData(forRowIndexes: [row], columnIndexes: [0, 1])
            self.save()
        }
    }
    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        let row = table.row(for: field)
        guard groups.indices.contains(row) else { return }
        if field.identifier?.rawValue == "color" {
            switch parseColor(field.stringValue) {
            case .clear: groups[row].color = nil
            case .color(let hex): groups[row].color = hex
            case .invalid: NSSound.beep()
            }
        } else {
            let name = field.stringValue.trimmingCharacters(in: .whitespaces)
            groups[row].name = name.isEmpty ? groups[row].name : name
        }
        table.reloadData(forRowIndexes: [row], columnIndexes: [0, 1])
        save()
    }
    func numberOfRows(in tableView: NSTableView) -> Int { groups.count }
    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        let group = groups[row]
        if column?.identifier.rawValue == "color" {
            return colorCell(hex: group.color, row: row, target: self, swatchAction: #selector(pickColor(_:)), delegate: self)
        }
        let field = NSTextField(string: group.name)
        field.identifier = .init("name")
        field.isBordered = false
        field.drawsBackground = false
        field.delegate = self
        return field
    }
}

// MARK: Settings window (⌘,): home page and pinned tabs, saved per app
final class SettingsWindow: NSWindowController, NSWindowDelegate, NSTextFieldDelegate, NSSplitViewDelegate {
    static let shared = SettingsWindow()
    private let homeField = NSTextField()
    private let pinnedEditor = PagesEditor(id: "pinned", load: { App.shared.pinnedPages }, store: { App.shared.pinnedPages = $0 })
    private let quickEditor = PagesEditor(id: "quick", groups: { App.shared.quickGroups },
                                          load: { App.shared.quickPages }, store: { App.shared.quickPages = $0 })
    private let groupEditor = GroupsEditor()
    private let colorWell = NSColorWell(style: .default)
    private let hexField = NSTextField()
    private let stylePopup = NSPopUpButton()
    private let pinnedButtonsPopup = NSPopUpButton()
    private let quickButtonsPopup = NSPopUpButton()

    init() {
        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "WebAppTabs"
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 880),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "\(name) Settings"
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 560, height: 800)
        super.init(window: window)
        window.delegate = self
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let isEscape = event.keyCode == 53, windowNumber = event.windowNumber
            let handled = isEscape && MainActor.assumeIsolated {
                guard let self, let window = self.window, window.windowNumber == windowNumber,
                      !self.pinnedEditor.isEditing, !self.quickEditor.isEditing, !self.groupEditor.isEditing
                else { return false }
                window.performClose(nil)   // Esc
                return true
            }
            return handled ? nil : event
        }

        homeField.placeholderString = defaultHomeURL.absoluteString
        homeField.delegate = self

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
        let outlineRow = NSStackView(views: [NSTextField(labelWithString: "Default colour:"), colorWell, hexField, reset,
                                             Self.hint("outlines and buttons without their own Colour; AA = opacity")])
        outlineRow.spacing = 8
        stylePopup.addItems(withTitles: PinnedStyle.allCases.map(\.title))
        stylePopup.target = self
        stylePopup.action = #selector(styleChanged)
        for popup in [pinnedButtonsPopup, quickButtonsPopup] {
            popup.addItems(withTitles: ButtonLabel.allCases.map(\.title))
            popup.target = self
            popup.action = #selector(buttonLabelChanged(_:))
        }
        let styleRow = NSStackView(views: [NSTextField(labelWithString: "Pinned tabs show:"), stylePopup,
                                           NSTextField(labelWithString: "  buttons:"), pinnedButtonsPopup])
        styleRow.spacing = 8
        pinnedButtonsPopup.toolTip = "What the separate row's buttons show"
        ColorPicker.shared.willPick = { [weak self] in self?.colorWell.deactivate() }
        ColorPicker.shared.isBlocked = { [weak self] in self?.colorWell.isActive ?? false }
        groupEditor.onSave = { [weak self] in self?.quickEditor.reload() }   // the Group menus list the groups

        // The three lists, with draggable dividers between them (sizes remembered). The panes are added as
        // plain subviews with autoresizing masks, so the split view sets their frames (as arranged subviews
        // with auto layout it held them at their natural height). arrangesAllSubviews must stay on: off, the
        // subviews aren't panes at all and there are no dividers.
        let split = NSSplitView()
        split.isVertical = false
        split.dividerStyle = .paneSplitter
        split.delegate = self
        for pane in [
            Self.pane([Self.heading("Pinned tabs"),
                       Self.hint("Open first, in this order, every time the app starts, outlined in their Colour. "
                                 + "Icon: 1–2 letters, an emoji, or an SF Symbol name like checklist. They can't be closed "
                                 + "or dragged – ⌘W takes one back to its page; ⌘1, ⌘2… count them first."),
                       pinnedEditor.scroll, pinnedEditor.buttons], grow: pinnedEditor.scroll),
            Self.pane([Self.heading("Quick tab groups"),
                       Self.hint("A group is one toolbar button, \u{201C}Name ▾\u{201D}, that opens a menu of its quick tabs. "
                                 + "Create it here (name and colour; empty Colour = the default colour), then pick it in the "
                                 + "Group column of the quick tabs."),
                       groupEditor.scroll, groupEditor.buttons], grow: groupEditor.scroll),
            Self.pane([Self.heading("Quick tabs"),
                       Self.hint("Buttons at the right end of the toolbar, for pages you jump to now and then. Like pinned "
                                 + "tabs they stay open and locked (⌘W takes one back to its page), but they're not in the "
                                 + "tab bar and ⌃Tab / ⌘1, ⌘2… skip them."),
                       quickEditor.scroll, Self.row([quickEditor.buttons, NSView(),
                                                     NSTextField(labelWithString: "Buttons show:"), quickButtonsPopup])],
                      grow: quickEditor.scroll),
        ] {
            pane.translatesAutoresizingMaskIntoConstraints = true
            pane.autoresizingMask = [.width, .height]
            split.addSubview(pane)
        }
        split.autosaveName = "settingsPanes"   // new name: the panes' order changed

        // settings at the top; the lists' split view pinned below them down to the bottom, so it gets all
        // the height the window has left (as a stack view arranged subview it kept its natural height)
        let stack = NSStackView(views: [
            Self.heading("Home page"), homeField,
            Self.hint("Opened by New Tab (⌘T) and View → Home Page (⌘⇧H). Leave empty for \(defaultHomeURL.absoluteString)"),
            styleRow, outlineRow,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.setCustomSpacing(18, after: stack.views[2])
        let root = NSView()
        for view in [stack, split] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            split.topAnchor.constraint(equalTo: stack.bottomAnchor, constant: 12),
            split.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            split.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            split.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
        ])
        window.contentView = root
        for view in [homeField, stack.views[2]] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        window.center()
    }
    required init?(coder: NSCoder) { fatalError() }

    // Each list keeps at least a few rows; the window grows/shrinks them in proportion
    static let minPaneHeight: CGFloat = 175   // heading, two lines of hint, a few table rows, + / −
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposed: CGFloat, ofSubviewAt index: Int) -> CGFloat {
        splitView.subviews[index].frame.minY + Self.minPaneHeight
    }
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposed: CGFloat, ofSubviewAt index: Int) -> CGFloat {
        splitView.subviews[index + 1].frame.maxY - Self.minPaneHeight - splitView.dividerThickness
    }
    func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
        // proportional, but never below the minimum (taken from the largest pane)
        let panes = splitView.subviews, divider = splitView.dividerThickness
        let available = splitView.bounds.height - divider * CGFloat(panes.count - 1)
        let oldTotal = panes.reduce(0) { $0 + $1.frame.height }
        // first layout: pinned tabs and quick tabs 2 parts each, groups (in between) 1
        let weights = oldTotal > 1 ? panes.map(\.frame.height) : panes.indices.map { $0 == 1 ? 1.2 : 2 }
        let weightTotal = weights.reduce(0, +)
        var heights = weights.map { max(Self.minPaneHeight, ($0 / weightTotal * available).rounded()) }
        if let biggest = heights.indices.max(by: { heights[$0] < heights[$1] }) {
            heights[biggest] += available - heights.reduce(0, +)
        }
        var y: CGFloat = 0
        for (pane, height) in zip(panes, heights) {
            pane.frame = NSRect(x: 0, y: y, width: splitView.bounds.width, height: max(0, height))
            y += height + divider
        }
    }

    // a pane of the lists' split view: its views stacked, `grow` (the table) taking the pane's spare height
    private static func pane(_ views: [NSView], grow: NSScrollView) -> NSView {
        let pane = NSStackView(views: views)
        pane.orientation = .vertical
        pane.distribution = .fill   // the table (lowest hugging) takes the spare height
        pane.alignment = .leading
        pane.spacing = 6
        pane.edgeInsets = NSEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        for view in views where view is NSScrollView || view is NSStackView || (view as? NSTextField)?.cell?.wraps == true {
            view.widthAnchor.constraint(equalTo: pane.widthAnchor).isActive = true
        }
        let minimum = grow.heightAnchor.constraint(greaterThanOrEqualToConstant: 40)
        minimum.priority = .init(999)
        minimum.isActive = true
        grow.setContentHuggingPriority(.init(1), for: .vertical)
        grow.setContentCompressionResistancePriority(.init(1), for: .vertical)
        return pane
    }
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

    @objc private func styleChanged() {
        App.shared.pinnedStyle = PinnedStyle.allCases[stylePopup.indexOfSelectedItem]
        pinnedButtonsPopup.isEnabled = App.shared.pinnedStyle == .separateRow   // only the separate row has buttons
    }
    @objc private func buttonLabelChanged(_ popup: NSPopUpButton) {
        let label = ButtonLabel.allCases[popup.indexOfSelectedItem]
        if popup === pinnedButtonsPopup { App.shared.pinnedButtonLabel = label } else { App.shared.quickButtonLabel = label }
    }
    private static func row(_ views: [NSView]) -> NSStackView {
        let row = NSStackView(views: views)
        row.spacing = 8
        views.first { type(of: $0) == NSView.self }?.setContentHuggingPriority(.init(1), for: .horizontal)   // spacer
        return row
    }

    func show() {
        pinnedEditor.reload()
        quickEditor.reload()
        groupEditor.reload()
        stylePopup.selectItem(at: PinnedStyle.allCases.firstIndex(of: App.shared.pinnedStyle) ?? 0)
        pinnedButtonsPopup.selectItem(at: ButtonLabel.allCases.firstIndex(of: App.shared.pinnedButtonLabel) ?? 0)
        quickButtonsPopup.selectItem(at: ButtonLabel.allCases.firstIndex(of: App.shared.quickButtonLabel) ?? 0)
        pinnedButtonsPopup.isEnabled = App.shared.pinnedStyle == .separateRow
        colorWell.color = App.shared.outlineColor
        hexField.stringValue = App.shared.outlineColor.hexString
        homeField.stringValue = UserDefaults.standard.string(forKey: Setting.homeURL) ?? ""
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    // Finish an edit that's still in progress when the window closes
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.makeFirstResponder(nil)
        ColorPicker.shared.stop()
        return true
    }

    @objc private func outlineColorChanged() {
        App.shared.outlineColor = colorWell.color
        hexField.stringValue = App.shared.outlineColor.hexString
        refreshDefaultSwatches()
    }
    @objc private func resetOutlineColor() {
        UserDefaults.standard.removeObject(forKey: Setting.outlineColor)
        colorWell.color = App.shared.outlineColor
        hexField.stringValue = App.shared.outlineColor.hexString
        App.shared.outlinePinnedTabs()
        App.shared.tabs.forEach { $0.refreshPinnedSwitcher() }
        refreshDefaultSwatches()
    }
    // rows without their own colour show the default one
    private func refreshDefaultSwatches() {
        [pinnedEditor.table, quickEditor.table, groupEditor.table].forEach { $0.reloadData() }
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
            refreshDefaultSwatches()
        }
    }
    private func saveHome() {
        let text = homeField.stringValue.trimmingCharacters(in: .whitespaces)
        if text.isEmpty { return UserDefaults.standard.removeObject(forKey: Setting.homeURL) }
        guard let url = webURL(from: text) else { return NSSound.beep() }
        UserDefaults.standard.set(url.absoluteString, forKey: Setting.homeURL)
        homeField.stringValue = url.absoluteString
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
