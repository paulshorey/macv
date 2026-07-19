# MacV

Local macOS clipboard manager: transform clipboard content with shell scripts (Python/Node/CLI) before paste.

## Requirements

- macOS 14+ (built and tested against macOS 26 / Xcode 26)
- Apple Silicon
- Xcode 16+
- Optional: [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) if regenerating the project

## Build & run

```bash
cd /Users/pshorey/git/macv
xcodegen generate          # only needed after editing project.yml
open MacV.xcodeproj
```

### Signing (required for stable permissions)

MacV is currently easy to build **ad-hoc**, but macOS TCC pins Input Monitoring / Accessibility to the binary’s code signature. Ad-hoc signatures change every rebuild, so System Settings can show “allowed” while the live check still fails.

1. Xcode → **Settings → Accounts** → add your Apple ID (free is fine)
2. Select the **MacV** target → **Signing & Capabilities**
3. Enable **Automatically manage signing** and choose your **Team**
4. Quit MacV completely, then **Product → Run**

After that, grant permissions once; they should survive rebuilds.

### Reload after code changes

1. Quit MacV from the menu bar (**Quit**) or stop in Xcode (**⌘.**)
2. **Product → Run** (**⌘R**) — rebuilds and launches
3. If you changed permissions in System Settings: Quit MacV fully, then Run again (TCC is applied at process start)

Optional cleanup if permissions are stuck after switching from ad-hoc → Team signing:

```bash
tccutil reset ListenEvent com.macv.app
tccutil reset Accessibility com.macv.app
```

Then Run from Xcode and re-grant in System Settings.
## First-run setup

1. Open **Settings → Permissions** and grant:
   - **Input Monitoring** (key suppression via CGEventTap)
   - **Accessibility** (synthesize Cmd+V / Cmd+C)
   - **Paste from Other Apps** → Allow (when prompted / available)
2. **Settings → Scripts**: starter scripts are copied to  
   `~/Library/Application Support/macv/scripts/`
3. **Settings → Shortcuts**: add a binding, pick a script, choose event mode (Paste / Copy / Cut / None), record a chord.

## Script contract

| Channel | Meaning |
| --- | --- |
| stdin | Active clipboard plain text (UTF-8) |
| stdout | Transformed plain text |
| stderr | Error detail (shown in Settings) |
| exit 0 | Success |
| exit ≠ 0 | Failure — no paste / no overwrite |

Environment: `MACV_SCRIPT_ID`, `MACV_EVENT`, `MACV_SNAPSHOT_ID`, `MACV_SOURCE_APP`, `MACV_SUPPORT_DIR`, plus a PATH that includes Homebrew.

Scripts may call `python3`, `node`, `jq`, etc. Examples ship as `plain-text-only.sh`, `json-pretty.sh`, `html-strip.sh`, `uppercase.js`.

## Event modes

- **Paste** — suppress chord, run script, paste plain text into the frontmost app, restore prior clipboard
- **Copy / Cut** — transform current clipboard, or intercept-then-transform (optional mode)
- **None** — update MacV history/active pointer only (no system pasteboard write)

## Project layout

```
MacV/                 Swift sources + Info.plist
MacV/Resources/Scripts/   Bundled starter scripts
project.yml           XcodeGen spec
.cursor/plans/        Design plan
```
