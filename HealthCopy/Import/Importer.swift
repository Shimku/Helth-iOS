import HealthKit
import CoreLocation

/// What happened to one type. Everything in the file ends up in exactly one of the counts.
struct TypeResult: Codable {
    var copied = 0
    var already = 0
    var failed = 0
    var skipped = 0
    var reason: String?
    var errors: [String] = []

    var total: Int { copied + already + failed + skipped }

    mutating func note(_ error: String) {
        if errors.count < 3 && !errors.contains(error) { errors.append(error) }
    }
}

/// Saved after every frame, so a closed app or a dead battery picks up where it stopped.
struct ImportState: Codable {
    var archiveID: String
    var nextFrame = 0
    var workDone = 0
    var finished = false
    var results: [String: TypeResult] = [:]
}

struct ImportProgress {
    var done = 0
    var total = 1
    var current = ""
}

enum ImportError: LocalizedError {
    case outOfSpace
    case nothingAllowed

    var errorDescription: String? {
        switch self {
        case .outOfSpace: return "This iPhone ran out of storage. Free up some space (Settings > General > iPhone Storage), then tap Continue. Nothing is copied twice."
        case .nothingAllowed: return "Hëlth isn't allowed to add anything yet. Tap Copy again, turn everything on (Turn On All or Select All), then tap Allow or Continue."
        }
    }
}

/// Why a whole type can't be copied.
enum Reason {
    static let appleOnly = "Only Apple's own apps can add this to Health, so no app can copy it."
    static let newerIOS = "This iPhone's iOS doesn't have this kind of data. Updating iOS and copying again would bring it over."
    static let notAllowed = "Not allowed in the Health permissions. In the Health app, tap your picture, then Apps > Hëlth, turn it on and tap Copy again."
}

/// Writes a .healthcopy file into Health on this iPhone.
///
/// Nothing is overwritten and nothing is copied twice: every record is first checked against
/// what's already here (same type, same start, end and value, to the millisecond, or to the
/// second for Apple's export), and each one is tagged with the original's UUID as its sync
/// identifier.
final class Importer {
    let reader: ArchiveReader
    var manifest: Manifest { reader.manifest }
    private(set) var state: ImportState
    private let stateURL: URL
    private var allowed: [String: Bool] = [:]
    /// What the importer reads back to spot duplicates. Set by `authorize`.
    private(set) var readTypes = Set<HKObjectType>()
    private var reasons: [String: String] = [:]
    private var policies: [String: MetaPolicy] = [:]
    private var progress = ImportProgress()
    /// Why the last record couldn't be built, for the report.
    private var lastBuildError: String?
    private var lastReport = Date.distantPast
    var report: (ImportProgress) -> Void = { _ in }

    init(url: URL, stateDirectory: URL) throws {
        reader = try ArchiveReader(url: url)
        stateURL = stateDirectory.appendingPathComponent("import-\(reader.manifest.id).json")
        if let data = try? Data(contentsOf: stateURL), let saved = try? JSONDecoder().decode(ImportState.self, from: data) {
            state = saved
        } else {
            state = ImportState(archiveID: reader.manifest.id)
        }
        progress.total = max(1, reader.manifest.work)
        progress.done = state.workDone
    }

    var hasStarted: Bool { state.nextFrame > 0 }

    func forgetProgress() {
        try? FileManager.default.removeItem(at: stateURL)
        state = ImportState(archiveID: manifest.id)
        progress.done = 0
    }

    // MARK: Plan and permission

    enum Status { case copy, appleOnly, newerIOS }

    struct PlanLine: Identifiable {
        var key: String
        var name: String
        var count: Int
        var status: Status
        var id: String { key }
    }

    /// What's in the file and whether this iPhone can take it, before asking for anything.
    func plan() -> [PlanLine] {
        var lines: [PlanLine] = []
        var probe = Set<HKSampleType>()
        var typeFor: [String: HKSampleType] = [:]
        for key in manifest.totals.keys {
            if let t = Catalog.sampleType(for: key), !(t is HKCorrelationType) { probe.insert(t); typeFor[key] = t }
        }
        let refused = HealthAccess.writable(probe).refused
        for (key, total) in manifest.totals {
            var status = Status.copy
            if Catalog.sampleType(for: key) == nil { status = .newerIOS }
            else if let t = typeFor[key], refused.contains(t) { status = .appleOnly }
            lines.append(PlanLine(key: key, name: Catalog.name(for: key), count: total.count, status: status))
        }
        return lines.sorted { $0.count > $1.count }
    }

