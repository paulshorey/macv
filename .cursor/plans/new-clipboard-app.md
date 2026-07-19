## Overview and Architecture Summary

This plan covers building a native macOS clipboard manager for Apple Silicon (ARM64) targeting macOS 26 (Tahoe), with user-defined global keyboard shortcuts mapped to **local shell scripts** (which may invoke Python, Node, or any other CLI on `$PATH`), an immutable clipboard history model, and event-aware processing (pre-paste interception vs. post-copy/cut transformation vs. silent history-only mutation).

**Product constraints (authoritative):**
- Single-machine, owner-operated utility. The operator has admin privileges to grant TCC permissions; the app itself runs as the logged-in user (not as root).
- Not App Store distributed. No sandbox. No MAS entitlements work.
- Fully local. No external APIs, sync, telemetry, or cloud services.
- Transformations are **user-authored shell scripts** with full terminal powers, not hardcoded Swift functions. Built-in example scripts may ship as starter templates.

The system decomposes into six subsystems: (1) global hotkey registration + event suppression, (2) pasteboard monitoring/history, (3) script-based transformation runner, (4) event dispatcher (paste/copy/cut/none), (5) history promotion, (6) SwiftUI/AppKit UI. Because the app must intercept keyboard events and synthesize paste into arbitrary foreground apps, it cannot be sandboxed.

---

## Target Platform Requirements

### Apple Silicon

Primary target: native `arm64`. Intel/universal is optional and not required for v1.

In Xcode: set `Architectures` to `arm64` for Apple Silicon-only, or `$(ARCHS_STANDARD)` if a fat binary is desired later. Verify with `lipo -info YourApp.app/Contents/MacOS/YourApp`. Delete any leftover deprecated `VALID_ARCHS` user-defined setting if "My Mac" destinations misbehave.

### macOS 26 (Tahoe)

Deployment target: `macOS 26.0` is fine for a personal Tahoe-only machine; use a lower floor (e.g. 14.0) only if you later want older Macs. Prefer `#available` guards for APIs introduced after the deployment floor.

**Tahoe-relevant facts to plan against:**
- Tahoe includes a built-in Spotlight clipboard history (off by default). Our app is still valuable because Spotlight history lacks transform-on-paste, scriptable transforms, and reliable plain-text paste into apps that ignore Shift-Cmd-V.
- Pasteboard Privacy ("Paste from Other Apps") APIs exist (`NSPasteboard.accessBehavior`, `detectedPatterns(for:)`) and a System Settings pane exists, but enforcement is **not on by default** in Tahoe mid-2026 unless enabled via developer preview defaults. Still: adopt `accessBehavior` checks and a first-run onboarding deep-link to `x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Pasteboard` so we survive when Apple flips the switch.
- No known breakage of `NSPasteboard`, `CGEventTap`, or Accessibility posting APIs that would invalidate the model below.

---

## Trust and Privilege Model

| Layer | Policy |
| --- | --- |
| Process identity | Runs as the logged-in GUI user via a normal `.app` / LaunchAgent. **Do not run as root.** Admin is only needed to approve TCC toggles. |
| Script trust | Scripts are local files the owner writes. Treat them as fully trusted code executing with the user's privileges (same as Terminal). |
| Network | App does not initiate network I/O. Scripts may (user choice); document that risk. |
| Signing | Prefer ad-hoc or Apple Development signing for local builds. Developer ID + notarization is optional nicety, not required for owner-only use — Gatekeeper can be overridden per-app by an admin. Skip App Store packaging entirely. |

---

## Subsystem 1: Global Hotkey Registration and Event Suppression

### Two mechanisms, two jobs

| Job | Mechanism | Why |
| --- | --- | --- |
| Record + persist user-chosen chords; fire for non-intercepting bindings | `KeyboardShortcuts` (Carbon `RegisterEventHotKey`) | Fast UI (`Recorder`), persistence, no permission for basic hotkeys |
| **Suppress** a chord so the frontmost app never sees it (required for `.paste` when binding Cmd+V or any chord that must not double-fire) | Own `CGEventTap` at `.cgSessionEventTap` / `.headInsertEventTap`, return `nil` to swallow | Carbon hotkeys do **not** reliably prevent the frontmost app from also handling the key; Electron/Zed-style hosts are especially hostile |

