import HealthKit
import CoreLocation

struct ExportProgress {
    var step = 0
    var steps = 1
    var current = ""
    var records = 0
}

/// Reads everything this app may read from Health and writes it to a .healthcopy file.
///
/// Workouts go first, then correlations, because the samples inside them also show up when
/// their type is read on its own. Their UUIDs are remembered and skipped later, so nothing is
/// stored twice and each sample keeps its place in its workout or blood pressure reading.
final class Exporter {
    private let writer: ArchiveWriter
    private let url: URL
    private let report: (ExportProgress) -> Void
    private var progress = ExportProgress()
    private var totals: [String: TypeTotal] = [:]
    private var work = 0
    private var notes: [String] = []
    private var inside = Set<UUID>()
    private var lastReport = Date.distantPast
    /// Single records that couldn't be read in full, by what went wrong. Reported in the notes
    /// instead of failing the whole type.
    private var partial: [String: Int] = [:]

    static let pageSize = 2000
    static let workoutsPerFrame = 25
    static let samplesPerWorkoutFrame = 20000

    private let device: String
    private let system: String

    /// `device` and `system` describe this phone for the other one, e.g. "iPhone", "iOS 26.1".
    init(url: URL, device: String, system: String, report: @escaping (ExportProgress) -> Void) throws {
        self.url = url
        self.device = device
        self.system = system
        self.writer = try ArchiveWriter(url: url)
        self.report = report
    }

