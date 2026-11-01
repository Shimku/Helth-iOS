// Records a page animation to video: film URL WxH@zoom out.mp4 seconds [fps]
// The page must define frame(t), which draws the moment t seconds in. Each frame is a WebKit
// snapshot, so the timing is exact however slow the snapshots are. The result is H.264 plus a
// silent stereo AAC track (App Store videos play muted, but the app preview spec describes audio
// as AAC). The silence is added afterwards without re-encoding: writing it alongside the frames
// stalls AVAssetWriter's interleaving.
// No Dock icon (accessory app, window kept off screen). On a 2x Mac, @0.25 of 3840x2560 gives
// 1920x1280 pixels. FILM_DEBUG=1 logs each frame.
import AVFoundation
import Cocoa
import WebKit

let a = CommandLine.arguments
guard a.count >= 5, let url = URL(string: a[1]) else { print("usage: film URL WxH@zoom out.mp4 seconds [fps]"); exit(2) }
let sizeArg = a[2].split(separator: "@")
let d = sizeArg[0].split(separator: "x").compactMap { Double($0) }
let zoom = sizeArg.count > 1 ? Double(sizeArg[1]) ?? 1 : 1
let out = URL(fileURLWithPath: a[3])
let duration = Double(a[4]) ?? 10
let fps = a.count > 5 ? Int32(a[5]) ?? 30 : 30
let frames = Int(duration * Double(fps))
let debug = ProcessInfo.processInfo.environment["FILM_DEBUG"] != nil

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let points = NSSize(width: d[0] * zoom, height: d[1] * zoom)
let win = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: points.width, height: points.height),
                   styleMask: [.borderless], backing: .buffered, defer: false)
let cfg = WKWebViewConfiguration()
cfg.websiteDataStore = .nonPersistent()
let web = WKWebView(frame: NSRect(origin: .zero, size: points), configuration: cfg)
web.pageZoom = zoom
win.contentView = web
win.orderBack(nil)
let scale = win.backingScaleFactor
let width = Int(points.width * scale), height = Int(points.height * scale)

let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("film-\(ProcessInfo.processInfo.processIdentifier)")
try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
let videoOnly = tmp.appendingPathComponent("video.mp4"), silence = tmp.appendingPathComponent("silence.m4a")

let writer = try! AVAssetWriter(outputURL: videoOnly, fileType: .mp4)
let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
  AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
  AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                              AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                              AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2],
  AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 12_000_000,
                                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                                    AVVideoExpectedSourceFrameRateKey: fps, AVVideoMaxKeyFrameIntervalKey: fps],
])
video.expectsMediaDataInRealTime = false
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
  kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width,
  kCVPixelBufferHeightKey as String: height])
writer.add(video)
writer.startWriting()
writer.startSession(atSourceTime: .zero)

func append(_ image: CGImage, at i: Int) {
  while !video.isReadyForMoreMediaData { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
  var buffer: CVPixelBuffer?
  CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
  CVPixelBufferLockBaseAddress(buffer!, [])
  let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer!), width: width, height: height, bitsPerComponent: 8,
                      bytesPerRow: CVPixelBufferGetBytesPerRow(buffer!), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
  ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
  CVPixelBufferUnlockBaseAddress(buffer!, [])
  adaptor.append(buffer!, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: fps))
}

// A silent stereo AAC file at least as long as the video, then video + silence into `out`.
@Sendable func addSilence() async throws {
  let file = try AVAudioFile(forWriting: silence, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000,
                                                              AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 256_000])
  let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 48000)!
  buffer.frameLength = 48000
  for c in 0..<Int(file.processingFormat.channelCount) { buffer.floatChannelData![c].update(repeating: 0, count: 48000) }
  for _ in 0...Int(duration) { try file.write(from: buffer) }
  file.close()

  let comp = AVMutableComposition()
  let videoAsset = AVURLAsset(url: videoOnly), audioAsset = AVURLAsset(url: silence)
  let range = CMTimeRange(start: .zero, duration: try await videoAsset.load(.duration))
  try comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
    .insertTimeRange(range, of: try await videoAsset.loadTracks(withMediaType: .video)[0], at: .zero)
  try comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
    .insertTimeRange(range, of: try await audioAsset.loadTracks(withMediaType: .audio)[0], at: .zero)
  try? FileManager.default.removeItem(at: out)
  let export = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetPassthrough)!
  try await export.export(to: out, as: out.pathExtension == "mov" ? .mov : .mp4)
}

func shoot(_ i: Int) {
  if i == frames {
    video.markAsFinished()
    writer.finishWriting {
      guard writer.status == .completed else { print("failed: \(String(describing: writer.error))"); exit(1) }
      Task {
        do { try await addSilence() } catch { print("audio: \(error)"); exit(1) }
        try? FileManager.default.removeItem(at: tmp)
        print("\(frames) frames, \(width)x\(height), \(duration) s")
        exit(0)
      }
    }
    return
  }
  if debug { FileHandle.standardError.write("frame \(i)\n".data(using: .utf8)!) }
  web.evaluateJavaScript("frame(\(Double(i) / Double(fps)))") { _, err in
    if let err { print("js: \(err)"); exit(1) }
    web.takeSnapshot(with: WKSnapshotConfiguration()) { img, err in
      var rect = NSRect(x: 0, y: 0, width: width, height: height)
      guard let img, let cg = img.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { print("snapshot failed: \(String(describing: err))"); exit(1) }
      append(cg, at: i)
      shoot(i + 1)
    }
  }
}

final class Nav: NSObject, WKNavigationDelegate {
  func webView(_ w: WKWebView, didFinish n: WKNavigation!) {
    // Give the images a moment to decode before the first frame.
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { shoot(0) }
  }
  func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) { print("fail \(e)"); exit(1) }
  func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) { print("fail \(e)"); exit(1) }
}
let nav = Nav()
web.navigationDelegate = nav
if url.isFileURL { web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent()) } else { web.load(URLRequest(url: url)) }
DispatchQueue.main.asyncAfter(deadline: .now() + 900) { print("timeout"); exit(1) }
app.run()
