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
        let (path, dir) = try script("exec sleep 30")
        defer { try? FileManager.default.removeItem(at: dir) }
        let start = ContinuousClock.now
        await #expect(throws: ExpansionError.scriptTimedOut(path: path)) {
            try await ScriptRunner.run(path: path, timeoutMs: 200)
        }
        #expect(ContinuousClock.now - start < .seconds(2))
    }

    @Test func timeoutWithForkedChildDoesNotHang() async throws {
        let (path, dir) = try script("sleep 30; echo x")
        defer { try? FileManager.default.removeItem(at: dir) }
        let start = ContinuousClock.now
        await #expect(throws: ExpansionError.scriptTimedOut(path: path)) {
            try await ScriptRunner.run(path: path, timeoutMs: 200)
        }
        #expect(ContinuousClock.now - start < .seconds(2))
    }

    @Test func largeOutputDoesNotDeadlock() async throws {
        let (path, dir) = try script("head -c 1000000 /dev/zero | tr '\\0' a")
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try await ScriptRunner.run(path: path, timeoutMs: 10_000).count == 1_000_000)
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
