import Foundation
import SwiftUI

// MARK: - Data Models

struct ClaudeStatsCache: Codable {
    let version: Int
    let lastComputedDate: String
    let dailyActivity: [DailyActivity]
    let modelUsage: [String: ModelUsage]
    let totalSessions: Int
    let totalMessages: Int

    struct DailyActivity: Codable {
        let date: String
        let messageCount: Int
        let sessionCount: Int
        let toolCallCount: Int
    }

    struct ModelUsage: Codable {
        let inputTokens: Int
        let outputTokens: Int
        let cacheReadInputTokens: Int
        let cacheCreationInputTokens: Int
    }
}

struct HistoryEntry: Codable {
    let display: String?
    let timestamp: Double
    let project: String?
}

struct ClaudeUsageData {
    var fiveHourCount: Int = 0
    var fiveHourLimit: Int = 80
    var fiveHourPercentage: Double = 0
    var fiveHourResetDate: Date?

    var weeklyCount: Int = 0
    var weeklyLimit: Int = 500
    var weeklyPercentage: Double = 0
    var weeklyResetDate: Date?

    var todayMessages: Int = 0

    var plan: String = "Pro"
    var lastUpdated: Date = Date()
    var isAvailable: Bool = false
}

// MARK: - Manager

@MainActor
final class ClaudeUsageManager: ObservableObject {
    static let shared = ClaudeUsageManager()

    @Published private(set) var usageData = ClaudeUsageData()

    private var statsWatchSource: DispatchSourceFileSystemObject?
    private var statsFileDescriptor: CInt = -1
    private var historyWatchSource: DispatchSourceFileSystemObject?
    private var historyFileDescriptor: CInt = -1
    private var refreshTimer: Timer?

    private var currentConfig: ConfigData = [:]

