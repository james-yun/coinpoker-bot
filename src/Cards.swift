import Foundation
import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers
import Vision

// MARK: card reading
//
// Reads our hole cards and the board from fixed slots, so the decider gets exact cards instead of
// reading them off the screenshot (Haiku misread board pairs and suits). Each face-up card is scaled
// to 120x160; the rank and suit glyphs are cut out by their connected ink, scaled to 20x26 bitmaps,
// and matched to the nearest template in cards.txt. Templates are built from labeled screenshots
// with `engine --build-cards`, using this same code, so live reading and templates always agree.

// BGRA pixels with the title bar (top rows) excluded from slot fractions.
struct Pixels {
    let base: UnsafePointer<UInt8>, width: Int, height: Int, stride: Int, top: Int
}

struct Glyph { let bits: [Bool]; let aspect: Double; let red: Bool }

enum CardGeom {
    static let cw = 120, ch = 160, gw = 20, gh = 26
    // slot rectangles (x, y, w, h) as fractions of the content area; hole cards are sorted high-low
    static let slots: [(name: String, rect: (Double, Double, Double, Double))] =
        (0..<5).map { ("b\($0)", (0.3142 + 0.0759 * Double($0), 0.3806, 0.0674, 0.131)) } +
        [("h0", (0.430, 0.712, 0.075, 0.135)), ("h1", (0.490, 0.712, 0.080, 0.135))]
    // glyph windows (x0, y0, x1, y1) inside the 120x160 card, by slot kind
    static let rankWin: [String: (Int, Int, Int, Int)] = ["b": (2, 2, 52, 50), "h0": (6, 4, 60, 68), "h1": (8, 2, 60, 66)]
    static let suitWin: [String: (Int, Int, Int, Int)] = ["b": (2, 48, 52, 88), "h0": (10, 52, 56, 94), "h1": (12, 48, 56, 90)]
}

// One slot scaled to 120x160 RGB (bilinear), or nil if the slot is off-frame.
func normalizedCard(_ px: Pixels, _ r: (Double, Double, Double, Double)) -> [(Int, Int, Int)]? {
    let ch = Double(px.height - px.top)
    let sx = r.0 * Double(px.width), sy = Double(px.top) + r.1 * ch
    let sw = r.2 * Double(px.width), sh = r.3 * ch
    guard sw > 4, sh > 4, Int(sx + sw) < px.width, Int(sy + sh) < px.height else { return nil }
    var out = [(Int, Int, Int)](repeating: (0, 0, 0), count: CardGeom.cw * CardGeom.ch)
    for y in 0..<CardGeom.ch {
        let fy = sy + (Double(y) + 0.5) * sh / Double(CardGeom.ch) - 0.5
        let y0 = max(0, Int(fy)), y1 = min(px.height - 1, y0 + 1), ty = max(0, fy - Double(y0))
        for x in 0..<CardGeom.cw {
            let fx = sx + (Double(x) + 0.5) * sw / Double(CardGeom.cw) - 0.5
            let x0 = max(0, Int(fx)), x1 = min(px.width - 1, x0 + 1), tx = max(0, fx - Double(x0))
            var c = [0.0, 0.0, 0.0]
            for (yy, wy) in [(y0, 1 - ty), (y1, ty)] {
                for (xx, wx) in [(x0, 1 - tx), (x1, tx)] {
                    let p = px.base + yy * px.stride + xx * 4
                    c[0] += Double(p[2]) * wy * wx; c[1] += Double(p[1]) * wy * wx; c[2] += Double(p[0]) * wy * wx
                }
            }
            out[y * CardGeom.cw + x] = (Int(c[0]), Int(c[1]), Int(c[2]))
        }
    }
    return out
}

