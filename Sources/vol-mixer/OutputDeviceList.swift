import Foundation
import CoreAudio

struct AudioOutputDevice: Equatable, Identifiable, Hashable {
    let id: AudioObjectID
    let uid: String
    let name: String
    let transportType: UInt32
}

enum OutputDeviceList {
    static func all() throws -> [AudioOutputDevice] {
        let ids = try caGetArray(AudioObjectID(kAudioObjectSystemObject),
                                  kAudioHardwarePropertyDevices)
        return ids.compactMap { id in
            guard hasOutputStreams(id) else { return nil }
            let uid = (try? caGetString(id, kAudioDevicePropertyDeviceUID)) ?? ""
            let name = (try? caGetString(id, kAudioObjectPropertyName))
                ?? (try? caGetString(id, kAudioDevicePropertyDeviceNameCFString))
                ?? uid
            let transport: UInt32 = (try? caGet(id,
                kAudioDevicePropertyTransportType,
                as: UInt32.self)) ?? 0
            return AudioOutputDevice(id: id, uid: uid, name: name, transportType: transport)
        }
        // Strip our own private aggregate devices so users don't see them
        // as selectable outputs.
        .filter { !$0.name.hasPrefix("vol-mixer-") }
    }

    static func currentDefaultID() throws -> AudioObjectID {
        try caGet(AudioObjectID(kAudioObjectSystemObject),
                  kAudioHardwarePropertyDefaultOutputDevice)
    }

    static func setDefault(_ id: AudioObjectID) throws {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value = id
        let size = UInt32(MemoryLayout<AudioObjectID>.size)
        try caCheck(AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &addr, 0, nil, size, &value),
                    "AudioObjectSetPropertyData defaultOutput")
    }

    private static func hasOutputStreams(_ device: AudioObjectID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr
        else { return false }
        return size >= UInt32(MemoryLayout<AudioObjectID>.stride)
    }
}

extension AudioOutputDevice {
    /// SF Symbol name chosen from the device's transport type.
    var sfSymbol: String {
        switch transportType {
        case kAudioDeviceTransportTypeBuiltIn: return "laptopcomputer"
        case kAudioDeviceTransportTypeBluetooth,
             kAudioDeviceTransportTypeBluetoothLE: return "airpodspro"
        case kAudioDeviceTransportTypeAirPlay: return "airplayaudio"
        case kAudioDeviceTransportTypeHDMI,
             kAudioDeviceTransportTypeDisplayPort: return "tv"
        case kAudioDeviceTransportTypeUSB: return "cable.connector"
        case kAudioDeviceTransportTypeAggregate,
             kAudioDeviceTransportTypeVirtual: return "rectangle.3.group"
        default: return "hifispeaker"
        }
    }
}