**v1 recommendation:** Use `KeyboardShortcuts` for the Settings recorder and for bindings that do **not** need suppression (typical `.none` / distinct post-process chords). Use a dedicated `CGEventTap` interceptor for any binding whose `event == .paste` **or** whose chord collides with a system shortcut the target app must not receive. Optionally unify later onto CGEventTap-only if Carbon edge cases dominate.

Add via SPM: `https://github.com/sindresorhus/KeyboardShortcuts` (macOS 10.15+).

Dynamic names from persisted UUIDs:

```swift
import KeyboardShortcuts

struct ShortcutBinding: Codable, Identifiable {
    let id: UUID
    var scriptID: String              // key into ScriptRegistry (filename / relative path)
    var event: ClipboardEvent         // .paste, .copy, .cut, .none
    var requiresSuppression: Bool     // true when CGEventTap must swallow the chord
}

func dynamicShortcutName(for binding: ShortcutBinding) -> KeyboardShortcuts.Name {
    .init("binding_\(binding.id.uuidString)")
}
```

### CGEventTap interceptor (suppression path)

```swift
import CoreGraphics

final class HotkeyInterceptor {
    var eventTap: CFMachPort?

    func start() {
        let mask = (1 << CGEventType.keyDown.rawValue)
                 | (1 << CGEventType.keyUp.rawValue) // match both if suppressing
        let callback: CGEventTapCallBack = { proxy, type, event, refcon in
            // CRITICAL: re-enable if macOS disabled the tap
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = Unmanaged<HotkeyInterceptor>.fromOpaque(refcon!).takeUnretainedValue().eventTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
                return nil
            }
            let interceptor = Unmanaged<HotkeyInterceptor>.fromOpaque(refcon!).takeUnretainedValue()
            if interceptor.matchesRegisteredBinding(event) {
                // MUST return immediately — never run scripts here
                interceptor.enqueueDispatch(event) // async to main/background queue
                return nil // swallow
            }
            return Unmanaged.passRetained(event)
        }
        // ... tapCreate + CFRunLoopAddSource as usual ...
    }
}
```

**Hard gotcha — tap timeout:** If the CGEventTap callback blocks (I/O, script execution, sleeps, waiting on locks), macOS silently disables the tap (`tapDisabledByTimeout`). Always: match → enqueue work → return. Handle `tapDisabledByTimeout` / `tapDisabledByUserInput` by re-enabling. Also re-check/recreate the tap on `NSWorkspace.didWakeNotification` and session active notifications.

### Permissions for this subsystem

| Capability | TCC surface | Check / request API |
| --- | --- | --- |
| Listen / filter keys via CGEventTap | **Input Monitoring** | `CGPreflightListenEventAccess()` / `CGRequestListenEventAccess()` |
| Post synthetic Cmd+V / Cmd+C | Shows under **Accessibility** (internally PostEvent) | `CGPreflightPostEventAccess()` / `CGRequestPostEventAccess()`; also `AXIsProcessTrustedWithOptions` if using AX APIs |
| Carbon `RegisterEventHotKey` only | None | — |

Onboarding UI must open the correct System Settings panes and re-check after the user returns. Do not conflate Input Monitoring with Accessibility in docs or prompts.

---

## Subsystem 2: Pasteboard Monitoring and Immutable History

### Polling model

macOS still has no pasteboard-change notification. Poll `NSPasteboard.general.changeCount` on a timer (0.3–0.5s). Integer compare is cheap.

```swift
@Observable
final class ClipboardMonitor {
    private var lastChangeCount: Int = NSPasteboard.general.changeCount
    private var timer: Timer?
    var onNewClipboardContent: ((ClipboardSnapshot) -> Void)?

    func start() {
        // Ensure timer fires during menu tracking / modal loops
        timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            self?.checkForChanges()
        }
        RunLoop.current.add(timer!, forMode: .common)
    }

    private func checkForChanges() {
        let current = NSPasteboard.general.changeCount
        guard current != lastChangeCount else { return }
        lastChangeCount = current
        let snapshot = ClipboardSnapshot.capture(from: .general)
        onNewClipboardContent?(snapshot)
    }
}
```

