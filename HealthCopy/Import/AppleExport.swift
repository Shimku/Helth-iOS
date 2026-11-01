import Foundation
import CryptoKit
import Compression

/// Reads the export Apple's Health app makes (profile picture > Export All Health Data) and
/// turns it into a .healthcopy file, so it goes into Health the same way as a file from Send.
///
/// The export is export.zip holding apple_health_export/export.xml, plus a GPX file per workout
/// route. What it can't say, compared with a file from Send: times are to the second, values to
/// six significant digits, records have no UUIDs, workouts don't list their samples, and there are
/// no heartbeat series or State of Mind entries. Samples inside a blood pressure or food entry are
/// listed twice, on their own and inside the entry, so the loose copies are left out.
/// Foundation only, so scripts/appleexport can run the same code on the Mac.
enum AppleExport {
    /// Manifest.origin of a file made from Apple's export. The importer matches its records
    /// against what's already in Health to the second instead of the millisecond.
    static let origin = "apple-export"

    // The same as Catalog's, repeated so this file needs only Foundation.
    static let quantityPrefix = "HKQuantityTypeIdentifier"
    static let categoryPrefix = "HKCategoryTypeIdentifier"

    enum Failure: LocalizedError {
        case notAnExport
        case incomplete
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .notAnExport: return "This zip isn't a Health export. Choose export.zip, the file the Health app makes with Export All Health Data."
            case .incomplete: return "The export file is incomplete, probably because it was still being sent. AirDrop export.zip again and choose the new copy."
            case .unreadable(let why): return "The Health export couldn't be read (\(why))."
            }
        }
    }

    /// Whether this looks like Apple's export: export.zip, the unzipped folder, or export.xml.
    static func detect(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return false }
        if isDir.boolValue { return Files(folder: url) != nil }
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        let head = (try? h.read(upToCount: 4096)) ?? Data()
        if head.starts(with: [0x50, 0x4B, 0x03, 0x04]) || head.starts(with: [0x50, 0x4B, 0x05, 0x06]) { return true }
        return String(decoding: head, as: UTF8.self).contains("<!DOCTYPE HealthData") || String(decoding: head, as: UTF8.self).contains("<HealthData")
    }

    /// The export's files, wherever they are.
    final class Files {
        private let zip: ZipFile?
        private let zipRoot: String
        private let folder: URL?
        private let mainURL: URL?
        private let mainEntry: ZipFile.Entry?
        /// Unpacked size of export.xml, for progress.
        let mainSize: Int64

        init(_ url: URL) throws {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            if isDir.boolValue {
                guard let f = Files(folder: url) else { throw Failure.notAnExport }
                zip = nil; zipRoot = ""; folder = f.folder; mainURL = f.mainURL; mainEntry = nil; mainSize = f.mainSize
                return
            }
            let h = try FileHandle(forReadingFrom: url)
            let head = (try? h.read(upToCount: 4)) ?? Data()
            try? h.close()
            if head.starts(with: [0x50, 0x4B]) {
                let z = try ZipFile(url: url)
                guard let main = z.entries.values.first(where: { $0.name == "export.xml" || $0.name.hasSuffix("/export.xml") }) else {
                    throw Failure.notAnExport
                }
                zip = z
                zipRoot = String(main.name.dropLast("export.xml".count))
                folder = nil; mainURL = nil; mainEntry = main
                mainSize = Int64(main.size)
            } else {
                // export.xml on its own: the routes next to it can't be reached.
                zip = nil; zipRoot = ""; folder = nil; mainURL = url; mainEntry = nil
                mainSize = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }

        fileprivate init?(folder url: URL) {
            let fm = FileManager.default
            for dir in [url, url.appendingPathComponent("apple_health_export")] {
                let main = dir.appendingPathComponent("export.xml")
                if fm.fileExists(atPath: main.path) {
                    zip = nil; zipRoot = ""; folder = dir; mainURL = main; mainEntry = nil
                    mainSize = Int64((try? main.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                    return
                }
            }
            return nil
        }

        /// export.xml, a piece at a time.
        func main() throws -> ChunkReader {
            if let zip, let mainEntry { return try zip.reader(mainEntry) }
            guard let mainURL else { throw Failure.notAnExport }
            return try FileChunks(url: mainURL)
        }

        /// Another file in the export, by the path export.xml gives, e.g. "/workout-routes/route_1.gpx".
        func file(_ path: String) -> Data? {
            let rel = path.hasPrefix("/") ? String(path.dropFirst()) : path
            if let zip {
                guard let e = zip.entries[zipRoot + rel] else { return nil }
                return try? zip.data(e)
            }
            guard let folder else { return nil }
            return try? Data(contentsOf: folder.appendingPathComponent(rel))
        }

        /// How many files are in the export under this folder, e.g. "electrocardiograms/".
        func count(under prefix: String) -> Int {
            if let zip { return zip.entries.keys.filter { $0.hasPrefix(zipRoot + prefix) && !$0.hasSuffix("/") }.count }
            guard let folder else { return 0 }
            let dir = folder.appendingPathComponent(prefix)
            return ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).count
        }
    }
}

// MARK: Reading in pieces

protocol ChunkReader: AnyObject {
    /// The next piece, or nil at the end.
    func next() throws -> Data?
    /// How far through the unpacked file, in bytes.
    var position: Int64 { get }
}

final class FileChunks: ChunkReader {
    private let handle: FileHandle
    private(set) var position: Int64 = 0

    init(url: URL) throws { handle = try FileHandle(forReadingFrom: url) }
    deinit { try? handle.close() }

    func next() throws -> Data? {
        guard let d = try handle.read(upToCount: 1 << 20), !d.isEmpty else { return nil }
        position += Int64(d.count)
        return d
    }
}

/// Just enough of the zip format for Apple's export: stored or deflated entries, Zip64 sizes.
final class ZipFile {
    struct Entry {
        let name: String
        let method: UInt16
        let compressed: UInt64
        let size: UInt64
        let localOffset: UInt64
    }

    let url: URL
    private(set) var entries: [String: Entry] = [:]

    init(url: URL) throws {
        self.url = url
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        let fileSize = try h.seekToEnd()
        guard fileSize >= 22 else { throw AppleExport.Failure.incomplete }
        let tailSize = min(fileSize, 22 + 65535 + 20)
        try h.seek(toOffset: fileSize - tailSize)
        let tail = try h.read(upToCount: Int(tailSize)) ?? Data()
        guard let eocd = Self.lastIndex(of: [0x50, 0x4B, 0x05, 0x06], in: tail), eocd + 22 <= tail.count else {
            throw AppleExport.Failure.incomplete
        }
        var count = UInt64(tail.le16(eocd + 10))
        var cdSize = UInt64(tail.le32(eocd + 12))
        var cdOffset = UInt64(tail.le32(eocd + 16))
        if eocd >= 20, tail.le32(eocd - 20) == 0x07064B50 {
            let at = tail.le64(eocd - 20 + 8)
            try h.seek(toOffset: at)
            let z = try h.read(upToCount: 56) ?? Data()
            if z.count == 56, z.le32(0) == 0x06064B50 {
                count = z.le64(32); cdSize = z.le64(40); cdOffset = z.le64(48)
            }
        }
        guard cdOffset + cdSize <= fileSize else { throw AppleExport.Failure.incomplete }
        try h.seek(toOffset: cdOffset)
        let cd = try h.read(upToCount: Int(cdSize)) ?? Data()
        guard cd.count == Int(cdSize) else { throw AppleExport.Failure.incomplete }

        var p = 0
        for _ in 0..<count {
            guard p + 46 <= cd.count, cd.le32(p) == 0x02014B50 else { throw AppleExport.Failure.unreadable("the zip's table of contents is damaged") }
            let method = cd.le16(p + 10)
            var csize = UInt64(cd.le32(p + 20)), usize = UInt64(cd.le32(p + 24))
            let nameLen = Int(cd.le16(p + 28)), extraLen = Int(cd.le16(p + 30)), commentLen = Int(cd.le16(p + 32))
            var local = UInt64(cd.le32(p + 42))
            guard p + 46 + nameLen + extraLen <= cd.count else { throw AppleExport.Failure.unreadable("the zip's table of contents is damaged") }
            let nameData = cd.subdata(in: (cd.startIndex + p + 46)..<(cd.startIndex + p + 46 + nameLen))
            let name = String(data: nameData, encoding: .utf8) ?? String(decoding: nameData, as: UTF8.self)
            // Zip64 extra field: the sizes and offset that didn't fit, in this order.
            var e = p + 46 + nameLen
            let extraEnd = e + extraLen
            while e + 4 <= extraEnd {
                let id = cd.le16(e), len = Int(cd.le16(e + 2))
                if id == 0x0001 {
                    var q = e + 4
                    if usize == 0xFFFF_FFFF, q + 8 <= e + 4 + len { usize = cd.le64(q); q += 8 }
                    if csize == 0xFFFF_FFFF, q + 8 <= e + 4 + len { csize = cd.le64(q); q += 8 }
                    if local == 0xFFFF_FFFF, q + 8 <= e + 4 + len { local = cd.le64(q); q += 8 }
                }
                e += 4 + len
            }
            entries[name] = Entry(name: name, method: method, compressed: csize, size: usize, localOffset: local)
            p += 46 + nameLen + extraLen + commentLen
        }
    }

    private static func lastIndex(of sig: [UInt8], in data: Data) -> Int? {
        guard data.count >= sig.count else { return nil }
        var i = data.count - sig.count
        while i >= 0 {
            if data[data.startIndex + i] == sig[0] && data[data.startIndex + i + 1] == sig[1]
                && data[data.startIndex + i + 2] == sig[2] && data[data.startIndex + i + 3] == sig[3] { return i }
            i -= 1
        }
        return nil
    }

    /// Where an entry's data starts, past its local header.
    fileprivate func dataOffset(_ e: Entry, _ h: FileHandle) throws -> UInt64 {
        try h.seek(toOffset: e.localOffset)
        let head = try h.read(upToCount: 30) ?? Data()
        guard head.count == 30, head.le32(0) == 0x04034B50 else { throw AppleExport.Failure.unreadable("a file in the zip is damaged") }
        return e.localOffset + 30 + UInt64(head.le16(26)) + UInt64(head.le16(28))
    }

    func reader(_ e: Entry) throws -> ChunkReader {
        guard e.method == 0 || e.method == 8 else { throw AppleExport.Failure.unreadable("the zip uses an unusual kind of compression") }
        return try ZipEntryReader(zip: self, entry: e)
    }

    /// A whole entry, for small files like routes.
    func data(_ e: Entry) throws -> Data {
        let r = try reader(e)
        var out = Data()
        out.reserveCapacity(Int(e.size))
        while let d = try r.next() { out.append(d) }
        return out
    }
}

final class ZipEntryReader: ChunkReader {
    /// The packed bytes still to read, shared with the inflater's callback.
    private final class Packed {
        let handle: FileHandle
        var remaining: UInt64
        var piece = Data()
        var offset = 0
        init(_ h: FileHandle, _ n: UInt64) { handle = h; remaining = n }

        func read(_ length: Int) throws -> Data? {
            if offset >= piece.count {
                guard remaining > 0 else { return nil }
                let want = Int(min(UInt64(1 << 20), remaining))
                guard let d = try handle.read(upToCount: want), !d.isEmpty else { throw AppleExport.Failure.incomplete }
                remaining -= UInt64(d.count)
                piece = d; offset = 0
            }
            let n = min(length, piece.count - offset)
            defer { offset += n }
            return piece.subdata(in: (piece.startIndex + offset)..<(piece.startIndex + offset + n))
        }
    }

    private let handle: FileHandle
    private let packed: Packed
    private let filter: InputFilter<Data>?
    private(set) var position: Int64 = 0

    init(zip: ZipFile, entry: ZipFile.Entry) throws {
        handle = try FileHandle(forReadingFrom: zip.url)
        try handle.seek(toOffset: try zip.dataOffset(entry, handle))
        let packed = Packed(handle, entry.compressed)
        self.packed = packed
        // Apple's "zlib" is raw deflate, which is what zip stores.
        filter = entry.method == 8 ? try InputFilter(.decompress, using: .zlib, bufferCapacity: 1 << 16) { try packed.read($0) } : nil
    }

    deinit { try? handle.close() }

    func next() throws -> Data? {
        if let filter {
            let d: Data?
            do { d = try filter.readData(ofLength: 1 << 20) }
            catch let e as AppleExport.Failure { throw e }
            catch { throw AppleExport.Failure.unreadable("a file in the zip doesn't unpack") }
            guard let d, !d.isEmpty else { return nil }
            position += Int64(d.count)
            return d
        }
        guard let d = try packed.read(1 << 20) else { return nil }
        position += Int64(d.count)
        return d
    }
}

private extension Data {
    func le16(_ i: Int) -> UInt16 { UInt16(self[startIndex + i]) | UInt16(self[startIndex + i + 1]) << 8 }
    func le32(_ i: Int) -> UInt32 { UInt32(le16(i)) | UInt32(le16(i + 2)) << 16 }
    func le64(_ i: Int) -> UInt64 { UInt64(le32(i)) | UInt64(le32(i + 4)) << 32 }
}

// MARK: XML

/// A forgiving streaming XML reader for machine-written files: start tags with attributes, end
/// tags and, when asked, text. Declarations, comments and the DOCTYPE are skipped. Attribute
/// values are only valid during the `start` call.
final class XMLScanner {
    var onStart: (String, XMLScanner) throws -> Void = { _, _ in }
    var onEnd: (String) throws -> Void = { _ in }
    var onText: ((String) -> Void)?

    private var buf: [UInt8] = []
    private var pos = 0
    private var attrNames: [Range<Int>] = []
    private var attrValues: [Range<Int>] = []

    func feed(_ data: Data) throws {
        if pos > 0 && pos >= buf.count / 2 {
            buf.removeFirst(pos)
            pos = 0
        }
        buf.append(contentsOf: data)
        try scan()
    }

    func finish() throws {
        try scan()
        let rest = buf[pos...].contains { !($0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09) }
        if rest { throw AppleExport.Failure.unreadable("export.xml ends part way through") }
    }

    // MARK: Attributes of the element being started

    private func index(_ name: StaticString) -> Int? {
        let n = name.utf8Start, len = name.utf8CodeUnitCount
        for (i, r) in attrNames.enumerated() where r.count == len {
            var same = true
            for k in 0..<len where buf[r.lowerBound + k] != n[k] { same = false; break }
            if same { return i }
        }
        return nil
    }

    func attr(_ name: StaticString) -> String? {
        guard let i = index(name) else { return nil }
        return decode(attrValues[i])
    }

    func double(_ name: StaticString) -> Double? {
        guard let i = index(name) else { return nil }
        let r = attrValues[i]
        return buf.withUnsafeBufferPointer { Double(Substring(decoding: UnsafeBufferPointer(rebasing: $0[r]), as: UTF8.self)) }
    }

    /// Seconds since 2001 from "2026-09-02 17:15:00 +0300".
    func date(_ name: StaticString) -> Double? {
        guard let i = index(name) else { return nil }
        let r = attrValues[i]
        return buf.withUnsafeBufferPointer { AppleDates.parse(UnsafeBufferPointer(rebasing: $0[r])) }
    }

    /// All attributes, for elements that are rare enough not to matter.
    func allAttributes() -> [String: String] {
        var out: [String: String] = [:]
        for (n, v) in zip(attrNames, attrValues) { out[decode(n)] = decode(v) }
        return out
    }

    private func decode(_ r: Range<Int>) -> String {
        buf.withUnsafeBufferPointer { p in
            let s = UnsafeBufferPointer(rebasing: p[r])
            guard s.contains(0x26) else { return String(decoding: s, as: UTF8.self) }
            return XMLScanner.unescape(String(decoding: s, as: UTF8.self))
        }
    }

    static func unescape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if c == "&", let semi = s[i...].firstIndex(of: ";"), s.distance(from: i, to: semi) <= 10 {
                let name = s[s.index(after: i)..<semi]
                var rep: String?
                switch name {
                case "lt": rep = "<"
                case "gt": rep = ">"
                case "amp": rep = "&"
                case "quot": rep = "\""
                case "apos": rep = "'"
                default:
                    if name.hasPrefix("#x"), let v = UInt32(name.dropFirst(2), radix: 16), let u = Unicode.Scalar(v) { rep = String(Character(u)) }
                    else if name.hasPrefix("#"), let v = UInt32(name.dropFirst()), let u = Unicode.Scalar(v) { rep = String(Character(u)) }
                }
                if let rep { out += rep; i = s.index(after: semi); continue }
            }
            out.append(c)
            i = s.index(after: i)
        }
        return out
    }

    // MARK: Scanning

    private func find(_ pattern: [UInt8], from: Int) -> Int? {
        guard pattern.count > 0 else { return nil }
        var i = from
        let last = buf.count - pattern.count
        while i <= last {
            if buf[i] == pattern[0] {
                var ok = true
                for k in 1..<pattern.count where buf[i + k] != pattern[k] { ok = false; break }
                if ok { return i }
            }
            i += 1
        }
        return nil
    }

    private func scan() throws {
        let n = buf.count
        while pos < n {
            if buf[pos] != 0x3C { // text
                var j = pos
                while j < n && buf[j] != 0x3C { j += 1 }
                if j == n && onText != nil { return } // wait for the rest of the text
                if let onText {
                    let t = decode(pos..<j)
                    if !t.allSatisfy(\.isWhitespace) { onText(t) }
                }
                pos = j
                continue
            }
            guard pos + 1 < n else { return }
            let c1 = buf[pos + 1]
            if c1 == 0x3F { // <? ... ?>
                guard let e = find([0x3F, 0x3E], from: pos + 2) else { return }
                pos = e + 2
            } else if c1 == 0x21 { // <!
                if pos + 3 < n && buf[pos + 2] == 0x2D && buf[pos + 3] == 0x2D {
                    guard let e = find([0x2D, 0x2D, 0x3E], from: pos + 4) else { return }
                    pos = e + 3
                } else if pos + 8 < n && buf[pos + 2] == 0x5B && buf[pos + 3] == 0x43 { // <![CDATA[
                    guard let e = find([0x5D, 0x5D, 0x3E], from: pos + 9) else { return }
                    if let onText { onText(String(decoding: buf[(pos + 9)..<e], as: UTF8.self)) }
                    pos = e + 3
                } else if pos + 3 >= n {
                    return
                } else { // <!DOCTYPE ... [ ... ]>
                    var j = pos + 2, depth = 0
                    var quote: UInt8 = 0
                    var done = false
                    while j < n {
                        let b = buf[j]
                        if quote != 0 { if b == quote { quote = 0 } }
                        else if b == 0x22 || b == 0x27 { quote = b }
                        else if b == 0x3C && j + 3 < n && buf[j + 1] == 0x21 && buf[j + 2] == 0x2D && buf[j + 3] == 0x2D {
                            guard let e = find([0x2D, 0x2D, 0x3E], from: j + 4) else { return }
                            j = e + 2
                        }
                        else if b == 0x5B { depth += 1 }
                        else if b == 0x5D { depth -= 1 }
                        else if b == 0x3E && depth <= 0 { done = true; break }
                        j += 1
                    }
                    guard done else { return }
                    pos = j + 1
                }
            } else if c1 == 0x2F { // </name>
                guard let e = find([0x3E], from: pos + 2) else { return }
                var a = pos + 2, b = e
                while a < b && Self.space(buf[a]) { a += 1 }
                while b > a && Self.space(buf[b - 1]) { b -= 1 }
                let name = String(decoding: buf[a..<b], as: UTF8.self)
                pos = e + 1
                try onEnd(name)
            } else {
                guard let end = tagEnd(from: pos + 1) else { return }
                try startTag(pos + 1, end)
                pos = end + 1
            }
        }
    }

    private static func space(_ b: UInt8) -> Bool { b == 0x20 || b == 0x0A || b == 0x0D || b == 0x09 }

    /// The closing ">" of a start tag, outside quoted values.
    private func tagEnd(from: Int) -> Int? {
        var j = from
        var quote: UInt8 = 0
        let n = buf.count
        while j < n {
            let b = buf[j]
            if quote != 0 { if b == quote { quote = 0 } }
            else if b == 0x22 || b == 0x27 { quote = b }
            else if b == 0x3E { return j }
            j += 1
        }
        return nil
    }

    private func startTag(_ from: Int, _ end: Int) throws {
        var j = from
        while j < end && !Self.space(buf[j]) && buf[j] != 0x2F { j += 1 }
        let name = String(decoding: buf[from..<j], as: UTF8.self)
        attrNames.removeAll(keepingCapacity: true)
        attrValues.removeAll(keepingCapacity: true)
        var selfClosing = false
        while j < end {
            let b = buf[j]
            if Self.space(b) { j += 1; continue }
            if b == 0x2F { selfClosing = true; j += 1; continue }
            let ns = j
            while j < end && buf[j] != 0x3D && !Self.space(buf[j]) { j += 1 }
            let ne = j
            while j < end && Self.space(buf[j]) { j += 1 }
            guard j < end, buf[j] == 0x3D else { continue }
            j += 1
            while j < end && Self.space(buf[j]) { j += 1 }
            guard j < end else { break }
            let q = buf[j]
            guard q == 0x22 || q == 0x27 else { continue }
            let vs = j + 1
            var ve = vs
            while ve < end && buf[ve] != q { ve += 1 }
            attrNames.append(ns..<ne)
            attrValues.append(vs..<ve)
            j = ve + 1
        }
        try onStart(name, self)
        if selfClosing { try onEnd(name) }
    }
}