    func authorize() async throws {
        let lines = plan()
        var share = Set<HKSampleType>()
        for line in lines where line.status == .copy {
            guard let t = Catalog.sampleType(for: line.key), !(t is HKCorrelationType) else { continue }
            share.insert(t)
            share.formUnion(HealthAccess.companions(of: t))
        }
        var read = Set<HKObjectType>(share)
        read.insert(HKObjectType.workoutType())
        readTypes = read
        let refused = try await HealthAccess.request(share: share, read: read)

        for line in lines {
            switch line.status {
            case .newerIOS: allowed[line.key] = false; reasons[line.key] = Reason.newerIOS
            case .appleOnly: allowed[line.key] = false; reasons[line.key] = Reason.appleOnly
            case .copy:
                guard let t = Catalog.sampleType(for: line.key) else { continue }
                if t is HKCorrelationType { allowed[line.key] = true; continue }
                if refused.contains(t.identifier) { allowed[line.key] = false; reasons[line.key] = Reason.appleOnly; continue }
                let ok = HealthAccess.canWrite(t)
                allowed[line.key] = ok
                if !ok { reasons[line.key] = Reason.notAllowed }
            }
        }
        if !allowed.values.contains(true) { throw ImportError.nothingAllowed }
    }

    private func canCopy(_ key: String) -> Bool { allowed[key] == true }

    private func reason(_ key: String) -> String {
        reasons[key] ?? (Catalog.sampleType(for: key) == nil ? Reason.newerIOS : Reason.notAllowed)
    }

    // MARK: Run

    func run() async throws {
        try reader.rewind()
        var index = 0
        while true {
            try Task.checkCancellation()
            if index < state.nextFrame {
                guard try reader.skip() else { break }
                index += 1
                continue
            }
            guard let (kind, data) = try reader.next() else { break }
            switch kind {
            case .samples: try await importSamples(try reader.decode(SampleChunk.self, data))
            case .workouts: try await importWorkouts(try reader.decode(WorkoutChunk.self, data))
            case .correlations: try await importCorrelations(try reader.decode(CorrelationChunk.self, data))
            case .heartbeats: try await importHeartbeats(try reader.decode(HeartbeatChunk.self, data))
            case .moods:
                if #available(iOS 18.0, *) { try await importMoods(try reader.decode(MoodChunk.self, data)) }
                else { let c = try reader.decode(MoodChunk.self, data); skip(Catalog.moodKey, c.items.count) }
            case .manifest: break
            }
            index += 1
            state.nextFrame = index
            state.workDone = progress.done
            saveState()
        }
        state.finished = true
        state.workDone = progress.done
        saveState()
        report(progress)
    }

    private func saveState() {
        if let data = try? JSONEncoder().encode(state) { try? data.write(to: stateURL, options: .atomic) }
    }

    private func advance(_ n: Int, _ name: String) {
        progress.done += n
        progress.current = name
        if Date().timeIntervalSince(lastReport) > 0.15 {
            lastReport = Date()
            report(progress)
        }
    }

    private func skip(_ key: String, _ n: Int) {
        guard n > 0 else { return }
        state.results[key, default: TypeResult()].skipped += n
        state.results[key]?.reason = reason(key)
    }

    // MARK: Metadata

    struct MetaPolicy {
        var dropped: Set<String> = []
        var minimal = false
    }

    /// Kept even in minimal mode. HealthKit requires the first two for their types.
    private static let essentialKeys: Set<String> = [
        HKMetadataKeyMenstrualCycleStart, HKMetadataKeyInsulinDeliveryReason, HKMetadataKeyWasUserEntered,
        HKMetadataKeyTimeZone,
    ]

    private func metadata(_ m: Meta?, id: String, source: SourceRecord?, policy: MetaPolicy) -> [String: Any] {
        var out: [String: Any] = [:]
        for (k, v) in m ?? [:] {
            if k.hasPrefix("_") || k == MetaCodec.syncID || k == MetaCodec.syncVersion || k == MetaCodec.originalSource { continue }
            if policy.dropped.contains(k) { continue }
            if policy.minimal && !Self.essentialKeys.contains(k) { continue }
            if let value = MetaCodec.decodeValue(v) { out[k] = value }
        }
        out[MetaCodec.syncID] = id
        out[MetaCodec.syncVersion] = NSNumber(value: 1)
        if let source, source.bundle != Bundle.main.bundleIdentifier { out[MetaCodec.originalSource] = source.name }
        return out
    }

    private func metaKeys(_ m: Meta?) -> [String] {
        (m ?? [:]).keys.filter { !$0.hasPrefix("_") && $0 != MetaCodec.syncID && $0 != MetaCodec.syncVersion }.sorted()
    }

    // MARK: Saving

    private static func describe(_ error: Error) -> String {
        let e = error as NSError
        return e.localizedDescription.isEmpty ? "\(e.domain) \(e.code)" : e.localizedDescription
    }

    /// Saves one batch, returning nil if it went in or the error if it didn't. Throws only for
    /// problems that should stop the whole copy.
    private func attempt(_ objects: [HKObject]) async throws -> Error? {
        do {
            try await Unlock.retrying { try await Health.store.save(objects) }
            return nil
        } catch {
            if Health.isOutOfSpace(error) { throw ImportError.outOfSpace }
            if error is CancellationError { throw error }
            return error
        }
    }

