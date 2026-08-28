import Foundation
import SwiftUI
import UniformTypeIdentifiers

enum DrummerPose: String {
    case rest
    case rightHit
    case leftHit

    var assetName: String {
        switch self {
        case .rest:
            return "DrummerPoseRest"
        case .rightHit:
            return "DrummerPoseRight"
        case .leftHit:
            return "DrummerPoseLeft"
        }
    }
}

/// Playback state that changes on every sequencer step or pad hit, split out from
/// DrumMachineEngine's own @Published properties. RootView holds DrumMachineEngine as its
/// @StateObject, so if this state lived there instead, every step tick (and @Published
/// fires unconditionally, even for a same-value reassignment) would re-invoke RootView's
/// entire body -- knobs, pads, header, all of it -- rather than just the small views that
/// actually need to redraw. Views that need this state observe it directly via
/// @ObservedObject; RootView itself only holds a plain (non-observing) reference to pass
/// it down, so it's never itself invalidated by these changes.
@MainActor
final class PlaybackVisualState: ObservableObject {
    @Published var currentStep = 0
    @Published private(set) var drummerPose: DrummerPose = .rest
    @Published private(set) var isAnyVoicePlaying = false
    @Published private(set) var triggeredPads = Array(repeating: false, count: 16)

    func isPadTriggered(_ index: Int) -> Bool {
        triggeredPads[safe: index] ?? false
    }

    func setPadTriggered(_ isTriggered: Bool, for index: Int) {
        guard triggeredPads.indices.contains(index) else { return }
        if triggeredPads[index] != isTriggered {
            triggeredPads[index] = isTriggered
        }
    }

    func setDrummerPose(_ pose: DrummerPose) {
        if drummerPose != pose {
            drummerPose = pose
        }
    }

    func setIsAnyVoicePlaying(_ isPlaying: Bool) {
        if isAnyVoicePlaying != isPlaying {
            isAnyVoicePlaying = isPlaying
        }
    }
}

struct ExportedWAV: Identifiable {
    let id = UUID()
    let document: WAVFileDocument
    let defaultFilename: String
}

struct WAVFileDocument: FileDocument {
    static var readableContentTypes: [UTType] {
        [UTType(filenameExtension: "wav") ?? .audio]
    }

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
