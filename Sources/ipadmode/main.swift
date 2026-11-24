// The `ipadmode` binary: the long-lived roles (daemon, watchdog, vdisplay) and the CLI (see CLI.swift).
// R58: the roles are entered from this synchronous top-level code, never from an async context or a queue block.
import Foundation
import IPadModeCore
import IPadModeSystem

/// R77: held for the whole process lifetime so that the windowless roles are not App-Napped; it does not prevent
/// system or display sleep.
var activity: NSObjectProtocol?
func holdActivity(_ role: String) {
    activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep], reason: "ipadmode \(role)")
}

let arguments = Array(CommandLine.arguments.dropFirst())
if CLIParsing.isHelp(arguments) {
    print(Messages.usage)
    exit(ExitCode.ok.rawValue)
}
switch CLIParsing.parse(arguments) {
case .failure(let error):
    fputs(error.message + "\n", stderr)
    exit(ExitCode.usage.rawValue)
case .success(.daemon):
    holdActivity("daemon")
    MainActor.assumeIsolated { runDaemon(paths: .standard) }
case .success(.watchdog):
    holdActivity("watchdog")
    MainActor.assumeIsolated {
        runWatchdog(paths: .standard, backend: CGDisplayBackend(), config: ConfigLoader.load(from: Paths.standard.config).config)
    }
case .success(.vdisplay(let rest)):
    guard let parsed = VDisplayProtocol.parseArguments([VDisplayProtocol.subcommand] + rest) else {
        fputs(Messages.usage + "\n", stderr)
        exit(ExitCode.usage.rawValue)
    }
    holdActivity("vdisplay")
    runVirtualDisplayProcess(role: parsed.role, resolution: parsed.resolution, parentPID: parsed.parentPID)
case .success(let command):
    exit(CLI.run(command, paths: .standard).rawValue)
}