**Self-write suppression:** Tag every programmatic write with a private UTI (e.g. `com.macv.internal-write`) and/or community markers:
- `org.nspasteboard.TransientType` — content will be restored/replaced shortly; other managers should ignore
- `org.nspasteboard.AutoGeneratedType` — not a user Copy
- Skip persistence when `org.nspasteboard.ConcealedType` is present (password managers)

Monitor must ignore items carrying the internal-write marker (or Transient, depending on config) to avoid feedback loops.

### Data model: append-only snapshot chain

```swift
struct ClipboardSnapshot: Identifiable, Codable {
    let id: UUID
    let createdAt: Date
    let parentID: UUID?              // nil for organic copy/cut; set when derived
    let sourceApp: String?           // best-effort bundle ID
    let origin: Origin
    let representations: [PasteboardRepresentation]
}

struct PasteboardRepresentation: Codable {
    let uti: String
    let data: Data                   // or fileURL for large blobs
}

enum Origin: Codable {
    case organicCopy
    case organicCut
    case transformation(scriptID: String)
    case promotion
}
```

Persist with SQLite (`GRDB.swift` or SQLite3). Keep large binaries (images, RTF) as files under `Application Support` with path references in SQLite. Retention: max N entries and/or max age; prune in background.

**Source-app gotcha:** `NSWorkspace.shared.frontmostApplication` at poll time is often *your* app or the app the user switched to after copying. Prefer recording frontmost app on the *previous* poll tick, or maintain a short ring buffer of frontmost-app changes keyed by time and associate the nearest prior app when `changeCount` bumps. Perfect attribution is impossible without Accessibility introspection; treat `sourceApp` as best-effort.

**Cut vs copy:** The pasteboard does not reliably distinguish cut from copy. Do not invent organicCut vs organicCopy from pasteboard alone unless the event came from *our* synthesized Cmd+X path. For organic polls, use `.organicCopy` (or a neutral `.organic`) unless you later add Accessibility selection-clear heuristics (fragile — defer).

### Capturing representations

Iterate `pasteboardItems` × `types`, read raw `Data` per type (not just string):

```swift
extension ClipboardSnapshot {
    static func capture(from pasteboard: NSPasteboard, origin: Origin, parentID: UUID? = nil) -> ClipboardSnapshot {
        var reps: [PasteboardRepresentation] = []
        for item in pasteboard.pasteboardItems ?? [] {
            for type in item.types {
                if let data = item.data(forType: type) {
                    reps.append(PasteboardRepresentation(uti: type.rawValue, data: data))
                }
            }
        }
        return ClipboardSnapshot(
            id: UUID(), createdAt: Date(), parentID: parentID,
            sourceApp: /* best-effort */, origin: origin, representations: reps
        )
    }
}
```

### Pasteboard Privacy readiness

Before reading content in the monitor:

```swift
if #available(macOS 15.4, *) {
    switch NSPasteboard.general.accessBehavior {
    case .alwaysAllow: break
    case .ask, .deny:
        // Surface onboarding; deep-link to Pasteboard privacy pane
        // Do not spam read attempts while denied
    @unknown default: break
    }
}
```

Hotkey-triggered transforms (user-initiated) are less likely to trip privacy prompts than silent polling; still request **Allow** in System Settings during setup so history monitoring works.

---

## Subsystem 3: Script-Based Transformation Pipeline

### Design goal

A user-assigned keyboard shortcut runs a **shell script**. That script has a normal login-shell environment (or a documented subset) and may call `python3`, `node`, `jq`, `iconv`, etc. The Swift app does **not** embed a Python/Node runtime — it relies on tools already on the machine (`/usr/bin`, Homebrew `/opt/homebrew/bin`, etc.).

This fully satisfies: shortcut → shell → (optional) Python/Node → stdout back to the app.

### Script layout

