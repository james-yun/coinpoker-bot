import Foundation
import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers
import Vision

// MARK: shadow mode
//
// With --shadow the engine decides every spot as usual but clicks nothing (not even OPEN); you play,
// and a listen-only event tap records which table button you click. shadow.tsv in the run folder gets
// one line per decision from each side ("bot<TAB>tag<TAB>action", "you<TAB>tag<TAB>action"), which
// shadow_report.py compares.
func shadowLog(_ fields: [String]) {
    let line = fields.map { $0.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") }.joined(separator: "\t") + "\n"
    writeQueue.async {
        let path = runDir + "/shadow.tsv"
        if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
        if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile() }
    }
}

var onUserClick: ((CGPoint) -> Void)?
var clickTap: CFMachPort?

// Left clicks anywhere (listen-only, from other processes), on a thread with its own run loop.
func startClickWatcher() -> Bool {
    let mask = CGEventMask(1 << CGEventType.leftMouseDown.rawValue)
    guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
                                      eventsOfInterest: mask, callback: { _, type, event, _ in
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let t = clickTap { CGEvent.tapEnable(tap: t, enable: true) }
        } else if type == .leftMouseDown, event.getIntegerValueField(.eventSourceUnixProcessID) != Int64(getpid()) {
            onUserClick?(event.location)
        }
        return Unmanaged.passUnretained(event)
    }, userInfo: nil) else { return false }
    clickTap = tap
    let src = CFMachPortCreateRunLoopSource(nil, tap, 0)
    Thread {
        CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        CFRunLoopRun()
    }.start()
    return true
}
