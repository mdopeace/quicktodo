import Foundation

/// How to bring a freshly installed app back up after replacing itself.
public enum AppRelaunch {

    /// How often the helper checks whether the outgoing process is gone.
    public static let pollInterval: TimeInterval = 0.1

    /// Longest the helper waits for that process to disappear before opening
    /// anyway. An orderly app shutdown can take a second or two (state saves,
    /// run-loop teardown), and opening before it finishes is deduplicated away.
    public static let maxWait: TimeInterval = 6

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
    /// - Parameter openTool: the `open` binary to invoke. Injectable only so
    ///   tests can observe how the helper is called.
    public static func command(
        for appURL: URL,
        exiting pid: pid_t,
        open openTool: String = "/usr/bin/open"
    ) -> (executable: String, arguments: [String]) {
        let attempts = Int(maxWait / pollInterval)
        // Absolute tool paths so this does not depend on the caller's PATH, and
        // the bundle path passed as an argument so the shell never parses it.
        let script = "i=0; while /bin/kill -0 \"$1\" 2>/dev/null && [ \"$i\" -lt \(attempts) ]; "
            + "do /bin/sleep \(pollInterval); i=$((i + 1)); done; exec \(openTool) \"$0\""
        return ("/bin/sh", ["-c", script, appURL.path, String(pid)])
    }
}
