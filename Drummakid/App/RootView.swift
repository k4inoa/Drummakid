import AVFoundation
import QuartzCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

private enum ThemeAccent: String, CaseIterable, Identifiable {
    case red
    case orange
    case yellow
    case green
    case blue
    case indigo
    case violet

    static let storageKey = "themeAccent"

    var id: String { rawValue }

    var label: String {
        rawValue.capitalized
    }

    var accent: Color {
        switch self {
        case .red:
            return Color(red: 0.82, green: 0.2, blue: 0.2)
        case .orange:
            return Color(red: 0.9, green: 0.48, blue: 0.16)
        case .yellow:
            return Color(red: 0.88, green: 0.78, blue: 0.18)
        case .green:
            return Color(red: 0.18, green: 0.72, blue: 0.34)
        case .blue:
            return Color(red: 0.18, green: 0.48, blue: 0.86)
        case .indigo:
            return Color(red: 0.33, green: 0.34, blue: 0.8)
        case .violet:
            return Color(red: 0.62, green: 0.34, blue: 0.82)
        }
    }

    var neon: Color {
        switch self {
        case .red:
            return Color(red: 0.98, green: 0.38, blue: 0.34)
        case .orange:
            return Color(red: 0.99, green: 0.66, blue: 0.3)
        case .yellow:
            return Color(red: 0.99, green: 0.9, blue: 0.4)
        case .green:
            return Color(red: 0.42, green: 0.98, blue: 0.56)
        case .blue:
            return Color(red: 0.44, green: 0.78, blue: 1.0)
        case .indigo:
            return Color(red: 0.54, green: 0.6, blue: 1.0)
        case .violet:
            return Color(red: 0.84, green: 0.6, blue: 1.0)
        }
    }

    static var current: ThemeAccent {
        ThemeAccent(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? ThemeAccent.green.rawValue) ?? .green
    }
}

enum UITheme {
    static var accent: Color { ThemeAccent.current.accent }
    static let accentSoft = Color(red: 0.78, green: 0.78, blue: 0.78)
    static var neon: Color { ThemeAccent.current.neon }
    static let panelTop = Color(red: 0.135, green: 0.135, blue: 0.14).opacity(0.96)
    static let panelBottom = Color(red: 0.045, green: 0.045, blue: 0.05).opacity(0.98)
    static let panelInsetTop = Color(red: 0.19, green: 0.19, blue: 0.2)
    static let panelInsetBottom = Color(red: 0.075, green: 0.075, blue: 0.08)
    static let chromeTop = Color(red: 0.24, green: 0.24, blue: 0.25)
    static let chromeBottom = Color(red: 0.095, green: 0.095, blue: 0.1)
    static let bezel = Color(red: 0.43, green: 0.43, blue: 0.45)
    static let shadow = Color.black.opacity(0.42)
    static let screenLine = Color(red: 0.68, green: 0.68, blue: 0.68)
    static let hardEdge = Color(red: 0.31, green: 0.31, blue: 0.33)
}


struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase

    enum PadMode: String, CaseIterable {
        case drum = "Drum"
        case fx = "FX"
    }
    enum KnobBank: String, CaseIterable {
        case performance = "Perf"
        case fx = "FX"
    }

    @StateObject private var drumMachine = DrumMachineEngine()
    @AppStorage(ThemeAccent.storageKey) private var themeAccentRawValue = ThemeAccent.green.rawValue
    @State private var showingImporter = false
    @State private var showingSettings = false
    @State private var padMode: PadMode = .drum
    @State private var knobBank: KnobBank = .performance
    @State private var performanceKnobPage = 0
    private let drumPadIcons = [
        "waveform",                       // 1 bass drum
        "waveform.path",                  // 2 snare drum
        "speaker.wave.1.fill",            // 3 closed hi-hat
        "speaker.wave.2.fill",            // 4 open hi-hat
        "waveform.path.ecg",              // 5 808
        "cursorarrow.click.2",            // 6 sticks
        "bell.fill",                      // 7 cymbal
        "dot.radiowaves.left.and.right",  // 8 noise
        "hands.clap.fill",                // 9 hand clap
        "metronome",                      // 10 click
        "dial.low.fill",                  // 11 low tom
        "dial.high.fill",                 // 12 hi tom
        "bell.badge.fill",                // 13 cow bell
        "sparkles",                       // 14 blip
        "music.note",                     // 15 tone
        "music.note.list"                 // 16 bass tone
    ]
    private let fxPadNames = [
        "sample rate", "bit crush", "distortion", "delay",
        "reverb", "low pass", "high pass", "stutter",
        "repeat", "feedback", "chorus", "vibrato",
        "shuffle", "phaser", "gate", "width"
    ]

    var body: some View {
        GeometryReader { geometry in
            let layout = ResponsiveStageLayout(geometry: geometry)

            ZStack {
                backgroundGradient.ignoresSafeArea()

                VStack(spacing: 10) {
                    header
                    sequenceSection
                    padsSection
                    knobsSection
                }
                .padding(layout.contentPadding)
                .frame(width: layout.contentWidth, height: layout.baseHeight, alignment: .top)
                .id(themeAccentRawValue)
                .overlay {
                    TechGridOverlay()
                        .allowsHitTesting(false)
                        .opacity(0.1)
                }
                .scaleEffect(layout.scale, anchor: .top)
                .frame(width: layout.availableWidth, height: layout.availableHeight, alignment: .top)
                .padding(.top, layout.topInset)
                .padding(.bottom, layout.bottomInset)
                .padding(.horizontal, layout.outerPadding)
            }
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.audio, .folder],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case let .success(urls):
                drumMachine.loadDrumPack(from: urls)
            case .failure:
                drumMachine.statusMessage = "Could not open files. Try again."
            }
        }
        .onDisappear {
            drumMachine.stopPlayback()
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                drumMachine.handleAppBecameActive()
            case .background:
                drumMachine.handleAppEnteredBackground()
            case .inactive:
                break
            @unknown default:
                break
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
                .presentationCornerRadius(24)
                .presentationBackground(
                    LinearGradient(
                        colors: [Color(red: 0.04, green: 0.04, blue: 0.04), Color(red: 0.08, green: 0.08, blue: 0.08)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        }
        .fileExporter(
            isPresented: Binding(
                get: { drumMachine.exportedWAV != nil },
                set: { isPresented in
                    if !isPresented {
                        drumMachine.exportedWAV = nil
                    }
                }
            ),
            document: drumMachine.exportedWAV?.document,
            contentType: UTType(filenameExtension: "wav") ?? .audio,
            defaultFilename: drumMachine.exportedWAV?.defaultFilename
        ) { result in
            switch result {
            case let .success(url):
                drumMachine.statusMessage = "Saved \(url.lastPathComponent)."
            case .failure:
                drumMachine.statusMessage = "WAV export was cancelled or could not be saved."
            }
            drumMachine.exportedWAV = nil
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Button {
                        drumMachine.togglePlayback()
                    } label: {
                        Image(systemName: drumMachine.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 18, weight: .black))
                            .frame(width: 68, height: 36)
                            .foregroundStyle(drumMachine.isPlaying ? UITheme.neon : UITheme.accentSoft)
                    }
                    .buttonStyle(.plain)
                    .dawButtonChrome(active: drumMachine.isPlaying, led: true)
                    .accessibilityLabel(drumMachine.isPlaying ? "Pause playback" : "Start playback")
                    .accessibilityHint("Double tap to \(drumMachine.isPlaying ? "pause" : "start") the sequencer")

                    Button {
                        drumMachine.isMetronomeEnabled.toggle()
                    } label: {
                        Image(systemName: "metronome")
                            .font(.system(size: 15, weight: .bold))
                            .frame(width: 68, height: 36)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color(red: 0.9, green: 0.9, blue: 0.9))
                    .dawButtonChrome(active: drumMachine.isMetronomeEnabled, led: drumMachine.isMetronomeEnabled)
                    .accessibilityLabel("Metronome")
                    .accessibilityValue(drumMachine.isMetronomeEnabled ? "On" : "Off")
                    .accessibilityHint("Double tap to toggle the metronome")
                }

                HStack(spacing: 8) {
                    Button("Load") {
                        showingImporter = true
                    }
                    .buttonStyle(.plain)
                    .font(.system(.caption, design: .monospaced).weight(.bold))
                    .foregroundStyle(Color(red: 0.9, green: 0.9, blue: 0.9))
                    .frame(width: 68, height: 36)
                    .dawButtonChrome(active: false, led: true)
                    .accessibilityLabel("Load sixteen WAV files")
                    .accessibilityHint("You can choose WAV files or a folder that contains them")

                    Button("MIDI") {
                        drumMachine.isMIDIEnabled.toggle()
                    }
                    .buttonStyle(.plain)
                    .font(.system(.caption, design: .monospaced).weight(.bold))
                    .foregroundStyle(Color(red: 0.9, green: 0.9, blue: 0.9))
                    .frame(width: 68, height: 36)
                    .dawButtonChrome(active: drumMachine.isMIDIEnabled, led: drumMachine.isMIDIEnabled)
                    .accessibilityLabel("MIDI output")
                    .accessibilityValue(drumMachine.isMIDIEnabled ? "On" : "Off")
                    .accessibilityHint("Double tap to toggle sending MIDI notes to a connected DAW")
                }

                HStack(spacing: 8) {
                    Button {
                        drumMachine.toggleRecording()
                    } label: {
                        Text(drumMachine.isRecording ? "STOP" : "REC")
                            .font(.system(size: 13, weight: .black, design: .monospaced))
                            .frame(width: 68, height: 36)
                            .foregroundStyle(drumMachine.isRecording ? Color.black.opacity(0.9) : Color(red: 0.9, green: 0.9, blue: 0.9))
                    }
                    .buttonStyle(.plain)
                    .dawButtonChrome(active: drumMachine.isRecording, led: true)
                    .overlay(alignment: .topTrailing) {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 10, height: 10)
                            .overlay(
                                Circle()
                                    .stroke(Color.red.opacity(0.9), lineWidth: 1)
                            )
                            .shadow(color: drumMachine.isRecording ? Color.red.opacity(0.85) : .clear, radius: 5)
                            .scaleEffect(drumMachine.isRecording ? 1.0 : 0.7)
                            .opacity(drumMachine.isRecording ? 1.0 : 0.0)
                            .animation(
                                drumMachine.isRecording
                                    ? .easeInOut(duration: 0.65).repeatForever(autoreverses: true)
                                    : .easeOut(duration: 0.15),
                                value: drumMachine.isRecording
                            )
                            .offset(x: 3, y: -3)
                            .allowsHitTesting(false)
                    }
                    .accessibilityLabel(drumMachine.isRecording ? "Stop recording" : "Start recording")
                    .accessibilityValue(drumMachine.isRecording ? "Recording" : "Idle")
                    .accessibilityHint("Double tap to record live drums and the playing sequence")

                    Button("WAV") {
                        drumMachine.exportRecordingToWAV()
                    }
                    .buttonStyle(.plain)
                    .font(.system(.caption, design: .monospaced).weight(.bold))
                    .foregroundStyle(Color(red: 0.9, green: 0.9, blue: 0.9))
                    .frame(width: 68, height: 36)
                    .dawButtonChrome(active: drumMachine.hasPendingRecording, led: true)
                    .accessibilityLabel("Export WAV")
                    .accessibilityHint("Double tap to save the current recording or pattern as a WAV file in Files")
                }
            }

            Spacer(minLength: 0)

            VStack(spacing: 6) {
                Button {
                    showingSettings = true
                } label: {
                    TinyLogoMark(visualState: drumMachine.visualState)
                    .frame(width: 136, height: 124)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open settings")
                .accessibilityHint("Double tap to change theme colors or open how to")
            }
            .frame(width: 140, alignment: .center)
            .padding(.trailing, 4)
        }
    }

    private var sequenceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(drumMachine.sampleName(for: drumMachine.selectedTrack))
                    .font(.system(.subheadline, design: .monospaced).weight(.bold))
                    .foregroundStyle(Color(red: 0.9, green: 0.9, blue: 0.9))
                Image(systemName: drumPadIcons[drumMachine.selectedTrack])
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(UITheme.neon)
                Spacer()
                HStack(spacing: 6) {
                    Button {
                        drumMachine.undoLastClear()
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 13, weight: .bold))
                            .frame(minWidth: 20)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color(red: 0.88, green: 0.88, blue: 0.88).opacity(drumMachine.canUndoClear ? 1 : 0.35))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .dawButtonChrome(active: false, led: false)
                    .disabled(!drumMachine.canUndoClear)
                    .accessibilityLabel("Undo last clear")
                    .accessibilityHint(drumMachine.canUndoClear ? "Restores the phrase and FX state from before the last clear" : "Nothing to undo")

                    Button("Clear") {
                        drumMachine.clearCurrentPhrase()
                    }
                    .buttonStyle(.plain)
                    .font(.system(.caption, design: .monospaced).weight(.bold))
                    .foregroundStyle(Color(red: 0.88, green: 0.88, blue: 0.88))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .dawButtonChrome(active: false, led: false)
                    .accessibilityHint("Clears only the selected drum from the current phrase")

                    Button("Clear All") {
                        drumMachine.clearAllPhrases()
                    }
                    .buttonStyle(.plain)
                    .font(.system(.caption, design: .monospaced).weight(.bold))
                    .foregroundStyle(Color(red: 0.88, green: 0.88, blue: 0.88))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .dawButtonChrome(active: false, led: true)
                    .accessibilityHint("Clears every drum from the current phrase")
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Selected drum")
            .accessibilityValue("Pad \(drumMachine.selectedTrack + 1), \(drumMachine.sampleName(for: drumMachine.selectedTrack))")

            HStack(spacing: 8) {
                Text("Phrase")
                    .font(.system(.caption, design: .monospaced).weight(.bold))
                    .foregroundStyle(UITheme.accentSoft)

                HStack(spacing: 0) {
                    ForEach(DrumMachineEngine.PatternSlot.allCases, id: \.self) { slot in
                        phraseSlotButton(slot)
                    }
                }

                Spacer()
            }

            StepGridView(
                drumMachine: drumMachine,
                visualState: drumMachine.visualState,
                selectedTrack: drumMachine.selectedTrack,
                isPlaying: drumMachine.isPlaying
            )

        }
        .padding(10)
        .panelCardStyle()
    }

    private func phraseSlotButton(_ slot: DrumMachineEngine.PatternSlot) -> some View {
        let isSelected = drumMachine.displayedPatternSlot == slot
        return Button {
            drumMachine.selectedPatternSlot = slot
        } label: {
            Text(slot.label)
                .font(.system(.caption, design: .monospaced).weight(.bold))
                .foregroundStyle(isSelected ? Color(red: 0.92, green: 0.92, blue: 0.92) : Color(red: 0.76, green: 0.76, blue: 0.76))
                .frame(width: 42, height: 30)
                .dawButtonChrome(active: isSelected, led: isSelected)
                .offset(y: isSelected ? 1 : 0)
                .shadow(color: isSelected ? .black.opacity(0.55) : .black.opacity(0.2), radius: isSelected ? 1 : 0, y: isSelected ? 1 : 0)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Phrase \(slot.label)")
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityHint("Double tap to edit phrase \(slot.label)")
    }

    private var padsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Pads")
                    .font(.system(.subheadline, design: .monospaced).weight(.bold))
                    .foregroundStyle(Color(red: 0.9, green: 0.9, blue: 0.9))
                Spacer()
                HStack(spacing: 0) {
                    ForEach(PadMode.allCases, id: \.self) { mode in
                        Button(mode.rawValue) {
                            padMode = mode
                        }
                        .buttonStyle(.plain)
                        .font(.system(.caption, design: .monospaced).weight(.bold))
                        .foregroundStyle(Color(red: 0.9, green: 0.9, blue: 0.9))
                        .frame(width: 80, height: 30)
                        .dawButtonChrome(active: padMode == mode, led: padMode == mode)
                        .accessibilityValue(padMode == mode ? "Selected" : "Not selected")
                        .accessibilityHint("Double tap to switch pad mode")
                    }
                }
            }

            if padMode == .fx {
                HStack(spacing: 0) {
                    Button("Drum") {
                        drumMachine.fxEditLayer = .track
                    }
                    .buttonStyle(.plain)
                    .font(.system(.caption2, design: .monospaced).weight(.bold))
                    .foregroundStyle(Color(red: 0.9, green: 0.9, blue: 0.9))
                    .frame(width: 68, height: 24)
                    .dawButtonChrome(active: drumMachine.fxEditLayer == .track, led: drumMachine.fxEditLayer == .track)

                    Button("Master") {
                        drumMachine.fxEditLayer = .master
                    }
                    .buttonStyle(.plain)
                    .font(.system(.caption2, design: .monospaced).weight(.bold))
                    .foregroundStyle(Color(red: 0.9, green: 0.9, blue: 0.9))
                    .frame(width: 68, height: 24)
                    .dawButtonChrome(active: drumMachine.fxEditLayer == .master, led: drumMachine.fxEditLayer == .master)
                }
            }

            let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(0..<16, id: \.self) { index in
                    PadButtonView(
                        drumMachine: drumMachine,
                        visualState: drumMachine.visualState,
                        index: index,
                        padMode: padMode,
                        fxName: fxPadNames[index]
                    )
                }
            }
        }
        .padding(10)
        .panelCardStyle()
    }

    private var knobsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Control Knobs")
                    .font(.system(.subheadline, design: .monospaced).weight(.bold))
                    .foregroundStyle(Color(red: 0.9, green: 0.9, blue: 0.9))
                Spacer()
                HStack(spacing: 0) {
                    if knobBank == .performance {
                        Button("+") {
                            performanceKnobPage = performanceKnobPage == 0 ? 1 : 0
                        }
                        .buttonStyle(.plain)
                        .font(.system(.caption, design: .monospaced).weight(.bold))
                        .foregroundStyle(Color(red: 0.9, green: 0.9, blue: 0.9))
                        .frame(width: 34, height: 30)
                        .dawButtonChrome(active: false, led: true)
                        .accessibilityLabel("More drum knobs")
                        .accessibilityValue(performanceKnobPage == 0 ? "Main knobs shown" : "More knobs shown")
                        .accessibilityHint("Double tap to switch to the other four drum knobs")
                    }
                    ForEach(KnobBank.allCases, id: \.self) { bank in
                        Button {
                            knobBank = bank
                        } label: {
                            if bank == .performance {
                                Text("Drums")
                            } else {
                                Text(bank.rawValue)
                            }
                        }
                        .buttonStyle(.plain)
                        .font(.system(.caption, design: .monospaced).weight(.bold))
                        .foregroundStyle(Color(red: 0.9, green: 0.9, blue: 0.9))
                        .frame(width: 60, height: 30)
                        .dawButtonChrome(active: knobBank == bank, led: knobBank == bank)
                        .accessibilityLabel(bank == .performance ? "Drums" : bank.rawValue)
                        .accessibilityValue(knobBank == bank ? "Selected" : "Not selected")
                        .accessibilityHint("Double tap to switch knob bank")
                    }
                }
            }

            let knobColumns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)
            if knobBank == .performance {
                Group {
                    if performanceKnobPage == 0 {
                        LazyVGrid(columns: knobColumns, spacing: 10) {
                            KnobControl(label: "Tempo", value: $drumMachine.bpm, range: 40 ... 300, style: .integer)
                            KnobControl(label: "Volume", value: Binding(
                                get: { drumMachine.trackVolume(for: drumMachine.selectedTrack) },
                                set: { drumMachine.setTrackVolume($0, for: drumMachine.selectedTrack) }
                            ), range: 0 ... 1, style: .percentage)

                            KnobControl(label: "Pan", value: Binding(
                                get: { drumMachine.trackPan(for: drumMachine.selectedTrack) },
                                set: { drumMachine.setTrackPan($0, for: drumMachine.selectedTrack) }
                            ), range: -1 ... 1, style: .signed)

                            KnobControl(label: "Accent", value: Binding(
                                get: { drumMachine.trackAccent(for: drumMachine.selectedTrack) },
                                set: { drumMachine.setTrackAccent($0, for: drumMachine.selectedTrack) }
                            ), range: 0.5 ... 2.0, style: .decimal)
                        }
                    } else {
                        LazyVGrid(columns: knobColumns, spacing: 10) {
                            KnobControl(label: "Chance", value: Binding(
                                get: { drumMachine.trackProbability(for: drumMachine.selectedTrack) },
                                set: { drumMachine.setTrackProbability($0, for: drumMachine.selectedTrack) }
                            ), range: 0 ... 1, style: .percentage)

                            KnobControl(label: "Swing", value: Binding(
                                get: { drumMachine.trackSwing(for: drumMachine.selectedTrack) },
                                set: { drumMachine.setTrackSwing($0, for: drumMachine.selectedTrack) }
                            ), range: 0 ... 0.45, style: .percentage)
                            KnobControl(label: "Click", value: Binding(
                                get: { drumMachine.trackClick(for: drumMachine.selectedTrack) },
                                set: { drumMachine.setTrackClick($0, for: drumMachine.selectedTrack) }
                            ), range: 0 ... 1, style: .percentage)
                            KnobControl(label: "Tune", value: Binding(
                                get: { drumMachine.trackTune(for: drumMachine.selectedTrack) },
                                set: { drumMachine.setTrackTune($0, for: drumMachine.selectedTrack) }
                            ), range: -12 ... 12, style: .integer)
                        }
                    }
                }
            } else {
                LazyVGrid(columns: knobColumns, spacing: 10) {
                    KnobControl(label: "Filter", value: Binding(
                        get: { drumMachine.selectedFXFilterCutoff },
                        set: { drumMachine.selectedFXFilterCutoff = $0 }
                    ), range: 200 ... 12_000, style: .integer)
                    KnobControl(label: "Delay", value: Binding(
                        get: { drumMachine.selectedFXDelayMix },
                        set: { drumMachine.selectedFXDelayMix = $0 }
                    ), range: 0 ... 1, style: .percentage)
                    KnobControl(label: "Reverb", value: Binding(
                        get: { drumMachine.selectedFXReverbMix },
                        set: { drumMachine.selectedFXReverbMix = $0 }
                    ), range: 0 ... 1, style: .percentage)
                    KnobControl(label: "Stutter", value: Binding(
                        get: { drumMachine.selectedFXStutterAmount },
                        set: { drumMachine.selectedFXStutterAmount = $0 }
                    ), range: 0 ... 1, style: .percentage)
                }
            }
        }
        .padding(10)
        .panelCardStyle()
    }

    private var backgroundGradient: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.022, green: 0.022, blue: 0.024),
                    Color(red: 0.045, green: 0.045, blue: 0.048),
                    Color(red: 0.03, green: 0.03, blue: 0.032)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RadialGradient(
                colors: [
                    Color.white.opacity(0.045),
                    Color.clear
                ],
                center: .top,
                startRadius: 10,
                endRadius: 420
            )
        }
    }

}

