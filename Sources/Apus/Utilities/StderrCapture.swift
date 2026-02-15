import Foundation

/// Captures stdout and stderr output (print(), NSLog(), etc.) in real-time using pipe + dup2.
/// Feeds captured lines into a provided callback.
final class StderrCapture {

    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var originalStdout: Int32 = -1
    private var originalStderr: Int32 = -1
    private var isCapturing = false
    private let onLine: (String) -> Void

    /// - Parameter onLine: Called for each captured line from stdout/stderr.
    init(onLine: @escaping (String) -> Void) {
        self.onLine = onLine
    }

    /// Start capturing stdout and stderr output.
    func start() {
        guard !isCapturing else { return }
        isCapturing = true

        // Capture stdout (print() output)
        let outPipe = Pipe()
        self.stdoutPipe = outPipe
        originalStdout = dup(STDOUT_FILENO)
        dup2(outPipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        setupReadHandler(pipe: outPipe, originalFD: originalStdout)

        // Capture stderr (NSLog() output)
        let errPipe = Pipe()
        self.stderrPipe = errPipe
        originalStderr = dup(STDERR_FILENO)
        dup2(errPipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO)
        setupReadHandler(pipe: errPipe, originalFD: originalStderr)
    }

    /// Stop capturing and restore stdout/stderr.
    func stop() {
        guard isCapturing else { return }
        isCapturing = false

        // Restore stdout
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        if originalStdout >= 0 {
            dup2(originalStdout, STDOUT_FILENO)
            close(originalStdout)
            originalStdout = -1
        }
        try? stdoutPipe?.fileHandleForWriting.close()
        stdoutPipe = nil

        // Restore stderr
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        if originalStderr >= 0 {
            dup2(originalStderr, STDERR_FILENO)
            close(originalStderr)
            originalStderr = -1
        }
        try? stderrPipe?.fileHandleForWriting.close()
        stderrPipe = nil
    }

    private func setupReadHandler(pipe: Pipe, originalFD: Int32) {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }

            // Forward to the original fd so Xcode console still works
            if originalFD >= 0 {
                data.withUnsafeBytes { bytes in
                    if let baseAddress = bytes.baseAddress {
                        write(originalFD, baseAddress, bytes.count)
                    }
                }
            }

            // Parse and forward lines
            if let text = String(data: data, encoding: .utf8) {
                let lines = text.components(separatedBy: .newlines)
                for line in lines where !line.isEmpty {
                    self?.onLine(line)
                }
            }
        }
    }

    deinit {
        stop()
    }
}
