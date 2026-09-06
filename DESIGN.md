# Pip
### A little tap. Just what you wanted.

**Repository:** `pip-mac`  
**Product:** A quiet macOS menu-bar app that turns taps on either side of your MacBook into useful actions.

Pip makes your Mac feel physically responsive: tap the edge, pause the music; tap twice, capture a thought; tap three times, run your favorite Shortcut.

We vendor the MIT-licensed [Bump](https://github.com/Roshan-Rengadurai/bump) detection engine. We build the product around it: a memorable first touch, an excellent six-slot editor, dependable actions, and feedback that feels native to the machine.

This is a small, complete instrument—not an automation platform with a gesture feature attached.

---

## 1. Product decisions

- **Menu-bar first.** No Dock icon during normal use. One proper editor window, not a miniature settings app crammed into a popover.
- **Local only.** No accounts, network service, analytics, or action-content telemetry.
- **Apple Silicon first.** Chassis tapping is offered only after a successful sensor probe. Trackpad fallback is a distinct, honestly labeled input mode.
- **Direct distribution.** Developer ID signing and notarization before a public release. No App Store sandbox assumptions.
- **macOS 14+ initially.** Raise this only if testing establishes a concrete reason.
- **Six global bindings.** Left/right × single/double/triple. No app-specific layers, gesture marketplace, or downloadable scripts in v1.
- **Any Apple Shortcut can be bound by exact name.** Pip does not restrict Shortcuts to a curated catalog. A Shortcut can still require its own permissions, input, or foreground interaction.
- **Small built-in library.** Do the common things well; let Shortcuts supply the long tail.

The success criterion is not “50 actions supported.” It is: **a new user makes their first intentional chassis tap, understands what happened, and keeps two or three bindings in daily use.**

Name and icon clearance are required before public distribution; `pip-mac` is the repository name, not a claim of trademark availability.

---

## 2. Experience: teach the Mac a small trick

The emotional core is **physical touch → immediate recognition → useful result**. The delight should come from that relationship, not from decorative animation.

### Design principles

1. **Touch before configuration.**  
   Onboarding demonstrates detection before asking the user to build a map. The first reward is seeing the Mac notice their hand.

2. **The machine acknowledges; it does not applaud.**  
   A small pulse is enough. No confetti, talking mascot, achievement badges, or repeated success notifications.

3. **Recognition must be legible.**  
   “Left · Double” is always distinguishable from “Shortcut completed.” A gesture being recognized is not proof that an action succeeded.

4. **Restraint is a feature.**  
   Typing suppression, a visible pause state, and conservative defaults matter more than detecting the lightest possible tap.

5. **Power belongs behind a clear door.**  
   Assigning “Play / Pause” takes one click. Scripts and troubleshooting exist, but never dominate the ordinary experience.

---

## 3. First run

> **Update, 2026-09-05: the in-app onboarding flow is cut.** Pip is not a published
> app, and setup now lives in the README, which is the onboarding. The six screens
> below stay in this spec as the record of the permission, calibration, and typing
> exercise thinking. Their functional parts survive in the product itself: the
> permission buttons in Settings, Test taps mode, the sensitivity sheet, and the
> preset picker in the Tap Map.

Onboarding is a compact, resizable window, approximately 720 × 560 points. It has a persistent Back button, clear progress labels, and no carousel dots.

No actions run during setup or calibration.

### Screen 1 — “Meet your Mac’s new little trick.”

A shallow top-view illustration of a MacBook. Two small contact marks sit on the left and right palm-rest/chassis edges.

Copy:

> Tap either side of your MacBook to do something useful.  
> Start gently. Pip listens for a tap—not a knock.

Primary: **Try a tap**  
Secondary: **Set up trackpad gestures instead**

Probe hardware in the background:

- Supported sensor opens and streams: proceed with chassis mode.
- Sensor unavailable: explain “Chassis taps aren’t available on this Mac” and offer trackpad mode.
- Probe failure: offer Retry and diagnostics rather than describing the machine as definitively unsupported.

No “works on every MacBook” claim.

### Screen 2 — “Give Pip permission to listen.”

Two permission rows, each with a purpose, status icon, and explicit button:

| Permission | Explanation |
|---|---|
| Input Monitoring | “Helps Pip avoid reacting while you type and supports trackpad input.” |
| Accessibility | “Lets Pip send keyboard controls to your Mac and other apps.” |

Use the vendored permission checks, verified against the selected input mode and actual engine behavior. Do not request a permission solely because an inherited UI did.

- Ask only after a button click.
- Open the relevant System Settings pane.
- Recheck when Pip becomes active, with modest polling only while this screen is visible.
- Display **Not allowed**, **Allowed**, or **Restart needed** in text.
- If the OS requires restarting the process, provide **Quit and reopen Pip** and preserve progress.
- **Set up without listening** allows entry to the editor with detection visibly paused.

Supporting copy:

> Pip doesn’t save what you type. Input activity is used only to suppress accidental gestures.

The adapter must uphold that promise: do not retain characters or log key contents.

### Screen 3 — “Tap here.”

**This is the centerpiece.**

The MacBook drawing grows to occupy the upper half of the window. Its left edge gets a dark outline and a small animated contact mark.

Below it, a live waveform spans the window:

- Thin graphite trace on a warm paper background.
- A visible threshold guide.
- A rolling history of approximately two seconds.
- Accepted impulses receive a small tick and a label.
- Rejected activity can be shown in a subdued style with a reason: **Too soft**, **Typing**, or **Uncertain**.

Copy:

> Rest your MacBook on a steady surface.  
> Give the left edge one gentle tap.

An accepted tap makes the illustrated edge compress inward by two points and rebound. The waveform spike is briefly pinned. A small label appears:

**Left tap. Got it.**

Then ask for two more left taps and three right taps, with generous pacing. Progress is shown as six outlined circles filling with checkmarks—not a score.

Implementation requirements:

- Calibration subscribes to engine diagnostics and **intercepts gestures before action dispatch**.
- Process sensor samples off the main thread.
- Render a downsampled min/max envelope at no more than 30 fps; do not publish 800 UI updates per second.
- Record a short quiet baseline plus accepted sample windows.
- Derive a conservative sensitivity adjustment within the engine’s supported parameter range. Preserve the engine’s side classifier; do not invent a new one in onboarding.
- Keep a default calibration if evidence is weak. Say “Let’s try a firmer tap” rather than silently making the detector hypersensitive.
- Offer **Swap left and right** if recognition is consistently reversed.

After singles, invite one double tap and one triple tap. The display shows separate impulses joining into **Left · Double** or **Right · Triple**.

This teaches an important constraint:

> Pip waits a short beat to tell one tap from two or three.

Use the engine’s validated grouping interval; expose a single shared source of truth for it. A single must not fire and then become a double.

**Trackpad variant:** same visualization, but illustrate the engine’s verified trackpad hit regions and gesture semantics. Do not imply that ordinary trackpad clicks are safe substitutes. Trackpad mode uses an intentional activation modifier—**hold Option while tapping**—with normal pointer use left untouched. If the engine cannot expose enough information to gate detection safely, ship this mode as unavailable until the adapter is fixed.

### Screen 4 — “Try it while you type.”

Ask the user to type a short sentence in a local text field. The waveform remains alive; a labeled **Typing protection on** shield appears.

No typed text is persisted.

Then ask for a tap after typing stops. This demonstrates both suppression and recovery. If repeated false positives occur, suggest a less sensitive setting and recalibrate.

Primary: **That feels right**  
Secondary: **Adjust sensitivity**

Do not pretend calibration can eliminate desk bumps or every typing pattern.

### Screen 5 — “Start with a good map.”

Choose one of three small preset packs. **Everyday** is selected.

| Gesture | Everyday | Quiet desk | Shortcut canvas |
|---|---|---|---|
| Left · Single | Play / Pause | Play / Pause | Unassigned |
| Left · Double | Previous track | Volume down | Unassigned |
| Left · Triple | Next track | Volume up | Unassigned |
| Right · Single | Mute / Unmute output | Mute / Unmute output | Unassigned |
| Right · Double | Screenshot selection → clipboard | Open Calendar | Unassigned |
| Right · Triple | Open Notes | Open Notes | Choose a Shortcut… |

“Shortcut canvas” is explicitly an empty starting point, not six supposed automations the user does not own. Its final slot opens the real Shortcut picker before setup finishes.

Everyday defaults make singles reversible and low-stakes. More deliberate gestures get capture and app-opening actions. No default locks the screen, runs a script, or sends a message.

Each binding can be changed immediately. Presets never install or fabricate Apple Shortcuts.

### Screen 6 — “You’re set.”

Show the final six bindings and the menu-bar glyph.

- **Launch Pip at login** — off until opted in.
- **Quiet tap sound** — on, with a preview button.
- Primary: **Start listening**

Close onboarding, open the map once, and indicate the menu-bar location. No fake gesture is dispatched as a celebration.

---

## 4. The main surface

### Window structure

The **Tap Map** window opens from the menu-bar item. Target size: 820 × 600 points; sensible minimum around 700 × 520, with scrolling rather than clipping.

Header:

- Pip wordmark.
- Segmented input selector: **Chassis / Trackpad**.
- Listening switch with text: **Listening**, **Paused**, or **Permission needed**.

Main area:

- Two columns, **Left side** and **Right side**.
- Three aligned rows labeled **Single**, **Double**, **Triple**.
- A restrained MacBook outline above the columns establishes physical orientation.
- Each slot is a substantial rounded rectangular card with:
  - Gesture marks: `•`, `••`, `•••`, plus the written count.
  - Action icon and name.
  - Secondary detail where useful: Shortcut name, app name, or URL host.
  - A small, labeled-on-hover **Run** button.
  - Overflow menu: Change, Duplicate to…, Clear.

Empty cards say **Assign an action**, not “None.”

Bottom utility strip:

- **Sensitivity**
- **Test taps**
- **Presets**
- Last result, e.g. **Right · Double — Screenshot copied**

Window content is fully navigable by keyboard. VoiceOver labels identify the side, count, action, and enabled state. No interaction depends on hover.

### Assigning an action

Clicking a card opens a searchable sheet, not a nested menu.

Sections:

1. **Suggested** — a few useful built-ins plus recently used actions.
2. **Mac controls**
3. **Apple Shortcuts**
4. **Open app or URL**
5. **Keyboard shortcut**
6. **Shell script** — visually separated under Advanced.

Search matches action labels and discovered Shortcut names. Rows show an icon, title, and a short consequence description.

Simple built-ins assign immediately. Configurable actions open a detail pane:

- **Shortcut:** discovered list, Refresh, and **Enter exact name…**
- **Open app:** application chooser, storing bundle ID and a file bookmark.
- **URL:** explicit scheme and full address preview.
- **Keyboard shortcut:** native-style recorder; shows modifiers and key.
- **Shell script:** monospace editor, working directory chooser, timeout, and a plain-language warning.

The sheet ends with **Assign to Right · Triple**. A capability warning is shown before assignment if an action needs a permission or missing application.

### Inline testing

There are two different tests:

- **Run** on a card executes its action without requiring a physical tap.
- **Test taps** arms a diagnostic mode. Physical gestures highlight the corresponding card, but do **not** execute anything by default. An explicit **Also run actions** switch is available for the session.

Test mode shows:

- Recognized side and count.
- Suppressed/uncertain events.
- Detection timestamp and dispatch delay in an expandable diagnostic row.

Never run a script merely because someone is testing sensitivity.

### Sensitivity

A small sheet contains:

- One slider: **Firmer taps ↔ Lighter taps**.
- Separate left/right adjustment behind **Tune each side**.
- **Typing protection** toggle, on by default, with a warning when disabled.
- **Swap sides**.
- **Recalibrate…**
- **Restore defaults**.
- Live waveform while the sheet is open.

The slider maps to a documented, bounded engine parameter transformation. It is not a cosmetic percentage. Keep timing constants and obscure detector controls out of the ordinary UI.

Chassis and trackpad configurations are stored separately.

### Menu-bar menu

- Listening / Paused status.
- **Open Tap Map…**
- **Pause for 10 minutes** / **Resume**
- **Input: Chassis** with submenu.
- Most recent failure, if any.
- **Settings…**
- **Quit Pip**

Use a stable template glyph: two small contact marks around a central dot. Paused state adds a slash; failure adds an exclamation mark. Color is supplementary.

---

## 5. Feedback and visual identity

### Feedback language

Default feedback is **a very quiet dry tick plus a menu-bar pulse**.

The tick should sound like a fingertip touching wood, not a system alert. Bundle an original short audio asset with documented ownership. No synthesized fake haptic claim.

- **Gesture accepted:** one tick, regardless of tap count; glyph briefly compresses.
- **Action running:** the matching editor card shows a small activity indicator, if visible.
- **Success:** editor result line receives a checkmark. No second sound.
- **Failure:** short, nonmodal message such as “Shortcut ‘Desk time’ wasn’t found.” No beep storm.

The tick acknowledges recognition and dispatch, not completion.

Sound can be disabled globally and respects output mute. Feedback events are throttled. Pip’s own sound must not create a detector loop; verify this on speakers and add a narrowly scoped suppression window only if necessary.

**No screen ripple by default.** Full-screen decoration distracts from the app being controlled and can appear in recordings. An optional **Visual acknowledgment** setting adds a tiny, nonactivating capsule near the menu bar for 450 ms: **Left · Double**. It never takes focus.

### Palette

Light is the signature appearance; dark mode is thoughtfully supported, not terminal-themed.

| Token | Light | Dark |
|---|---|---|
| Canvas | Oat `#F6F3EC` | Warm charcoal `#252420` |
| Surface | Porcelain `#FFFEFA` | `#302F2A` |
| Primary text | Ink `#292D29` | `#F5F1E8` |
| Secondary text | `#62675F` | `#BABCB2` |
| Accent | Deep fern `#41624D` | `#A8C3A8` |
| Decorative contact mark | Apricot `#E9AD83` | `#DDA079` |
| Error | Brick `#A13932` | `#F0A199` |

Apricot is decoration, not small text. Validate actual control contrast, including disabled states; use system semantic colors where they provide better accessibility.

- **Typography:** SF Pro throughout. Titles 26–28 pt semibold; card labels 15 pt medium; body 13–14 pt. SF Mono only for scripts, key diagnostics, and exact command previews.
- **Shape:** 14-point card corners, thin opaque borders, minimal shadow. No frosted panels or floating glass stacks.
- **Icon:** a simple contact mark—two offset rounded forms meeting at one small apricot point. It must read at 16 pixels.
- **Motion:** contact compression around 100 ms, release around 180 ms; no elastic overshoot across the window. Respect Reduce Motion with opacity changes instead.
- **State:** always combine text, shape, or icon with hue. Waveform acceptance uses checkmarks/ticks; rejection uses dashed markers and labels.

---

## 6. Action architecture

### Models

Keep persisted definitions separate from execution services.

```swift
enum ActionKind: Codable, Equatable, Sendable {
    case builtIn(BuiltInAction)
    case shortcut(ShortcutAction)
    case openApplication(ApplicationReference)
    case openURL(URLAction)
    case keyboardShortcut(KeyChord)
    case shellScript(ShellScriptAction)
}

struct ActionDefinition: Codable, Identifiable, Sendable {
    var id: UUID
    var titleOverride: String?
    var kind: ActionKind
}

struct GestureSlot: Codable, Hashable, Sendable {
    var side: Side
    var count: TapCount // one, two, three
}

struct SlotBinding: Codable, Sendable {
    var slot: GestureSlot
    var actionID: UUID?
    var isEnabled: Bool
}
```

Use explicit tagged Codable representations and version migrations, not compiler-dependent enum serialization as a permanent file contract.

Initial built-ins:

- Play / Pause, Previous track, Next track.
- Output volume up/down by a small fixed step.
- Mute / Unmute system output.
- Interactive screenshot selection to clipboard.
- Pause Pip for ten minutes.

Open Notes and Calendar are ordinary `openApplication` actions, not special-case built-ins.

Implement system output controls with CoreAudio against the current default output device. Devices that do not expose software volume return a useful unsupported result. Media controls use the macOS system media-key event route, isolated behind a backend and hardware-tested. Keyboard events use Accessibility-authorized event posting.

Screenshot capture invokes `/usr/sbin/screencapture` with argument-array options for interactive selection and clipboard output. Verify cancellation and permission behavior on every supported macOS release. Cancellation is not an error. Any additional Screen Recording requirement is requested only when this action is first used.

### Execution pipeline

```text
Bump detector
  → EngineAdapter
  → completed GestureEvent
  → GestureRouter
  → binding snapshot
  → ActionDispatcher
  → typed executor
  → ActionResult + FeedbackCoordinator
```

- Only **completed gesture groups** cross the adapter. Never independently dispatch each impulse.
- Each group gets an ID; duplicate delivery is ignored.
- Calibration, pause, typing suppression, and device availability are explicit states.
- The dispatcher snapshots the binding at acceptance so editing a card cannot alter an in-flight invocation.
- Fast controls execute promptly in order.
- Long-running external actions allow one active invocation per binding and at most two globally. Repeated invocation returns **Already running**; do not create an invisible backlog.
- External processes never block the main thread.
- A launch acknowledgment is not proof that a media player or target application changed state.

`ActionResult` distinguishes completed, launched, cancelled, unavailable, permissionRequired, busy, and failed. UI copy comes from structured results, not raw process output.

### Apple Shortcuts: use the CLI

Use `/usr/bin/shortcuts`, not UI scripting or Apple Events.

**Discovery**

- Run `shortcuts list` with `Process`.
- Capture UTF-8 stdout and stderr independently.
- Preserve name spelling and whitespace; remove line terminators, not arbitrary surrounding spaces.
- Sort for display only.
- Refresh on entering the picker if stale and through an explicit Refresh button.
- Cache names locally for a responsive picker; cached presence is not proof that a Shortcut still exists.
- Discovery’s line-oriented output is not a complete identity API. Provide **Enter exact name…** for names the listing cannot represent unambiguously.

**Execution**

```swift
process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
process.arguments = ["run", exactShortcutName]
```

Never construct a shell command. Spaces, quotes, and metacharacters remain literal arguments.

- Persist the exact name. The CLI does not give us a stable, universally usable Shortcut identity contract.
- Renaming or deleting a Shortcut can break its binding. Offer **Choose replacement…**; never fuzzy-match and run something else.
- If duplicate names are ambiguous, ask the user to make the name unique.
- No input is supplied by default. Offer an optional literal text input written to a temporary file and passed using the CLI’s input-path option.
- Foreground prompts and permissions belong to Shortcuts. Do not promise silent execution.
- Drain both output pipes continuously, keep bounded diagnostic tails, and treat exit status as the primary result.
- Use a generous five-minute default timeout, configurable in advanced settings. Timing out stops Pip’s runner process; it does not promise rollback or cancellation of effects already triggered.
- Do not surface Shortcut output contents in general logs or notifications.
- Validate actual CLI behavior on supported macOS versions, including interactive Shortcuts, Unicode names, cancellation, and nonzero exits.

“Any Shortcut” means **no Pip-side allowlist or action taxonomy limitation**, not a promise to bypass the Shortcut’s own requirements.

### Other executors

- **Application:** resolve bundle ID first, bookmarked location second; launch through `NSWorkspace`. Explain missing apps.
- **URL:** allow `https` and `http` directly. Custom schemes require confirmation on assignment. Reject executable pseudo-URLs; local files use a separate file/app route.
- **Keyboard shortcut:** store virtual key code, modifiers, and display metadata; explain layout-sensitive behavior. Target the frontmost app at dispatch time. Release all synthesized modifiers even on failure.
- **Shell script:** user-authored only; execute using `/bin/zsh -c` with the stored script as one argument, a documented non-login environment, explicit working directory, and bounded output. Default timeout: 30 seconds. No `sudo`, no downloaded scripts, no hidden profile sourcing. Warn that scripts run with the user’s privileges.

Importing configuration never silently enables shell scripts. They remain disabled pending review.

### Preset packs

Ship versioned JSON resources:

```json
{
  "schemaVersion": 1,
  "id": "everyday",
  "revision": 1,
  "name": "Everyday",
  "bindings": [
    {
      "side": "left",
      "count": 1,
      "action": {
        "type": "builtIn",
        "name": "mediaPlayPause"
      }
    },
    {
      "side": "right",
      "count": 3,
      "action": {
        "type": "openApplication",
        "bundleIdentifier": "com.apple.Notes"
      }
    }
  ]
}
```

Actual packs contain all six slots, including explicit empty slots. Validate them in tests.

Applying a pack previews changes and offers **Replace all** or **Fill empty slots**. Preset updates never overwrite user configuration.

### Persistence

Store an atomic, versioned JSON document at:

`~/Library/Application Support/Pip/config.json`

It contains:

- Bindings and action definitions.
- Separate input-mode tuning.
- Feedback preferences.
- Onboarding progress.
- Preset provenance.
- Schema version.

Use an actor-owned configuration store, debounced writes, atomic replacement, and a last-known-good backup. On corrupt input, offer recovery; do not silently erase the map.

Keep transient pause state and running tasks out of persistent configuration. Use `SMAppService` for login-item registration and report its actual state.

---

## 7. Repository and module boundaries

Use SwiftPM for libraries and the executable source. Supply a small, checked-in macOS app target/project for bundle metadata, signing, resources, and stable permission identity.

```text
pip-mac/
├── DESIGN.md
├── Package.swift
├── App/
│   ├── Pip.xcodeproj/
│   ├── Info.plist
│   └── Pip.entitlements
├── Sources/
│   ├── PipApp/             # app lifecycle, menu bar, composition root
│   ├── PipUI/              # map, picker, onboarding, settings
│   ├── PipTheme/           # colors, typography, components, feedback assets
│   ├── PipDomain/          # models, protocols, routing rules
│   ├── PipActions/         # executors, CLI discovery, process management
│   ├── PipPersistence/     # config store, migrations, presets
│   └── PipEngineAdapter/   # upstream translation, calibration, diagnostics
├── Vendor/Bump/
│   ├── Core/
│   ├── Permissions/
│   ├── Models/
│   ├── LICENSE
│   ├── UPSTREAM.md
│   └── PATCHES.md
├── Resources/Presets/
├── Tests/
└── Scripts/
    ├── build-app.sh
    └── package-release.sh
```

### Vendor

Pin an upstream commit and record its SHA. Import:

- `Core/`: sensor access, buffering, impulse detection, grouping, typing suppression, verified trackpad support.
- `Permissions/`: permission probes and OS integration, without inherited presentation.
- Only the portions of `Models/` required by those modules.

Exact file boundaries follow an initial dependency audit. Do not copy an entire unfinished app merely to preserve its directory names.

Preserve copyright and MIT attribution. Maintain a short patch ledger. Keep upstream behavioral changes separate from product changes.

### Write fresh

All UI, onboarding, action execution, presets, persistence, theme, sound, overlays, and menu-bar presentation.

Do not adopt Bump’s `SoundPlayer` or overlay layer as product architecture. Replace them with `FeedbackCoordinator`; reuse an asset only after verifying its license.

### Dependency rule

Apple frameworks plus vendored Bump only for v1. SwiftUI for screens; AppKit for menu-bar integration, window control, and keyboard recording. No theme framework, database, reactive library, or shell-command package.

`PipDomain` must compile without AppKit or sensor access. The engine adapter exposes protocols and an `AsyncStream` of events; UI never imports vendor types. A replay source makes the full app demonstrable without hardware.

---

## 8. Milestones

### M1 — This weekend: land the complete skeleton, off-Mac

**Scope**

- Pin and vendor the engine with license and dependency audit.
- Create app shell, package targets, bundle identity, and build scripts.
- Implement six-slot editor and action picker against a replay engine.
- Implement action models and library, including the real argument-based Shortcuts runner.
- Implement preset JSON, persistence, and basic migrations.
- Add basic card/menu-bar feedback and bundled tick asset.
- Build minimal permission/status surfaces.
- Unit-test routing, serialization, preset validity, process argument construction, and duplicate-group prevention.
- Write a local-Mac verification checklist.

**Done means:** the planned source, resources, project configuration, and tests are committed; platform-independent tests pass wherever a Swift toolchain is available; macOS-only code is explicitly marked **not yet built or exercised**. The replay path is implemented, not claimed to have been visually verified. No signing, HID, permissions, media-control, or Shortcuts integration claims are made before a local build.

M1 is an ambitious implementation pass, not a release.

### M2 — On a Mac: make the instrument trustworthy

**Scope**

- Compile, fix integration assumptions, and launch a stable `.app` bundle.
- Validate sensor lifecycle and permissions.
- Build the complete waveform calibration and typing exercise.
- Verify gesture grouping latency, side identification, and suppression.
- Validate Shortcuts discovery/run, application launching, media controls, screenshot behavior, and keyboard events.
- Validate trackpad safety before enabling fallback.
- Handle sleep/wake, lid close, output-device changes, permission revocation, and sensor failure.
- Tune sound and visual feedback on actual hardware.

**Done means:** a first-time user can grant permissions, calibrate, apply Everyday, edit a slot to an existing Shortcut, and run it by tapping. A documented typing/desk-bump test produces acceptable results, with hardware and settings recorded. Failures are recoverable and visible. CPU/energy profiling shows the detector does not keep a sleeping Mac awake; waveform work stops when hidden.

### M3 — Small public release

**Scope**

- Test multiple Apple Silicon MacBook models and supported OS versions.
- Polish VoiceOver, keyboard navigation, contrast, and Reduce Motion.
- Add reviewed configuration import/export, diagnostics export, and recovery.
- Developer ID sign, enable hardened runtime where compatible, notarize, and staple.
- Publish a concise site, compatibility notes, license attribution, and release archive.
- Use manual update checks initially; no updater dependency until needed.

**Done means:** a downloaded build installs and launches normally on a clean Mac; permission instructions match reality; no known accidental destructive default exists; unsupported hardware gets an honest fallback path; diagnostics contain no typed text, script bodies, Shortcut output, or raw sensor history by default.

---

## 9. Risks and mitigations

### Undocumented HID interface

`AppleSPUHIDDevice` is private implementation territory. Availability, report formats, or access policy can change with hardware and macOS updates; notarization does not make the interface supported. Keep all access inside the vendored engine boundary, probe capability at runtime, and fail closed on unknown or malformed data. Maintain a tested hardware/OS matrix rather than a broad compatibility claim. Reinitialize after wake with bounded retries, release resources when paused where practical, and never busy-loop on disconnect. Keep trackpad mode independently usable. The app must remain a working editor even if a future macOS update disables chassis input entirely.

### False positives while typing

This is the product’s trust risk. Start conservative, preserve Bump’s typing suppression, demonstrate it during onboarding, and test typing bursts, palm contact, desk bumps, lap use, and speaker playback. Show suppressed events in diagnostics so users can distinguish protection from broken detection. Only completed groups dispatch; apply narrowly measured cooldowns, not arbitrary dead time that hides detector problems. Singles default to reversible controls. Sensitive user-assigned actions receive a warning recommending double or triple taps. Pause is always one menu-bar interaction away; do not market chassis gestures as suitable for safety-critical operations.

### Gatekeeper and unsigned distribution

An off-Mac source drop is not a distributable app. Early development builds may be blocked, and changing bundle identity or signing can cause permissions to reset. Use one stable bundle identifier and local app packaging from the beginning. For testers, explain the legitimate per-app macOS approval path; never instruct users to disable Gatekeeper globally. Before public release, sign nested executable code correctly, notarize, staple, and test the actual downloaded artifact on a clean account. Keep distribution outside the Mac App Store unless both sensor access and arbitrary user action execution are proven compatible with its rules.

### Accessibility-permission friction

System Settings handoffs are confusing, and the permission database can appear stale after rebuilding. Request permissions just in time, explain each in plain language, and show observed OS state instead of assuming a successful button click means access was granted. Recheck on activation and provide a real restart path when needed. Keep “set up without listening” usable, but never display **Listening** while required access is absent. Detect revocation and stop affected operations gracefully. Do not request blanket Automation access for Shortcuts: the CLI route avoids that additional Pip-specific prompt, although individual Shortcuts can still prompt for their own capabilities.

---

## Shipping standard

Pip is ready when the first successful tap feels inevitable—and the next hundred do not demand attention.

The waveform earns the user’s trust. The six cards make the system understandable. Shortcuts make it personal. Everything else should stay quiet.