private struct ResponsiveStageLayout {
    enum DeviceClass {
        case compactPhone
        case standardPhone
        case tablet
    }

    let deviceClass: DeviceClass
    let availableWidth: CGFloat
    let availableHeight: CGFloat
    let contentWidth: CGFloat
    let baseHeight: CGFloat
    let scale: CGFloat
    let outerPadding: CGFloat
    let contentPadding: CGFloat
    let topInset: CGFloat
    let bottomInset: CGFloat

    init(geometry: GeometryProxy) {
        let isTabletWidth = geometry.size.width >= 700
        let isCompactPhone = !isTabletWidth && (geometry.size.height < 760 || geometry.size.width < 360)

        if isTabletWidth {
            deviceClass = .tablet
        } else if isCompactPhone {
            deviceClass = .compactPhone
        } else {
            deviceClass = .standardPhone
        }

        switch deviceClass {
        case .compactPhone:
            outerPadding = 2
            contentPadding = 8
            topInset = 2
            bottomInset = 2
        case .standardPhone:
            outerPadding = 3
            contentPadding = 10
            topInset = 2
            bottomInset = 2
        case .tablet:
            outerPadding = 2
            contentPadding = 14
            topInset = 2
            bottomInset = 2
        }

        let rawAvailableWidth = max(geometry.size.width - (outerPadding * 2), 320)
        let rawAvailableHeight = max(
            geometry.size.height - topInset - bottomInset,
            480
        )

        let targetWidth: CGFloat
        let targetHeight: CGFloat
        let maxScale: CGFloat

        switch deviceClass {
        case .compactPhone:
            targetWidth = min(rawAvailableWidth, 410)
            targetHeight = 720
            maxScale = 1.0
        case .standardPhone:
            targetWidth = min(rawAvailableWidth, 430)
            targetHeight = 735
            maxScale = 1.07
        case .tablet:
            targetWidth = min(rawAvailableWidth, 640)
            targetHeight = 760
            maxScale = 1.75
        }

        let widthScale = rawAvailableWidth / targetWidth
        let heightScale = rawAvailableHeight / targetHeight

        availableWidth = rawAvailableWidth
        availableHeight = rawAvailableHeight
        contentWidth = targetWidth
        baseHeight = targetHeight
        scale = min(widthScale, heightScale, maxScale)
    }
}

