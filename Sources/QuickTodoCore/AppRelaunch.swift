import Foundation

/// How to bring a freshly installed app back up after replacing itself.
public enum AppRelaunch {

    /// How often the helper checks whether the outgoing process is gone.
    public static let pollInterval: TimeInterval = 0.1

    /// Longest the helper waits before opening anyway. Shutdown can take a second
    /// or two; opening early is deduplicated away.
    public static let maxWait: TimeInterval = 6

    /// Shared marker on every relaunch diagnostic, so one log query returns
    /// both the app-side and helper-side lines.
    public static let logTag = "QuickTodo.updater"

    /// Command that launches `appURL` once `pid` has exited.
    ///
    /// `open` cannot be called from the app being replaced: LaunchServices
    /// activates the running copy instead of starting the new one. So a helper
    /// waits for the real exit, then opens. `logger` must come immediately
    /// after `open` or it reports the wrong status.
    public static func command(
        for appURL: URL,
        exiting pid: pid_t,
        open openTool: String = "/usr/bin/open",
        log logTool: String = "/usr/bin/logger"
    ) -> (executable: String, arguments: [String]) {
        let attempts = Int(maxWait / pollInterval)
        // Absolute tool paths so PATH can't break it; the bundle path is passed as an
        // argument so the shell never parses it.
        let script =
            "i=0; while /bin/kill -0 \"$1\" 2>/dev/null && [ \"$i\" -lt \(attempts) ]; "
            + "do /bin/sleep \(pollInterval); i=$((i + 1)); done; "
            + "\(openTool) \"$0\"; "
            + "\(logTool) -t \(logTag) \"\(logTag): open exited with status $?\""
        return ("/bin/sh", ["-c", script, appURL.path, String(pid)])
    }
}
