import AVFoundation
import CoreMIDI
import QuartzCore

/// Sends outgoing Note On/Off messages so Drummakid can act as a MIDI controller for an
/// external DAW, alongside its own local audio playback. Owned by DrumMachineEngine and
/// driven from its single triggerSample choke point, so both live pad taps and sequenced
/// steps reach here the same way.
///
/// Pad-to-note mapping is deliberately position-based (`noteBase + padIndex`) rather than
/// keyed to whatever sound currently occupies that pad: drum packs get swapped constantly
/// (see loadDrumPack), so a mapping tied to a specific sound's identity would go stale the
/// moment a new pack is loaded. Slot position is the one thing that stays fixed.
///
/// Transport is automatic and free once a virtual source endpoint exists: any wired
/// (USB/Lightning class-compliant) or Network MIDI (Bonjour/RTP-MIDI over Wi-Fi) receiver
/// on the other end sees this source without any further code. Bluetooth MIDI pairing UI
/// is a separate, later phase.
@MainActor
final class MIDIControllerEngine {
    static let noteBase: UInt8 = 36
    private static let enabledStorageKey = "midiControllerEnabled"
    private static let channelStorageKey = "midiControllerChannel"
    private static let noteOffDelay: CFTimeInterval = 0.05

    private var client = MIDIClientRef()
    private var source = MIDIEndpointRef()

    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledStorageKey)
        }
    }

    /// 1-based, matching how MIDI channels are conventionally shown to users (1...16).
    var channel: UInt8 {
        didSet {
            guard channel != oldValue else { return }
            UserDefaults.standard.set(Int(channel), forKey: Self.channelStorageKey)
        }
    }

    init() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledStorageKey)
        let storedChannel = UserDefaults.standard.object(forKey: Self.channelStorageKey) as? Int
        channel = UInt8(min(max(storedChannel ?? 1, 1), 16))

        MIDIClientCreateWithBlock("drummakid" as CFString, &client, nil)
        MIDISourceCreate(client, "drummakid Pads" as CFString, &source)
        let networkSession = MIDINetworkSession.default()
        networkSession.isEnabled = true
        networkSession.connectionPolicy = .anyone
    }

    /// `scheduledTime` mirrors DrumMachineEngine's own CACurrentMediaTime-based scheduling
    /// (nil means "live, right now"), so a sequenced hit's MIDI note lands at the same
    /// instant as its audio onset rather than whenever this call happens to run.
    func trigger(padIndex: Int, accent: Double, scheduledTime: CFTimeInterval?) {
        guard isEnabled, (0..<16).contains(padIndex) else { return }

        let note = Self.noteBase + UInt8(padIndex)
        let velocity = UInt8(min(max(Int((100 * accent).rounded()), 1), 127))
        let statusNibble = channel - 1
        let now = CACurrentMediaTime()
        let onsetSeconds = scheduledTime ?? now

        send(status: 0x90 | statusNibble, note: note, velocity: velocity, atSeconds: onsetSeconds)

        let offSeconds = onsetSeconds + Self.noteOffDelay
        let workItem = DispatchWorkItem { [weak self] in
            self?.send(status: 0x80 | statusNibble, note: note, velocity: 0, atSeconds: offSeconds)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + max(offSeconds - now, 0), execute: workItem)
    }

    private func send(status: UInt8, note: UInt8, velocity: UInt8, atSeconds seconds: CFTimeInterval) {
        let hostTime = AVAudioTime.hostTime(forSeconds: seconds)
        var packetList = MIDIPacketList()
        withUnsafeMutablePointer(to: &packetList) { listPointer in
            let packet = MIDIPacketListInit(listPointer)
            var bytes: [UInt8] = [status, note, velocity]
            _ = MIDIPacketListAdd(listPointer, 1024, packet, hostTime, bytes.count, &bytes)
            MIDIReceived(source, listPointer)
        }
    }
}