    /// Saves items in one go when possible. When HealthKit refuses a batch, it's split in half
    /// until the record it objects to is found. For that record each metadata key is dropped in
    /// turn, then all but the essentials, and whatever fixes it is remembered for the rest of the
    /// type. Returns, per item, nil if saved or the reason it couldn't be.
    private func save<T>(_ items: [T], key: String, meta: (T) -> Meta?,
                         make: (T, MetaPolicy) -> HKObject?) async throws -> [String?] {
        var outcome = [String?](repeating: nil, count: items.count)
        guard !items.isEmpty else { return outcome }

        func objects(_ r: Range<Int>, _ policy: MetaPolicy) -> [HKObject]? {
            var out: [HKObject] = []
            out.reserveCapacity(r.count)
            for i in r { guard let o = make(items[i], policy) else { return nil }; out.append(o) }
            return out
        }

        func run(_ r: Range<Int>) async throws {
            guard !r.isEmpty else { return }
            if !canCopy(key) { for i in r { outcome[i] = reason(key) }; return }
            let policy = policies[key] ?? MetaPolicy()
            guard let batch = objects(r, policy) else {
                if r.count == 1 {
                    let error = BuildError(reason: lastBuildError ?? "it couldn't be rebuilt")
                    outcome[r.lowerBound] = try await rescue(items[r.lowerBound], key: key, keys: metaKeys(meta(items[r.lowerBound])),
                                                             make: make, error: error)
                    return
                }
                let mid = (r.lowerBound + r.upperBound) / 2
                try await run(r.lowerBound..<mid); try await run(mid..<r.upperBound)
                return
            }
            guard let error = try await attempt(batch) else { return }
            if Health.isAuthorization(error) {
                allowed[key] = false; reasons[key] = Reason.notAllowed
                for i in r { outcome[i] = Reason.notAllowed }
                return
            }
            if r.count > 1 {
                let mid = (r.lowerBound + r.upperBound) / 2
                try await run(r.lowerBound..<mid); try await run(mid..<r.upperBound)
                return
            }
            outcome[r.lowerBound] = try await rescue(items[r.lowerBound], key: key, keys: metaKeys(meta(items[r.lowerBound])),
                                                     make: make, error: error)
        }

        try await run(0..<items.count)
        return outcome
    }

    private func rescue<T>(_ item: T, key: String, keys: [String], make: (T, MetaPolicy) -> HKObject?,
                           error: Error) async throws -> String? {
        let policy = policies[key] ?? MetaPolicy()
        for k in keys.prefix(16) where !policy.dropped.contains(k) {
            var p = policy
            p.dropped.insert(k)
            if let o = make(item, p), try await attempt([o]) == nil { policies[key] = p; return nil }
        }
        if !policy.minimal {
            var p = policy
            p.minimal = true
            if let o = make(item, p), try await attempt([o]) == nil { policies[key] = p; return nil }
        }
        return Self.describe(error)
    }

    private func tally(_ key: String, _ outcomes: [String?]) {
        var r = state.results[key] ?? TypeResult()
        for o in outcomes {
            if let o {
                if o == Reason.notAllowed || o == Reason.appleOnly || o == Reason.newerIOS { r.skipped += 1; r.reason = o }
                else { r.failed += 1; r.note(o) }
            } else {
                r.copied += 1
            }
        }
        state.results[key] = r
    }

    // MARK: Building samples

    private func device(_ i: Int?, _ devices: [DeviceRecord]) -> HKDevice? {
        guard let i, devices.indices.contains(i) else { return nil }
        return devices[i].hkDevice
    }

    private func source(_ i: Int, _ sources: [SourceRecord]) -> SourceRecord? {
        sources.indices.contains(i) ? sources[i] : nil
    }

    private func makeSample(_ type: HKSampleType, _ kind: SampleKind, _ unit: HKUnit?, _ r: SampleRecord,
                            _ devices: [DeviceRecord], _ sources: [SourceRecord], _ policy: MetaPolicy) -> HKSample? {
        let start = Date(ref: r.s), end = Date(ref: max(r.e, r.s))
        let meta = metadata(r.m, id: r.id, source: source(r.sr, sources), policy: policy)
        let dev = device(r.dv, devices)
        do {
            switch kind {
            case .quantity:
                guard let qt = type as? HKQuantityType, let unit, r.v.isFinite else { lastBuildError = "The value is missing."; return nil }
                return try Safely.build { HKQuantitySample(type: qt, quantity: HKQuantity(unit: unit, doubleValue: r.v), start: start, end: end, device: dev, metadata: meta) }
            case .category:
                guard let ct = type as? HKCategoryType, r.v.isFinite else { lastBuildError = "The value is missing."; return nil }
                return try Safely.build { HKCategorySample(type: ct, value: Int(r.v), start: start, end: end, device: dev, metadata: meta) }
            }
        } catch {
            lastBuildError = (error as? BuildError)?.reason ?? Self.describe(error)
            return nil
        }
    }

    /// A quantity series as separate samples, for when it can't be rebuilt as one series.
    private func flattened(_ r: SampleRecord) -> [SampleRecord] {
        guard let ser = r.ser, ser.count >= 6 else {
            var plain = r
            plain.ser = nil
            return [plain]
        }
        var out: [SampleRecord] = []
        out.reserveCapacity(ser.count / 3)
        var n = 0
        var i = 0
        while i + 2 < ser.count {
            out.append(SampleRecord(id: "\(r.id).\(n)", s: ser[i + 1], e: ser[i + 2], v: ser[i], dv: r.dv, sr: r.sr, m: r.m, ser: nil))
            n += 1
            i += 3
        }
        return out
    }