/// Dates as Apple's export writes them, parsed by hand: there are millions.
enum AppleDates {
    private static func digits(_ p: UnsafeBufferPointer<UInt8>, _ at: Int, _ n: Int) -> Int? {
        var v = 0
        for k in 0..<n {
            let c = Int(p[at + k]) - 48
            guard c >= 0 && c <= 9 else { return nil }
            v = v * 10 + c
        }
        return v
    }

    /// Days from 1970-01-01 to a civil date (Howard Hinnant's algorithm).
    private static func days(_ y0: Int, _ m: Int, _ d: Int) -> Int {
        let y = m <= 2 ? y0 - 1 : y0
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146097 + doe - 719468
    }

    /// "yyyy-MM-dd HH:mm:ss +hhmm" (export.xml) or "yyyy-MM-ddTHH:mm:ss[.fff](Z|+hh:mm)" (GPX).
    static func parse(_ p: UnsafeBufferPointer<UInt8>) -> Double? {
        guard p.count >= 19, p[4] == 0x2D, p[7] == 0x2D,
              let y = digits(p, 0, 4), let mo = digits(p, 5, 2), let d = digits(p, 8, 2),
              let h = digits(p, 11, 2), let mi = digits(p, 14, 2), let s = digits(p, 17, 2),
              (1...12).contains(mo), (1...31).contains(d) else { return nil }
        var i = 19
        var frac = 0.0
        if i < p.count && (p[i] == 0x2E || p[i] == 0x2C) {
            i += 1
            var scale = 0.1
            while i < p.count, p[i] >= 48 && p[i] <= 57 { frac += Double(p[i] - 48) * scale; scale /= 10; i += 1 }
        }
        while i < p.count && p[i] == 0x20 { i += 1 }
        var offset = 0
        if i < p.count && (p[i] == 0x2B || p[i] == 0x2D) {
            let sign = p[i] == 0x2D ? -1 : 1
            i += 1
            guard let oh = i + 2 <= p.count ? digits(p, i, 2) : nil else { return nil }
            i += 2
            if i < p.count && p[i] == 0x3A { i += 1 }
            let om = i + 2 <= p.count ? (digits(p, i, 2) ?? 0) : 0
            offset = sign * (oh * 3600 + om * 60)
        }
        let unix = days(y, mo, d) * 86400 + h * 3600 + mi * 60 + s - offset
        return Double(unix - 978_307_200) + frac
    }

