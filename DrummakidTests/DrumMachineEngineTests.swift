import AVFoundation
import XCTest
@testable import Drummakid

@MainActor
final class DrumMachineEngineTests: XCTestCase {
    func testBuiltInDrumPackProvidesSixteenBundledWAVs() {
        let urls = DrumMachineEngine.debugBuiltInDrumPackURLs()

        XCTAssertEqual(urls.count, 16)
        if urls.count >= 5 {
            XCTAssertTrue(urls[4].lastPathComponent.contains("05_808"))
        }
    }

    func testImportPreservesLongSampleMetadata() throws {
        let url = try makeTestWAV(
            name: "long-808",
            sampleRate: 44_100,
            channels: 1,
            duration: 1.6,
            frequency: 55
        )
        let engine = DrumMachineEngine()

        engine.loadDrumPack(from: [url])

        let asset = try XCTUnwrap(engine.debugSampleAsset(for: 0))
        XCTAssertEqual(asset.sampleRate, 44_100, accuracy: 0.5)
        XCTAssertEqual(asset.channelCount, 1)
        XCTAssertGreaterThan(asset.duration, 1.5)
    }

    func testImportPreservesStereoMetadata() throws {
        let url = try makeTestWAV(
            name: "stereo-tone",
            sampleRate: 48_000,
            channels: 2,
            duration: 0.5,
            frequency: 220
        )
        let engine = DrumMachineEngine()

        engine.loadDrumPack(from: [url])

        let asset = try XCTUnwrap(engine.debugSampleAsset(for: 0))
        XCTAssertEqual(asset.sampleRate, 48_000, accuracy: 0.5)
        XCTAssertEqual(asset.channelCount, 2)
    }

    func testImportPreservesDrumKnobValues() throws {
        let url = try makeTestWAV(
            name: "new-kick",
            sampleRate: 44_100,
            channels: 1,
            duration: 0.4,
            frequency: 90
        )
        let engine = DrumMachineEngine()

        engine.setTrackVolume(0.35, for: 0)
        engine.setTrackPan(-0.6, for: 0)
        engine.setTrackSwing(0.2, for: 0)
        engine.setTrackClick(0.7, for: 0)
        engine.setTrackTune(7, for: 0)
        engine.loadDrumPack(from: [url])

        XCTAssertEqual(engine.trackVolume(for: 0), 0.35, accuracy: 0.001)
        XCTAssertEqual(engine.trackPan(for: 0), -0.6, accuracy: 0.001)
        XCTAssertEqual(engine.trackSwing(for: 0), 0.2, accuracy: 0.001)
        XCTAssertEqual(engine.trackClick(for: 0), 0.7, accuracy: 0.001)
        XCTAssertEqual(engine.trackTune(for: 0), 7, accuracy: 0.001)
    }

    func testClearAllPhrasesTurnsOffTrackAndMasterFX() {
        let engine = DrumMachineEngine()

        engine.selectOrEnableFXPreset(.delay)
        XCTAssertTrue(engine.isFXPresetActive(DrumMachineEngine.FXPreset.delay.rawValue))

        engine.fxEditLayer = .master
        engine.selectOrEnableFXPreset(.reverb)
        XCTAssertTrue(engine.isFXPresetActive(DrumMachineEngine.FXPreset.reverb.rawValue))

        engine.fxEditLayer = .track
        engine.clearAllPhrases()

        XCTAssertFalse(engine.isFXPresetActive(DrumMachineEngine.FXPreset.delay.rawValue))

        engine.fxEditLayer = .master
        XCTAssertFalse(engine.isFXPresetActive(DrumMachineEngine.FXPreset.reverb.rawValue))
    }

    func testDryPlaybackUsesSourcePathUntilProcessingIsNeeded() {
        let engine = DrumMachineEngine()

        XCTAssertFalse(engine.debugUsesProcessedPlayback(for: 0))

        engine.setTrackTune(2, for: 0)

        XCTAssertTrue(engine.debugUsesProcessedPlayback(for: 0))
    }

