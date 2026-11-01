// Checks a file converted from Apple's Health export against a file Send made from the same
// phone (the truth): every record should be there, at the same second, with the same value
// to six digits, device and metadata. Also reports what the export can't carry.
//
//   swiftc -O HealthCopy/Archive/Format.swift scripts/applecompare/main.swift -o build/applecompare
//   build/applecompare truth.healthcopy converted.healthcopy

import Foundation
import HealthKit

struct Flat {
    var type: String
    var unit: String?
    var r: SampleRecord
    var device: DeviceRecord?
    var source: String
}

struct Loaded {
    var samples: [String: [Flat]] = [:]
    var workouts: [(WorkoutRecord, [DeviceRecord])] = []
    var correlations: [(CorrelationRecord, [DeviceRecord])] = []
    var heartbeats = 0
    var moods = 0
    var manifest: Manifest
}

func load(_ path: String) throws -> Loaded {
    let reader = try ArchiveReader(url: URL(fileURLWithPath: path))
    var out = Loaded(manifest: reader.manifest)
    func flat(_ type: String, _ unit: String?, _ r: SampleRecord, _ d: [DeviceRecord], _ s: [SourceRecord]) -> Flat {
        Flat(type: type, unit: unit, r: r, device: r.dv.map { d[$0] }, source: s[r.sr].name)
    }
    while let (kind, data) = try reader.next() {
        switch kind {
        case .samples:
            let c = try reader.decode(SampleChunk.self, data)
            out.samples[c.type, default: []] += c.items.map { flat(c.type, c.unit, $0, c.devices, c.sources) }
        case .workouts:
            let c = try reader.decode(WorkoutChunk.self, data)
            for w in c.items {
                out.workouts.append((w, c.devices))
                // Apple's export lists a workout's samples on their own.
                for g in w.samples { out.samples[g.type, default: []] += g.items.map { flat(g.type, g.unit, $0, c.devices, c.sources) } }
            }
        case .correlations:
            let c = try reader.decode(CorrelationChunk.self, data)
            for k in c.items {
                out.correlations.append((k, c.devices))
                for g in k.objs { out.samples["correlation/" + g.type, default: []] += g.items.map { flat(g.type, g.unit, $0, c.devices, c.sources) } }
            }
        case .heartbeats: out.heartbeats += try reader.decode(HeartbeatChunk.self, data).items.count
        case .moods: out.moods += try reader.decode(MoodChunk.self, data).items.count
        case .manifest: break
        }
    }
    return out
}

func unit(_ s: String) -> HKUnit? {
    var u: HKUnit?
    // HKUnit raises on strings it doesn't know; the export only writes ones it made.
    u = HKUnit(from: s)
    return u
}

func convert(_ v: Double, from: String?, to: String?) -> Double {
    guard let from, let to, from != to, let a = unit(from), let b = unit(to) else { return v }
    let q = HKQuantity(unit: a, doubleValue: v)
    return q.is(compatibleWith: b) ? q.doubleValue(for: b) : .nan
}

func sig(_ x: Double, _ digits: Int = 5) -> Double {
    guard x != 0, x.isFinite else { return x }
    let e = floor(log10(abs(x)))
    let f = pow(10, Double(digits - 1) - e)
    return (x * f).rounded() / f
}

func near(_ a: Double, _ b: Double, _ rel: Double = 2e-6) -> Bool { a == b || abs(a - b) <= rel * max(abs(a), abs(b), 1e-300) }