    static func parse(_ s: String) -> Double? {
        var s = s
        return s.withUTF8 { parse($0) }
    }
}

// MARK: Converting

/// Turns export.xml (and its route files) into a .healthcopy file.
final class AppleExportConverter {
    struct Progress {
        var read: Int64 = 0
        var total: Int64 = 1
        var records = 0
    }

    static let samplesPerFrame = 2000
    static let workoutsPerFrame = 25

    private let files: AppleExport.Files
    private let writer: ArchiveWriter
    private let out: URL
    private let report: (Progress) -> Void
    private var progress = Progress()
    private var lastReport = Date.distantPast

    private var totals: [String: TypeTotal] = [:]
    private var work = 0
    private var skipped: [String: Int] = [:]
    private var exportDate: Double?
    private var exportDateText = ""

    init(files: AppleExport.Files, to url: URL, report: @escaping (Progress) -> Void) throws {
        self.files = files
        self.out = url
        self.writer = try ArchiveWriter(url: url)
        self.report = report
        progress.total = max(1, files.mainSize)
    }

    // MARK: Tables

    /// Device and source tables, shared by every frame of one kind of record.
    final class Tables {
        private(set) var devices: [DeviceRecord] = []
        private(set) var sources: [SourceRecord] = []
        private var deviceIndex: [DeviceRecord: Int] = [:]
        private var sourceIndex: [SourceRecord: Int] = [:]