    func run() async throws -> Manifest {
        do {
            let quantities = Catalog.quantityTypes
            let categories = Catalog.categoryTypes
            var steps = 3 + quantities.count + categories.count
            if #available(iOS 18.0, *) { steps += 1 }
            progress.steps = steps

            try await step(Catalog.name(for: Catalog.workoutKey)) { try await exportWorkouts() }
            try await step("Blood Pressure and Food") { try await exportCorrelations() }
            try await step(Catalog.name(for: Catalog.heartbeatKey)) { try await exportHeartbeats() }
            if #available(iOS 18.0, *) {
                try await step(Catalog.name(for: Catalog.moodKey)) { try await exportMoods() }
            }
            for (type, _) in quantities {
                try await step(Catalog.name(for: type.identifier)) { try await exportSamples(type, kind: .quantity) }
            }
            for type in categories {
                try await step(Catalog.name(for: type.identifier)) { try await exportSamples(type, kind: .category) }
            }

            for (what, n) in partial.sorted(by: { $0.key < $1.key }) { notes.append("\(what): \(n)") }
            let info = Bundle.main.infoDictionary
            let manifest = Manifest(
                format: ArchiveFormat.version, id: UUID().uuidString, created: Date().ref,
                device: device, system: system,
                app: "\(info?["CFBundleShortVersionString"] ?? "?") (\(info?["CFBundleVersion"] ?? "?"))",
                frames: writer.frames, work: work, totals: totals, notes: notes)
            try writer.finish(manifest)
            return manifest
        } catch {
            writer.abandon()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    /// Runs one step; a type that fails to read is noted and skipped rather than ending the export.
    private func step(_ name: String, _ body: () async throws -> Void) async throws {
        progress.current = name
        report(progress)
        do {
            try await body()
        } catch is CancellationError {
            throw CancellationError()
        } catch let e as ArchiveError {
            throw e
        } catch {
            if (error as NSError).domain == NSCocoaErrorDomain || Health.isOutOfSpace(error) { throw error }
            notes.append("\(name): \(error.localizedDescription)")
        }
        progress.step += 1
        report(progress)
    }

    private func counted(_ n: Int) {
        progress.records += n
        if Date().timeIntervalSince(lastReport) > 0.15 {
            lastReport = Date()
            report(progress)
        }
    }

    // MARK: Plain samples

    private func record(_ sample: HKSample, kind: SampleKind, unit: HKUnit?, tables: Tables) async throws -> SampleRecord {
        var value = 0.0
        var series: [Double]?
        if kind == .quantity, let q = sample as? HKQuantitySample, let unit {
            value = q.quantity.doubleValue(for: unit)
            if q.count > 1 {
                do { series = try await HealthQuery.series(q, unit: unit) }
                catch is CancellationError { throw CancellationError() }
                catch { partial["\(Catalog.name(for: sample.sampleType.identifier)): readings kept as one total", default: 0] += 1 }
            }
        } else if let c = sample as? HKCategorySample {
            value = Double(c.value)
        }
        totals[sample.sampleType.identifier, default: TypeTotal(count: 0)].add(start: sample.startDate.ref, end: sample.endDate.ref)
        return SampleRecord(id: sample.uuid.uuidString, s: sample.startDate.ref, e: sample.endDate.ref, v: value,
                            dv: tables.device(sample.device), sr: tables.source(sample.sourceRevision),
                            m: MetaCodec.encode(sample.metadata), ser: series)
    }

    private func exportSamples(_ type: HKSampleType, kind: SampleKind) async throws {
        var unit: HKUnit?
        var unitString: String?
        if kind == .quantity, let qt = type as? HKQuantityType {
            guard let (u, s) = Units.unit(for: qt) else {
                notes.append("\(Catalog.name(for: type.identifier)): no unit to store it in")
                return
            }
            unit = u; unitString = s
        }
        try await HealthQuery.paged(type, pageSize: Self.pageSize) { page in
            let tables = Tables()
            var items: [SampleRecord] = []
            items.reserveCapacity(page.count)
            for sample in page where !inside.contains(sample.uuid) {
                items.append(try await record(sample, kind: kind, unit: unit, tables: tables))
            }
            guard !items.isEmpty else { return }
            try writer.append(.samples, SampleChunk(type: type.identifier, kind: kind, unit: unitString,
                                                    devices: tables.devices, sources: tables.sources, items: items))
            work += items.count
            counted(items.count)
        }
    }

    // MARK: Workouts

    /// Quantity types worth asking a workout about, beyond the ones it has statistics for.
    private static let workoutBase: [String] = [
        "HeartRate", "ActiveEnergyBurned", "BasalEnergyBurned", "DistanceWalkingRunning", "DistanceCycling",
        "DistanceSwimming", "DistanceWheelchair", "DistanceDownhillSnowSports", "SwimmingStrokeCount", "StepCount",
        "FlightsClimbed", "PushCount", "RunningPower", "RunningSpeed", "RunningStrideLength", "RunningVerticalOscillation",
        "RunningGroundContactTime", "CyclingPower", "CyclingCadence", "CyclingSpeed", "PhysicalEffort",
        "HeartRateVariabilitySDNN", "RespiratoryRate", "OxygenSaturation", "UnderwaterDepth", "WaterTemperature",
        "DistanceRowing", "DistancePaddleSports", "DistanceCrossCountrySkiing", "DistanceSkatingSports",
    ].map { Catalog.quantityPrefix + $0 }

    private func exportWorkouts() async throws {
        var tables = Tables()
        var items: [WorkoutRecord] = []
        var samplesInFrame = 0

        func flush() throws {
            guard !items.isEmpty else { return }
            try writer.append(.workouts, WorkoutChunk(devices: tables.devices, sources: tables.sources, items: items))
            items = []; samplesInFrame = 0; tables = Tables()
        }

        try await HealthQuery.paged(HKObjectType.workoutType(), pageSize: 50) { page in
            for case let workout as HKWorkout in page {
                let rec = try await workoutRecord(workout, tables: tables)
                let n = rec.samples.reduce(0) { $0 + $1.items.count }
                items.append(rec)
                samplesInFrame += n
                work += 1 + n + rec.routes.count
                counted(1 + n)
                if items.count >= Self.workoutsPerFrame || samplesInFrame >= Self.samplesPerWorkoutFrame { try flush() }
            }
        }
        try flush()
    }

    private func workoutRecord(_ workout: HKWorkout, tables: Tables) async throws -> WorkoutRecord {
        totals[Catalog.workoutKey, default: TypeTotal(count: 0)].add(start: workout.startDate.ref, end: workout.endDate.ref)

        var typeIDs = Set(Self.workoutBase)
        var activities: [ActivityRecord]?
        if #available(iOS 16.0, *) {
            workout.allStatistics.keys.forEach { typeIDs.insert($0.identifier) }
            let acts = workout.workoutActivities
            if !acts.isEmpty {
                activities = acts.map { a in
                    a.allStatistics.keys.forEach { typeIDs.insert($0.identifier) }
                    let c = a.workoutConfiguration
                    return ActivityRecord(act: c.activityType.rawValue, loc: c.locationType.rawValue,
                                          swim: c.swimmingLocationType.rawValue, lap: c.lapLength?.doubleValue(for: .meter()),
                                          s: a.startDate.ref, e: a.endDate?.ref, m: MetaCodec.encode(a.metadata))
                }
            }
        }

        let inWorkout = HKQuery.predicateForObjects(from: workout)
        var groups: [SampleGroup] = []
        for id in typeIDs.sorted() {
            guard let type = HKObjectType.quantityType(forIdentifier: HKQuantityTypeIdentifier(rawValue: id)),
                  let (unit, unitString) = Units.unit(for: type) else { continue }
            let found: [HKSample]
            do { found = try await HealthQuery.samples(type, inWorkout) }
            catch is CancellationError { throw CancellationError() }
            catch { partial["Workouts: \(Catalog.name(for: id)) during a workout couldn't be read", default: 0] += 1; continue }
            guard !found.isEmpty else { continue }
            var recs: [SampleRecord] = []
            for s in found {
                inside.insert(s.uuid)
                recs.append(try await record(s, kind: .quantity, unit: unit, tables: tables))
            }
            groups.append(SampleGroup(type: id, kind: .quantity, unit: unitString, items: recs))
        }

        var routes: [RouteRecord] = []
        for case let route as HKWorkoutRoute in (try? await HealthQuery.samples(HKSeriesType.workoutRoute(), inWorkout)) ?? [] {
            let points: [CLLocation]
            do { points = try await HealthQuery.route(route) }
            catch is CancellationError { throw CancellationError() }
            catch { partial["Workout routes that couldn't be read", default: 0] += 1; continue }
            totals[Catalog.routeKey, default: TypeTotal(count: 0)].add(start: route.startDate.ref, end: route.endDate.ref)
            routes.append(RouteRecord(id: route.uuid.uuidString, s: route.startDate.ref, e: route.endDate.ref,
                                      dv: tables.device(route.device), sr: tables.source(route.sourceRevision),
                                      m: MetaCodec.encode(route.metadata), pts: points.flatMap(\.packed)))
        }

        let events = (workout.workoutEvents ?? []).map {
            EventRecord(t: $0.type.rawValue, s: $0.dateInterval.start.ref, e: $0.dateInterval.end.ref, m: MetaCodec.encode($0.metadata))
        }

        return WorkoutRecord(
            id: workout.uuid.uuidString, s: workout.startDate.ref, e: workout.endDate.ref, dur: workout.duration,
            act: workout.workoutActivityType.rawValue, dv: tables.device(workout.device), sr: tables.source(workout.sourceRevision),
            m: MetaCodec.encode(workout.metadata), ev: events, acts: activities,
            kcal: legacyTotal(workout, "totalEnergyBurned", .kilocalorie()),
            dist: legacyTotal(workout, "totalDistance", .meter()),
            strokes: legacyTotal(workout, "totalSwimmingStrokeCount", .count()),
            flights: legacyTotal(workout, "totalFlightsClimbed", .count()),
            samples: groups, routes: routes)
    }

