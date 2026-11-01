// Compares two .healthcopy files: what the source phone sent (A) and a fresh export of the
// target phone after the import (B). Every record in A must be in B with the same type,
// times, value, device and metadata; B finds A's records through the sync identifier the
// importer sets (or, for data that was on the target already, by content).
//
//   swiftc -O HealthCopy/Archive/Format.swift scripts/compare/main.swift -o build/compare
//   build/compare source.healthcopy target-dump.healthcopy

import Foundation

let syncKey = "HKMetadataKeySyncIdentifier"
let ignoredKeys: Set<String> = [syncKey, "HKMetadataKeySyncVersion", "Health Copy original source"]

struct Flat {
    var type: String
    var r: SampleRecord
    var device: DeviceRecord?
    var source: String
}

struct Loaded {
    var samples: [String: [Flat]] = [:]
    var workouts: [(WorkoutRecord, [DeviceRecord])] = []
    var correlations: [(CorrelationRecord, [DeviceRecord])] = []
    var heartbeats: [(HeartbeatRecord, [DeviceRecord])] = []
    var moods: [MoodRecord] = []
    var manifest: Manifest
}

func load(_ path: String) throws -> Loaded {
    let reader = try ArchiveReader(url: URL(fileURLWithPath: path))
    var out = Loaded(manifest: reader.manifest)
    func flat(_ type: String, _ r: SampleRecord, _ d: [DeviceRecord], _ s: [SourceRecord]) -> Flat {
        Flat(type: type, r: r, device: r.dv.map { d[$0] }, source: s[r.sr].name)
    }
    while let (kind, data) = try reader.next() {
        switch kind {
        case .samples:
            let c = try reader.decode(SampleChunk.self, data)
            out.samples[c.type, default: []] += c.items.map { flat(c.type, $0, c.devices, c.sources) }
        case .workouts:
            let c = try reader.decode(WorkoutChunk.self, data)
            for w in c.items {
                out.workouts.append((w, c.devices))
                for g in w.samples { out.samples["workout/" + g.type, default: []] += g.items.map { flat(g.type, $0, c.devices, c.sources) } }
            }
        case .correlations:
            let c = try reader.decode(CorrelationChunk.self, data)
            for k in c.items {
                out.correlations.append((k, c.devices))
                for g in k.objs { out.samples["correlation/" + g.type, default: []] += g.items.map { flat(g.type, $0, c.devices, c.sources) } }
            }
        case .heartbeats:
            let c = try reader.decode(HeartbeatChunk.self, data)
            out.heartbeats += c.items.map { ($0, c.devices) }
        case .moods:
            out.moods += try reader.decode(MoodChunk.self, data).items
        case .manifest: break
        }
    }
    return out
}

func close(_ a: Double, _ b: Double, _ tol: Double = 1e-9) -> Bool {
    a == b || abs(a - b) <= tol * max(1, abs(a), abs(b))
}

func metaDiff(_ a: Meta?, _ b: Meta?) -> String? {
    let a = (a ?? [:]).filter { !ignoredKeys.contains($0.key) && !$0.key.hasPrefix("_") }
    let b = (b ?? [:]).filter { !ignoredKeys.contains($0.key) && !$0.key.hasPrefix("_") }
    var diffs: [String] = []
    for k in Set(a.keys).union(b.keys).sorted() {
        guard let x = a[k] else { diffs.append("+\(k)"); continue }
        guard let y = b[k] else { diffs.append("-\(k)"); continue }
        if x == y { continue }
        if let p = x.q, let q = y.q, x.u == y.u, close(p, q, 1e-9) { continue }
        if let p = x.n, let q = y.n, close(p, q) { continue }
        if let p = x.d, let q = y.d, close(p, q, 1e-12) { continue }
        diffs.append("\(k): \(x) vs \(y)")
    }
    return diffs.isEmpty ? nil : diffs.joined(separator: "; ")
}

