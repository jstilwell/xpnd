import Foundation

enum ProcessRunError: Error, Equatable { case notExecutable, timedOut }

/// Thread-safe byte buffer filled by the pipe reader thread.
private final class LockedBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
    func snapshot() -> Data { lock.lock(); defer { lock.unlock() }; return data }
}

struct ProcessOutput: Sendable, Equatable {
    let status: Int32
    let stdout: String
    let stderr: String
}

enum ProcessRunner {
    /// Runs `executable` directly (no shell). `timeoutMs` of 0 means no timeout.
    /// stdout is drained on its own thread so a full pipe can never block the child.
    static func run(_ executable: URL, arguments: [String], timeoutMs: Int) async throws(ProcessRunError) -> ProcessOutput {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw .notExecutable }
        let result: Result<ProcessOutput, ProcessRunError> = await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                cont.resume(returning: runBlocking(executable, arguments, timeoutMs))
            }
        }
        return try result.get()
    }

    private static func runBlocking(_ executable: URL, _ arguments: [String], _ timeoutMs: Int) -> Result<ProcessOutput, ProcessRunError> {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let pipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = pipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return .failure(.notExecutable) }
        try? pipe.fileHandleForWriting.close() // parent's copy, so reader sees EOF when the child exits
        try? errPipe.fileHandleForWriting.close()

        let buffer = LockedBuffer()
        let errBuffer = LockedBuffer()
        let eof = DispatchSemaphore(value: 0)
        for (p, b) in [(pipe, buffer), (errPipe, errBuffer)] {
            let reader = p.fileHandleForReading
            DispatchQueue.global().async {
                while let chunk = try? reader.read(upToCount: 65536), !chunk.isEmpty { b.append(chunk) }
                eof.signal()
            }
        }

        var timedOut = false
        if timeoutMs > 0, exited.wait(timeout: .now() + .milliseconds(timeoutMs)) == .timedOut {
            timedOut = true
            // Foundation makes the child its own group leader; children that setsid/daemonize still escape.
            let pid = process.processIdentifier
            kill(-pid, SIGTERM)
            let leaderGone = exited.wait(timeout: .now() + 1) == .success
            kill(-pid, SIGKILL) // unconditional: the leader may be gone while group members linger
            if !leaderGone { exited.wait() }
        } else if timeoutMs <= 0 {
            exited.wait()
        }
        // A grandchild may keep the pipe open; don't wait for EOF forever.
        let deadline = DispatchTime.now() + (timedOut ? 0.1 : 1)
        _ = eof.wait(timeout: deadline)
        _ = eof.wait(timeout: deadline)
        if timedOut { return .failure(.timedOut) }
        return .success(ProcessOutput(status: process.terminationStatus,
                                      stdout: String(decoding: buffer.snapshot(), as: UTF8.self),
                                      stderr: String(decoding: errBuffer.snapshot(), as: UTF8.self)))
    }
}

enum ScriptRunner {
    /// Returns stdout untrimmed; the evaluator owns trimming.
    static func run(path: String, timeoutMs: Int) async throws(ExpansionError) -> String {
        do {
            let r = try await ProcessRunner.run(URL(fileURLWithPath: path), arguments: [], timeoutMs: timeoutMs)
            guard r.status == 0 else { throw ExpansionError.scriptFailed(path: path, status: r.status) }
            return r.stdout
        } catch let e as ProcessRunError {
            throw e == .timedOut ? .scriptTimedOut(path: path) : .scriptNotFound(path: path)
        } catch let e as ExpansionError {
            throw e
        } catch { throw .scriptNotFound(path: path) }
    }
}
