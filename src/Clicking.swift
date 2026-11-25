import Foundation
import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers
import Vision

// MARK: clicking

// Button centers as fractions of the saved screenshot (the window minus its title bar),
// so they can be measured straight off a turnN.png. Presets set the amount; Raise submits it.
let buttons: [String: (x: Double, y: Double)] = [
    "fold":  (0.659, 0.952),
    "call":  (0.795, 0.952),    // also Check
    "raise": (0.930, 0.952),    // also Bet
    "33":    (0.623, 0.872),
    "50":    (0.674, 0.872),
    "75":    (0.726, 0.872),
    "max":   (0.776, 0.872),
    // Pre-moves, shown while it's someone else's turn. X/F and Check sit where Fold and Call do,
    // so "fold"/"check" also work then. They toggle: clicking twice unsets them.
    "xf":      (0.662, 0.958),
    "callany": (0.797, 0.879),
    // Card-squeeze overlay shown when cards are dealt; the engine clicks this by itself.
    "open":    (0.781, 0.945),
    // EV Cashout dialog after an all-in; handled by the engine itself.
    "reject":  (0.664, 0.949),
    "accept":  (0.922, 0.949),
]
// Preflop when opening, the four sizing buttons read 2X 2.5X 3X 4X instead of 33% 50% 75% Max;
// they sit in the same spots, so map those labels onto the same buttons. ("2.5x" normalizes to "25x".)
let aliases = ["check": "call", "bet": "raise", "min": "raise", "allin": "max", "all-in": "max", "shove": "max",
               "x/f": "xf", "checkfold": "xf", "2x": "33", "25x": "50", "3x": "75", "4x": "max"]

// Returns the clicks for an action word, e.g. "50" -> 50% preset then Raise.
func clicks(for action: String) -> [String]? {
    // Tolerate model output like "**Call Any**" or "50%": keep only letters, digits and '/'.
    // If the whole line isn't an action (reasoning on the same line), use its last word.
    func norm(_ t: Substring) -> String {
        let a = String(t.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "/" })
        return aliases[a] ?? a
    }
    let whole = norm(Substring(action))
    guard let a = buttons[whole] != nil ? whole : action.split(whereSeparator: \.isWhitespace).last.map(norm),
          buttons[a] != nil else { return nil }
    return ["fold", "call", "raise", "xf", "callany", "open", "reject", "accept"].contains(a) ? [a] : [a, "raise"]
}

// The action word the answer names, before aliases ("2.5X" -> "25x", "Raise" -> "raise").
func actionToken(_ action: String) -> String? {
    func norm(_ t: Substring) -> String { String(t.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "/" }) }
    func valid(_ t: String) -> Bool { buttons[aliases[t] ?? t] != nil }
    let whole = norm(Substring(action))
    if valid(whole) { return whole }
    if let last = action.split(whereSeparator: \.isWhitespace).last.map(norm), valid(last) { return last }
    return nil
}

// Matches a sizing answer to the labels actually on screen (see Frame.presetKind). The buttons sit
// in the same four spots either way, so naming a size that isn't shown would click the wrong one:
// "4x" with 33%/50%/75%/Max showing would click Max, an all-in.
func fitToPresets(_ token: String, kind: String) -> (token: String, note: String?) {
    let multiplier = ["2x": "raise", "25x": "33", "3x": "50", "4x": "75"]   // their nearest percent-mode play
    let allIn = ["max", "allin", "shove"]
    switch kind {
    case "percent" where multiplier[token] != nil:
        return (multiplier[token]!, "\(token) isn't shown (33/50/75/Max are), using \(multiplier[token]!)")
    case "multiplier" where allIn.contains(token):
        return ("4x", "no all-in button preflop (2X-4X shown), using 4x")
    case "none" where !["fold", "call", "check", "xf"].contains(token):
        return ("call", "no raise buttons (facing an all-in), calling instead of \(token)")
    default:
        return (token, nil)
    }
}

func click(at p: CGPoint) {
    let src = CGEventSource(stateID: .hidSystemState)
    for t in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
        CGEvent(mouseEventSource: src, mouseType: t, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
        usleep(30_000)
    }
}

// True if an on-screen window stacked above the table contains the point: a click there would go
// to that window (e.g. after switching to another app), not the table.
func coveredByOtherWindow(_ pt: CGPoint, above id: CGWindowID) -> Bool {
    guard let l = CGWindowListCopyWindowInfo([.optionOnScreenAboveWindow], id) as? [[String: Any]] else { return false }
    for w in l {
        guard (w[kCGWindowLayer as String] as? Int) == 0,                       // normal windows, not the menu bar etc.
              ((w[kCGWindowAlpha as String] as? Double) ?? 1) > 0.05,
              let bd = w[kCGWindowBounds as String] as? [String: Any],
              let r = CGRect(dictionaryRepresentation: bd as CFDictionary) else { continue }
        if r.contains(pt) { return true }
    }
    return false
}

