import Foundation
import os.log

final class AerospaceCommandRunner {
    private let executablePath: String
    private static let logger = Logger(
        subsystem: "io.barik.spaces", category: "AerospaceCommandRunner")

    init(executablePath: String) {
        self.executablePath = executablePath
    }

    func run(arguments: [String]) -> Data? {
        let benchmarkStart = DispatchTime.now()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        // Optimize process environment
        process.environment = ["PATH": "/usr/local/bin:/usr/bin:/bin"]

        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = nil  // Discard stderr to reduce overhead

        let launchTime = DispatchTime.now()

        do {
            try process.run()
        } catch {
            let elapsedMs = Self.elapsedMillis(since: benchmarkStart)
            Self.logger.error(
                "Aerospace command failed to start (\(arguments.joined(separator: " "), privacy: .public)) in \(elapsedMs, privacy: .public) ms: \(String(describing: error), privacy: .public)")
            return nil
        }

        let launchElapsed = Self.elapsedMillis(since: launchTime)

        let waitStart = DispatchTime.now()
        process.waitUntilExit()
        let waitElapsed = Self.elapsedMillis(since: waitStart)

        if process.terminationStatus != 0 {
            let elapsedMs = Self.elapsedMillis(since: benchmarkStart)
            Self.logger.error(
                "Aerospace command failed (\(arguments.joined(separator: " "), privacy: .public)) in \(elapsedMs, privacy: .public) ms with exit code \(process.terminationStatus)")
            return nil
        }

        let readStart = DispatchTime.now()
        let outputData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let readElapsed = Self.elapsedMillis(since: readStart)

        let elapsedMs = Self.elapsedMillis(since: benchmarkStart)
        Self.logger.debug(
            "Aerospace command succeeded (\(arguments.joined(separator: " "), privacy: .public)) in \(elapsedMs, privacy: .public) ms [launch: \(launchElapsed, privacy: .public)ms, wait: \(waitElapsed, privacy: .public)ms, read: \(readElapsed, privacy: .public)ms]")
        return outputData
    }

    private static func elapsedMillis(since start: DispatchTime) -> String {
        let nanos = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
        let millis = Double(nanos) / 1_000_000
        return String(format: "%.2f", millis)
    }
}
