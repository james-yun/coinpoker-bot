import Foundation
import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers
import Vision

// MARK: preflop charts
//
// Preflop decisions come from solved charts (preflop_charts.json, made with GTOpen's preflop
// solver: 100bb, no rake, 2.5bb opens, 3x re-raises, for 2-6 players) instead of the model,
// whenever the spot is one the charts cover: folded to us, facing a single open, or facing a 3-bet
// after we opened. Anything else (limpers, cold-callers, all-ins) still goes to the decider.
//
// The table is read from fixed seat spots. Each player's last action shows as a colored tag on
// their avatar (SB/BB blue, CALL/CHECK green, RAISE orange, ALL-IN red, FOLD dark); players still
// in the hand show red card backs. Seats are listed clockwise from us.

enum SeatTag: String { case none, blind, call, raise, allin, fold }

struct SeatSpot {
    let tag: (Double, Double, Double, Double)     // left part of the tag (fits the short SB/BB tags too)
    let cards: (Double, Double, Double, Double)   // where face-down card backs show
    let dealer: (Double, Double)                  // where the D button sits when it's this seat's
}

let seatSpots: [SeatSpot] = [
    SeatSpot(tag: (0.435, 0.455, 0.822, 0.842), cards: (0.44, 0.56, 0.73, 0.83), dealer: (0.422, 0.709)),   // us
    SeatSpot(tag: (0.055, 0.075, 0.633, 0.653), cards: (0.055, 0.183, 0.592, 0.630), dealer: (0.191, 0.536)), // bottom-left
    SeatSpot(tag: (0.078, 0.098, 0.224, 0.240), cards: (0.071, 0.202, 0.180, 0.218), dealer: (0.222, 0.362)), // top-left
    SeatSpot(tag: (0.438, 0.458, 0.140, 0.157), cards: (0.430, 0.567, 0.097, 0.135), dealer: (0.582, 0.221)), // top
    SeatSpot(tag: (0.803, 0.823, 0.224, 0.240), cards: (0.816, 0.944, 0.180, 0.218), dealer: (0.777, 0.362)), // top-right
    SeatSpot(tag: (0.819, 0.839, 0.633, 0.653), cards: (0.817, 0.945, 0.592, 0.630), dealer: (0.808, 0.537)), // bottom-right
]

extension Frame {
    func seatTag(_ i: Int) -> SeatTag {
        let (x0, x1, y0, y1) = seatSpots[i].tag
        let tests: [(SeatTag, (Int, Int, Int) -> Bool)] = [
            (.allin, { r, g, b in r > 180 && g < 70 && b < 70 }),
            (.raise, { r, g, b in r > 190 && g > 90 && g < 170 && b < 80 }),
            (.blind, { r, g, b in b > 170 && r < 90 && g < 160 }),
            (.call, { r, g, b in g > 110 && r < 45 && b < 150 && g > b }),
            (.fold, { r, g, b in r < 45 && g > 45 && g < 95 && b > 45 && b < 95 }),
        ]
        // Colored tags are only part color: their white lettering ("RAISE", "CALL", "BB") fills much of
        // the box, leaving ~20-35% color at small window sizes. So a colored tag needs 18% color plus
        // that white lettering; FOLD (gray lettering on dark) keeps a plain 35% bar.
        let white = fraction(x0, x1, y0, y1) { r, g, b in r > 200 && g > 200 && b > 200 }
        var best = (SeatTag.none, 0.0)
        for (t, test) in tests {
            let f = fraction(x0, x1, y0, y1, test)
            let ok = t == .fold ? f > 0.35 : f > 0.18 && white >= 0.06
            if ok && f > best.1 { best = (t, f) }
        }
        // (The white-lettering check also keeps bare felt, the same green as CALL/CHECK, from counting.)
        return best.0
    }
    func hasCardBacks(_ i: Int) -> Bool {
        let (x0, x1, y0, y1) = seatSpots[i].cards
        return fraction(x0, x1, y0, y1) { r, g, b in r > 100 && r < 180 && g < 80 && b > 45 && b < 120 && r > b + 30 } > 0.08
    }
    // The seat whose D spot has the most of the button's bright red.
    var dealerSeat: Int {
        var best = (0, -1.0)
        for (i, s) in seatSpots.enumerated() {
            let f = fraction(s.dealer.0 - 0.015, s.dealer.0 + 0.015, s.dealer.1 - 0.02, s.dealer.1 + 0.02) { r, g, b in
                r > 140 && g < 80 && b < 80 && r > g + 70 }
            if f > best.1 { best = (i, f) }
        }
        return best.1 > 0.10 ? best.0 : -1
    }
}