    /// The totals a workout was saved with. Older apps set these without adding samples, so
    /// they're the only record of the distance or energy. Read by name because Swift flags
    /// the properties as deprecated.
    private func legacyTotal(_ w: HKWorkout, _ key: String, _ unit: HKUnit) -> Double? {
        guard let q = w.value(forKey: key) as? HKQuantity, q.is(compatibleWith: unit) else { return nil }
        return q.doubleValue(for: unit)
    }

    // MARK: Correlations, heartbeats, state of mind

    private func exportCorrelations() async throws {
        for id in Catalog.correlationTypes {
            guard let type = HKObjectType.correlationType(forIdentifier: HKCorrelationTypeIdentifier(rawValue: id)) else { continue }
            try await HealthQuery.paged(type, pageSize: 500) { page in
                let tables = Tables()
                var items: [CorrelationRecord] = []
                for case let c as HKCorrelation in page {
                    var byType: [String: [HKSample]] = [:]
                    for o in c.objects { byType[o.sampleType.identifier, default: []].append(o) }
                    var groups: [SampleGroup] = []
                    for (tid, objs) in byType.sorted(by: { $0.key < $1.key }) {
                        guard let qt = HKObjectType.quantityType(forIdentifier: HKQuantityTypeIdentifier(rawValue: tid)),
                              let (unit, unitString) = Units.unit(for: qt) else { continue }
                        var recs: [SampleRecord] = []
                        for o in objs.sorted(by: { $0.startDate < $1.startDate }) {
                            inside.insert(o.uuid)
                            recs.append(try await record(o, kind: .quantity, unit: unit, tables: tables))
                        }
                        groups.append(SampleGroup(type: tid, kind: .quantity, unit: unitString, items: recs))
                    }
                    totals[id, default: TypeTotal(count: 0)].add(start: c.startDate.ref, end: c.endDate.ref)
                    items.append(CorrelationRecord(id: c.uuid.uuidString, type: id, s: c.startDate.ref, e: c.endDate.ref,
                                                   dv: tables.device(c.device), sr: tables.source(c.sourceRevision),
                                                   m: MetaCodec.encode(c.metadata), objs: groups))
                }
                guard !items.isEmpty else { return }
                try writer.append(.correlations, CorrelationChunk(devices: tables.devices, sources: tables.sources, items: items))
                let n = items.reduce(0) { $0 + 1 + $1.objs.reduce(0) { $0 + $1.items.count } }
                work += n
                counted(n)
            }
        }
    }

