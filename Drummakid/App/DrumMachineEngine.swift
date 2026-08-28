import AVFoundation
import CoreMIDI
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers
import UIKit

@MainActor
final class DrumMachineEngine: ObservableObject {
    private struct SampleAsset {
        var fileURL: URL
        var sampleRate: Double
        var channelCount: AVAudioChannelCount
        var frameCount: AVAudioFramePosition
        var duration: Double
    }

    private struct RenderSampleBuffer {
        var left: [Float]
        var right: [Float]
        var sampleRate: Double

        var frameCount: Int {
            max(left.count, right.count)
        }
    }

    private struct DrumPackCopyResult {
        var copiedURLs: [URL]
        var failedFileNames: [String]
        var oversizedFileNames: [String]
    }

    private struct RecordedHit {
        var time: Double
        var track: Int
        var volume: Double
        var pan: Double
        var rate: Double
    }

    private struct VoicePlaybackSettings {
        var volume: Double
        var pan: Double
        var rate: Double
        var fxIsActive: Bool
    }

    private final class DrumVoice {
        let player = AVAudioPlayerNode()
        let varispeed = AVAudioUnitVarispeed()
        var trackIndex = 0
        var chokeGroup: Int?
        var playbackRate: Double = 1.0
        var isActive = false
        var startedAt: CFTimeInterval = 0
        var expectedEndTime: CFTimeInterval = 0
        private var fadeWorkItem: DispatchWorkItem?

