import Foundation

/// How to bring a freshly installed app back up after replacing itself.
public enum AppRelaunch {

    /// How often the helper checks whether the outgoing process is gone.
    public static let pollInterval: TimeInterval = 0.1

    /// Longest the helper waits for that process to disappear before opening
    /// anyway. An orderly app shutdown can take a second or two (state saves,
    /// run-loop teardown), and opening before it finishes is deduplicated away.
    public static let maxWait: TimeInterval = 6

    /// Shared marker on every relaunch diagnostic. The app-side lines carry it
    /// in the message and the helper-side line as its `logger` tag, so one
    /// `eventMessage CONTAINS` query returns both halves of the story.
    public static let logTag = "QuickTodo.updater"

    /// The command that launches `appURL` once `pid` has exited.
    ///
    /// `open` cannot be called directly from the app being replaced:
    /// LaunchServices will not start a second copy of an app whose bundle
    /// identifier is already running — it just activates the running one. So
    /// opening the new bundle and then exiting installs the update and leaves
    /// nothing running.
    ///
    /// The helper therefore polls until the outgoing process is actually gone
    /// rather than sleeping a guessed interval, then opens. Waiting on the
    /// process is what makes this reliable; a fixed delay is only a guess about
    /// how long shutdown takes.
    ///
    /// Once the app has exited the parent can no longer observe anything, so
    /// the helper reports `open`'s exit status to the unified log itself. It
    /// must be the statement immediately after `open` — anything in between
    /// would clobber the status being reported.
    ///
    /// - Parameters openTool: the `open` binary. logTool: the `logger` binary.
    ///   Both injectable only so tests can observe how the helper is called.
    public static func command(
        for appURL: URL,
        exiting pid: pid_t,
        open openTool: String = "/usr/bin/open",
        log logTool: String = "/usr/bin/logger"
    ) -> (executable: String, arguments: [String]) {
        let attempts = Int(maxWait / pollInterval)
        // Absolute tool paths so this does not depend on the caller's PATH, and
        // the bundle path passed as an argument so the shell never parses it.
        let script = "i=0; while /bin/kill -0 \"$1\" 2>/dev/null && [ \"$i\" -lt \(attempts) ]; "
            + "do /bin/sleep \(pollInterval); i=$((i + 1)); done; "
            + "\(openTool) \"$0\"; "
            + "\(logTool) -t \(logTag) \"\(logTag): open exited with status $?\""
        return ("/bin/sh", ["-c", script, appURL.path, String(pid)])
    }
}
