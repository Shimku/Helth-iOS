import HealthKit
import CoreLocation

enum Health {
    static let store = HKHealthStore()

    static func isLocked(_ error: Error) -> Bool {
        let e = error as NSError
        return e.domain == HKErrorDomain && e.code == HKError.Code.errorDatabaseInaccessible.rawValue
    }

    static func isAuthorization(_ error: Error) -> Bool {
        let e = error as NSError
        return e.domain == HKErrorDomain && (e.code == HKError.Code.errorAuthorizationDenied.rawValue
            || e.code == HKError.Code.errorAuthorizationNotDetermined.rawValue)
    }

    static func isOutOfSpace(_ error: Error) -> Bool {
        let e = error as NSError
        if e.domain == NSCocoaErrorDomain && e.code == NSFileWriteOutOfSpaceError { return true }
        if e.domain == NSPOSIXErrorDomain && e.code == Int(ENOSPC) { return true }
        let text = e.localizedDescription.lowercased()
        return text.contains("disk full") || text.contains("not enough space") || text.contains("out of space")
    }
}

/// Health data is encrypted while the phone is locked. When that bites, wait for the unlock and
/// try again, telling the screen it's waiting.
enum Unlock {
    static var onChange: ((Bool) -> Void)?

    static func retrying<T>(_ op: () async throws -> T) async throws -> T {
        var announced = false
        while true {
            do {
                let value = try await op()
                if announced { onChange?(false) }
                return value
            } catch where Health.isLocked(error) {
                if !announced { onChange?(true); announced = true }
                try await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }
}

enum HealthQuery {
    static let byStart = [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]

    static func samples(_ type: HKSampleType, _ predicate: NSPredicate?, limit: Int = HKObjectQueryNoLimit) async throws -> [HKSample] {
        try await Unlock.retrying { try await rawSamples(type, predicate, limit: limit) }
    }

    private static func rawSamples(_ type: HKSampleType, _ predicate: NSPredicate?, limit: Int) async throws -> [HKSample] {
        try await withCheckedThrowingContinuation { cont in
            let q = HKSampleQuery(sampleType: type, predicate: predicate, limit: limit, sortDescriptors: byStart) { _, results, error in
                if let error { cont.resume(throwing: error) } else { cont.resume(returning: results ?? []) }
            }
            Health.store.execute(q)
        }
    }

    /// Walks every sample of a type in start-date order, a page at a time, so even a million
    /// heart rate readings never sit in memory together. Ties on the page boundary are handled
    /// by remembering which UUIDs at that instant were already handed out.
    static func paged(_ type: HKSampleType, _ predicate: NSPredicate? = nil, pageSize: Int,
                      _ body: ([HKSample]) async throws -> Void) async throws {
        var cursor: Date?
        var seenAtCursor = Set<UUID>()
        var limit = pageSize
        while true {
            try Task.checkCancellation()
            var parts: [NSPredicate] = []
            if let predicate { parts.append(predicate) }
            if let cursor { parts.append(HKQuery.predicateForSamples(withStart: cursor, end: nil, options: .strictStartDate)) }
            let pred: NSPredicate? = parts.isEmpty ? nil : NSCompoundPredicate(andPredicateWithSubpredicates: parts)
            let page = try await samples(type, pred, limit: limit)
            let fresh = page.filter { !seenAtCursor.contains($0.uuid) }
            if !fresh.isEmpty { try await body(fresh) }
            if page.count < limit { return }
            let last = page[page.count - 1].startDate
            if fresh.isEmpty || last == cursor {
                // A whole page shares one start time. Widen the page until it gets past it.
                seenAtCursor.formUnion(page.map(\.uuid))
                if fresh.isEmpty { limit *= 2 }
                cursor = last
                continue
            }
            cursor = last
            seenAtCursor = Set(page.lazy.filter { $0.startDate == last }.map(\.uuid))
            limit = pageSize
        }
    }

    /// The individual values of a quantity series, as [value, start, end] triples.
    static func series(_ sample: HKQuantitySample, unit: HKUnit) async throws -> [Double] {
        try await Unlock.retrying { try await rawSeries(sample, unit: unit) }
    }

    private static func rawSeries(_ sample: HKQuantitySample, unit: HKUnit) async throws -> [Double] {
        try await withCheckedThrowingContinuation { cont in
            var out: [Double] = []
            var finished = false
            let pred = HKQuery.predicateForObject(with: sample.uuid)
            let q = HKQuantitySeriesSampleQuery(quantityType: sample.quantityType, predicate: pred) { _, quantity, interval, _, done, error in
                if finished { return }
                if let error { finished = true; cont.resume(throwing: error); return }
                if let quantity, let interval {
                    out.append(quantity.doubleValue(for: unit))
                    out.append(interval.start.ref)
                    out.append(interval.end.ref)
                }
                if done { finished = true; cont.resume(returning: out) }
            }
            Health.store.execute(q)
        }
    }

    static func route(_ route: HKWorkoutRoute) async throws -> [CLLocation] {
        try await Unlock.retrying { try await rawRoute(route) }
    }

    private static func rawRoute(_ route: HKWorkoutRoute) async throws -> [CLLocation] {
        try await withCheckedThrowingContinuation { cont in
            var out: [CLLocation] = []
            var finished = false
            let q = HKWorkoutRouteQuery(route: route) { _, locations, done, error in
                if finished { return }
                if let error { finished = true; cont.resume(throwing: error); return }
                if let locations { out += locations }
                if done { finished = true; cont.resume(returning: out) }
            }
            Health.store.execute(q)
        }
    }

    /// Beat times since the series start, each followed by 1 if a gap came before it, else 0.
    static func heartbeats(_ series: HKHeartbeatSeriesSample) async throws -> [Double] {
        try await Unlock.retrying { try await rawHeartbeats(series) }
    }

    private static func rawHeartbeats(_ series: HKHeartbeatSeriesSample) async throws -> [Double] {
        try await withCheckedThrowingContinuation { cont in
            var out: [Double] = []
            var finished = false
            let q = HKHeartbeatSeriesQuery(heartbeatSeries: series) { _, t, gap, done, error in
                if finished { return }
                if let error { finished = true; cont.resume(throwing: error); return }
                if series.count > 0 {
                    out.append(t)
                    out.append(gap ? 1 : 0)
                }
                if done { finished = true; cont.resume(returning: out) }
            }
            Health.store.execute(q)
        }
    }
}
