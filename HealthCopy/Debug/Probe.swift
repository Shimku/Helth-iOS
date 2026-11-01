#if DEBUG
import HealthKit

/// Launch with -probe to measure what this iOS allows. Writes Documents/probe.json.
enum Probe {
    static func run() async {
        var out: [String: Any] = [:]
        var all: [HKSampleType] = Catalog.quantityTypes.map(\.0) + Catalog.categoryTypes
        all += [HKObjectType.workoutType(), HKSeriesType.workoutRoute(), HKSeriesType.heartbeat()]
        if #available(iOS 18.0, *) { all.append(HKObjectType.stateOfMindType()) }
        for id in Catalog.correlationTypes { if let t = HKObjectType.correlationType(forIdentifier: .init(rawValue: id)) { all.append(t) } }

        var statusRaises: [String: String] = [:]
        for t in all {
            if let r = HCCatch({ Health.store.getRequestStatusForAuthorization(toShare: [t], read: []) { _, _ in } }) {
                statusRaises[t.identifier] = r
            }
        }
        out["statusRaises"] = statusRaises

        var readRaises: [String: String] = [:]
        for t in all {
            if let r = HCCatch({ Health.store.getRequestStatusForAuthorization(toShare: [], read: [t]) { _, _ in } }) {
                readRaises[t.identifier] = r
            }
        }
        out["readRaises"] = readRaises

        var units: [String: String] = [:]
        for (t, u) in Catalog.quantityTypes {
            if let (_, s) = Units.unit(for: t) { if s != u { units[t.identifier] = "fallback \(s) for \(u)" } } else { units[t.identifier] = "NONE for \(u)" }
        }
        for s in Units.metadataUnits where Units.unit(s) == nil { units["meta " + s] = "unparsed" }
        out["units"] = units

        var ids: [String] = []
        for (suffix, _) in Catalog.quantities where HKObjectType.quantityType(forIdentifier: .init(rawValue: Catalog.quantityPrefix + suffix)) == nil { ids.append(suffix) }
        for suffix in Catalog.categories where HKObjectType.categoryType(forIdentifier: .init(rawValue: Catalog.categoryPrefix + suffix)) == nil { ids.append(suffix) }
        out["unresolved"] = ids
        out["identifiers"] = [HKObjectType.workoutType().identifier, HKSeriesType.workoutRoute().identifier, HKSeriesType.heartbeat().identifier]

        write(out, "probe.json")
    }

    static func write(_ out: [String: Any], _ name: String) {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(name)
        if let data = try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: url) }
    }

    /// What HealthKit does with a second save carrying the same sync identifier and version,
    /// alone, in a batch with a new sample, and in a workout builder.
    static func syncIdentifiers() async throws {
        let type = HKObjectType.quantityType(forIdentifier: .bodyTemperature)!
        try await HealthAccess.request(share: [type, HKObjectType.workoutType()], read: [type, HKObjectType.workoutType()])
        let id = "probe-\(UUID().uuidString)"
        let t = Date(timeIntervalSinceNow: -3600)
        func sample(_ v: Double, _ sid: String, _ version: Int = 1) -> HKQuantitySample {
            HKQuantitySample(type: type, quantity: HKQuantity(unit: .degreeCelsius(), doubleValue: v), start: t, end: t,
                             metadata: [HKMetadataKeySyncIdentifier: sid, HKMetadataKeySyncVersion: NSNumber(value: version)])
        }
        func count(_ sid: String) async throws -> Int {
            try await HealthQuery.samples(type, HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeySyncIdentifier, allowedValues: [sid])).count
        }
        var out: [String: Any] = [:]
        try await Health.store.save(sample(36.6, id))
        do { try await Health.store.save(sample(36.6, id)); out["sameAgain"] = "ok" } catch { out["sameAgain"] = "\(error)" }
        out["countAfterSame"] = try await count(id)
        let other = "probe-\(UUID().uuidString)"
        do { try await Health.store.save([sample(36.7, id), sample(36.8, other)]); out["batchWithDup"] = "ok" } catch { out["batchWithDup"] = "\(error)" }
        out["countDupAfterBatch"] = try await count(id)
        out["countNewAfterBatch"] = try await count(other)
        do { try await Health.store.save(sample(37.0, id, 2)); out["higherVersion"] = "ok" } catch { out["higherVersion"] = "\(error)" }
        out["countAfterHigher"] = try await count(id)
        out["valueAfterHigher"] = (try await HealthQuery.samples(type, HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeySyncIdentifier, allowedValues: [id])).first as? HKQuantitySample)?.quantity.doubleValue(for: .degreeCelsius()) ?? -1
        try await Health.store.deleteObjects(of: type, predicate: HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeySyncIdentifier, allowedValues: [id, other]))
        write(out, "syncprobe.json")
    }
}
#endif
