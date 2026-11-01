import Foundation

// Converts Apple's Health export on the Mac with the app's own code, for testing:
//   build/appleexport export.zip out.healthcopy
let args = CommandLine.arguments
guard args.count == 3 else { print("usage: appleexport <export.zip|folder|export.xml> <out.healthcopy>"); exit(2) }
let started = Date()
do {
    let files = try AppleExport.Files(URL(fileURLWithPath: args[1]))
    let conv = try AppleExportConverter(files: files, to: URL(fileURLWithPath: args[2])) { _ in }
    let m = try conv.run()
    print(String(format: "converted in %.1fs: %d frames, work %d", Date().timeIntervalSince(started), m.frames, m.work))
    for (k, t) in m.totals.sorted(by: { $0.key < $1.key }) { print("  \(k) \(t.count)") }
    for n in m.notes { print("  note: \(n)") }
} catch {
    print("failed: \(error.localizedDescription)")
    exit(1)
}