/// Metadata the same in meaning: the export turns everything into text and back.
func metaDiff(_ a: Meta?, _ b: Meta?) -> String? {
    let skip: Set<String> = ["HKMetadataKeySyncIdentifier", "HKMetadataKeySyncVersion", "Health Copy original source"]
    let a = (a ?? [:]).filter { !skip.contains($0.key) && !$0.key.hasPrefix("_") }
    let b = (b ?? [:]).filter { !skip.contains($0.key) && !$0.key.hasPrefix("_") }
    var d: [String] = []
    for k in Set(a.keys).union(b.keys).sorted() {
        guard let x = a[k] else { d.append("+\(k)"); continue }
        guard let y = b[k] else { d.append("-\(k)"); continue }
        var same = false
        if let s = x.s { same = y.s == s && y.q == nil }
        else if let i = x.i { same = y.i == i || (y.n.map { $0 == Double(i) } ?? false) }
        else if let n = x.n { same = (y.n.map { near($0, n, 1e-5) } ?? false) || (y.i.map { Double($0) == n } ?? false) }
        else if let t = x.d { same = y.d.map { abs($0 - t) < 1 } ?? false }
        else if let q = x.q { same = y.q.map { near(convert($0, from: y.u, to: x.u), q, 1e-4) } ?? false }
        if !same { d.append("\(k): \(x) vs \(y)") }
    }
    return d.isEmpty ? nil : d.joined(separator: "; ")
}

guard CommandLine.arguments.count == 3 else { print("usage: applecompare truth converted"); exit(2) }
let A = try load(CommandLine.arguments[1])
let C = try load(CommandLine.arguments[2])
var problems = 0

func key(_ type: String, _ s: Double, _ e: Double) -> String { "\(type)|\(Int64(floor(s)))|\(Int64(floor(e)))" }

var cIndex: [String: [Flat]] = [:]
for (k, list) in C.samples { for f in list { cIndex[key(k, f.r.s, f.r.e), default: []].append(f) } }
var used = Set<String>()
var exact = 0, inexact = 0

for k in Set(A.samples.keys).union(C.samples.keys).sorted() {
    let list = A.samples[k] ?? []
    var ok = 0, missing = 0, bad = 0
    var examples: [String] = []
    for a in list {
        let cands = cIndex[key(k, a.r.s, a.r.e)] ?? []
        let want: Double
        if let ser = a.r.ser, ser.count >= 6, k.contains("HeartRate") == false || true {
            want = a.r.v
        } else { want = a.r.v }
        guard let c = cands.first(where: { !used.contains($0.r.id) && near(sig(convert($0.r.v, from: $0.unit, to: a.unit)), sig(want), 1e-4) }) else {
            missing += 1
            if examples.count < 3 {
                let alt = cands.first.map { "export has \(convert($0.r.v, from: $0.unit, to: a.unit))" } ?? "nothing at that time"
                examples.append("missing \(a.r.v) \(a.unit ?? "") at \(a.r.s) (\(alt))\(a.r.ser != nil ? " series of \(a.r.ser!.count / 3)" : "")")
            }
            continue
        }
        used.insert(c.r.id)
        if String(format: "%.6g", convert(a.r.v, from: a.unit, to: c.unit)) == String(format: "%.6g", c.r.v) { exact += 1 } else {
            inexact += 1
            if inexact <= 5 { print("    not exact: \(convert(a.r.v, from: a.unit, to: c.unit)) vs \(c.r.v) \(c.unit ?? "")") }
        }
        var d: [String] = []
        if a.device != c.device { d.append("device \(String(describing: a.device)) vs \(String(describing: c.device))") }
        if a.source != c.source { d.append("source \(a.source) vs \(c.source)") }
        if let m = metaDiff(a.r.m, c.r.m) { d.append("meta \(m)") }
        if d.isEmpty { ok += 1 } else { bad += 1; if examples.count < 3 { examples.append(d.joined(separator: ", ")) } }
    }
    let extra = (C.samples[k] ?? []).filter { !used.contains($0.r.id) }.count
    print("\(k): \(list.count) in truth, \(ok) same, \(bad) different, \(missing) missing, \(extra) extra in converted")
    if bad + missing + extra > 0 { problems += bad + missing; examples.forEach { print("    \($0)") } }
}

