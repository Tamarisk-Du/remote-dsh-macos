import Foundation

public protocol ManagedProcessHandle: AnyObject, Sendable {
    var processIdentifier: Int32 { get }
    var isRunning: Bool { get }
    func terminate()
    func sanitizedDiagnostic() -> String
}

public protocol ProcessLaunching: Sendable {
    func launch(
        _ command: CommandSpec,
        onTermination: @escaping @Sendable (Int32) -> Void
    ) throws -> ManagedProcessHandle
}

public struct FoundationProcessLauncher: ProcessLaunching, Sendable {
    public init() {}

    public func launch(
        _ command: CommandSpec,
        onTermination: @escaping @Sendable (Int32) -> Void
    ) throws -> ManagedProcessHandle {
        let process = Process()
        let output = Pipe()
        let errorPipe = Pipe()
        let buffer = RollingDiagnosticBuffer()

        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        process.environment = command.environment
        if let currentDirectory = command.currentDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory)
        }
        process.standardOutput = output
        process.standardError = errorPipe

        output.fileHandleForReading.readabilityHandler = { [weak buffer] handle in
            buffer?.append(handle.availableData)
        }
        errorPipe.fileHandleForReading.readabilityHandler = { [weak buffer] handle in
            buffer?.append(handle.availableData)
        }
        process.terminationHandler = { process in
            output.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            buffer.append(output.fileHandleForReading.readDataToEndOfFile())
            buffer.append(errorPipe.fileHandleForReading.readDataToEndOfFile())
            onTermination(process.processIdentifier)
        }

        do {
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            throw error
        }
        return FoundationManagedProcess(
            process: process,
            outputPipe: output,
            errorPipe: errorPipe,
            diagnosticBuffer: buffer
        )
    }
}

private final class FoundationManagedProcess: ManagedProcessHandle, @unchecked Sendable {
    private let process: Process
    private let outputPipe: Pipe
    private let errorPipe: Pipe
    private let diagnosticBuffer: RollingDiagnosticBuffer

    init(
        process: Process,
        outputPipe: Pipe,
        errorPipe: Pipe,
        diagnosticBuffer: RollingDiagnosticBuffer
    ) {
        self.process = process
        self.outputPipe = outputPipe
        self.errorPipe = errorPipe
        self.diagnosticBuffer = diagnosticBuffer
    }

    var processIdentifier: Int32 { process.processIdentifier }
    var isRunning: Bool { process.isRunning }

    func terminate() {
        guard process.isRunning else { return }
        process.terminate()
    }

    func sanitizedDiagnostic() -> String {
        DiagnosticSanitizer.clean(diagnosticBuffer.string)
    }
}

private final class RollingDiagnosticBuffer: @unchecked Sendable {
    private static let capacity = 16_384
    private let lock = NSLock()
    private var data = Data()

    var string: String {
        lock.withLock { String(decoding: data, as: UTF8.self) }
    }

    func append(_ newData: Data) {
        guard newData.isEmpty == false else { return }
        lock.withLock {
            data.append(newData)
            if data.count > Self.capacity {
                data.removeFirst(data.count - Self.capacity)
            }
        }
    }
}
