import Foundation

// The .healthcopy file. Foundation only, so the Mac-side checker in scripts/ can read it too.
//
// Layout: "HCPY" + UInt32 format, then frames, then the manifest frame, then a footer of
// UInt64 manifest offset + "HCPYEND!". A frame is UInt8 kind + UInt32 raw size + UInt32 stored
// size + the JSON payload, LZFSE-compressed. Integers are little-endian. Dates are seconds since
// 2001-01-01 (timeIntervalSinceReferenceDate), which round-trips exactly through JSON.

enum ArchiveFormat {
    static let magic = Data("HCPY".utf8)
    static let footerMagic = Data("HCPYEND!".utf8)
    static let version: UInt32 = 1
    static let fileExtension = "healthcopy"
    static let typeIdentifier = "com.shimku.healthcopy.archive"
}

enum FrameKind: UInt8 {
    case samples = 1
    case workouts = 2
    case correlations = 3
    case heartbeats = 4
    case moods = 5
    case manifest = 255
}

enum SampleKind: String, Codable {
    case quantity, category
}

/// A metadata value. HealthKit allows strings, numbers, dates and quantities.
struct MetaValue: Codable, Equatable {
    var s: String?
    var i: Int64?
    var n: Double?
    var d: Double?
    var q: Double?
    var u: String?
}

typealias Meta = [String: MetaValue]

struct DeviceRecord: Codable, Hashable {
    var name: String?
    var manufacturer: String?
    var model: String?
    var hardware: String?
    var firmware: String?
    var software: String?
    var localID: String?
    var udi: String?
}

struct SourceRecord: Codable, Hashable {
    var name: String
    var bundle: String
    var version: String?
    var product: String?
    var os: String?
}

/// One quantity or category sample. For a quantity `v` is in the chunk's unit, for a category
/// it is the raw category value. `ser` holds a quantity series as [value, start, end] triples.
struct SampleRecord: Codable {
    var id: String
    var s: Double
    var e: Double
    var v: Double
    var dv: Int?
    var sr: Int
    var m: Meta?
    var ser: [Double]?
}

struct SampleChunk: Codable {
    var type: String
    var kind: SampleKind
    var unit: String?
    var devices: [DeviceRecord]
    var sources: [SourceRecord]
    var items: [SampleRecord]
}

/// Samples inside a workout or correlation. Device and source indexes point into the
/// enclosing chunk's tables.
struct SampleGroup: Codable {
    var type: String
    var kind: SampleKind
    var unit: String?
    var items: [SampleRecord]
}

struct EventRecord: Codable {
    var t: Int
    var s: Double
    var e: Double
    var m: Meta?
}

struct ActivityRecord: Codable {
    var act: UInt
    var loc: Int
    var swim: Int
    var lap: Double?
    var s: Double
    var e: Double?
    var m: Meta?
}

/// Route points, ten numbers each: time, latitude, longitude, altitude, horizontal accuracy,
/// vertical accuracy, course, course accuracy, speed, speed accuracy.
struct RouteRecord: Codable {
    var id: String
    var s: Double
    var e: Double
    var dv: Int?
    var sr: Int
    var m: Meta?
    var pts: [Double]
}

struct WorkoutRecord: Codable {
    var id: String
    var s: Double
    var e: Double
    var dur: Double
    var act: UInt
    var dv: Int?
    var sr: Int
    var m: Meta?
    var ev: [EventRecord]
    var acts: [ActivityRecord]?
    /// Totals as the source phone reports them: kcal, metres, strokes, flights.
    var kcal: Double?
    var dist: Double?
    var strokes: Double?
    var flights: Double?
    var samples: [SampleGroup]
    var routes: [RouteRecord]
}

struct WorkoutChunk: Codable {
    var devices: [DeviceRecord]
    var sources: [SourceRecord]
    var items: [WorkoutRecord]
}

struct CorrelationRecord: Codable {
    var id: String
    var type: String
    var s: Double
    var e: Double
    var dv: Int?
    var sr: Int
    var m: Meta?
    var objs: [SampleGroup]
}

struct CorrelationChunk: Codable {
    var devices: [DeviceRecord]
    var sources: [SourceRecord]
    var items: [CorrelationRecord]
}

/// Beat times in seconds since the series start, paired with 1 when a gap precedes the beat.
struct HeartbeatRecord: Codable {
    var id: String
    var s: Double
    var e: Double
    var dv: Int?
    var sr: Int
    var m: Meta?
    var beats: [Double]
}

struct HeartbeatChunk: Codable {
    var devices: [DeviceRecord]
    var sources: [SourceRecord]
    var items: [HeartbeatRecord]
}

struct MoodRecord: Codable {
    var id: String
    var s: Double
    var e: Double
    var dv: Int?
    var sr: Int
    var m: Meta?
    var kind: Int
    var valence: Double
    var labels: [Int]
    var assoc: [Int]
}

struct MoodChunk: Codable {
    var devices: [DeviceRecord]
    var sources: [SourceRecord]
    var items: [MoodRecord]
}

/// Totals per type. Keys are HealthKit identifiers, plus "workout", "heartbeat", "mood" and
/// "route". Samples stored inside workouts and correlations count towards their own type.
struct TypeTotal: Codable {
    var count: Int
    var first: Double?
    var last: Double?

    mutating func add(start: Double, end: Double) {
        count += 1
        first = min(first ?? start, start)
        last = max(last ?? end, end)
    }
}