// White card face in the upper right of the slot: blank on every card (rank and suit are top left,
// the big pip or face picture lower down), and clear of our own action tag (e.g. RAISE), which
// covers the lower left of the first hole card.
func isFaceUp(_ card: [(Int, Int, Int)]) -> Bool {
    var n = 0, t = 0
    for y in Swift.stride(from: 12, to: 64, by: 4) {
        for x in Swift.stride(from: 66, to: 108, by: 4) {
            let (r, g, b) = card[y * CardGeom.cw + x]
            t += 1; if r > 200 && g > 200 && b > 200 { n += 1 }
        }
    }
    return Double(n) / Double(t) > 0.35
}

// Cuts the glyph out of a window by its connected ink (black or red; the teal table isn't ink).
// Rank: components that start in the top part of the window. Suit: the biggest component.
func extractGlyph(_ card: [(Int, Int, Int)], _ win: (Int, Int, Int, Int), rank: Bool) -> Glyph? {
    let (x0, y0, x1, y1) = win, w = x1 - x0, h = y1 - y0
    var ink = [Bool](repeating: false, count: w * h), nInk = 0, nRed = 0
    for y in 0..<h {
        for x in 0..<w {
            let (r, g, b) = card[(y0 + y) * CardGeom.cw + x0 + x]
            let hi = max(r, g, b), lo = min(r, g, b)
            let isRed = r > 140 && g < 110 && r > g + 60
            if (hi < 110 && hi - lo < 40) || isRed { ink[y * w + x] = true; nInk += 1; if isRed { nRed += 1 } }
        }
    }
    // connected components (4-neighbour)
    var seen = [Bool](repeating: false, count: w * h)
    var comps: [[Int]] = []
    for i in 0..<(w * h) where ink[i] && !seen[i] {
        var stack = [i], pts: [Int] = []
        seen[i] = true
        while let j = stack.popLast() {
            pts.append(j)
            let x = j % w, y = j / w
            for (nx, ny) in [(x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)] where nx >= 0 && nx < w && ny >= 0 && ny < h {
                let k = ny * w + nx
                if ink[k] && !seen[k] { seen[k] = true; stack.append(k) }
            }
        }
        if pts.count >= 20 { comps.append(pts) }
    }
    // drop specks of card edge / shadow touching the window's top or left border
    comps.removeAll { c in c.count < 120 && (c.contains { $0 % w == 0 } || c.contains { $0 / w == 0 }) }
    if rank {
        comps = comps.filter { c in
            Double(c.map { $0 / w }.min()!) < Double(h) * 0.45 && Double(c.map { $0 % w }.min()!) < Double(w) * 0.6
        }
    } else if let big = comps.max(by: { $0.count < $1.count }) {
        comps = [big]
    }
    let pts = comps.flatMap { $0 }
    guard !pts.isEmpty else { return nil }
    let xs = pts.map { $0 % w }, ys = pts.map { $0 / w }
    let bx0 = xs.min()!, bx1 = xs.max()! + 1, by0 = ys.min()!, by1 = ys.max()! + 1
    let bw = bx1 - bx0, bh = by1 - by0
    var cell = [Int](repeating: 0, count: bw * bh)
    for j in pts { cell[(j / w - by0) * bw + (j % w - bx0)] = 1 }
    // area-average the glyph into a gw x gh grid, then threshold at half coverage
    var bits = [Bool](repeating: false, count: CardGeom.gw * CardGeom.gh)
    for gy in 0..<CardGeom.gh {
        let sy0 = gy * bh / CardGeom.gh, sy1 = max(sy0 + 1, (gy + 1) * bh / CardGeom.gh)
        for gx in 0..<CardGeom.gw {
            let sx0 = gx * bw / CardGeom.gw, sx1 = max(sx0 + 1, (gx + 1) * bw / CardGeom.gw)
            var on = 0, all = 0
            for yy in sy0..<min(sy1, bh) { for xx in sx0..<min(sx1, bw) { on += cell[yy * bw + xx]; all += 1 } }
            bits[gy * CardGeom.gw + gx] = all > 0 && on * 2 >= all
        }
    }
    return Glyph(bits: bits, aspect: Double(bw) / Double(bh), red: nInk > 0 && Double(nRed) / Double(nInk) > 0.4)
}

