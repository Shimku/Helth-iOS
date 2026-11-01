// Writes a small .healthcopy file with the cases the simulator can't produce itself: data
// from other sources, types only Apple may write, a type newer than any iOS, odd metadata,
// and a record HealthKit must refuse (a period day without its required cycle-start flag).
//   swiftc HealthCopy/Archive/Format.swift scripts/synthetic/main.swift -o build/synthetic
//   build/synthetic build/synthetic.healthcopy
import Foundation

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let w = try ArchiveWriter(url: out)
let base = 810_000_000.0 // October 2026
let watch = DeviceRecord(name: "Apple Watch", manufacturer: "Apple Inc.", model: "Watch", hardware: "Watch7,3", software: "11.0")
let her = SourceRecord(name: "Her Apple Watch", bundle: "com.apple.health.5F1A2B3C", version: "11.0", product: "Watch7,3", os: "11.0.1")
var totals: [String: TypeTotal] = [:]
var work = 0

func chunk(_ type: String, _ kind: SampleKind, _ unit: String?, _ items: [SampleRecord]) throws {
    try w.append(.samples, SampleChunk(type: type, kind: kind, unit: unit, devices: [watch], sources: [her], items: items))
    for i in items { totals[type, default: TypeTotal(count: 0)].add(start: i.s, end: i.e) }
    work += items.count
}
func rec(_ n: Int, _ v: Double, _ m: Meta? = nil, len: Double = 60) -> SampleRecord {
    SampleRecord(id: UUID().uuidString, s: base + Double(n) * 3600, e: base + Double(n) * 3600 + len, v: v, dv: 0, sr: 0, m: m, ser: nil)
}

try chunk("HKQuantityTypeIdentifierAppleExerciseTime", .quantity, "min", (0..<5).map { rec($0, 1) })
try chunk("HKCategoryTypeIdentifierAppleStandHour", .category, nil, (0..<4).map { rec($0, 0, len: 3600) })
try chunk("HKQuantityTypeIdentifierSomethingFromIOS40", .quantity, "count", (0..<3).map { rec($0, 7) })
try chunk("HKQuantityTypeIdentifierStepCount", .quantity, "count", (0..<6).map { n in
    rec(n, 100 + Double(n), n == 0 ? ["_HKPrivateSomething": MetaValue(s: "x"), "HKMetadataKeyNotARealKey": MetaValue(s: "odd"),
                                       "HKTimeZone": MetaValue(s: "Europe/Helsinki")] : nil)
})
try chunk("HKCategoryTypeIdentifierMenstrualFlow", .category, nil, [
    rec(0, 2, ["HKMenstrualCycleStart": MetaValue(i: 1)], len: 86400),
    rec(30, 2, nil, len: 86400),
])
try w.finish(Manifest(format: ArchiveFormat.version, id: UUID().uuidString, created: base + 200_000, device: "iPhone",
                      system: "iOS 27.0", app: "1.0 (1)", frames: w.frames, work: work, totals: totals, notes: []))
print("wrote \(work) records")
