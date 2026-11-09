import CoreMIDI
import Foundation

/// A virtual MIDI device named "Margin". Any DAW sees it as a controller and
/// can assign it through its own MIDI Learn, with no plugin per app.
final class MIDIOut {
    static let shared = MIDIOut()
    static let name = "Margin"

    private var client = MIDIClientRef()
    private var source = MIDIEndpointRef()

    private init() {
        guard MIDIClientCreateWithBlock(Self.name as CFString, &client, nil) == noErr else { return }
        MIDISourceCreate(client, Self.name as CFString, &source)
    }

    var isAvailable: Bool { source != 0 }

    /// `value` is 0...1, sent as a 7-bit control change on channel 1.
    func send(cc: Int, value: Double) {
        guard isAvailable else { return }
        let bytes: [UInt8] = [0xB0, UInt8(clamping: cc) & 0x7F, UInt8((min(1, max(0, value)) * 127).rounded())]
        var list = MIDIPacketList()
        let packet = MIDIPacketListInit(&list)
        MIDIPacketListAdd(&list, MemoryLayout<MIDIPacketList>.size, packet, 0, bytes.count, bytes)
        MIDIReceived(source, &list)
    }
}
