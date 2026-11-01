import SwiftUI
import Foundation
import Combine
import UniformTypeIdentifiers
import ZIPFoundation

struct WHOOPImportedNight: Codable, Identifiable {
    var id: String { (wakeOnset ?? sleepOnset ?? cycleStart)?.timeIntervalSince1970.description ?? UUID().uuidString }
    let cycleStart: Date?
    let sleepOnset: Date?
    let wakeOnset: Date?
    let asleepMinutes: Double?
    let inBedMinutes: Double?
    let lightMinutes: Double?
    let deepMinutes: Double?
    let remMinutes: Double?
    let awakeMinutes: Double?
    let sleepNeedMinutes: Double?
    let sleepDebtMinutes: Double?
    let recoveryScore: Double?
    let restingHeartRate: Double?
    let hrvMilliseconds: Double?
    let respiratoryRate: Double?
    let skinTemperatureCelsius: Double?
    let bloodOxygenPercent: Double?
    let dayStrain: Double?
}

@MainActor
final class WHOOPImportStore: ObservableObject {
    @Published private(set) var nights: [WHOOPImportedNight] = []
    @Published private(set) var importedWorkoutCount = 0
    @Published private(set) var sourceName: String?
    @Published private(set) var importedAt: Date?
    @Published private(set) var status = "No WHOOP export imported"
    @Published private(set) var isImporting = false

    private let persistenceKey = "pulseforge.whoop.import.v1"

    init() { restore() }

    var latestNight: WHOOPImportedNight? {
        nights.max { ($0.wakeOnset ?? $0.sleepOnset ?? .distantPast) < ($1.wakeOnset ?? $1.sleepOnset ?? .distantPast) }
    }

    func importZIP(from url: URL) {
        guard !isImporting else { return }
        isImporting = true
        defer { isImporting = false }
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }

