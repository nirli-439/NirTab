# NirTab

A Windows-style ⌘Tab window switcher for macOS: one Swift file, no dependencies.

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
- which screen the switcher opens on
- window movement shortcuts and five custom key bindings
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
/Applications/NirTab.app/Contents/MacOS/NirTab --test-recorder # shortcut recorder check
swift re/move-e2e.swift  # live check: all four halves and both display directions
```
A local build has **Update (rebuild from source)** in its menu instead of Check for Updates.

## Releasing
Push a tag, or run the **Release** workflow by hand with a version number:
```bash
git tag v0.10 && git push origin v0.10
```
`.github/workflows/release.yml` then builds a universal app on a macOS runner, signs it, smoke-tests it and publishes
`NirTab-0.10.zip` as a GitHub release. Installed copies pick it up via Check for Updates.

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
- **Keys:** a `CGEventTap` catches ⌘Tab before the system switcher does.

### Limits
- **Current Space only.** Windows on other desktops need private SkyLight calls that break between macOS releases.
- No search-as-you-type yet.

## Credits
Inspired by [AltTab](https://github.com/lwouis/alt-tab-macos) (GPL-3.0). NirTab is an independent reimplementation
and contains no AltTab code or artwork.

## License
[MIT](LICENSE)