    // MARK: Dedupe

    private struct ContentKey: Hashable {
        let s: Int64, e: Int64, v: Int64
        /// To the millisecond, or for Apple's export, which writes whole seconds and six
        /// significant digits, the same way it does.
        init(_ s: Double, _ e: Double, _ v: Double, coarse: Bool) {
            if coarse {
                self.s = Self.whole(s); self.e = Self.whole(e); self.v = Self.sixDigits(v)
            } else {
                self.s = Self.round(s); self.e = Self.round(e); self.v = Self.round(v)
            }
        }
        init(seconds s: Int64, _ e: Int64, _ v: Double) {
            self.s = s; self.e = e; self.v = Self.sixDigits(v)
        }
        static func round(_ x: Double) -> Int64 {
            guard x.isFinite else { return 0 }
            let y = (x * 1000).rounded()
            return abs(y) < 9e18 ? Int64(y) : 0
        }
        static func whole(_ x: Double) -> Int64 {
            guard x.isFinite, abs(x) < 9e15 else { return 0 }
            return Int64(x.rounded(.down))
        }
        /// The value as the export prints it ("%g"), read back.
        static func sixDigits(_ x: Double) -> Int64 {
            guard x.isFinite else { return 0 }
            let printed = Double(String(format: "%.6g", x)) ?? x
            return Int64(bitPattern: printed.bitPattern)
        }
    }

    /// Apple's export keeps times to the second, so its records are matched more loosely.
    private var coarse: Bool { manifest.origin == AppleExport.origin }

    private func contentKey(_ s: Double, _ e: Double, _ v: Double) -> ContentKey { ContentKey(s, e, v, coarse: coarse) }

    /// What's already on this phone of one type between two start times, as content keys.
    private func existing(_ type: HKSampleType, from lo: Double, to hi: Double, value: (HKSample) -> Double) async throws -> Set<ContentKey> {
        let pred = HKQuery.predicateForSamples(withStart: Date(ref: lo - 0.001), end: Date(ref: hi + (coarse ? 1.001 : 0.001)), options: .strictStartDate)
        let found = try await HealthQuery.samples(type, pred)
        guard coarse else { return Set(found.map { contentKey($0.startDate.ref, $0.endDate.ref, value($0)) }) }
        // The export cuts times to the second; in case a version rounds them instead, both count.
        var keys = Set<ContentKey>()
        for f in found {
            let v = value(f)
            let s = f.startDate.ref, e = f.endDate.ref
            for a in Set([ContentKey.whole(s), Int64(s.rounded())]) {
                for b in Set([ContentKey.whole(e), Int64(e.rounded())]) { keys.insert(ContentKey(seconds: a, b, v)) }
            }
        }
        return keys
    }

    // MARK: Plain samples

    private func importSamples(_ c: SampleChunk) async throws {
        let key = c.type
        let name = Catalog.name(for: key)
        guard canCopy(key), let type = Catalog.sampleType(for: key) else {
            skip(key, c.items.count); advance(c.items.count, name); return
        }
        var unit: HKUnit?
        if c.kind == .quantity {
            guard let u = c.unit.flatMap(Units.unit), let qt = type as? HKQuantityType, qt.is(compatibleWith: u) else {
                state.results[key, default: TypeResult()].failed += c.items.count
                state.results[key]?.note("Unknown unit \(c.unit ?? "?")")
                advance(c.items.count, name)
                return
            }
            unit = u
        }

        let starts = c.items.map(\.s)
        let here = try await existing(type, from: starts.min() ?? 0, to: starts.max() ?? 0) { s in
            if let q = s as? HKQuantitySample, let unit { return q.quantity.doubleValue(for: unit) }
            if let k = s as? HKCategorySample { return Double(k.value) }
            return 0
        }
        var plain: [SampleRecord] = [], series: [SampleRecord] = []
        var already = 0
        for item in c.items {
            if here.contains(contentKey(item.s, item.e, item.v)) { already += 1; continue }
            if (item.ser?.count ?? 0) >= 6 { series.append(item) } else { plain.append(item) }
        }
        state.results[key, default: TypeResult()].already += already
        advance(already, name)

        let outcomes = try await save(plain, key: key, meta: { $0.m }) { item, policy in
            self.makeSample(type, c.kind, unit, item, c.devices, c.sources, policy)
        }
        tally(key, outcomes)
        advance(plain.count, name)

        if let qt = type as? HKQuantityType, let unit {
            for item in series {
                let outcome = try await saveSeries(item, type: qt, unit: unit, key: key, devices: c.devices, sources: c.sources)
                tally(key, [outcome])
                advance(1, name)
            }
        }
    }