func glyphDistance(_ a: Glyph, _ b: Glyph) -> Double {
    var diff = 0
    for i in 0..<a.bits.count where a.bits[i] != b.bits[i] { diff += 1 }
    return Double(diff) / Double(a.bits.count) + abs(a.aspect - b.aspect) * 0.5
}

struct CardTemplate { let rank: Bool; let label: String; let glyph: Glyph }

// cards.txt lines: "r|s <label> <red 0|1> <aspect> <bits as 0/1 string>"
func loadCardTemplates(_ path: String) -> [CardTemplate] {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
    return text.split(whereSeparator: \.isNewline).compactMap { line in
        let f = line.split(separator: " ")
        guard f.count == 5, let aspect = Double(f[3]) else { return nil }
        return CardTemplate(rank: f[0] == "r", label: String(f[1]),
                            glyph: Glyph(bits: f[4].map { $0 == "1" }, aspect: aspect, red: f[2] == "1"))
    }
}

let cardTemplatesPath = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    .deletingLastPathComponent().appendingPathComponent("cards.txt").path
let cardTemplates = loadCardTemplates(cardTemplatesPath)

// Nearest template; "?" when nothing is close enough. Suits only match templates of the same color.
func classify(_ g: Glyph, rank: Bool, _ templates: [CardTemplate]) -> (String, Double) {
    var best = ("?", 9.0)
    for t in templates where t.rank == rank && (rank || t.glyph.red == g.red) {
        let d = glyphDistance(g, t.glyph)
        if d < best.1 { best = (t.label, d) }
    }
    return best.1 <= (rank ? 0.25 : 0.09) ? best : ("?", best.1)
}

// Glyphs of every face-up slot: [slot name: (rank glyph, suit glyph)].
func slotGlyphs(_ px: Pixels) -> [String: (Glyph, Glyph)] {
    var out: [String: (Glyph, Glyph)] = [:]
    for s in CardGeom.slots {
        guard let card = normalizedCard(px, s.rect), isFaceUp(card) else { continue }
        let kind = s.name.hasPrefix("h") ? s.name : "b"
        if let r = extractGlyph(card, CardGeom.rankWin[kind]!, rank: true),
           let u = extractGlyph(card, CardGeom.suitWin[kind]!, rank: false) { out[s.name] = (r, u) }
    }
    return out
}

let suitSymbol = ["s": "♠", "h": "♥", "d": "♦", "c": "♣"]

// The first flop card is face up.
func boardHasCards(_ px: Pixels) -> Bool {
    guard let card = normalizedCard(px, CardGeom.slots[0].rect) else { return false }
    return isFaceUp(card)
}

// "Your cards: A♣ 3♣ (suited). Board: Q♦ K♥ 2♣." Unreadable cards show as "?".
func readCards(_ px: Pixels, _ templates: [CardTemplate] = cardTemplates) -> (cards: [String: String], text: String) {
    guard !templates.isEmpty else { return ([:], "") }
    var cards: [String: String] = [:]
    for (slot, (r, s)) in slotGlyphs(px) {
        let rank = classify(r, rank: true, templates).0, suit = classify(s, rank: false, templates).0
        cards[slot] = rank + (suitSymbol[suit] ?? "?")
    }
    let hole = ["h0", "h1"].compactMap { cards[$0] }
    let board = (0..<5).compactMap { cards["b\($0)"] }
    guard hole.count == 2 else { return (cards, "") }
    let s0 = hole[0].last!, s1 = hole[1].last!
    let pair = hole[0].dropLast() == hole[1].dropLast()
    let kind = pair ? "pair" : s0 == s1 && s0 != "?" ? "suited" : "offsuit"
    var text = "Your cards: \(hole.joined(separator: " ")) (\(kind)). Board: " +
        (board.isEmpty ? "none (preflop)." : board.joined(separator: " ") + ".")
    if board.count >= 3, let strength = handStrength(hole: hole, board: board) { text += " " + strength }
    return (cards, text)
}