    private let statsCachePath: String
    private let historyPath: String
    private let projectsPath: String

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        statsCachePath = "\(home)/.claude/stats-cache.json"
        historyPath = "\(home)/.claude/history.jsonl"
        projectsPath = "\(home)/.claude/projects"
    }

    func startUpdating(config: ConfigData) {
        currentConfig = config
        fetchData()
        startWatching(path: statsCachePath, source: &statsWatchSource, descriptor: &statsFileDescriptor)
        startWatching(path: historyPath, source: &historyWatchSource, descriptor: &historyFileDescriptor)
        // Periodically rescan session files since we can't watch them all individually
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.fetchData()
            }
        }
    }

    func stopUpdating() {
        stopWatching(source: &statsWatchSource, descriptor: &statsFileDescriptor)
        stopWatching(source: &historyWatchSource, descriptor: &historyFileDescriptor)
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    func refresh() {
        fetchData()
    }

    // MARK: - File Watching

    private func startWatching(
        path: String,
        source: inout DispatchSourceFileSystemObject?,
        descriptor: inout CInt
    ) {
        stopWatching(source: &source, descriptor: &descriptor)

        descriptor = open(path, O_EVTONLY)
        if descriptor == -1 { return }

        let newSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend],
            queue: DispatchQueue.global()
        )
        newSource.setEventHandler { [weak self] in
            Task { @MainActor in
                self?.fetchData()
            }
        }
        let fd = descriptor
        newSource.setCancelHandler {
            if fd != -1 { close(fd) }
        }
        newSource.resume()
        source = newSource
    }

    private func stopWatching(
        source: inout DispatchSourceFileSystemObject?,
        descriptor: inout CInt
    ) {
        source?.cancel()
        source = nil
        descriptor = -1
    }

    // MARK: - Data Fetching

    private func fetchData() {
        let config = currentConfig
        let fiveHourLimit = config["five-hour-limit"]?.intValue ?? 80
        let weeklyLimit = config["weekly-limit"]?.intValue ?? 500
        let plan = config["plan"]?.stringValue ?? "Pro"

        // Get counts from session JSONL files (captures all sessions including Conductor agents)
        let sessionCounts = computeFromSessions()
        // Fall back to history.jsonl for direct CLI usage
        let historyCounts = computeFromHistory()

        // Use whichever source reports more messages (session files are the superset)
        let fiveHourCount = max(sessionCounts.fiveHourCount, historyCounts.fiveHourCount)
        let todayMessages = max(sessionCounts.todayCount, historyCounts.todayCount)
        let fiveHourResetDate = sessionCounts.fiveHourCount >= historyCounts.fiveHourCount
            ? sessionCounts.fiveHourResetDate
            : historyCounts.fiveHourResetDate

        // Get weekly count from stats-cache.json (may lag behind)
        var weeklyCount = todayMessages // Start with today's count
        if FileManager.default.fileExists(atPath: statsCachePath) {
            do {
                let statsData = try Data(contentsOf: URL(fileURLWithPath: statsCachePath))
                let stats = try JSONDecoder().decode(ClaudeStatsCache.self, from: statsData)

                let todayString = Self.dateFormatter.string(from: Date())

                // Add prior days this week from stats-cache
                weeklyCount += computeWeeklyCount(from: stats.dailyActivity, excludingToday: todayString)
            } catch {
                print("ClaudeUsageManager: Error reading stats-cache: \(error)")
            }
        }

        var data = ClaudeUsageData()
        data.fiveHourCount = fiveHourCount
        data.fiveHourLimit = fiveHourLimit
        data.fiveHourPercentage = fiveHourLimit > 0 ? Double(fiveHourCount) / Double(fiveHourLimit) : 0
        data.fiveHourResetDate = fiveHourResetDate

        data.weeklyCount = weeklyCount
        data.weeklyLimit = weeklyLimit
        data.weeklyPercentage = weeklyLimit > 0 ? Double(weeklyCount) / Double(weeklyLimit) : 0
        data.weeklyResetDate = nextWeeklyReset()

        data.todayMessages = todayMessages
        data.plan = plan
        data.lastUpdated = Date()
        data.isAvailable = todayMessages > 0 || FileManager.default.fileExists(atPath: statsCachePath)

        usageData = data
    }

    // MARK: - Computations

    private func computeWeeklyCount(from dailyActivity: [ClaudeStatsCache.DailyActivity], excludingToday todayString: String) -> Int {
        let now = Date()
        var calendar = Calendar.current
        calendar.firstWeekday = 2 // Monday
        guard let startOfWeek = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)) else {
            return 0
        }
        let startString = Self.dateFormatter.string(from: startOfWeek)
        return dailyActivity
            .filter { $0.date >= startString && $0.date != todayString }
            .reduce(0) { $0 + $1.messageCount }
    }

    /// Scans session JSONL files in ~/.claude/projects/ for user messages
    private func computeFromSessions() -> (fiveHourCount: Int, fiveHourResetDate: Date?, todayCount: Int) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: projectsPath),
              let enumerator = fm.enumerator(atPath: projectsPath) else {
            return (0, nil, 0)
        }

        let now = Date()
        let fiveHoursAgo = now.addingTimeInterval(-5 * 3600)
        let startOfDay = Calendar.current.startOfDay(for: now)
        let todayPrefix = Self.dateFormatter.string(from: now)

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var fiveHourCount = 0
        var todayCount = 0
        var oldestInWindow: Date?

        while let relativePath = enumerator.nextObject() as? String {
            guard relativePath.hasSuffix(".jsonl") else { continue }

            let fullPath = "\(projectsPath)/\(relativePath)"

            // Skip files not modified since start of day
            guard let attrs = try? fm.attributesOfItem(atPath: fullPath),
                  let modDate = attrs[.modificationDate] as? Date,
                  modDate >= startOfDay else { continue }

            guard let data = fm.contents(atPath: fullPath),
                  let content = String(data: data, encoding: .utf8) else { continue }

            for line in content.components(separatedBy: "\n") {
                // Quick pre-filter to avoid JSON parsing on non-user lines
                guard !line.isEmpty, line.contains("\"type\":\"user\"") || line.contains("\"type\": \"user\"") else {
                    continue
                }
                // Skip tool-result continuations — these are internal API round-trips, not real messages
                if line.contains("\"tool_result\"") { continue }

                guard let lineData = line.data(using: .utf8),
                      let entry = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                      entry["type"] as? String == "user",
                      let timestamp = entry["timestamp"] as? String else { continue }

                // Quick prefix check before full ISO parse
                guard timestamp.hasPrefix(todayPrefix) else { continue }

                guard let date = isoFormatter.date(from: timestamp) else { continue }

                todayCount += 1

                if date >= fiveHoursAgo {
                    fiveHourCount += 1
                    if oldestInWindow == nil || date < oldestInWindow! {
                        oldestInWindow = date
                    }
                }
            }
        }

        let resetDate = oldestInWindow?.addingTimeInterval(5 * 3600)
        return (fiveHourCount, resetDate, todayCount)
    }

    /// Parses history.jsonl and returns (fiveHourCount, fiveHourResetDate, todayCount)
    private func computeFromHistory() -> (fiveHourCount: Int, fiveHourResetDate: Date?, todayCount: Int) {
        guard FileManager.default.fileExists(atPath: historyPath),
              let data = FileManager.default.contents(atPath: historyPath),
              let content = String(data: data, encoding: .utf8) else {
            return (0, nil, 0)
        }

        let now = Date()
        let fiveHoursAgo = now.addingTimeInterval(-5 * 3600)
        let fiveHoursAgoMs = fiveHoursAgo.timeIntervalSince1970 * 1000
        let startOfDay = Calendar.current.startOfDay(for: now)
        let startOfDayMs = startOfDay.timeIntervalSince1970 * 1000

        let decoder = JSONDecoder()
        let lines = content.components(separatedBy: "\n")

        var fiveHourCount = 0
        var todayCount = 0
        var oldestInWindow: Double?

        for line in lines.reversed() {
            guard !line.isEmpty,
                  let lineData = line.data(using: .utf8),
                  let entry = try? decoder.decode(HistoryEntry.self, from: lineData) else {
                continue
            }

            // Stop once we're past both windows
            if entry.timestamp < startOfDayMs && entry.timestamp < fiveHoursAgoMs {
                break
            }

            if entry.timestamp >= fiveHoursAgoMs {
                fiveHourCount += 1
                if oldestInWindow == nil || entry.timestamp < (oldestInWindow ?? .infinity) {
                    oldestInWindow = entry.timestamp
                }
            }

            if entry.timestamp >= startOfDayMs {
                todayCount += 1
            }
        }

        let resetDate = oldestInWindow.map {
            Date(timeIntervalSince1970: $0 / 1000).addingTimeInterval(5 * 3600)
        }

        return (fiveHourCount, resetDate, todayCount)
    }

    private func nextWeeklyReset() -> Date {
        var calendar = Calendar.current
        calendar.firstWeekday = 2
        let now = Date()
        var components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)
        components.weekday = 2
        components.hour = 0
        components.minute = 0
        var resetDate = calendar.date(from: components) ?? now
        if resetDate <= now {
            resetDate = calendar.date(byAdding: .weekOfYear, value: 1, to: resetDate) ?? now
        }
        return resetDate
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