        func device(_ d: DeviceRecord?) -> Int? {
            guard let d else { return nil }
            if let i = deviceIndex[d] { return i }
            devices.append(d); deviceIndex[d] = devices.count - 1
            return devices.count - 1
        }

        func source(_ s: SourceRecord) -> Int {
            if let i = sourceIndex[s] { return i }
            sources.append(s); sourceIndex[s] = sources.count - 1
            return sources.count - 1
        }
    }

    private var deviceCache: [String: DeviceRecord] = [:]

    /// "<<HKDevice: 0x1>, name:Apple Watch, manufacturer:Apple Inc., model:Watch, hardware:Watch7,3,
    /// software:26.0, creation date:2026-10-30 01:59:14 +0000>"
    private func device(_ raw: String?) -> DeviceRecord? {
        guard var s = raw, !s.isEmpty else { return nil }
        if let r = s.range(of: ">, ") { s = String(s[r.upperBound...]) }
        if s.hasSuffix(">") { s.removeLast() }
        if let hit = deviceCache[s] { return hit }
        let keys = ["name", "manufacturer", "model", "hardware", "firmware", "software", "localIdentifier", "UDIDeviceIdentifier", "creation date"]
        var marks: [(String.Index, String.Index, String)] = []
        for k in keys {
            if s.hasPrefix(k + ":") { marks.append((s.startIndex, s.index(s.startIndex, offsetBy: k.count + 1), k)) }
            var from = s.startIndex
            while let r = s.range(of: ", " + k + ":", range: from..<s.endIndex) {
                marks.append((r.lowerBound, r.upperBound, k))
                from = r.upperBound
            }
        }
        marks.sort { $0.0 < $1.0 }
        var fields: [String: String] = [:]
        for (i, m) in marks.enumerated() {
            let end = i + 1 < marks.count ? marks[i + 1].0 : s.endIndex
            guard m.1 <= end else { continue }
            fields[m.2] = String(s[m.1..<end])
        }
        let rec = DeviceRecord(name: fields["name"], manufacturer: fields["manufacturer"], model: fields["model"],
                               hardware: fields["hardware"], firmware: fields["firmware"], software: fields["software"],
                               localID: fields["localIdentifier"], udi: fields["UDIDeviceIdentifier"])
        let empty = rec.name == nil && rec.manufacturer == nil && rec.model == nil && rec.hardware == nil
        let result = empty ? DeviceRecord(name: s) : rec
        if deviceCache.count < 5000 { deviceCache[s] = result }
        return result
    }