    func testDefaultChokeGroupsSelfChokeEachPad() {
        let engine = DrumMachineEngine()

        XCTAssertEqual(engine.debugChokeGroup(for: 0), 1)
        XCTAssertEqual(engine.debugChokeGroup(for: 4), 5)
        XCTAssertNotEqual(engine.debugChokeGroup(for: 2), engine.debugChokeGroup(for: 3))

        engine.handlePadTap(index: 4)
        XCTAssertGreaterThan(engine.debugActiveVoiceCount(for: 4), 0)

        engine.handlePadTap(index: 4)

        XCTAssertEqual(engine.debugActiveVoiceCount(for: 4), 1)
    }

    func testPadsDoNotChokeOtherPadsByDefault() {
        let engine = DrumMachineEngine()

        engine.handlePadTap(index: 3)
        XCTAssertGreaterThan(engine.debugActiveVoiceCount(for: 3), 0)

        engine.handlePadTap(index: 2)

        XCTAssertGreaterThan(engine.debugActiveVoiceCount(for: 3), 0)
        XCTAssertGreaterThan(engine.debugActiveVoiceCount(for: 2), 0)
    }

    func testClearAllPhrasesClearsEveryPhraseSlot() {
        let engine = DrumMachineEngine()

        for slot in DrumMachineEngine.PatternSlot.allCases {
            engine.selectedPatternSlot = slot
            engine.handleStepTap(track: 0, step: 0)
        }
        for slot in DrumMachineEngine.PatternSlot.allCases {
            engine.selectedPatternSlot = slot
            XCTAssertTrue(engine.stepIsActive(track: 0, step: 0), "expected phrase \(slot) to have an active step before clearing")
        }

        engine.selectedPatternSlot = .a
        engine.clearAllPhrases()

        for slot in DrumMachineEngine.PatternSlot.allCases {
            engine.selectedPatternSlot = slot
            XCTAssertFalse(engine.stepIsActive(track: 0, step: 0), "expected phrase \(slot) to be cleared by Clear All")
        }
    }

    func testClearCurrentPhraseClearsOnlySelectedTrack() {
        let engine = DrumMachineEngine()

        engine.selectedTrack = 0
        engine.handleStepTap(track: 0, step: 0)
        engine.selectedTrack = 1
        engine.handleStepTap(track: 1, step: 0)

        engine.selectedTrack = 0
        engine.clearCurrentPhrase()

        XCTAssertFalse(engine.stepIsActive(track: 0, step: 0), "Clear should wipe the selected track")
        XCTAssertTrue(engine.stepIsActive(track: 1, step: 0), "Clear should not touch other tracks")
    }

    func testUndoRestoresClearedStep() {
        let engine = DrumMachineEngine()

        engine.selectedTrack = 0
        engine.handleStepTap(track: 0, step: 0)
        XCTAssertFalse(engine.canUndoClear)

        engine.clearCurrentPhrase()
        XCTAssertFalse(engine.stepIsActive(track: 0, step: 0))
        XCTAssertTrue(engine.canUndoClear)

        engine.undoLastClear()

        XCTAssertTrue(engine.stepIsActive(track: 0, step: 0), "Undo should restore the step Clear wiped")
        XCTAssertFalse(engine.canUndoClear, "Undo is one-slot: once used, there's nothing left to undo")
    }

    func testUndoRestoresClearAllPhrasesAndFX() {
        let engine = DrumMachineEngine()

        engine.selectedTrack = 0
        engine.handleStepTap(track: 0, step: 0)
        engine.selectOrEnableFXPreset(.reverb)
        engine.fxEditLayer = .master
        engine.selectOrEnableFXPreset(.delay)
        engine.fxEditLayer = .track

        engine.clearAllPhrases()
        XCTAssertFalse(engine.stepIsActive(track: 0, step: 0))
        XCTAssertFalse(engine.isFXPresetActive(DrumMachineEngine.FXPreset.reverb.rawValue))

        engine.undoLastClear()

        XCTAssertTrue(engine.stepIsActive(track: 0, step: 0), "Undo should restore the cleared step")
        XCTAssertTrue(engine.isFXPresetActive(DrumMachineEngine.FXPreset.reverb.rawValue), "Undo should restore track FX Clear All turned off")
        engine.fxEditLayer = .master
        XCTAssertTrue(engine.isFXPresetActive(DrumMachineEngine.FXPreset.delay.rawValue), "Undo should restore master FX Clear All turned off")
    }