func sampleDiff(_ a: Flat, _ b: Flat) -> String? {
    var d: [String] = []
    if !close(a.r.s, b.r.s, 1e-12) { d.append("start \(a.r.s) vs \(b.r.s)") }
    if !close(a.r.e, b.r.e, 1e-12) { d.append("end \(a.r.e) vs \(b.r.e)") }
    if !close(a.r.v, b.r.v) { d.append("value \(a.r.v) vs \(b.r.v)") }
    if a.device != b.device { d.append("device \(String(describing: a.device)) vs \(String(describing: b.device))") }
    if let m = metaDiff(a.r.m, b.r.m) { d.append("meta \(m)") }
    let sa = a.r.ser ?? [], sb = b.r.ser ?? []
    if sa.count != sb.count { d.append("series \(sa.count / 3) vs \(sb.count / 3) values") }
    else if zip(sa, sb).contains(where: { !close($0, $1, 1e-9) }) { d.append("series values differ") }
    return d.isEmpty ? nil : d.joined(separator: ", ")
}

guard CommandLine.arguments.count == 3 else { print("usage: compare A B"); exit(2) }
let A = try load(CommandLine.arguments[1])
let B = try load(CommandLine.arguments[2])

func syncID(_ m: Meta?) -> String? { m?[syncKey]?.s }

var problems = 0
func report(_ line: String) { print(line) }

// Plain samples, plus those inside workouts and correlations.
var bByID: [String: [Flat]] = [:]
var bByContent: [String: [Flat]] = [:]
func contentKey(_ type: String, _ r: SampleRecord) -> String { "\(type)|\(Int64((r.s * 1000).rounded()))|\(Int64((r.e * 1000).rounded()))|\(Int64((r.v * 1000).rounded()))" }
for (_, list) in B.samples {
    for f in list {
        if let id = syncID(f.r.m) { bByID[id, default: []].append(f) }
        bByContent[contentKey(f.type, f.r), default: []].append(f)
    }
}

for key in A.samples.keys.sorted() {
    let list = A.samples[key]!
    var matched = 0, byContent = 0, missing = 0, flattened = 0, bad = 0
    var examples: [String] = []
    for a in list {
        if let b = bByID[a.r.id]?.first(where: { $0.type == a.type }) {
            matched += 1
            if let d = sampleDiff(a, b) { bad += 1; if examples.count < 3 { examples.append(d) } }
        } else if let ser = a.r.ser, ser.count >= 6, bByID["\(a.r.id).0"] != nil {
            // Stored as separate readings: check each one.
            var ok = true
            for n in 0..<(ser.count / 3) {
                guard let b = bByID["\(a.r.id).\(n)"]?.first,
                      close(b.r.v, ser[3 * n]), close(b.r.s, ser[3 * n + 1], 1e-12), close(b.r.e, ser[3 * n + 2], 1e-12) else { ok = false; break }
            }
            flattened += 1
            if !ok { bad += 1; if examples.count < 3 { examples.append("flattened series differs \(a.r.id)") } }
        } else if let b = bByContent[contentKey(a.type, a.r)]?.first {
            byContent += 1
            if a.device != b.device, examples.count < 3 { examples.append("content match with other device") }
        } else {
            missing += 1
            if examples.count < 3 { examples.append("missing \(a.r.id) at \(a.r.s)") }
        }
    }
    let line = "\(key): \(list.count) sent, \(matched) copied\(flattened > 0 ? " (+\(flattened) as separate readings)" : ""), \(byContent) already there, \(missing) missing, \(bad) different"
    report(line)
    if bad > 0 || missing > 0 { problems += bad; examples.forEach { report("    \($0)") } }
}