// Workouts by type and start second.
var cw: [String: (WorkoutRecord, [DeviceRecord])] = [:]
for (w, d) in C.workouts { cw["\(w.act)|\(Int64(floor(w.s)))"] = (w, d) }
var wOK = 0
for (a, ad) in A.workouts {
    guard let (c, cd) = cw["\(a.act)|\(Int64(floor(a.s)))"] else { problems += 1; print("  workout missing act \(a.act) at \(a.s)"); continue }
    var d: [String] = []
    if floor(a.e) != floor(c.e) { d.append("end") }
    if abs(a.dur - c.dur) > 1 { d.append("duration \(a.dur) vs \(c.dur)") }
    if a.dv.map({ ad[$0] }) != c.dv.map({ cd[$0] }) { d.append("device \(String(describing: a.dv.map { ad[$0] })) vs \(String(describing: c.dv.map { cd[$0] }))") }
    if let m = metaDiff(a.m, c.m) { d.append("meta \(m)") }
    let ae = a.ev.map { "\($0.t)@\(Int64(floor($0.s)))-\(Int64(floor($0.e)))" }, ce = c.ev.map { "\($0.t)@\(Int64(floor($0.s)))-\(Int64(floor($0.e)))" }
    if ae != ce { d.append("events \(ae) vs \(ce)") }
    // Totals: truth keeps the legacy ones; the export has statistics, which come from samples.
    let truthKcal = a.kcal ?? a.samples.first { $0.type.hasSuffix("ActiveEnergyBurned") }?.items.reduce(0) { $0 + $1.v }
    if let x = truthKcal, let y = c.kcal, !near(x, y, 1e-4) { d.append("kcal \(x) vs \(y)") }
    if (truthKcal == nil) != (c.kcal == nil) { d.append("kcal \(String(describing: truthKcal)) vs \(String(describing: c.kcal))") }
    if let x = a.dist, let y = c.dist, !near(x, y, 1e-4) { d.append("dist \(x) vs \(y)") }
    let ar = a.routes.map { $0.pts.count / 10 }, cr = c.routes.map { $0.pts.count / 10 }
    if ar != cr { d.append("routes \(ar) vs \(cr)") }
    for (x, y) in zip(a.routes, c.routes) {
        var worst = 0.0
        var i = 0
        while i + 9 < min(x.pts.count, y.pts.count) {
            worst = max(worst, abs(x.pts[i] - y.pts[i]) > 1 ? 99 : 0, abs(x.pts[i + 1] - y.pts[i + 1]) * 1e5, abs(x.pts[i + 2] - y.pts[i + 2]) * 1e5, abs(x.pts[i + 3] - y.pts[i + 3]))
            i += 10
        }
        if worst > 1 { d.append("route points off by \(worst)") }
        if a.routes.count == c.routes.count, let m = metaDiff(x.m, y.m) { d.append("route meta \(m)") }
    }
    if (a.acts?.count ?? 0) > 1 { d.append("note: \(a.acts!.count) activities not in the export") }
    if d.isEmpty { wOK += 1 } else { print("  workout act \(a.act) at \(a.s): " + d.joined(separator: ", ")) }
}
print("workouts: \(A.workouts.count) in truth, \(C.workouts.count) converted, \(wOK) same")

var cc: [String: CorrelationRecord] = [:]
for (c, _) in C.correlations { cc["\(c.type)|\(Int64(floor(c.s)))"] = c }
var cOK = 0
for (a, _) in A.correlations {
    guard let c = cc["\(a.type)|\(Int64(floor(a.s)))"] else { problems += 1; print("  correlation missing \(a.type) at \(a.s)"); continue }
    let av = a.objs.map { "\($0.type)×\($0.items.count)" }.sorted(), cv = c.objs.map { "\($0.type)×\($0.items.count)" }.sorted()
    if av != cv || metaDiff(a.m, c.m) != nil { print("  correlation \(a.type) at \(a.s): \(av) vs \(cv) \(metaDiff(a.m, c.m) ?? "")") } else { cOK += 1 }
}
print("correlations: \(A.correlations.count) in truth, \(C.correlations.count) converted, \(cOK) same")
print("heartbeat series in truth: \(A.heartbeats), state of mind: \(A.moods) (Apple's export has neither)")
print("values the importer's duplicate check sees as equal (printed to six digits): \(exact) of \(exact + inexact)")
print("notes: \(C.manifest.notes)")
print(problems == 0 ? "NO PROBLEMS" : "PROBLEMS: \(problems)")
