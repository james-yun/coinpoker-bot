import Foundation
import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers
import Vision

// Loads a saved screenshot (content area only, no title bar) as BGRA pixels.
func withPNGPixels<T>(_ path: String, _ body: (Pixels) -> T) -> T? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
    let w = img.width, h = img.height, stride = w * 4
    var buf = [UInt8](repeating: 0, count: stride * h)
    let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
    return buf.withUnsafeMutableBytes { raw -> T? in
        guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: stride,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info) else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return body(Pixels(base: UnsafePointer(raw.bindMemory(to: UInt8.self).baseAddress!), width: w, height: h, stride: stride, top: 0))
    }
}

// --build-cards <labels.txt> <png-dir> <out.txt>: labels lines are "<png> <slot> <rank> <suit>".
// Reports leave-one-screenshot-out accuracy, then writes deduplicated templates.
// --read-cards <png>...: prints what the reader sees in each screenshot.
// --selftest: the pure logic, pinned to cases that broke before (or were checked by hand at the table).
func selfTest() -> Bool {
    var failed = 0, passed = 0
    func check<T: Equatable>(_ name: String, _ got: T, _ want: T) {
        if got == want { passed += 1 } else { failed += 1; print("FAIL \(name)\n  got:  \(got)\n  want: \(want)") }
    }
    // amounts: a zero read as the letter O ("Raise O.1" once made the big blind 0.50)
    check("digitFix O.1", digitFix("Raise O.1"), "Raise 0.1")
    check("digitFix 1.O8", digitFix("Raise 1.O8"), "Raise 1.08")
    check("digitFix leaves words", digitFix("Pot 0.07"), "Pot 0.07")
    // names: lookalike letters (Cyrillic O) and names the table cuts short
    check("sameName cyrillic", sameName("NОVA77", "NOVA77"), true)
    check("sameName truncated", sameName("LongNameExam...", "LongNameExample"), true)
    check("sameName different", sameName("Seat1", "Seat2"), false)
    // hand descriptions (each checked against the real table)
    let hands: [([String], [String], String)] = [
        (["Q♣", "J♣"], ["Q♦", "7♠", "8♦", "K♥"], "Your hand: second pair (Qs, J kicker). Draws: none."),
        (["9♠", "9♣"], ["4♠", "4♥", "A♥"], "Your hand: pocket 9s below 1 board card; the 4s pair is on the board. Draws: none."),
        (["A♣", "9♠"], ["A♥", "J♠", "6♠", "3♠"], "Your hand: top pair (As, 9 kicker). Draws: flush draw (9 outs)."),
        (["8♠", "7♠"], ["T♣", "9♠", "Q♥", "8♥"], "Your hand: bottom pair (8s, 7 kicker). Draws: open-ended straight draw (8 outs)."),
        (["A♦", "T♠"], ["3♠", "4♥", "2♦", "5♠", "J♣"], "Your hand: straight (5-high)."),
        (["T♥", "9♥"], ["A♥", "Q♠", "A♣", "6♠", "6♣"], "Your hand: no pair of your own (both pairs are on the board); the board plays, you hold nothing better."),
    ]
    for (hole, board, want) in hands { check("hand \(hole) on \(board)", handStrength(hole: hole, board: board) ?? "nil", want) }
    // action words from the model, and fitting them to the sizing buttons on screen
    check("action **Call**", actionToken("**Call**") ?? "nil", "call")
    check("action 2.5X", actionToken("2.5X") ?? "nil", "25x")
    check("action reason then word", actionToken("raise for value 75") ?? "nil", "75")
    check("4x with percent buttons", fitToPresets("4x", kind: "percent").token, "75")
    check("max with multiplier buttons", fitToPresets("max", kind: "multiplier").token, "4x")
    check("bet facing an all-in", fitToPresets("75", kind: "none").token, "call")
    // the results ledger: big blind from the Raise button, chips added after a fold not counted
    var l = Ledger()
    _ = l.record(hand: 1, stack: 4.93, pot: 0.07, blind: 0, foldedTo: true, minRaise: 0.1)
    check("bb from the Raise button", l.bb ?? 0, 0.05)
    l.foldedFirst.insert(1)
    let line = l.record(hand: 2, stack: 6.93, pot: nil, blind: 0, foldedTo: false) ?? ""
    check("top-up not counted", line.contains("2.00 added to the stack") && line.contains("+0.00"), true)
    var l2 = Ledger()
    _ = l2.record(hand: 1, stack: 5.00, pot: 0.07, blind: 0, foldedTo: true, minRaise: 0.1)
    l2.foldedFirst.insert(1)
    check("reading noise isn't a top-up", (l2.record(hand: 2, stack: 5.01, pot: nil, blind: 0, foldedTo: false) ?? "").contains("added"), false)
    // the stats window's layout: ten percentages in rows of 4, 4, 2; the showdown count above its label
    var hud: [(text: String, x: Double, y: Double)] = [("ExamplePlayer", 0.31, 0.12), ("VPIP", 0.13, 0.43)]
    let pct = [27, 21, 12, 38, 80, 38, 38, 0, 25, 82]
    let spots: [(Double, Double)] = [(0.13, 0.38), (0.36, 0.38), (0.6, 0.38), (0.83, 0.38), (0.13, 0.52), (0.36, 0.52),
                                     (0.6, 0.52), (0.83, 0.52), (0.25, 0.635), (0.77, 0.634)]
    for (v, p) in zip(pct, spots).reversed() { hud.append(("\(v)%", p.0, p.1)) }
    let parsed = parseHud(hud)
    check("hud name", parsed.name ?? "nil", "ExamplePlayer")
    check("hud stats in order", parsed.values ?? [], pct)
    check("hud showdowns", parseHud([("x", 0.3, 0.12), ("310", 0.5, 0.354), ("Showdowns O", 0.5, 0.392)]).showdowns ?? -1, 310)
    print("\(passed) passed, \(failed) failed")
    return failed == 0
}