// Chart positions in preflop order for a table of n players dealt in.
func chartPositions(_ n: Int) -> [String] {
    n == 2 ? ["SB", "BB"] : Array(["UTG", "HJ", "CO", "BTN", "SB", "BB"].suffix(n))
}

// Facing one raise, the chart assumes a balanced opener. Against a loose one (PFR 26+ or steal 45+,
// over 30+ showdowns) it plays the chart for an opener one seat later (up to the button), whose range is wider, so it
// calls and 3-bets more; against a tight one (PFR 14- and steal 25-) one seat earlier, so it folds more.
func adjustForOpener(_ pf: inout PreflopRead, _ st: PlayerStats?) -> String? {
    guard let key = pf.key, key.hasPrefix("VO:"), let st, (st.showdowns ?? 0) >= 30, st.values.count == statLabels.count else { return nil }
    let pfr = st.values[1], steal = st.values[6]
    let shift = pfr >= 26 || steal >= 45 ? 1 : pfr <= 14 && steal <= 25 ? -1 : 0
    let parts = key.split(separator: ":").map(String.init), order = chartPositions(pf.players)
    // only among UTG..BTN: a small-blind open is blind vs blind (the BB has position), not just a wider range
    guard shift != 0, let i = order.firstIndex(of: parts[2]), order.indices.contains(i + shift),
          !["SB", "BB"].contains(order[i + shift]), !["SB", "BB"].contains(parts[2]) else { return nil }
    let newKey = "VO:\(parts[1]):\(order[i + shift])"
    guard preflopCharts["\(pf.players)"]?[newKey] != nil else { return nil }
    pf.key = newKey
    let note = "\(st.name) opens \(shift > 0 ? "loose" : "tight") (PFR \(pfr), steal \(steal)): playing \(key) as \(newKey)"
    pf.why += "; " + note
    return note
}

struct PreflopRead {
    var key: String? = nil          // chart spot, e.g. "VO:BTN:CO"; nil when the charts don't cover it
    var hero = "?"                  // our position
    var players = 0
    var raiserSeat: Int? = nil      // seat of the opener (VO) or the 3-bettor (V3)
    var why = ""                    // what was read, for logs
}

// Every dealt seat's position (UTG, HJ, ..., BB) from the button and the seats dealt in: a seat is
// in if it's us or shows a tag or card backs. Read it on the hand's first preflop screenshot.
func seatPositions(_ f: Frame) -> [Int: String]? {
    let dealt = (0..<6).map { $0 == 0 || f.seatTag($0) != .none || f.hasCardBacks($0) }
    let button = f.dealerSeat, players = dealt.filter { $0 }.count
    guard button >= 0, dealt[button], players >= 2 else { return nil }
    let fromSB = (1...6).map { (button + $0) % 6 }.filter { dealt[$0] }
    let order = players == 2 ? [button, fromSB[0]] : Array(fromSB[2...]) + [fromSB[0], fromSB[1]]
    return Dictionary(uniqueKeysWithValues: zip(order, chartPositions(players)))
}

func readPreflop(_ f: Frame) -> PreflopRead {
    var r = PreflopRead()
    let tags = (0..<6).map { f.seatTag($0) }
    let dealt = (0..<6).map { $0 == 0 || tags[$0] != .none || f.hasCardBacks($0) }
    let button = f.dealerSeat
    r.players = dealt.filter { $0 }.count
    r.why = "tags " + tags.map(\.rawValue).joined(separator: ",") + "; button seat \(button)"
    guard button >= 0, dealt[button], r.players >= 2 else { r.why += "; no button/players"; return r }
    // dealt-in seats clockwise from the button's left (SB first), then preflop order UTG..BTN, SB, BB
    let fromSB = (1...6).map { (button + $0) % 6 }.filter { dealt[$0] }
    let order = r.players == 2 ? [button, fromSB[0]] : Array(fromSB[2...]) + [fromSB[0], fromSB[1]]
    let names = chartPositions(r.players)
    let pos = Dictionary(uniqueKeysWithValues: zip(order, names))
    r.hero = pos[0] ?? "?"
    let others = (1..<6).filter { dealt[$0] }
    let raisers = others.filter { tags[$0] == .raise }
    let callers = others.filter { tags[$0] == .call }
    if others.contains(where: { tags[$0] == .allin }) { r.why += "; all-in"; return r }
    if tags[0] == .raise {
        if raisers.count == 1 && callers.isEmpty { r.key = "V3:\(r.hero):\(pos[raisers[0]]!)"; r.raiserSeat = raisers[0] }
    } else if raisers.isEmpty && callers.isEmpty {
        r.key = "RFI:\(r.hero)"
    } else if raisers.count == 1 && callers.isEmpty {
        r.key = "VO:\(r.hero):\(pos[raisers[0]]!)"
        r.raiserSeat = raisers[0]
    }
    if r.key == nil { r.why += "; raisers \(raisers.count), callers \(callers.count)" }
    return r
}

