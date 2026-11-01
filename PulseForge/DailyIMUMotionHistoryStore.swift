import Foundation

/// Workout-independent, bounded daily archive for decoded WHOOP IMU samples.
/// One JSON array per line keeps appends small and avoids rewriting history.
final class DailyIMUMotionHistoryStore {
    static let shared = DailyIMUMotionHistoryStore()
    private let queue = DispatchQueue(label: "pulseforge.daily-imu-history")
    private let retentionDays = 3

    private init() {}

    @discardableResult
    func append(_ samples: [WhoopIMUSample], receivedAt: Date = Date()) -> Bool {
        guard !samples.isEmpty, let data = try? JSONEncoder().encode(samples),
              let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return false }
        return queue.sync {
            do {
                let folder = support.appendingPathComponent("PulseForge/WhoopIMU", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = .current
                formatter.dateFormat = "yyyy-MM-dd"
                let day = formatter.string(from: receivedAt)
                let url = folder.appendingPathComponent("imu-\(day).jsonl")
                if !FileManager.default.fileExists(atPath: url.path) {
                    guard FileManager.default.createFile(atPath: url.path, contents: nil) else { return false }
                }
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                var line = data
                line.append(0x0A)
                try handle.write(contentsOf: line)
                prune(folder: folder, formatter: formatter, today: day)
                return true
            } catch { return false }
        }
    }

    private func prune(folder: URL, formatter: DateFormatter, today: String) {
        let cutoff = Calendar.current.date(byAdding: .day, value: -(retentionDays - 1), to: Date()) ?? Date()
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }
        for file in files where file.lastPathComponent.hasPrefix("imu-") && file.pathExtension == "jsonl" {
            let key = String(file.deletingPathExtension().lastPathComponent.dropFirst(4))
            if key != today, let date = formatter.date(from: key), date < cutoff {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}