struct Manifest: Codable {
    var format: UInt32
    var id: String
    var created: Double
    var device: String
    var system: String
    var app: String
    var frames: Int
    /// Units of work for the import progress bar: one per record, workouts count their samples.
    var work: Int
    var totals: [String: TypeTotal]
    var notes: [String]
    /// Where the data came from when it wasn't Send on another iPhone: AppleExport.origin.
    var origin: String? = nil
}

enum ArchiveError: LocalizedError {
    case notAnArchive
    case newerFormat
    case damaged(String)

    var errorDescription: String? {
        switch self {
        case .notAnArchive: return "This isn't a Hëlth file or a Health export. Choose the file Hëlth's Send made, or export.zip from the Health app."
        case .newerFormat: return "This file was made by a newer version of Hëlth. Update the app on this iPhone and try again."
        case .damaged(let why): return "The file is damaged (\(why)). Make a new one on the other iPhone and send it again."
        }
    }
}

private func makeEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
    return encoder
}

private func makeDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
    return decoder
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }

    func readLE<T: FixedWidthInteger>(_: T.Type, at offset: Int) -> T {
        var v: T = 0
        _ = Swift.withUnsafeMutableBytes(of: &v) { copyBytes(to: $0, from: (startIndex + offset)..<(startIndex + offset + MemoryLayout<T>.size)) }
        return T(littleEndian: v)
    }
}

final class ArchiveWriter {
    private let handle: FileHandle
    private let encoder = makeEncoder()
    private(set) var offset: UInt64 = 0
    private(set) var frames = 0

    init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        var head = ArchiveFormat.magic
        head.appendLE(ArchiveFormat.version)
        try write(head)
    }

    private func write(_ data: Data) throws {
        try handle.write(contentsOf: data)
        offset += UInt64(data.count)
    }

    func append<T: Encodable>(_ kind: FrameKind, _ payload: T) throws {
        let raw = try encoder.encode(payload)
        let stored = try (raw as NSData).compressed(using: .lzfse) as Data
        var head = Data()
        head.append(kind.rawValue)
        head.appendLE(UInt32(raw.count))
        head.appendLE(UInt32(stored.count))
        try write(head)
        try write(stored)
        if kind != .manifest { frames += 1 }
    }

    func finish(_ manifest: Manifest) throws {
        let at = offset
        try append(.manifest, manifest)
        var foot = Data()
        foot.appendLE(at)
        foot.append(ArchiveFormat.footerMagic)
        try write(foot)
        try handle.synchronize()
        try handle.close()
    }

    func abandon() {
        try? handle.close()
    }
}

final class ArchiveReader {
    private let handle: FileHandle
    private let decoder = makeDecoder()
    private let dataEnd: UInt64
    private(set) var manifest: Manifest

    init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
        let size = try handle.seekToEnd()
        guard size >= 8 + 16 else { throw ArchiveError.notAnArchive }
        try handle.seek(toOffset: 0)
        let head = try handle.read(upToCount: 8) ?? Data()
        guard head.count == 8, head.prefix(4) == ArchiveFormat.magic else { throw ArchiveError.notAnArchive }
        guard head.readLE(UInt32.self, at: 4) <= ArchiveFormat.version else { throw ArchiveError.newerFormat }
        try handle.seek(toOffset: size - 16)
        let foot = try handle.read(upToCount: 16) ?? Data()
        guard foot.count == 16, foot.suffix(8) == ArchiveFormat.footerMagic else {
            throw ArchiveError.damaged("it was cut off before the end, probably while sending")
        }
        let manifestAt = foot.readLE(UInt64.self, at: 0)
        dataEnd = manifestAt
        manifest = Manifest(format: 0, id: "", created: 0, device: "", system: "", app: "", frames: 0, work: 0, totals: [:], notes: [])
        try handle.seek(toOffset: manifestAt)
        guard let (kind, payload) = try readFrame(), kind == .manifest else { throw ArchiveError.damaged("no table of contents") }
        manifest = try decoder.decode(Manifest.self, from: payload)
        try handle.seek(toOffset: 8)
    }

    deinit { try? handle.close() }

    private func readFrame() throws -> (FrameKind, Data)? {
        guard let head = try handle.read(upToCount: 9), head.count == 9 else { return nil }
        guard let kind = FrameKind(rawValue: head[head.startIndex]) else { throw ArchiveError.damaged("unknown section") }
        let rawSize = Int(head.readLE(UInt32.self, at: 1))
        let storedSize = Int(head.readLE(UInt32.self, at: 5))
        guard let stored = try handle.read(upToCount: storedSize), stored.count == storedSize else {
            throw ArchiveError.damaged("a section is incomplete")
        }
        let raw = try (stored as NSData).decompressed(using: .lzfse) as Data
        guard raw.count == rawSize else { throw ArchiveError.damaged("a section doesn't unpack") }
        return (kind, raw)
    }

    /// Back to the first frame.
    func rewind() throws {
        try handle.seek(toOffset: 8)
    }

    /// Next data frame, or nil at the manifest. Frames are numbered from 0 in file order.
    func next() throws -> (FrameKind, Data)? {
        guard try handle.offset() < dataEnd else { return nil }
        return try readFrame()
    }

    /// Skips the next frame without unpacking it.
    func skip() throws -> Bool {
        guard try handle.offset() < dataEnd, let head = try handle.read(upToCount: 9), head.count == 9 else { return false }
        let storedSize = UInt64(head.readLE(UInt32.self, at: 5))
        try handle.seek(toOffset: try handle.offset() + storedSize)
        return true
    }

    func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        try decoder.decode(type, from: data)
    }
}