// Workouts.
var bWorkouts: [String: (WorkoutRecord, [DeviceRecord])] = [:]
for (w, d) in B.workouts { if let id = syncID(w.m) { bWorkouts[id] = (w, d) } }
var wMatched = 0, wMissing = 0
for (a, ad) in A.workouts {
    guard let (b, bd) = bWorkouts[a.id] else {
        wMissing += 1
        report("  workout missing: act \(a.act) at \(a.s)")
        continue
    }
    wMatched += 1
    var d: [String] = []
    if a.act != b.act { d.append("activity \(a.act) vs \(b.act)") }
    if !close(a.s, b.s, 1e-12) || !close(a.e, b.e, 1e-12) { d.append("times") }
    if abs(a.dur - b.dur) > 1 { d.append("duration \(a.dur) vs \(b.dur)") }
    if a.dv.map({ ad[$0] }) != b.dv.map({ bd[$0] }) { d.append("device") }
    if let m = metaDiff(a.m, b.m) { d.append("meta \(m)") }
    let ae = a.ev.map { "\($0.t)@\($0.s)-\($0.e)" }, be = b.ev.map { "\($0.t)@\($0.s)-\($0.e)" }
    if ae != be { d.append("events \(ae.count) vs \(be.count)") }
    if (a.acts?.count ?? 0) > 1 || (b.acts?.count ?? 0) > 1 {
        let aa = (a.acts ?? []).map { "\($0.act)/\($0.loc)/\($0.swim)@\($0.s)" }, ba = (b.acts ?? []).map { "\($0.act)/\($0.loc)/\($0.swim)@\($0.s)" }
        if aa != ba { d.append("activities \(aa) vs \(ba)") }
    }
    for (name, x, y) in [("kcal", a.kcal, b.kcal), ("dist", a.dist, b.dist), ("strokes", a.strokes, b.strokes), ("flights", a.flights, b.flights)] {
        if (x == nil) != (y == nil) || (x != nil && !close(x!, y!, 1e-6)) { d.append("\(name) \(String(describing: x)) vs \(String(describing: y))") }
    }
    let ac = Dictionary(a.samples.map { ($0.type, $0.items.count) }, uniquingKeysWith: +)
    let bc = Dictionary(b.samples.map { ($0.type, $0.items.count) }, uniquingKeysWith: +)
    if ac != bc { d.append("samples \(ac) vs \(bc)") }
    let ar = a.routes.map { $0.pts.count / 10 }, br = b.routes.map { $0.pts.count / 10 }
    if ar != br { d.append("routes \(ar) vs \(br)") }
    else {
        for (x, y) in zip(a.routes, b.routes) where zip(x.pts, y.pts).contains(where: { !close($0, $1, 1e-9) }) { d.append("route points differ") }
    }
    if !d.isEmpty { problems += 1; report("  workout act \(a.act) at \(a.s): " + d.joined(separator: ", ")) }
}
report("workouts: \(A.workouts.count) sent, \(wMatched) copied, \(wMissing) missing")

// Correlations.
var bCorr: [String: CorrelationRecord] = [:]
for (c, _) in B.correlations { if let id = syncID(c.m) { bCorr[id] = c } }
var cMatched = 0, cMissing = 0
for (a, _) in A.correlations {
    guard let b = bCorr[a.id] else { cMissing += 1; continue }
    cMatched += 1
    let av = a.objs.flatMap { g in g.items.map { "\(g.type)=\($0.v)" } }.sorted()
    let bv = b.objs.flatMap { g in g.items.map { "\(g.type)=\($0.v)" } }.sorted()
    if av != bv || !close(a.s, b.s, 1e-12) || metaDiff(a.m, b.m) != nil { problems += 1; report("  correlation differs \(a.id): \(av) vs \(bv) \(metaDiff(a.m, b.m) ?? "")") }
}
report("correlations: \(A.correlations.count) sent, \(cMatched) copied, \(cMissing) missing")

// Heartbeat series.
var bBeats: [String: HeartbeatRecord] = [:]
for (h, _) in B.heartbeats { if let id = syncID(h.m) { bBeats[id] = h } }
var hMatched = 0, hMissing = 0
for (a, _) in A.heartbeats {
    guard let b = bBeats[a.id] else { hMissing += 1; continue }
    hMatched += 1
    if a.beats.count != b.beats.count || zip(a.beats, b.beats).contains(where: { abs($0 - $1) > 1e-6 }) || !close(a.s, b.s, 1e-12) {
        problems += 1
        report("  heartbeat series differs \(a.id): \(a.beats.count / 2) vs \(b.beats.count / 2) beats, max diff \(zip(a.beats, b.beats).map { abs($0 - $1) }.max() ?? 0)")
    }
}
report("heartbeat series: \(A.heartbeats.count) sent, \(hMatched) copied, \(hMissing) missing")

// State of mind.
var bMoods: [String: MoodRecord] = [:]
for m in B.moods { if let id = syncID(m.m) { bMoods[id] = m } }
var mMatched = 0, mMissing = 0
for a in A.moods {
    guard let b = bMoods[a.id] else { mMissing += 1; continue }
    mMatched += 1
    if a.kind != b.kind || !close(a.valence, b.valence) || a.labels.sorted() != b.labels.sorted() || a.assoc.sorted() != b.assoc.sorted() || !close(a.s, b.s, 1e-12) {
        problems += 1
        report("  mood differs \(a.id)")
    }
}
report("state of mind: \(A.moods.count) sent, \(mMatched) copied, \(mMissing) missing")

print(problems == 0 ? "RESULT: no differences" : "RESULT: \(problems) differences")
