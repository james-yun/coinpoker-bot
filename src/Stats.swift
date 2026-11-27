import Foundation
import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers
import Vision

// MARK: player stats
//
// Clicking a seat's name plate opens the client's "HUD Stats" window for that player: a Game Stats tab
// (VPIP, PFR, 3-bet, ... WTSD, WSD) and a Showdown tab whose showdown count tells how big the sample is.
// Whenever it isn't our turn the engine opens each seated player's stats once (kept a day in players.tsv),
// reads them with text recognition and closes the window; the model gets the stats of the players
// still in the hand.
let namePlates: [CGPoint] = [.zero,                                    // seat 0 is us
    CGPoint(x: 0.119, y: 0.680), CGPoint(x: 0.139, y: 0.268), CGPoint(x: 0.500, y: 0.184),
    CGPoint(x: 0.861, y: 0.268), CGPoint(x: 0.881, y: 0.680)]         // content fractions
// Points in the stats window, as fractions of the whole window (title bar included).
let hudStatsTab = CGPoint(x: 0.251, y: 0.207), hudShowdownTab = CGPoint(x: 0.751, y: 0.207), hudClose = CGPoint(x: 0.954, y: 0.029)
let statLabels = ["VPIP", "PFR", "3bet", "fold to 3bet", "cbet", "fold to cbet", "steal", "check-raise", "WTSD", "WSD"]
let clickLock = NSLock()            // the stats scanner and the actions never click at the same time

struct PlayerStats {
    var name: String
    var values: [Int] = []          // statLabels order
    var showdowns: Int? = nil
    var read = 0.0
    var summary: String {
        let v = zip(statLabels, values).map { "\($0) \($1)" }.joined(separator: ", ")
        let n = showdowns.map { $0 < 30 ? " (only \($0) showdowns: rough)" : " (\($0) showdowns)" } ?? ""
        return "\(name): \(v)\(n)"
    }
}

// Stats are kept in <output dir>/players.tsv for a day, so a restart doesn't open every player again
// (they cover the last 15 days, so they barely change in a day). Lines: name, unix time, values, showdowns.
let playersFile = (out.isEmpty ? NSHomeDirectory() + "/pokerbot-runs" : out) + "/players.tsv"   // the card tools read the default

func loadPlayerStats(maxAge: Double = 86_400) -> [String: PlayerStats] {
    guard let text = try? String(contentsOfFile: playersFile, encoding: .utf8) else { return [:] }
    var all: [String: PlayerStats] = [:]
    for line in text.split(whereSeparator: \.isNewline) {
        let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard f.count == 4, let t = Double(f[1]), Date().timeIntervalSince1970 - t < maxAge else { continue }
        let v = f[2].split(separator: ",").compactMap { Int($0) }
        guard v.count == statLabels.count else { continue }
        all[nameKey(f[0])] = PlayerStats(name: f[0], values: v, showdowns: Int(f[3]), read: 0)   // later lines win
    }
    return all
}

func savePlayerStats(_ st: PlayerStats) {
    let line = "\(st.name)\t\(Int(Date().timeIntervalSince1970))\t\(st.values.map(String.init).joined(separator: ","))\t\(st.showdowns.map(String.init) ?? "")\n"
    if !FileManager.default.fileExists(atPath: playersFile) { FileManager.default.createFile(atPath: playersFile, contents: nil) }
    if let h = FileHandle(forWritingAtPath: playersFile) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile() }
}

// The stats line for the model: players in seats still holding cards, by the name on their plate.
func statsSummary(_ f: Frame, names: [Int: String], lookup: (String) -> PlayerStats?) -> String {
    let lines = (1..<6).filter { f.hasCardBacks($0) }.compactMap { names[$0].flatMap(lookup)?.summary }
    return lines.isEmpty ? "" : " Opponent stats (% over the last 15 days): " + lines.joined(separator: "; ") + "."
}

// The price of a call, read off the table: the Call button's amount and the pot (which already
// includes every bet on the table). The model misjudged bet sizes from the picture (a 74%-pot bet
// read as under half pot, because the pot shown already holds the bet).
let callBox = CGRect(x: 0.735, y: 0.915, width: 0.12, height: 0.08)