    private func exportHeartbeats() async throws {
        try await HealthQuery.paged(HKSeriesType.heartbeat(), pageSize: 200) { page in
            let tables = Tables()
            var items: [HeartbeatRecord] = []
            for case let series as HKHeartbeatSeriesSample in page {
                let beats: [Double]
                do { beats = try await HealthQuery.heartbeats(series) }
                catch is CancellationError { throw CancellationError() }
                catch { partial["Heartbeat series that couldn't be read", default: 0] += 1; continue }
                totals[Catalog.heartbeatKey, default: TypeTotal(count: 0)].add(start: series.startDate.ref, end: series.endDate.ref)
                items.append(HeartbeatRecord(id: series.uuid.uuidString, s: series.startDate.ref, e: series.endDate.ref,
                                             dv: tables.device(series.device), sr: tables.source(series.sourceRevision),
                                             m: MetaCodec.encode(series.metadata), beats: beats))
            }
            guard !items.isEmpty else { return }
            try writer.append(.heartbeats, HeartbeatChunk(devices: tables.devices, sources: tables.sources, items: items))
            work += items.count
            counted(items.count)
        }
    }

    @available(iOS 18.0, *)
    private func exportMoods() async throws {
        try await HealthQuery.paged(HKObjectType.stateOfMindType(), pageSize: 1000) { page in
            let tables = Tables()
            var items: [MoodRecord] = []
            for case let mood as HKStateOfMind in page {
                totals[Catalog.moodKey, default: TypeTotal(count: 0)].add(start: mood.startDate.ref, end: mood.endDate.ref)
                items.append(MoodRecord(id: mood.uuid.uuidString, s: mood.startDate.ref, e: mood.endDate.ref,
                                        dv: tables.device(mood.device), sr: tables.source(mood.sourceRevision),
                                        m: MetaCodec.encode(mood.metadata), kind: mood.kind.rawValue, valence: mood.valence,
                                        labels: mood.labels.map(\.rawValue), assoc: mood.associations.map(\.rawValue)))
            }
            guard !items.isEmpty else { return }
            try writer.append(.moods, MoodChunk(devices: tables.devices, sources: tables.sources, items: items))
            work += items.count
            counted(items.count)
        }
    }
}
