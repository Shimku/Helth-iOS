import SwiftUI
import HealthKit
import UniformTypeIdentifiers

enum Files {
    /// Hëlth's own folder. It's kept out of iCloud and computer backups: the files in it hold
    /// Health data, and a backup only needs Health's own copy.
    static var support: URL {
        var url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("HealthCopy", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        return url
    }

    static var incoming: URL { folder("Incoming") }
    static var exports: URL { folder("Exports") }

    private static func folder(_ name: String) -> URL {
        let url = support.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func size(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    static var freeSpace: Int64 {
        let values = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? .max
    }

    static let archiveType = UTType(exportedAs: ArchiveFormat.typeIdentifier)
}

/// The app's website, for the privacy policy and help.
enum Site {
    static let privacy = URL(string: "https://helthtransfer.com/privacy")!
    static let help = URL(string: "https://helthtransfer.com/help")!
}

enum Format {
    static func count(_ n: Int) -> String { n.formatted() }

    static func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

    static func day(_ ref: Double) -> String { Date(ref: ref).formatted(date: .abbreviated, time: .omitted) }

    static func moment(_ ref: Double) -> String { Date(ref: ref).formatted(date: .abbreviated, time: .shortened) }

    static func records(_ n: Int) -> String { n == 1 ? "1 record" : "\(n.formatted()) records" }

    static func remaining(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "" }
        if seconds < 60 { return "Less than a minute left" }
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes < 60 { return minutes == 1 ? "About a minute left" : "About \(minutes) minutes left" }
        let hours = Double(minutes) / 60
        return String(format: "About %.1f hours left", hours)
    }
}

/// Keeps the screen on while a long job runs; the Health database locks with the phone.
enum Awake {
    @MainActor static func set(_ on: Bool) { UIApplication.shared.isIdleTimerDisabled = on }
}

// MARK: App

@MainActor
final class AppModel: ObservableObject {
    enum Screen: Hashable { case send, receive }

    @Published var path: [Screen] = []
    let send = ExportModel()
    let receive = ImportModel()

    init() {
        receive.restore()
    }

    /// A file arrived by AirDrop or "Open in". Keep a copy of our own and show it.
    func open(_ url: URL) {
        guard url.isFileURL else { return }
        receive.take(url)
        path = [.receive]
    }
}

// MARK: Send

@MainActor
final class ExportModel: ObservableObject {
    enum Phase: Equatable { case intro, asking, limited(Date), running, done, failed(String) }

    @Published var phase = Phase.intro
    @Published var progress = ExportProgress()
    @Published var waiting = false
    @Published var manifest: Manifest?
    @Published var file: URL?
    private var task: Task<Void, Never>?

    /// `anyway` goes ahead even though Health only shares recent data with the app.
    func start(anyway: Bool = false) {
        guard phase != .asking, phase != .running else { return }
        phase = .asking
        task = Task {
            do {
                guard HKHealthStore.isHealthDataAvailable() else { throw HealthUnavailable() }
                try await HealthAccess.request(share: [], read: HealthAccess.exportReadTypes)
                if !anyway, let cut = await HealthAccess.limitedSince(HealthAccess.exportReadTypes) {
                    phase = .limited(cut)
                    return
                }
                phase = .running
                Awake.set(true)
                defer { Awake.set(false) }
                Unlock.onChange = { on in DispatchQueue.main.async { self.waiting = on } }

                for old in (try? FileManager.default.contentsOfDirectory(at: Files.exports, includingPropertiesForKeys: nil)) ?? [] {
                    try? FileManager.default.removeItem(at: old)
                }
                let stamp = Date().formatted(.iso8601.year().month().day().dateSeparator(.dash))
                let url = Files.exports.appendingPathComponent("Hëlth \(stamp).\(ArchiveFormat.fileExtension)")
                let device = UIDevice.current.model
                let system = "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
                let exporter = try Exporter(url: url, device: device, system: system) { p in
                    DispatchQueue.main.async { self.progress = p }
                }
                let manifest = try await Task.detached(priority: .userInitiated) { try await exporter.run() }.value
                self.manifest = manifest
                self.file = url
                phase = .done
            } catch is CancellationError {
                phase = .intro
            } catch {
                phase = .failed(error.localizedDescription)
            }
            waiting = false
        }
    }

    func reset() {
        task?.cancel()
        phase = .intro
        progress = ExportProgress()
    }
}

struct HealthUnavailable: LocalizedError {
    var errorDescription: String? { "Health isn't available on this device." }
}

// MARK: Receive

@MainActor
final class ImportModel: ObservableObject {
    enum Phase: Equatable { case noFile, reading, loaded, asking, limited(Date), running, stopped, done, failed(String) }

    @Published var phase = Phase.noFile
    @Published var lines: [Importer.PlanLine] = []
    @Published var manifest: Manifest?
    @Published var progress = ImportProgress()
    @Published var results: [String: TypeResult] = [:]
    @Published var waiting = false
    @Published var loadError: String?
    @Published var resumable = false
    /// How much of Apple's Health export has been read, 0-1.
    @Published var reading = 0.0
    private(set) var importer: Importer?
    private var task: Task<Void, Never>?
    private var started: (Date, Int)?

    private static let fileKey = "importFile"

    /// Reopens the file from last time, so an interrupted copy can carry on.
    func restore() {
        guard let name = UserDefaults.standard.string(forKey: Self.fileKey) else { return }
        let url = Files.incoming.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        load(url)
    }

    /// Copies an incoming file into the app's own folder and opens it. Apple's Health export is
    /// read where it is and turned into a file of our own first.
    func take(_ source: URL) {
        let scoped = source.startAccessingSecurityScopedResource()
        if AppleExport.detect(source) {
            convert(source, scoped: scoped)
            return
        }
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let name = source.lastPathComponent
        let dest = Files.incoming.appendingPathComponent(name)
        do {
            if source.standardizedFileURL != dest.standardizedFileURL {
                for old in (try? FileManager.default.contentsOfDirectory(at: Files.incoming, includingPropertiesForKeys: nil)) ?? [] {
                    try? FileManager.default.removeItem(at: old)
                }
                try FileManager.default.copyItem(at: source, to: dest)
                if source.path.contains("/Inbox/") { try? FileManager.default.removeItem(at: source) }
            }
            task?.cancel()
            load(dest)
        } catch {
            loadError = "Couldn't open the file: \(error.localizedDescription)"
            phase = .noFile
        }
    }

    private func convert(_ source: URL, scoped: Bool) {
        task?.cancel()
        importer = nil
        manifest = nil
        loadError = nil
        reading = 0
        phase = .reading
        task = Task {
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            Awake.set(true)
            defer { Awake.set(false) }
            do {
                let files = try AppleExport.Files(source)
                // The converted file comes to roughly a tenth of export.xml.
                let need = files.mainSize / 8 + 100_000_000
                if Files.freeSpace < need {
                    throw ImportModel.Problem("This iPhone needs about \(Format.bytes(need)) of free storage to read the export, and has \(Format.bytes(Files.freeSpace)). Free up some space (Settings > General > iPhone Storage), then choose the file again.")
                }
                for old in (try? FileManager.default.contentsOfDirectory(at: Files.incoming, includingPropertiesForKeys: nil)) ?? [] {
                    try? FileManager.default.removeItem(at: old)
                }
                let out = Files.incoming.appendingPathComponent("Apple Health export.\(ArchiveFormat.fileExtension)")
                let converter = try AppleExportConverter(files: files, to: out) { p in
                    DispatchQueue.main.async { self.reading = min(1, Double(p.read) / Double(max(1, p.total))) }
                }
                _ = try await Task.detached(priority: .userInitiated) { try converter.run() }.value
                if source.path.contains("/Inbox/") { try? FileManager.default.removeItem(at: source) }
                load(out)
            } catch {
                loadError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                phase = .noFile
            }
        }
    }

    struct Problem: LocalizedError {
        let errorDescription: String?
        init(_ s: String) { errorDescription = s }
    }

    var fromApple: Bool { manifest?.origin == AppleExport.origin }

    private func load(_ url: URL) {
        do {
            let importer = try Importer(url: url, stateDirectory: Files.support)
            importer.report = { p in DispatchQueue.main.async { self.update(p) } }
            self.importer = importer
            manifest = importer.manifest
            lines = importer.plan()
            results = importer.state.results
            progress = ImportProgress(done: importer.state.workDone, total: max(1, importer.manifest.work), current: "")
            resumable = importer.hasStarted && !importer.state.finished
            phase = importer.state.finished ? .done : .loaded
            loadError = nil
            UserDefaults.standard.set(url.lastPathComponent, forKey: Self.fileKey)
        } catch {
            loadError = error.localizedDescription
            phase = .noFile
        }
    }

    private func update(_ p: ImportProgress) {
        progress = p
        if let importer { results = importer.state.results }
    }

    var remaining: String {
        guard let (at, from) = started else { return "" }
        let elapsed = Date().timeIntervalSince(at)
        let done = progress.done - from
        guard elapsed > 5, done > 0 else { return "" }
        return Format.remaining(Double(progress.total - progress.done) / (Double(done) / elapsed))
    }

    /// Space Health is likely to need, with room to spare. A record takes a few hundred bytes.
    var spaceNeeded: Int64 { Int64(manifest?.work ?? 0) * 400 + 300_000_000 }

    var lowOnSpace: Bool { Files.freeSpace < spaceNeeded }

    /// `anyway` goes ahead even though Health only lets the app see this phone's recent data,
    /// which means older duplicates can't be spotted.
    func start(again: Bool = false, anyway: Bool = false) {
        guard let importer, phase != .asking, phase != .running else { return }
        if again { importer.forgetProgress(); results = [:]; progress.done = 0 }
        phase = .asking
        task = Task {
            do {
                try await importer.authorize()
                if !anyway, let cut = await HealthAccess.limitedSince(importer.readTypes),
                   let first = importer.manifest.totals.values.compactMap(\.first).min(), first < cut.ref {
                    phase = .limited(cut)
                    return
                }
                phase = .running
                started = (Date(), progress.done)
                Awake.set(true)
                defer { Awake.set(false) }
                Unlock.onChange = { on in DispatchQueue.main.async { self.waiting = on } }
                try await Task.detached(priority: .userInitiated) { try await importer.run() }.value
                results = importer.state.results
                progress.done = progress.total
                resumable = false
                phase = .done
            } catch is CancellationError {
                results = importer.state.results
                resumable = true
                phase = .stopped
            } catch {
                results = importer.state.results
                resumable = importer.hasStarted
                phase = .failed(error.localizedDescription)
            }
            waiting = false
        }
    }

    func stop() { task?.cancel() }

    // Totals for the summary screens.
    var copied: Int { results.values.reduce(0) { $0 + $1.copied } }
    var already: Int { results.values.reduce(0) { $0 + $1.already } }
    var failed: Int { results.values.reduce(0) { $0 + $1.failed } }
    var skipped: Int { results.values.reduce(0) { $0 + $1.skipped } }
}

// MARK: Remove

@MainActor
final class RemoveModel: ObservableObject {
    enum Phase: Equatable { case idle, working, done(Int), failed(String) }
    @Published var phase = Phase.idle

    func run() {
        phase = .working
        Task {
            do {
                let n = try await Remover.removeAll()
                phase = .done(n)
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }
}

/// Deletes everything this app wrote to Health on this phone. HealthKit only lets an app
/// delete its own records, and the predicate asks for exactly those. It asks for no new
/// permission: the app can only have added kinds of data it was already allowed to write.
enum Remover {
    static func removeAll() async throws -> Int {
        var types: [HKSampleType] = [HKObjectType.workoutType(), HKSeriesType.workoutRoute(), HKSeriesType.heartbeat()]
        types += Catalog.quantityTypes.map(\.0)
        types += Catalog.categoryTypes
        if #available(iOS 18.0, *) { types.append(HKObjectType.stateOfMindType()) }
        let mine = HKQuery.predicateForObjects(from: HKSource.default())
        var total = 0
        for id in Catalog.correlationTypes {
            if let t = HKObjectType.correlationType(forIdentifier: HKCorrelationTypeIdentifier(rawValue: id)) {
                total += (try? await Health.store.deleteObjects(of: t, predicate: mine)) ?? 0
            }
        }
        for t in types where HealthAccess.canWrite(t) {
            total += try await Unlock.retrying { try await Health.store.deleteObjects(of: t, predicate: mine) }
        }
        for name in (try? FileManager.default.contentsOfDirectory(atPath: Files.support.path)) ?? [] where name.hasPrefix("import-") {
            try? FileManager.default.removeItem(at: Files.support.appendingPathComponent(name))
        }
        return total
    }
}
