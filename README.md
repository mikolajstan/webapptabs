# WebAppTabs

Small single-site browsers for macOS (26 / Tahoe), one app per web app, where every page is a **native
macOS tab**. They replace Safari's "Add to Dock" web apps, which can't do tabs.

Installed apps (in `~/Applications`, pinned to the Dock):

| App | Site | Built from |
|---|---|---|
| **Netivo Tabs** | https://projekty.netivo.pl/admin/tasks | `Projekty Netivo – Zadania.app` (Safari web app) |
| **Gmail Tabs** | https://mail.google.com/mail/ | `Gmail.app` (Safari web app) |
| **Link Router** | – | set as the **default web browser**; sends links to the right Tabs app |

## Building

```bash
# a new Tabs app from an existing Safari web app (copies its address and icon; only needed once)
./make-app.sh ~/Applications/GitHub.app            # → ~/Applications/GitHub Tabs.app
./make-app.sh ~/Applications/Gmail.app "My Mail"   # custom name

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

**Pinned tabs** (Settings → Pinned tabs) – open first, in order, every time the app starts, with a
coloured outline (Settings → Outline colour; opacity 0 = none). Each has an **icon** (1–2 letters, an
emoji, or an SF Symbol name such as `checklist`, `ticket`, `timer`). Settings → **Pinned tabs show**:
*Icon only* (36 px tabs, name on hover), *Icon and name, compact* (just as wide as icon + name; the other
tabs get the rest), *Icon and name, full width*, *Name only, full width*, or *Separate row above the tabs* (buttons in the
toolbar next to ‹ ›, tinted with the outline colour; the tab bar below only has the tabs you opened and
stays hidden until you open one).
Pinned tabs are locked: no close button, ⌘W takes them back to their pinned page instead of closing, they
can't be dragged, and anything that moves them (a tab dropped in between, one pulled into its own window)
snaps back. ⌘1, ⌘2… count them first in every style. New tabs always open after the pinned ones.
Netivo: ⏱ Timesheets · `checklist` Zadania · `ticket` Tickety.

**Quick tabs** (Settings → Quick tabs, same list editor) – pages you jump to now and then, shown as buttons
at the right end of the toolbar (before Share), tinted with the outline colour. Like pinned tabs they open
at launch, stay loaded and are locked (⌘W takes one back to its page), but they never appear in the tab bar
and ⌃Tab / ⌃⇧Tab and ⌘1…⌘9 skip them.

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

Per app (stored in `UserDefaults` under the app's bundle ID, e.g. `local.webapptabs.NetivoTabs`):
home page, pinned tabs (Icon / Name / Address, **+** / **−**, drag to reorder), how pinned tabs show, outline colour,
quick tabs (same editor) (colour
picker, or hex `#RRGGBB` / `#RRGGBBAA` where AA is the opacity).
Restore Tabs and Mute Site are in the app menu. Esc closes the Settings window.

## Known limits

- Notifications only while the app is running (no web push).
- Logins aren't shared with Safari; no iCloud Keychain autofill, no Safari extensions.
- A site that jumps to another site with its own script (not a link) stays inside the app.
- Icon-only pinned tabs are a fixed 36 px (macOS's built-in pinned layout). "Icon and name, compact" falls
  back to equal-width tabs when there are so many tabs that the others would get narrower than 100 px.
- Pinned tabs, the outline and icon centring use internal macOS tab-bar views. If a macOS update changes
  them, pinned tabs fall back to normal-width tabs / no outline – nothing else breaks.

Developer notes (architecture, workarounds, testing): see [CLAUDE.md](CLAUDE.md).
