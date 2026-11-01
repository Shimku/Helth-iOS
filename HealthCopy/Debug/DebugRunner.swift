#if DEBUG
import SwiftUI

/// Launch arguments for the simulator tests (scripts/roundtrip.sh drives them):
///   -probe             measure what this iOS allows
///   -seed full|partial fill Health with test data
///   -export            run Send, copy the file to Documents/export.healthcopy
///   -import NAME       run Receive on Documents/NAME (or Apple's export.zip), write Documents/import-result.json
///   -remove            remove everything this app added
///   -open NAME         show Receive's plan for Documents/NAME without copying
///   -screen send|receive  open that screen
///   -healthapp         home shows the steps for the Health app's export
///   -privacy           home scrolls to its privacy section
///   -quiet             no status line on screen (for screenshots)
/// The status line at the bottom reads "debug-done" or "debug-failed: ..." when finished.
@MainActor
final class DebugStatus: ObservableObject {
    static let shared = DebugStatus()
    @Published var text = ""
}

struct DebugBadge: View {
    @ObservedObject var status = DebugStatus.shared
    var body: some View {
        if !status.text.isEmpty {
            Text(status.text).font(.caption2).padding(4).background(.yellow).accessibilityIdentifier("debug-status")
        }
    }
}

enum DebugRunner {
    static func arg(_ name: String) -> String? {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: name) else { return nil }
        return i + 1 < a.count && !a[i + 1].hasPrefix("-") ? a[i + 1] : ""
    }

    static var docs: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }

    @MainActor
    static func run(_ app: AppModel) async {
        let any = ["-probe", "-seed", "-export", "-import", "-remove", "-syncprobe", "-open", "-screen"].contains { CommandLine.arguments.contains($0) }
        guard any else { return }
        let quiet = CommandLine.arguments.contains("-quiet")
        func finish(_ s: String) {
            if !quiet { DebugStatus.shared.text = s }
            try? s.write(to: docs.appendingPathComponent("debug-status.txt"), atomically: true, encoding: .utf8)
        }
        finish("debug-running")
        var timings: [String: Double] = [:]
        do {
            let started = Date()
            if let screen = arg("-screen") { app.path = [screen == "send" ? .send : .receive] }
            if CommandLine.arguments.contains("-probe") { await Probe.run() }
            if CommandLine.arguments.contains("-syncprobe") { try await Probe.syncIdentifiers() }
            if let mode = arg("-seed") {
                if mode == "bulk" { try await Seeder.bulk() } else { try await Seeder.seed(partial: mode == "partial") }
            }
            if arg("-export") != nil {
                app.path = [.send]
                app.send.start()
                while [.intro, .asking].contains(app.send.phase) { try await Task.sleep(nanoseconds: 100_000_000) }
                let ran = Date()
                while app.send.phase == .running { try await Task.sleep(nanoseconds: 100_000_000) }
                timings["export"] = Date().timeIntervalSince(ran)
                if case .failed(let why) = app.send.phase { throw DebugError(why) }
                let out = docs.appendingPathComponent("export.healthcopy")
                try? FileManager.default.removeItem(at: out)
                try FileManager.default.copyItem(at: app.send.file!, to: out)
            }
            if let name = arg("-import") {
                // A full path reads straight from the Mac (simulator apps can), else Documents/NAME.
                app.open(name.hasPrefix("/") ? URL(fileURLWithPath: name) : docs.appendingPathComponent(name))
                let reading = Date()
                while app.receive.phase == .reading { try await Task.sleep(nanoseconds: 100_000_000) }
                timings["read"] = Date().timeIntervalSince(reading)
                if let why = app.receive.loadError { throw DebugError(why) }
                if arg("-again") != nil { app.receive.start(again: true) } else { app.receive.start() }
                while [.loaded, .asking].contains(app.receive.phase) { try await Task.sleep(nanoseconds: 100_000_000) }
                let ran = Date()
                while app.receive.phase == .running { try await Task.sleep(nanoseconds: 100_000_000) }
                timings["import"] = Date().timeIntervalSince(ran)
                if case .failed(let why) = app.receive.phase { throw DebugError(why) }
                let report: [String: Any] = [
                    "seconds": timings["import"] ?? 0,
                    "results": try JSONSerialization.jsonObject(with: JSONEncoder().encode(app.receive.results)),
                    "totals": try JSONSerialization.jsonObject(with: JSONEncoder().encode(app.receive.manifest?.totals ?? [:])),
                ]
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    .write(to: docs.appendingPathComponent("import-result.json"))
            }
            if let name = arg("-open") {
                // Just show the file's plan screen, for screenshots.
                app.open(name.hasPrefix("/") ? URL(fileURLWithPath: name) : docs.appendingPathComponent(name))
                while app.receive.phase == .reading { try await Task.sleep(nanoseconds: 100_000_000) }
            }
            if CommandLine.arguments.contains("-remove") {
                let n = try await Remover.removeAll()
                try "\(n)".write(to: docs.appendingPathComponent("removed.txt"), atomically: true, encoding: .utf8)
            }
            let times = timings.map { "\($0.key) \(String(format: "%.1f", $0.value))s" }.sorted().joined(separator: ", ")
            finish("debug-done \(Int(Date().timeIntervalSince(started)))s \(times)")
        } catch {
            finish("debug-failed: \(error)")
        }
    }

    struct DebugError: Error, CustomStringConvertible {
        let description: String
        init(_ s: String) { description = s }
    }
}
#endif