        /// Cuts playback. Pool bookkeeping (`isActive`, `startedAt`, `expectedEndTime`)
        /// updates synchronously so voice-pool reuse and active-voice counts (e.g. choke
        /// groups) are correct the instant this call returns, exactly as before. When the
        /// voice is audibly playing, only the actual player cutoff is deferred: volume is
        /// ramped to zero over a handful of milliseconds first so choking another pad's
        /// voice, or reaping a stale one, never produces a hard-edged click. This has to
        /// stay short -- a choke is meant to read as an instant cut (the same way it does
        /// on real hardware/DAW voice-stealing), not a fade-out that overlaps audibly with
        /// the next hit's attack; a few milliseconds is enough to remove the click without
        /// being perceptible as an overlapping tail. `declick: false` is for the "reuse
        /// this same voice immediately" path, where a new onset follows in the same call
        /// and any ramp would just be cancelled by the next `stop()` anyway.
        func stop(declick: Bool = true) {
            fadeWorkItem?.cancel()
            fadeWorkItem = nil

            let shouldFade = declick && player.isPlaying && player.volume > 0.001
            let startVolume = player.volume
            isActive = false
            startedAt = 0
            expectedEndTime = 0
            playbackRate = 1.0

            guard shouldFade else {
                player.stop()
                player.reset()
                return
            }

            let steps = 4
            let stepDuration = 0.001
            for step in 1...steps {
                let workItem = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    if step == steps {
                        self.player.stop()
                        self.player.reset()
                    } else {
                        self.player.volume = startVolume * Float(steps - step) / Float(steps)
                    }
                }
                if step == steps {
                    fadeWorkItem = workItem
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + stepDuration * Double(step), execute: workItem)
            }
        }
    }

    private struct TrackFXRuntimeState {
        // Independent bands (rather than one filterMode + one filterCutoff) so Low Pass
        // and High Pass can both be active at once as a real band-pass combination,
        // instead of whichever preset happens to be processed last silently winning.
        var lowPassActive = false
        var lowPassCutoff: Double = 20_000
        var highPassActive = false
        var highPassCutoff: Double = 20
        var stutterDivisionOverride: Int?
        var lfoEnabled = false
        var vibratoEnabled = false
        var fxRate: Double = 1.0
        var fxRateJitter: Double = 0.0
        var fxGain: Double = 1.0
        var fxEchoRepeats: Int = 0
        var fxEchoDelay: Double = 0.08
        var fxEchoDecay: Double = 0.55
        var fxPanJitter: Double = 0.0
        var delayMix: Double = 0
        var reverbMix: Double = 0
        var stutterAmount: Double = 0
    }

    private struct FXControlState {
        var filterCutoff: Double
        var delayMix: Double
        var reverbMix: Double
        var stutterAmount: Double
    }

    struct StepEvent: Codable {
        var isActive: Bool = false
    }

    enum EntryMode: String, CaseIterable {
        case pattern
        case build

        var title: String {
            switch self {
            case .pattern: return "Pattern"
            case .build: return "Build"
            }
        }
    }

    enum SequenceLength: Int, CaseIterable {
        case oneBar = 16
        case fourBars = 64

        var title: String {
            switch self {
            case .oneBar: return "16 Steps"
            case .fourBars: return "4 Bars"
            }
        }
    }

    enum PatternSlot: String, CaseIterable, Codable {
        case a
        case b
        case c
        case d

        var label: String { rawValue.uppercased() }
    }

    enum FXEditLayer {
        case track
        case master
    }

    enum FXPreset: Int, CaseIterable {
        case sampleRate = 1
        case bitCrush = 2
        case distortion = 3
        case delay = 4
        case reverb = 5
        case lowPass = 6
        case highPass = 7
        case stutter = 8
        case repeatFX = 9
        case feedback = 10
        case chorus = 11
        case vibrato = 12
        case shuffle = 13
        case phaser = 14
        case gate = 15
        case width = 16

        var label: String {
            switch self {
            case .sampleRate: return "sample rate"
            case .bitCrush: return "bit crush"
            case .distortion: return "distortion"
            case .delay: return "Delay"
            case .reverb: return "reverb"
            case .lowPass: return "low pass"
            case .highPass: return "high pass"
            case .stutter: return "stutter"
            case .repeatFX: return "repeat"
            case .feedback: return "feedback"
            case .chorus: return "chorus"
            case .vibrato: return "vibrato"
            case .shuffle: return "shuffle"
            case .phaser: return "phaser"
            case .gate: return "gate"
            case .width: return "width"
            }
        }
    }

    struct PersistedState: Codable {
        var currentPattern: [[StepEvent]]
        var slotPatterns: [String: [[StepEvent]]]
        var bpm: Double
        var trackSwings: [Double]?
        var trackClicks: [Double]?
        var trackTunes: [Double]?
        var trackAccents: [Double]?
        var trackProbabilities: [Double]?
        var swingAmount: Double?
    }

    private enum DrummerPoseSource {
        case sequencer
        case livePad
    }

    private struct DrummerPoseState {
        var pose: DrummerPose = .rest
        var deadline: CFTimeInterval = 0
        var updatedAt: CFTimeInterval = 0
    }

    @Published var bpm: Double = 120 {
        didSet {
            guard bpm.isFinite else {
                bpm = oldValue
                return
            }
            let clamped = min(max(bpm, 40), 300)
            if clamped != bpm {
                bpm = clamped
                return
            }
            persistState()
            // No clock reschedule needed: the phase-locked sequencer reads bpm fresh when
            // it computes each step's duration, so a live tempo change takes effect at the
            // next step boundary without disturbing the step already in flight.
        }
    }
    @Published var isPlaying = false
    @Published var entryMode: EntryMode = .pattern
    @Published var sequenceLength: SequenceLength = .oneBar {
        didSet {
            if visualState.currentStep >= sequenceLength.rawValue {
                visualState.currentStep = 0
            }
            if selectedStep >= sequenceLength.rawValue {
                selectedStep = 0
            }
            // Step duration doesn't depend on sequence length, and the sequencer already
            // re-reads sequenceLength.rawValue on every step, so no reschedule is needed here.
        }
    }
    @Published var selectedTrack = 0 {
        didSet {
            syncSelectedTrackFXUIState()
            applyFXSettings()
        }
    }
    @Published var selectedStep = 0
    @Published var selectedPatternSlot: PatternSlot = .a {
        didSet {
            loadPatternForSelectedSlot()
        }
    }
    @Published var activeFXPresets: Set<FXPreset> = []
    @Published var selectedFXPreset: FXPreset?
    @Published var fxEditLayer: FXEditLayer = .track {
        didSet {
            syncSelectedTrackFXUIState()
        }
    }
    /// currentStep, drummerPose, isAnyVoicePlaying, and triggeredPads live on this shared
    /// object instead of as @Published properties here -- see PlaybackVisualState's doc
    /// comment for why.
    let visualState = PlaybackVisualState()
    @Published var statusMessage = "Load a 16-file WAV drum pack to begin."
    @Published var isRecording = false
    @Published var hasPendingRecording = false
    @Published var exportedWAV: ExportedWAV?
    @Published private var currentPlaybackSlot: PatternSlot = .a

    @Published var isMetronomeEnabled = false
    @Published var metronomeVolume: Double = 0.45

    @Published var isMIDIEnabled: Bool = false {
        didSet { midiEngine.isEnabled = isMIDIEnabled }
    }
    private let midiEngine = MIDIControllerEngine()

    @Published var filterCutoff: Double = 12_000 {
        didSet { applyFXSettings() }
    }
    @Published var delayMix: Double = 0 {
        didSet { applyFXSettings() }
    }
    @Published var reverbMix: Double = 0 {
        didSet { applyFXSettings() }
    }
    @Published var stutterAmount: Double = 0

    private let trackCount = 16
    private let voicesPerTrack = 12
    private var trackVolumes = Array(repeating: 1.0, count: 16)
    private var trackPans = Array(repeating: 0.0, count: 16)
    private var trackSwings = Array(repeating: 0.0, count: 16)
    private var trackClicks = Array(repeating: 0.0, count: 16)
    private var trackTunes = Array(repeating: 0.0, count: 16)
    private var trackAccents = Array(repeating: 1.0, count: 16)
    private var trackProbabilities = Array(repeating: 1.0, count: 16)
    private var sampleNames = (1...16).map { "Pad \($0)" }
    private var steps: [[StepEvent]]
    private var slotPatterns: [String: [[StepEvent]]] = [:]
    private var trackActiveFXPresets = Array(repeating: Set<FXPreset>(), count: 16)
    private var trackSelectedFXPresets = Array<FXPreset?>(repeating: nil, count: 16)
    private var trackFXControlStates = Array(repeating: [FXPreset: FXControlState](), count: 16)
    private var trackFXRuntimeStates = Array(repeating: TrackFXRuntimeState(), count: 16)
    private var masterActiveFXPresets = Set<FXPreset>()
    private var masterSelectedFXPreset: FXPreset?
    private var masterFXControlStates: [FXPreset: FXControlState] = [:]
    private var masterFXRuntimeState = TrackFXRuntimeState()
    private var masterHighPassSweepPhase = 0.0

    private var sampleURLs: [URL?] = Array(repeating: nil, count: 16)
    private var sampleAssets: [SampleAsset?] = Array(repeating: nil, count: 16)
    private let playbackEngine = AVAudioEngine()
    private var playbackEngineConfigured = false
    private var voicePools: [[DrumVoice]] = Array(repeating: [], count: 16)
    // Real per-track insert chain so FX are actually audible live, not just approximated
    // via volume/pan/rate scalars: each track's voices sum into trackFXInputMixers, run
    // through distortion -> EQ (low/high pass) -> reverb, then all 16 tracks sum into the
    // master chain before finally reaching playbackEngine's own mixer. Bypassed aggressively
    // when unused (see applyLiveTrackFXChain/applyLiveMasterFXChain) to keep idle CPU cost low.
    private var trackFXInputMixers: [AVAudioMixerNode] = []
    private var trackDistortionUnits: [AVAudioUnitDistortion] = []
    private var trackEQUnits: [AVAudioUnitEQ] = []
    private var trackReverbUnits: [AVAudioUnitReverb] = []
    private let masterFXInputMixer = AVAudioMixerNode()
    private let masterDistortionUnit = AVAudioUnitDistortion()
    private let masterEQUnit = AVAudioUnitEQ(numberOfBands: 2)
    private let masterReverbUnit = AVAudioUnitReverb()
    private var processedPlaybackBuffers: [AVAudioPCMBuffer?] = Array(repeating: nil, count: 16)
    private var cachedAudioFiles: [AVAudioFile?] = Array(repeating: nil, count: 16)
    private var chokeGroups: [Int?] = Array(repeating: nil, count: 16)
    private var triggerPulseToken = Array(repeating: 0, count: 16)
    // The metronome plays through the same AVAudioEngine graph (and the same AVAudioTime
    // scheduling) as the drum voices, rather than a separate AVAudioPlayer instance, so it
    // shares one precise clock with everything else instead of its own weaker, less
    // reliable scheduling path.
    private var metronomeHighVoice: AVAudioPlayerNode?
    private var metronomeLowVoice: AVAudioPlayerNode?
    private var metronomeHighBuffer: AVAudioPCMBuffer?
    private var metronomeLowBuffer: AVAudioPCMBuffer?
    private var interruptionObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?
    private var playbackMonitorTimer: Timer?
    private var playbackVisualWorkItem: DispatchWorkItem?
    private var playbackVisualDeadline: CFTimeInterval = 0
    private var drummerPoseWorkItem: DispatchWorkItem?
    private var recordingStartTime: CFTimeInterval = 0
    private var recordedHits: [RecordedHit] = []
    private var sampleRenderCache: [RenderSampleBuffer?] = Array(repeating: nil, count: 16)
    private var isRenderingExport = false
    private var persistWorkItem: DispatchWorkItem?
    private let persistDebounceInterval: TimeInterval = 0.3
    private var sequencerWorkItem: DispatchWorkItem?
    private var clockGeneration = 0
    /// Absolute CACurrentMediaTime-based deadline for the next unprocessed step. The
    /// scheduler wakes up schedulerLookahead seconds before this, hands CoreAudio a
    /// precise AVAudioTime for that exact instant, then advances this by one step
    /// duration (read fresh from the current bpm) -- so execution delays on the main
    /// thread cause bounded per-hit jitter instead of the cumulative drift you get from
    /// repeatedly scheduling "now + interval".
    private var nextStepDeadline: CFTimeInterval = 0
    private let schedulerLookahead: CFTimeInterval = 0.012
    private let schedulerLeadIn: CFTimeInterval = 0.03
    private var playbackPhraseOrder: [PatternSlot] = [.a]
    private var playbackPhraseIndex = 0
    private var sequencerPoseState = DrummerPoseState()
    private var livePadPoseState = DrummerPoseState()
    private var nextLivePadPose: DrummerPose = .rightHit
    private let minDrummerPoseHold: CFTimeInterval = 0.12
    private let maxDrummerPoseHold: CFTimeInterval = 0.18
    private let livePadPoseHold: CFTimeInterval = 0.14
    private let livePadRestGrace: CFTimeInterval = 0.08
    private let renderSampleRate = 48_000.0
    private let playbackChannelCount: AVAudioChannelCount = 2
    private let persistedStateKey = "drumMachineState.v2"

    init() {
        steps = Self.makeEmptyPattern()
        chokeGroups = Self.defaultChokeGroups
        prepareUserDocumentsIfNeeded()
        loadPersistedStateIfAvailable()
        loadPatternForSelectedSlot()
        configureAudioSession()
        configureMetronomeBuffers()
        registerAudioObservers()
        startPlaybackMonitor()
        loadBuiltInDrumPack()
        syncSelectedTrackFXUIState()
        isMIDIEnabled = midiEngine.isEnabled
    }

    deinit {
        playbackMonitorTimer?.invalidate()
        sequencerWorkItem?.cancel()
        persistWorkItem?.cancel()
        playbackEngine.stop()
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
        if let routeChangeObserver {
            NotificationCenter.default.removeObserver(routeChangeObserver)
        }
    }

    func sampleName(for index: Int) -> String {
        sampleNames[safe: index] ?? "Pad \(index + 1)"
    }

    func trackVolume(for index: Int) -> Double {
        trackVolumes[safe: index] ?? 1.0
    }

    func trackPan(for index: Int) -> Double {
        trackPans[safe: index] ?? 0
    }

    func trackSwing(for index: Int) -> Double {
        trackSwings[safe: index] ?? 0
    }

    func trackClick(for index: Int) -> Double {
        trackClicks[safe: index] ?? 0
    }

    func trackTune(for index: Int) -> Double {
        trackTunes[safe: index] ?? 0
    }

    func stepIsActive(track: Int, step: Int) -> Bool {
        guard isValid(track: track, step: step) else { return false }
        return patternForSlot(displayedPatternSlot)[track][step].isActive
    }

    var displayedPatternSlot: PatternSlot {
        isPlaying ? currentPlaybackSlot : selectedPatternSlot
    }

    func setTrackVolume(_ value: Double, for index: Int) {
        guard trackVolumes.indices.contains(index) else { return }
        objectWillChange.send()
        trackVolumes[index] = value
        refreshActivePlayers(for: index)
    }

    func setTrackPan(_ value: Double, for index: Int) {
        guard trackPans.indices.contains(index) else { return }
        objectWillChange.send()
        trackPans[index] = value
        refreshActivePlayers(for: index)
    }

    func setTrackSwing(_ value: Double, for index: Int) {
        guard trackSwings.indices.contains(index) else { return }
        objectWillChange.send()
        trackSwings[index] = min(max(value, 0), 0.45)
        persistState()
    }

    func setTrackClick(_ value: Double, for index: Int) {
        guard trackClicks.indices.contains(index) else { return }
        objectWillChange.send()
        trackClicks[index] = min(max(value, 0), 1)
        persistState()
    }

    func setTrackTune(_ value: Double, for index: Int) {
        guard trackTunes.indices.contains(index) else { return }
        objectWillChange.send()
        trackTunes[index] = min(max(value, -12), 12)
        refreshActivePlayers(for: index)
        persistState()
    }

    /// Accent and Chance are properties of the drum itself, not of a specific step or
    /// phrase -- every active hit of a track plays with that track's accent and trigger
    /// probability, the same way Volume and Pan already work.
    func trackAccent(for index: Int) -> Double {
        trackAccents[safe: index] ?? 1.0
    }

    func trackProbability(for index: Int) -> Double {
        trackProbabilities[safe: index] ?? 1.0
    }

    func setTrackAccent(_ value: Double, for index: Int) {
        guard trackAccents.indices.contains(index) else { return }
        objectWillChange.send()
        trackAccents[index] = min(max(value, 0.5), 2)
        persistState()
    }

    func setTrackProbability(_ value: Double, for index: Int) {
        guard trackProbabilities.indices.contains(index) else { return }
        objectWillChange.send()
        trackProbabilities[index] = min(max(value, 0), 1)
        persistState()
    }

    func stepColor(track: Int, step: Int) -> Color {
        guard isValid(track: track, step: step) else {
            return .black.opacity(0.45)
        }

        let event = patternForSlot(displayedPatternSlot)[track][step]
        guard event.isActive else {
            let group = (step / 4) % 2
            return group == 0
                ? Color(red: 0.16, green: 0.16, blue: 0.16).opacity(0.82)
                : Color(red: 0.1, green: 0.1, blue: 0.1).opacity(0.78)
        }

        let chance = 0.35 + (trackProbability(for: track) * 0.65)
        return UITheme.neon.opacity(chance)
    }

    func handleStepTap(track: Int, step: Int) {
        guard isValid(track: track, step: step) else { return }
        selectedStep = step
        toggleStep(track: track, step: step)
    }

    func clearCurrentPhrase() {
        guard steps.indices.contains(selectedTrack) else { return }
        captureClearUndoSnapshot()
        steps[selectedTrack] = Array(repeating: StepEvent(), count: 64)
        syncSelectedSlotPattern()
        persistState()
        statusMessage = "Cleared drum \(selectedTrack + 1) from phrase \(selectedPatternSlot.label)."
    }

    func clearAllPhrases() {
        captureClearUndoSnapshot()
        let empty = Self.makeEmptyPattern()
        steps = empty
        for slot in PatternSlot.allCases {
            slotPatterns[slot.rawValue] = empty
        }
        clearAllFXState()
        persistState()
        statusMessage = "All phrases cleared. All FX turned off."
    }

    /// One-slot undo scoped specifically to Clear/Clear All -- both are single-tap, no
    /// confirmation, and can wipe a track's phrase or every phrase plus all FX at once, so
    /// they're the actions most worth a safety net. Not a general undo history: only the
    /// most recent clear can be undone, and only until another clear happens.
    private struct ClearUndoSnapshot {
        var steps: [[StepEvent]]
        var slotPatterns: [String: [[StepEvent]]]
        var trackActiveFXPresets: [Set<FXPreset>]
        var trackSelectedFXPresets: [FXPreset?]
        var trackFXControlStates: [[FXPreset: FXControlState]]
        var trackFXRuntimeStates: [TrackFXRuntimeState]
        var masterActiveFXPresets: Set<FXPreset>
        var masterSelectedFXPreset: FXPreset?
        var masterFXControlStates: [FXPreset: FXControlState]
        var masterFXRuntimeState: TrackFXRuntimeState
    }

    @Published private(set) var canUndoClear = false
    private var clearUndoSnapshot: ClearUndoSnapshot?

    private func captureClearUndoSnapshot() {
        clearUndoSnapshot = ClearUndoSnapshot(
            steps: steps,
            slotPatterns: slotPatterns,
            trackActiveFXPresets: trackActiveFXPresets,
            trackSelectedFXPresets: trackSelectedFXPresets,
            trackFXControlStates: trackFXControlStates,
            trackFXRuntimeStates: trackFXRuntimeStates,
            masterActiveFXPresets: masterActiveFXPresets,
            masterSelectedFXPreset: masterSelectedFXPreset,
            masterFXControlStates: masterFXControlStates,
            masterFXRuntimeState: masterFXRuntimeState
        )
        canUndoClear = true
    }

    func undoLastClear() {
        guard let snapshot = clearUndoSnapshot else { return }
        steps = snapshot.steps
        slotPatterns = snapshot.slotPatterns
        trackActiveFXPresets = snapshot.trackActiveFXPresets
        trackSelectedFXPresets = snapshot.trackSelectedFXPresets
        trackFXControlStates = snapshot.trackFXControlStates
        trackFXRuntimeStates = snapshot.trackFXRuntimeStates
        masterActiveFXPresets = snapshot.masterActiveFXPresets
        masterSelectedFXPreset = snapshot.masterSelectedFXPreset
        masterFXControlStates = snapshot.masterFXControlStates
        masterFXRuntimeState = snapshot.masterFXRuntimeState

        clearUndoSnapshot = nil
        canUndoClear = false
        syncSelectedTrackFXUIState()
        applyFXSettings()
        persistState()
        statusMessage = "Undid last clear."
    }

    var selectedFXFilterCutoff: Double {
        get { selectedFXControlState?.filterCutoff ?? filterCutoff }
        set { updateSelectedFXControlState { $0.filterCutoff = newValue } }
    }

    var selectedFXDelayMix: Double {
        get { selectedFXControlState?.delayMix ?? delayMix }
        set { updateSelectedFXControlState { $0.delayMix = newValue } }
    }

    var selectedFXReverbMix: Double {
        get { selectedFXControlState?.reverbMix ?? reverbMix }
        set { updateSelectedFXControlState { $0.reverbMix = newValue } }
    }

    var selectedFXStutterAmount: Double {
        get { selectedFXControlState?.stutterAmount ?? stutterAmount }
        set { updateSelectedFXControlState { $0.stutterAmount = newValue } }
    }

    func selectOrEnableFXPreset(_ preset: FXPreset) {
        switch fxEditLayer {
        case .track:
            guard trackActiveFXPresets.indices.contains(selectedTrack) else { return }
            if !trackActiveFXPresets[selectedTrack].contains(preset) {
                trackActiveFXPresets[selectedTrack].insert(preset)
                trackFXControlStates[selectedTrack][preset] = trackFXControlStates[selectedTrack][preset] ?? defaultFXControlState(for: preset)
            }
            trackSelectedFXPresets[selectedTrack] = preset
            rebuildActiveFXChain(for: selectedTrack)
        case .master:
            if !masterActiveFXPresets.contains(preset) {
                masterActiveFXPresets.insert(preset)
                masterFXControlStates[preset] = masterFXControlStates[preset] ?? defaultFXControlState(for: preset)
            }
            masterSelectedFXPreset = preset
            rebuildActiveFXChain()
        }
        statusMessage = fxEditLayer == .master ? "Master FX selected: \(preset.label)." : "FX selected: \(preset.label)."
    }

    func disableFXPreset(_ preset: FXPreset) {
        switch fxEditLayer {
        case .track:
            guard trackActiveFXPresets.indices.contains(selectedTrack),
                  trackActiveFXPresets[selectedTrack].contains(preset)
            else { return }
            trackActiveFXPresets[selectedTrack].remove(preset)
            if trackSelectedFXPresets[selectedTrack] == preset {
                trackSelectedFXPresets[selectedTrack] = FXPreset.allCases.first(where: { trackActiveFXPresets[selectedTrack].contains($0) })
            }
            rebuildActiveFXChain(for: selectedTrack)
        case .master:
            guard masterActiveFXPresets.contains(preset) else { return }
            masterActiveFXPresets.remove(preset)
            if masterSelectedFXPreset == preset {
                masterSelectedFXPreset = FXPreset.allCases.first(where: { masterActiveFXPresets.contains($0) })
            }
            rebuildActiveFXChain()
        }
        statusMessage = fxEditLayer == .master ? "Master FX \(preset.label) removed." : "FX \(preset.rawValue): \(preset.label) removed."
    }

    private func rebuildActiveFXChain(for track: Int? = nil) {
        if let track, trackActiveFXPresets.indices.contains(track) {
            trackFXRuntimeStates[track] = buildFXRuntimeState(for: track)
        } else {
            for index in 0..<trackCount {
                trackFXRuntimeStates[index] = buildFXRuntimeState(for: index)
            }
        }
        masterFXRuntimeState = buildMasterFXRuntimeState()
        syncSelectedTrackFXUIState()
        applyFXSettings()
    }

    private func clearAllFXState() {
        trackActiveFXPresets = Array(repeating: Set<FXPreset>(), count: trackCount)
        trackSelectedFXPresets = Array<FXPreset?>(repeating: nil, count: trackCount)
        trackFXControlStates = Array(repeating: [FXPreset: FXControlState](), count: trackCount)
        trackFXRuntimeStates = Array(repeating: TrackFXRuntimeState(), count: trackCount)
        masterActiveFXPresets.removeAll()
        masterSelectedFXPreset = nil
        masterFXControlStates.removeAll()
        masterFXRuntimeState = TrackFXRuntimeState()
        syncSelectedTrackFXUIState()
        applyFXSettings()
    }

    func isFXPresetActive(_ rawValue: Int) -> Bool {
        guard let preset = FXPreset(rawValue: rawValue) else { return false }
        switch fxEditLayer {
        case .track:
            return trackActiveFXPresets[safe: selectedTrack]?.contains(preset) == true
        case .master:
            return masterActiveFXPresets.contains(preset)
        }
    }

    func isFXPresetSelected(_ rawValue: Int) -> Bool {
        guard let preset = FXPreset(rawValue: rawValue) else { return false }
        switch fxEditLayer {
        case .track:
            return trackSelectedFXPresets[safe: selectedTrack] == preset
        case .master:
            return masterSelectedFXPreset == preset
        }
    }

    private var selectedFXControlState: FXControlState? {
        switch fxEditLayer {
        case .track:
            guard let preset = trackSelectedFXPresets[safe: selectedTrack] ?? nil else { return nil }
            return trackFXControlStates[safe: selectedTrack]?[preset] ?? defaultFXControlState(for: preset)
        case .master:
            guard let preset = masterSelectedFXPreset else { return nil }
            return masterFXControlStates[preset] ?? defaultFXControlState(for: preset)
        }
    }

    private func updateSelectedFXControlState(_ mutate: (inout FXControlState) -> Void) {
        objectWillChange.send()
        switch fxEditLayer {
        case .track:
            guard let preset = trackSelectedFXPresets[safe: selectedTrack] ?? nil else { return }
            var state = trackFXControlStates[selectedTrack][preset] ?? defaultFXControlState(for: preset)
            mutate(&state)
            trackFXControlStates[selectedTrack][preset] = state
            rebuildActiveFXChain(for: selectedTrack)
        case .master:
            guard let preset = masterSelectedFXPreset else { return }
            var state = masterFXControlStates[preset] ?? defaultFXControlState(for: preset)
            mutate(&state)
            masterFXControlStates[preset] = state
            rebuildActiveFXChain()
        }
    }

    private func defaultFXControlState(for preset: FXPreset) -> FXControlState {
        switch preset {
        case .sampleRate:
            return FXControlState(filterCutoff: 900, delayMix: 0, reverbMix: 0, stutterAmount: 0)
        case .bitCrush:
            return FXControlState(filterCutoff: 2_200, delayMix: 0, reverbMix: 0, stutterAmount: 0.1)
        case .distortion:
            return FXControlState(filterCutoff: 8_000, delayMix: 0.08, reverbMix: 0.05, stutterAmount: 0)
        case .delay:
            return FXControlState(filterCutoff: 10_000, delayMix: 0.45, reverbMix: 0.12, stutterAmount: 0)
        case .reverb:
            return FXControlState(filterCutoff: 12_000, delayMix: 0.08, reverbMix: 0.5, stutterAmount: 0)
        case .lowPass:
            return FXControlState(filterCutoff: 1_400, delayMix: 0, reverbMix: 0, stutterAmount: 0)
        case .highPass:
            return FXControlState(filterCutoff: 12_000, delayMix: 0, reverbMix: 0, stutterAmount: 0)
        case .stutter:
            return FXControlState(filterCutoff: 12_000, delayMix: 0, reverbMix: 0, stutterAmount: 0.52)
        case .repeatFX:
            return FXControlState(filterCutoff: 12_000, delayMix: 0.18, reverbMix: 0, stutterAmount: 0.3)
        case .feedback:
            return FXControlState(filterCutoff: 12_000, delayMix: 0.56, reverbMix: 0.08, stutterAmount: 0)
        case .chorus:
            return FXControlState(filterCutoff: 12_000, delayMix: 0.22, reverbMix: 0.05, stutterAmount: 0)
        case .vibrato:
            return FXControlState(filterCutoff: 12_000, delayMix: 0.18, reverbMix: 0, stutterAmount: 0)
        case .shuffle:
            return FXControlState(filterCutoff: 12_000, delayMix: 0, reverbMix: 0, stutterAmount: 0)
        case .phaser:
            return FXControlState(filterCutoff: 4_200, delayMix: 0.06, reverbMix: 0.04, stutterAmount: 0)
        case .gate:
            return FXControlState(filterCutoff: 12_000, delayMix: 0, reverbMix: 0, stutterAmount: 0.72)
        case .width:
            return FXControlState(filterCutoff: 12_000, delayMix: 0.08, reverbMix: 0.08, stutterAmount: 0)
        }
    }

    private func buildFXRuntimeState(for track: Int) -> TrackFXRuntimeState {
        let activePresets = trackActiveFXPresets[track]
        if trackSelectedFXPresets[track] == nil || (trackSelectedFXPresets[track].map { !activePresets.contains($0) } ?? false) {
            trackSelectedFXPresets[track] = FXPreset.allCases.first(where: { activePresets.contains($0) })
        }
        return buildFXRuntimeState(
            activePresets: activePresets,
            controlStates: trackFXControlStates[track],
            shuffleTrack: track
        )
    }

    private func buildMasterFXRuntimeState() -> TrackFXRuntimeState {
        if masterSelectedFXPreset == nil || (masterSelectedFXPreset.map { !masterActiveFXPresets.contains($0) } ?? false) {
            masterSelectedFXPreset = FXPreset.allCases.first(where: { masterActiveFXPresets.contains($0) })
        }
        return buildFXRuntimeState(
            activePresets: masterActiveFXPresets,
            controlStates: masterFXControlStates,
            shuffleTrack: nil
        )
    }

    private func buildFXRuntimeState(
        activePresets: Set<FXPreset>,
        controlStates: [FXPreset: FXControlState],
        shuffleTrack: Int?
    ) -> TrackFXRuntimeState {
        var runtime = TrackFXRuntimeState()

        for preset in FXPreset.allCases where activePresets.contains(preset) {
            let controls = controlStates[preset] ?? defaultFXControlState(for: preset)
            switch preset {
            case .sampleRate:
                runtime.lowPassActive = true
                runtime.lowPassCutoff = min(runtime.lowPassCutoff, controls.filterCutoff)
                runtime.fxRate *= 0.72
                runtime.fxGain *= 1.15
            case .bitCrush:
                runtime.lowPassActive = true
                runtime.lowPassCutoff = min(runtime.lowPassCutoff, controls.filterCutoff)
                runtime.stutterAmount = max(runtime.stutterAmount, controls.stutterAmount)
                runtime.fxRate *= 0.84
                runtime.fxRateJitter = max(runtime.fxRateJitter, 0.12)
                runtime.fxGain *= 1.2
            case .distortion:
                runtime.lowPassActive = true
                runtime.lowPassCutoff = min(runtime.lowPassCutoff, controls.filterCutoff)
                runtime.delayMix = max(runtime.delayMix, controls.delayMix)
                runtime.reverbMix = max(runtime.reverbMix, controls.reverbMix)
                runtime.fxGain *= 1.65
                runtime.fxRateJitter = max(runtime.fxRateJitter, 0.02)
            case .delay:
                runtime.lowPassActive = true
                runtime.delayMix = max(runtime.delayMix, controls.delayMix)
                runtime.reverbMix = max(runtime.reverbMix, controls.reverbMix)
                runtime.lowPassCutoff = min(runtime.lowPassCutoff, controls.filterCutoff)
                runtime.fxEchoRepeats = max(runtime.fxEchoRepeats, 3)
                runtime.fxEchoDelay = max(runtime.fxEchoDelay, 0.09)
                runtime.fxEchoDecay = max(runtime.fxEchoDecay, 0.62)
            case .reverb:
                runtime.reverbMix = max(runtime.reverbMix, controls.reverbMix)
                runtime.delayMix = max(runtime.delayMix, controls.delayMix)
            case .lowPass:
                runtime.lowPassActive = true
                runtime.lowPassCutoff = min(runtime.lowPassCutoff, controls.filterCutoff)
                runtime.fxRate *= 0.9
            case .highPass:
                runtime.highPassActive = true
                runtime.highPassCutoff = max(runtime.highPassCutoff, controls.filterCutoff)
                runtime.fxRate *= 1.2
                runtime.fxGain *= 0.92
            case .stutter:
                runtime.stutterAmount = max(runtime.stutterAmount, controls.stutterAmount)
                runtime.stutterDivisionOverride = 4
                runtime.fxGain *= 1.1
            case .repeatFX:
                runtime.stutterAmount = max(runtime.stutterAmount, controls.stutterAmount)
                runtime.stutterDivisionOverride = 8
                runtime.fxEchoRepeats = max(runtime.fxEchoRepeats, 2)
                runtime.fxEchoDelay = max(runtime.fxEchoDelay, 0.05)
                runtime.fxEchoDecay = max(runtime.fxEchoDecay, 0.7)
            case .feedback:
                runtime.delayMix = max(runtime.delayMix, controls.delayMix)
                runtime.fxEchoRepeats = max(runtime.fxEchoRepeats, 4)
                runtime.fxEchoDelay = max(runtime.fxEchoDelay, 0.075)
                runtime.fxEchoDecay = max(runtime.fxEchoDecay, 0.74)
            case .chorus:
                runtime.delayMix = max(runtime.delayMix, controls.delayMix)
                runtime.reverbMix = max(runtime.reverbMix, controls.reverbMix)
                runtime.fxRateJitter = max(runtime.fxRateJitter, 0.06)
                runtime.fxPanJitter = max(runtime.fxPanJitter, 0.16)
            case .vibrato:
                runtime.lowPassActive = true
                runtime.vibratoEnabled = true
                runtime.delayMix = max(runtime.delayMix, controls.delayMix)
                runtime.fxRateJitter = max(runtime.fxRateJitter, 0.18)
            case .shuffle:
                if let shuffleTrack {
                    setTrackSwing(0.32, for: shuffleTrack)
                }
                runtime.fxPanJitter = max(runtime.fxPanJitter, 0.22)
            case .phaser:
                runtime.lowPassActive = true
                runtime.lfoEnabled = true
                runtime.lowPassCutoff = min(runtime.lowPassCutoff, controls.filterCutoff)
                runtime.fxRateJitter = max(runtime.fxRateJitter, 0.14)
                runtime.fxPanJitter = max(runtime.fxPanJitter, 0.1)
            case .gate:
                runtime.stutterAmount = max(runtime.stutterAmount, controls.stutterAmount)
                runtime.stutterDivisionOverride = 2
                runtime.fxGain *= 0.95
            case .width:
                runtime.delayMix = max(runtime.delayMix, controls.delayMix)
                runtime.reverbMix = max(runtime.reverbMix, controls.reverbMix)
                runtime.fxPanJitter = max(runtime.fxPanJitter, 0.42)
            }
        }

        return runtime
    }

    private func syncSelectedTrackFXUIState() {
        let runtime: TrackFXRuntimeState
        switch fxEditLayer {
        case .track:
            guard trackActiveFXPresets.indices.contains(selectedTrack),
                  trackFXRuntimeStates.indices.contains(selectedTrack)
            else { return }
            activeFXPresets = trackActiveFXPresets[selectedTrack]
            selectedFXPreset = trackSelectedFXPresets[selectedTrack]
            runtime = trackFXRuntimeStates[selectedTrack]
        case .master:
            activeFXPresets = masterActiveFXPresets
            selectedFXPreset = masterSelectedFXPreset
            runtime = masterFXRuntimeState
        }
        if runtime.lowPassActive {
            filterCutoff = runtime.lowPassCutoff
        } else if runtime.highPassActive {
            filterCutoff = runtime.highPassCutoff
        } else {
            filterCutoff = 12_000
        }
        delayMix = runtime.delayMix
        reverbMix = runtime.reverbMix
        stutterAmount = runtime.stutterAmount
    }

    func handlePadTap(index: Int) {
        guard (0..<trackCount).contains(index) else { return }
        selectedTrack = index
        registerDrummerHit(nextLivePadPose, source: .livePad, holdDuration: livePadPoseHold)
        nextLivePadPose = nextLivePadPose == .rightHit ? .leftHit : .rightHit
        triggerSample(index, accent: trackAccents[index])

        if entryMode == .build, isPlaying {
            selectedStep = visualState.currentStep
            steps[index][visualState.currentStep].isActive = true
            syncSelectedSlotPattern()
            persistState()
        }
    }

    func loadDrumPack(from urls: [URL]) {
        let wavURLs = orderedDrumPackURLs(from: resolvedWAVURLs(from: urls))

        guard !wavURLs.isEmpty else {
            statusMessage = "No WAV files found. Select WAV files or a folder containing them."
            return
        }

        let selectedURLs = Array(wavURLs.prefix(trackCount))
        let copyResult = copyDrumPackToSandbox(urls: selectedURLs)
        guard !copyResult.copiedURLs.isEmpty else {
            if !copyResult.oversizedFileNames.isEmpty {
                statusMessage = "No WAV files were imported. Some files were too large."
            } else if !copyResult.failedFileNames.isEmpty {
                statusMessage = "No WAV files were imported. Some files could not be read."
            } else {
                statusMessage = "Could not import the selected drum pack."
            }
            return
        }

        let builtInURLs = exportBuiltInDrumPackWAVs(specs: Self.defaultDrumSpecs)
        let missingCount = max(0, trackCount - copyResult.copiedURLs.count)
        let paddedURLs = copyResult.copiedURLs + builtInURLs.dropFirst(copyResult.copiedURLs.count).prefix(missingCount)
        let paddedNames = copyResult.copiedURLs.map { $0.deletingPathExtension().lastPathComponent }
            + Self.defaultDrumSpecs.dropFirst(copyResult.copiedURLs.count).prefix(missingCount).map(\.name)

        let fallbackTracks = applyDrumPack(from: paddedURLs, names: paddedNames)
        var messageParts: [String] = []
        if wavURLs.count > trackCount {
            messageParts.append("Warning: drum pack has \(wavURLs.count) WAV files, more than the required 16.")
            messageParts.append("Loaded the first \(trackCount) WAVs and ignored the rest.")
        } else if wavURLs.count < trackCount {
            messageParts.append("Warning: drum pack has only \(wavURLs.count) WAV files, fewer than the required 16.")
            messageParts.append("Loaded your WAVs and filled the remaining slots with built-in sounds.")
        } else {
            messageParts.append("Loaded all 16 WAV files.")
        }
        if !copyResult.failedFileNames.isEmpty {
            messageParts.append("Some files could not be copied and were skipped.")
        }
        if !copyResult.oversizedFileNames.isEmpty {
            messageParts.append("Some files were too large and were skipped.")
        }
        if missingCount > 0, wavURLs.count >= trackCount {
            messageParts.append("Missing slots were filled with built-in sounds.")
        }
        if !fallbackTracks.isEmpty {
            let list = fallbackTracks.map(String.init).joined(separator: ", ")
            messageParts.append("Tracks \(list) had bad audio and were replaced with built-in samples.")
        }
        statusMessage = messageParts.joined(separator: " ")
    }

    @discardableResult
    private func applyDrumPack(from urls: [URL], names: [String]) -> [Int] {
        guard urls.count == trackCount, names.count == trackCount else { return [] }
        var fallbackURLs: [URL] = []
        var replacedTracks: [Int] = []

        for (index, url) in urls.enumerated() {
            sampleNames[index] = names[index]
            sampleURLs[index] = url
            sampleAssets[index] = nil
            sampleRenderCache[index] = nil
            configureTrackSample(for: index, url: url)

            if sampleAssets[index] == nil {
                if fallbackURLs.isEmpty {
                    fallbackURLs = exportBuiltInDrumPackWAVs(specs: Self.defaultDrumSpecs)
                }
                if fallbackURLs.indices.contains(index) {
                    sampleURLs[index] = fallbackURLs[index]
                    configureTrackSample(for: index, url: fallbackURLs[index])
                    if sampleAssets[index] != nil {
                        replacedTracks.append(index + 1)
                    }
                }
            }
        }
        return replacedTracks
    }

    private func loadBuiltInDrumPack() {
        let specs = Self.defaultDrumSpecs
        guard specs.count == trackCount else { return }
        let urls = exportBuiltInDrumPackWAVs(specs: specs)
        guard urls.count == trackCount else {
            statusMessage = "Could not build default drum pack."
            return
        }

        applyDrumPack(from: urls, names: specs.map(\.name))
        statusMessage = "Built-in 16 drum WAVs loaded. You can also replace them with your own pack."
    }

    @discardableResult
    private func exportBuiltInDrumPackWAVs(specs: [(name: String, duration: Double)]) -> [URL] {
        let bundledURLs = Self.bundledDrumPackURLs()
        if bundledURLs.count == trackCount {
            return bundledURLs
        }

        statusMessage = "Built-in WAV resources are missing from the app bundle."
        return []
    }

    private func resolvedWAVURLs(from urls: [URL]) -> [URL] {
        let fileManager = FileManager.default
        var wavs: [URL] = []

        for url in urls {
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                if let children = try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                    wavs.append(contentsOf: children.filter {
                        $0.pathExtension.lowercased() == "wav" && !$0.lastPathComponent.hasPrefix(".")
                    })
                }
            } else if url.pathExtension.lowercased() == "wav", !url.lastPathComponent.hasPrefix(".") {
                wavs.append(url)
            }
        }

        let unique = Dictionary(grouping: wavs, by: \.standardizedFileURL).compactMap { $0.value.first }
        return unique.sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
    }

    private func orderedDrumPackURLs(from urls: [URL]) -> [URL] {
        guard !urls.isEmpty else { return [] }

        let slotAliases: [[String]] = [
            ["bass drum", "kick", "bd"],
            ["snare drum", "snare"],
            ["closed hi hat", "closed hat", "closed hihat", "chh"],
            ["open hi hat", "open hat", "open hihat", "ohh"],
            ["808", "synthesized snare", "synth snare"],
            ["sticks", "stick", "clave", "rim"],
            ["cymbal", "crash", "cymbol", "ride"],
            ["noise", "scratch", "scratch record", "fx"],
            ["hand clap", "clap"],
            ["click", "perc", "percussion"],
            ["low tom", "low tom", "low tom", "lowtom"],
            ["hi tom", "hi tom", "high tom", "hi-tom", "hitom"],
            ["cow bell", "cowbell"],
            ["blip", "bleep"],
            ["tone"],
            ["bass tone", "synth bass", "bass", "sub"],
        ]

        func normalizedName(_ url: URL) -> String {
            url.deletingPathExtension()
                .lastPathComponent
                .lowercased()
                .replacingOccurrences(of: "-", with: " ")
                .replacingOccurrences(of: "_", with: " ")
        }

        func score(name: String, aliases: [String]) -> Int {
            var best = 0
            for alias in aliases {
                if name == alias {
                    best = max(best, 100)
                } else if name.contains(alias) {
                    best = max(best, 60 + alias.count)
                }
            }
            return best
        }

        let normalized = urls.map { ($0, normalizedName($0)) }
        var used = Set<URL>()
        var ordered: [URL] = []

        for aliases in slotAliases {
            let bestMatch = normalized
                .filter { !used.contains($0.0) }
                .map { ($0.0, score(name: $0.1, aliases: aliases)) }
                .filter { $0.1 > 0 }
                .sorted {
                    if $0.1 == $1.1 {
                        return $0.0.lastPathComponent.localizedCaseInsensitiveCompare($1.0.lastPathComponent) == .orderedAscending
                    }
                    return $0.1 > $1.1
                }
                .first

            if let match = bestMatch {
                ordered.append(match.0)
                used.insert(match.0)
            }
        }

        let leftovers = urls.filter { !used.contains($0) }
        return ordered + leftovers
    }

    func togglePlayback() {
        isPlaying ? stopPlayback() : startPlayback()
    }

    func handleAppBecameActive() {
        recoverAudioIfNeeded()
    }

    func handleAppEnteredBackground() {
        visualState.setIsAnyVoicePlaying(false)
        playbackVisualWorkItem?.cancel()
        resetDrummerPose()
        stopAllVoices()
        flushPersistedStateIfNeeded()
        if playbackEngineConfigured {
            playbackEngine.pause()
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    func toggleRecording() {
        isRecording ? stopRecordingSession() : startRecordingSession()
    }

    func exportRecordingToWAV() {
        if isRecording {
            stopRecordingSession()
        }

        let hits = recordedHits.isEmpty ? renderHitsForCurrentArrangement() : recordedHits
        guard !hits.isEmpty else {
            statusMessage = "Nothing to export yet. Record a take or program a pattern first."
            return
        }

        guard let exportedWAV = makeRecordingWAV(from: hits) else {
            statusMessage = "Could not export the WAV file."
            return
        }

        if !recordedHits.isEmpty {
            hasPendingRecording = false
        }
        self.exportedWAV = exportedWAV
        statusMessage = "Choose where to save your WAV and rename it if you want."
    }

    func stopPlayback() {
        sequencerWorkItem?.cancel()
        sequencerWorkItem = nil
        clockGeneration += 1
        visualState.currentStep = 0
        isPlaying = false
        currentPlaybackSlot = selectedPatternSlot
        stopAllVoices()
        resetDrummerPose()
        refreshPlaybackVisualState()
    }

    private func startPlayback() {
        visualState.currentStep = 0
        syncSelectedSlotPattern()
        playbackPhraseOrder = computePlaybackPhraseOrder()
        playbackPhraseIndex = 0
        currentPlaybackSlot = playbackPhraseOrder.first ?? .a
        isPlaying = true
        clockGeneration += 1
        nextStepDeadline = CACurrentMediaTime() + schedulerLeadIn
        scheduleNextStep()
    }

    /// A 16th note at the current tempo. Read fresh every time a deadline is advanced
    /// (never cached), so a live bpm change takes effect at the next step boundary.
    private var stepDuration: TimeInterval {
        max(60.0 / bpm / 4.0, 0.02)
    }

    private func startRecordingSession() {
        recordedHits.removeAll()
        recordingStartTime = CACurrentMediaTime()
        isRecording = true
        hasPendingRecording = false
        statusMessage = isPlaying
            ? "Recording started. Live drums and the playing sequence will be captured."
            : "Recording started. Tap pads or press play to capture a take."
    }

    private func stopRecordingSession() {
        isRecording = false
        if recordedHits.isEmpty {
            hasPendingRecording = false
            statusMessage = "Recording stopped. No audio was captured."
        } else {
            hasPendingRecording = true
            statusMessage = "Recording stopped. \(recordedHits.count) hits are ready to export as WAV."
        }
    }

    /// Wakes schedulerLookahead seconds before nextStepDeadline (not at it), so there's
    /// always a small cushion for scheduleAudioTime-based playback to reach CoreAudio
    /// before the moment it's meant to sound -- even if this wakeup itself lands a couple
    /// milliseconds late under main-thread contention, the audio onset stays exact.
    private func scheduleNextStep() {
        let generation = clockGeneration
        let now = CACurrentMediaTime()
        if nextStepDeadline < now - 1.0 {
            // The app was backgrounded, debugger-paused, or otherwise stalled long enough
            // that catching up step-by-step would fire a burst of stale hits all at once.
            // There's no meaningful phase to preserve after a gap that large -- just resume
            // playing forward from now, the same way any hardware drum machine would.
            nextStepDeadline = now + schedulerLeadIn
        }
        let fireTime = nextStepDeadline - schedulerLookahead
        let delay = max(fireTime - now, 0)
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.clockGeneration == generation, self.isPlaying else { return }
            let deadline = self.nextStepDeadline
            self.nextStepDeadline += self.stepDuration
            self.advanceStep(deadline: deadline)
            if self.isPlaying {
                self.scheduleNextStep()
            }
        }

        sequencerWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    /// `deadline` is the exact, drift-free instant this step is meant to sound. Every
    /// triggerSample/triggerMetronome call below is handed that instant (plus any swing
    /// offset) as its scheduledTime, so the actual audio onset is scheduled precisely on
    /// CoreAudio's clock regardless of when this function itself happened to run.
    private func advanceStep(deadline: CFTimeInterval) {
        let step = visualState.currentStep
        let length = sequenceLength.rawValue
        let activeSlot = playbackPhraseOrder[safe: playbackPhraseIndex] ?? .a
        let activePattern = patternForSlot(activeSlot)
        let currentStepDuration = stepDuration
        var didTriggerStepHit = false

        if isMetronomeEnabled, step % 4 == 0 {
            triggerMetronome(downbeat: step % 16 == 0, scheduledTime: deadline)
        }

        applyDynamicFX(at: step, patternLength: length)

        for track in 0..<trackCount {
            let event = activePattern[track][step]
            guard event.isActive else { continue }
            if Double.random(in: 0 ... 1) <= trackProbabilities[track] {
                didTriggerStepHit = true
                let gate = gateValue(for: step, track: track)
                let swing = trackSwings[track]
                let swingOffset = (swing > 0 && !step.isMultiple(of: 2)) ? currentStepDuration * swing * 0.5 : 0
                triggerSample(track, accent: trackAccents[track], gate: gate, scheduledTime: deadline + swingOffset)
            }
        }

        if didTriggerStepHit {
            registerDrummerHit(
                drummerPoseForStep(step),
                source: .sequencer,
                holdDuration: sequencerPoseHoldDuration(for: currentStepDuration)
            )
        }

        if step + 1 >= length {
            visualState.currentStep = 0
            let nextOrder = computePlaybackPhraseOrder()
            if !nextOrder.isEmpty {
                playbackPhraseOrder = nextOrder
                playbackPhraseIndex = (playbackPhraseIndex + 1) % nextOrder.count
                currentPlaybackSlot = playbackPhraseOrder[playbackPhraseIndex]
            }
        } else {
            visualState.currentStep = step + 1
        }
    }

    private func applyDynamicFX(at step: Int, patternLength: Int) {
        for track in 0..<trackCount {
            guard trackFXRuntimeStates.indices.contains(track) else { continue }
            var runtime = buildFXRuntimeState(for: track)

            // Phaser's own sweep is driven by lfoEnabled below (phaser is the only preset
            // that sets it); this is the single authoritative sweep for it.
            if runtime.lfoEnabled {
                let phase = (Double(step) / Double(max(patternLength, 1))) * .pi * 2
                let lfo = (sin(phase) + 1.0) * 0.5
                runtime.lowPassCutoff = 1_200 + lfo * 8_000
            }

            trackFXRuntimeStates[track] = runtime
            applyLiveTrackFXChain(for: track)
        }

        if masterActiveFXPresets.contains(.highPass) {
            masterHighPassSweepPhase += 0.12
            let sweep = (sin(masterHighPassSweepPhase) + 1.0) * 0.5
            masterFXRuntimeState.highPassActive = true
            masterFXRuntimeState.highPassCutoff = 7_000 + sweep * 4_500
            applyLiveMasterFXChain()
        }

        syncSelectedTrackFXUIState()
    }

    /// Converts a CACurrentMediaTime()-based instant to an absolute AVAudioTime. Both clocks
    /// are seconds against the same host clock origin (device boot), so this is a pure unit
    /// conversion with no extra offset math -- the standard bridge between CoreAnimation-style
    /// timestamps and AVAudioEngine's render-thread-accurate scheduling.
    private static func avAudioTime(atSeconds seconds: CFTimeInterval) -> AVAudioTime {
        AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: seconds))
    }

    /// `scheduledTime` is an absolute CACurrentMediaTime-based deadline for the sequencer's
    /// phase-locked steps; nil means "play immediately" (live pad taps). Passing a future
    /// scheduledTime lets playVoice hand CoreAudio a precise AVAudioTime instead of playing
    /// on the calling thread's schedule, so swing offsets and echo repeats no longer need
    /// their own asyncAfter timers -- they're just later scheduledTime values, scheduled now.
    private func triggerSample(_ index: Int, accent: Double, gate: Double = 1.0, rateMultiplier: Double = 1.0, dryPreview: Bool = false, scheduledTime: CFTimeInterval? = nil) {
        guard sampleAssets.indices.contains(index), sampleAssets[index] != nil else {
            return
        }
        registerPlaybackActivity(minimumDuration: 0.16)
        pulsePad(index)
        playVoice(index: index, accent: accent, gate: gate, echoDepth: 0, rateMultiplier: rateMultiplier, dryPreview: dryPreview, scheduledTime: scheduledTime)
        if !dryPreview {
            midiEngine.trigger(padIndex: index, accent: accent, scheduledTime: scheduledTime)
        }

        let runtime = fxRuntimeState(for: index)
        guard !dryPreview, fxApplies(to: index), runtime.fxEchoRepeats > 0 else { return }
        let baseTime = scheduledTime ?? CACurrentMediaTime()
        for repeatIndex in 1...runtime.fxEchoRepeats {
            let attenuated = accent * pow(runtime.fxEchoDecay, Double(repeatIndex))
            let repeatTime = baseTime + (runtime.fxEchoDelay * Double(repeatIndex))
            playVoice(index: index, accent: attenuated, gate: gate, echoDepth: repeatIndex, rateMultiplier: rateMultiplier, dryPreview: false, scheduledTime: repeatTime)
        }
    }

    private func playVoice(index: Int, accent: Double, gate: Double = 1.0, echoDepth: Int, rateMultiplier: Double = 1.0, dryPreview: Bool = false, scheduledTime: CFTimeInterval? = nil) {
        startPlaybackEngineIfNeeded()
        guard voicePools.indices.contains(index),
              !voicePools[index].isEmpty
        else { return }

        let settings = voicePlaybackSettings(
            track: index,
            accent: accent,
            gate: gate,
            repeatIndex: echoDepth,
            dryPreview: dryPreview,
            panRandomizer: { Double.random(in: -1...1) },
            rateRandomizer: { Double.random(in: -1...1) }
        )
        guard settings.rate.isFinite else { return }

        let onsetTime = scheduledTime ?? CACurrentMediaTime()
        let audioTime = scheduledTime.map(Self.avAudioTime(atSeconds:))
        captureRecordedHit(track: index, volume: settings.volume, pan: settings.pan, rate: settings.rate, at: onsetTime)
        applyChokeGroup(for: index)
        guard let voice = allocateVoice(for: index) else { return }
        let useProcessedPlayback = shouldUseProcessedPlayback(track: index, requestedRate: settings.rate, dryPreview: dryPreview)
        // A new onset is about to be scheduled on this exact voice, so there's nothing to
        // declick -- fading here would just get cancelled by the next stop() anyway.
        voice.stop(declick: false)
        voice.trackIndex = index
        voice.chokeGroup = chokeGroups[safe: index] ?? nil
        voice.playbackRate = useProcessedPlayback ? settings.rate : 1.0
        voice.player.volume = Float(min(max(settings.volume, 0), 1))
        voice.player.pan = Float(min(max(settings.pan, -1), 1))
        voice.varispeed.rate = Float(min(max(voice.playbackRate, 0.5), 2.0))
        voice.isActive = true
        voice.startedAt = onsetTime
        if useProcessedPlayback {
            guard let buffer = processedPlaybackBuffer(for: index) else {
                voice.stop()
                return
            }
            let duration = Double(buffer.frameLength) / buffer.format.sampleRate / max(settings.rate, 0.5)
            voice.expectedEndTime = onsetTime + duration
            voice.player.scheduleBuffer(buffer, at: audioTime, options: [])
            voice.player.play()
            markVoicePlayback(duration: duration, startingAt: onsetTime)
            return
        }

        guard let asset = sampleAssets[safe: index] ?? nil,
              let file = cachedAudioFile(for: index)
        else {
            voice.stop()
            return
        }
        file.framePosition = 0
        let duration = max(asset.duration, 0.05)
        voice.expectedEndTime = onsetTime + duration
        voice.player.scheduleFile(file, at: audioTime, completionHandler: nil)
        voice.player.play()

        markVoicePlayback(duration: duration, startingAt: onsetTime)
    }

    private func captureRecordedHit(track: Int, volume: Double, pan: Double, rate: Double, at onsetTime: CFTimeInterval) {
        guard isRecording, !isRenderingExport else { return }
        let timestamp = max(onsetTime - recordingStartTime, 0)
        recordedHits.append(
            RecordedHit(
                time: timestamp,
                track: track,
                volume: max(volume, 0),
                pan: min(max(pan, -1), 1),
                rate: min(max(rate, 0.5), 2.0)
            )
        )
    }

    private func shouldUseProcessedPlayback(track: Int, requestedRate: Double, dryPreview: Bool) -> Bool {
        if dryPreview {
            return false
        }
        if fxApplies(to: track) {
            return true
        }
        if abs(trackTunes[track]) > 0.0001 {
            return true
        }
        return abs(requestedRate - 1.0) > 0.0001
    }

    private func applyChokeGroup(for track: Int) {
        guard let chokeGroup = chokeGroups[safe: track] ?? nil else { return }
        for (otherTrack, group) in chokeGroups.enumerated() where group == chokeGroup {
            for voice in voicePools[safe: otherTrack] ?? [] where voice.isActive {
                // A choke is always immediately followed by a new onset on the triggering
                // track within this same call, so the incoming transient masks any click
                // from cutting instantly -- no need for the declick ramp here, and skipping
                // it is what makes same-pad retriggering read as a tight, instant cutoff
                // instead of an audible overlap with the dying previous hit.
                voice.stop(declick: false)
            }
        }
    }

    private func fxApplies(to index: Int) -> Bool {
        (trackActiveFXPresets[safe: index]?.isEmpty == false) || !masterActiveFXPresets.isEmpty
    }

    private func fxRuntimeState(for index: Int) -> TrackFXRuntimeState {
        var runtime = trackFXRuntimeStates[safe: index] ?? TrackFXRuntimeState()
        let master = masterFXRuntimeState
        runtime.delayMix = max(runtime.delayMix, master.delayMix)
        runtime.reverbMix = max(runtime.reverbMix, master.reverbMix)
        runtime.stutterAmount = max(runtime.stutterAmount, master.stutterAmount)
        runtime.fxGain *= master.fxGain
        runtime.fxRate *= master.fxRate
        runtime.fxRateJitter = max(runtime.fxRateJitter, master.fxRateJitter)
        runtime.fxEchoRepeats = max(runtime.fxEchoRepeats, master.fxEchoRepeats)
        runtime.fxEchoDelay = max(runtime.fxEchoDelay, master.fxEchoDelay)
        runtime.fxEchoDecay = max(runtime.fxEchoDecay, master.fxEchoDecay)
        runtime.fxPanJitter = max(runtime.fxPanJitter, master.fxPanJitter)
        if !masterActiveFXPresets.isEmpty {
            if master.lowPassActive {
                runtime.lowPassActive = true
                runtime.lowPassCutoff = min(runtime.lowPassCutoff, master.lowPassCutoff)
            }
            if master.highPassActive {
                runtime.highPassActive = true
                runtime.highPassCutoff = max(runtime.highPassCutoff, master.highPassCutoff)
            }
            runtime.lfoEnabled = runtime.lfoEnabled || master.lfoEnabled
            runtime.vibratoEnabled = runtime.vibratoEnabled || master.vibratoEnabled
            if let division = master.stutterDivisionOverride {
                runtime.stutterDivisionOverride = division
            }
        }
        return runtime
    }

    private func pulsePad(_ index: Int) {
        guard triggerPulseToken.indices.contains(index) else { return }
        triggerPulseToken[index] += 1
        let token = triggerPulseToken[index]
        visualState.setPadTriggered(true, for: index)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self else { return }
            guard self.triggerPulseToken.indices.contains(index),
                  self.triggerPulseToken[index] == token else { return }
            self.visualState.setPadTriggered(false, for: index)
        }
    }

    private func triggerMetronome(downbeat: Bool, scheduledTime: CFTimeInterval? = nil) {
        guard isMetronomeEnabled else { return }
        startPlaybackEngineIfNeeded()
        let voice = downbeat ? metronomeHighVoice : metronomeLowVoice
        let buffer = downbeat ? metronomeHighBuffer : metronomeLowBuffer
        guard let voice, let buffer else { return }
        registerPlaybackActivity(minimumDuration: 0.08)
        voice.stop()
        voice.volume = Float(metronomeVolume)
        let audioTime = scheduledTime.map(Self.avAudioTime(atSeconds:))
        voice.scheduleBuffer(buffer, at: audioTime, options: [])
        voice.play()
    }

    private func toggleStep(track: Int, step: Int) {
        guard isValid(track: track, step: step) else {
            return
        }

        steps[track][step].isActive.toggle()
        syncSelectedSlotPattern()
        persistState()
    }

    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            // Match the hardware I/O rate to renderSampleRate so processed voices, exports,
            // and live playback all share one sample rate and avoid an extra implicit SRC pass.
            try session.setPreferredSampleRate(renderSampleRate)
            try session.setPreferredIOBufferDuration(0.005)
            try session.setActive(true)
        } catch {
            statusMessage = "Audio session failed to start."
        }
    }

    private func recoverAudioIfNeeded() {
        // Metronome buffers are plain in-memory PCM data with no audio-session dependency,
        // and the metronome's player nodes stay attached to playbackEngine across
        // interruptions, so neither needs to be rebuilt here the way the old
        // AVAudioPlayer-based metronome required.
        configureAudioSession()
        startPlaybackEngineIfNeeded()
        refreshVoicePools()
        refreshPlaybackVisualState()
    }

    private func startPlaybackMonitor() {
        playbackMonitorTimer?.invalidate()
        playbackMonitorTimer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshPlaybackVisualState()
            }
        }
        RunLoop.main.add(playbackMonitorTimer!, forMode: .common)
    }

    private func markVoicePlayback(duration: TimeInterval, startingAt: CFTimeInterval = CACurrentMediaTime()) {
        let now = CACurrentMediaTime()
        let safeDuration = max(duration.isFinite ? duration : 0, 0.12)
        playbackVisualDeadline = max(playbackVisualDeadline, startingAt + safeDuration + 0.04)
        visualState.setIsAnyVoicePlaying(true)

        playbackVisualWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.refreshPlaybackVisualState()
        }
        playbackVisualWorkItem = workItem
        let fireDelay = max(startingAt + safeDuration + 0.05 - now, 0.01)
        DispatchQueue.main.asyncAfter(deadline: .now() + fireDelay, execute: workItem)
    }

    private func registerPlaybackActivity(minimumDuration: TimeInterval) {
        let now = CACurrentMediaTime()
        playbackVisualDeadline = max(playbackVisualDeadline, now + max(minimumDuration, 0.08))
        visualState.setIsAnyVoicePlaying(true)
    }

    private func registerDrummerHit(_ pose: DrummerPose, source: DrummerPoseSource, holdDuration: CFTimeInterval) {
        let now = CACurrentMediaTime()
        let deadline = now + max(holdDuration, minDrummerPoseHold)

        switch source {
        case .sequencer:
            sequencerPoseState.pose = pose
            sequencerPoseState.updatedAt = now
            sequencerPoseState.deadline = deadline
        case .livePad:
            livePadPoseState.pose = pose
            livePadPoseState.updatedAt = now
            livePadPoseState.deadline = deadline
        }

        refreshDrummerPose()
    }

    private func refreshDrummerPose() {
        let now = CACurrentMediaTime()
        let sequencerVisibleUntil = sequencerPoseState.deadline
        let livePadVisibleUntil = livePadPoseState.deadline + livePadRestGrace

        if sequencerVisibleUntil <= now {
            sequencerPoseState.pose = .rest
        }

        if livePadVisibleUntil <= now {
            livePadPoseState.pose = .rest
        }

        var activeStates: [DrummerPoseState] = []
        if sequencerPoseState.pose != .rest, sequencerVisibleUntil > now {
            activeStates.append(sequencerPoseState)
        }
        if livePadPoseState.pose != .rest, livePadVisibleUntil > now {
            var paddedState = livePadPoseState
            paddedState.deadline = livePadVisibleUntil
            activeStates.append(paddedState)
        }
        let resolvedPose = activeStates.max(by: { $0.updatedAt < $1.updatedAt })?.pose ?? .rest
        visualState.setDrummerPose(resolvedPose)

        drummerPoseWorkItem?.cancel()
        guard let nextDeadline = activeStates.map(\.deadline).min() else { return }

        let workItem = DispatchWorkItem { [weak self] in
            self?.refreshDrummerPose()
        }
        drummerPoseWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + max(nextDeadline - now, 0.01), execute: workItem)
    }

    private func resetDrummerPose() {
        drummerPoseWorkItem?.cancel()
        sequencerPoseState = DrummerPoseState()
        livePadPoseState = DrummerPoseState()
        nextLivePadPose = .rightHit
        visualState.setDrummerPose(.rest)
    }

    private func drummerPoseForStep(_ step: Int) -> DrummerPose {
        step.isMultiple(of: 2) ? .rightHit : .leftHit
    }

    private func sequencerPoseHoldDuration(for stepDuration: CFTimeInterval) -> CFTimeInterval {
        min(max(stepDuration * 0.95, minDrummerPoseHold), maxDrummerPoseHold)
    }

    private func refreshPlaybackVisualState() {
        let now = CACurrentMediaTime()
        let shouldStayActive = hasAnyAudiblePlayback() || now < playbackVisualDeadline
        // This function is driven by a 30ms timer that runs continuously for the app's
        // whole lifetime; setIsAnyVoicePlaying only actually publishes on a real
        // transition, so idle periods don't cost a re-render 33 times a second.
        visualState.setIsAnyVoicePlaying(shouldStayActive)

        playbackVisualWorkItem?.cancel()
        guard shouldStayActive else { return }

        let workItem = DispatchWorkItem { [weak self] in
            self?.refreshPlaybackVisualState()
        }
        playbackVisualWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: workItem)
    }

    private func hasAnyAudiblePlayback() -> Bool {
        // The metronome's nodes only exist once the engine graph is configured (same as
        // drum voices), so nothing can be audible before that.
        guard playbackEngineConfigured else { return false }
        cleanupAllInactiveVoices()
        if voicePools.flatMap({ $0 }).contains(where: { voice in
            voice.isActive || voice.player.isPlaying
        }) {
            return true
        }
        if metronomeHighVoice?.isPlaying == true || metronomeLowVoice?.isPlaying == true {
            return true
        }
        return false
    }

    private func configurePlaybackEngineIfNeeded() {
        guard !playbackEngineConfigured else { return }

        setUpFXUnit(masterDistortionUnit, on: playbackEngine)
        setUpFXUnit(masterEQUnit, on: playbackEngine)
        setUpFXUnit(masterReverbUnit, on: playbackEngine)
        playbackEngine.attach(masterFXInputMixer)
        playbackEngine.connect(masterFXInputMixer, to: masterDistortionUnit, format: nil)
        playbackEngine.connect(masterDistortionUnit, to: masterEQUnit, format: nil)
        playbackEngine.connect(masterEQUnit, to: masterReverbUnit, format: nil)
        playbackEngine.connect(masterReverbUnit, to: playbackEngine.mainMixerNode, format: nil)

        for track in 0..<trackCount {
            let trackInputMixer = AVAudioMixerNode()
            let distortion = AVAudioUnitDistortion()
            let eq = AVAudioUnitEQ(numberOfBands: 2)
            let reverb = AVAudioUnitReverb()
            setUpFXUnit(distortion, on: playbackEngine)
            setUpFXUnit(eq, on: playbackEngine)
            setUpFXUnit(reverb, on: playbackEngine)
            playbackEngine.attach(trackInputMixer)

            var pool: [DrumVoice] = []
            for _ in 0..<voicesPerTrack {
                let voice = DrumVoice()
                playbackEngine.attach(voice.player)
                playbackEngine.attach(voice.varispeed)
                playbackEngine.connect(voice.player, to: voice.varispeed, format: nil)
                playbackEngine.connect(voice.varispeed, to: trackInputMixer, format: nil)
                pool.append(voice)
            }
            voicePools[track] = pool

            playbackEngine.connect(trackInputMixer, to: distortion, format: nil)
            playbackEngine.connect(distortion, to: eq, format: nil)
            playbackEngine.connect(eq, to: reverb, format: nil)
            playbackEngine.connect(reverb, to: masterFXInputMixer, format: nil)

            trackFXInputMixers.append(trackInputMixer)
            trackDistortionUnits.append(distortion)
            trackEQUnits.append(eq)
            trackReverbUnits.append(reverb)
        }

        let highVoice = AVAudioPlayerNode()
        let lowVoice = AVAudioPlayerNode()
        playbackEngine.attach(highVoice)
        playbackEngine.attach(lowVoice)
        playbackEngine.connect(highVoice, to: playbackEngine.mainMixerNode, format: nil)
        playbackEngine.connect(lowVoice, to: playbackEngine.mainMixerNode, format: nil)
        metronomeHighVoice = highVoice
        metronomeLowVoice = lowVoice

        playbackEngineConfigured = true
        // In case any FX presets were toggled before the graph existed (e.g. before the
        // first pad tap), sync the freshly-built nodes to the current state immediately
        // rather than leaving them in their default bypassed state until the next change.
        applyFXSettings()
    }

    /// Attaches an effect unit and puts it in its resting (bypassed, neutral) state.
    /// applyLiveTrackFXChain/applyLiveMasterFXChain turn individual stages back on as
    /// presets are activated; distortion and reverb factory presets are loaded once here
    /// since the preset choice itself never changes, only whether it's bypassed and how wet.
    private func setUpFXUnit(_ unit: AVAudioUnit, on engine: AVAudioEngine) {
        engine.attach(unit)
        switch unit {
        case let distortion as AVAudioUnitDistortion:
            distortion.loadFactoryPreset(.multiBrokenSpeaker)
            distortion.wetDryMix = 0
            distortion.bypass = true
        case let eq as AVAudioUnitEQ:
            guard eq.bands.count >= 2 else { break }
            eq.bands[0].filterType = .lowPass
            eq.bands[0].frequency = 20_000
            eq.bands[0].bandwidth = 0.5
            eq.bands[0].bypass = true
            eq.bands[1].filterType = .highPass
            eq.bands[1].frequency = 20
            eq.bands[1].bandwidth = 0.5
            eq.bands[1].bypass = true
            eq.bypass = true
        case let reverb as AVAudioUnitReverb:
            reverb.loadFactoryPreset(.mediumHall)
            reverb.wetDryMix = 0
            reverb.bypass = true
        default:
            break
        }
    }

    private func startPlaybackEngineIfNeeded() {
        configurePlaybackEngineIfNeeded()
        guard !playbackEngine.isRunning else { return }
        do {
            playbackEngine.prepare()
            try playbackEngine.start()
        } catch {
            statusMessage = "Playback engine failed to start."
        }
    }

    private func stopAllVoices() {
        guard playbackEngineConfigured else { return }
        voicePools.flatMap { $0 }.forEach { $0.stop() }
        metronomeHighVoice?.stop()
        metronomeLowVoice?.stop()
    }

    private func cleanupAllInactiveVoices() {
        guard playbackEngineConfigured else { return }
        for index in 0..<trackCount {
            cleanupInactiveVoices(for: index)
        }
    }

    private func cleanupInactiveVoices(for index: Int) {
        guard voicePools.indices.contains(index) else { return }
        let now = CACurrentMediaTime()
        for voice in voicePools[index] where voice.isActive {
            if !voice.player.isPlaying || voice.expectedEndTime <= now {
                voice.stop()
            }
        }
    }

    private func allocateVoice(for index: Int) -> DrumVoice? {
        guard voicePools.indices.contains(index) else { return nil }
        cleanupInactiveVoices(for: index)
        if let freeVoice = voicePools[index].first(where: { !$0.isActive }) {
            return freeVoice
        }
        return voicePools[index].min(by: { $0.startedAt < $1.startedAt })
    }

    private func refreshVoicePools() {
        for index in 0..<trackCount {
            guard let url = sampleURLs[safe: index] ?? nil else { continue }
            configureTrackSample(for: index, url: url)
            refreshActivePlayers(for: index)
        }
    }

    private func registerAudioObservers() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            guard
                let userInfo = notification.userInfo,
                let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
                let type = AVAudioSession.InterruptionType(rawValue: typeValue)
            else {
                return
            }

            if type == .ended {
                Task { @MainActor in
                    self.recoverAudioIfNeeded()
                }
            }
        }

        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.recoverAudioIfNeeded()
            }
        }
    }

    private func applyFXSettings() {
        for index in 0..<trackCount {
            refreshActivePlayers(for: index)
            applyLiveTrackFXChain(for: index)
        }
        applyLiveMasterFXChain()
    }

    /// Pushes track's current TrackFXRuntimeState into its live distortion/EQ/reverb nodes.
    /// This is what makes Distortion, Low Pass, High Pass, Phaser, and Reverb audible while
    /// actually playing -- previously only the offline export ran real DSP for these; live
    /// playback only ever approximated with volume/pan/rate scalars.
    private func applyLiveTrackFXChain(for track: Int) {
        guard trackDistortionUnits.indices.contains(track),
              trackEQUnits.indices.contains(track),
              trackReverbUnits.indices.contains(track)
        else { return }

        let runtime = trackFXRuntimeStates[track]
        let hasFX = !trackActiveFXPresets[track].isEmpty
        let distortionActive = hasFX && trackActiveFXPresets[track].contains(.distortion)

        applyLiveDistortion(trackDistortionUnits[track], active: distortionActive)
        applyLiveEQ(trackEQUnits[track], runtime: runtime, hasFX: hasFX)
        applyLiveReverb(trackReverbUnits[track], runtime: runtime, hasFX: hasFX)
    }

    private func applyLiveMasterFXChain() {
        let runtime = masterFXRuntimeState
        let hasFX = !masterActiveFXPresets.isEmpty
        let distortionActive = hasFX && masterActiveFXPresets.contains(.distortion)

        applyLiveDistortion(masterDistortionUnit, active: distortionActive)
        applyLiveEQ(masterEQUnit, runtime: runtime, hasFX: hasFX)
        applyLiveReverb(masterReverbUnit, runtime: runtime, hasFX: hasFX)
    }

    private func applyLiveDistortion(_ distortion: AVAudioUnitDistortion, active: Bool) {
        distortion.bypass = !active
        distortion.wetDryMix = active ? 45 : 0
    }

    private func applyLiveEQ(_ eq: AVAudioUnitEQ, runtime: TrackFXRuntimeState, hasFX: Bool) {
        guard eq.bands.count >= 2 else { return }
        let lowPassOn = hasFX && runtime.lowPassActive
        let highPassOn = hasFX && runtime.highPassActive
        eq.bands[0].frequency = Float(min(max(runtime.lowPassCutoff, 20), 20_000))
        eq.bands[0].bypass = !lowPassOn
        eq.bands[1].frequency = Float(min(max(runtime.highPassCutoff, 20), 20_000))
        eq.bands[1].bypass = !highPassOn
        eq.bypass = !(lowPassOn || highPassOn)
    }

    private func applyLiveReverb(_ reverb: AVAudioUnitReverb, runtime: TrackFXRuntimeState, hasFX: Bool) {
        let active = hasFX && runtime.reverbMix > 0.001
        reverb.bypass = !active
        reverb.wetDryMix = active ? Float(min(max(runtime.reverbMix * 100, 0), 100)) : 0
    }

    private func configureTrackSample(for index: Int, url: URL) {
        guard (0..<trackCount).contains(index) else { return }
        sampleRenderCache[index] = nil
        processedPlaybackBuffers[index] = nil
        cachedAudioFiles[index] = nil
        sampleAssets[index] = sampleAsset(for: url)
    }

    private func sampleAsset(for url: URL) -> SampleAsset? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        let frameCount = file.length
        let duration = frameCount > 0 && format.sampleRate > 0
            ? Double(frameCount) / format.sampleRate
            : 0

        return SampleAsset(
            fileURL: url,
            sampleRate: format.sampleRate,
            channelCount: format.channelCount,
            frameCount: frameCount,
            duration: duration
        )
    }

    /// Returns the AVAudioFile for dry (unprocessed) playback of a track, opening and
    /// parsing it once and reusing the handle thereafter. scheduleFile already streams
    /// from disk and upmixes mono sources to the engine's stereo connection correctly;
    /// what was expensive was reopening + re-parsing the header on every single trigger.
    /// Reused across concurrent voices for the same track: the class is @MainActor-isolated
    /// and framePosition is reset immediately before each synchronous scheduleFile call
    /// with no suspension point in between, so there's no race on the read cursor.
    private func cachedAudioFile(for index: Int) -> AVAudioFile? {
        if let cached = cachedAudioFiles[safe: index] ?? nil {
            return cached
        }
        guard let asset = sampleAssets[safe: index] ?? nil,
              let file = try? AVAudioFile(forReading: asset.fileURL)
        else {
            return nil
        }
        cachedAudioFiles[index] = file
        return file
    }

    private func processedPlaybackBuffer(for index: Int) -> AVAudioPCMBuffer? {
        if let cached = processedPlaybackBuffers[safe: index] ?? nil {
            return cached
        }
        let renderBuffer = renderedSamples(for: index)
        guard renderBuffer.frameCount > 0,
              let playbackFormat = AVAudioFormat(
                standardFormatWithSampleRate: renderSampleRate,
                channels: playbackChannelCount
              ),
              let buffer = makePCMBuffer(from: renderBuffer, format: playbackFormat)
        else {
            processedPlaybackBuffers[index] = nil
            return nil
        }
        processedPlaybackBuffers[index] = buffer
        return buffer
    }

    private func refreshActivePlayers(for index: Int) {
        guard voicePools.indices.contains(index) else { return }
        for voice in voicePools[index] {
            voice.player.pan = Float(trackPans[index])
            voice.player.volume = Float(trackVolumes[index])
            voice.varispeed.rate = Float(min(max(voice.playbackRate, 0.5), 2.0))
        }
    }

    private func copyDrumPackToSandbox(urls: [URL]) -> DrumPackCopyResult {
        guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return DrumPackCopyResult(copiedURLs: [], failedFileNames: urls.map(\.lastPathComponent), oversizedFileNames: [])
        }
        let packURL = documentsURL.appendingPathComponent("CurrentDrumPack", isDirectory: true)
        try? FileManager.default.removeItem(at: packURL)
        do {
            try FileManager.default.createDirectory(at: packURL, withIntermediateDirectories: true)
        } catch {
            return DrumPackCopyResult(copiedURLs: [], failedFileNames: urls.map(\.lastPathComponent), oversizedFileNames: [])
        }

        var copied: [URL] = []
        var failed: [String] = []
        var oversized: [String] = []
        let maxImportBytes = 512 * 1_024 * 1_024
        for (index, sourceURL) in urls.enumerated() {
            let hasAccess = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if hasAccess { sourceURL.stopAccessingSecurityScopedResource() }
            }

            if let values = try? sourceURL.resourceValues(forKeys: [.fileSizeKey]),
               let fileSize = values.fileSize,
               fileSize > maxImportBytes {
                oversized.append(sourceURL.lastPathComponent)
                continue
            }

            let safeName = sourceURL.lastPathComponent.replacingOccurrences(of: "/", with: "_")
            let destURL = packURL.appendingPathComponent(String(format: "%02d_%@", index + 1, safeName))
            do {
                if FileManager.default.fileExists(atPath: destURL.path) {
                    try FileManager.default.removeItem(at: destURL)
                }
                try FileManager.default.copyItem(at: sourceURL, to: destURL)
                if sampleAsset(for: destURL) != nil {
                    copied.append(destURL)
                } else {
                    try? FileManager.default.removeItem(at: destURL)
                    failed.append(sourceURL.lastPathComponent)
                }
            } catch {
                failed.append(sourceURL.lastPathComponent)
            }
        }
        return DrumPackCopyResult(copiedURLs: copied, failedFileNames: failed, oversizedFileNames: oversized)
    }

    private func configureMetronomeBuffers() {
        let highSamples = Self.makeClickSamples(frequency: 1800, amplitude: 0.8, duration: 0.035, sampleRate: renderSampleRate)
        let lowSamples = Self.makeClickSamples(frequency: 1300, amplitude: 0.55, duration: 0.03, sampleRate: renderSampleRate)
        metronomeHighBuffer = Self.makeStereoBuffer(from: highSamples, sampleRate: renderSampleRate, channels: playbackChannelCount)
        metronomeLowBuffer = Self.makeStereoBuffer(from: lowSamples, sampleRate: renderSampleRate, channels: playbackChannelCount)
    }

    private func loadPatternForSelectedSlot() {
        steps = patternForSlot(selectedPatternSlot)
    }

    private func syncSelectedSlotPattern() {
        slotPatterns[selectedPatternSlot.rawValue] = steps
    }

    private func patternForSlot(_ slot: PatternSlot) -> [[StepEvent]] {
        slotPatterns[slot.rawValue] ?? Self.makeEmptyPattern()
    }

    private func phraseHasContent(_ slot: PatternSlot) -> Bool {
        let pattern = patternForSlot(slot)
        return pattern.flatMap { $0 }.contains { $0.isActive }
    }

    private func computePlaybackPhraseOrder() -> [PatternSlot] {
        let slots: [PatternSlot] = [.a, .b, .c, .d]
        guard phraseHasContent(.a) else { return [.a] }
        guard let lastFilledIndex = slots.lastIndex(where: { phraseHasContent($0) }) else {
            return [.a]
        }
        return Array(slots[...lastFilledIndex])
    }

    private func renderHitsForCurrentArrangement() -> [RecordedHit] {
        let order = computePlaybackPhraseOrder()
        let patternLength = sequenceLength.rawValue
        let stepDuration = 60.0 / bpm / 4.0
        var hits: [RecordedHit] = []

        for (phraseIndex, slot) in order.enumerated() {
            let pattern = patternForSlot(slot)
            let phraseOffset = Double(phraseIndex * patternLength) * stepDuration

            for step in 0..<patternLength {
                for track in 0..<trackCount {
                    let event = pattern[track][step]
                    guard event.isActive else { continue }
                    guard deterministicPasses(probability: trackProbabilities[track], phraseIndex: phraseIndex, track: track, step: step) else { continue }
                    let gate = gateValue(for: step, track: track)

                    let swingDelay = trackSwings[track] > 0 && !step.isMultiple(of: 2)
                        ? stepDuration * trackSwings[track] * 0.5
                        : 0
                    let baseTime = phraseOffset + (Double(step) * stepDuration) + swingDelay
                    let baseHit = renderedHit(
                        track: track,
                        time: baseTime,
                        accent: trackAccents[track],
                        gate: gate,
                        phraseIndex: phraseIndex,
                        step: step,
                        repeatIndex: 0
                    )
                    hits.append(baseHit)

                    let runtime = fxRuntimeState(for: track)
                    if fxApplies(to: track), runtime.fxEchoRepeats > 0 {
                        for repeatIndex in 1...runtime.fxEchoRepeats {
                            let repeatedAccent = trackAccents[track] * pow(runtime.fxEchoDecay, Double(repeatIndex))
                            hits.append(
                                renderedHit(
                                    track: track,
                                    time: baseTime + (runtime.fxEchoDelay * Double(repeatIndex)),
                                    accent: repeatedAccent,
                                    gate: gate,
                                    phraseIndex: phraseIndex,
                                    step: step,
                                    repeatIndex: repeatIndex
                                )
                            )
                        }
                    }
                }
            }
        }

        return hits.sorted { $0.time < $1.time }
    }

    private func renderedHit(track: Int, time: Double, accent: Double, gate: Double, phraseIndex: Int, step: Int, repeatIndex: Int) -> RecordedHit {
        let settings = voicePlaybackSettings(
            track: track,
            accent: accent,
            gate: gate,
            repeatIndex: repeatIndex,
            dryPreview: false,
            panRandomizer: { deterministicSignedValue(phraseIndex: phraseIndex, track: track, step: step, repeatIndex: repeatIndex, salt: 1) },
            rateRandomizer: { deterministicSignedValue(phraseIndex: phraseIndex, track: track, step: step, repeatIndex: repeatIndex, salt: 2) }
        )

        return RecordedHit(
            time: max(time, 0),
            track: track,
            volume: max(settings.volume, 0),
            pan: settings.pan,
            rate: min(max(settings.rate.isFinite ? settings.rate : 1.0, 0.5), 2.0)
        )
    }

    private func voicePlaybackSettings(
        track: Int,
        accent: Double,
        gate: Double,
        repeatIndex: Int,
        dryPreview: Bool,
        panRandomizer: () -> Double,
        rateRandomizer: () -> Double
    ) -> VoicePlaybackSettings {
        let runtime = fxRuntimeState(for: track)
        let fxIsActive = !dryPreview && fxApplies(to: track)
        let gain = fxIsActive ? runtime.fxGain : 1.0
        var volume = trackVolumes[track] * accent * gate * gain
        if !dryPreview {
            volume *= 1 + (trackClicks[track] * 0.35)
        }
        if repeatIndex > 0 {
            volume *= pow(0.9, Double(repeatIndex))
        }

        let basePan = dryPreview ? 0 : trackPans[track]
        let panJitter = fxIsActive ? runtime.fxPanJitter : 0
        let pan = min(max(basePan + (panRandomizer() * panJitter), -1), 1)

        let rateJitter = fxIsActive ? runtime.fxRateJitter : 0
        var rate = (fxIsActive ? runtime.fxRate : 1.0) + (rateRandomizer() * rateJitter)
        if fxIsActive, runtime.vibratoEnabled {
            rate += rateRandomizer() * 0.15
        }
        if !dryPreview {
            rate *= pow(2.0, trackTunes[track] / 12.0)
        }

        return VoicePlaybackSettings(
            volume: max(volume, 0),
            pan: pan,
            rate: min(max(rate.isFinite ? rate : 1.0, 0.5), 2.0),
            fxIsActive: fxIsActive
        )
    }

    private func gateValue(for step: Int, track: Int) -> Double {
        let runtime = fxRuntimeState(for: track)
        guard runtime.stutterAmount > 0.05 else { return 1.0 }
        let division = runtime.stutterDivisionOverride ?? Int(2 + (runtime.stutterAmount * 10))
        return step % max(division, 1) == 0 ? 0.35 : 1.0
    }

    private func deterministicPasses(probability: Double, phraseIndex: Int, track: Int, step: Int) -> Bool {
        probability >= 1 || deterministicUnitValue(phraseIndex: phraseIndex, track: track, step: step, repeatIndex: 0, salt: 0) <= probability
    }

    private func deterministicUnitValue(phraseIndex: Int, track: Int, step: Int, repeatIndex: Int, salt: Int) -> Double {
        let seed = Double((phraseIndex + 1) * 101 + (track + 1) * 37 + (step + 1) * 17 + (repeatIndex + 1) * 13 + salt * 97)
        let raw = sin(seed * 12.9898) * 43_758.5453
        return raw - floor(raw)
    }

    private func deterministicSignedValue(phraseIndex: Int, track: Int, step: Int, repeatIndex: Int, salt: Int) -> Double {
        (deterministicUnitValue(phraseIndex: phraseIndex, track: track, step: step, repeatIndex: repeatIndex, salt: salt) * 2) - 1
    }

    private func makeRecordingWAV(from hits: [RecordedHit]) -> ExportedWAV? {
        // The offline engine render applies each track's delay/reverb/distortion/filter/etc.
        // FX chain; it's the only path that reproduces what the user actually hears. The dry
        // additive mix below is a true fallback, used only if offline rendering fails to start.
        if let exported = makeRecordingWAVOffline(from: hits) {
            return exported
        }
        return makeRecordingWAVFallback(from: hits)
    }

    private func makeRecordingWAVFallback(from hits: [RecordedHit]) -> ExportedWAV? {
        guard !hits.isEmpty else { return nil }
        let sortedHits = hits.sorted { $0.time < $1.time }
        let totalDuration = sortedHits.reduce(0.0) { partial, hit in
            let buffer = renderedSamples(for: hit.track)
            let baseDuration = (Double(buffer.frameCount) / renderSampleRate) / hit.rate
            return max(partial, hit.time + max(baseDuration, 0.05))
        }
        let frameCount = max(Int((totalDuration + 0.5) * renderSampleRate), 1)
        var left = Array(repeating: Float.zero, count: frameCount)
        var right = Array(repeating: Float.zero, count: frameCount)

        isRenderingExport = true
        defer { isRenderingExport = false }

        for hit in sortedHits {
            mix(hit: hit, intoLeft: &left, right: &right)
        }

        let protectedMix = Self.protectStereoMix(left: left, right: right)
        let data = Self.makePCM24StereoWavData(
            left: protectedMix.left,
            right: protectedMix.right,
            sampleRate: Int(renderSampleRate)
        )
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let kind = recordedHits.isEmpty ? "Pattern" : "Recording"
        let filename = "drummakid-\(kind)-\(formatter.string(from: Date()))"
        return ExportedWAV(document: WAVFileDocument(data: data), defaultFilename: filename)
    }

    private func makeRecordingWAVOffline(from hits: [RecordedHit]) -> ExportedWAV? {
        let sortedHits = hits.sorted { $0.time < $1.time }
        guard !sortedHits.isEmpty else { return nil }

        let totalDuration = sortedHits.reduce(0.0) { partial, hit in
            let buffer = renderedSamples(for: hit.track)
            let baseDuration = (Double(buffer.frameCount) / renderSampleRate) / max(hit.rate, 0.5)
            return max(partial, hit.time + max(baseDuration, 0.05))
        }
        let totalFrames = max(Int((totalDuration + 0.5) * renderSampleRate), 1)

        let engine = AVAudioEngine()
        let outputFormat = AVAudioFormat(standardFormatWithSampleRate: renderSampleRate, channels: 2)!
        let mainMixer = engine.mainMixerNode
        var cachedBuffers: [Int: AVAudioPCMBuffer] = [:]

        for hit in sortedHits {
            guard cachedBuffers[hit.track] == nil else { continue }
            guard let sourceBuffer = processedPlaybackBuffers[safe: hit.track] ?? nil else {
                guard let converted = makePCMBuffer(from: renderedSamples(for: hit.track), format: outputFormat) else {
                    continue
                }
                cachedBuffers[hit.track] = converted
                continue
            }
            cachedBuffers[hit.track] = sourceBuffer
        }

        guard !cachedBuffers.isEmpty else { return nil }

        // The engine must already be running in its final (manual/offline) rendering mode
        // before any node schedules or plays a buffer: the AVAudioTime values handed to
        // scheduleBuffer/play(at:) below are interpreted against whichever render clock is
        // active at the moment those calls happen. Enabling manual rendering mode and
        // starting the engine only *after* scheduling (the previous order) silently
        // produces empty output -- the scheduled times end up bound to a clock the manual
        // renderer never advances, so every buffer waits for an instant that never comes.
        do {
            try engine.enableManualRenderingMode(.offline, format: outputFormat, maximumFrameCount: 4096)
            try engine.start()
        } catch {
            engine.stop()
            return nil
        }

        for hit in sortedHits {
            guard let buffer = cachedBuffers[hit.track] else { continue }
            let runtime = fxRuntimeState(for: hit.track)
            let activePresets = trackActiveFXPresets[safe: hit.track] ?? []

            let player = AVAudioPlayerNode()
            let varispeed = AVAudioUnitVarispeed()
            let distortion = AVAudioUnitDistortion()
            let eq = AVAudioUnitEQ(numberOfBands: 2)
            let delay = AVAudioUnitDelay()
            let reverb = AVAudioUnitReverb()
            let mixer = AVAudioMixerNode()

            engine.attach(player)
            engine.attach(varispeed)
            engine.attach(distortion)
            engine.attach(eq)
            engine.attach(delay)
            engine.attach(reverb)
            engine.attach(mixer)

            reverb.loadFactoryPreset(.mediumHall)
            reverb.wetDryMix = fxApplies(to: hit.track) ? Float(min(max(runtime.reverbMix * 100, 0), 100)) : 0

            delay.wetDryMix = fxApplies(to: hit.track) ? Float(min(max(runtime.delayMix * 100, 0), 100)) : 0
            delay.feedback = fxApplies(to: hit.track) ? Float(min(max(runtime.fxEchoDecay * 100, 0), 95)) : 0
            delay.delayTime = fxApplies(to: hit.track) ? runtime.fxEchoDelay : 0.08

            distortion.loadFactoryPreset(.multiBrokenSpeaker)
            distortion.wetDryMix = fxApplies(to: hit.track) && activePresets.contains(.distortion) ? 45 : 0

            if eq.bands.count >= 2 {
                eq.bands[0].filterType = .lowPass
                eq.bands[0].frequency = Float(min(max(runtime.lowPassCutoff, 20), 20_000))
                eq.bands[0].bandwidth = 0.5
                eq.bands[0].bypass = !(fxApplies(to: hit.track) && runtime.lowPassActive)

                eq.bands[1].filterType = .highPass
                eq.bands[1].frequency = Float(min(max(runtime.highPassCutoff, 20), 20_000))
                eq.bands[1].bandwidth = 0.5
                eq.bands[1].bypass = !(fxApplies(to: hit.track) && runtime.highPassActive)
            }

            varispeed.rate = Float(min(max(hit.rate, 0.25), 4.0))
            mixer.outputVolume = Float(min(max(hit.volume, 0), 1))
            mixer.pan = Float(min(max(hit.pan, -1), 1))

            engine.connect(player, to: varispeed, format: buffer.format)
            engine.connect(varispeed, to: distortion, format: buffer.format)
            engine.connect(distortion, to: eq, format: buffer.format)
            engine.connect(eq, to: delay, format: buffer.format)
            engine.connect(delay, to: reverb, format: buffer.format)
            engine.connect(reverb, to: mixer, format: buffer.format)
            engine.connect(mixer, to: mainMixer, format: buffer.format)

            let startFrame = AVAudioFramePosition(max(Int(hit.time * renderSampleRate), 0))
            let startTime = AVAudioTime(sampleTime: startFrame, atRate: renderSampleRate)
            player.scheduleBuffer(buffer, at: startTime, options: [], completionHandler: nil)
            player.play(at: startTime)
        }

        var renderedLeft: [Float] = []
        var renderedRight: [Float] = []
        renderedLeft.reserveCapacity(totalFrames)
        renderedRight.reserveCapacity(totalFrames)

        while engine.manualRenderingSampleTime < AVAudioFramePosition(totalFrames) {
            let framesRemaining = AVAudioFrameCount(max(0, totalFrames - Int(engine.manualRenderingSampleTime)))
            let framesToRender = min(framesRemaining, engine.manualRenderingMaximumFrameCount)
            guard framesToRender > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: framesToRender)
            else { break }

            do {
                let status = try engine.renderOffline(framesToRender, to: buffer)
                guard status == .success || status == .insufficientDataFromInputNode else { break }

                let frameCount = Int(buffer.frameLength)
                guard frameCount > 0,
                      let channels = buffer.floatChannelData
                else { continue }

                renderedLeft.append(contentsOf: UnsafeBufferPointer(start: channels[0], count: frameCount))
                renderedRight.append(contentsOf: UnsafeBufferPointer(start: channels[1], count: frameCount))
            } catch {
                engine.stop()
                return nil
            }
        }

        engine.stop()
        guard !renderedLeft.isEmpty, renderedLeft.count == renderedRight.count else { return nil }

        let protectedMix = Self.protectStereoMix(left: renderedLeft, right: renderedRight)
        let data = Self.makePCM24StereoWavData(
            left: protectedMix.left,
            right: protectedMix.right,
            sampleRate: Int(renderSampleRate)
        )
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let kind = recordedHits.isEmpty ? "Pattern" : "Recording"
        let filename = "drummakid-\(kind)-\(formatter.string(from: Date()))"
        return ExportedWAV(document: WAVFileDocument(data: data), defaultFilename: filename)
    }

    private func makePCMBuffer(from renderBuffer: RenderSampleBuffer, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frameCount = AVAudioFrameCount(renderBuffer.frameCount)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
        else { return nil }

        buffer.frameLength = frameCount
        guard let channels = buffer.floatChannelData else { return nil }
        for frame in 0..<Int(frameCount) {
            channels[0][frame] = renderBuffer.left[safe: frame] ?? 0
            channels[1][frame] = renderBuffer.right[safe: frame] ?? 0
        }
        return buffer
    }

    private func mix(hit: RecordedHit, intoLeft left: inout [Float], right: inout [Float]) {
        let buffer = renderedSamples(for: hit.track)
        guard buffer.frameCount > 0 else { return }

        let startFrame = max(Int(hit.time * renderSampleRate), 0)
        let leftGain = Float(hit.volume * (hit.pan <= 0 ? 1.0 : 1.0 - hit.pan))
        let rightGain = Float(hit.volume * (hit.pan >= 0 ? 1.0 : 1.0 + hit.pan))
        let safeRate = max(hit.rate, 0.5)
        let outputFrames = Int(Double(buffer.frameCount) / safeRate) + 2

        for outputIndex in 0..<outputFrames {
            let frameIndex = startFrame + outputIndex
            guard left.indices.contains(frameIndex), right.indices.contains(frameIndex) else { break }

            let sourcePosition = Double(outputIndex) * safeRate
            let lowerIndex = Int(sourcePosition)
            if lowerIndex >= buffer.frameCount { break }
            let upperIndex = min(lowerIndex + 1, buffer.frameCount - 1)
            let fraction = Float(sourcePosition - Double(lowerIndex))
            let leftSample = interpolatedSample(in: buffer.left, lowerIndex: lowerIndex, upperIndex: upperIndex, fraction: fraction)
            let rightSample = interpolatedSample(in: buffer.right, lowerIndex: lowerIndex, upperIndex: upperIndex, fraction: fraction)

            left[frameIndex] += leftSample * leftGain
            right[frameIndex] += rightSample * rightGain
        }
    }

    private func renderedSamples(for track: Int) -> RenderSampleBuffer {
        if let cached = sampleRenderCache[safe: track] ?? nil {
            return cached
        }
        guard sampleURLs.indices.contains(track), let url = sampleURLs[track] else {
            return RenderSampleBuffer(left: [], right: [], sampleRate: renderSampleRate)
        }

        let samples = loadNormalizedRenderSamples(from: url, targetSampleRate: renderSampleRate)
        sampleRenderCache[track] = samples
        return samples
    }

    private func loadRenderSamples(from url: URL) -> RenderSampleBuffer {
        guard let file = try? AVAudioFile(forReading: url) else {
            return RenderSampleBuffer(left: [], right: [], sampleRate: renderSampleRate)
        }

        let sourceFormat = file.processingFormat
        let targetChannels = AVAudioChannelCount(min(max(Int(sourceFormat.channelCount), 1), 2))
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sourceFormat.sampleRate,
            channels: targetChannels,
            interleaved: false
        ),
        let converter = AVAudioConverter(from: sourceFormat, to: targetFormat)
        else {
            return RenderSampleBuffer(left: [], right: [], sampleRate: sourceFormat.sampleRate)
        }

        let inputFrameCount: AVAudioFrameCount = 4096
        let outputFrameCapacity = AVAudioFrameCount((Double(inputFrameCount) * targetFormat.sampleRate / sourceFormat.sampleRate).rounded(.up)) + 512
        var reachedEnd = false
        var convertedLeft: [Float] = []
        var convertedRight: [Float] = []

        while !reachedEnd {
            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCapacity) else {
                break
            }

            var conversionError: NSError?
            let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
                if reachedEnd {
                    outStatus.pointee = .endOfStream
                    return nil
                }

                guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: inputFrameCount) else {
                    reachedEnd = true
                    outStatus.pointee = .endOfStream
                    return nil
                }

                do {
                    try file.read(into: inputBuffer, frameCount: inputFrameCount)
                } catch {
                    reachedEnd = true
                    outStatus.pointee = .endOfStream
                    return nil
                }

                if inputBuffer.frameLength == 0 {
                    reachedEnd = true
                    outStatus.pointee = .endOfStream
                    return nil
                }

                outStatus.pointee = .haveData
                return inputBuffer
            }

            if outputBuffer.frameLength > 0, let channels = outputBuffer.floatChannelData {
                convertedLeft.append(contentsOf: UnsafeBufferPointer(start: channels[0], count: Int(outputBuffer.frameLength)))
                if Int(targetChannels) > 1 {
                    convertedRight.append(contentsOf: UnsafeBufferPointer(start: channels[1], count: Int(outputBuffer.frameLength)))
                }
            }

            if conversionError != nil || status == .error || status == .endOfStream {
                break
            }
        }

        guard !convertedLeft.isEmpty else {
            return RenderSampleBuffer(left: [], right: [], sampleRate: sourceFormat.sampleRate)
        }
        if convertedRight.isEmpty {
            convertedRight = convertedLeft
        }
        return RenderSampleBuffer(left: convertedLeft, right: convertedRight, sampleRate: sourceFormat.sampleRate)
    }

    private func loadNormalizedRenderSamples(from url: URL, targetSampleRate: Double) -> RenderSampleBuffer {
        guard let file = try? AVAudioFile(forReading: url) else {
            return RenderSampleBuffer(left: [], right: [], sampleRate: targetSampleRate)
        }

        let sourceFormat = file.processingFormat
        if abs(sourceFormat.sampleRate - targetSampleRate) < 0.5 {
            return loadRenderSamples(from: url)
        }

        let targetChannels = AVAudioChannelCount(min(max(Int(sourceFormat.channelCount), 1), 2))
        guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: targetSampleRate, channels: targetChannels, interleaved: false),
              let converter = AVAudioConverter(from: sourceFormat, to: targetFormat)
        else {
            return loadRenderSamples(from: url)
        }

        let inputFrameCount: AVAudioFrameCount = 4096
        let outputFrameCapacity = AVAudioFrameCount((Double(inputFrameCount) * targetSampleRate / sourceFormat.sampleRate).rounded(.up)) + 512
        var reachedEnd = false
        var convertedLeft: [Float] = []
        var convertedRight: [Float] = []

        while !reachedEnd {
            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCapacity) else {
                break
            }

            var conversionError: NSError?
            let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
                if reachedEnd {
                    outStatus.pointee = .endOfStream
                    return nil
                }

                guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: inputFrameCount) else {
                    reachedEnd = true
                    outStatus.pointee = .endOfStream
                    return nil
                }

                do {
                    try file.read(into: inputBuffer, frameCount: inputFrameCount)
                } catch {
                    reachedEnd = true
                    outStatus.pointee = .endOfStream
                    return nil
                }

                if inputBuffer.frameLength == 0 {
                    reachedEnd = true
                    outStatus.pointee = .endOfStream
                    return nil
                }

                outStatus.pointee = .haveData
                return inputBuffer
            }

            if outputBuffer.frameLength > 0, let channels = outputBuffer.floatChannelData {
                convertedLeft.append(contentsOf: UnsafeBufferPointer(start: channels[0], count: Int(outputBuffer.frameLength)))
                if Int(targetChannels) > 1 {
                    convertedRight.append(contentsOf: UnsafeBufferPointer(start: channels[1], count: Int(outputBuffer.frameLength)))
                }
            }

            if conversionError != nil || status == .error || status == .endOfStream {
                break
            }
        }

        guard !convertedLeft.isEmpty else { return loadRenderSamples(from: url) }
        if convertedRight.isEmpty {
            convertedRight = convertedLeft
        }
        return RenderSampleBuffer(left: convertedLeft, right: convertedRight, sampleRate: targetSampleRate)
    }

    private static func protectStereoMix(left: [Float], right: [Float]) -> (left: [Float], right: [Float]) {
        guard left.count == right.count, !left.isEmpty else {
            return (left, right)
        }

        let peak = zip(left, right).reduce(Float.zero) { partial, pair in
            max(partial, max(abs(pair.0), abs(pair.1)))
        }
        guard peak > 1 else {
            return (left, right)
        }

        let gain = 1 / peak
        let protectedLeft = left.map { $0 * gain }
        let protectedRight = right.map { $0 * gain }
        return (protectedLeft, protectedRight)
    }

    private func interpolatedSample(in samples: [Float], lowerIndex: Int, upperIndex: Int, fraction: Float) -> Float {
        guard samples.indices.contains(lowerIndex) else { return 0 }
        let lower = samples[lowerIndex]
        let upper = samples.indices.contains(upperIndex) ? samples[upperIndex] : lower
        return lower + ((upper - lower) * fraction)
    }

    private func prepareUserDocumentsIfNeeded() {
        guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return
        }

        let exportsURL = documentsURL.appendingPathComponent("Exports", isDirectory: true)
        try? FileManager.default.createDirectory(at: exportsURL, withIntermediateDirectories: true)
    }

    /// Coalesces writes so a continuous knob drag (which calls persistState on every
    /// gesture delta) doesn't JSON-encode and hit disk on every pixel of movement.
    private func persistState() {
        persistWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.writePersistedStateNow()
        }
        persistWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + persistDebounceInterval, execute: workItem)
    }

    /// Bypasses the debounce for moments where losing the last edit would be user-visible,
    /// e.g. right before the app leaves the foreground.
    private func flushPersistedStateIfNeeded() {
        guard persistWorkItem != nil else { return }
        persistWorkItem?.cancel()
        persistWorkItem = nil
        writePersistedStateNow()
    }

    private func writePersistedStateNow() {
        persistWorkItem = nil
        let state = PersistedState(
            currentPattern: steps,
            slotPatterns: slotPatterns,
            bpm: bpm,
            trackSwings: trackSwings,
            trackClicks: trackClicks,
            trackTunes: trackTunes,
            trackAccents: trackAccents,
            trackProbabilities: trackProbabilities,
            swingAmount: nil
        )

        do {
            let data = try JSONEncoder().encode(state)
            UserDefaults.standard.set(data, forKey: persistedStateKey)
        } catch {
            statusMessage = "Could not save sequencer state."
        }
    }

    private func loadPersistedStateIfAvailable() {
        guard let data = UserDefaults.standard.data(forKey: persistedStateKey) else {
            return
        }

        do {
            let decoded = try JSONDecoder().decode(PersistedState.self, from: data)
            slotPatterns = decoded.slotPatterns.filter { _, pattern in
                Self.isPatternShapeValid(pattern)
            }
            if slotPatterns["a"] == nil, Self.isPatternShapeValid(decoded.currentPattern) {
                slotPatterns["a"] = decoded.currentPattern
            }

            if Self.isPatternShapeValid(decoded.currentPattern), slotPatterns[selectedPatternSlot.rawValue] == nil {
                steps = decoded.currentPattern
                syncSelectedSlotPattern()
            }

            bpm = min(max(decoded.bpm, 40), 300)
            if let swings = decoded.trackSwings, swings.count == trackCount {
                trackSwings = swings.map { min(max($0, 0), 0.45) }
            } else if let legacySwing = decoded.swingAmount {
                trackSwings = Array(repeating: min(max(legacySwing, 0), 0.45), count: trackCount)
            }
            if let clicks = decoded.trackClicks, clicks.count == trackCount {
                trackClicks = clicks.map { min(max($0, 0), 1) }
            }
            if let tunes = decoded.trackTunes, tunes.count == trackCount {
                trackTunes = tunes.map { min(max($0, -12), 12) }
            }
            if let accents = decoded.trackAccents, accents.count == trackCount {
                trackAccents = accents.map { min(max($0, 0.5), 2) }
            }
            if let probabilities = decoded.trackProbabilities, probabilities.count == trackCount {
                trackProbabilities = probabilities.map { min(max($0, 0), 1) }
            }
        } catch {
            statusMessage = "Could not restore previous sequencer state."
        }
    }

    private func isValid(track: Int, step: Int) -> Bool {
        steps.indices.contains(track) && steps[track].indices.contains(step)
    }

    private static func makeEmptyPattern() -> [[StepEvent]] {
        Array(repeating: Array(repeating: StepEvent(), count: 64), count: 16)
    }

    private static func isPatternShapeValid(_ pattern: [[StepEvent]]) -> Bool {
        pattern.count == 16 && pattern.allSatisfy { $0.count == 64 }
    }

    private static var defaultDrumSpecs: [(name: String, duration: Double)] {
        [
            ("808", 1.82),
            ("kick", 0.48),
            ("cymbal", 3.69),
            ("clap", 0.11),
            ("hi-hat", 0.02),
            ("open hat", 0.17),
            ("hi tom", 1.0),
            ("low tom", 0.76),
            ("snare", 2.79),
            ("clave", 0.05),
            ("cowbell", 0.58),
            ("crash", 1.65),
            ("EEHHH", 0.32),
            ("maraca", 0.26),
            ("rim shot", 1.82),
            ("scratch", 0.5),
        ]
    }

    private static var defaultChokeGroups: [Int?] {
        Array(1...16).map { Optional($0) }
    }

    private static func bundledDrumPackURLs() -> [URL] {
        let fileNames = [
            "01_bass_drum",
            "02_snare_drum",
            "03_closed_hi_hat",
            "04_open_hi_hat",
            "05_808",
            "06_sticks",
            "07_cymbal",
            "08_noise",
            "09_hand_clap",
            "10_click",
            "11_low_tom",
            "12_hi_tom",
            "13_cow_bell",
            "14_blip",
            "15_tone",
            "16_bass_tone",
        ]

        let bundles = [Bundle.main, Bundle(for: DrumMachineEngine.self)]
        var urls: [URL] = []

        for fileName in fileNames {
            let resolvedURL = bundles.lazy.compactMap { bundle in
                bundle.url(forResource: fileName, withExtension: "wav", subdirectory: "BuiltInDrumPack")
                    ?? bundle.url(forResource: fileName, withExtension: "wav")
                    ?? bundle.urls(forResourcesWithExtension: "wav", subdirectory: "BuiltInDrumPack")?
                        .first(where: { $0.lastPathComponent == "\(fileName).wav" })
                    ?? bundle.urls(forResourcesWithExtension: "wav", subdirectory: nil)?
                        .first(where: { $0.lastPathComponent == "\(fileName).wav" })
            }.first
            if let resolvedURL {
                urls.append(resolvedURL)
            }
        }

        if urls.count == fileNames.count {
            return urls
        }

        guard let cacheDirectory = try? materializedBuiltInDrumPackDirectory() else {
            return urls
        }

        urls.removeAll(keepingCapacity: true)
        for fileName in fileNames {
            guard let asset = bundles.lazy.compactMap({ NSDataAsset(name: fileName, bundle: $0) }).first else {
                continue
            }
            let destinationURL = cacheDirectory.appendingPathComponent("\(fileName).wav")
            if !FileManager.default.fileExists(atPath: destinationURL.path) ||
                ((try? Data(contentsOf: destinationURL)) != asset.data) {
                try? asset.data.write(to: destinationURL, options: .atomic)
            }
            urls.append(destinationURL)
        }

        if urls.count == fileNames.count {
            return urls
        }

        let sourceResourceDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/BuiltInDrumPack", isDirectory: true)
        let sourceTreeURLs = fileNames.compactMap { fileName in
            let url = sourceResourceDirectory.appendingPathComponent("\(fileName).wav")
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        if sourceTreeURLs.count == fileNames.count {
            return sourceTreeURLs
        }

        return urls
    }

    private static func materializedBuiltInDrumPackDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("drummakidBuiltInDrumPack", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func makeClickSamples(frequency: Double, amplitude: Double, duration: Double, sampleRate: Double) -> [Float] {
        let frameCount = Int(duration * sampleRate)
        var samples = Array(repeating: Float.zero, count: frameCount)
        for frame in 0..<frameCount {
            let t = Double(frame) / sampleRate
            let envelope = exp(-t / 0.018)
            let tone = sin(2.0 * .pi * frequency * t) * envelope * amplitude
            samples[frame] = Float(max(min(tone, 1), -1))
        }
        return samples
    }

    /// Duplicates mono samples across `channels` so the resulting buffer's channel count
    /// matches whatever the destination player node was connected with -- scheduleBuffer
    /// requires an exact match (see the dry-playback buffer fix above for the same issue).
    private static func makeStereoBuffer(from samples: [Float], sampleRate: Double, channels: AVAudioChannelCount) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channels, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channelData = buffer.floatChannelData
        else {
            return nil
        }

        buffer.frameLength = AVAudioFrameCount(samples.count)
        for channel in 0..<Int(channels) {
            for i in samples.indices {
                channelData[channel][i] = samples[i]
            }
        }
        return buffer
    }

    private static func makePCM24StereoWavData(left: [Float], right: [Float], sampleRate: Int) -> Data {
        let frameCount = min(left.count, right.count)
        var pcm = Data(capacity: frameCount * 6)
        for index in 0..<frameCount {
            let leftSample = Int32(max(min(left[index], 1), -1) * 8_388_607)
            let rightSample = Int32(max(min(right[index], 1), -1) * 8_388_607)
            pcm.append(UInt8(truncatingIfNeeded: leftSample))
            pcm.append(UInt8(truncatingIfNeeded: leftSample >> 8))
            pcm.append(UInt8(truncatingIfNeeded: leftSample >> 16))
            pcm.append(UInt8(truncatingIfNeeded: rightSample))
            pcm.append(UInt8(truncatingIfNeeded: rightSample >> 8))
            pcm.append(UInt8(truncatingIfNeeded: rightSample >> 16))
        }

        let byteRate = sampleRate * 6
        let blockAlign: UInt16 = 6
        let bitsPerSample: UInt16 = 24
        let subChunk2Size = UInt32(pcm.count)
        let chunkSize = UInt32(36) + subChunk2Size
        let subChunk1Size: UInt32 = 16
        let audioFormat: UInt16 = 1
        let numChannels: UInt16 = 2

        var wav = Data()
        wav.append("RIFF".data(using: .ascii)!)
        wav.append(contentsOf: withUnsafeBytes(of: chunkSize.littleEndian, Array.init))
        wav.append("WAVE".data(using: .ascii)!)
        wav.append("fmt ".data(using: .ascii)!)
        wav.append(contentsOf: withUnsafeBytes(of: subChunk1Size.littleEndian, Array.init))
        wav.append(contentsOf: withUnsafeBytes(of: audioFormat.littleEndian, Array.init))
        wav.append(contentsOf: withUnsafeBytes(of: numChannels.littleEndian, Array.init))
        wav.append(contentsOf: withUnsafeBytes(of: UInt32(sampleRate).littleEndian, Array.init))
        wav.append(contentsOf: withUnsafeBytes(of: UInt32(byteRate).littleEndian, Array.init))
        wav.append(contentsOf: withUnsafeBytes(of: blockAlign.littleEndian, Array.init))
        wav.append(contentsOf: withUnsafeBytes(of: bitsPerSample.littleEndian, Array.init))
        wav.append("data".data(using: .ascii)!)
        wav.append(contentsOf: withUnsafeBytes(of: subChunk2Size.littleEndian, Array.init))
        wav.append(pcm)
        return wav
    }
}

