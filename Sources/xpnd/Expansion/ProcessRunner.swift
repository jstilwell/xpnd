import Foundation

enum ProcessRunError: Error, Equatable { case notExecutable, timedOut, cancelled }

/// Thread-safe byte buffer filled by the pipe reader thread.
private final class LockedBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
    func snapshot() -> Data { lock.lock(); defer { lock.unlock() }; return data }
}

/// The child's process group, so cancelling the awaiting task can stop it from another thread.
private final class ChildProcess: @unchecked Sendable {
    private enum State { case notStarted, running(pid_t), exited }
    private let lock = NSLock()
    private var state = State.notStarted
    private var cancelled = false

    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    func started(_ pid: pid_t) {
        lock.lock()
        if case .notStarted = state { state = .running(pid) }
        let stop = cancelled
        lock.unlock()
        if stop { cancel() }
    }

    func exited() { lock.lock(); state = .exited; lock.unlock() }

    /// SIGTERM to the group, then SIGKILL a second later if the leader is still running.
    func cancel() {
        lock.lock()
        cancelled = true
        let pid: pid_t? = if case .running(let p) = state { p } else { nil }
        lock.unlock()
        guard let pid else { return }
        kill(-pid, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [self] in
            lock.lock()
            let still = if case .running = state { true } else { false }
            lock.unlock()
            if still { kill(-pid, SIGKILL) }
        }
    }
}

struct ProcessOutput: Sendable, Equatable {
    let status: Int32
    let stdout: String
    let stderr: String
}

enum ProcessRunner {
    /// Runs `executable` directly (no shell). `timeoutMs` of 0 means no timeout; cancelling the task
    /// stops the child and throws `.cancelled`. stdout is drained on its own thread so a full pipe
    /// can never block the child.
    static func run(_ executable: URL, arguments: [String], timeoutMs: Int) async throws(ProcessRunError) -> ProcessOutput {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw .notExecutable }
        let child = ChildProcess()
        let result: Result<ProcessOutput, ProcessRunError> = await withTaskCancellationHandler {
            await withCheckedContinuation { cont in
                DispatchQueue.global().async {
                    cont.resume(returning: runBlocking(executable, arguments, timeoutMs, child))
                }
            }
        } onCancel: {
            child.cancel()
        }
        return try result.get()
    }

    private static func runBlocking(_ executable: URL, _ arguments: [String], _ timeoutMs: Int,
                                    _ child: ChildProcess) -> Result<ProcessOutput, ProcessRunError> {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let pipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = pipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            child.exited()
            exited.signal()
        }
        guard !child.isCancelled else { return .failure(.cancelled) }
        do { try process.run() } catch { return .failure(.notExecutable) }
        child.started(process.processIdentifier)
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
            exited.wait() // a cancel's SIGTERM ends this
        }
        let cancelled = child.isCancelled
        if cancelled { kill(-process.processIdentifier, SIGKILL) } // group members the leader left behind
        // A grandchild may keep the pipe open; don't wait for EOF forever.
        let deadline = DispatchTime.now() + (timedOut || cancelled ? 0.1 : 1)
        _ = eof.wait(timeout: deadline)
        _ = eof.wait(timeout: deadline)
        if timedOut { return .failure(.timedOut) }
        if cancelled { return .failure(.cancelled) }
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
            switch e {
            case .timedOut: throw .scriptTimedOut(path: path)
            // Only the engine cancels an evaluation, when the user leaves the app they typed in.
            case .cancelled: throw .targetAppChanged
            case .notExecutable: throw .scriptNotFound(path: path)
            }
        } catch let e as ExpansionError {
            throw e
        } catch { throw .scriptNotFound(path: path) }
    }
}