    /// Rebuilds a quantity series (a run of readings stored as one sample). If HealthKit won't
    /// take it as a series, the readings go in one by one instead.
    private func saveSeries(_ r: SampleRecord, type: HKQuantityType, unit: HKUnit, key: String,
                            devices: [DeviceRecord], sources: [SourceRecord]) async throws -> String? {
        guard canCopy(key), let ser = r.ser else { return reason(key) }
        let policy = policies[key] ?? MetaPolicy()
        let builder = HKQuantitySeriesSampleBuilder(healthStore: Health.store, quantityType: type,
                                                    startDate: Date(ref: min(r.s, ser[1])), device: device(r.dv, devices))
        do {
            var i = 0
            while i + 2 < ser.count {
                let s = Date(ref: ser[i + 1]), e = Date(ref: max(ser[i + 1], ser[i + 2]))
                try builder.insert(HKQuantity(unit: unit, doubleValue: ser[i]), for: DateInterval(start: s, end: e))
                i += 3
            }
            let meta = metadata(r.m, id: r.id, source: source(r.sr, sources), policy: policy)
            let end = Date(ref: max(r.e, r.s))
            let made: [HKQuantitySample]? = try await Safely.value { builder.finishSeries(metadata: meta, endDate: end, completion: $0) }
            _ = made
            return nil
        } catch {
            builder.discard()
            if Health.isOutOfSpace(error) { throw ImportError.outOfSpace }
            if error is CancellationError { throw error }
            let parts = flattened(r)
            let outcomes = try await save(parts, key: key, meta: { $0.m }) { item, policy in
                self.makeSample(type, .quantity, unit, item, devices, sources, policy)
            }
            return outcomes.compactMap { $0 }.first
        }
    }

    // MARK: Workouts

    private func importWorkouts(_ c: WorkoutChunk) async throws {
        let key = Catalog.workoutKey
        let name = Catalog.name(for: key)
        let weight: (WorkoutRecord) -> Int = { w in 1 + w.samples.reduce(0) { $0 + $1.items.count } + w.routes.count }

        guard canCopy(key) else {
            for w in c.items {
                skip(key, 1)
                for g in w.samples { skip(g.type, g.items.count) }
                skip(Catalog.routeKey, w.routes.count)
                advance(weight(w), name)
            }
            return
        }

        let starts = c.items.map(\.s)
        let found = try await HealthQuery.samples(HKObjectType.workoutType(),
            HKQuery.predicateForSamples(withStart: Date(ref: (starts.min() ?? 0) - 2), end: Date(ref: (starts.max() ?? 0) + 2), options: .strictStartDate))
        let here = found.compactMap { $0 as? HKWorkout }
        let tolerance = coarse ? 1.5 : 1

        for w in c.items {
            try Task.checkCancellation()
            let duplicate = here.contains {
                $0.workoutActivityType.rawValue == w.act && abs($0.startDate.ref - w.s) < tolerance && abs($0.endDate.ref - w.e) < tolerance
            }
            if duplicate {
                state.results[key, default: TypeResult()].already += 1
                for g in w.samples { state.results[g.type, default: TypeResult()].already += g.items.count }
                if !w.routes.isEmpty { state.results[Catalog.routeKey, default: TypeResult()].already += w.routes.count }
            } else {
                try await importWorkout(w, c)
            }
            advance(weight(w), name)
        }
    }

    /// The plain ways drop events and all but essential metadata, for when HealthKit objects.
    private enum WorkoutWay { case builder, builderPlain, legacy, legacyPlain }

    private func importWorkout(_ w: WorkoutRecord, _ c: WorkoutChunk) async throws {
        let key = Catalog.workoutKey
        // Samples recorded during the workout, for the types this phone takes.
        var groups: [(String, HKQuantityType, HKUnit, [SampleRecord])] = []
        for g in w.samples {
            guard canCopy(g.type), let t = Catalog.sampleType(for: g.type) as? HKQuantityType,
                  let u = g.unit.flatMap(Units.unit), t.is(compatibleWith: u) else {
                skip(g.type, g.items.count)
                continue
            }
            groups.append((g.type, t, u, g.items.flatMap(flattened)))
        }
        let hasSamples = groups.contains { !$0.3.isEmpty }
        let hasTotals = w.kcal != nil || w.dist != nil || w.strokes != nil || w.flights != nil
        let ways: [WorkoutWay] = (!hasSamples && hasTotals) ? [.legacy, .legacyPlain, .builder] : [.builder, .builderPlain, .legacyPlain]

        var lastError: Error?
        for way in ways {
            do {
                let workout = try await buildWorkout(w, c, groups: groups, way: way)
                state.results[key, default: TypeResult()].copied += 1
                for g in w.samples where canCopy(g.type) && groups.contains(where: { $0.0 == g.type }) {
                    state.results[g.type, default: TypeResult()].copied += g.items.count
                }
                try await saveRoutes(w, c, workout)
                return
            } catch {
                if Health.isOutOfSpace(error) { throw ImportError.outOfSpace }
                if error is CancellationError { throw error }
                if Health.isAuthorization(error), way == ways.last {
                    lastError = error
                    break
                }
                lastError = error
            }
        }
        let why = lastError.map(Self.describe) ?? "Unknown error"
        state.results[key, default: TypeResult()].failed += 1
        state.results[key]?.note(why)
        for (type, _, _, _) in groups {
            let n = w.samples.first { $0.type == type }?.items.count ?? 0
            state.results[type, default: TypeResult()].failed += n
            state.results[type]?.note("Part of a workout that couldn't be copied: \(why)")
        }
        if !w.routes.isEmpty {
            state.results[Catalog.routeKey, default: TypeResult()].failed += w.routes.count
            state.results[Catalog.routeKey]?.note("Part of a workout that couldn't be copied")
        }
    }

