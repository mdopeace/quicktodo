import XCTest
@testable import QuickTodoCore

/// Locks in why the relaunch cannot simply call `open`: LaunchServices dedupes
/// by bundle identifier, so the new app is never actually started.
///
/// The behavioural tests here execute the generated command for real. Asserting
/// on substrings of the script is not enough — swapping `open "$0"` for
/// `"$1"`, or `&&` for `||`, leaves every substring check passing while
/// breaking the feature outright.
final class AppRelaunchTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("relaunch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Behaviour

    func test_opens_the_bundle_path_and_not_the_pid_once_the_process_is_gone() throws {
        let log = try makeLog()
        let app = "/Applications/quicktodo.app"

        let start = Date()
        try run(AppRelaunch.command(
            for: URL(fileURLWithPath: app),
            exiting: try exitedPID(),
            open: try makeOpenStub(),
            log: try makeSilentLoggerStub()
        ))
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(
            try String(contentsOf: log, encoding: .utf8), "open \(app)\n",
            "the helper must open the bundle path ($0), not the outgoing pid ($1)"
        )
        // A pid that is already gone needs no waiting. A loop that always ran to
        // its cap would burn the full budget here and silently degrade back to
        // a fixed delay, which is the bug this whole mechanism exists to avoid.
        XCTAssertLessThan(
            elapsed, AppRelaunch.maxWait / 2,
            "must not wait when the outgoing process has already exited"
        )
    }

    func test_waits_for_a_live_process_to_exit_before_opening() throws {
        let log = try makeLog()
        // The child appends to the log as it exits, so the ordering of the two
        // events is directly observable.
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sh")
        child.arguments = ["-c", "sleep 0.4; echo child-exited >> \(log.path)"]
        try child.run()

        try run(AppRelaunch.command(
            for: URL(fileURLWithPath: "/Applications/quicktodo.app"),
            exiting: child.processIdentifier,
            open: try makeOpenStub(),
            log: try makeSilentLoggerStub()
        ))
        child.waitUntilExit()

        let lines = try String(contentsOf: log, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(
            lines,
            ["child-exited", "open /Applications/quicktodo.app"],
            "open must not run while the outgoing process is still alive"
        )
    }

    // MARK: - Shape

    func test_runs_through_a_helper_instead_of_calling_open_directly() throws {
        let command = AppRelaunch.command(
            for: URL(fileURLWithPath: "/Applications/quicktodo.app"), exiting: 4242
        )
        // If this were `/usr/bin/open` with the app as its only argument,
        // LaunchServices would only activate the copy that is still running.
        XCTAssertEqual(command.executable, "/bin/sh")
        XCTAssertEqual(command.arguments.first, "-c")
        XCTAssertEqual(command.arguments.last, "4242")
    }

    func test_uses_absolute_tool_paths_so_it_does_not_depend_on_path() throws {
        let script = try script()
        XCTAssertTrue(script.contains("/bin/kill"), "kill should be absolute: \(script)")
        XCTAssertTrue(script.contains("/bin/sleep"), "sleep should be absolute: \(script)")
        XCTAssertTrue(script.contains("/usr/bin/open"), "open should be absolute: \(script)")
    }

    func test_poll_is_bounded_so_a_stuck_process_cannot_hang_the_helper_forever() throws {
        let script = try script()
        // Read the cap out of the script rather than recomputing it, so a wrong
        // value is actually caught.
        let range = try XCTUnwrap(
            script.range(of: #"-lt (\d+)"#, options: .regularExpression),
            "expected a numeric retry cap in \(script)"
        )
        let attempts = try XCTUnwrap(Int(script[range].dropFirst("-lt ".count)))
        XCTAssertGreaterThan(attempts, 0, "the cap must allow at least one attempt")
        XCTAssertLessThanOrEqual(
            Double(attempts) * AppRelaunch.pollInterval, AppRelaunch.maxWait,
            "the retry cap must bound the total wait"
        )
    }

    /// Once the app has exited nobody can observe whether the relaunch worked, so
    /// the helper has to say so itself. Asserted by running it, because a
    /// substring check cannot tell `open "$0"; logger ... $?` from a version with
    /// something in between that clobbers the status — which would leave the
    /// helper cheerfully reporting success while the relaunch silently failed.
    func test_helper_reports_the_real_open_exit_status() throws {
        try run(AppRelaunch.command(
            for: URL(fileURLWithPath: "/Applications/quicktodo.app"),
            exiting: try exitedPID(),
            open: try makeStub(named: "open", exitCode: 3),
            log: try makeStub(named: "logger", exitCode: 0, recordsTo: "")
        ))

        XCTAssertEqual(
            try String(contentsOf: try makeLog(), encoding: .utf8),
            "-t \(AppRelaunch.logTag) \(AppRelaunch.logTag): open exited with status 3\n",
            "the reported status must be open's, not a later command's"
        )
    }

    func test_relaunch_diagnostics_share_one_greppable_marker() throws {
        // The app-side lines carry this marker in the message and the helper
        // side as its logger tag, so one query returns both.
        let script = try script()
        XCTAssertTrue(
            script.contains("\(AppRelaunch.logTag): open exited with status"),
            "helper message must carry the shared marker: \(script)"
        )
    }

    // MARK: - Helpers

    private func script() throws -> String {
        let command = AppRelaunch.command(
            for: URL(fileURLWithPath: "/Applications/quicktodo.app"), exiting: 4242
        )
        return try XCTUnwrap(command.arguments.dropFirst().first)
    }

    private func makeLog() throws -> URL {
        root.appendingPathComponent("calls.log")
    }

    /// A stand-in for `open` that records how it was called.
    private func makeOpenStub() throws -> String {
        try makeStub(named: "open", exitCode: 0, recordsTo: "open")
    }

    /// Keeps the suite out of the developer's unified log — these tests would
    /// otherwise write the very lines someone greps for when diagnosing a real
    /// failed update.
    private func makeSilentLoggerStub() throws -> String {
        try makeStub(named: "silent-logger", exitCode: 0)
    }

    /// A stand-in for one of the helper's tools.
    ///
    /// - Parameters exitCode: what the stub returns, standing in for the real
    ///   tool's result. recordsTo: when set, appends the stub's arguments to
    ///   the call log behind this label; when nil, records nothing.
    private func makeStub(
        named name: String,
        exitCode: Int32,
        recordsTo label: String? = nil
    ) throws -> String {
        let stub = root.appendingPathComponent(name)
        var body = ""
        if let label {
            let logged = label.isEmpty ? "\"$*\"" : "\"\(label) $*\""
            body = "printf '%s\\n' \(logged) >> \(try makeLog().path)\n"
        }
        try ("#!/bin/sh\n" + body + "exit \(exitCode)\n")
            .write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        return stub.path
    }

    /// The pid of a process that has already exited.
    private func exitedPID() throws -> pid_t {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()
        return process.processIdentifier
    }

    private func run(_ command: (executable: String, arguments: [String])) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
    }
}
