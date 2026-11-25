import Foundation
import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers
import Vision

// Table windows are titled just the app name, same as the lobby (the "NLH ..." header
// is drawn inside the window). Tables open after the lobby, so prefer the newest
// (highest window ID) sizable window; a title naming a game still wins outright.
func windowScore(id: CGWindowID, title: String, size: CGSize) -> Double? {
    // "HUD Stats" is the player-stats panel (a separate window), never the table.
    guard !title.isEmpty, !title.contains("HUD"), size.width >= 300, size.height >= 200 else { return nil }
    return Double(id) + (title.contains("NLH") || title.contains("PLO") ? 1e9 : 0)
}

func pickWindow(_ windows: [SCWindow]) -> SCWindow? {
    var best: (SCWindow, Double)? = nil
    for w in windows where w.owningApplication?.applicationName.contains("Poker") == true && w.isOnScreen {
        guard let score = windowScore(id: w.windowID, title: w.title ?? "", size: w.frame.size) else { continue }
        if best == nil || score > best!.1 { best = (w, score) }
    }
    return best?.0
}

// Cheap CoreGraphics version of pickWindow, used by the 1s check to notice a newly opened table.
func preferredWindowID() -> CGWindowID? {
    guard let l = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return nil }
    var best: (CGWindowID, Double)? = nil
    for w in l where (w[kCGWindowOwnerName as String] as? String)?.contains("Poker") == true {
        guard let id = w[kCGWindowNumber as String] as? CGWindowID,
              let bd = w[kCGWindowBounds as String] as? [String: Any],
              let r = CGRect(dictionaryRepresentation: bd as CFDictionary),
              let score = windowScore(id: id, title: w[kCGWindowName as String] as? String ?? "", size: r.size) else { continue }
        if best == nil || score > best!.1 { best = (id, score) }
    }
    return best?.0
}

func windowBounds(_ id: CGWindowID) -> CGRect? {
    guard let l = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]],
          let w = l.first, (w[kCGWindowIsOnscreen as String] as? Bool) ?? false,
          let b = w[kCGWindowBounds as String] as? [String: Any] else { return nil }
    return CGRect(dictionaryRepresentation: b as CFDictionary)
}

// Fraction of red pixels in the Fold-button region: x 59%..72%, y 91%..99% (from top).
func redFraction(_ base: UnsafePointer<UInt8>, width: Int, height: Int, stride: Int) -> Double {
    let x0 = Int(0.59 * Double(width)), x1 = Int(0.72 * Double(width))
    let y0 = Int(0.91 * Double(height)), y1 = Int(0.99 * Double(height))
    guard x1 > x0, y1 > y0 else { return 0 }
    var red = 0
    for y in y0..<y1 {
        let row = base + y * stride
        for x in x0..<x1 {
            let p = row + x * 4           // BGRA
            if p[2] > 150 && p[1] < 90 && p[0] < 100 { red += 1 }
        }
    }
    return Double(red) / Double((x1 - x0) * (y1 - y0))
}
