import Foundation
import CoreAudio

struct CAError: Error, CustomStringConvertible {
    let status: OSStatus
    let context: String
    var description: String {
        let b: [UInt8] = [
            UInt8(truncatingIfNeeded: status >> 24),
            UInt8(truncatingIfNeeded: status >> 16),
            UInt8(truncatingIfNeeded: status >> 8),
            UInt8(truncatingIfNeeded: status),
        ]
        let printable = b.allSatisfy { (0x20...0x7e).contains($0) }
        let code = printable ? "'\(String(bytes: b, encoding: .ascii) ?? "")'" : "\(status)"
        return "\(context) failed: OSStatus \(status) (\(code))"
    }
}

struct RuntimeError: Error, CustomStringConvertible {
    let description: String
    init(_ s: String) { self.description = s }
}

@discardableResult
func caCheck(_ status: OSStatus, _ context: @autoclosure () -> String) throws -> OSStatus {
    if status != noErr { throw CAError(status: status, context: context()) }
    return status
}

func caGet<T>(
    _ object: AudioObjectID,
    _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
    element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
    as _: T.Type = T.self
) throws -> T {
    var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    var size = UInt32(MemoryLayout<T>.size)
    let ptr = UnsafeMutablePointer<T>.allocate(capacity: 1)
    defer { ptr.deallocate() }
    try caCheck(
        AudioObjectGetPropertyData(object, &addr, 0, nil, &size, ptr),
        "AudioObjectGetPropertyData selector=0x\(String(selector, radix: 16))"
    )
    return ptr.pointee
}

func caGetArray(
    _ object: AudioObjectID,
    _ selector: AudioObjectPropertySelector
) throws -> [AudioObjectID] {
    var addr = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    try caCheck(
        AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size),
        "AudioObjectGetPropertyDataSize selector=0x\(String(selector, radix: 16))"
    )
    let count = Int(size) / MemoryLayout<AudioObjectID>.stride
    guard count > 0 else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: count)
    try caCheck(
        AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &ids),
        "AudioObjectGetPropertyData selector=0x\(String(selector, radix: 16))"
    )
    return ids
}

func caGetString(
    _ object: AudioObjectID,
    _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
) throws -> String {
    var addr = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain
    )
    var size = UInt32(MemoryLayout<CFString?>.size)
    var value: Unmanaged<CFString>? = nil
    try caCheck(
        AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value),
        "AudioObjectGetPropertyData(CFString) selector=0x\(String(selector, radix: 16))"
    )
    guard let cf = value?.takeRetainedValue() else {
        throw RuntimeError("nil string for selector 0x\(String(selector, radix: 16))")
    }
    return cf as String
}
