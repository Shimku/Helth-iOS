import HealthKit
import CoreLocation

/// Parses HealthKit unit strings once and keeps them. HKUnit raises on strings it doesn't know.
enum Units {
    private static let lock = NSLock()
    private static var cache: [String: HKUnit] = [:]
    private static var bad: Set<String> = []

    static func unit(_ string: String) -> HKUnit? {
        lock.lock(); defer { lock.unlock() }
        if let u = cache[string] { return u }
        if bad.contains(string) { return nil }
        var parsed: HKUnit?
        if string == "appleEffortScore" {
            if #available(iOS 18.0, *) { parsed = .appleEffortScore() }
        } else {
            _ = HCCatch { parsed = HKUnit(from: string) }
        }
        if let parsed { cache[string] = parsed } else { bad.insert(string) }
        return parsed
    }

    /// The unit sample values of this type are stored in.
    static func unit(for type: HKQuantityType) -> (HKUnit, String)? {
        var candidates: [String] = []
        if let u = Catalog.unitString(for: type.identifier) { candidates.append(u) }
        candidates += metadataUnits
        for s in candidates {
            if let u = unit(s), type.is(compatibleWith: u) { return (u, s) }
        }
        return nil
    }

    /// One unit per dimension HealthKit uses, tried in order for quantities found in metadata.
    static let metadataUnits = [
        "count", "m", "s", "kcal", "kg", "L", "degC", "mmHg", "count/min", "m/s", "W", "dBASPL", "dBHL",
        "kcal/(kg*hr)", "ml/(kg*min)", "mg/dL", "L/min", "S", "IU", "lx", "Pa", "deg", "appleEffortScore",
        "mmol<180.15588000005408>/L",
    ]
}

enum MetaCodec {
    static let syncID = HKMetadataKeySyncIdentifier
    static let syncVersion = HKMetadataKeySyncVersion
    /// Custom key recording which app or device first wrote the sample.
    static let originalSource = "Health Copy original source"

    static func encode(_ metadata: [String: Any]?) -> Meta? {
        guard let metadata, !metadata.isEmpty else { return nil }
        var out = Meta()
        for (key, value) in metadata {
            if let v = encodeValue(value) { out[key] = v }
        }
        return out.isEmpty ? nil : out
    }

    static func encodeValue(_ value: Any) -> MetaValue? {
        switch value {
        case let s as String:
            return MetaValue(s: s)
        case let d as Date:
            return MetaValue(d: d.timeIntervalSinceReferenceDate)
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return MetaValue(i: n.boolValue ? 1 : 0) }
            if CFNumberIsFloatType(n) { return MetaValue(n: n.doubleValue) }
            return MetaValue(i: n.int64Value)
        case let q as HKQuantity:
            for s in Units.metadataUnits {
                if let u = Units.unit(s), q.is(compatibleWith: u) { return MetaValue(q: q.doubleValue(for: u), u: s) }
            }
            return nil
        default:
            return nil
        }
    }

    /// A value from Send has one field set. One from Apple's export can have a quantity and the
    /// text it came from, which is used if the unit turns out not to be one HealthKit knows.
    static func decodeValue(_ v: MetaValue) -> Any? {
        if let q = v.q, let us = v.u, let u = Units.unit(us) { return HKQuantity(unit: u, doubleValue: q) }
        if let i = v.i { return NSNumber(value: i) }
        if let n = v.n { return NSNumber(value: n) }
        if let d = v.d { return Date(timeIntervalSinceReferenceDate: d) }
        if let s = v.s { return s }
        return nil
    }
}

extension DeviceRecord {
    init?(_ device: HKDevice?) {
        guard let d = device else { return nil }
        self.init(name: d.name, manufacturer: d.manufacturer, model: d.model, hardware: d.hardwareVersion,
                  firmware: d.firmwareVersion, software: d.softwareVersion, localID: d.localIdentifier,
                  udi: d.udiDeviceIdentifier)
    }

    var hkDevice: HKDevice {
        HKDevice(name: name, manufacturer: manufacturer, model: model, hardwareVersion: hardware,
                 firmwareVersion: firmware, softwareVersion: software, localIdentifier: localID,
                 udiDeviceIdentifier: udi)
    }
}

extension SourceRecord {
    init(_ revision: HKSourceRevision) {
        let os = revision.operatingSystemVersion
        self.init(name: revision.source.name, bundle: revision.source.bundleIdentifier, version: revision.version,
                  product: revision.productType, os: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")
    }
}

/// Device and source tables for one frame, so each record stores small indexes.
final class Tables {
    private(set) var devices: [DeviceRecord] = []
    private(set) var sources: [SourceRecord] = []
    private var deviceIndex: [DeviceRecord: Int] = [:]
    private var sourceIndex: [SourceRecord: Int] = [:]

    func device(_ d: HKDevice?) -> Int? {
        guard let rec = DeviceRecord(d) else { return nil }
        if let i = deviceIndex[rec] { return i }
        devices.append(rec)
        deviceIndex[rec] = devices.count - 1
        return devices.count - 1
    }

    func source(_ r: HKSourceRevision) -> Int {
        let rec = SourceRecord(r)
        if let i = sourceIndex[rec] { return i }
        sources.append(rec)
        sourceIndex[rec] = sources.count - 1
        return sources.count - 1
    }

    var isEmpty: Bool { devices.isEmpty && sources.isEmpty }

    func reset() {
        devices = []; sources = []; deviceIndex = [:]; sourceIndex = [:]
    }
}

extension Date {
    var ref: Double { timeIntervalSinceReferenceDate }
    init(ref: Double) { self.init(timeIntervalSinceReferenceDate: ref) }
}

extension CLLocation {
    /// Ten numbers, in the order RouteRecord documents.
    var packed: [Double] {
        [timestamp.ref, coordinate.latitude, coordinate.longitude, altitude, horizontalAccuracy,
         verticalAccuracy, course, courseAccuracy, speed, speedAccuracy]
    }

    static func unpack(_ p: ArraySlice<Double>) -> CLLocation {
        let i = p.startIndex
        return CLLocation(coordinate: CLLocationCoordinate2D(latitude: p[i + 1], longitude: p[i + 2]),
                          altitude: p[i + 3], horizontalAccuracy: p[i + 4], verticalAccuracy: p[i + 5],
                          course: p[i + 6], courseAccuracy: p[i + 7], speed: p[i + 8], speedAccuracy: p[i + 9],
                          timestamp: Date(ref: p[i]))
    }
}