    private func configuration(_ w: WorkoutRecord) -> HKWorkoutConfiguration {
        let config = HKWorkoutConfiguration()
        config.activityType = HKWorkoutActivityType(rawValue: w.act) ?? .other
        let m = w.m ?? [:]
        if let indoor = m[HKMetadataKeyIndoorWorkout]?.i { config.locationType = indoor != 0 ? .indoor : .outdoor }
        if let swim = m[HKMetadataKeySwimmingLocationType]?.i, let t = HKWorkoutSwimmingLocationType(rawValue: Int(swim)) {
            config.swimmingLocationType = t
        }
        if let lap = m[HKMetadataKeyLapLength], let q = lap.q, let u = lap.u.flatMap(Units.unit), u.isCompatible(.meter()) {
            config.lapLength = HKQuantity(unit: u, doubleValue: q)
        }
        if let acts = w.acts, acts.count == 1, let a = acts.first {
            config.activityType = HKWorkoutActivityType(rawValue: a.act) ?? config.activityType
            config.locationType = HKWorkoutSessionLocationType(rawValue: a.loc) ?? config.locationType
            config.swimmingLocationType = HKWorkoutSwimmingLocationType(rawValue: a.swim) ?? config.swimmingLocationType
            if let lap = a.lap { config.lapLength = HKQuantity(unit: .meter(), doubleValue: lap) }
        }
        return config
    }

    private func events(_ w: WorkoutRecord, policy: MetaPolicy) -> [HKWorkoutEvent] {
        w.ev.sorted { $0.s < $1.s }.compactMap { e in
            guard let type = HKWorkoutEventType(rawValue: e.t) else { return nil }
            var meta: [String: Any] = [:]
            if !policy.minimal {
                for (k, v) in e.m ?? [:] where !k.hasPrefix("_") { if let value = MetaCodec.decodeValue(v) { meta[k] = value } }
            }
            let interval = DateInterval(start: Date(ref: e.s), end: Date(ref: max(e.s, e.e)))
            return try? Safely.build { HKWorkoutEvent(type: type, dateInterval: interval, metadata: meta.isEmpty ? nil : meta) }
        }
    }

    private func buildWorkout(_ w: WorkoutRecord, _ c: WorkoutChunk,
                              groups: [(String, HKQuantityType, HKUnit, [SampleRecord])], way: WorkoutWay) async throws -> HKWorkout {
        var policy = policies[Catalog.workoutKey] ?? MetaPolicy()
        let plain = way == .builderPlain || way == .legacyPlain
        if plain { policy.minimal = true }
        let meta = metadata(w.m, id: w.id, source: source(w.sr, c.sources), policy: policy)
        let dev = device(w.dv, c.devices)
        let start = Date(ref: w.s), end = Date(ref: max(w.e, w.s))

        func samples() -> [HKSample] {
            groups.flatMap { key, type, unit, items in
                items.compactMap { makeSample(type, .quantity, unit, $0, c.devices, c.sources, policies[key] ?? MetaPolicy()) }
            }
        }

        if way == .legacy || way == .legacyPlain {
            let evs = plain ? nil : events(w, policy: policy)
            let workout = try Safely.build {
                HCLegacyWorkout(
                    HKWorkoutActivityType(rawValue: w.act) ?? .other, start, end, evs,
                    w.kcal.map { HKQuantity(unit: .kilocalorie(), doubleValue: $0) },
                    w.dist.map { HKQuantity(unit: .meter(), doubleValue: $0) },
                    w.strokes.map { HKQuantity(unit: .count(), doubleValue: $0) },
                    w.flights.map { HKQuantity(unit: .count(), doubleValue: $0) },
                    dev, meta)
            }
            try await Unlock.retrying { try await Health.store.save(workout) }
            let all = samples()
            var i = 0
            while i < all.count {
                let batch = Array(all[i..<min(i + 2000, all.count)])
                try await Unlock.retrying {
                    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                        HCAddSamplesToWorkout(Health.store, batch, workout) { ok, error in
                            if let error { cont.resume(throwing: error) } else { cont.resume() }
                        }
                    }
                }
                i += 2000
            }
            return workout
        }