// charts[table size][spot] = (action labels, hand class -> frequencies)
let preflopCharts: [String: [String: (actions: [String], hands: [String: [Double]])]] = {
    let path = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        .deletingLastPathComponent().appendingPathComponent("preflop_charts.json").path
    guard let data = FileManager.default.contents(atPath: path),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: [String: [String: Any]]] else { return [:] }
    return json.mapValues { spots in
        spots.compactMapValues { spot in
            guard let actions = spot["actions"] as? [String], let hands = spot["hands"] as? [String: [Double]] else { return nil }
            return (actions, hands)
        }
    }
}()

// "Your cards: A♥ T♦ (offsuit)…" -> "ATo"
func handClass(_ cards: [String: String]) -> String? {
    guard let a = cards["h0"], let b = cards["h1"] else { return nil }
    let ranks = "AKQJT98765432"
    let ra = String(a.dropLast()), rb = String(b.dropLast())
    // A pair doesn't need its suits; anything else does (suited vs offsuit).
    guard ra != "?", rb != "?", ra == rb || (a.last != "?" && b.last != "?") else { return nil }
    guard let ia = ranks.firstIndex(of: Character(ra)), let ib = ranks.firstIndex(of: Character(rb)) else { return nil }
    let (hi, lo) = ia <= ib ? (ra, rb) : (rb, ra)
    if ra == rb { return ra + rb }
    return hi + lo + (a.last == b.last ? "s" : "o")
}

struct ChartPlay { let action: String; let summary: String }

// One line for the model postflop, since the charts (not the model's conversation) played preflop.
func preflopSummary(_ r: PreflopRead, _ action: String) -> String {
    guard let key = r.key else { return "" }
    let parts = key.split(separator: ":").map(String.init)
    let before = parts[0] == "RFI" ? "it was folded to you" :
        parts[0] == "VO" ? "\(parts[2]) opened" : "you opened and \(parts[2]) 3-bet"
    let did = ["fold": "folded", "call": "called", "max": "went all-in"][action] ?? "raised"
    return "Preflop (\(r.players)-handed): you were \(r.hero), \(before), and you \(did)."
}

// The chart's play for our hand, drawn by its frequencies (mixed strategies stay mixed).
// Raises: opens use the 2.5X button; re-raises the 75% button (about 3x the last raise).
// Mixed spots lean aggressive (a LAG style, as you play): the chart's raise is taken whenever its
// frequency is at least `raiseAt` (15%; 5% against an opener who folds to 3-bets 55%+), otherwise the
// play is sampled. From the small blind facing a raise it's 3-bet or fold: a chart call becomes a 3-bet.
func chartPlay(_ read: PreflopRead, _ cards: [String: String], raiseAt: Double = 0.15) -> ChartPlay? {
    guard let key = read.key, let spot = preflopCharts["\(read.players)"]?[key],
          let hand = handClass(cards), let freqs = spot.hands[hand] else { return nil }
    var x = Double.random(in: 0..<1), pick = freqs.count - 1
    for (i, f) in freqs.enumerated() { if x < f { pick = i; break }; x -= f }
    if let r = spot.actions.indices.filter({ spot.actions[$0].hasPrefix("raise") }).max(by: { freqs[$0] < freqs[$1] }),
       freqs[r] >= raiseAt, freqs[r] > 0.005 { pick = r }
    var kind = spot.actions[pick].split(separator: " ").first.map(String.init) ?? "fold"
    if key.hasPrefix("VO:SB:") && kind == "call" && spot.actions.contains(where: { $0.hasPrefix("raise") }) { kind = "raise" }
    let action: String
    switch kind {
    case "fold": action = "fold"
    case "check", "call": action = "call"
    case "jam": action = "max"
    default: action = key.hasPrefix("RFI") ? "2.5x" : "75"
    }
    let mix = zip(spot.actions, freqs).filter { $0.1 > 0.005 }
        .map { "\($0.0.split(separator: " ").first!) \(Int(($0.1 * 100).rounded()))%" }.joined(separator: ", ")
    return ChartPlay(action: action, summary: "\(key) \(read.players)-handed, \(hand): \(mix) -> \(kind)")
}
