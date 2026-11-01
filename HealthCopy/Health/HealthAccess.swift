import HealthKit

/// Asks for Health access without ever tripping HealthKit's exceptions. Asking to write a type
/// Apple reserves for itself, or one this iOS doesn't know, raises instead of returning an error.
enum HealthAccess {
    enum AccessError: LocalizedError {
        case refused(String)
        var errorDescription: String? {
            switch self {
            case .refused(let why): return "Health wouldn't open the permission screen: \(why)"
            }
        }
    }

    /// Types to read on the phone the data comes from.
    static var exportReadTypes: Set<HKObjectType> {
        var types = Set<HKObjectType>()
        Catalog.quantityTypes.forEach { types.insert($0.0) }
        Catalog.categoryTypes.forEach { types.insert($0) }
        types.insert(HKObjectType.workoutType())
        types.insert(HKSeriesType.workoutRoute())
        types.insert(HKSeriesType.heartbeat())
        if #available(iOS 18.0, *) { types.insert(HKObjectType.stateOfMindType()) }
        return types
    }

    /// Splits the types an archive holds into those this phone lets an app write and those it
    /// doesn't, without asking yet.
    static func writable(_ types: Set<HKSampleType>) -> (ok: Set<HKSampleType>, refused: Set<HKSampleType>) {
        var ok = Set<HKSampleType>(), refused = Set<HKSampleType>()
        for t in types {
            if raisesWhenShared(t) { refused.insert(t) } else { ok.insert(t) }
        }
        return (ok, refused)
    }

    /// Whether HealthKit rejects a share request for this type outright. Checking the request
    /// status runs the same validation as a real request but shows no screen. On iOS 27 this
    /// refuses 26 types, among them Exercise, Stand and Move minutes, the heart notifications,
    /// walking steadiness and asymmetry, wrist temperature and the cycle deviation alerts.
    private static func raisesWhenShared(_ type: HKSampleType) -> Bool {
        HCCatch {
            Health.store.getRequestStatusForAuthorization(toShare: Set([type]).union(companions(of: type)), read: []) { _, _ in }
        } != nil
    }

    /// Types HealthKit insists are requested together with this one.
    static func companions(of type: HKSampleType) -> Set<HKSampleType> {
        if type == HKSeriesType.workoutRoute() { return [HKObjectType.workoutType()] }
        if type == HKSeriesType.heartbeat(), let hrv = HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN) { return [hrv] }
        return []
    }

    /// Shows Health's permission screen. Returns the identifiers HealthKit turned down, if any
    /// slipped past `writable`.
    @discardableResult
    static func request(share: Set<HKSampleType>, read: Set<HKObjectType>) async throws -> Set<String> {
        var share = share, read = read
        var refused = Set<String>()
        while true {
            let (reason, error) = await ask(share: share, read: read)
            if let reason {
                let named = tokens(reason)
                let dropShare = share.filter { named.contains($0.identifier) }
                let dropRead = read.filter { named.contains($0.identifier) }
                if dropShare.isEmpty && dropRead.isEmpty { throw AccessError.refused(reason) }
                share.subtract(dropShare)
                read.subtract(dropRead)
                refused.formUnion(dropShare.map(\.identifier))
                continue
            }
            if let error { throw error }
            return refused
        }
    }

    /// iOS 27 lets people share only the last 30 days with an app. Returns the cut-off if they
    /// chose that for any of these types, so nothing older can be read.
    static func limitedSince(_ types: Set<HKObjectType>) async -> Date? {
        if #available(iOS 27.0, *) {
            guard let dates = try? await Health.store.earliestAuthorizedSampleDate(for: types) else { return nil }
            return dates.values.max()
        }
        return nil
    }

    /// Whether the user said no to this app adding data of this type.
    static func canWrite(_ type: HKObjectType) -> Bool {
        Health.store.authorizationStatus(for: type) == .sharingAuthorized
    }

    private static func ask(share: Set<HKSampleType>, read: Set<HKObjectType>) async -> (String?, Error?) {
        await withCheckedContinuation { cont in
            let once = Once()
            let reason = HCCatch {
                Health.store.requestAuthorization(toShare: share, read: read) { _, error in
                    once.run { cont.resume(returning: (nil, error)) }
                }
            }
            if let reason { once.run { cont.resume(returning: (reason, nil)) } }
        }
    }

    private static func tokens(_ text: String) -> Set<String> {
        Set(text.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty })
    }
}

/// Runs its block at most once, from whichever thread gets there first.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ block: () -> Void) {
        lock.lock()
        let first = !done
        done = true
        lock.unlock()
        if first { block() }
    }
}
