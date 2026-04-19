import Foundation
import CoreAudio
import Darwin

struct AudioProcessInfo {
    let audioObjectID: AudioObjectID
    let pid: pid_t
    let bundleID: String?
    let executable: String?
    let isRunning: Bool
}

enum AudioProcessList {
    static func all() throws -> [AudioProcessInfo] {
        let ids = try caGetArray(AudioObjectID(kAudioObjectSystemObject),
                                 kAudioHardwarePropertyProcessObjectList)
        return ids.map { id in
            let pid: pid_t = (try? caGet(id, kAudioProcessPropertyPID, as: pid_t.self)) ?? -1
            let bundle: String? = try? caGetString(id, kAudioProcessPropertyBundleID)
            let running: UInt32 = (try? caGet(id, kAudioProcessPropertyIsRunning, as: UInt32.self)) ?? 0
            return AudioProcessInfo(
                audioObjectID: id,
                pid: pid,
                bundleID: (bundle?.isEmpty == false) ? bundle : nil,
                executable: executableName(for: pid),
                isRunning: running != 0
            )
        }
    }

    static func audioObjectID(forPID pid: pid_t) throws -> AudioObjectID? {
        try all().first { $0.pid == pid }?.audioObjectID
    }

    static func printAll() throws {
        let procs = try all().sorted { $0.pid < $1.pid }
        print(String(format: "%-8@ %-7@ %-8@ %@",
                     "OBJID" as NSString,
                     "PID" as NSString,
                     "STATE" as NSString,
                     "NAME" as NSString))
        for p in procs {
            let name = p.bundleID ?? p.executable ?? "?"
            print(String(format: "%-8d %-7d %-8@ %@",
                         p.audioObjectID,
                         p.pid,
                         (p.isRunning ? "playing" : "idle") as NSString,
                         name as NSString))
        }
    }

    private static func executableName(for pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: 2048)
        let n = proc_name(pid, &buf, UInt32(buf.count))
        if n > 0 { return String(cString: buf) }
        return nil
    }
}