        do {
            let archive = try Archive(url: url, accessMode: .read)
            var csv: [String: String] = [:]
            for entry in archive where entry.type == .file && entry.path.lowercased().hasSuffix(".csv") {
                let name = URL(fileURLWithPath: entry.path).lastPathComponent.lowercased()
                guard ["physiological_cycles.csv", "sleeps.csv", "workouts.csv"].contains(name) else { continue }
                var bytes = Data()
                _ = try archive.extract(entry) { bytes.append($0) }
                if let value = String(data: bytes, encoding: .utf8) { csv[name] = value }
            }

            guard let cyclesCSV = csv["physiological_cycles.csv"] ?? csv["sleeps.csv"] else {
                throw ImportError.missingWHOOPData
            }
            var parsed = Self.parseNights(cyclesCSV)
            if let sleepsCSV = csv["sleeps.csv"] {
                let sleepRows = Self.parseNights(sleepsCSV)
                for sleep in sleepRows {
                    if let index = parsed.firstIndex(where: { Self.sameNight($0, sleep) }) {
                        parsed[index] = Self.mergingSleep(sleep, into: parsed[index])
                    } else {
                        parsed.append(sleep)
                    }
                }
            }
            guard !parsed.isEmpty else { throw ImportError.noRows }
            parsed.sort { ($0.wakeOnset ?? $0.sleepOnset ?? .distantPast) < ($1.wakeOnset ?? $1.sleepOnset ?? .distantPast) }
            nights = parsed
            importedWorkoutCount = Self.countRows(csv["workouts.csv"] ?? "")
            sourceName = url.lastPathComponent
            importedAt = Date()
            status = "Imported \(parsed.count) WHOOP nights · \(importedWorkoutCount) workouts"
            persist()
        } catch {
            status = "Import failed: \(error.localizedDescription)"
        }
    }

    func setImportError(_ error: Error) { status = "Import failed: \(error.localizedDescription)" }

    private func restore() {
        guard let data = UserDefaults.standard.data(forKey: persistenceKey),
              let saved = try? JSONDecoder().decode(SavedImport.self, from: data) else { return }
        nights = saved.nights
        importedWorkoutCount = saved.workoutCount
        sourceName = saved.sourceName
        importedAt = saved.importedAt
        status = "Restored \(nights.count) WHOOP nights from \(sourceName ?? "previous import")"
    }

    private func persist() {
        let saved = SavedImport(nights: nights, workoutCount: importedWorkoutCount,
                                sourceName: sourceName, importedAt: importedAt)
        if let data = try? JSONEncoder().encode(saved) {
            UserDefaults.standard.set(data, forKey: persistenceKey)
        }
    }

    private struct SavedImport: Codable {
        let nights: [WHOOPImportedNight]
        let workoutCount: Int
        let sourceName: String?
        let importedAt: Date?
    }

    private enum ImportError: LocalizedError {
        case invalidArchive, missingWHOOPData, noRows
        var errorDescription: String? {
            switch self {
            case .invalidArchive: "This file is not a readable ZIP archive."
            case .missingWHOOPData: "No physiological_cycles.csv or sleeps.csv found in this WHOOP export."
            case .noRows: "WHOOP CSV files were found, but no valid sleep rows could be read."
            }
        }
    }

    nonisolated private static func parseNights(_ csv: String) -> [WHOOPImportedNight] {
        let rows = CSV.decode(csv)
        guard let header = rows.first else { return [] }
        let keys = header.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        return rows.dropFirst().compactMap { row in
            guard row.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { return nil }
            func value(_ key: String) -> String? {
                guard let i = keys.firstIndex(of: key.lowercased()), i < row.count else { return nil }
                let v = row[i].trimmingCharacters(in: .whitespacesAndNewlines)
                return v.isEmpty ? nil : v
            }
            let zone = value("cycle timezone") ?? "UTC"
            func date(_ key: String) -> Date? { value(key).flatMap { parseDate($0, zone: zone) } }
            func number(_ key: String) -> Double? { value(key).flatMap(Double.init) }
            return WHOOPImportedNight(
                cycleStart: date("cycle start time"),
                sleepOnset: date("sleep onset"),
                wakeOnset: date("wake onset"),
                asleepMinutes: number("asleep duration (min)"),
                inBedMinutes: number("in bed duration (min)"),
                lightMinutes: number("light sleep duration (min)"),
                deepMinutes: number("deep (sws) duration (min)"),
                remMinutes: number("rem duration (min)"),
                awakeMinutes: number("awake duration (min)"),
                sleepNeedMinutes: number("sleep need (min)"),
                sleepDebtMinutes: number("sleep debt (min)"),
                recoveryScore: number("recovery score %"),
                restingHeartRate: number("resting heart rate (bpm)"),
                hrvMilliseconds: number("heart rate variability (ms)"),
                respiratoryRate: number("respiratory rate (rpm)"),
                skinTemperatureCelsius: number("skin temp (celsius)"),
                bloodOxygenPercent: number("blood oxygen %"),
                dayStrain: number("day strain")
            )
        }
    }

    nonisolated private static func parseDate(_ raw: String, zone: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = parseTimeZone(zone)
        return formatter.date(from: raw)
    }

    nonisolated private static func parseTimeZone(_ raw: String) -> TimeZone {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.hasPrefix("UTC"), cleaned.count >= 8 else {
            return TimeZone(identifier: cleaned) ?? .current
        }
        let offset = String(cleaned.dropFirst(3))
        let sign = offset.hasPrefix("-") ? -1 : 1
        let digits = offset.filter(\.isNumber)
        guard digits.count >= 4,
              let hours = Int(digits.prefix(2)),
              let minutes = Int(digits.suffix(2)) else { return .current }
        return TimeZone(secondsFromGMT: sign * (hours * 3600 + minutes * 60)) ?? .current
    }

    nonisolated private static func sameNight(_ lhs: WHOOPImportedNight, _ rhs: WHOOPImportedNight) -> Bool {
        guard let a = lhs.wakeOnset ?? lhs.sleepOnset, let b = rhs.wakeOnset ?? rhs.sleepOnset else { return false }
        return abs(a.timeIntervalSince(b)) < 60
    }

    nonisolated private static func mergingSleep(_ sleep: WHOOPImportedNight, into cycle: WHOOPImportedNight) -> WHOOPImportedNight {
        WHOOPImportedNight(
            cycleStart: cycle.cycleStart ?? sleep.cycleStart,
            sleepOnset: sleep.sleepOnset ?? cycle.sleepOnset,
            wakeOnset: sleep.wakeOnset ?? cycle.wakeOnset,
            asleepMinutes: sleep.asleepMinutes ?? cycle.asleepMinutes,
            inBedMinutes: sleep.inBedMinutes ?? cycle.inBedMinutes,
            lightMinutes: sleep.lightMinutes ?? cycle.lightMinutes,
            deepMinutes: sleep.deepMinutes ?? cycle.deepMinutes,
            remMinutes: sleep.remMinutes ?? cycle.remMinutes,
            awakeMinutes: sleep.awakeMinutes ?? cycle.awakeMinutes,
            sleepNeedMinutes: sleep.sleepNeedMinutes ?? cycle.sleepNeedMinutes,
            sleepDebtMinutes: sleep.sleepDebtMinutes ?? cycle.sleepDebtMinutes,
            recoveryScore: cycle.recoveryScore,
            restingHeartRate: cycle.restingHeartRate,
            hrvMilliseconds: cycle.hrvMilliseconds,
            respiratoryRate: sleep.respiratoryRate ?? cycle.respiratoryRate,
            skinTemperatureCelsius: cycle.skinTemperatureCelsius,
            bloodOxygenPercent: cycle.bloodOxygenPercent,
            dayStrain: cycle.dayStrain
        )
    }

    nonisolated private static func countRows(_ csv: String) -> Int {
        max(0, CSV.decode(csv).count - 1)
    }
}