        let builder = HKWorkoutBuilder(healthStore: Health.store, configuration: configuration(w), device: dev)
        do {
            try await builder.beginCollection(at: start)
            if way == .builder, #available(iOS 16.0, *), let acts = w.acts, acts.count > 1 {
                for a in acts.sorted(by: { $0.s < $1.s }) {
                    let cfg = HKWorkoutConfiguration()
                    cfg.activityType = HKWorkoutActivityType(rawValue: a.act) ?? .other
                    cfg.locationType = HKWorkoutSessionLocationType(rawValue: a.loc) ?? .unknown
                    cfg.swimmingLocationType = HKWorkoutSwimmingLocationType(rawValue: a.swim) ?? .unknown
                    if let lap = a.lap { cfg.lapLength = HKQuantity(unit: .meter(), doubleValue: lap) }
                    var am: [String: Any] = [:]
                    for (k, v) in a.m ?? [:] where !k.hasPrefix("_") && k != MetaCodec.syncID && k != MetaCodec.syncVersion {
                        if let value = MetaCodec.decodeValue(v) { am[k] = value }
                    }
                    let activity = try Safely.build {
                        HKWorkoutActivity(workoutConfiguration: cfg, start: Date(ref: a.s), end: a.e.map { Date(ref: $0) }, metadata: am.isEmpty ? nil : am)
                    }
                    try await Safely.call { builder.addWorkoutActivity(activity, completion: $0) }
                }
            }
            let all = samples()
            var i = 0
            while i < all.count {
                let batch = Array(all[i..<min(i + 2000, all.count)])
                try await Unlock.retrying { try await Safely.call { builder.add(batch, completion: $0) } }
                i += 2000
            }
            if way == .builder {
                let evs = events(w, policy: policy)
                if !evs.isEmpty { try await Safely.call { builder.addWorkoutEvents(evs, completion: $0) } }
            }
            try await Safely.call { builder.addMetadata(meta, completion: $0) }
            try await builder.endCollection(at: end)
            guard let workout = try await Unlock.retrying({ try await builder.finishWorkout() }) else {
                throw ArchiveError.damaged("the workout came back empty")
            }
            return workout
        } catch {
            builder.discardWorkout()
            throw error
        }
    }

    private func saveRoutes(_ w: WorkoutRecord, _ c: WorkoutChunk, _ workout: HKWorkout) async throws {
        let key = Catalog.routeKey
        for r in w.routes {
            guard canCopy(key) else { skip(key, 1); continue }
            var points: [CLLocation] = []
            var i = 0
            while i + 9 < r.pts.count { points.append(CLLocation.unpack(r.pts[i..<(i + 10)])); i += 10 }
            points.sort { $0.timestamp < $1.timestamp }
            guard !points.isEmpty else { state.results[key, default: TypeResult()].failed += 1; continue }

            var lastError: Error?
            for minimal in [false, true] {
                let builder = HKWorkoutRouteBuilder(healthStore: Health.store, device: device(r.dv, c.devices))
                do {
                    var j = 0
                    while j < points.count {
                        let batch = Array(points[j..<min(j + 1000, points.count)])
                        try await Safely.call { builder.insertRouteData(batch, completion: $0) }
                        j += 1000
                    }
                    var p = policies[key] ?? MetaPolicy()
                    p.minimal = minimal
                    let meta = metadata(r.m, id: r.id, source: source(r.sr, c.sources), policy: p)
                    let route: HKWorkoutRoute? = try await Unlock.retrying {
                        try await Safely.value { builder.finishRoute(with: workout, metadata: meta, completion: $0) }
                    }
                    _ = route
                    lastError = nil
                    break
                } catch {
                    builder.discard()
                    if Health.isOutOfSpace(error) { throw ImportError.outOfSpace }
                    if error is CancellationError { throw error }
                    lastError = error
                }
            }
            if let lastError {
                state.results[key, default: TypeResult()].failed += 1
                state.results[key]?.note(Self.describe(lastError))
            } else {
                state.results[key, default: TypeResult()].copied += 1
            }
        }
    }

    // MARK: Correlations

    private func importCorrelations(_ c: CorrelationChunk) async throws {
        var byType: [String: [CorrelationRecord]] = [:]
        for item in c.items { byType[item.type, default: []].append(item) }
        for (key, items) in byType {
            let name = Catalog.name(for: key)
            let weight: (CorrelationRecord) -> Int = { 1 + $0.objs.reduce(0) { $0 + $1.items.count } }
            guard let type = Catalog.sampleType(for: key) as? HKCorrelationType else {
                for item in items { skip(key, 1); item.objs.forEach { skip($0.type, $0.items.count) }; advance(weight(item), name) }
                continue
            }
            let starts = items.map(\.s)
            let here = try await existing(type, from: starts.min() ?? 0, to: starts.max() ?? 0) { _ in 0 }
            var todo: [CorrelationRecord] = []
            for item in items {
                if here.contains(contentKey(item.s, item.e, 0)) {
                    state.results[key, default: TypeResult()].already += 1
                    item.objs.forEach { state.results[$0.type, default: TypeResult()].already += $0.items.count }
                    advance(weight(item), name)
                } else if let blocked = item.objs.first(where: { !canCopy($0.type) }) {
                    skip(key, 1)
                    state.results[key]?.reason = "Needs \(Catalog.name(for: blocked.type)), which can't be copied: \(reason(blocked.type))"
                    item.objs.forEach { skip($0.type, $0.items.count) }
                    advance(weight(item), name)
                } else {
                    todo.append(item)
                }
            }
            let outcomes = try await save(todo, key: key, meta: { $0.m }) { item, policy in
                var objects = Set<HKSample>()
                for g in item.objs {
                    guard let t = Catalog.sampleType(for: g.type), let u = g.unit.flatMap(Units.unit) else { return nil }
                    for r in g.items {
                        guard let s = self.makeSample(t, .quantity, u, r, c.devices, c.sources, policy) else { return nil }
                        objects.insert(s)
                    }
                }
                let meta = self.metadata(item.m, id: item.id, source: self.source(item.sr, c.sources), policy: policy)
                let dev = self.device(item.dv, c.devices)
                do {
                    return try Safely.build {
                        HKCorrelation(type: type, start: Date(ref: item.s), end: Date(ref: max(item.e, item.s)), objects: objects, device: dev, metadata: meta)
                    }
                } catch {
                    self.lastBuildError = (error as? BuildError)?.reason ?? Self.describe(error)
                    return nil
                }
            }
            tally(key, outcomes)
            for (item, outcome) in zip(todo, outcomes) {
                for g in item.objs {
                    if let outcome {
                        state.results[g.type, default: TypeResult()].failed += g.items.count
                        state.results[g.type]?.note("Part of a \(name.lowercased()) reading that couldn't be copied: \(outcome)")
                    } else {
                        state.results[g.type, default: TypeResult()].copied += g.items.count
                    }
                }
                advance(weight(item), name)
            }
        }
    }

    // MARK: Heartbeats

    private func importHeartbeats(_ c: HeartbeatChunk) async throws {
        let key = Catalog.heartbeatKey
        let name = Catalog.name(for: key)
        guard canCopy(key) else { skip(key, c.items.count); advance(c.items.count, name); return }
        let type = HKSeriesType.heartbeat()
        let starts = c.items.map(\.s)
        let here = try await existing(type, from: starts.min() ?? 0, to: starts.max() ?? 0) { _ in 0 }
        for item in c.items {
            try Task.checkCancellation()
            if here.contains(contentKey(item.s, item.e, 0)) {
                state.results[key, default: TypeResult()].already += 1
            } else {
                tally(key, [try await saveHeartbeats(item, c)])
            }
            advance(1, name)
        }
    }

    private func saveHeartbeats(_ item: HeartbeatRecord, _ c: HeartbeatChunk) async throws -> String? {
        guard item.beats.count >= 2 else { return "The series has no beats." }
        var lastError: Error?
        for minimal in [false, true] {
            let builder = HKHeartbeatSeriesBuilder(healthStore: Health.store, device: device(item.dv, c.devices), start: Date(ref: item.s))
            do {
                var i = 0
                while i + 1 < item.beats.count {
                    try await builder.addHeartbeat(at: item.beats[i], precededByGap: item.beats[i + 1] != 0)
                    i += 2
                }
                var p = policies[Catalog.heartbeatKey] ?? MetaPolicy()
                p.minimal = minimal
                let meta = metadata(item.m, id: item.id, source: source(item.sr, c.sources), policy: p)
                try await Safely.call { builder.addMetadata(meta, completion: $0) }
                _ = try await Unlock.retrying { try await builder.finishSeries() }
                return nil
            } catch {
                builder.discard()
                if Health.isOutOfSpace(error) { throw ImportError.outOfSpace }
                if error is CancellationError { throw error }
                lastError = error
            }
        }
        return lastError.map(Self.describe)
    }

    // MARK: State of mind

    @available(iOS 18.0, *)
    private func importMoods(_ c: MoodChunk) async throws {
        let key = Catalog.moodKey
        let name = Catalog.name(for: key)
        guard canCopy(key) else { skip(key, c.items.count); advance(c.items.count, name); return }
        let starts = c.items.map(\.s)
        let here = try await existing(HKObjectType.stateOfMindType(), from: starts.min() ?? 0, to: starts.max() ?? 0) {
            ($0 as? HKStateOfMind)?.valence ?? 0
        }
        let todo = c.items.filter { !here.contains(self.contentKey($0.s, $0.e, $0.valence)) }
        state.results[key, default: TypeResult()].already += c.items.count - todo.count
        let outcomes = try await save(todo, key: key, meta: { $0.m }) { item, policy in
            guard let kind = HKStateOfMind.Kind(rawValue: item.kind) else { self.lastBuildError = "Unknown kind of entry."; return nil }
            let meta = self.metadata(item.m, id: item.id, source: self.source(item.sr, c.sources), policy: policy)
            do {
                return try Safely.build {
                    HKStateOfMind(date: Date(ref: item.s), kind: kind, valence: item.valence,
                                  labels: item.labels.compactMap { HKStateOfMind.Label(rawValue: $0) },
                                  associations: item.assoc.compactMap { HKStateOfMind.Association(rawValue: $0) },
                                  metadata: meta)
                }
            } catch {
                self.lastBuildError = (error as? BuildError)?.reason ?? Self.describe(error)
                return nil
            }
        }
        tally(key, outcomes)
        advance(c.items.count, name)
    }
}

extension HKUnit {
    func isCompatible(_ other: HKUnit) -> Bool {
        HKQuantity(unit: self, doubleValue: 1).is(compatibleWith: other)
    }
}
