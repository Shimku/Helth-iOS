import HealthKit

/// HealthKit checks a record when it's created, and when it doesn't like it (a period day
/// without its cycle-start flag, a metadata value of the wrong kind) it raises an Objective-C
/// exception instead of returning an error. Uncaught, that ends the app, so every object the
/// importer builds and every builder call that takes metadata goes through here.
struct BuildError: LocalizedError {
    let reason: String
    var errorDescription: String? { "Health refused this record: \(reason)" }
}

enum Safely {
    static func build<T>(_ make: () -> T) throws -> T {
        var out: T?
        if let reason = HCCatch({ out = make() }) { throw BuildError(reason: reason) }
        return out!
    }

    /// Calls a completion-handler HealthKit method, turning a raised exception into an error.
    static func call(_ start: (@escaping @Sendable (Bool, Error?) -> Void) -> Void) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let once = Once()
            let reason = HCCatch {
                start { _, error in once.run { if let error { cont.resume(throwing: error) } else { cont.resume() } } }
            }
            if let reason { once.run { cont.resume(throwing: BuildError(reason: reason)) } }
        }
    }

    static func value<V>(_ start: (@escaping @Sendable (V?, Error?) -> Void) -> Void) async throws -> V? {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<V?, Error>) in
            let once = Once()
            let reason = HCCatch {
                start { value, error in once.run { if let error { cont.resume(throwing: error) } else { cont.resume(returning: value) } } }
            }
            if let reason { once.run { cont.resume(throwing: BuildError(reason: reason)) } }
        }
    }
}
