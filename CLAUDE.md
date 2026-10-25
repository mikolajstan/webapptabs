# WebAppTabs – notes for Claude

Single-site browsers for macOS 26 (Tahoe): one app per web app, each page a native macOS tab, replacing
Safari "Add to Dock" web apps. User-facing docs: README.md. Everything below is what isn't obvious from
the code: how it fits together, decisions already made, and traps already hit.

## Files

| File | What |
|---|---|
| `main.swift` (~2650 lines) | the whole Tabs app (AppKit + WKWebView, no Xcode project) |
| `make-app.sh` | builds `~/Applications/<Name>.app` from a Safari web app, or `--all` rebuilds every Tabs app |
| `router/main.swift`, `router/build.sh` | **Link Router**, the default browser: routes links to Tabs apps, rest to Safari |
| `tools/test.sh`, `tools/harness.py` | scripted tests in a throwaway app (see Testing) |
| `tools/crop.swift` | crop + enlarge a screenshot region (tab bar inspection) |
| `CHANGELOG.md` | changes per version (= git tag / GitHub release); add an entry with every release |

Build: `./make-app.sh --all` after any main.swift change (restarts running apps; tabs are restored from the
saved session). Router: `router/build.sh` then `pkill -x LinkRouter` (it stays running).

## The user's setup (Oct 2026)

- Mac: external monitor (main) + built-in display **below** it → built-in has negative y coordinates.
- Apps: **Gmail Tabs** (`local.webapptabs.GmailTabs`), **GitHub Tabs** (`local.webapptabs.GitHubTabs`, github.com) and a
  third Tabs app for a work site, all pinned in the Dock. The work site's name, address and settings are
  kept out of the repo (in Claude's local memory) – don't write them into tracked files. GitHub Tabs replaced the GitHub Safari web app's Dock tile in place (edited
  `com.apple.dock persistent-apps` via export → change one tile → import → `killall Dock`). Old Safari web apps may still exist; make-app.sh only
  needs them for a first build.
- **Link Router** (`local.linkrouter`) is the default web browser.
- Gmail Tabs: Mute Site on.
- Inspect/modify settings: `defaults read local.webapptabs.GmailTabs`. `pinnedPages`/`session` are JSON
  stored as data. Write single keys with `defaults write … -data <hex>`, **never `defaults import`** on a real
  app (it replaces the whole domain). Quit the app first (`pkill -f "<Name>.app/Contents/MacOS/WebAppTabs"`).
- The user writes Polish/English, prefers custom code over third-party apps, wants things verified (screens,
  tests) before being told they work, and prefers background computer-use (app_* tools).

## Architecture (main.swift)

- **One NSWindow per tab**, grouped with native tabbing (`tabbingMode = .preferred`, `tabbingIdentifier`).
  `Tab` (NSWindowController) owns one `WebView` and is its navigation/UI delegate. `App.shared` owns `tabs`.
- `homeURL` = Settings override (`homeURL` default) or `WebAppURL` from Info.plist (`defaultHomeURL`).
- `App.openTab(url:configuration:next:after:opener:newWindow:inBackground:pinned:)` is the single way tabs
  are created. Position: inserted right after `after ?? next` via `tabGroup.insertWindow(_:at:)`, clamped to
  after the pinned tabs. `inBackground` re-selects the current tab.
