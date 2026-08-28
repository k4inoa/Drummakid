# Changelog

## [1.1] - 2026-07-19

### Added
- **Undo button** next to Clear / Clear All (arrow icon, no label). Single-slot undo: restores the pattern and all FX state from immediately before the last Clear or Clear All.
- **Real live effects processing.** Distortion, Low Pass / High Pass filtering, and Reverb are now genuinely applied to audio *while playing*, through a per-track and master effects chain — previously these were only approximated with volume/pan/rate tricks and had no audible effect live.
- 6 new automated regression tests covering export correctness, Clear/Clear All scope, undo, and per-track Accent/Chance behavior (8 → 14 total).

### Fixed
- **Exported WAV files silently dropped every effect.** The export path meant to reproduce delay, reverb, distortion, and filtering was never actually being used; every export was a dry, unprocessed mix regardless of what FX were active.
- **Exported WAV files could come out completely silent.** A separate, deeper bug in that same export path: the offline audio engine was being switched into rendering mode *after* audio was already scheduled to play, so the scheduled audio never actually rendered. Found via a new automated test that compares dry vs. FX-active export output.
- **Sequencer timing drifted and jittered** under UI load. Replaced the old "wait, then reschedule" timer with a phase-locked, sample-accurate scheduler, so steps land on time regardless of what else the UI is doing.
- **Changing tempo mid-playback could glitch** — double-firing or truncating whichever step was in flight. Tempo changes now cleanly take effect at the next step boundary.
- **Metronome could drift or skip beats.** It now shares the exact same precise audio engine clock as the drum voices instead of a separate, weaker scheduling path.
- **Low Pass and High Pass couldn't be used together** — enabling both silently dropped whichever was processed second. They now combine correctly as a real band-pass filter.
- **Choking a voice clicked, then (after an earlier fix) lingered too long**, causing a retriggered pad to audibly overlap with the tail of the previous hit. Choke cutoffs are now instant, since the new hit's own attack masks any click.
- **Clear and Clear All updated the underlying pattern correctly but the screen didn't show it** — steps, pads, and FX indicators looked unchanged even though the data was cleared.
- **Clear All only cleared the currently viewed phrase**, not all four (A/B/C/D) despite the label.
- **Accent and Chance reset when switching phrases.** They're now properties of the drum itself, consistent everywhere, matching how Volume and Pan already worked.
- **The app was redrawing its entire UI ~30 times a second, constantly, even sitting idle**, due to a status property re-publishing on every check regardless of whether it had changed.
- Removed a hardcoded filesystem path that only ever pointed at the original development machine and did nothing for anyone else.
- Fixed a mismatch between the audio session's hardware sample rate and the app's internal processing rate that forced a needless resampling pass on every processed voice.

### Changed
- **BPM range widened from 60–180 to 40–300**, covering drone/ambient/half-time tempos on the low end and drum & bass/hardcore tempos on the high end.
- Audio files are now decoded once and cached, instead of being reopened from disk on every single pad trigger.
- Pattern and settings auto-save now waits for a brief pause instead of writing to disk on every pixel of a knob drag.

### Performance
- Fast-changing playback state (current step, pad-trigger pulses, drummer animation) was moved off the main engine object onto its own observable state, so the step sequencer no longer forces a full-screen re-render on every 16th note.

### Removed
- ~180 lines of dead code with no remaining callers: an unused procedural drum-synthesis fallback (superseded by the bundled WAV samples), an unused 16-bit WAV encoder (superseded by the 24-bit export path), and several UI-disconnected functions (manual pattern slot save/load, a standalone clear-FX-preset action, a legacy alias for Clear) along with their unused supporting constants.
