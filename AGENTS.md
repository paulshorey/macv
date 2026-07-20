# MacV — Agent / Engineer Guide

MacV is a **local, unsandboxed macOS menu-bar clipboard manager**. It watches the pasteboard, keeps an immutable history, and runs **user shell scripts** (which may call Python, Node, or any CLI) when the user hits a custom global shortcut — typically to transform content *before* paste so apps that ignore Shift-Cmd-V still receive plain text.

This file is for AI agents and engineers working in the repo. For human setup/ops, see [README.md](README.md). Design rationale lives in [`.cursor/plans/new-clipboard-app.md`](.cursor/plans/new-clipboard-app.md).

---

## Product constraints (do not violate)

| Constraint | Implication |
| --- | --- |
| Owner-operated, single machine | No multi-user, no sync, no accounts |
| Not App Store | **No App Sandbox.** Entitlements stay empty of sandbox keys |
| Fully local | No network client code, no telemetry, no cloud APIs |
| Transforms = scripts | Do **not** reintroduce hardcoded Swift-only transforms as the primary path; keep the `Transformation` protocol for tests/fixtures, but user-facing logic is scripts under Application Support |
| Runs as the logged-in user | Never require root. Admin is only for TCC toggles |

---

## Architecture map

```
Hotkey (KeyboardShortcuts and/or CGEventTap)
        │
        ▼
TransformationDispatcher ──► ScriptRegistry / ScriptRunner
        │                              │
        │                              ▼
        │                     shell/python/node (stdin→stdout)
        ▼
HistoryStore (SQLite via GRDB) + PasteSynthesizer (NSPasteboard + Cmd+V)
        ▲
ClipboardMonitor (poll changeCount)
```

| Piece | File(s) | Role |
| --- | --- | --- |
| App entry / menu bar | `MacVApp.swift`, `StatusItemController.swift` | `NSStatusItem` + nonactivating panel; Settings scene; `LSUIElement` |
| Composition root | `MacV/AppState.swift` | Wires stores, monitor, dispatcher, interceptor; start lifecycle |
| Models | `MacV/Models/Models.swift` | Snapshots, bindings, events, pasteboard markers |
| History | `HistoryStore.swift`, `HistoryPersistence.swift` | Append-only SQLite + active pointer |
| Monitor | `ClipboardMonitor.swift` | Poll `changeCount`; skip internal/transient/concealed |
| Scripts | `ScriptRunner.swift`, `ScriptRegistry.swift` | Clean env execution; install starters |
| Hotkeys | `BindingStore.swift`, `HotkeyInterceptor.swift` | Carbon shortcuts + CGEventTap swallow |
| Paste | `PasteSynthesizer.swift` | Write markers, synthesize keys, restore-after-paste |
| Dispatch | `TransformationDispatcher.swift` | paste / copy / cut / none branching |
| Permissions | `PermissionsManager.swift` | TCC preflight + ad-hoc signing detection |
| UI | `Views/HistoryBrowserView.swift`, `Views/SettingsView.swift` | History, shortcuts, scripts, permissions |
| Paths | `AppPaths.swift` | `~/Library/Application Support/macv/` |
| Project gen | `project.yml` | XcodeGen source of truth for the Xcode project |