private struct TinyLogoMark: View {
    // Observes visualState directly (instead of receiving drummerPose as a plain value
    // read by RootView) so a pose change redraws only this small logo, not the whole
    // RootView tree.
    @ObservedObject var visualState: PlaybackVisualState

    var body: some View {
        Image(visualState.drummerPose.assetName)
            .resizable()
            .interpolation(.high)
            .antialiased(true)
            .aspectRatio(contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .opacity(0.82)
            .shadow(color: Color.white.opacity(0.08), radius: 3)
            .animation(.easeOut(duration: 0.08), value: visualState.drummerPose)
            .clipped()
            .accessibilityHidden(true)
    }
}

private struct StepGridView: View {
    // Must be @ObservedObject, not a plain reference: stepColor/stepIsActive read
    // pattern data (steps, slotPatterns) that isn't exposed as one of this view's own
    // stored properties, so without a subscription here SwiftUI has no way to know a
    // step toggle or Clear/Clear All changed anything -- it only re-diffs this view when
    // one of its own declared properties' values actually differ between renders (which
    // selectedTrack/isPlaying do on track or transport changes, but a step edit does
    // not). visualState stays separately observed for the high-frequency currentStep tick.
    @ObservedObject var drumMachine: DrumMachineEngine
    @ObservedObject var visualState: PlaybackVisualState
    let selectedTrack: Int
    let isPlaying: Bool