#if DEBUG
extension DrumMachineEngine {
    struct DebugSampleAsset {
        let sampleRate: Double
        let channelCount: AVAudioChannelCount
        let frameCount: AVAudioFramePosition
        let duration: Double
        let fileURL: URL
    }

    static func debugBuiltInDrumPackURLs() -> [URL] {
        bundledDrumPackURLs()
    }

    func debugSampleAsset(for index: Int) -> DebugSampleAsset? {
        guard let asset = sampleAssets[safe: index] ?? nil else { return nil }
        return DebugSampleAsset(
            sampleRate: asset.sampleRate,
            channelCount: asset.channelCount,
            frameCount: asset.frameCount,
            duration: asset.duration,
            fileURL: asset.fileURL
        )
    }

    func debugUsesProcessedPlayback(for index: Int, requestedRate: Double = 1.0, dryPreview: Bool = false) -> Bool {
        shouldUseProcessedPlayback(track: index, requestedRate: requestedRate, dryPreview: dryPreview)
    }

    func debugChokeGroup(for index: Int) -> Int? {
        chokeGroups[safe: index] ?? nil
    }

    func debugActiveVoiceCount(for index: Int) -> Int {
        cleanupInactiveVoices(for: index)
        return voicePools[safe: index]?.filter { $0.isActive }.count ?? 0
    }
}
#endif