// Brings the poker app forward and raises the table window (via Accessibility, which clicking
// already needs), so the game is visible whenever the bot acts and clicks land on the table.
func bringToFront(_ id: CGWindowID, bounds b: CGRect) {
    guard let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]])?.first,
          let pid = info[kCGWindowOwnerPID as String] as? pid_t else { return }
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &ref) == .success,
          let windows = ref as? [AXUIElement] else { return }
    for w in windows {
        var pos: CFTypeRef?, size: CFTypeRef?
        var p = CGPoint.zero, sz = CGSize.zero
        guard AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &pos) == .success,
              AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &size) == .success,
              AXValueGetValue(pos as! AXValue, .cgPoint, &p), AXValueGetValue(size as! AXValue, .cgSize, &sz) else { continue }
        if abs(p.x - b.minX) < 2 && abs(p.y - b.minY) < 2 && abs(sz.width - b.width) < 2 {
            AXUIElementPerformAction(w, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(w, kAXMainAttribute as CFString, kCFBooleanTrue)
        }
    }
}

// The app that owns the frontmost normal window (the window list runs front to back), and handing
// it back the focus after our clicks: the table's clicks must be real mouse clicks (it ignores
// events posted to its process), which brings the poker client forward; this returns the keyboard
// to whatever you were using within about 0.2s. The cursor is already put back.
func frontmostPid() -> pid_t? {
    let l = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    return l.first { ($0[kCGWindowLayer as String] as? Int) == 0 }?[kCGWindowOwnerPID as String] as? pid_t
}

func giveBackFocus(_ pid: pid_t?) {
    guard !stayFront, let pid, pid != getpid(),
          let app = NSRunningApplication(processIdentifier: pid), !(app.localizedName ?? "").contains("Poker") else { return }
    AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
}

// Window bounds that are the same on two reads one screen refresh (16ms) apart (tries for ~0.5s).
func stableBounds(_ id: CGWindowID) -> CGRect? {
    var last = windowBounds(id)
    for _ in 0..<30 {
        usleep(16_000)
        let b = windowBounds(id)
        if let b, b == last { return b }
        last = b
    }
    return nil
}

func act(_ action: String, windowID: CGWindowID, tag: String = "", presets: String = "") {
    let label = tag.isEmpty ? "ACT" : "ACT (\(tag))"
    var action = action
    if !presets.isEmpty, let token = actionToken(action) {
        let fit = fitToPresets(token, kind: presets)
        if let note = fit.note { log("\(label): \(note)") }
        action = fit.token
    }
    guard let seq = clicks(for: action) else { log("\(label): unknown action '\(action)'"); return }
    if shadow {                         // the bot's choice is recorded, you do the clicking
        if !tag.isEmpty { log("SHADOW (\(tag)): bot \(seq.joined(separator: " -> "))"); shadowLog(["bot", tag, seq.joined(separator: " ")]) }
        return
    }
    // The window must hold still: while it's being dragged or reopened its bounds jump around, and
    // clicks computed from a stale position landed on other windows and displays.
    guard let b = stableBounds(windowID) else { log("\(label): table window moving or gone, skipped"); return }
    clickLock.lock(); defer { clickLock.unlock() }
    let focusOwner = frontmostPid()
    defer { giveBackFocus(focusOwner) }
    // With the stats window open (and maybe focused), the first click on the table would only focus it.
    if hudWindow() != nil { bringToFront(windowID, bounds: b); usleep(50_000) }
    let restore = CGEvent(source: nil)?.location
    for name in seq {
        let f = buttons[name]!
        let top = b.minY + titleBarHeight
        let pt = CGPoint(x: b.minX + f.x * b.width, y: top + f.y * (b.maxY - top))
        var displays: UInt32 = 0
        CGGetDisplaysWithPoint(pt, 0, nil, &displays)
        // Covered by another window (you switched apps): bring the table forward first.
        if coveredByOtherWindow(pt, above: windowID) {
            bringToFront(windowID, bounds: b)
            for _ in 0..<20 where coveredByOtherWindow(pt, above: windowID) { usleep(15_000) }
            log("\(label): brought the table to the front")
        }
        guard displays > 0, windowBounds(windowID) == b, !coveredByOtherWindow(pt, above: windowID) else {
            log("\(label): table moved or still covered, skipped \(name)")
            if let restore { CGWarpMouseCursorPosition(restore) }
            return
        }
        if debug { log("DEBUG: click \(name) at (\(Int(pt.x)), \(Int(pt.y)))") }
        click(at: pt)
        usleep(150_000)   // let the client register the preset before submitting
    }
    if let restore { CGWarpMouseCursorPosition(restore) }
    log("\(label): \(seq.joined(separator: " -> "))")
}
