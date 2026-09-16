import Foundation
import Darwin

/// Owns one process group and all three pipes. Nonblocking I/O keeps cancellation
/// responsive even while stdin is full or a child inherits its parent's stdout.
final class LocalCLIProcessRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }

    static func run(command: String, environment: [String: String], input: String, timeoutSeconds: Int, interactive: Bool = false) async throws -> String {
        let runner = LocalCLIProcessRunner()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do { continuation.resume(returning: try runner.execute(command: command, environment: environment, input: Data(input.utf8), timeoutSeconds: timeoutSeconds, interactive: interactive)) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { runner.cancel() }
    }

    private func execute(command: String, environment: [String: String], input: Data, timeoutSeconds: Int, interactive: Bool) throws -> String {
        if isCancelled { throw CancellationError() }
        var inputPipe: [Int32] = [0, 0], outputPipe: [Int32] = [0, 0], errorPipe: [Int32] = [0, 0]
        guard pipe(&inputPipe) == 0 else { throw LocalCLIServiceError.launchFailed("") }
        guard pipe(&outputPipe) == 0 else {
            inputPipe.forEach { close($0) }; throw LocalCLIServiceError.launchFailed("")
        }
        guard pipe(&errorPipe) == 0 else {
            (inputPipe + outputPipe).forEach { close($0) }; throw LocalCLIServiceError.launchFailed("")
        }
        let allFDs = inputPipe + outputPipe + errorPipe
        var ownedFDs = Set(allFDs)
        func closeOwned(_ fd: Int32) { if ownedFDs.remove(fd) != nil { close(fd) } }
        defer { ownedFDs.forEach { close($0) } }
        for fd in allFDs { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }

        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw LocalCLIServiceError.launchFailed("") }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { throw LocalCLIServiceError.launchFailed("") }
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawn_file_actions_adddup2(&actions, inputPipe[0], STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, outputPipe[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, errorPipe[1], STDERR_FILENO)
        allFDs.forEach { posix_spawn_file_actions_addclose(&actions, $0) }
        // Atomic process-group creation avoids racing cancellation against setpgid.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)
        let argumentStrings: [String] = interactive ? ["/bin/zsh", "-ilc", command] : ["/bin/zsh", "-l", "-c", command]
        let argv: [UnsafeMutablePointer<CChar>?] = argumentStrings.map { value in value.withCString { strdup($0) } } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = environment.map { entry in "\(entry.key)=\(entry.value)".withCString { strdup($0) } } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        var pid: pid_t = 0
        if isCancelled { throw CancellationError() }
        let launchResult = argv.withUnsafeBufferPointer { args in
            envp.withUnsafeBufferPointer { env in
                posix_spawn(&pid, "/bin/zsh", &actions, &attributes, args.baseAddress!, env.baseAddress!)
            }
        }
        guard launchResult == 0 else { throw LocalCLIServiceError.launchFailed("") }
        closeOwned(inputPipe[0]); closeOwned(outputPipe[1]); closeOwned(errorPipe[1])
        let stdinFD = inputPipe[1], stdoutFD = outputPipe[0], stderrFD = errorPipe[0]
        for fd in [stdinFD, stdoutFD, stderrFD] { _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) }
        // A command may exit without reading stdin. EPIPE must not signal the app.
        _ = fcntl(stdinFD, F_SETNOSIGPIPE, 1)
        var inputOffset = 0
        var output = Data()
        var exited = false
        var status: Int32 = 0
        let deadline = ContinuousClock.now + .seconds(max(1, timeoutSeconds))
        var failure: (any Error)?
        var shutdownDeadline: ContinuousClock.Instant?
        defer {
            if !exited {
                kill(-pid, SIGKILL)
                while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
            }
        }
        while !exited || ownedFDs.contains(stdoutFD) || ownedFDs.contains(stderrFD) {
            if failure == nil {
                if isCancelled { failure = CancellationError() }
                else if ContinuousClock.now >= deadline { failure = LocalCLIServiceError.timeout(seconds: timeoutSeconds) }
                if failure != nil {
                    kill(-pid, SIGKILL)
                    closeOwned(stdinFD)
                    shutdownDeadline = .now + .seconds(1)
                }
            }
            if !exited {
                let waited = waitpid(pid, &status, WNOHANG)
                if waited == pid || (waited == -1 && errno == ECHILD) {
                    exited = true
                    closeOwned(stdinFD)
                }
            }
            if let shutdownDeadline, .now >= shutdownDeadline {
                closeOwned(stdoutFD); closeOwned(stderrFD)
                break
            }
            if inputOffset >= input.count { closeOwned(stdinFD) }
            var descriptors = [
                pollfd(fd: ownedFDs.contains(stdinFD) ? stdinFD : -1, events: Int16(POLLOUT), revents: 0),
                pollfd(fd: ownedFDs.contains(stdoutFD) ? stdoutFD : -1, events: Int16(POLLIN), revents: 0),
                pollfd(fd: ownedFDs.contains(stderrFD) ? stderrFD : -1, events: Int16(POLLIN), revents: 0),
            ]
            _ = poll(&descriptors, nfds_t(descriptors.count), 25)
            if ownedFDs.contains(stdinFD), descriptors[0].revents != 0 {
                let written = input.withUnsafeBytes { bytes in
                    Darwin.write(stdinFD, bytes.baseAddress!.advanced(by: inputOffset), min(16_384, input.count - inputOffset))
                }
                if written > 0 { inputOffset += written }
                else if written < 0 && errno != EAGAIN && errno != EINTR { closeOwned(stdinFD) }
            }
            for (index, fd) in [(1, stdoutFD), (2, stderrFD)] where ownedFDs.contains(fd) && descriptors[index].revents != 0 {
                // Bound each poll iteration so continuously writing commands cannot starve cancellation.
                for _ in 0..<16 {
                    var buffer = [UInt8](repeating: 0, count: 16_384)
                    let count = read(fd, &buffer, buffer.count)
                    if count > 0 {
                        if fd == stdoutFD && failure == nil {
                            if output.count + count > 1_048_576 {
                                failure = LocalCLIServiceError.outputTooLong
                                kill(-pid, SIGKILL)
                                closeOwned(stdinFD)
                                shutdownDeadline = .now + .seconds(1)
                            } else { output.append(contentsOf: buffer.prefix(count)) }
                        }
                    } else {
                        if count == 0 || (errno != EAGAIN && errno != EINTR) { closeOwned(fd) }
                        break
                    }
                }
            }
        }
        if isCancelled { throw CancellationError() }
        if let failure { throw failure }
        guard status & 0x7f == 0, (status >> 8) & 0xff == 0 else {
            throw LocalCLIServiceError.nonZeroExit(code: Int(status & 0x7f == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)), stderr: "")
        }
        return String(decoding: output, as: UTF8.self)
    }
}