- Tab selection is tracked by **KVO on `NSWindowTabGroup.selectedWindow`** (`observeSelection`), not by
  key-window events (those don't fire while the app is inactive). `didGetSelected(after:)` drives two
  Safari behaviours: middle-click ordering (`lastOpenedInBackground`) and "closing returns to opener"
  (`returnOnClose`, applied in `windowShouldClose` by pre-selecting the opener).
- Settings window: `SettingsWindow` (⌘,, issue #10): a `.preference` toolbar of selectable items switching
  the content between four panes – `GeneralPane` (home, default colour well + hex, Restore Tabs / Mute Site
  checkboxes; the app-menu items get their tick in `validateMenuItem`), `PinnedPane` (style + list + `PageForm`),
  `QuickPane` (sidebar of "All quick tabs" + groups | the selected group's quick tabs | `PageForm(quick:)` or
  `GroupForm`; drop a page row on a group = move it there; reordering inside a group moves the page in
  `quickPages` before the target), `LoadingPane`. One window size for all panes (`settingsWindow` frame
  autosave) and the last pane (`settingsPane`) are remembered. Building blocks in `enum Form` (grid, hint with
  the long text as tooltip, list, cell), `ColorField`, `IconField` (live 32 pt preview). The forms stop the
  colour panel when they show another page (`ColorPicker.stop`), else it kept editing the previous one.
  Known: clicking another field within ~0.3 s of pressing Return in a form field returns the focus to the
  first one (machine speed only; Tab between fields is fine). Per-page `PinnedPage.color` / group
  `QuickGroup.color` (hex) override
  the default for outlines and toolbar buttons; colour fields use the shared `ColorPicker` (NSColorPanel target,
  yields to the default colour well while it's active). `pinnedButtonLabel` / `quickButtonLabel`
  (`ButtonLabel`: icon and name / icon / name) set what the toolbar pills show (`PinnedSwitcher.update(show:)`).
  `PinnedPage.width` / `QuickGroup.width` (points): a fixed width in `narrowPinnedTabs` (the pass also runs for
  it in the full-width styles) and `Pill.fixedWidth` (content centred, name dropped by `fitLabel` if it
  doesn't fit next to the icon).
  Outline colour is stored as "r g b a" (sRGB) under `pinnedOutlineColor`. Every change saves immediately and calls `App.applyPinnedPages()`
  (pins/unpins/renames/opens tabs, keeps pinned first, restores selection + key window).
- Launch: `openStartTabs()` = pinned pages, then (if Restore Tabs) saved non-pinned tabs (first saved
  window continues after the pinned tabs), or the home page. `saveSession()` runs on every URL/tab/frame
  change (survives force quits) and skips pinned tabs.
- `UserDefaults` keys: see `enum Setting`. Per app automatically (bundle ID domain).

## Link rules (Tab.decidePolicyFor / createWebViewWith)

- Clicked link in main frame to another **domain** (last two host labels) → `NSWorkspace.open` (→ Link Router).
  Same domain stays (needed for Google sign-in: workspace.google.com → accounts.google.com).
- New-window links (target=_blank / window.open): stay only if `belongsInApp` = exact host, or same domain
  with a sign-in subdomain (accounts/login/auth/sso/signin). So Gmail → Docs links go to the browser.
- Script navigation and redirects stay in the app. Non-http schemes (mailto:, …) → `NSWorkspace.open`.
- ⌘-click → new foreground tab; middle-click is intercepted in `WebView.otherMouseDown` (JS
  `elementFromPoint` → link href) → background tab.
- Link Router (`router/main.swift`): host → app map built from `~/Applications/*.app` with bundle ID prefix
  `local.webapptabs.` (Info.plist `WebAppURL`, or the app's `homeURL` setting). Unwraps redirect links whose
  query contains a Tabs-app URL (`google.com/url?q=…`). Everything else → Safari.

## Private / undocumented macOS bits (each degrades gracefully)

1. **Native pinned tabs**: `window.tab.value(forKey: "tabBarItem")` (NSTabBarItem) → `setPinned:`,
   `image`, `setShowIcon:`. Settings → "Pinned tabs show" (`pinnedStyle`, key `pinnedTabStyle`: `icon` /
   `iconAndNameCompact` / `iconAndName` / `name`; falls back to the old `compactPinnedTabs` bool): `icon` =
   `pinned` + image → 36 px icon-only tabs; `iconAndName*` = not pinned, image + `showIcon` → the tab's own
   icon slot before the title; `name` = plain tab. Guarded with `responds(to:)`.
   **Compact icon + name widths** (`narrowPinnedTabs`, `hookTabBarLayout`): normal tabs are always equal
   width, so after `NSTabBar._layOutButtonsAnimated:` (hooked) the pinned NSTabButtons get fit-to-content
   frames and the rest share the remainder; NSTabSeparator views (one at each tab's right edge) move too.
   The tab bar sets frames again later (animation blocks), so `setFrame:` is overridden on NSTabButton and
   NSTabSeparator to apply the kept frame while bar width + subview count are unchanged and
   `_draggedTabButton` is nil; a mismatch schedules a recompute (live resize). Fit = 2·(5 + 16 close/right
   slot + stack spacing) + 16 icon + 6 + label intrinsic width + 4. Also sets `buttonWidthForTitleLayout`
   (else the name truncates) and `canShowCloseButton = false` on pinned tabs. Falls back to native when the
   others would be < 100 px (macOS then stacks tabs). Snapshots (`cacheDisplay`) draw titles wider than the
   real window – check truncation with `app_zoom`. Tab dragging with this on is not verified (background
   drags arrive as clicks).
   Buttons/separators are matched to tabs by identity, not x order: NSTabButton.`tabBarViewItem` is the
   window's `tab.tabBarItem`; separators come from NSTabBar ivar `_tabBarViewItemsToTabSeparators`
   (`App.tabButtons(in:for:)`). Never set `buttonWidthForTitleLayout` to 0 – it loops the window layout
   ("more Layout Window passes than there are views") – zero-width tabs are `isHidden` instead.
   **Separate row** (`separateRow`): pinned buttons width 0 + hidden, toolbar item `.pinnedSwitcher`
   (`PinnedSwitcher`: custom `Pill` views – icon + label in a padded stack, layer background tinted with
   `outlineColor`; an NSButton with image + attributed title under-reported its width, so the text ran
   past the background. `Tab.updateToolbar` / `refreshPinnedSwitcher`; toolbars share the "main"
   identifier, so inserting in one adds to all).
   The tab bar is hidden while only pinned tabs are open by hiding the NSTitlebarAccessoryViewController
   (public `isHidden`; `updateTabBarVisibility`) – `toggleTabBar` does nothing with 2+ tabs. Rule: hidden only
   when the bar would show nothing, or the window is a single ordinary tab (macOS's own behaviour); next to
   pinned / quick tabs even one opened tab shows, and a lone pinned tab keeps it on. A one-tab window
   has no accessory: there `toggleTabBar` (View → Show Tab Bar) is used to show a lone pinned tab. Hide it in
   **every** tab window: each has the accessory, but the NSTabBar view inside moves to the selected one.
   Hiding only the window that holds the bar made every tab switch resize the page by 36 px, which left
   pages drawn shifted under the toolbar and looking frozen/slow (user report).
   **Clicks**: NSTabBar finds the clicked tab arithmetically from its equal-width layout
   (`_visibleTabIndexAtPoint:stackingRegion:ignorePointsOutsideOfLayoutBounds:`, point in the buttons'
   row coordinates) → hooked to answer from the real frames whenever kept frames are active
   (`tabIndex(at:in:)`, NSNotFound for empty space), else clicks hit the wrong / hidden tabs.
   A click on empty tab-bar space sends `newWindowForTab:` – `Tab.newWindowForTab` ignores it unless the
   click hit `NSTabBarNewTabButton` (+); ⌘T / menu are keyboard events and pass. Test clicks: post the mouse-up with
   `NSApp.postEvent` *before* `sendEvent(mouseDown)`, or the tracking loop hangs.
   **Quick tabs** (`quickPages`, key `quickPages`; `PinnedPage.quick == true`): handled as pinned tabs
   everywhere (`tab.pinned != nil` → locked, no close button, ⌘W resets, skipped by saveSession), ordered
   after the pinned ones (`allPinnedPages`), plain tab look, always width 0 + hidden in the layout pass (which
   therefore also runs in the icon-only and full-width styles when quick tabs exist: fixed widths 36 / fit /
   0, the rest share). Switcher `.quickSwitcher` before Share. ⌃Tab / ⌘1…⌘9 are our own (`handleTabShortcut`)
   and skip them (on a quick tab: ⌃Tab → first, ⌃⇧Tab → last; `windowShouldClose` pre-selects the first
   non-quick tab when AppKit would land on a quick one); the "current" tab is the group's selectedWindow (falls back to selectedTab without a key
   window). Groups: `QuickGroup` {id, name, color, width, icon (nil = the open page's)} in `quickGroups` (Settings → Quick tab groups,
   `GroupsEditor`); a quick page points at one by `PinnedPage.groupId` (Group column = NSPopUpButton,
   `PagesEditor(groups:)`). Earlier drafts stored the group name in `PinnedPage.group` + `quickGroupColors`:
   `migrateQuickGroups()` converts that at launch. `PinnedSwitcher` makes one pill per page or per group (popup `menu(for:)`), and every switcher item
   gets a `menuFormRepresentation` (`overflowMenu()`) – without it, items moved into the toolbar's » overflow
   menu did nothing. Each Tab's toolbar has its own identifier (`main-<id>`): with a shared identifier AppKit mirrors
   item inserts across windows and throws on a duplicate. Settings lists are `PagesEditor` instances.
   **Locked pinned tabs**: `_shouldShowCloseButtonForTabBarViewItem:` hooked → no close button;
   `_dragShouldBeginFromMouseDown:withExpiration:xHysteresis:yHysteresis:` hooked → original's answer AND
   not over a pinned tab (`isPinnedTab(at:in:)`), so clicks are untouched (not verified with a real drag);
   `keepPinnedTabsInPlace()` on every `windows` KVO (after mouse-up) re-inserts pinned windows first, in list
   order, into the group holding most of them (public API, tested). `windowShouldClose` → false for pinned
   (window ×, Close Other Tabs do nothing); ⌘W = File → Close Tab = `App.closeTab(_:)`, which loads the
   pinned URL on a pinned tab instead.
2. **Outline**: finds `NSTabButton` views (private) in the selected window's tab bar, matched to
   `tabGroup.windows` by x order, sets `layer.border*`. Re-run via `outlinePinnedTabs()` (now, next runloop,
   +0.4 s) on selection/windows KVO, pin changes.
3. **Icon centring** (macOS bug): pinned button's content `NSStackView` still reserves the hidden close
   button → icon at x=24 in a 36 px tab. Fix: `detachesHiddenViews = true` + left inset (36−16)/2; originals
   restored when unpinned (`centerPinnedIcon`).
4. **Icons**: always a 16×16 image; symbols (template, tinted by tab bar) and text (CoreText ink bounds)
   are centred on their visible shape – SF Symbol images otherwise sit high, emoji low. Symbols and images
   are scaled to fit (`PinnedPage.fit`; wide ones like person.3 were clipped). An icon that's a file path or a
   web address is an image (`IconImages`: files load directly, web images download in the background into
   ~/Library/Caches/<bundle id>/icons, then tabs/buttons are redrawn; first letter meanwhile).
   `PinnedPage.normalizedIcon` keeps symbol names and image references whole, cuts other text to 2 chars.
5. **Mute**: `_setPageMuted:` via method IMP (+ JS shim blocking `play()` / AudioContext).
6. **Load modes** (`PinnedPage.load`: `LoadMode` always / whenOpened / unloadIdle; quick tabs only – `loadMode`
   is always `.always` for pinned ones; Settings → Load column, `unloadIdleMinutes`). A deferred tab
   (`Tab(deferred:)`, set by `openTab` for non-always quick pages) and
   an unloaded one hold a **fresh, never-loaded WebView**: WebKit starts no WebContent process until the first
   load, so it costs nothing. `Tab.webView` is therefore a `var` – `attach(_:)` wires a web view up (delegates,
   KVO, contentView, ‹ › toolbar targets); never keep a reference to a tab's web view. `unload()` saves
   `interactionState` (history + page), swaps in an empty web view (the old process exits);
   `loadIfNeeded()` runs from the selection KVO handler; `open(_:)` loads a URL and clears the unloaded state.
   `App.unloadIdleTabs()` runs every 10 s: `backgroundSince` is set on the first tick a tab isn't its
   window's selected tab, cleared by `didGetSelected`. Test: `_webProcessIdentifier` (KVC) is 0 for no process.
   Any tab can be unloaded by hand (View → Unload Tab ▸ / Unload Background Tabs; `App.isBackground` = not a
   pinned tab and not the tab its window shows). `Tab.pageURL` is the page also while unloaded (saveSession,
   Recently Closed) – use it instead of `webView.url`; `hasLoaded` false = "not loaded yet". Unloaded tabs are
   dimmed: NSTabButton `alphaValue` in the outline pass (the tab bar sets every button back to alpha 1 when
   the pointer moves over it, so a `setAlphaValue:` override caps buttons in `dimmedTabButtons`), `Pill.alphaValue` + menu items in `PinnedSwitcher`
   (`unloaded` ids); `App.loadStateChanged()` refreshes those and `TabMemoryWindow` (footprint via
   `proc_pid_rusage` `ri_phys_footprint` of `_webProcessIdentifier`).
   **Staying signed in** (issue #8): the reported "session expired in the morning" was **not** a cold-launch
   problem – tested with only the remember-me cookie, 3 tabs loading at once all signed in fine. It's pages
   left open while the Mac sleeps: the session expires server-side and the next AJAX action fails, with no
   redirect. So `observeSleep()` reloads `alwaysLoadedTabs` (loaded pinned + quick on Always – user's choice;
   ordinary tabs are left alone) after system or screen sleep ≥ `reloadAfterSleepHours` (Settings, default 2)
   (`awaySince`, `didWake`). Login pages: `isLoginPage` (Settings → Login page prefix, else a heuristic);
   `Tab` notes one on server redirect / commit and, when a later `didFinish` is on the site but not the login
   page, calls `App.didSignIn` → reloads the loaded always-loaded tabs (pinned + quick on Always), the tab
   goes back to its pinned URL; at most every 30 s. `Diagnostics.log` writes
   `~/Library/Logs/WebAppTabs/<app>.log` – read it when the user reports session / loading problems.
7. Notifications: JS shim replaces `window.Notification` → `webkit.messageHandlers.notify` → UNUserNotification.
   Every tab of the site posts its own copy (each pinned / quick tab runs the whole site), so the handler drops a
   repeat of the same tag + title + body within 10 s (`recentNotifications`) and identifies a tagged one by
   `"tag:" + tag` (app-wide, replaces the earlier one), an untagged one by tab + JS id.

## Decisions already made (don't redo)

- Native macOS tabs, not a custom tab bar (keeps drag-out / merge windows / ⌃Tab).
- Repo: github.com/mikolajstan/webapptabs (private). Work on a branch, `main` = last known-good build.
- Pinned tab **width is not configurable**: swizzling `NSTabBar._pinnedTabsWidth`,
  `_frameForButtonAtIndex:…` and `_unstackedFrameForButtonAtIndex:` only resized unpinned tabs; pinned
  frames come from elsewhere. Compact 36 px with icon was chosen instead.
- Outline default is a muted red at 45 % opacity (bright red was "awful"); user can pick in Settings.
- `📌` in titles was replaced by outline + icons.
- Toolbar: back/forward on the left, centred title (`centeredItemIdentifiers`), Share on the right.
- One app per site; logins are per app (WKWebView default data store per bundle ID).

## Traps hit before

- Tests: an app launched with `open -W` from the terminal is often **not frontmost** → no key-window events,
  `makeKeyAndOrderFront` doesn't change focus. Don't base logic or assertions on `windowDidBecomeKey`.
- Script-triggered clicks (`element.click()` via evaluateJavaScript) aren't user gestures (popups,
  downloads differ) → use `realClick` (synthesised NSEvents) in tests.
- `cacheDisplay` snapshots render Liquid Glass (selected tab, toolbar buttons) as white blobs; text and
  layer borders are fine. Real look: computer-use `app_screenshot` of the actual app (grant the app first).
- `addTabbedWindow(_:ordered:)` doesn't reliably place a tab next to a non-selected tab → `insertWindow(_:at:)`.
- `tabbedWindows` no longer contains a window in `windowWillClose` → capture position in `windowShouldClose`.
- WKWebView: no Edit menu = no ⌘C/⌘V; file inputs need `runOpenPanelWith`; downloads need WKDownload
  handling; `Content-Disposition: attachment` must force download even for displayable types.
- LaunchServices only delivers http(s) URLs to an app that declares them (`CFBundleURLTypes`, rank None).
- `NSApplication.delegate` is weak – keep a strong reference (bit the router once).
- `log show` doesn't capture NSLog from these ad-hoc apps → debug by writing to a file.
- Window frames: save on move/resize; on restore with one window prefer `windowFrame` over the session copy.
- `tools/test.sh` stops on a compile error (it used to re-run the previous binary under `pipefail`). If the
  test app aborts, run `$TMPDIR/webapptabs-test/Test.app/Contents/MacOS/test` directly to see the exception.
- A synthesised mouse-down on a tab button enters the tab bar's tracking loop and hangs the test – unless
  the mouse-up was queued first with `NSApp.postEvent(up, atStart: false)`.
- Shell: the scratchpad can be wiped between turns; use `set -euo pipefail`, absolute paths, and
  `"${VAR:?}"` in `rm` (unguarded variables in rm are blocked).

## Testing

```bash
tools/test.sh tools/example-steps.swift https://example.com/?home tools/example-defaults.json
```
Builds a copy of main.swift with helpers (`log`, `snap`, `bar`, `widths`, `tab`, `realClick`,
`tabButtons`, `selectedWindow` – see tools/harness.py) and timed `steps`, runs it as "Test Tabs", prints
the log. Use `https://example.com/?name` URLs so `bar()` shows readable tab names. For link/download tests
serve a page with `python3 -m http.server` or a small handler. harness.py patches two notification lines
and inserts after `UserDefaults.standard.register(...)` in main.swift – keep those lines stable (it asserts).
After a real build, check the actual app with computer-use (`app_screenshot`, `app_zoom` on the tab bar).