```
~/Library/Application Support/macv/
  scripts/
    plain-text-only.sh
    json-pretty.py          # may be invoked from a .sh wrapper or directly via shebang
    html-strip.sh
  bin/                      # optional: helpers shipped with the app, prepended to PATH
```

Ship a few starter scripts in the app bundle; on first launch, copy them into `Application Support/scripts/` if missing (never overwrite user edits).

### Script I/O contract (v1 — text-first)

**v1 scope:** primary payload is UTF-8 text on stdin → UTF-8 text on stdout. Multi-representation / image transforms can wait for v2 (temp dir of files + JSON manifest).

| Channel | Meaning |
| --- | --- |
| stdin | Preferred plain-text representation of the active snapshot (`public.utf8-plain-text`, else `public.rtf`→string, else first string-like UTI) |
| stdout | Transformed plain text to become the new snapshot's string representation |
| stderr | Logged to app console / optional UI "last error" panel; not written to clipboard |
| exit 0 | Success — use stdout (even if empty) |
| exit ≠ 0 | Failure — keep prior active snapshot; show error; do not paste |

**Environment variables** (always set):

```
MACV_SCRIPT_ID=plain-text-only
MACV_EVENT=paste|copy|cut|none
MACV_SNAPSHOT_ID=<uuid>
MACV_SOURCE_APP=<bundle-id-or-empty>
MACV_PLAINTEXT_UTI=public.utf8-plain-text
MACV_SUPPORT_DIR=~/Library/Application Support/macv
PATH=<homebrew + /usr/bin + app-bundled bin + existing PATH>
```

Optional later: `MACV_REPS_DIR` pointing at a temp folder with one file per UTI.

### Example scripts

Shell that calls Python:

```bash
#!/bin/zsh
# scripts/json-pretty.sh
set -euo pipefail
python3 - <<'PY'
import json, sys
raw = sys.stdin.read()
try:
    obj = json.loads(raw)
except json.JSONDecodeError:
    sys.stderr.write("not JSON\n")
    sys.exit(1)
print(json.dumps(obj, indent=2, ensure_ascii=False))
PY
```

Or a shebang script registered directly:

```python
#!/usr/bin/env python3
# scripts/json-pretty.py
import json, sys
print(json.dumps(json.load(sys.stdin), indent=2, ensure_ascii=False))
```

Node equivalent works the same (`#!/usr/bin/env node`). The runner executes the file with `Process` / `/bin/zsh` — shebang or explicit shell both work.

### ScriptRunner (Swift)

Use Foundation `Process` (or Swift `Subprocess` package if preferred). Critical implementation rules:

1. **Never run from inside the CGEventTap callback** — always async off the tap.
2. Avoid the classic **64 KiB pipe deadlock**: write stdin and read stdout concurrently (readabilityHandler / async streams), or use a temp file for large payloads.
3. Enforce a **timeout** (e.g. 5s default, configurable). On timeout: `terminate()`, treat as failure.
4. Inherit a curated environment: user's `HOME`, expanded `PATH` including Homebrew, `LANG`/`LC_ALL` UTF-8.
5. Working directory: `MACV_SUPPORT_DIR` or the script's directory.
6. Mark scripts executable on install (`chmod +x`).

```swift
struct ScriptResult {
    let exitCode: Int32
    let stdout: Data
    let stderr: Data
    let timedOut: Bool
}

protocol Transformation {
    var id: String { get }
    var displayName: String { get }
    func apply(to snapshot: ClipboardSnapshot) async throws -> ClipboardSnapshot
}

/// Wraps a user script under Application Support/scripts/
struct ShellScriptTransformation: Transformation {
    let id: String
    let displayName: String
    let scriptURL: URL
    let runner: ScriptRunner

    func apply(to snapshot: ClipboardSnapshot) async throws -> ClipboardSnapshot {
        let input = snapshot.preferredPlainTextData()
        let result = try await runner.run(script: scriptURL, stdin: input, env: /* MACV_* */)
        guard result.exitCode == 0, !result.timedOut else {
            throw ScriptError.failed(stderr: String(data: result.stderr, encoding: .utf8) ?? "")
        }
        let rep = PasteboardRepresentation(
            uti: NSPasteboard.PasteboardType.string.rawValue,
            data: result.stdout
        )
        return ClipboardSnapshot(
            id: UUID(), createdAt: Date(), parentID: snapshot.id,
            sourceApp: snapshot.sourceApp,
            origin: .transformation(scriptID: id),
            representations: [rep]
        )
    }
}
```

