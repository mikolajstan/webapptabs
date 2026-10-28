# WebAppTabs

Small single-site browsers for macOS (26 / Tahoe), one app per web app, where every page is a **native
macOS tab**. They replace Safari's "Add to Dock" web apps, which can't do tabs.

Installed apps (in `~/Applications`, pinned to the Dock):

| App | Site | Built from |
|---|---|---|
| **Gmail Tabs** | https://mail.google.com/mail/ | `Gmail.app` (Safari web app) |
| **GitHub Tabs** | https://github.com/ | `GitHub.app` (Safari web app) |
| **Link Router** | – | set as the **default web browser**; sends links to the right Tabs app |

## Building

```bash
# a new Tabs app from an existing Safari or Chrome web app (copies its address and icon; only needed once)
./make-app.sh ~/Applications/GitHub.app            # → ~/Applications/GitHub Tabs.app
./make-app.sh ~/Applications/Gmail.app "My Mail"   # custom name
./make-app.sh ~/Applications/Chrome\ Apps.localized/YouTube.app "YouTube Tabs"   # from a Chrome web app

# after changing main.swift: rebuild every Tabs app (running ones are restarted, tabs come back)
./make-app.sh --all

# Link Router (after changing router/main.swift)
router/build.sh
```

No Xcode project: `swiftc` compiles `main.swift` into one binary; `make-app.sh` wraps it in an `.app`
bundle whose `Info.plist` carries the site (`WebAppURL`), then ad-hoc signs and registers it.
To make a Safari web app first: open the site in Safari → **File → Add to Dock…**.

## Features

**Tabs** – ⌘T new tab · ⌘W close · ⌃Tab / ⌃⇧Tab switch · ⌘1…⌘9 jump · drag tabs out into windows /
Window → Merge All Windows · ⌘⇧T reopen closed tab · File → Recently Closed (any tab closed this session).

**Links**
- ⌘-click opens a link in a new tab (switches to it); **middle-click** opens it in the background, in
  click order after previously middle-clicked tabs (like Safari).
- Closing a tab selects the one to its right (left if last) – or returns to the tab that opened it, if
  you went straight there from it (like Safari).
- Links to other sites open in the default browser (→ Link Router). Same-domain links/redirects and
  sign-in pages (`accounts.`, `login.`, `auth.`, `sso.`, `signin.`) stay in the app.
- `mailto:` etc. open in their apps. Gmail/Outlook/Messenger redirect-wrapped links are unwrapped by
  Link Router.

