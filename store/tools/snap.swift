// Headless WebKit stills: snap URL WxH out.png [wait] [js]
// No Dock icon (accessory app, window kept off screen).
import Cocoa
import WebKit

let a = CommandLine.arguments
guard a.count >= 4, let url = URL(string: a[1]) else { print("usage: snap URL WxH out.png [wait] [js]"); exit(2) }
// WxH or WxH@zoom: zoom 1.5 on a 2x Mac renders at the phone's 3x
let sizeArg = a[2].split(separator: "@")
let d = sizeArg[0].split(separator: "x").compactMap { Double($0) }
let zoom = sizeArg.count > 1 ? Double(sizeArg[1]) ?? 1 : 1
let out = a[3]
let wait = a.count > 4 ? Double(a[4]) ?? 1.5 : 1.5
let js = a.count > 5 ? a[5] : ""

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let frame = NSRect(x: -20000, y: -20000, width: d[0] * zoom, height: d[1] * zoom)
let win = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
let cfg = WKWebViewConfiguration()
cfg.websiteDataStore = .nonPersistent()
let web = WKWebView(frame: NSRect(x: 0, y: 0, width: d[0] * zoom, height: d[1] * zoom), configuration: cfg)
web.pageZoom = zoom
win.contentView = web
win.orderBack(nil)

final class Nav: NSObject, WKNavigationDelegate {
  func webView(_ w: WKWebView, didFinish n: WKNavigation!) {
    DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
      let run = js.isEmpty ? "document.title" : js + ";document.title"
      w.evaluateJavaScript(run) { res, err in
        if let err { FileHandle.standardError.write("js: \(err)\n".data(using: .utf8)!) }
        if let t = res as? String, !t.isEmpty { print(t) }
        let c = WKSnapshotConfiguration()
        w.takeSnapshot(with: c) { img, err in
          guard let img, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                let png = rep.representation(using: .png, properties: [:]) else { print("snapshot failed: \(String(describing: err))"); exit(1) }
          try? png.write(to: URL(fileURLWithPath: out))
          exit(0)
        }
      }
    }
  }
  func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) { print("fail \(e)"); exit(1) }
  func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) { print("fail \(e)"); exit(1) }
}
let nav = Nav()
web.navigationDelegate = nav
if url.isFileURL { web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent()) } else { web.load(URLRequest(url: url)) }
DispatchQueue.main.asyncAfter(deadline: .now() + 60) { print("timeout"); exit(1) }
app.run()