### ScriptRegistry

Scan `scripts/` for `*.sh`, `*.py`, `*.js`, `*.mjs`, or a small `manifest.json` mapping `id` → path + display name. Settings UI picks from this registry. Reloading the list on window open is enough for v1 (no hot reload required).

**Builtin Swift transforms are optional.** Prefer shipping them as scripts so users can read/fork them. Keep the `Transformation` protocol so tests can inject fixtures without spawning processes.

---

## Subsystem 4: Event Dispatcher (Core Business Logic)

```swift
enum ClipboardEvent: String, Codable {
    case paste, cut, copy, none
}

final class TransformationDispatcher {
    let historyStore: HistoryStore
    let pasteSynthesizer: PasteSynthesizer
    let scriptRegistry: ScriptRegistry

    func handle(binding: ShortcutBinding) {
        Task { @MainActor in
            guard let transformation = scriptRegistry.find(binding.scriptID) else { return }
            switch binding.event {
            case .paste: await handlePasteEvent(transformation: transformation)
            case .copy, .cut: await handleCopyOrCutEvent(transformation: transformation, event: binding.event)
            case .none: await handleSilentTransform(transformation: transformation)
            }
        }
    }
}
```

### Resolved semantics (no longer open questions)

#### A. Copy/cut trigger semantics — **two explicit modes**

Store on `ShortcutBinding`:

```swift
enum CopyCutMode: String, Codable {
    /// Chord is distinct (e.g. Cmd+Shift+C). Transform whatever is already on the pasteboard.
    case transformCurrentClipboard
    /// Chord replaces/intercepts Cmd+C or Cmd+X: synthesize the real copy/cut, wait for changeCount, then transform + overwrite pasteboard.
    case interceptThenTransform
}
```

Default for new `.copy`/`.cut` bindings: `transformCurrentClipboard` (safer, no need to synthesize Cmd+C). Use `interceptThenTransform` only when the user intentionally binds Cmd+C/Cmd+X and enables suppression.

#### B. `.none` and pasteboard visibility — **history + active only; no system pasteboard write**

`.none` updates the app's active pointer and history. It does **not** write `NSPasteboard.general` and does **not** synthesize keys. Organic Cmd+V in other apps continues to see the previous system clipboard until the user **Promotes** or uses a `.paste` / `.copy` binding that writes. This matches "do not send any system event" and keeps "active in UI" distinct from "system clipboard."

#### C. Feedback-loop suppression — **required**

Always write private marker UTI (+ Transient when doing temporary paste injection). Monitor skips marked writes.

### `.paste` path: transform before the target app sees anything

1. Swallow the user's chord (CGEventTap) so the app never gets raw Cmd+V.
2. Run script on active snapshot (async).
3. Append transformed snapshot to history (`setActive` per product preference; default true).
4. **Save** current pasteboard → write transformed content (string UTI only is enough for the plain-text goal) tagged Transient + internal marker → synthesize Cmd+V → after short delay (~150ms), **restore** previous pasteboard if `changeCount` unchanged.

Restore-after-paste is the right default for transform-on-paste: the destination gets plain text once, and the user's prior clipboard is preserved. Mark the temporary write Transient so we (and other managers) don't pollute history.

```swift
final class PasteSynthesizer {
    func writeAndPaste(_ snapshot: ClipboardSnapshot, restoreAfter: Bool = true) {
        let pb = NSPasteboard.general
        let saved = pb.deepCopiedItems()
        pb.clearContents()
        write(snapshot, to: pb, markers: [.transient, .internalWrite])
        let writtenCount = pb.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            self.synthesizeCmdV()
            if restoreAfter {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    guard pb.changeCount == writtenCount else { return }
                    pb.clearContents()
                    pb.writeObjects(saved)
                    // mark restore as internal so monitor ignores
                }
            }
        }
    }

    private func synthesizeCmdV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true) // V
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
}
```