**Pinned tabs** (Settings → Pinned Tabs) – open first, in order, every time the app starts, with a
coloured outline (Settings → General → Default colour, or the page's own; opacity 0 = none). Each has an **icon** (1–2 letters, an
emoji, an SF Symbol name such as `checklist`, `ticket`, `timer`, or an image: a file path or a web address
like a site's `https://…/favicon.ico`). Settings → **Pinned tabs show**:
*Icon only* (36 px tabs, name on hover), *Icon and name, compact* (just as wide as icon + name; the other
tabs get the rest), *Icon and name, full width*, *Name only, full width*, or *Separate row above the tabs* (buttons in the
toolbar next to ‹ ›, tinted with the outline colour; the tab bar below only has the tabs you opened and
stays hidden until you open one). Settings → "buttons:" next to it: icon and name, icon only or name only;
the quick tab buttons have their own "Buttons show" setting.
Pinned tabs are locked: no close button, ⌘W takes them back to their pinned page instead of closing, they
can't be dragged, and anything that moves them (a tab dropped in between, one pulled into its own window)
snaps back. ⌘1, ⌘2… count them first in every style. New tabs always open after the pinned ones.
For example: ⏱ Timesheets · `checklist` Tasks · `ticket` Tickets.

**Quick tabs** (Settings → Quick Tabs) – pages you jump to now and then, shown as buttons
at the right end of the toolbar (before Share), tinted with the outline colour. Like pinned tabs they open
at launch, stay loaded (unless their **Load** says otherwise, below) and are locked (⌘W takes one back to its page), but they never appear in the tab bar
and ⌃Tab / ⌃⇧Tab and ⌘1…⌘9 skip them. They count as sitting before the pinned tabs: on a quick tab ⌃Tab goes
to the first pinned tab and ⌃⇧Tab to the last tab, and closing the last tab next to them selects the first
pinned tab rather than a quick one. **Quick tab groups** (the sidebar of Settings → Quick Tabs: icon, name,
colour, width, **+** / **−**) are one button each, `Name ▾`, that opens a menu of their quick tabs – it shows the open
page's icon; put a quick tab in a group with its Group menu, or drag it onto the group. When the window is too narrow,
the toolbar's » menu lists the pinned and quick pages (groups as submenus).

**Loading and memory** – every loaded tab runs its own copy of the site in its own process (Gmail: 1 GB+
each in Activity Monitor). Pinned tabs are always loaded. Quick tabs have a **Load** setting (a column in the
quick tabs list), so rarely used ones don't have to be loaded all the time:
- **Always** (default) – loaded at launch, stays loaded. Only loaded tabs send notifications, so keep the
  ones you need them from (e.g. Gmail's inbox / chat) on Always.
- **When opened** – the tab and its button are there, but the page loads the first time you open it, then
  stays loaded until you quit.
- **Unload idle** – loads when opened, and is unloaded again after **Unload idle tabs after** *n* minutes
  (Settings, default 10) in the background; its process ends and the memory is freed. Opening it again
  reloads the page where it was (back/forward history kept); things like scroll position are lost.

By hand (View menu, which stays open so you can unload one tab after another): **Unload Background Tabs** and
**Unload Tab ▸** free the memory of quick tabs and ordinary tabs right away – every tab except the pinned ones and the tab shown in each window. Unloaded tabs are dimmed
(tab bar, toolbar buttons, their menus); opening one loads it again where it was, and it stays in the saved
session. **Reload All Tabs** (⌘⇧R) reloads every loaded tab. **View → Tab Memory** lists every tab with its
state (loaded / unloaded / not loaded yet) and memory, with Unload / Reload buttons and the total.

**Keeping pages signed in**
- After the Mac (or its screens) slept for 2 hours or more (Settings → **Reload after sleeping**, 1–48 h), the
  pinned tabs and the quick tabs on Always reload: pages from before have an expired session, and the next
  click on them fails with "session expired". Other tabs are left as they are.
- When a tab lands on the site's **login page** and you sign in there, the pinned tabs and the quick tabs on
  Always reload, and that tab goes back to its own pinned page. The login page is recognised by its address
  (login, sign-in, authentication, sso…, or a sign-in host like accounts.google.com), or set it in Settings →
  **Login page**.
- At launch the first tab loads on its own and the others right after it (at most 8 s later), so they share
  the session and security token the site hands out. Loading all at once, each tab could get its own token,
  and all but one then failed their background requests (e.g. a table that never loaded).
- A diagnostics log of launches, quits, sleep / wake, reloads, unloads and login pages is kept in
  `~/Library/Logs/WebAppTabs/<app>.log` (local time; addresses without their query).

**Other**
- Toolbar: ‹ › back/forward, centred page title, Share button.
- Restore Tabs on Launch (app menu, per app) – also restores window size, position and display.
- Mute Site (app menu) – stops the page starting sounds (so a Gmail chat sound doesn't grab AirPods).
- Notifications from the site → macOS notifications (click → that tab); unread count `(3)` in the page
  title → Dock badge.
- Downloads → ~/Downloads (`name (1).pdf` on clashes), Dock Downloads bounce + notification (click →
  shows the file in Finder).
- Pop-up dialogs (alert / confirm / prompt), file upload, View → Home Page (⌘⇧H).
- Pages can be inspected from Safari → Develop → *Mac name* → *app*.

## Settings (⌘,)

Per app (stored in `UserDefaults` under the app's bundle ID, e.g. `local.webapptabs.GmailTabs`), in four tabs
along the window's toolbar. Every change applies right away; Esc closes the window, which reopens on the tab
you used last. Each section has one short line; an ⓘ next to it has the full explanation (hover, or click).
- **General** – home page; the **default colour** (colour picker, or hex `#RRGGBB` / `#RRGGBBAA` where AA is
  the opacity; opacity 0 = no outline); Restore tabs on launch and Mute site (also in the app menu).
- **Pinned Tabs** – how pinned tabs show (and the separate row's button label), then the list (icon preview +
  name; **+** adds the page you're on, **−** removes, drag to reorder) and the selected page's settings:
  icon (with a large preview), name, address, colour and width.
- **Quick Tabs** – what the buttons and the group menus show; on the left the groups (top) and the quick
  tabs (below, with their group's name), each with **+** / **−**, and a divider between them that can be
  dragged. On the right the selected quick tab's settings (as for pinned tabs, plus its group and **Load**),
  or the selected group's: icon (empty = its open page's icon), name, colour, width. Drag a quick tab onto a
  group to move it there, or within the list to reorder.
- **Loading** – unload idle time, reload after sleeping, login page, and a button for Tab Memory.

A page's or group's colour (empty = the default colour) is its outline in the tab bar and its toolbar
button's tint; its **width** (points, 24–800; empty = automatic) sets the tab's width in the tab bar or its
button's width in the toolbar (a button too narrow for icon and name shows just the icon).

## Known limits

- Notifications only while the app is running (no web push).
- Logins aren't shared with Safari; no iCloud Keychain autofill, no Safari extensions.
- A site that jumps to another site with its own script (not a link) stays inside the app.
- Icon-only pinned tabs are a fixed 36 px (macOS's built-in pinned layout). "Icon and name, compact" falls
  back to equal-width tabs when there are so many tabs that the others would get narrower than 100 px.
- Pinned tabs, the outline and icon centring use internal macOS tab-bar views. If a macOS update changes
  them, pinned tabs fall back to normal-width tabs / no outline – nothing else breaks.

Changes per version: [CHANGELOG.md](CHANGELOG.md). Developer notes (architecture, workarounds, testing):
see [CLAUDE.md](CLAUDE.md).