    private var visibleSteps: [Int] {
        Array(0..<16)
    }

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 16), spacing: 6) {
            ForEach(visibleSteps, id: \.self) { step in
                Button {
                    drumMachine.handleStepTap(track: selectedTrack, step: step)
                } label: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(drumMachine.stepColor(track: selectedTrack, step: step))
                            .shadow(color: .black.opacity(0.18), radius: 4, y: 2)

                        if visualState.currentStep == step && isPlaying {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .stroke(UITheme.neon, lineWidth: 2)
                        }
                    }
                    .frame(height: 36)
                    .overlay(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .inset(by: 1)
                            .stroke(Color.black.opacity(0.4), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Step \(step + 1)")
                .accessibilityValue(stepAccessibilityValue(step))
                .accessibilityHint("Double tap to toggle this step for the selected drum")
            }
        }
    }

    private func stepAccessibilityValue(_ step: Int) -> String {
        let isActive = drumMachine.stepIsActive(track: selectedTrack, step: step)
        let isCurrent = isPlaying && visualState.currentStep == step
        if isCurrent {
            return isActive ? "On, current step" : "Off, current step"
        }
        return isActive ? "On" : "Off"
    }
}

private struct PadButtonView: View {
    // Must be @ObservedObject -- see StepGridView's comment. isFXActive/isSelected read
    // FX preset state that isn't one of this view's own stored properties, so a preset
    // toggle needs a real subscription to be reflected; visualState stays separately
    // observed for the high-frequency trigger pulse.
    @ObservedObject var drumMachine: DrumMachineEngine
    @ObservedObject var visualState: PlaybackVisualState
    let index: Int
    let padMode: RootView.PadMode
    let fxName: String