**Why this beats fighting Shift-Cmd-V:** writing only `public.utf8-plain-text` (no HTML/RTF) leaves the target app nothing richer to prefer. Apps that ignore Shift-Cmd-V still paste plain text because that is all that exists.

**Pasteboard write detail:** Prefer building `NSPasteboardItem`s and `writeObjects(_:)` over repeated `setData` after `clearContents` when multiple types/markers are involved.

### `.copy` / `.cut` path

**`transformCurrentClipboard`:** read active/current pasteboard → script → append history → write result to `NSPasteboard.general` (not Transient; this *is* the new clipboard) with internal marker for one poll cycle.

**`interceptThenTransform`:** swallow chord → synthesize real Cmd+C or Cmd+X → wait until `changeCount` changes (with timeout) → capture → script → overwrite pasteboard with transformed result → append both organic and transformed history entries.

### `.none` path

Run script → append transformed snapshot → set active in `historyStore` only. No pasteboard write. No key synthesis.

---

## Subsystem 5: History Promotion (Non-Destructive)

Promotion creates a new snapshot (`origin: .promotion`, `parentID` = historical id) and writes its representations to `NSPasteboard.general` so subsequent organic Cmd+V uses it. Original row untouched.

```swift
extension TransformationDispatcher {
    func promote(_ historical: ClipboardSnapshot) {
        let promoted = ClipboardSnapshot(
            id: UUID(), createdAt: Date(), parentID: historical.id,
            sourceApp: historical.sourceApp, origin: .promotion,
            representations: historical.representations
        )
        historyStore.append(promoted, setActive: true)
        NSPasteboard.general.clearContents()
        pasteSynthesizer.write(promoted, to: .general, markers: [.internalWrite])
    }
}
```

---

## UI Layer

### Menu bar agent (no Dock icon)

`LSUIElement` = `true`. `MenuBarExtra` (SwiftUI) or `NSStatusItem` + popover.

```swift
@main
struct ClipboardManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene {
        MenuBarExtra("Clipboard", systemImage: "doc.on.clipboard") {
            HistoryBrowserView()
        }
        .menuBarExtraStyle(.window)
        Settings {
            ShortcutSettingsView()
            ScriptsSettingsView()
            PermissionsOnboardingView()
        }
    }
}
```

`AppDelegate` owns: permission checks, `ClipboardMonitor.start()`, tap lifecycle, launch-at-login registration.

### History browser

List of snapshots: plain-text preview / image thumbnail, origin badge, Promote button, optional "Run script…" action. Filter by app / date / UTI. Fuzzy text search over stored plain-text extracts.

### Shortcut settings

Rows: `KeyboardShortcuts.Recorder`, script picker (`ScriptRegistry`), event picker (paste/copy/cut/none), copy/cut mode picker when relevant, suppression toggle (default on for `.paste`).

### Scripts settings

Reveal scripts folder in Finder, reload registry, show last stderr for failed runs, optional timeout field.

### Launch at login

`SMAppService.mainApp.register()` (modern). Skip legacy `SMLoginItemSetEnabled`.

---

## Permissions, Entitlements, and Distribution

| Requirement | Mechanism | Notes |
| --- | --- | --- |
| Suppress / filter hotkeys (CGEventTap) | **Input Monitoring** | `CGPreflightListenEventAccess` / `CGRequestListenEventAccess` |
| Synthesize Cmd+V / Cmd+C | **Accessibility** (PostEvent) | `CGPreflightPostEventAccess` / `CGRequestPostEventAccess` |
| Background clipboard history | **Paste from Other Apps** (when enforced) | Check `NSPasteboard.accessBehavior`; onboard to System Settings |
| Full pasteboard R/W (non-sandboxed) | None beyond above | Sandbox is off |
| Run user shell/Python/Node | None | Same user privileges as Terminal |
| App Store | **Out of scope** | Do not sandbox; do not prepare MAS entitlements |
| Distribution | Local build / optional Developer ID | Owner may override Gatekeeper; notarization optional |
| Launch at login | `SMAppService` | — |

