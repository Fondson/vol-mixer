import Foundation
import CoreAudio
import AudioToolbox
import os.lock

/// Per-process volume mixer using Core Audio Process Taps (macOS 14.2+).
///
/// Strategy: create a stereo-mixdown tap on the target process with `.muted`
/// mute-behavior so its audio is silenced at the system mixer. Then build a
/// private aggregate device whose input is the tap and whose output sub-device
/// is the current default output. An IOProc copies the tapped samples into the
/// output buffer after multiplying by the current gain.
final class VolumeMixer {
    private let targetPID: pid_t
    private let gainLock = OSAllocatedUnfairLock<Float>(initialState: 1.0)

    private var tapID: AudioObjectID = 0
    private var aggregateID: AudioObjectID = 0
    private var ioProcID: AudioDeviceIOProcID?
    private var started = false

    init(targetPID: pid_t, gain: Float) {
        self.targetPID = targetPID
        self.gainLock.withLock { $0 = gain }
    }

    func setGain(_ g: Float) {
        gainLock.withLock { $0 = max(0, g) }
    }

    func start() throws {
        guard let procObject = try AudioProcessList.audioObjectID(forPID: targetPID) else {
            throw RuntimeError("no audio-process object for pid \(targetPID) — run `vol-mixer list`")
        }

        let desc = CATapDescription(stereoMixdownOfProcesses: [procObject])
        desc.uuid = UUID()
        desc.name = "vol-mixer-tap-\(targetPID)"
        desc.isPrivate = true
        // .mutedWhenTapped: the source is silenced only while our IOProc is
        // actively reading. As soon as we AudioDeviceStop, the process resumes
        // on the hardware on its own — so reset/teardown leaves no residue.
        desc.muteBehavior = .mutedWhenTapped

        var tap: AudioObjectID = kAudioObjectUnknown
        try caCheck(AudioHardwareCreateProcessTap(desc, &tap),
                    "AudioHardwareCreateProcessTap")
        self.tapID = tap

        let defaultOutput: AudioObjectID = try caGet(
            AudioObjectID(kAudioObjectSystemObject),
            kAudioHardwarePropertyDefaultOutputDevice
        )
        let outputUID = try caGetString(defaultOutput, kAudioDevicePropertyDeviceUID)
        let tapUID = try caGetString(tap, kAudioTapPropertyUID)

        let aggregateDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "vol-mixer-\(targetPID)",
            kAudioAggregateDeviceUIDKey as String: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey as String: outputUID,
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceIsStackedKey as String: false,
            kAudioAggregateDeviceTapAutoStartKey as String: true,
            kAudioAggregateDeviceSubDeviceListKey as String: [
                [kAudioSubDeviceUIDKey as String: outputUID]
            ],
            kAudioAggregateDeviceTapListKey as String: [
                [
                    kAudioSubTapUIDKey as String: tapUID,
                    kAudioSubTapDriftCompensationKey as String: true,
                ]
            ],
        ]

        var agg: AudioObjectID = kAudioObjectUnknown
        try caCheck(AudioHardwareCreateAggregateDevice(aggregateDesc as CFDictionary, &agg),
                    "AudioHardwareCreateAggregateDevice")
        self.aggregateID = agg

        // IOProc: self is not retained by the block — we hold the mixer alive
        // from `main.swift` for the lifetime of the CLI.
        let unownedSelf = Unmanaged.passUnretained(self)
        var procID: AudioDeviceIOProcID?
        try caCheck(AudioDeviceCreateIOProcIDWithBlock(
            &procID,
            agg,
            nil,
            { _, inputData, _, outputData, _ in
                unownedSelf.takeUnretainedValue().render(input: inputData, output: outputData)
            }
        ), "AudioDeviceCreateIOProcIDWithBlock")
        self.ioProcID = procID

        try caCheck(AudioDeviceStart(agg, procID),
                    "AudioDeviceStart")
        started = true
    }

    private func render(input: UnsafePointer<AudioBufferList>,
                        output: UnsafeMutablePointer<AudioBufferList>) {
        let gain = gainLock.withLock { $0 }

        let inList = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: input))
        let outList = UnsafeMutableAudioBufferListPointer(output)

        let pairs = min(inList.count, outList.count)
        for i in 0..<pairs {
            let inBuf = inList[i]
            let outBuf = outList[i]
            guard
                let inPtr = inBuf.mData?.assumingMemoryBound(to: Float.self),
                let outPtr = outBuf.mData?.assumingMemoryBound(to: Float.self)
            else {
                if let out = outBuf.mData {
                    memset(out, 0, Int(outBuf.mDataByteSize))
                }
                continue
            }
            let bytes = min(inBuf.mDataByteSize, outBuf.mDataByteSize)
            let samples = Int(bytes) / MemoryLayout<Float>.size
            if gain == 1.0 {
                memcpy(outPtr, inPtr, Int(bytes))
            } else {
                for s in 0..<samples { outPtr[s] = inPtr[s] * gain }
            }
            // Zero any tail the output expected but we didn't fill.
            if outBuf.mDataByteSize > bytes {
                let extra = Int(outBuf.mDataByteSize - bytes)
                memset(outPtr.advanced(by: samples), 0, extra)
            }
        }
        // Silence any extra output buffers with no matching input.
        for i in pairs..<outList.count {
            if let p = outList[i].mData {
                memset(p, 0, Int(outList[i].mDataByteSize))
            }
        }
    }

    func stop() {
        // Order matters: halt the IOProc so the tapped process immediately
        // resumes hardware playback, then tear down the owning objects.
        if let pid = ioProcID, aggregateID != 0 {
            if started {
                logIfError(AudioDeviceStop(aggregateID, pid), "AudioDeviceStop")
            }
            logIfError(AudioDeviceDestroyIOProcID(aggregateID, pid),
                       "AudioDeviceDestroyIOProcID")
            ioProcID = nil
        }
        if aggregateID != 0 {
            logIfError(AudioHardwareDestroyAggregateDevice(aggregateID),
                       "AudioHardwareDestroyAggregateDevice")
            aggregateID = 0
        }
        if tapID != 0 {
            logIfError(AudioHardwareDestroyProcessTap(tapID),
                       "AudioHardwareDestroyProcessTap")
            tapID = 0
        }
        started = false
    }

    private func logIfError(_ status: OSStatus, _ ctx: String) {
        guard status != noErr else { return }
        FileHandle.standardError.write(Data(
            "vol-mixer: \(ctx) returned OSStatus \(status)\n".utf8))
    }

    deinit { stop() }
}
