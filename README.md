# drummakid

A native iOS drum machine and step sequencer, built with SwiftUI and AVAudioEngine.

## What it does

- **16 drum pads** — live-tappable, loaded from a built-in kit or your own WAV samples (single files or a whole folder, auto-mapped to slots by filename, with built-in sounds filling any gaps).
- **16-track step sequencer** — 1-bar or 4-bar patterns, four independent phrase slots (A/B/C/D) that automatically chain into an arrangement as you fill them in.
- **Per-drum controls** — Volume, Pan, Accent, Chance (trigger probability), Swing, Click, and Tune, consistent across every phrase.
- **FX** — 16 effect presets (filters, distortion, delay/echo, reverb, stutter, chorus, vibrato, phaser, and more), applied per-track or on a master bus, with real live DSP processing for distortion, filtering, and reverb — not just an approximation.
- **Recording & export** — capture a live take (pad taps plus the running sequence) or render the current pattern arrangement directly to a 24-bit WAV file, FX included.
- **Metronome**, one-step **Undo** for pattern clears, and a handful of accent color themes.

Sequencer timing is phase-locked and sample-accurate — the audio engine, not the UI thread, decides exactly when each hit sounds, so playback stays tight regardless of what else is happening on screen.

## Project structure

- `Drummakid/App/DrumMachineEngine.swift` — the audio engine and all sequencing, FX, and persistence logic (the app's single `ObservableObject`).
- `Drummakid/App/RootView.swift` — the SwiftUI interface.
- `Drummakid/App/DrumMachineAudioSupport.swift`, `ArraySafeAccess.swift` — small supporting types.
- `Drummakid/Resources/BuiltInDrumPack` — the bundled default drum kit.
- `DrummakidTests/` — engine-level unit tests (XCTest).

See `CHANGELOG.md` for release notes.

## Building

Open `Drummakid.xcodeproj` directly in Xcode 15+ and run. There's also a `project.yml` for [XcodeGen](https://github.com/yonaskolb/XcodeGen) if you'd rather regenerate the `.xcodeproj` from scratch:

```bash
xcodegen generate
```

The app is fully self-contained: no external dependencies, no backend, no configuration to set up.

## Testing

Run the `DrummakidTests` target from Xcode, or from the command line against any available simulator:

```bash
xcodebuild -project Drummakid.xcodeproj -scheme Drummakid \
  -destination 'platform=iOS Simulator,name=<simulator name>' test
```
