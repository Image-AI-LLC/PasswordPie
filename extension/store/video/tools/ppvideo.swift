// Helper for the promo video recording (record.mjs). Compile: swiftc -O ppvideo.swift -o ppvideo
//
//   ppvideo key hotkey|return|tab        posts the keys as the keyboard would (HID tap); prints the epoch ms of key down
//   ppvideo type <text> <ms-per-char> [seed]
//                                        types text one character at a time; prints the epoch ms of the first and the
//                                        last key. With a seed, each gap varies between 60% and 140% of <ms-per-char>
//                                        (a fixed pseudo-random sequence), like a person typing.
//   ppvideo panel <pid> <timeout-ms>     waits for the PasswordPie panel (an on-screen window of <pid> above level 0)
//   ppvideo gone <pid> <timeout-ms>      waits until <pid> has no window above level 0 on screen
//   ppvideo activate <pid>               brings that process to the front
//   ppvideo machine                      prints the Mac's model, chip, memory and macOS version
//   ppvideo click <x> <y>                clicks at a screen point (top-left origin)
//   ppvideo record <out.mov> <fps> <pid,pid,...> <x,y,w,h>
//       records only the windows of those processes (ScreenCaptureKit), inside a rectangle in screen points
//       (top-left origin), at 2x. Nothing else on the screen (notifications, other apps, the menu bar) is captured.
//       Stops on SIGINT or when stdin closes.
import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

func nowMs() -> Double { Date().timeIntervalSince1970 * 1000 }
func ms(_ t: Double) -> String { String(format: "%.1f", t) }
func fail(_ s: String) -> Never { FileHandle.standardError.write((s + "\n").data(using: .utf8)!); exit(1) }

let source = CGEventSource(stateID: .hidSystemState)

func post(_ key: CGKeyCode, flags: CGEventFlags = []) -> Double {
  let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)!
  let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)!
  down.flags = flags
  up.flags = flags
  let t = nowMs()
  down.post(tap: .cghidEventTap)
  usleep(30_000)
  up.post(tap: .cghidEventTap)
  return t
}

func typeChar(_ ch: Character) {
  let units = Array(String(ch).utf16)
  for keyDown in [true, false] {
    let e = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: keyDown)!
    e.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
    e.post(tap: .cghidEventTap)
    if keyDown { usleep(25_000) }
  }
}

func panelBounds(_ pid: pid_t) -> CGRect? {
  let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
  for w in list where (w[kCGWindowOwnerPID as String] as? pid_t) == pid {
    guard let layer = w[kCGWindowLayer as String] as? Int, layer > 0,
          let alpha = w[kCGWindowAlpha as String] as? Double, alpha > 0.9,
          let b = w[kCGWindowBounds as String] as? [String: Double] else { continue }
    let r = CGRect(x: b["X"]!, y: b["Y"]!, width: b["Width"]!, height: b["Height"]!)
    if r.width >= 200 && r.height >= 100 { return r }
  }
  return nil
}

let args = CommandLine.arguments
guard args.count >= 2 else { fail("usage: see the top of ppvideo.swift") }

