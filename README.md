# Pip

Double- or triple-tap the back of your Mac (or the desk beside it) to run any Apple Shortcut. Built on the [Bump](https://github.com/Roshan-Rengadurai/bump) accelerometer engine (MIT, vendored in `Vendor/Bump/`).

**Private.** Design spec: [DESIGN.md](DESIGN.md). Milestones and module map live there.

- `Sources/PipDomain` — tap-to-action model + gesture router
- `Sources/PipActions` — Shortcut discovery (`shortcuts list`) + runner + dispatcher
- `Sources/PipPersistence` — config store + preset packs (`Resources/Presets/`)
- `Sources/PipEngineAdapter` — Bump GestureEngine adapter + replay source for tests
- `Sources/PipApp` — app shell (M1 stub)

M2: on-Mac build + first real desk-tap. Nothing here publishes without the owner's explicit approval.