// `raised`: we bet this street (our tag shows RAISE/BET), so this is a raise of our bet, which is
// far stronger than a bet and is said so; its size relative to the pot means little then.
func facingLine(_ img: CGImage, raised: Bool = false, preflop: Bool = false) -> String {
    let call = digitFix(textLines(img, callBox).map(\.text).joined(separator: " "))
    guard call.lowercased().contains("call"),
          let m = call.range(of: #"[0-9][0-9,]*(\.[0-9]+)?"#, options: .regularExpression),
          let x = Double(call[m].replacingOccurrences(of: ",", with: "")), x > 0,
          let pot = readAmount(img, potBox), pot > x else { return "" }
    func f(_ v: Double) -> String { String(format: "%.2f", v) }
    if raised || preflop {                 // (preflop, a raise's size against the blinds says little)
        return String(format: raised ? " Facing a raise of your bet: call %@ into a pot of %@ (bets included), so you need %.0f%% equity." : " Facing a raise: call %@ into a pot of %@ (bets included), so you need %.0f%% equity.",
                      f(x), f(pot), x / (pot + x) * 100)
    }
    return String(format: " Facing a bet: call %@ into a pot of %@ (bets included), so you need %.0f%% equity; the bet is about %.0f%% of the pot before it.",
                  f(x), f(pot), x / (pot + x) * 100, x / (pot - x) * 100)
}

// Names compared without case, punctuation or emoji; the table cuts long names ("LongNameExam...").
// Lookalike letters (a Cyrillic "О" in a name the stats window spells with a Latin "O") count as the same.
func nameKey(_ s: String) -> String {
    let latin = (s.applyingTransform(.toLatin, reverse: false) ?? s).folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
    // Text recognition mixes up I, l, | and 1, and O and 0 ("Dani3I09205", "Dani3l09205", "Dani3|09205"):
    // each group counts as one character.
    let same: [Character: Character] = ["i": "l", "|": "l", "1": "l", "!": "l", "0": "o"]
    return String(latin.lowercased().map { same[$0] ?? $0 }.filter { $0.isLetter || $0.isNumber })
}
func sameName(_ a: String, _ b: String) -> Bool {
    let x = nameKey(a), y = nameKey(b)
    return x.count >= 3 && y.count >= 3 && (x == y || x.hasPrefix(y) || y.hasPrefix(x))
}

// A seat's name, read off its name plate.
func seatName(_ img: CGImage, _ seat: Int) -> String? {
    let c = namePlates[seat]
    let t = textLines(img, CGRect(x: c.x - 0.08, y: c.y - 0.02, width: 0.16, height: 0.04)).map(\.text).joined(separator: " ")
    return nameKey(t).count >= 3 ? t.trimmingCharacters(in: .whitespaces) : nil
}

// What the stats window shows: the player's name, and the stats or the showdown count (whichever tab is open).
func parseHud(_ lines: [(text: String, x: Double, y: Double)]) -> (name: String?, values: [Int]?, showdowns: Int?) {
    let name = lines.filter { $0.y > 0.08 && $0.y < 0.15 }.min { $0.x < $1.x }?.text
    var values: [Int]? = nil
    if lines.contains(where: { $0.text.contains("VPIP") }) {
        // ten percentages in three rows (4, 4, 2), read row by row, left to right
        let pct = lines.filter { $0.text.range(of: #"^[0-9]{1,3} ?%$"#, options: .regularExpression) != nil }.sorted { $0.y < $1.y }
        var rows: [[(text: String, x: Double, y: Double)]] = []
        for l in pct { if let last = rows.last?.last, l.y - last.y < 0.03 { rows[rows.count - 1].append(l) } else { rows.append([l]) } }
        let v = rows.flatMap { $0.sorted { $0.x < $1.x } }.compactMap { Int($0.text.filter(\.isNumber)) }
        if v.count == statLabels.count { values = v }
    }
    var showdowns: Int? = nil
    if let label = lines.first(where: { $0.text.hasPrefix("Showdowns") }) {
        showdowns = lines.filter { abs($0.x - label.x) < 0.1 && label.y - $0.y > 0 && label.y - $0.y < 0.08 }
            .compactMap { Int($0.text.filter(\.isNumber)) }.first
    }
    return (name, values, showdowns)
}

func hudWindow() -> (id: CGWindowID, bounds: CGRect)? {
    guard let l = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return nil }
    for w in l where (w[kCGWindowOwnerName as String] as? String)?.contains("Poker") == true && (w[kCGWindowName as String] as? String) == "HUD Stats" {
        if let id = w[kCGWindowNumber as String] as? CGWindowID, let bd = w[kCGWindowBounds as String] as? [String: Any],
           let r = CGRect(dictionaryRepresentation: bd as CFDictionary) { return (id, r) }
    }
    return nil
}

// One screenshot of a window (at 2x), waiting up to 2s.
func captureWindow(_ id: CGWindowID) -> CGImage? {
    let done = DispatchSemaphore(value: 0)
    var out: CGImage?
    SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: true) { content, _ in
        guard let w = content?.windows.first(where: { $0.windowID == id }) else { done.signal(); return }
        let cfg = SCStreamConfiguration()
        cfg.width = Int(w.frame.width * 2); cfg.height = Int(w.frame.height * 2)
        cfg.scalesToFit = true; cfg.showsCursor = false
        SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: w), configuration: cfg) { img, _ in
            out = img; done.signal()
        }
    }
    _ = done.wait(timeout: .now() + 2)
    return out
}

// Clicks a point given as fractions of a rectangle on screen, unless another window covers it.
func clickIn(_ r: CGRect, _ f: CGPoint, above id: CGWindowID? = nil) -> Bool {
    let pt = CGPoint(x: r.minX + f.x * r.width, y: r.minY + f.y * r.height)
    if let id, coveredByOtherWindow(pt, above: id) { return false }
    clickLock.lock(); defer { clickLock.unlock() }
    let focusOwner = frontmostPid()
    let restore = CGEvent(source: nil)?.location
    click(at: pt)
    if let restore { CGWarpMouseCursorPosition(restore) }
    giveBackFocus(focusOwner)
    return true
}