**Dependencies (SPM):** [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts), [GRDB](https://github.com/groue/GRDB.swift).

---

## Where to edit what

| Goal | Edit |
| --- | --- |
| New event mode / paste semantics | `TransformationDispatcher.swift`, maybe `PasteSynthesizer.swift` |
| Script I/O contract / PATH / rc pollution | `ScriptRunner.swift` |
| Starter scripts shipped with the app | `MacV/Resources/Scripts/*` **and** `EmbeddedStarters` in `ScriptRegistry.swift` **and** `project.yml` resource list |
| History schema | `HistoryPersistence` migrator (`v1`, add `v2`…) |
| Binding model fields | `ShortcutBinding` in `Models.swift` + Settings UI |
| Suppression / tap lifecycle | `HotkeyInterceptor.swift` — **never** run scripts inside the tap callback |
| Permissions UX | `PermissionsManager.swift`, Permissions tab in `SettingsView.swift` |
| Bundle ID / signing / deployment | `project.yml` then `xcodegen generate` |
| Info.plist agent behavior | `MacV/Info.plist` (`LSUIElement`) |

After changing `project.yml`, regenerate: `xcodegen generate`.

---

## Critical quirks (read before changing behavior)

### 1. CGEventTap must return immediately
If the tap callback blocks (script I/O, sleeps, locks), macOS **silently disables** the tap (`tapDisabledByTimeout`). Pattern: match → `DispatchQueue.main.async` dispatch → return `nil` to swallow. Always handle re-enable on timeout / wake.

### 2. Two hotkey mechanisms
- **KeyboardShortcuts** (Carbon): record/persist chords; fire non-suppressed bindings.
- **CGEventTap**: required when `requiresSuppression == true` (default for `.paste`) so the frontmost app never also sees the key.

Suppressed bindings register an empty Carbon handler to avoid double-fire; the tap owns dispatch.

### 3. Script stdout is clipboard content
Anything a shell prints to stdout becomes the transform result. User `~/.zshenv` banners used to pollute paste. **Shell scripts are launched with `zsh -f`** (no user RCS) and a curated env + empty `ZDOTDIR`. Do not “fix” this by inheriting the full login environment.

### 4. Self-write feedback loops
Programmatic pasteboard writes must include `com.macv.internal-write` (and often Transient / AutoGenerated). `ClipboardMonitor` skips those. Restore-after-paste also re-tags restored items.

### 5. Paste path restores the previous clipboard
Default `.paste`: save → write plain text (Transient) → Cmd+V → restore if `changeCount` unchanged. History still records the transformed snapshot.

### 6. `.none` does not touch `NSPasteboard.general`
Only history + active pointer. Organic Cmd+V in other apps keeps the old system clipboard until Promote or a write path.

### 7. TCC ↔ code signing
Permissions are pinned to code identity. **Ad-hoc builds break grants every rebuild** (Settings may show Allowed while `CGPreflight*` is false). Prefer Apple Development Team signing. Bundle ID: `com.macv.app`.

### 8. Cut vs copy on organic polls
Pasteboard does not reliably distinguish cut from copy. Organic monitor entries use `.organicCopy`. `.organicCut` is for our intercept path only.

### 9. GUI `$PATH` is minimal
`ScriptRunner` injects Homebrew + system paths. Scripts that assume a full interactive shell PATH will fail without that curation.

### 10. Starter scripts are copied once
First launch copies into `~/Library/Application Support/macv/scripts/` if missing — **never overwrites** user edits. Bundled + `EmbeddedStarters` fallback both exist.

### 11. Unsandboxed by design
`MacV.entitlements` has no App Sandbox. Paste synthesis / event taps need that. Do not add sandbox entitlements “for safety” without a full redesign.

### 12. AppKit agent entry (not SwiftUI `App`)
Use `@main enum MacVMain` + `NSApplication.run()` (`MacVApp.swift`). A SwiftUI `App` with only `Settings` / `MenuBarExtra` can **quit when scenes invalidate** on Tahoe — that looks like die/relaunch every few seconds, often with `FBSceneErrorDomain` / `NSStatusItemView` console noise.

Status UI: `StatusItemController` uses `NSStatusItem` + **`NSMenu`** + independent history/settings windows. Do **not** attach `NSPopover` or `MenuBarExtra(.window)` to the status button (those create `…-Aux[1]-NSStatusItemView` scenes). Always return `false` from `applicationShouldTerminateAfterLastWindowClosed`. Own `AppState` on `AppDelegate`.

---

## Script contract (agents implementing transforms)

| Channel | Meaning |
| --- | --- |
| stdin | Preferred plain text of active snapshot |
| stdout | New plain text (`public.utf8-plain-text`) |
| stderr | Logged / shown as last error — not pasted |
| exit 0 | Success (stdout may be empty) |
| exit ≠ 0 or timeout | Abort; no paste / no overwrite |

Env always set: `MACV_SCRIPT_ID`, `MACV_EVENT`, `MACV_SNAPSHOT_ID`, `MACV_SOURCE_APP`, `MACV_PLAINTEXT_UTI`, `MACV_SUPPORT_DIR`.

User scripts live in Application Support; repo copies under `MacV/Resources/Scripts/` are templates only.

---

## Event modes (dispatcher)

| `ClipboardEvent` | Behavior |
| --- | --- |
| `paste` | Swallow key → script → history → write+Cmd+V → restore clipboard |
| `copy` / `cut` | `transformCurrentClipboard` (default) or `interceptThenTransform` |
| `none` | Script → history/active only |

---

## Data locations

```
~/Library/Application Support/macv/
  history.sqlite
  bindings.json
  scripts/          # user-editable transforms
  blobs/            # large representation payloads
  .empty-zdotdir/   # prevents zshenv pollution
```

---

## Testing expectations

- Prefer unit-testing pure snapshot/transform helpers with fixtures; process spawns need timeouts and clean env.
- Manual smoke: TextEdit + one Electron app (VS Code/Slack) for paste suppression.
- After permission changes: full process restart required.
- Do not add App Store / sandbox test matrices.

---

## Out of scope (v1)

Mac App Store, cloud sync, multi-rep script manifests (images/HTML round-trip), root helpers, competing with Tahoe Spotlight clipboard history, guaranteed organic cut detection.
