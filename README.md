# NirTab

A Windows-style ⌘Tab window switcher and window layout tool for macOS. Native Swift, no dependencies.

Hold ⌘ and press Tab to see **every window of every app**, including minimized and hidden windows and apps with no
open window. Each one shows a live preview. Release ⌘ to jump to the selected window. Minimized windows are restored.

## Install
1. Download `NirTab-<version>.zip` from [Releases](https://github.com/nirli-439/NirTab/releases), unzip it, and move
   `NirTab.app` to `/Applications`.
2. The first time, right-click → **Open**. The app is self-signed, not notarized, so Gatekeeper asks once.
3. The **Setup checklist** opens and stays until everything works. It has a green check or a fix button for each of:
   - Accessibility
   - Screen Recording
   - the keyboard shortcut being active
   - being installed in Applications
   - launch at login (optional)

   Each permission is checked by a fresh process, which catches the case where System Settings shows a switch as on
   but macOS still refuses it. You can reopen the checklist anytime: menu bar → Setup Checklist.

Requires macOS 14 or later, Apple Silicon or Intel. Quit other ⌘Tab tools such as AltTab first.

## Use
| Key (while holding ⌘) | Does |
|---|---|
| Tab / ⇧Tab, → / ← | next / previous |
| W · M · F · H | close window · minimize/restore · maximize/restore size · hide app |
| Q · ⇧Q | quit app · force quit app (unsaved work is lost) |
| release ⌘ / Esc | switch / cancel |

**Mouse:** hover a tile to select it and show its buttons (close, minimize/restore, maximize, quit; larger red force quit above).
Click a tile to switch to it.

**Move the front window:** ⌥⌘ + ←/→/↑/↓ snaps it to the left/right/top/bottom half of its display.
⌃⌥⌘ + an arrow sends it to the nearest display in that direction, keeping its size and relative position where possible.
An arrow with no display in that direction does nothing. Some macOS apps do not allow their windows to be moved or resized.

**Five custom shortcuts:** Settings → Custom shortcuts. For each slot, choose a window action, click **Record…**,
then press ⌘, ⌥ or ⌃ (optionally ⇧) plus a key. Changes work immediately. **Clear** disables a slot.
Custom shortcuts override the built-in window movement shortcuts; if two slots use the same keys, the first wins.

**Window layouts:** The menu bar → Window Layouts offers halves, thirds, quarters, sixths, eighths, ninths,
twelfths and sixteenths; vertical sizes, moving/resizing, display targeting, restore, stacked-window cycling,
and tiling/cascading windows. Settings → Window layouts lets you record or clear a shortcut for each action,
select Rectangle's recommended keyboard defaults or the older Spectacle preset, set a screen-edge gap,
configure row/column tiling limits, and ignore chosen apps. Middle/extra mouse buttons can be recorded as shortcuts.
NirTab's existing ⌥⌘ and ⌃⌥⌘ arrow shortcuts keep priority where they overlap.
Enable **Snap windows by dragging to screen edges** to get a footprint and snap on release; this is off by default.
Other apps may constrain the resulting window size or position.
Actions can also be triggered without activating NirTab via `open -g 'nirtab://execute-action?name=left-half'`.

**Experimental features** (menu bar → Experimental Features; clipboard history and Pomodoro are off by default):
- **Clipboard history**: ⌥⌘V shows copied text, images/media and file references. Copy an entry back to the clipboard,
  pin it, or delete it. Up to 50 recent and 20 pinned items (16 MB per capture). Stored **unencrypted** in
  `~/Documents/NirTab/Clipboard/`; file entries reference the original file, rather than duplicating it.
  Disabling stops capture but keeps saved history until you delete it.
  Enable **Show clipboard menu-bar icon** in Experimental Features for a separate clipboard icon; click it to open
  history. The preference survives restarts; disabling clipboard history hides the icon without clearing the preference.
- **Automatically copy screenshots**: With Clipboard history on, ⌘⇧3 (full screen) and ⌘⇧4 (selection/window)
  copy the image to the clipboard and save it in history under `~/Documents/NirTab/Clipboard/`. Screenshots taken this
  way are not also saved on the Desktop. Turn this off in Experimental Features or Settings to restore macOS's normal
  file-saving shortcuts. ⌃⌘⇧3/4 still use macOS's built-in clipboard shortcut.
- **Pomodoro**: a second menu-bar icon shows the countdown. Start/pause/reset focus sessions or start a break from its
  menu. A coffee popup appears when focus ends and the break timer starts. Configure focus/break minutes in Settings.
- **Keep Mac awake**: turn on the separate cup from Experimental Features. Click the cup to start/stop preventing sleep;
  right-click for independent display/idle/disk/system choices and an optional 15-minute–8-hour or custom auto-off timer.
  The cup can return at login, but sleep prevention does not resume until you click it. Inspired by Caffeinate (MIT).

**Capture Area / Window / Record…** opens macOS's built-in Screenshot toolbar; its recording files and save location
follow macOS settings and do not enter NirTab's clipboard history automatically.

**Battery Health (coconutBattery-style)…** opens a built-in popup with current charge, battery health (full charge
capacity / design capacity), capacities in mAh, cycle count, temperature, voltage and adapter wattage. It refreshes
every 10 seconds while open; **Refresh** updates immediately. Missing sensors show **Unavailable**, and desktops
without a battery show an empty state. Also opens via `open -g 'nirtab://battery'`.
This is an independent Mac battery monitor inspired by coconutBattery, not the proprietary app embedded or bundled.
iPhone/iPad monitoring, battery history and coconutBattery's other features are not included.

**Install DisplayLink Manager…** opens Synaptics' official macOS downloads page. Choose the installer there and follow
its setup instructions; NirTab does not silently install drivers or change Screen Recording permissions.

**Capture & Annotate…** (menu bar, or `open -g 'nirtab://capture'`) captures the display under the pointer at full
resolution. Draw arrows/rectangles, place text, undo/reset, then copy a PNG (also added to clipboard history if enabled)
or save it; **Copy Text** uses macOS Vision OCR to copy recognized text. This is an independent implementation inspired
by Capso's workflow; **not a copy of Capso's BSL source**.
Capso's custom area/window/scroll capture tools, video/GIF editor, webcam, visual OCR selection, translation, cloud sharing, and full
annotation editor are not included.

**Tiles show:**
- a window preview, plus the last picture taken of minimized windows
- the app's memory, counting its helper processes the way Activity Monitor does (orange at 2 GB or more)
- badges for minimized, hidden, and no window

Order is most recently used. Minimized, hidden and windowless entries go last.

**Settings** (menu bar icon → Settings…):
- hold key: ⌘ / ⌥ / ⌃
- where minimized windows go
- show hidden apps, show apps with no window
- exclude apps by name
- previews on/off, memory on/off, tile size
- switcher style: default auto-fit grid, compact list, or custom grid (1–8 windows per row; limited by display width)
- switcher background: choose an image (stored as a resized local copy) or restore the default glass
- which screen the switcher opens on
- window movement shortcuts, five custom key bindings, and per-action layout shortcuts
- launch at login

## Updates
Menu bar → **Check for Updates…** downloads the latest release, replaces the app and restarts it. You don't have to
grant Accessibility or Screen Recording again. macOS ties those grants to the app's bundle id, signing certificate
and path, and every release keeps all three the same.

## Build from source
```bash
./build.sh            # build, install to /Applications, restart
./build.sh --release  # universal build + NirTab-<version>.zip (what CI runs)
/Applications/NirTab.app/Contents/MacOS/NirTab --list     # what the switcher would show, with memory and previews
swift re/e2e.swift    # live check: minimize → listed with preview → restored through the real switcher
/Applications/NirTab.app/Contents/MacOS/NirTab --test-layout  # layout geometry checks
/Applications/NirTab.app/Contents/MacOS/NirTab --test-rectangle-ui # all layout menu actions and Settings
/Applications/NirTab.app/Contents/MacOS/NirTab --test-recorder # shortcut recorder check
/Applications/NirTab.app/Contents/MacOS/NirTab --test-background # image import/resize check
/Applications/NirTab.app/Contents/MacOS/NirTab --test-extras # clipboard and timer checks
/Applications/NirTab.app/Contents/MacOS/NirTab --test-caffeinate # in-memory sleep assertion/menu checks
/Applications/NirTab.app/Contents/MacOS/NirTab --test-battery # battery parsing, popup and refresh lifecycle
/Applications/NirTab.app/Contents/MacOS/NirTab --test-capture # image annotation and OCR checks
/Applications/NirTab.app/Contents/MacOS/NirTab -layout list --test-styles # live layout and scroll check
swift re/move-e2e.swift  # live check: all four halves and both display directions
swift re/move-e2e.swift --rectangle --rectangle-url # live layout shortcuts and URL action
```
A local build has **Update (rebuild from source)** in its menu instead of Check for Updates.

## Releasing
Push a tag, or run the **Release** workflow by hand with a version number:
```bash
git tag v0.17 && git push origin v0.17
```
`.github/workflows/release.yml` then builds a universal app on a macOS runner, signs it, smoke-tests it and publishes
`NirTab-0.17.zip` as a GitHub release. Installed copies pick it up via Check for Updates.

### Signing
All releases must be signed with the same certificate, otherwise every user would have to grant permissions again
after updating. The project uses a self-signed code-signing certificate named `NirTab Signing`. CI reads it from two
repository secrets:
- `SIGNING_CERT_P12`: the `.p12` file, base64-encoded
- `SIGNING_CERT_PASSWORD`: its password

Keep a backup of the `.p12` file. If it's lost, the next release forces every user to re-grant permissions once.

To create a certificate (for a fork), and to sign local builds with it:
```bash
openssl req -x509 -newkey rsa:2048 -keyout k.pem -out cert.pem -days 7300 -nodes -subj "/CN=NirTab Signing" \
  -addext "keyUsage=critical,digitalSignature" -addext "extendedKeyUsage=critical,codeSigning"
openssl pkcs12 -export -inkey k.pem -in cert.pem -out nirtab.p12 -name "NirTab Signing" && rm k.pem
security import nirtab.p12 -T /usr/bin/codesign                 # local builds
base64 -i nirtab.p12 | gh secret set SIGNING_CERT_P12           # CI
gh secret set SIGNING_CERT_PASSWORD
```

## How it works
- **Window list:** each app's Accessibility tree (`kAXWindowsAttribute`), ordered by the window server's z-order
  (`CGWindowListCopyWindowInfo`).
- **Window ids:** `_AXUIElementGetWindow`. This is the one private call NirTab makes. It has been stable for over 10
  years, and most window managers rely on it.
- **Previews:** ScreenCaptureKit. macOS can't capture a minimized window (error -3811), so NirTab saves each window's
  picture while it's visible: on every app switch, every 20 s for the app in front, and right before minimizing it
  from the switcher. Pictures are kept in `~/Library/Caches/NirTab/thumbs/` so they survive restarts.
- **Memory:** `proc_pid_rusage` physical footprint for every process, added up per app with
  `responsibility_get_pid_responsible_for_pid`. That covers Chrome tabs, Electron renderers and XPC helpers, and
  takes about 15 ms. macOS has no per-window memory figure.
- **Keys:** a `CGEventTap` catches ⌘Tab before the system switcher does; a two-second check restores a disabled tap or retries a failed one.

### Limits
- **Current Space only.** Windows on other desktops need private SkyLight calls that break between macOS releases.
- No search-as-you-type yet.

## Credits
Inspired by [AltTab](https://github.com/lwouis/alt-tab-macos) (GPL-3.0). NirTab is an independent reimplementation
and contains no AltTab code or artwork.
Window-layout actions are independently implemented based on the behavior documented by
[Rectangle](https://github.com/rxhanson/Rectangle) (MIT); no Rectangle source or artwork is included.

## License
[MIT](LICENSE)
