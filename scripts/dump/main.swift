import Foundation
// Prints every frame of a .healthcopy file as JSON, for eyeballing small test files.
let r = try ArchiveReader(url: URL(fileURLWithPath: CommandLine.arguments[1]))
while let (kind, data) = try r.next() {
    let obj = try JSONSerialization.jsonObject(with: data)
    let pretty = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
    print("\(kind): \(String(decoding: pretty, as: UTF8.self))")
}
print("manifest: \(r.manifest)")
