# Changelog

All notable changes to WebAppTabs. Versions match the git tags and the
[GitHub releases](https://github.com/mikolajstan/webapptabs/releases).

## Unreleased

### Added
- **Unload by hand** (View menu): **Unload Background Tabs**, and **Unload Tab ▸** for one tab. They free the
  memory of quick tabs and ordinary tabs right away; pinned tabs and the tab each window shows stay loaded.
  Opening an unloaded tab loads it again where it was, and unloaded tabs stay in the saved session.
- **Reload All Tabs** (⌘⇧R): reloads every loaded tab.
- **Window → Tab Memory**: every tab with its state (loaded / unloaded / not loaded yet) and memory, as
  Activity Monitor shows it, with Unload / Reload buttons and the total.
- Unloaded tabs are **dimmed** in the tab bar, the toolbar buttons and their menus.
- **Reload after waking**: after the Mac or its screens slept for 2 hours or more (Settings → **Reload after
  sleeping**), the pinned tabs and the quick tabs on Always reload. Pages left open overnight had an expired
  session, and the next action on them failed with "session expired".
- **Login page detection**: after you sign in on the site's login page, the pinned tabs and the quick tabs on
  Always reload, and that tab goes back to its pinned page. The login page is recognised by its address, or
  set in Settings → **Login page**.
- **Diagnostics log** in `~/Library/Logs/WebAppTabs/<app>.log`: launches, quits, sleep / wake, reloads,
  unloads and login pages.

### Changed
- Pinned tabs are always loaded; the **Load** setting is only for quick tabs now.

## [1.5.1] – 2026-10-24

### Changed
- Clean-up: removed references to a site the project isn't related to from the README, code comments and
  notes. Examples now use Gmail and GitHub.

## [1.5] – 2026-10-22

### Added
- **Load** setting per pinned and quick tab (a column in both Settings lists), to save memory. Every loaded tab
  runs its own copy of the site; with Gmail that's 1 GB+ each.
  - **Always** (default): loaded at launch, as before.
  - **When opened**: loaded the first time you open it, then stays loaded.
  - **Unload idle**: unloaded again after some minutes in the background. Its process ends and the memory is
    freed; opening it reloads the page where it was, with its back/forward history.
  - **Unload idle tabs after** *n* minutes in Settings (default 10).
  - A tab that isn't loaded doesn't send notifications.

## [1.4] – 2026-10-21

### Added
- **Group icons**: an Icon column in Settings → Quick tab groups, like a tab's icon. The group's button and its
  entry in the » overflow menu show it. Empty keeps the open page's icon, as before.
- **Image icons**: any Icon field also takes an image file path (`/…` or `~/…`) or a web address, such as a
  client site's `https://…/favicon.ico`. Web images are downloaded once in the background and cached; the
  first letter shows until then. Images keep their own colours.
- **Group menus** setting (Settings → Quick tabs): what the pages in a group's menu show – icon and name, icon
  only, or name only.

### Fixed
- Wide SF Symbols (e.g. `person.3`) were cut off at the sides of the 16 pt icon; they're scaled down to fit.

## [1.3] – 2026-10-21

### Added
- **Quick tab groups** (Settings → Quick tab groups): create a group with a name and a colour, then pick it
  for quick tabs in the Group menu of the quick tabs list.
  - A group is one toolbar button, "Name ⌄", that opens a menu of its quick tabs.
  - The button shows the open page's icon and is highlighted while one of its pages is open; the menu ticks
    the open page.
  - Renaming a group updates everything in it, and removing a group makes its quick tabs separate buttons
    again.
- **Colours per tab**: a Colour column in the pinned tabs, quick tab groups and quick tabs lists.
  - A page's or group's colour (swatch → colour picker, or hex) is its outline in the tab bar and its
    toolbar button's tint.
  - Empty uses the default colour (formerly "Outline colour").
- **Widths per tab**: a Width column (points; empty = automatic) for pinned tabs, quick tab groups and quick
  tabs.
  - It sets a pinned tab's width in the tab bar (in every style) or the toolbar button's width.
  - Content is centred in a wider button; a button too narrow for icon and name shows just the icon.
- **Button labels**: what the separate row's pinned buttons and the quick tab buttons show (icon and name,
  icon only, or name only), set separately for each.

### Changed
- Settings: the pinned tabs, quick tab groups and quick tabs lists sit in a split view with draggable
  dividers, and all of them grow with the window. Before, only the pinned list did.

### Fixed
- **Duplicate notifications**: every pinned and quick tab runs its own copy of the site, so each notification
  arrived once per tab. With Gmail's 2 pinned + 3 quick tabs, one chat message gave 5 notifications; it's
  now shown once. A tagged notification replaces the earlier one with that tag, as in browsers.
- **Tab bar visibility**: the tab bar is hidden only when it would show nothing, or when the window is a
  single ordinary tab (as in macOS). Before, a single pinned tab or a single opened tab next to pinned and
  quick tabs could end up invisible.