    private var isFXActive: Bool {
        padMode == .fx && drumMachine.isFXPresetActive(index + 1)
    }
    private var isSelected: Bool {
        padMode == .drum
            ? drumMachine.selectedTrack == index
            : drumMachine.isFXPresetSelected(index + 1)
    }
    private var isTriggered: Bool {
        padMode == .drum && visualState.isPadTriggered(index)
    }

    var body: some View {
        let content =
            ZStack {
                if padMode == .drum {
                    EmptyView()
                } else {
                    Text(fxName)
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                        .padding(.horizontal, 4)
                        .foregroundStyle(isSelected ? .black.opacity(0.9) : UITheme.accentSoft)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 58)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: isSelected
                                ? [UITheme.neon, UITheme.accent]
                                : isTriggered
                                ? [UITheme.accent.opacity(0.88), UITheme.accent.opacity(0.34)]
                                : [UITheme.chromeTop.opacity(0.82), UITheme.chromeBottom.opacity(0.92)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(
                        (isSelected || isTriggered)
                            ? UITheme.neon.opacity(0.9)
                            : UITheme.bezel.opacity(0.3),
                        lineWidth: 1
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .inset(by: 1)
                    .stroke(Color.black.opacity(0.45), lineWidth: 1)
            )
            .overlay(alignment: .topLeading) {
                Text("\(index + 1)")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle((isSelected || isTriggered) ? .black.opacity(0.9) : Color(red: 0.72, green: 0.72, blue: 0.72))
                    .padding(6)
            }
            .overlay(alignment: .topTrailing) {
                Circle()
                    .fill(
                        (isSelected || isTriggered)
                            ? UITheme.neon
                            : isFXActive
                            ? UITheme.accent.opacity(0.8)
                            : UITheme.accentSoft.opacity(0.45)
                    )
                    .frame(width: 5, height: 5)
                    .shadow(
                        color: isFXActive ? UITheme.neon.opacity(0.35) : .clear,
                        radius: isFXActive ? 3 : 0
                    )
                    .padding(6)
            }
            .shadow(color: (isSelected || isTriggered) ? UITheme.neon.opacity(0.4) : .black.opacity(0.25), radius: 4, y: 2)
            .scaleEffect(isTriggered ? 1.03 : 1.0)
            .animation(.easeOut(duration: 0.1), value: isTriggered)
            .foregroundStyle(Color(red: 0.88, green: 0.88, blue: 0.88))
        return Group {
            if padMode == .drum {
                Button {
                    drumMachine.handlePadTap(index: index)
                } label: {
                    content
                }
                .buttonStyle(.plain)
            } else {
                content
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        guard let preset = DrumMachineEngine.FXPreset(rawValue: index + 1) else { return }
                        drumMachine.disableFXPreset(preset)
                    }
                    .onTapGesture {
                        guard let preset = DrumMachineEngine.FXPreset(rawValue: index + 1) else { return }
                        drumMachine.selectOrEnableFXPreset(preset)
                    }
            }
        }
        .accessibilityLabel(padMode == .drum ? "Drum pad \(index + 1)" : "FX pad \(index + 1)")
        .accessibilityValue(padAccessibilityValue)
        .accessibilityHint(padMode == .drum ? "Double tap to trigger and select this drum" : "Single tap to enable or select this effect. Double tap to disable it.")
    }

    private var padAccessibilityValue: String {
        if padMode == .drum {
            let sampleName = drumMachine.sampleName(for: index)
            if isTriggered {
                return "\(sampleName), triggered"
            }
            return isSelected ? "\(sampleName), selected" : sampleName
        }

        if isSelected {
            return "\(fxName), selected"
        }
        return drumMachine.isFXPresetActive(index + 1) ? "\(fxName), active" : fxName
    }
}

/// Gives every tappable control in Settings a soft scale/opacity dip on press. The rest of
/// the app relies on dawButtonChrome's static active/inactive coloring alone with no touch
/// feedback; Settings is where that starts to read as unresponsive rather than minimal, so
/// it gets this instead.
private struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .opacity(configuration.isPressed ? 0.85 : 1.0)
            .animation(.spring(response: 0.28, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

private struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(ThemeAccent.storageKey) private var themeAccentRawValue = ThemeAccent.green.rawValue
    @State private var showingHowTo = false
    @State private var selectedHelpTopic: HelpTopic = .pads

    private enum HelpTopic: String, CaseIterable, Identifiable {
        case pads = "Pads"
        case sequencing = "Sequencing"
        case fx = "FX"
        case importPack = "Load"
        case recording = "REC / WAV"

        var id: String { rawValue }

        var bodyText: String {
            switch self {
            case .pads:
                return "Tap a drum pad to hear it and select it. The selected drum is the one edited by the steps, drum knobs, and FX pads."
            case .sequencing:
                return "The 16 steps edit the selected drum inside the current phrase. A, B, C, and D each keep their own pattern. Clear removes the selected drum from the current phrase. Clear All wipes the whole current phrase."
            case .fx:
                return "FX mode has two layers: Drum and Master. Drum FX are saved per selected drum. Master FX affect the full mix. Single tap an FX pad to enable it and focus its knobs. Single tap another FX to switch editing without disabling the first one. Double tap an FX pad to disable it on the current layer."
            case .importPack:
                return "Load imports WAV files or a folder. Up to 16 sounds are mapped into the pads, and any missing slots are filled with built-in sounds."
            case .recording:
                return "REC captures live pad taps and sequencer playback. WAV exports the take. If nothing was recorded, WAV exports the current pattern chain instead. Files save to Files > On My iPhone > drummakid > Exports."
            }
        }
    }

    private var selectedTheme: ThemeAccent {
        ThemeAccent(rawValue: themeAccentRawValue) ?? .green
    }

    private var appVersionLabel: String {
        let shortVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "drummakid \u{2022} v\(shortVersion) (\(build))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Capsule()
                .fill(UITheme.bezel.opacity(0.7))
                .frame(width: 42, height: 5)
                .frame(maxWidth: .infinity)
                .padding(.top, 6)

            header
            appearanceSection
            helpSection

            Spacer(minLength: 0)

            Text(appVersionLabel)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.35))
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(14)
        .overlay {
            TechGridOverlay()
                .allowsHitTesting(false)
                .opacity(0.08)
        }
        .background(
            LinearGradient(
                colors: [Color(red: 0.04, green: 0.04, blue: 0.04), Color(red: 0.08, green: 0.08, blue: 0.08)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(UITheme.bezel.opacity(0.5), lineWidth: 1)
                .ignoresSafeArea()
        )
        .overlay { helpOverlay }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Settings")
                .font(.system(.headline, design: .monospaced).weight(.bold))
                .foregroundStyle(Color.white)
            Spacer()
            Button {
                dismiss()
            } label: {
                Text("Done")
                    .font(.system(.caption, design: .monospaced).weight(.bold))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            }
            .buttonStyle(PressableButtonStyle())
            .dawButtonChrome(active: false, led: false)
        }
        .padding(14)
        .panelCardStyle()
    }

    private func sectionHeader(icon: String, title: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(UITheme.neon)
            Text(title)
                .font(.system(.subheadline, design: .monospaced).weight(.bold))
                .foregroundStyle(Color.white)
        }
    }

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(icon: "paintpalette.fill", title: "Appearance")

