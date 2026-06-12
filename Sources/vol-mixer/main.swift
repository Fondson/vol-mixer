import AppKit
import SwiftUI

let args = CommandLine.arguments

if args.count >= 2, ["list", "run", "--help", "-h"].contains(args[1]) {
    CLI.run(args: args)
    exit(0)
}

MainActor.assumeIsolated {
    let delegate = VolMixerAppDelegate()
    let app = NSApplication.shared
    app.delegate = delegate
    // Keep delegate alive for the lifetime of the process.
    objc_setAssociatedObject(app, &delegateKey, delegate, .OBJC_ASSOCIATION_RETAIN)
    app.run()
}

nonisolated(unsafe) var delegateKey: UInt8 = 0