    // MARK: Metadata

    /// HealthKit keys whose values are text even when they look like numbers.
    private static let textKeys: Set<String> = [
        "HKTimeZone", "HKExternalUUID", "HKDeviceSerialNumber", "HKUDIDeviceIdentifier", "HKUDIProductionIdentifier",
        "HKDigitalSignature", "HKDeviceName", "HKDeviceManufacturerName", "HKWorkoutBrandName", "HKFoodType",
        "HKMetadataKeySyncIdentifier", "HKAppleECGAlgorithmVersion",
    ]

    /// Metadata values are all text in the export: "1", "51.8 degF", "76 %", "Europe/Helsinki".
    static func metaValue(key: String, _ raw: String) -> MetaValue {
        if textKeys.contains(key) { return MetaValue(s: raw) }
        if let i = Int64(raw) { return MetaValue(i: i) }
        if let n = Double(raw), n.isFinite, raw.contains(where: { $0 == "." || $0 == "e" || $0 == "E" }) { return MetaValue(n: n) }
        if raw.count >= 19, raw.count <= 30, raw.first?.isNumber == true, let d = AppleDates.parse(raw) { return MetaValue(d: d) }
        if let space = raw.firstIndex(of: " "), let n = Double(raw[..<space]), n.isFinite {
            let unit = String(raw[raw.index(after: space)...])
            if !unit.isEmpty, !unit.contains(" ") {
                // The export writes a percentage as 76 for 0.76.
                if unit == "%" { return MetaValue(s: raw, q: n / 100, u: "%") }
                return MetaValue(s: raw, q: n, u: unit)
            }
        }
        return MetaValue(s: raw)
    }

    // MARK: Records being read

    private struct Pending {
        var type = ""
        var unit: String?
        var value: String?
        var start = 0.0
        var end = 0.0
        var created = ""
        var source = SourceRecord(name: "", bundle: "")
        var device: DeviceRecord?
        var meta: Meta = [:]
    }

    private struct Group {
        var kind: SampleKind
        var unit: String?
        let tables = Tables()
        var items: [SampleRecord] = []
        var keys: [String] = []
    }

    private struct PendingCorrelation {
        var record = Pending()
        var members: [Pending] = []
    }

    private struct PendingWorkout {
        var act: UInt = 3000
        var start = 0.0
        var end = 0.0
        var duration: Double?
        var created = ""
        var source = SourceRecord(name: "", bundle: "")
        var device: DeviceRecord?
        var meta: Meta = [:]
        var events: [EventRecord] = []
        var kcal: Double?
        var dist: Double?
        var strokes: Double?
        var flights: Double?
        var routes: [Pending] = []
        /// Per route: the GPX file, or the points older exports list inline.
        var routeData: [(String, [Double])] = []
        var statDistance = 0.0
    }

    private var record: Pending?
    private var correlation: PendingCorrelation?
    private var workout: PendingWorkout?
    private var route: Pending?
    private var routePath: String?
    private var routeInline: [Double] = []
    private var event: EventRecord?
    private var activityDepth = 0
    private var ignoreDepth = 0

    private var groups: [String: Group] = [:]
    /// Loose copies of blood pressure and food values, held back until the entries they belong
    /// to have been seen.
    private var held: [String: Group] = [:]
    private var memberKeys = Set<String>()

    private var correlations: [CorrelationRecord] = []
    private let correlationTables = Tables()
    private var workouts: [WorkoutRecord] = []
    private let workoutTables = Tables()

    private static func isMemberType(_ t: String) -> Bool {
        t.hasPrefix("HKQuantityTypeIdentifierDietary") || t.hasPrefix("HKQuantityTypeIdentifierBloodPressure")
    }

    // MARK: Run