            let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(ThemeAccent.allCases) { theme in
                    Button {
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.72)) {
                            themeAccentRawValue = theme.rawValue
                        }
                    } label: {
                        VStack(spacing: 8) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(theme.neon)
                                    .frame(height: 30)
                                if selectedTheme == theme {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 15, weight: .bold))
                                        .foregroundStyle(Color.black.opacity(0.75))
                                        .transition(.scale.combined(with: .opacity))
                                }
                            }
                            .overlay(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .stroke(Color.white.opacity(selectedTheme == theme ? 0.9 : 0.2), lineWidth: selectedTheme == theme ? 2 : 1)
                            )
                            Text(theme.label)
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(Color.white.opacity(selectedTheme == theme ? 0.95 : 0.6))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(Color.white.opacity(selectedTheme == theme ? 0.09 : 0.03))
                        )
                        .scaleEffect(selectedTheme == theme ? 1.03 : 1.0)
                    }
                    .buttonStyle(PressableButtonStyle())
                }
            }
        }
        .padding(14)
        .panelCardStyle()
    }

    private var helpSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(icon: "questionmark.circle.fill", title: "Help & Guide")

            Text("Quick reference for pads, sequencing, FX, and exporting.")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)

            Button {
                withAnimation(.easeOut(duration: 0.22)) {
                    showingHowTo = true
                }
            } label: {
                HStack {
                    Text("View Guide")
                        .font(.system(.caption, design: .monospaced).weight(.bold))
                        .foregroundStyle(Color.white)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.5))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle())
            .dawButtonChrome(active: false, led: false)
            .accessibilityHint("Shows instructions for import, recording, and export")
        }
        .padding(14)
        .panelCardStyle()
    }

    @ViewBuilder
    private var helpOverlay: some View {
        if showingHowTo {
            ZStack {
                Color.black.opacity(0.6)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.easeOut(duration: 0.2)) {
                            showingHowTo = false
                        }
                    }
                    .transition(.opacity)

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Help")
                            .font(.system(.headline, design: .monospaced).weight(.bold))
                            .foregroundStyle(Color.white)
                        Spacer()
                        Button {
                            withAnimation(.easeOut(duration: 0.2)) {
                                showingHowTo = false
                            }
                        } label: {
                            Text("Close")
                                .font(.system(.caption, design: .monospaced).weight(.bold))
                                .foregroundStyle(Color.white)
                        }
                        .buttonStyle(PressableButtonStyle())
                    }

                    let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 2)
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(HelpTopic.allCases) { topic in
                            Button {
                                withAnimation(.easeInOut(duration: 0.16)) {
                                    selectedHelpTopic = topic
                                }
                            } label: {
                                Text(topic.rawValue)
                                    .font(.system(.caption, design: .monospaced).weight(.bold))
                                    .foregroundStyle(Color.white)
                                    .frame(maxWidth: .infinity)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 9)
                                    .contentShape(Rectangle())
                                    .dawButtonChrome(active: selectedHelpTopic == topic, led: selectedHelpTopic == topic)
                            }
                            .buttonStyle(PressableButtonStyle())
                        }
                    }

                    Text(selectedHelpTopic.bodyText)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                        .id(selectedHelpTopic)
                        .transition(.opacity)
                }
                .padding(14)
                .frame(maxWidth: 340)
                .panelCardStyle()
                .transition(.scale(scale: 0.94).combined(with: .opacity))
            }
        }
    }
}

private struct KnobControl: View {
    enum ValueStyle {
        case percentage
        case signed
        case decimal
        case integer
    }

    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let style: ValueStyle
    var accessibilityLabelOverride: String? = nil
    var accessibilityHintText: String? = nil

    @State private var dragStartValue: Double?

    private var normalized: Double {
        let width = range.upperBound - range.lowerBound
        guard width > 0 else { return 0 }
        return (value - range.lowerBound) / width
    }

    private var angle: Double {
        // 270-degree travel from 135 to 405.
        135 + (normalized * 270)
    }