Entitlements file: empty / no App Sandbox. Hardened Runtime can stay on for notarization experiments but is not required for local ad-hoc builds.

---

## Edge Cases and Gotchas Checklist

1. **Never block inside CGEventTap** — scripts/async only; re-enable on timeout disable.
2. **Secure Input** (password fields) can disable taps — detect and surface "Secure Input active" status.
3. **Pipe deadlock / large clipboard** — concurrent stdin/stdout or temp files.
4. **Script timeout & non-zero exit** — no paste, keep prior state, show stderr.
5. **Self-write feedback loops** — internal + Transient markers; ignore in monitor.
6. **Restore-after-paste races** — only restore if `changeCount` still matches our write.
7. **Frontmost-app attribution** — best-effort only; don't trust instantaneous frontmost at poll.
8. **Cut ≠ distinguishable** on pasteboard for organic events.
9. **Keyboard layout / virtualKey** — `0x09` is ANSI V; fine for Cmd+V synthesis on standard layouts; document if exotic ISO layouts misbehave.
10. **Homebrew PATH** — GUI apps get a minimal PATH; inject `/opt/homebrew/bin` and `/usr/local/bin` into script env or scripts won't find `node`/`python3`.
11. **Shebang + quarantine** — scripts copied from the net may be quarantined; owner-local scripts under Application Support should be fine.
12. **Sleep/wake** — recreate or re-enable event tap after wake.
13. **SwiftUI MenuBarExtra + Accessibility prompts** — run permission UX from a proper window/settings scene, not only a menu.
14. **Tahoe Spotlight clipboard history** — orthogonal; our Transient writes should keep us from polluting well-behaved managers; Spotlight's behavior may differ.

---

## Suggested Build Order

1. Scaffold `LSUIElement` menu bar app; implement Permissions onboarding (Input Monitoring + Accessibility + Pasteboard privacy pane link). Verify prompts on a clean TCC state (`tccutil reset` as needed during dev).
2. Implement `ClipboardMonitor` + SQLite history + marker-based self-write suppression. Verify organic copies appear once.
3. Implement `ScriptRunner` + `ShellScriptTransformation` + starter scripts (`plain-text-only.sh`, `json-pretty.sh` calling Python, optional Node sample). Unit-test runner with fixtures (timeout, stderr, PATH).
4. Wire `KeyboardShortcuts` recorder UI + binding persistence. Add CGEventTap suppression path for `.paste` bindings; prove swallow + async dispatch (empty handler first).
5. Implement `PasteSynthesizer` (save → write plain text → Cmd+V → restore). End-to-end: shortcut → script → paste into TextEdit, Safari, and one Electron app (VS Code or Slack).
6. Wire `.copy`/`.cut` (both modes) and `.none` per resolved semantics.
7. History browser + Promote; validate immutability in SQLite across transform/promote cycles.
8. Launch-at-login via `SMAppService`. Optional: Developer ID sign + notarize. Confirm fresh-login permission flow.

---

## Out of Scope for v1

- Mac App Store / sandbox / MAS review prep
- Cloud sync, accounts, telemetry
- Multi-representation script contract (images, HTML round-trip) — design hook via `MACV_REPS_DIR` only
- Running the app as root or as a privileged helper for transforms
- Guaranteed cut-vs-copy detection for organic system events
- Competing with / disabling Tahoe Spotlight clipboard history

---

## References (research anchors)

- Pasteboard has no change notification — poll `changeCount` (industry standard; Maccy et al.)
- `org.nspasteboard.*` transient/concealed conventions — nspasteboard.org
- CGEventTap silent disable on slow callbacks — must return immediately; handle `tapDisabledByTimeout`
- Input Monitoring vs Accessibility vs PostEvent are distinct TCC services
- KeyboardShortcuts uses Carbon `RegisterEventHotKey` — good for registration, insufficient alone when the frontmost app must not also receive the key
- Pasteboard Privacy APIs exist; default enforcement not on in Tahoe mid-2026, but prepare onboarding
- GUI app `$PATH` lacks Homebrew — must be set explicitly for script subprocesses