    func testAccentAndChanceStayWithTrackAcrossPhrases() {
        let engine = DrumMachineEngine()

        engine.setTrackAccent(1.75, for: 0)
        engine.setTrackProbability(0.4, for: 0)

        engine.selectedPatternSlot = .a
        XCTAssertEqual(engine.trackAccent(for: 0), 1.75, accuracy: 0.001)
        XCTAssertEqual(engine.trackProbability(for: 0), 0.4, accuracy: 0.001)

        engine.selectedPatternSlot = .b
        XCTAssertEqual(engine.trackAccent(for: 0), 1.75, accuracy: 0.001, "Accent is a track property; it must not reset when switching phrases")
        XCTAssertEqual(engine.trackProbability(for: 0), 0.4, accuracy: 0.001, "Chance is a track property; it must not reset when switching phrases")
    }

    func testExportAppliesActiveFXToAudio() throws {
        let url = try makeTestWAV(name: "tone-test", sampleRate: 44_100, channels: 1, duration: 0.3, frequency: 440)
        let engine = DrumMachineEngine()
        engine.loadDrumPack(from: [url])
        engine.selectedTrack = 0
        engine.handleStepTap(track: 0, step: 0)

        engine.exportRecordingToWAV()
        let dryData = try XCTUnwrap(engine.exportedWAV?.document.data, "dry export should succeed")
        engine.exportedWAV = nil

        engine.selectOrEnableFXPreset(.reverb)
        engine.exportRecordingToWAV()
        let wetData = try XCTUnwrap(engine.exportedWAV?.document.data, "export with FX active should succeed")

        XCTAssertNotEqual(dryData, wetData, "an export made with FX active must audibly differ from a dry export -- FX must not be silently dropped from exports")
    }

    private func makeTestWAV(
        name: String,
        sampleRate: Int,
        channels: Int,
        duration: Double,
        frequency: Double
    ) throws -> URL {
        let frames = Int(Double(sampleRate) * duration)
        let bytesPerSample = 2
        let blockAlign = channels * bytesPerSample
        let byteRate = sampleRate * blockAlign
        var pcm = Data(capacity: frames * blockAlign)

        for frame in 0..<frames {
            let t = Double(frame) / Double(sampleRate)
            let amplitude = Int16(max(min(sin(2 * .pi * frequency * t) * 0.8, 1), -1) * Double(Int16.max))
            for channel in 0..<channels {
                let sample = channel == 1 ? Int16(amplitude / 2) : amplitude
                var littleEndian = sample.littleEndian
                withUnsafeBytes(of: &littleEndian) { pcm.append(contentsOf: $0) }
            }
        }

        let subchunk2Size = UInt32(pcm.count)
        let chunkSize = UInt32(36) + subchunk2Size
        var wav = Data()
        wav.append("RIFF".data(using: .ascii)!)
        wav.append(contentsOf: withUnsafeBytes(of: chunkSize.littleEndian, Array.init))
        wav.append("WAVE".data(using: .ascii)!)
        wav.append("fmt ".data(using: .ascii)!)

        let subChunk1Size: UInt32 = 16
        let audioFormat: UInt16 = 1
        let numChannels = UInt16(channels)
        let sr = UInt32(sampleRate)
        let byteRateLE = UInt32(byteRate)
        let blockAlignLE = UInt16(blockAlign)
        let bitsPerSample: UInt16 = 16
        wav.append(contentsOf: withUnsafeBytes(of: subChunk1Size.littleEndian, Array.init))
        wav.append(contentsOf: withUnsafeBytes(of: audioFormat.littleEndian, Array.init))
        wav.append(contentsOf: withUnsafeBytes(of: numChannels.littleEndian, Array.init))
        wav.append(contentsOf: withUnsafeBytes(of: sr.littleEndian, Array.init))
        wav.append(contentsOf: withUnsafeBytes(of: byteRateLE.littleEndian, Array.init))
        wav.append(contentsOf: withUnsafeBytes(of: blockAlignLE.littleEndian, Array.init))
        wav.append(contentsOf: withUnsafeBytes(of: bitsPerSample.littleEndian, Array.init))
        wav.append("data".data(using: .ascii)!)
        wav.append(contentsOf: withUnsafeBytes(of: subchunk2Size.littleEndian, Array.init))
        wav.append(pcm)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(name)
            .appendingPathExtension("wav")
        try wav.write(to: url)
        return url
    }
}