    private var knobDragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { drag in
                if dragStartValue == nil {
                    dragStartValue = value
                }

                let movement = drag.translation.width - drag.translation.height
                let raw = (dragStartValue ?? value) + (movement * dragSensitivity)
                guard raw.isFinite else { return }
                setValue(raw)
            }
            .onEnded { _ in
                dragStartValue = nil
            }
    }

    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [UITheme.panelInsetTop, UITheme.panelInsetBottom],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(UITheme.bezel.opacity(0.3), lineWidth: 1)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .inset(by: 1)
                            .stroke(Color.black.opacity(0.45), lineWidth: 1)
                    )

                ZStack {
                    Circle()
                        .stroke(UITheme.bezel.opacity(0.22), lineWidth: 2)

                    ForEach(0..<16, id: \.self) { tick in
                        Capsule()
                            .fill(tick <= Int(normalized * 15) ? UITheme.neon.opacity(0.96) : UITheme.bezel.opacity(0.28))
                            .frame(width: 2, height: tick.isMultiple(of: 4) ? 8 : 6)
                            .offset(y: -23)
                            .rotationEffect(.degrees(Double(tick) * 16.875 + 135))
                    }

                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [Color(red: 0.78, green: 0.78, blue: 0.8), Color(red: 0.32, green: 0.32, blue: 0.34)],
                                center: .topLeading,
                                startRadius: 2,
                                endRadius: 24
                            )
                        )
                        .overlay(
                            Circle().stroke(Color.white.opacity(0.18), lineWidth: 0.8)
                        )
                        .padding(8)

                    Capsule()
                        .fill(Color.black.opacity(0.82))
                        .frame(width: 4, height: 12)
                        .offset(y: -12)
                        .rotationEffect(.degrees(angle))

                    Circle()
                        .fill(Color.black.opacity(0.5))
                        .frame(width: 6, height: 6)
                }
                .padding(4)
            }
            .frame(width: 54, height: 54)

            Text(label)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(Color(red: 0.9, green: 0.9, blue: 0.9))
                .lineLimit(1)
            Text(valueText)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(Color(red: 0.68, green: 0.68, blue: 0.7))
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .highPriorityGesture(knobDragGesture)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabelOverride ?? label)
        .accessibilityValue(valueText)
        .accessibilityHint(accessibilityHintText ?? "Swipe up or down to adjust")
        .accessibilityAdjustableAction { direction in
            let step: Double
            switch style {
            case .integer:
                step = 1
            case .percentage:
                step = max((range.upperBound - range.lowerBound) / 20, 0.01)
            case .signed, .decimal:
                step = max((range.upperBound - range.lowerBound) / 50, 0.01)
            }

            switch direction {
            case .increment:
                setValue(value + step)
            case .decrement:
                setValue(value - step)
            @unknown default:
                break
            }
        }
    }

    private var valueText: String {
        guard value.isFinite else { return "--" }
        switch style {
        case .percentage:
            return "\(Int(value * 100))%"
        case .signed:
            return String(format: "%.2f", value)
        case .decimal:
            return String(format: "%.2f", value)
        case .integer:
            return "\(Int(value))"
        }
    }

    private var dragSensitivity: Double {
        let width = range.upperBound - range.lowerBound
        guard width > 0 else { return 0 }

        switch style {
        case .integer:
            if width <= 24 {
                return 0.125
            } else if width <= 120 {
                return 0.08
            } else {
                return width / 900
            }
        case .percentage:
            return width / 260
        case .signed, .decimal:
            return width / 320
        }
    }

    private func setValue(_ newValue: Double) {
        let clamped = min(max(newValue, range.lowerBound), range.upperBound)
        if style == .integer {
            value = clamped.rounded()
        } else {
            value = clamped
        }
    }
}

private struct PanelCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [UITheme.panelTop, UITheme.panelBottom],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )

                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.white.opacity(0.035), Color.clear],
                                startPoint: .top,
                                endPoint: .center
                            )
                        )
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(UITheme.bezel.opacity(0.34), lineWidth: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .inset(by: 1)
                    .strokeBorder(UITheme.hardEdge.opacity(0.4), lineWidth: 1)
            )
            .shadow(color: UITheme.shadow, radius: 10, y: 3)
    }
}

private struct DawButtonChromeModifier: ViewModifier {
    let active: Bool
    let led: Bool

    func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: active
                                    ? [UITheme.accent.opacity(0.46), UITheme.accent.opacity(0.16)]
                                    : [UITheme.chromeTop, UITheme.chromeBottom],
                                startPoint: .topLeading,
                                endPoint: .bottom
                            )
                        )
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(active ? UITheme.neon.opacity(0.45) : UITheme.bezel.opacity(0.45), lineWidth: 1)
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .inset(by: 1)
                        .stroke(Color.black.opacity(0.52), lineWidth: 1)
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .inset(by: 1.5)
                        .fill(
                            LinearGradient(
                                colors: [Color.white.opacity(active ? 0.08 : 0.05), Color.clear],
                                startPoint: .top,
                                endPoint: .center
                            )
                        )
                }
            )
            .shadow(color: .black.opacity(active ? 0.56 : 0.38), radius: active ? 4 : 2, y: active ? 2 : 1)
    }
}

private struct TechGridOverlay: View {
    var body: some View {
        GeometryReader { proxy in
            Path { path in
                let step: CGFloat = 22
                let width = proxy.size.width
                let height = proxy.size.height

                var x: CGFloat = 0
                while x <= width {
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: height))
                    x += step
                }

                var y: CGFloat = 0
                while y <= height {
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: width, y: y))
                    y += step
                }
            }
            .stroke(UITheme.screenLine.opacity(0.2), lineWidth: 0.5)
        }
    }
}

private extension View {
    func panelCardStyle() -> some View {
        modifier(PanelCardModifier())
    }

    func dawButtonChrome(active: Bool, led: Bool) -> some View {
        modifier(DawButtonChromeModifier(active: active, led: led))
    }
}
