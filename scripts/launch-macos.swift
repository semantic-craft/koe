import AppKit

// Called by run-with-secrets.py with its filtered environment. Keep credentials
// in memory; open --env KEY=value would expose them in process arguments.
let appURL = URL(fileURLWithPath: "/Applications/Koe.app", isDirectory: true)
let bundleID = "com.anker.ankerRecorder"
if !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty {
  fputs("Quit Koe before launching; an existing process cannot receive the new environment.\n", stderr)
  exit(1)
}
let configuration = NSWorkspace.OpenConfiguration()
configuration.environment = ProcessInfo.processInfo.environment
configuration.activates = true
NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { app, error in
  guard error == nil, let app else {
    // Do not print errors that could include launch configuration or credentials.
    fputs("Could not launch the installed Koe app through LaunchServices.\n", stderr)
    exit(1)
  }
  print("Launched installed macOS app through LaunchServices, PID \(app.processIdentifier).")
  exit(0)
}
dispatchMain()