    func run() throws -> Manifest {
        do {
            let scanner = XMLScanner()
            scanner.onStart = { [unowned self] name, x in try self.start(name, x) }
            scanner.onEnd = { [unowned self] name in try self.end(name) }
            let reader = try files.main()
            while let chunk = try reader.next() {
                try scanner.feed(chunk)
                progress.read = reader.position
                tick()
            }
            try scanner.finish()

            for key in groups.keys.sorted() { try flushGroup(key, all: true) }
            try flushCorrelations(all: true)
            try flushWorkouts(all: true)
            // Loose copies of values that are also inside an entry would end up in Health twice.
            for key in held.keys.sorted() {
                guard var g = held[key] else { continue }
                var keep: [SampleRecord] = []
                for (item, k) in zip(g.items, g.keys) where !memberKeys.contains(k) { keep.append(item) }
                g.items = keep
                g.keys = []
                let type = String(key.split(separator: "|", maxSplits: 1).first ?? "")
                var i = 0
                while i < keep.count {
                    let part = Array(keep[i..<min(i + Self.samplesPerFrame, keep.count)])
                    try writeSamples(type: type, g, part)
                    i += Self.samplesPerFrame
                }
            }

            let ecgs = files.count(under: "electrocardiograms/")
            if ecgs > 0 { skipped["ECG recordings (only Apple's ECG app can add these)", default: 0] += ecgs }
            let notes = skipped.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }
            let info = Bundle.main.infoDictionary
            let idSource = "\(exportDateText)|\(files.mainSize)"
            let manifest = Manifest(
                format: ArchiveFormat.version, id: "apple-" + Self.uuid(idSource), created: exportDate ?? Date().timeIntervalSinceReferenceDate,
                device: "iPhone", system: "Apple Health export",
                app: "\(info?["CFBundleShortVersionString"] ?? "?") (\(info?["CFBundleVersion"] ?? "?"))",
                frames: writer.frames, work: work, totals: totals, notes: notes, origin: AppleExport.origin)
            try writer.finish(manifest)
            progress.read = progress.total
            report(progress)
            return manifest
        } catch {
            writer.abandon()
            try? FileManager.default.removeItem(at: out)
            throw error
        }
    }

    private func tick() {
        if Date().timeIntervalSince(lastReport) > 0.2 {
            lastReport = Date()
            report(progress)
        }
    }

    /// A stable UUID made from a record's contents, so the same export always gives the same IDs
    /// and copying it twice never adds anything twice.
    static func uuid(_ s: String) -> String {
        var b = Array(SHA256.hash(data: Data(s.utf8)).prefix(16))
        b[6] = (b[6] & 0x0F) | 0x50
        b[8] = (b[8] & 0x3F) | 0x80
        let hex = b.map { String(format: "%02X", $0) }.joined()
        let c = Array(hex)
        return "\(String(c[0..<8]))-\(String(c[8..<12]))-\(String(c[12..<16]))-\(String(c[16..<20]))-\(String(c[20..<32]))"
    }

    // MARK: Elements

    private func pending(_ x: XMLScanner, type: String) -> Pending? {
        guard let s = x.date("startDate"), let e = x.date("endDate") else { return nil }
        var p = Pending()
        p.type = type
        p.unit = x.attr("unit")
        p.value = x.attr("value")
        p.start = s
        p.end = e
        p.created = x.attr("creationDate") ?? ""
        p.source = SourceRecord(name: x.attr("sourceName") ?? "", bundle: "", version: x.attr("sourceVersion"))
        p.device = device(x.attr("device"))
        return p
    }

    private static func seconds(_ value: Double?, _ unit: String?) -> Double? {
        guard let value else { return nil }
        switch unit ?? "min" {
        case "s", "sec": return value
        case "ms": return value / 1000
        case "min": return value * 60
        case "hr", "h": return value * 3600
        case "d", "day": return value * 86400
        default: return nil
        }
    }

    private static let kcalPer: [String: Double] = ["kcal": 1, "Cal": 1, "cal": 0.001, "kJ": 0.239005736, "J": 0.000239005736]
    private static let metresPer: [String: Double] = [
        "m": 1, "km": 1000, "cm": 0.01, "mm": 0.001, "mi": 1609.344, "yd": 0.9144, "ft": 0.3048, "in": 0.0254,
    ]

    private func start(_ name: String, _ x: XMLScanner) throws {
        if ignoreDepth > 0 { ignoreDepth += 1; return }
        switch name {
        case "Record":
            if workout != nil { ignoreDepth = 1; return } // also listed on its own
            guard let type = x.attr("type") else { ignoreDepth = 1; return }
            guard let p = pending(x, type: type) else { skipped["Records without dates", default: 0] += 1; ignoreDepth = 1; return }
            record = p
        case "MetadataEntry":
            guard let key = x.attr("key"), let raw = x.attr("value") else { return }
            if key.hasPrefix("_") { return }
            let v = Self.metaValue(key: key, raw)
            if record != nil { record!.meta[key] = v }
            else if route != nil { route!.meta[key] = v }
            else if event != nil { event!.m = (event!.m ?? [:]).merging([key: v]) { $1 } }
            else if activityDepth > 0 { return }
            else if workout != nil { workout!.meta[key] = v }
            else if correlation != nil { correlation!.record.meta[key] = v }
        case "HeartRateVariabilityMetadataList":
            skipped["Heartbeat series (Apple's export only has their summary)", default: 0] += 1
            ignoreDepth = 1
        case "Correlation":
            guard let type = x.attr("type"), let p = pending(x, type: type) else { ignoreDepth = 1; return }
            correlation = PendingCorrelation(record: p)
        case "Workout":
            guard let s = x.date("startDate"), let e = x.date("endDate") else { ignoreDepth = 1; skipped["Workouts without dates", default: 0] += 1; return }
            var w = PendingWorkout()
            let typeName = x.attr("workoutActivityType") ?? ""
            w.act = AppleNames.activityTypes[typeName].map(UInt.init) ?? UInt(typeName) ?? 3000
            w.start = s; w.end = e
            w.duration = Self.seconds(x.double("duration"), x.attr("durationUnit"))
            w.created = x.attr("creationDate") ?? ""
            w.source = SourceRecord(name: x.attr("sourceName") ?? "", bundle: "", version: x.attr("sourceVersion"))
            w.device = device(x.attr("device"))
            if let d = x.double("totalDistance"), let f = Self.metresPer[x.attr("totalDistanceUnit") ?? "km"] { w.dist = d * f }
            if let k = x.double("totalEnergyBurned"), let f = Self.kcalPer[x.attr("totalEnergyBurnedUnit") ?? "kcal"] { w.kcal = k * f }
            if let n = x.double("totalSwimmingStrokeCount") { w.strokes = n }
            if let n = x.double("totalFlightsClimbed") { w.flights = n }
            workout = w
        case "WorkoutActivity":
            if workout != nil { activityDepth += 1 }
        case "WorkoutEvent":
            guard workout != nil, let t = AppleNames.eventTypes[x.attr("type") ?? ""], let s = x.date("date") else { return }
            let dur = Self.seconds(x.double("duration"), x.attr("durationUnit")) ?? 0
            event = EventRecord(t: t, s: s, e: s + dur, m: nil)
        case "WorkoutStatistics":
            guard workout != nil, activityDepth == 0, let type = x.attr("type"), let sum = x.double("sum") else { return }
            let unit = x.attr("unit") ?? ""
            let suffix = type.replacingOccurrences(of: "HKQuantityTypeIdentifier", with: "")
            if suffix == "ActiveEnergyBurned", workout!.kcal == nil, let f = Self.kcalPer[unit] { workout!.kcal = sum * f }
            else if suffix.hasPrefix("Distance"), let f = Self.metresPer[unit], sum * f > workout!.statDistance {
                workout!.statDistance = sum * f
            }
            else if suffix == "SwimmingStrokeCount", workout!.strokes == nil { workout!.strokes = sum }
            else if suffix == "FlightsClimbed", workout!.flights == nil { workout!.flights = sum }
        case "WorkoutRoute":
            guard workout != nil, let p = pending(x, type: "route") else { ignoreDepth = 1; return }
            route = p
            routePath = nil
            routeInline = []
        case "FileReference":
            if route != nil { routePath = x.attr("path") }
        case "Location":
            // Exports before iOS 13 list route points inline.
            if route != nil, let t = x.date("date"), let lat = x.double("latitude"), let lon = x.double("longitude") {
                routeInline += [t, lat, lon, x.double("altitude") ?? 0, x.double("horizontalAccuracy") ?? -1,
                                x.double("verticalAccuracy") ?? -1, x.double("course") ?? -1, -1, x.double("speed") ?? -1, -1]
            }
        case "ExportDate":
            if let v = x.attr("value") { exportDateText = v; exportDate = AppleDates.parse(v) }
        case "ActivitySummary":
            skipped["Activity ring days (Apple makes these itself)", default: 0] += 1
        case "ClinicalRecord":
            skipped["Health Records from hospitals (only Apple can add these)", default: 0] += 1
        case "Audiogram":
            skipped["Hearing tests", default: 0] += 1
            ignoreDepth = 1
        case "VisionPrescription":
            skipped["Glasses and lens prescriptions", default: 0] += 1
            ignoreDepth = 1
        case "WorkoutZoneGroup":
            ignoreDepth = 1
        default:
            break
        }
    }

    private func end(_ name: String) throws {
        if ignoreDepth > 0 { ignoreDepth -= 1; return }
        switch name {
        case "Record":
            guard let r = record else { return }
            record = nil
            if correlation != nil { correlation!.members.append(r) } else { try add(r) }
        case "Correlation":
            guard let c = correlation else { return }
            correlation = nil
            try addCorrelation(c)
        case "WorkoutEvent":
            if let e = event, workout != nil {
                if !workout!.events.contains(where: { $0.t == e.t && $0.s == e.s && $0.e == e.e }) { workout!.events.append(e) }
            }
            event = nil
        case "WorkoutActivity":
            if activityDepth > 0 { activityDepth -= 1 }
        case "WorkoutRoute":
            if let r = route, workout != nil { workout!.routes.append(r); workout!.routeData.append((routePath ?? "", routeInline)) }
            routeInline = []
            route = nil
        case "Workout":
            guard let w = workout else { return }
            workout = nil
            try addWorkout(w)
        default:
            break
        }
    }

    // MARK: Samples

    /// The record as stored, or nil (and why) if it can't be.
    private func sample(_ p: Pending, tables: Tables) -> (SampleRecord, SampleKind)? {
        let kind: SampleKind
        let value: Double
        if p.type.hasPrefix(AppleExport.quantityPrefix) {
            guard p.unit?.isEmpty == false, let v = p.value.flatMap(Double.init), v.isFinite else {
                skipped["\(Self.name(p.type)): records without a readable value", default: 0] += 1
                return nil
            }
            kind = .quantity; value = v
        } else if p.type.hasPrefix(AppleExport.categoryPrefix) {
            let raw = p.value ?? "HKCategoryValueNotApplicable"
            guard let v = AppleNames.categoryValues[raw] ?? Int(raw) else {
                skipped["\(Self.name(p.type)): records with an unknown value (\(raw))", default: 0] += 1
                return nil
            }
            kind = .category; value = Double(v)
        } else {
            skipped["\(Self.name(p.type)) (not something apps can add)", default: 0] += 1
            return nil
        }
        let id = Self.uuid([p.type, String(p.start), String(p.end), p.value ?? "", p.source.name, p.created].joined(separator: "|"))
        let rec = SampleRecord(id: id, s: p.start, e: p.end, v: value, dv: tables.device(p.device), sr: tables.source(p.source),
                               m: p.meta.isEmpty ? nil : p.meta, ser: nil)
        return (rec, kind)
    }

    private static func name(_ type: String) -> String {
        for prefix in [AppleExport.quantityPrefix, AppleExport.categoryPrefix, "HKDataType"] where type.hasPrefix(prefix) {
            return String(type.dropFirst(prefix.count))
        }
        return type
    }

    /// Identifies a value inside an entry and its loose copy.
    private static func memberKey(_ p: Pending) -> String {
        [p.type, String(p.start), String(p.end), p.value ?? "", p.source.name, p.unit ?? ""].joined(separator: "|")
    }

    private func add(_ p: Pending) throws {
        let key = p.type + "|" + (p.unit ?? "")
        let hold = Self.isMemberType(p.type)
        var g = (hold ? held[key] : groups[key]) ?? Group(kind: .quantity, unit: p.unit)
        guard let (rec, kind) = sample(p, tables: g.tables) else { return }
        g.kind = kind
        g.items.append(rec)
        if hold { g.keys.append(Self.memberKey(p)) }
        progress.records += 1
        if hold { held[key] = g } else { groups[key] = g; if g.items.count >= Self.samplesPerFrame { try flushGroup(key, all: false) } }
    }

    private func flushGroup(_ key: String, all: Bool) throws {
        guard var g = groups[key], !g.items.isEmpty else { return }
        let type = String(key.split(separator: "|", maxSplits: 1).first ?? "")
        try writeSamples(type: type, g, g.items)
        g.items = []
        groups[key] = g
    }

    private func writeSamples(type: String, _ g: Group, _ items: [SampleRecord]) throws {
        guard !items.isEmpty else { return }
        let unit = g.kind == .quantity ? g.unit : nil
        try writer.append(.samples, SampleChunk(type: type, kind: g.kind, unit: unit, devices: g.tables.devices,
                                                sources: g.tables.sources, items: items))
        for r in items { totals[type, default: TypeTotal(count: 0)].add(start: r.s, end: r.e) }
        work += items.count
    }

    // MARK: Correlations

    private func addCorrelation(_ c: PendingCorrelation) throws {
        var byType: [String: [Pending]] = [:]
        for m in c.members { byType[m.type + "|" + (m.unit ?? ""), default: []].append(m) }
        var objs: [SampleGroup] = []
        for (key, members) in byType.sorted(by: { $0.key < $1.key }) {
            var recs: [SampleRecord] = []
            var kind = SampleKind.quantity
            for m in members {
                guard let (rec, k) = sample(m, tables: correlationTables) else { continue }
                kind = k
                recs.append(rec)
                memberKeys.insert(Self.memberKey(m))
            }
            guard !recs.isEmpty else { continue }
            let type = String(key.split(separator: "|", maxSplits: 1).first ?? "")
            objs.append(SampleGroup(type: type, kind: kind, unit: members.first?.unit, items: recs))
        }
        guard !objs.isEmpty else { skipped["\(Self.name(c.record.type)) entries with nothing in them", default: 0] += 1; return }
        let p = c.record
        let id = Self.uuid(["correlation", p.type, String(p.start), String(p.end), p.source.name, p.created].joined(separator: "|"))
        correlations.append(CorrelationRecord(id: id, type: p.type, s: p.start, e: p.end, dv: correlationTables.device(p.device),
                                              sr: correlationTables.source(p.source), m: p.meta.isEmpty ? nil : p.meta, objs: objs))
        totals[p.type, default: TypeTotal(count: 0)].add(start: p.start, end: p.end)
        for g in objs { for r in g.items { totals[g.type, default: TypeTotal(count: 0)].add(start: r.s, end: r.e) } }
        work += 1 + objs.reduce(0) { $0 + $1.items.count }
        progress.records += 1
        if correlations.count >= 500 { try flushCorrelations(all: false) }
    }

    private func flushCorrelations(all: Bool) throws {
        guard !correlations.isEmpty else { return }
        try writer.append(.correlations, CorrelationChunk(devices: correlationTables.devices, sources: correlationTables.sources, items: correlations))
        correlations = []
    }

    // MARK: Workouts

    private func addWorkout(_ p: PendingWorkout) throws {
        var w = p
        if w.dist == nil, w.statDistance > 0 { w.dist = w.statDistance }
        var routes: [RouteRecord] = []
        for (r, (path, inline)) in zip(w.routes, w.routeData) {
            var points = inline
            if points.isEmpty {
                guard !path.isEmpty, let data = files.file(path) else {
                    skipped["Workout routes whose map file isn't in the export", default: 0] += 1
                    continue
                }
                points = Self.gpxPoints(data)
            }
            guard !points.isEmpty else { skipped["Workout routes with no points", default: 0] += 1; continue }
            let id = Self.uuid(["route", String(r.start), String(r.end), path].joined(separator: "|"))
            routes.append(RouteRecord(id: id, s: r.start, e: r.end, dv: workoutTables.device(r.device),
                                      sr: workoutTables.source(r.source), m: r.meta.isEmpty ? nil : r.meta, pts: points))
            totals["route", default: TypeTotal(count: 0)].add(start: r.start, end: r.end)
        }
        let id = Self.uuid(["workout", String(w.act), String(w.start), String(w.end), w.source.name, w.created].joined(separator: "|"))
        workouts.append(WorkoutRecord(
            id: id, s: w.start, e: w.end, dur: w.duration ?? (w.end - w.start), act: w.act,
            dv: workoutTables.device(w.device), sr: workoutTables.source(w.source), m: w.meta.isEmpty ? nil : w.meta,
            ev: w.events.sorted { $0.s < $1.s }, acts: nil, kcal: w.kcal, dist: w.dist, strokes: w.strokes, flights: w.flights,
            samples: [], routes: routes))
        totals["workout", default: TypeTotal(count: 0)].add(start: w.start, end: w.end)
        work += 1 + routes.count
        progress.records += 1
        if workouts.count >= Self.workoutsPerFrame { try flushWorkouts(all: false) }
    }

    private func flushWorkouts(all: Bool) throws {
        guard !workouts.isEmpty else { return }
        try writer.append(.workouts, WorkoutChunk(devices: workoutTables.devices, sources: workoutTables.sources, items: workouts))
        workouts = []
    }

    /// Route points from a GPX file, ten numbers each as RouteRecord stores them. The export
    /// leaves out course and speed accuracy, which are stored as unknown (-1). A point without a
    /// horizontal accuracy gets 0, as a negative one would mark the whole point invalid.
    static func gpxPoints(_ data: Data) -> [Double] {
        var out: [Double] = []
        var point: [Double]?
        var field = ""
        let x = XMLScanner()
        x.onStart = { name, x in
            switch name {
            case "trkpt":
                point = [0, x.double("lat") ?? 0, x.double("lon") ?? 0, 0, 0, -1, -1, -1, -1, -1]
            default:
                field = name
            }
        }
        x.onEnd = { name in
            if name == "trkpt", let p = point { if p[0] != 0 { out += p }; point = nil }
            field = ""
        }
        x.onText = { text in
            guard point != nil else { return }
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch field {
            case "time": point![0] = AppleDates.parse(t) ?? 0
            case "ele": point![3] = Double(t) ?? 0
            case "hAcc": point![4] = Double(t) ?? 0
            case "vAcc": point![5] = Double(t) ?? -1
            case "course": point![6] = Double(t) ?? -1
            case "speed": point![8] = Double(t) ?? -1
            default: break
            }
        }
        try? x.feed(data)
        try? x.finish()
        return out
    }
}