- **Narrow windows**: when the toolbar moves the quick tabs (or the separate-row pinned tabs) into its »
  menu, that menu entry now lists the pages, with groups as submenus. Before, it did nothing.

## [1.2.1] – 2026-10-21

### Changed
- Quick tabs count as sitting **before the pinned tabs**. On a quick tab, ⌃Tab goes to the first pinned tab
  and ⌃⇧Tab goes to the last tab. Before, they went to the tabs next to the quick tab's hidden position.
- Closing the last opened tab selects the first pinned tab, not the last quick tab.

## [1.2] – 2026-10-20

### Added
- **Quick tabs** (Settings → Quick tabs): a second list of pages, edited like the pinned tabs. They show as
  buttons at the right end of the toolbar, before Share, tinted with the outline colour. Like pinned tabs,
  they open at launch, stay loaded and are locked, and ⌘W takes one back to its page. They never appear in
  the tab bar, and ⌃Tab / ⌃⇧Tab and ⌘1…⌘9 skip them.

### Fixed
- Adding a quick page could crash the app: windows shared one toolbar identifier, so a button got added
  twice. Each tab now has its own toolbar.
- ⌃Tab and ⌘W act on the tab you're looking at.

## [1.1] – 2026-10-20

### Added
- New "Pinned tabs show" style **Separate row above the tabs**: the pinned pages become buttons in the
  toolbar next to ‹ ›, tinted with the outline colour. The tab bar below only shows the tabs you opened and
  stays hidden until you open one.
- **Locked pinned tabs**: no close button in any style, and they can't be dragged. Anything that still moves
  them snaps back: a tab dropped in between, or a pinned tab pulled into its own window.
- Esc closes the Settings window.

### Changed
- Only ⌘W (File → Close Tab) takes a pinned tab back to its pinned page. The window's × and "Close Other
  Tabs" now leave pinned tabs alone.

### Fixed
- Clicks on the tab bar hit the right tab in the compact and separate-row styles. Before, they were worked
  out as if all tabs had the same width.
- Clicking empty tab-bar space does nothing; only **+**, ⌘T and File → New Tab open a tab.
- Separate row: switching pinned pages no longer resizes the page. Before, pages looked shifted or frozen
  and were slow.
- `tools/test.sh` stops on a compile error instead of re-running the previous build.

## [1.0] – 2026-10-20

First tracked version: single-site browsers for macOS 26 that replace Safari "Add to Dock" web apps, with
every page as a native macOS tab.

### Added
- **One app per site**, built from a Safari web app with `make-app.sh`. `./make-app.sh --all` rebuilds
  every Tabs app.
- **Native tabs**: ⌘T, ⌘W, ⌃Tab / ⌃⇧Tab, ⌘1…⌘9, ⌘⇧T and File → Recently Closed (any tab closed this
  session).
- **Safari-like tab behaviour**:
  - ⌘-click opens a link in a new tab.
  - Middle-click opens it in the background, in click order.
  - Closing a tab returns to the tab that opened it, or selects the tab to its right.
- **Toolbar** like the Safari web app: back/forward buttons, a centred page title and Share.
- **Pinned tabs** (Settings → Pinned tabs): pages that open first at every launch, with an icon (letters,
  emoji or an SF Symbol name) and a coloured outline. Settings sets the outline colour, with a colour
  picker or `#RRGGBBAA` hex.
- **Pinned tab styles**: icon only (36 px), icon and name compact (just as wide as the content), icon and
  name full width, or name only. Pinned tabs can't be closed: ⌘W or × takes one back to its page.
- **Link Router**, set as the default browser:
  - Links open in the right Tabs app; everything else goes to Safari.
  - Redirect-wrapped links (Gmail, Messenger, Outlook) are unwrapped.
  - Links to other sites open outside the app; sign-in pages on the same domain stay inside.
- **Settings** (⌘,), per app: home page, pinned tabs, outline colour.
- **App menu** toggles, per app: Restore Tabs on Launch (also remembers window size, position and
  display) and Mute Site.
- **Web content**:
  - Site notifications become macOS notifications, and an unread count in the title becomes a Dock badge.
  - Downloads go to ~/Downloads.
  - Pop-up dialogs, file upload and copy/paste work.

[1.5.1]: https://github.com/mikolajstan/webapptabs/releases/tag/1.5.1
[1.5]: https://github.com/mikolajstan/webapptabs/releases/tag/1.5
[1.4]: https://github.com/mikolajstan/webapptabs/releases/tag/1.4
[1.3]: https://github.com/mikolajstan/webapptabs/releases/tag/1.3
[1.2.1]: https://github.com/mikolajstan/webapptabs/releases/tag/1.2.1
[1.2]: https://github.com/mikolajstan/webapptabs/releases/tag/1.2
[1.1]: https://github.com/mikolajstan/webapptabs/releases/tag/1.1
[1.0]: https://github.com/mikolajstan/webapptabs/releases/tag/1.0
