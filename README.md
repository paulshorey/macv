# MacV

Local macOS clipboard manager for power users: transform clipboard content with **shell scripts** (Python, Node, or any CLI) on a global shortcut — especially **plain-text paste** that works even when apps ignore Shift-Cmd-V.

- Menu bar agent (no Dock icon)
- Runs entirely on your Mac (no cloud, no App Store build)
- Owner-operated; grant permissions once with a stable Development signing identity

For codebase/architecture notes aimed at engineers and AI agents, see [AGENTS.md](AGENTS.md).

---

## Requirements

| Item | Notes |
| --- | --- |
| macOS | 14+ (developed on macOS 26 / Tahoe) |
| Hardware | Apple Silicon (`arm64`) |
| Xcode | 16+ (26.x is fine) |
| Apple ID | Free account is enough for local **Apple Development** signing |
| Optional tools | `python3`, `node`, Homebrew CLIs — only if your scripts call them |
| Optional | [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) to regenerate the project from `project.yml` |

You do **not** need:
- Apple Developer Program paid membership (for local use)
- iPhone/iPad provisioning / “On Device Testing” (Mac app only)
- App Store Connect

---

## Accounts & signing (maintain this)

macOS ties **Input Monitoring** and **Accessibility** to the app’s **code signature**. Ad-hoc unsigned/ad-hoc builds get a new identity almost every rebuild, so System Settings can show MacV as allowed while the app still reports “not granted.”

### One-time setup

1. **Xcode → Settings → Accounts** → add your Apple ID.
2. Select the account → **Manage Certificates…** → **+** → **Apple Development**  
   (Creates a cert **and** private key on this Mac. A cert without a private key is useless — `security find-identity -p codesigning -v` should list a **valid** identity.)
3. Open the project, select the **MacV** target → **Signing & Capabilities**:
   - Enable **Automatically manage signing**
   - **Team** = your Personal Team / name  
   - Ignore any iOS “provisioned devices” messaging — it does not apply to this Mac target.
4. Bundle ID should remain `com.macv.app`.

### After switching from ad-hoc → Team signing

Quit MacV, then reset stale TCC grants if checks still fail:

```bash
tccutil reset ListenEvent com.macv.app
tccutil reset Accessibility com.macv.app
```

Run from Xcode again and re-grant permissions once.

---

## Open, build, run

```bash
cd /path/to/macv
xcodegen generate    # only if you changed project.yml
open MacV.xcodeproj
```

In Xcode: scheme **MacV** → **Product → Run** (**⌘R**).

The app appears in the **menu bar** (clipboard icon), not the Dock.

### CLI build (optional)

```bash
xcodebuild -project MacV.xcodeproj -scheme MacV \
  -configuration Debug -destination 'platform=macOS,arch=arm64' build
```

Prefer running via Xcode so signing and the debugger attach correctly.

---

## Start / stop / restart

| Action | How |
| --- | --- |
| **Start** | Xcode **⌘R**, or launch `MacV.app` from DerivedData / an installed copy |
| **Stop** | Menu bar → **Quit**, or Xcode **⌘.** (Stop) |
| **Restart after code changes** | Quit or Stop → **⌘R** |
| **Restart after permission toggles** | Fully Quit MacV → **⌘R** (TCC applies at process start; Refresh alone is not enough) |
| **Launch at login** | MacV **Settings → General → Launch at login** |

Do not leave an old MacV running, rebuild, and assume the new binary is what has focus — Quit first.

---

## First-run checklist

1. **Settings → Permissions**
   - **Input Monitoring** — suppress global hotkeys (CGEventTap)
   - **Accessibility** — synthesize Cmd+V / Cmd+C
   - **Paste from Other Apps** — Allow when the OS offers it (clipboard history polling)
2. Confirm the Permissions tab does **not** warn about ad-hoc signing.
3. **Settings → Scripts** — starters are copied to  
   `~/Library/Application Support/macv/scripts/` (existing files are never overwritten).
4. **Settings → Shortcuts** — Add a binding:
   - Script (e.g. `plain-text-only`)
   - Event (**Paste** for transform-before-paste)
   - Record a chord (prefer something that won’t fight system shortcuts until suppression works)
5. Copy rich text → trigger shortcut → paste into TextEdit / Safari / an Electron app.

---

## Using transforms

### Event modes

| Mode | What happens |
| --- | --- |
| **Paste** | Shortcut is swallowed → script runs → plain text pasted into the frontmost app → previous clipboard restored |
| **Copy / Cut** | Transform current clipboard, or “intercept then transform” if you enable that mode |
| **None** | Updates MacV history / active item only — does **not** change the system clipboard |

### Script contract