func runCardTool(_ args: [String]) {
    if args.first == "--selftest" { exit(selfTest() ? 0 : 1) }
    // --context <png>...: the context line the model would get for a saved screenshot (cards, hand,
    // the price of a call, and saved stats of the players still in), as the replay benchmark uses it.
    if args.first == "--context" {
        let saved = loadPlayerStats(maxAge: .infinity)     // replays use whatever was saved
        for p in args.dropFirst() {
            guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: p) as CFURL, nil),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { print("\(p): unreadable"); continue }
            let line = withPNGPixels(p) { px -> String in
                let f = Frame(base: px.base, width: px.width, height: px.height, stride: px.stride, top: 0)
                var names: [Int: String] = [:]
                for seat in 1..<6 { names[seat] = seatName(img, seat) }
                return readCards(px).text + facingLine(img, raised: f.seatTag(0) == .raise, preflop: readCards(px).cards.keys.allSatisfy { !$0.hasPrefix("b") }) + statsSummary(f, names: names) { n in saved.values.first { sameName(n, $0.name) } }
            } ?? ""
            print(args.count > 2 ? "\((p as NSString).lastPathComponent): \(line)" : line)
        }
        return
    }
    // --read-seats <png>...: the names on seats 1-5 of saved table screenshots.
    if args.first == "--read-seats" {
        for p in args.dropFirst() {
            guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: p) as CFURL, nil),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { print("\(p): unreadable"); continue }
            print("\((p as NSString).lastPathComponent): " + (1..<6).map { "\($0) \(seatName(img, $0) ?? "-")" }.joined(separator: ", "))
        }
        return
    }
    // --read-hud <png>...: what the stats-window reader sees in screenshots of that window.
    if args.first == "--read-hud" {
        for p in args.dropFirst() {
            guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: p) as CFURL, nil),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { print("\(p): unreadable"); continue }
            let r = parseHud(textLines(img))
            print("\((p as NSString).lastPathComponent): name \(r.name ?? "?"), stats \(r.values.map { "\($0)" } ?? "-"), showdowns \(r.showdowns.map(String.init) ?? "-")")
        }
        return
    }
    // --results <run-dir>: the per-hand results ledger, rebuilt from a run's saved screenshots.
    if args.first == "--results", args.count == 2 {
        let dir = args[1]
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
            .filter { $0.range(of: #"^h[0-9]{3}_preflop_turn\.png$"#, options: .regularExpression) != nil }.sorted()
        var ledger = Ledger()
        for file in files {
            let path = dir + "/" + file
            guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, nil), let stack = readAmount(img, stackBox),
                  let hero = withPNGPixels(path, { readPreflop(Frame(base: $0.base, width: $0.width, height: $0.height, stride: $0.stride, top: 0)).hero }) as String?
            else { print("\(file): unreadable"); continue }
            let blind = hero == "BB" ? 1.0 : hero == "SB" ? 0.5 : 0.0, handNo = Int(file.dropFirst().prefix(3))!
            let foldedTo = withPNGPixels(path, { readPreflop(Frame(base: $0.base, width: $0.width, height: $0.height, stride: $0.stride, top: 0)).key?.hasPrefix("RFI") }) ?? nil
            // a hand we folded at our first decision: its decision file ends in "fold"
            let decision = (try? String(contentsOfFile: path.replacingOccurrences(of: ".png", with: ".txt"), encoding: .utf8)) ?? ""
            if decision.split(whereSeparator: \.isNewline).last.map({ actionToken(String($0)) == "fold" }) == true { ledger.foldedFirst.insert(handNo) }
            let minRaise = foldedTo == true ? readAmount(img, raiseBox) : nil
            if let line = ledger.record(hand: handNo, stack: stack, pot: readAmount(img, potBox), blind: blind, foldedTo: foldedTo == true, minRaise: minRaise) { print(line) }
        }
        return
    }
    if args.first == "--read-preflop" {
        for p in args.dropFirst() {
            let t = withPNGPixels(p) { px -> String in
                let f = Frame(base: px.base, width: px.width, height: px.height, stride: px.stride, top: px.top)
                var read = readPreflop(f)
                let cards = readCards(px).cards
                // with the cached player stats, as live
                if let seat = read.raiserSeat, let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: p) as CFURL, nil),
                   let img = CGImageSourceCreateImageAtIndex(src, 0, nil), let name = seatName(img, seat) {
                    _ = adjustForOpener(&read, loadPlayerStats(maxAge: .infinity).values.first { sameName(name, $0.name) })
                }
                let play = chartPlay(read, cards)
                return "\(read.hero) of \(read.players), presets \(f.presetKind), spot \(read.key ?? "none") [\(read.why)]" +
                    (play.map { " => \($0.action) (\($0.summary))" } ?? "")
            } ?? "unreadable file"
            print("\((p as NSString).lastPathComponent): \(t)")
        }
        return
    }
    if args.first == "--read-cards" {
        for p in args.dropFirst() {
            let t = withPNGPixels(p) { readCards($0).text } ?? "unreadable file"
            print("\((p as NSString).lastPathComponent): \(t.isEmpty ? "(no hole cards)" : t)")
        }
        return
    }
    guard args.count == 4, let labels = try? String(contentsOfFile: args[1], encoding: .utf8) else {
        print("usage: engine --build-cards <labels.txt> <png-dir> <out.txt>"); return
    }
    var samples: [(file: String, rank: String, suit: String, glyphs: (Glyph, Glyph))] = []
    var byFile: [String: [(String, String, String)]] = [:]
    for line in labels.split(whereSeparator: \.isNewline) {
        let f = line.split(separator: " ").map(String.init)
        if f.count == 4 { byFile[f[0], default: []].append((f[1], f[2], f[3])) }
    }
    for (file, slots) in byFile.sorted(by: { $0.key < $1.key }) {
        guard let g = withPNGPixels(args[2] + "/" + file, slotGlyphs) else { print("missing \(file)"); continue }
        for (slot, rank, suit) in slots {
            if let gl = g[slot] { samples.append((file, rank, suit, gl)) } else { print("no glyph: \(file) \(slot)") }
        }
    }
    func templates(excluding file: String?) -> [CardTemplate] {
        samples.filter { $0.file != file }.flatMap {
            [CardTemplate(rank: true, label: $0.rank, glyph: $0.glyphs.0), CardTemplate(rank: false, label: $0.suit, glyph: $0.glyphs.1)]
        }
    }
    var errors = 0
    for s in samples {
        let t = templates(excluding: s.file)
        let r = classify(s.glyphs.0, rank: true, t).0, u = classify(s.glyphs.1, rank: false, t).0
        if r != s.rank || u != s.suit { errors += 1; print("miss \(s.file): \(s.rank)\(s.suit) read as \(r)\(u)") }
    }
    print("leave-one-screenshot-out: \(samples.count - errors)/\(samples.count) correct")
    // keep a template only if no kept template with the same label is nearly identical
    var kept: [CardTemplate] = []
    for t in templates(excluding: nil) where !kept.contains(where: {
        $0.rank == t.rank && $0.label == t.label && $0.glyph.red == t.glyph.red && glyphDistance($0.glyph, t.glyph) < 0.02
    }) { kept.append(t) }
    let text = kept.map { t in
        "\(t.rank ? "r" : "s") \(t.label) \(t.glyph.red ? 1 : 0) \(String(format: "%.3f", t.glyph.aspect)) " +
        String(t.glyph.bits.map { $0 ? "1" : "0" })
    }.joined(separator: "\n") + "\n"
    try? text.write(toFile: args[3], atomically: true, encoding: .utf8)
    print("wrote \(kept.count) templates to \(args[3])")
}