switch args[1] {
case "key":
  switch args[2] {
  case "hotkey": print(ms(post(42, flags: .maskCommand)))  // ⌘\
  case "return": print(ms(post(36)))
  case "tab": print(ms(post(48)))
  default: fail("unknown key")
  }
case "type":
  let mean = Double(args[3])!
  var seed = args.count > 4 ? UInt64(args[4])! : 0
  var first = 0.0, last = 0.0
  for (i, ch) in args[2].enumerated() {
    if i > 0 {
      var gap = mean
      if args.count > 4 {
        seed = (seed &* 6364136223846793005 &+ 1442695040888963407)
        gap = mean * (0.6 + 0.8 * Double(seed >> 11) / Double(1 << 53))
      }
      let wait = gap - (nowMs() - last)  // typeChar itself takes ~25 ms
      if wait > 0 { usleep(UInt32(wait * 1000)) }
    }
    last = nowMs()
    if i == 0 { first = last }
    typeChar(ch)
  }
  print(ms(first), ms(last))
case "panel", "gone":
  let pid = pid_t(args[2])!
  let deadline = nowMs() + Double(args[3])!
  while nowMs() < deadline {
    let b = panelBounds(pid)
    if args[1] == "panel", let b { print(ms(nowMs()), Int(b.minX), Int(b.minY), Int(b.width), Int(b.height)); exit(0) }
    if args[1] == "gone", b == nil { print(ms(nowMs())); exit(0) }
    usleep(5_000)
  }
  fail("timeout")
case "activate":
  guard let app = NSRunningApplication(processIdentifier: pid_t(args[2])!) else { fail("no such process") }
  app.activate(options: [])
case "machine":
  func sysctl(_ name: String) -> String {
    var size = 0
    sysctlbyname(name, nil, &size, nil, 0)
    var buf = [CChar](repeating: 0, count: size)
    sysctlbyname(name, &buf, &size, nil, 0)
    return String(cString: buf)
  }
  let gb = ProcessInfo.processInfo.physicalMemory / 1_073_741_824
  print("\(sysctl("hw.model")), \(sysctl("machdep.cpu.brand_string")), \(gb) GB, macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
case "click":
  let p = CGPoint(x: Double(args[2])!, y: Double(args[3])!)
  for type in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
    CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: .left)!.post(tap: .cghidEventTap)
    usleep(type == .leftMouseDown ? 80_000 : 30_000)
  }
case "record":
  let out = URL(fileURLWithPath: args[2])
  let fps = Int(args[3])!
  let pids = Set(args[4].split(separator: ",").map { pid_t($0)! })
  let r = args[5].split(separator: ",").map { Double($0)! }
  let rect = CGRect(x: r[0], y: r[1], width: r[2], height: r[3])
  let recorder = Recorder()
  Task {
    do { try await recorder.start(out: out, fps: fps, pids: pids, rect: rect) } catch { fail("record: \(error)") }
  }
  signal(SIGINT, SIG_IGN)
  let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
  sigint.setEventHandler { recorder.stop() }
  sigint.resume()
  DispatchQueue.global().async {
    while FileHandle.standardInput.availableData.count > 0 {}
    DispatchQueue.main.async { recorder.stop() }
  }
  RunLoop.main.run()
default:
  fail("unknown command")
}

final class Recorder: NSObject, SCRecordingOutputDelegate, SCStreamDelegate, @unchecked Sendable {
  var stream: SCStream?
  var stopping = false

  func start(out: URL, fps: Int, pids: Set<pid_t>, rect: CGRect) async throws {
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
    guard let display = content.displays.first(where: { $0.frame.contains(rect.origin) }) ?? content.displays.first
    else { fail("no display") }
    let apps = content.applications.filter { pids.contains($0.processID) }
    guard apps.count == pids.count else { fail("not every pid is a running app with windows: \(pids)") }
    let filter = SCContentFilter(display: display, including: apps, exceptingWindows: [])
    let config = SCStreamConfiguration()
    config.sourceRect = CGRect(x: rect.minX - display.frame.minX, y: rect.minY - display.frame.minY,
                               width: rect.width, height: rect.height)
    config.width = Int(rect.width * 2)
    config.height = Int(rect.height * 2)
    config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
    config.showsCursor = false
    config.capturesAudio = false
    config.queueDepth = 8
    config.backgroundColor = .black
    let stream = SCStream(filter: filter, configuration: config, delegate: self)
    let rc = SCRecordingOutputConfiguration()
    rc.outputURL = out
    rc.outputFileType = .mov
    rc.videoCodecType = .hevc
    let output = SCRecordingOutput(configuration: rc, delegate: self)
    try stream.addRecordingOutput(output)
    try await stream.startCapture()
    self.stream = stream
    print("recording \(ms(nowMs()))")
    fflush(stdout)
  }

  func stop() {
    guard !stopping, let stream else { if stream == nil { exit(1) }; return }
    stopping = true
    Task {
      try? await stream.stopCapture()
      try? await Task.sleep(nanoseconds: 300_000_000)
      print("stopped \(ms(nowMs()))")
      exit(0)
    }
  }

  func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: any Error) { fail("recording: \(error)") }
  func stream(_ stream: SCStream, didStopWithError error: any Error) { fail("stream: \(error)") }
}