| Channel | Meaning |
| --- | --- |
| **stdin** | Current clipboard plain text (UTF-8) |
| **stdout** | Transformed plain text (this becomes the result) |
| **stderr** | Errors (shown under Settings → Scripts) |
| **exit 0** | Success |
| **exit ≠ 0** | Failure — no paste / no clipboard overwrite |

Environment variables: `MACV_SCRIPT_ID`, `MACV_EVENT`, `MACV_SNAPSHOT_ID`, `MACV_SOURCE_APP`, `MACV_SUPPORT_DIR`, plus a PATH that includes `/opt/homebrew/bin`.

Edit scripts in:

```text
~/Library/Application Support/macv/scripts/
```

Use **Settings → Scripts → Reveal Scripts Folder**. Make them executable (`chmod +x`). Shebang scripts (`.py`, `.js`) and `.sh` wrappers that call `python3` / `node` are both supported.

Shell scripts are run with **`zsh -f`** so your interactive `~/.zshenv` / `.shortcuts.sh` banners do **not** end up in the clipboard.

### Shipped examples

| Script | Purpose |
| --- | --- |
| `plain-text-only.sh` | Pass-through plain text (use with Paste to strip rich formats) |
| `json-pretty.sh` / `.py` | Pretty-print JSON |
| `html-strip.sh` | Strip HTML tags via Python |
| `uppercase.js` | Node demo |

---

## Data & files

```text
~/Library/Application Support/macv/
  history.sqlite     # clipboard history
  bindings.json      # shortcut bindings
  scripts/           # your transforms
  blobs/             # large clipboard payloads
```

**Clear history:** Settings → General → Clear clipboard history.

---

## Debug & troubleshoot

### Permissions show Allowed in System Settings but warning in MacV

Usually **ad-hoc signing** or a **stale TCC grant** after rebuild.

1. Ensure Team signing + valid Apple Development identity (see above).
2. Quit MacV.
3. `tccutil reset ListenEvent com.macv.app` and `tccutil reset Accessibility com.macv.app`
4. Run from Xcode, re-grant, Quit, Run again.
5. Click **Refresh all** on the Permissions tab — live checks use `CGPreflight*`, not the Settings UI label alone.

### Shortcut does nothing

- Binding recorded? Script selected?
- For **Paste**, **Suppress key** should be on; Input Monitoring must pass the live check.
- Secure Input (password fields) can disable event taps temporarily.
- Check Settings → Scripts for **Last script error**.

### Paste includes shell banners / `LOADING CUSTOM` text

Old builds inherited user zsh startup. Current `ScriptRunner` uses `zsh -f`. Rebuild/relaunch MacV. Do not print diagnostics to stdout in your scripts — use stderr.

### Script can’t find `node` / `python3`

GUI apps get a short PATH. MacV prepends Homebrew paths; confirm binaries exist:

```bash
which python3 node
ls /opt/homebrew/bin/python3 /opt/homebrew/bin/node
```

### History not updating

- Pasteboard Privacy deny/ask (Permissions tab).
- Content marked concealed (password managers) is skipped on purpose.
- Internal/transient writes (MacV’s own paste injection) are skipped on purpose.

### Event tap died after sleep

MacV tries to re-enable on wake. If hotkeys die: Quit → Run. Check Input Monitoring still granted for **this** signed build.

### Xcode “0 provisioned devices”

Irrelevant for Mac. You are not provisioning an iPhone. Focus on **MacV target → Signing → Team** and **Manage Certificates → Apple Development**.

### Useful checks

```bash
# Valid signing identity present?
security find-identity -v -p codesigning

# How is the built app signed?
codesign -dv --verbose=2 /path/to/MacV.app
# Prefer TeamIdentifier=… set; avoid Signature=adhoc

# Reset TCC for this bundle
tccutil reset ListenEvent com.macv.app
tccutil reset Accessibility com.macv.app
```

Console.app / Xcode debugger: filter for `MacV` / `transform error`.

---

## Project layout

```text
MacV/                     App sources, Info.plist, entitlements
MacV/Resources/Scripts/   Bundled starter scripts (templates)
MacV.xcodeproj/           Generated Xcode project
project.yml               XcodeGen spec — edit this, then xcodegen generate
AGENTS.md                 Architecture guide for agents/engineers
.cursor/plans/            Design plan
```

---

## Security model (admin)

- App runs as **your user**, not root.
- Scripts under Application Support run with **your privileges** (same as Terminal). Treat them as trusted code you wrote.
- No sandbox; the app can synthesize keys and read the pasteboard by design.
- Keep the machine’s TCC grants limited to this bundle ID; reset with `tccutil` if you retire the app.