private enum CSV {
    static func decode(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\"" {
                if quoted && i + 1 < chars.count && chars[i + 1] == "\"" {
                    field.append("\""); i += 1
                } else { quoted.toggle() }
            } else if c == "," && !quoted {
                row.append(field); field = ""
            } else if (c == "\n" || c == "\r") && !quoted {
                if c == "\r" && i + 1 < chars.count && chars[i + 1] == "\n" { i += 1 }
                row.append(field); field = ""
                rows.append(row); row = []
            } else { field.append(c) }
            i += 1
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }
}

struct WHOOPDataImportSheet: View {
    @EnvironmentObject private var importer: WHOOPImportStore
    @Environment(\.dismiss) private var dismiss
    @State private var showingPicker = false
    @State private var selectedFile: URL?
    @State private var showingError = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                Label("WHOOP DATA IMPORT", systemImage: "arrow.down.doc.fill")
                    .font(.system(size: 11, weight: .bold)).tracking(1.4)
                    .foregroundStyle(WoopReplicaPalette.sleep)
                Text("Import your WHOOP export")
                    .font(WoopTypography.emphasis(24)).foregroundStyle(WoopReplicaPalette.primary)
                Text("Choose the ZIP downloaded from WHOOP. PulseForge reads physiological cycles, sleep sessions and workout summaries. Imported values remain labelled as WHOOP Export data.")
                    .font(WoopTypography.body(12)).foregroundStyle(WoopReplicaPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button { showingPicker = true } label: {
                    Label("Choose WHOOP ZIP", systemImage: "folder")
                        .font(WoopTypography.emphasis(14))
                        .frame(maxWidth: .infinity).padding(16)
                        .background(WoopReplicaPalette.sleep, in: RoundedRectangle(cornerRadius: 14))
                        .foregroundStyle(.black)
                }
                .buttonStyle(.plain)
                VStack(alignment: .leading, spacing: 7) {
                    Text("IMPORT STATUS").font(WoopTypography.label(9)).tracking(1).foregroundStyle(WoopReplicaPalette.secondary)
                    Text(importer.status).font(WoopTypography.body(12)).foregroundStyle(WoopReplicaPalette.primary)
                    if let name = importer.sourceName {
                        Text(name).font(WoopTypography.body(10)).foregroundStyle(WoopReplicaPalette.muted)
                    }
                    if let date = importer.importedAt {
                        Text("Imported \(date.formatted(date: .abbreviated, time: .shortened))")
                            .font(WoopTypography.body(10)).foregroundStyle(WoopReplicaPalette.muted)
                    }
                }
                .padding(15).frame(maxWidth: .infinity, alignment: .leading)
                .background(WoopReplicaPalette.surface, in: RoundedRectangle(cornerRadius: 15))
                if let night = importer.latestNight {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("LATEST IMPORTED NIGHT").font(WoopTypography.label(9)).tracking(1).foregroundStyle(WoopReplicaPalette.secondary)
                        Text(night.asleepMinutes.map { String(format: "%.1f hours asleep", $0 / 60) } ?? "Sleep duration unavailable")
                            .font(WoopTypography.emphasis(18)).foregroundStyle(WoopReplicaPalette.primary)
                        if let start = night.sleepOnset, let end = night.wakeOnset {
                            Text("\(start.formatted(date: .omitted, time: .shortened)) – \(end.formatted(date: .omitted, time: .shortened))")
                                .font(WoopTypography.body(12)).foregroundStyle(WoopReplicaPalette.secondary)
                        }
                        HStack {
                            importMetric("HRV", night.hrvMilliseconds.map { String(format: "%.0f ms", $0) } ?? "—")
                            importMetric("RHR", night.restingHeartRate.map { String(format: "%.0f bpm", $0) } ?? "—")
                            importMetric("RECOVERY", night.recoveryScore.map { String(format: "%.0f%%", $0) } ?? "—")
                        }
                    }
                    .padding(15).frame(maxWidth: .infinity, alignment: .leading)
                    .background(WoopReplicaPalette.surface, in: RoundedRectangle(cornerRadius: 15))
                }
                Spacer()
                Text("This imports historical summaries only. New overnight data still requires a working WHOOP band sync.")
                    .font(WoopTypography.body(10)).foregroundStyle(WoopReplicaPalette.muted)
            }
            .padding(20)
            .background(WoopReplicaPalette.canvas.ignoresSafeArea())
            .navigationTitle("Import WHOOP Data")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .fileImporter(isPresented: $showingPicker, allowedContentTypes: [.zip], allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first { importer.importZIP(from: url) }
                case .failure(let error):
                    importer.setImportError(error)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func importMetric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(WoopTypography.label(8)).foregroundStyle(WoopReplicaPalette.muted)
            Text(value).font(WoopTypography.metricBold(12)).foregroundStyle(WoopReplicaPalette.primary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
