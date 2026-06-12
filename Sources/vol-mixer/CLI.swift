import Foundation
import Darwin

enum CLI {
    static func usage() -> Never {
        let text = """
        vol-mixer — per-app volume control for macOS 14.2+

        usage:
          vol-mixer                       launch the GUI (default)
          vol-mixer list                  list known audio processes
          vol-mixer run <pid> <gain>      tap <pid> at <gain> (foreground)
                                          type new gain + Enter to adjust;
                                          Ctrl-C to quit.

        The GUI is the intended entry point — the CLI requires the binary to
        already hold the Audio Capture TCC grant, which only the bundled .app
        reliably obtains. See README.md.

        """
        FileHandle.standardError.write(Data(text.utf8))
        exit(2)
    }

    static func run(args: [String]) {
        do {
            switch args[1] {
            case "list":
                try AudioProcessList.printAll()

            case "run":
                guard args.count == 4,
                      let pid = pid_t(args[2]),
                      let gain = Float(args[3]),
                      gain >= 0
                else { usage() }

                let mixer = VolumeMixer(targetPID: pid, gain: gain)
                try mixer.start()

                // Dispatch sources, not signal() handlers: the handler runs on a
                // normal queue where the Core Audio teardown in stop() is safe to call.
                for sig in [SIGINT, SIGTERM] {
                    signal(sig, SIG_IGN)
                    let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
                    src.setEventHandler { mixer.stop(); exit(0) }
                    src.resume()
                    cliSignalSources.append(src)
                }

                FileHandle.standardError.write(Data(
                    "tapping pid \(pid) at gain \(gain) — type new gain + Enter, Ctrl-C to quit\n".utf8))

                // Read gain updates off the main thread so the main queue stays
                // free to service the signal sources.
                DispatchQueue.global().async {
                    while let line = readLine() {
                        let t = line.trimmingCharacters(in: .whitespaces)
                        guard !t.isEmpty else { continue }
                        if let g = Float(t), g >= 0 {
                            mixer.setGain(g)
                            FileHandle.standardError.write(Data("gain → \(g)\n".utf8))
                        } else {
                            FileHandle.standardError.write(Data("ignored: not a non-negative number\n".utf8))
                        }
                    }
                    DispatchQueue.main.async { mixer.stop(); exit(0) }   // stdin EOF
                }

                dispatchMain()   // park main on the queue; never returns

            case "--help", "-h":
                usage()

            default:
                usage()
            }
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            exit(1)
        }
    }
}

// Retains the signal dispatch sources for the lifetime of the `run` command.
var cliSignalSources: [DispatchSourceSignal] = []
