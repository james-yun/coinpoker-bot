import Foundation
import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers
import Vision

// Streams the poker table window with ScreenCaptureKit instead of spawning
// `screencapture` and round-tripping a PNG through disk every 0.7s. Frames arrive
// in-process as soon as the window changes, so a turn is detected within ~50ms.

// Usage: engine [output-dir] [--decide <command> | --manual] [--shadow] [--front] [--debug]
//   output-dir  where screenshots go (default /tmp/poker, created if missing)
//   --decide    decider command (default: decide.sh next to this binary)
//   --manual    no decider; only actions typed on stdin (and OPEN) are clicked
//   --accept-cashout  accept EV Cashout offers (default: reject them)
//   --no-session  ask the decider one-shot for every decision instead of one conversation per hand
//   --debug     log state changes with detector values, click points, and full decider output
var argv = Array(CommandLine.arguments.dropFirst())
func flag(_ name: String) -> Bool { defer { argv.removeAll { $0 == name } }; return argv.contains(name) }
let debug = flag("--debug")
let manual = flag("--manual")
let shadow = flag("--shadow")       // decide every spot but click nothing; record what you click instead
let acceptCashout = flag("--accept-cashout")
let stayFront = flag("--front")     // leave the table in front after clicking (default: give focus back)
let useSessions = !flag("--no-session")          // one model conversation per hand (see HandSession)   // default: reject EV Cashout offers (never worse in EV)
var decideCmd: String? = nil
if let i = argv.firstIndex(of: "--decide"), i + 1 < argv.count { decideCmd = argv[i + 1]; argv.removeSubrange(i...i + 1) }
if decideCmd == nil && !manual {
    let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let script = exe.deletingLastPathComponent().appendingPathComponent("decide.sh").path
    if FileManager.default.isExecutableFile(atPath: script) { decideCmd = "'\(script)'" }
}
// Card-template tools (see "card reading" below): --build-cards <labels.txt> <png-dir> <out.txt>,
// --read-cards <png>...
let cardTool = ["--build-cards", "--read-cards", "--read-preflop", "--results", "--read-hud", "--read-seats", "--context", "--selftest"].contains(argv.first ?? "")
let out = cardTool ? "" : argv.first ?? "/tmp/poker"
// Each run saves into its own folder named by start time, so runs never overwrite or mix:
// <out>/2026-11-22_095332/h007_flop_turn.png (+ .txt with the cards and the decider's answer).
// cur.png (latest frame) stays directly in <out>.
let runDir: String = {
    guard !cardTool else { return "" }
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd_HHmmss"
    let dir = out + "/" + f.string(from: Date())
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}()
let fps: Int32 = 20                 // max frame rate; SCK only delivers frames when the window changes
let redThreshold = 0.35
let offGrace = 0.3                  // seconds the button must be gone before a new turn can trigger
let curInterval = 0.7               // how often cur.png is refreshed
let titleBarHeight = 28.0           // points cropped off the top of saved PNGs (the table's title bar)

let clock: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f }()
// In --debug, every line gets a wall-clock timestamp to line it up with the timer and the screenshots.
func log(_ s: String) { print(debug ? "\(clock.string(from: Date())) \(s)" : s); fflush(stdout) }

if cardTool { runCardTool(argv); exit(0) }

signal(SIGPIPE, SIG_IGN)   // a decider that exits early must not kill the engine on the next write
_ = NSApplication.shared   // connects to the window server (required by ScreenCaptureKit in a CLI)
// Posting clicks needs Accessibility permission; this prompts for it the first time.
if !AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary) {
    log("ENGINE: grant Accessibility permission to click (System Settings → Privacy & Security → Accessibility)")
}
log("ENGINE: saving to \(runDir); " + (decideCmd.map { "decider \($0)" } ?? "manual mode (type actions)"))
let engine = Monitor()
// Typing an action on stdin (e.g. "call", "50", "fold") clicks it on the current table.
FileHandle.standardInput.readabilityHandler = { h in
    let d = h.availableData
    if d.isEmpty { h.readabilityHandler = nil; return }
    for line in String(decoding: d, as: UTF8.self).split(whereSeparator: \.isNewline) where !line.trimmingCharacters(in: .whitespaces).isEmpty {
        let a = String(line)
        DispatchQueue.main.async { act(a, windowID: engine.windowID) }
    }
}
if shadow {
    onUserClick = { p in engine.sampleQueue.async { engine.userClick(p) } }
    log(startClickWatcher() ? "ENGINE: shadow mode: deciding every spot, clicking nothing; recording your clicks to shadow.tsv"
                            : "ENGINE: shadow mode, but your clicks can't be watched (allow the terminal under Input Monitoring)")
}
signal(SIGINT, SIG_IGN)
let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigint.setEventHandler { engine.finish() }
sigint.resume()
engine.findAndStart()
let timer = DispatchSource.makeTimerSource(queue: .main)
timer.schedule(deadline: .now() + 1, repeating: 1)
timer.setEventHandler { engine.check() }
timer.resume()
dispatchMain()
