import Foundation
import Testing
@testable import xpnd

@Suite struct ProcessRunnerTests {
    private func script(_ body: String, mode: Int = 0o755) throws -> (path: String, dir: URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("s.sh")
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        return (url.path, dir)
    }

    @Test func scriptOutput() async throws {
        let (path, dir) = try script("echo hi")
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try await ScriptRunner.run(path: path, timeoutMs: 0) == "hi\n")
    }

    @Test func nonZeroExitIsFailure() async throws {
        let (path, dir) = try script("exit 3")
        defer { try? FileManager.default.removeItem(at: dir) }
        await #expect(throws: ExpansionError.scriptFailed(path: path, status: 3)) {
            try await ScriptRunner.run(path: path, timeoutMs: 0)
        }
    }

    @Test func timeoutKillsScript() async throws {
        let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: pidFile) }
        // Background grandchild (not exec'd) so only a group kill can stop it.
        let (path, dir) = try script("sleep 30 &\necho $! > '\(pidFile)'\nwait")
        defer { try? FileManager.default.removeItem(at: dir) }
        let start = ContinuousClock.now
        await #expect(throws: ExpansionError.scriptTimedOut(path: path)) {
            try await ScriptRunner.run(path: path, timeoutMs: 300)
        }
        #expect(ContinuousClock.now - start < .seconds(2))
        let pid = pid_t(try String(contentsOfFile: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
        #expect(pid > 0)
        var gone = false
        for _ in 0..<50 {
            if kill(pid, 0) == -1 && errno == ESRCH { gone = true; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        if !gone { kill(pid, SIGKILL) }
        #expect(gone)
    }

    @Test func largeOutputDoesNotDeadlock() async throws {
        let (path, dir) = try script("head -c 1000000 /dev/zero | tr '\\0' a")
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try await ScriptRunner.run(path: path, timeoutMs: 10_000).count == 1_000_000)
    }

    @Test func largeStderrDoesNotDeadlockAndIsCaptured() async throws {
        let (path, dir) = try script("head -c 1500000 /dev/zero | tr '\\0' e >&2\necho out")
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try await ProcessRunner.run(URL(fileURLWithPath: path), arguments: [], timeoutMs: 10_000)
        #expect(r.status == 0)
        #expect(r.stdout == "out\n")
        #expect(r.stderr.count == 1_500_000)
    }

    @Test func relativeScriptPathIsNotFound() async throws {
        // Resolves to /bin/echo against any working directory, so it would run if relative paths were allowed.
        let relative = String(repeating: "../", count: 30) + "bin/echo"
        await #expect(throws: ExpansionError.scriptNotFound(path: relative)) {
            try await LiveEvaluationContext(library: .empty).runScript(path: relative, timeoutMs: 0)
        }
    }

    @Test func nonExecutableIsNotFound() async throws {
        let (path, dir) = try script("echo hi", mode: 0o644)
        defer { try? FileManager.default.removeItem(at: dir) }
        await #expect(throws: ExpansionError.scriptNotFound(path: path)) {
            try await ScriptRunner.run(path: path, timeoutMs: 0)
        }
        let missing = dir.appendingPathComponent("nope").path
        await #expect(throws: ExpansionError.scriptNotFound(path: missing)) {
            try await ScriptRunner.run(path: missing, timeoutMs: 0)
        }
    }
}
