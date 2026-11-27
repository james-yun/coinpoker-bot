import Foundation
import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers
import Vision

final class Monitor: NSObject, SCStreamOutput, SCStreamDelegate {
    let sampleQueue = DispatchQueue(label: "engine.frames", qos: .userInteractive)
    var stream: SCStream?
    var windowID: CGWindowID = 0
    var windowSize: CGSize = .zero
    var missing = false
    var starting = false
    var titleBarRows = 0                // titleBarHeight in pixels; set before each stream starts

    // turn state (touched only on sampleQueue)
    var turnEdge = Edge(), preEdge = Edge()
    var inPremove = false
    var lastOpen = 0.0
    var lastCashout = 0.0
    var turnSince: Double? = nil        // when the Fold button appeared with our cards face up
    var boardSum = 0, boardChanged = 0.0  // board checksum and when it last changed
    var debugState = ""
    var generation = 0                  // bumped on each screenshot sent to the decider and each OPEN click
    var hand = 0                        // +1 each time a new hand's OPEN overlay appears
    var openEdge = Edge()
    var shots: [String: Int] = [:]      // screenshots per hand/street/kind, for _turn2 etc.
    var session: HandSession?           // this hand's model conversation (turn decisions)
    var preflopNote = ""                // what the charts did preflop, told to the model postflop
    var ledger = Ledger()               // chips won or lost per hand
    var scanOK = false                  // not our turn, nothing to click: stats windows may be opened
    var lastSeatRead = 0.0
    var turnTag = ""                    // the current turn's screenshot name, for shadow mode
    var pendingSize: String? = nil      // a sizing preset you clicked this turn (then Raise)
    var turnOnNow = false               // the Fold button is up right now (the turn edge can lag a little)
    var openSeenAt = 0.0                // the OPEN overlay was last on screen (its button sits on pre-move Call)
    var lastPF: PreflopRead? = nil
    var cardsGoneSince: Double? = nil   // our hole cards left the screen (folded or the hand ended)
    var endReadHand = -1                // the hand whose end-of-hand stack was read
    var endStack: (hand: Int, stack: Double)? = nil   // our stack once that hand was over, for the last RESULT      // this hand's chart spot, to retell preflop with your action
    var scanOKSince = 0.0               // scanOK has held since then (it flickers just after OPEN is clicked)
    var scanning = false
    var seatNames: [Int: String] = [:]  // seat -> name on its plate, read at each new hand
    var playerStats: [String: PlayerStats] = loadPlayerStats()   // by nameKey; read once per player
    var scanFailed: [String: Double] = [:]         // nameKey -> when reading its stats last failed
    var scanTries: [String: Int] = [:]             // nameKey -> reads that didn't finish (max scanMaxTries)
    let scanMaxTries = 3
    let hudQueue = DispatchQueue(label: "engine.hud")

    func stats(for name: String) -> PlayerStats? { playerStats.values.first { sameName(name, $0.name) } }


    // Stats of the opponents still holding cards, for the model.
    func statsLine(_ f: Frame) -> String { statsSummary(f, names: seatNames, lookup: stats(for:)) }

    // Ctrl-C: count the last hand too (with the stack read after it ended), then exit.
    func finish() {
        let (h, end) = sampleQueue.sync { (hand, endStack) }
        if let end, end.hand == h, let line = ledger.record(hand: h + 1, stack: end.stack, pot: nil, blind: 0, foldedTo: false) {
            log(line)
            let path = runDir + "/results.txt"
            if let f = FileHandle(forWritingAtPath: path) { f.seekToEndOfFile(); f.write((line + "\n").data(using: .utf8)!); f.closeFile() }
        } else if h > 0 {
            log("RESULT h\(String(format: "%03d", h)): not counted (stopped before the hand ended)")
        }
        exit(0)
    }

    // Shadow mode (on sampleQueue): which table button a click of yours hit, recorded against the
    // current turn (or as a pre-move while it isn't your turn).
    func userClick(_ p: CGPoint) {
        guard let b = windowBounds(windowID) else { return }
        let top = b.minY + titleBarHeight
        let f = CGPoint(x: (p.x - b.minX) / b.width, y: (p.y - top) / (b.maxY - top))
        guard (0...1).contains(f.x), (0...1).contains(f.y) else { return }
        // a click on OPEN (it sits where the pre-move Call button is)
        if ProcessInfo.processInfo.systemUptime - openSeenAt < 0.8 { return }
        let yourTurn = turnEdge.had || turnOnNow
        let names = yourTurn ? ["fold", "call", "raise", "33", "50", "75", "max"] : ["xf", "callany", "call"]
        // nearest button, within about half a button (presets are smaller)
        guard let hit = names.compactMap({ n -> (String, Double)? in
            guard let c = buttons[n] else { return nil }
            let small = ["33", "50", "75", "max"].contains(n)
            let d = hypot((f.x - c.x) / (small ? 0.025 : 0.06), (f.y - c.y) / (small ? 0.02 : 0.035))
            return d < 1 ? (n, d) : nil
        }).min(by: { $0.1 < $1.1 })?.0 else { return }
        if yourTurn {
            if ["33", "50", "75", "max"].contains(hit) { pendingSize = hit; return }
            let action = hit == "raise" ? [pendingSize, "raise"].compactMap { $0 }.joined(separator: " ") : hit
            pendingSize = nil
            log("SHADOW (\(turnTag)): you \(action)")
            shadowLog(["you", turnTag, action])
            // Postflop, the model is told what you did preflop, not what it would have done.
            if turnTag.contains("_preflop_turn"), let pf = lastPF {
                preflopNote = preflopSummary(pf, action == "fold" ? "fold" : action == "call" ? "call" : action.hasPrefix("max") ? "max" : "raise")
            }
            if action == "fold", turnTag.range(of: #"^h[0-9]{3}_preflop_turn$"#, options: .regularExpression) != nil {
                let n = hand; DispatchQueue.main.async { self.ledger.foldedFirst.insert(n) }
            }
        } else {
            let tag = String(format: "h%03d_premove", hand)
            log("SHADOW (\(tag)): you \(hit) (pre-move)")
            shadowLog(["you", tag, "pre " + hit])
        }
    }

    // Player stats (on sampleQueue): read any seated player's we don't have yet.
    func startScan() {
        // Not in shadow mode: you're using the mouse, and the scan moves it. Saved stats still apply.
        guard !shadow else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let todo = seatNames.sorted { $0.key < $1.key }.filter { seat, name in
            // an unfinished read waits 30s, then 60s; after scanMaxTries the player is left alone
            let tries = scanTries[nameKey(name)] ?? 0
            if tries >= scanMaxTries { return false }
            if let t = scanFailed[nameKey(name)], now - t < 30 * pow(2, Double(tries - 1)) { return false }
            return stats(for: name) == nil
        }.map { (seat: $0.key, name: $0.value) }
        if !scanning && scanOK && now - scanOKSince > 1.0 && decideCmd != nil && !todo.isEmpty {
            scanning = true
            let wid = windowID
            hudQueue.async { self.scan(todo, windowID: wid) }
        }
    }

    // Opens, reads and closes the stats window for each listed seat, while it stays safe to click
    // (runs on hudQueue; every click first checks scanOK, which the frame handler keeps current).
    func scan(_ seats: [(seat: Int, name: String)], windowID: CGWindowID) {
        defer { sampleQueue.async { self.scanning = false } }
        var lastHud: CGImage?
        var lastHudName: String?
        func failed(_ name: String, _ why: String) {
            sampleQueue.async {
                let k = nameKey(name)
                self.scanFailed[k] = ProcessInfo.processInfo.systemUptime
                self.scanTries[k, default: 0] += 1
                let n = self.scanTries[k]!
                log("STATS: \(name) not read (\(why)); " + (n >= self.scanMaxTries ? "giving up on them" : "try \(n) of \(self.scanMaxTries)"))
            }
        }
        func hudNow(_ expect: String) -> (bounds: CGRect, values: [Int]?, showdowns: Int?)? {
            guard let h = hudWindow(), let img = captureWindow(h.id) else { return nil }
            lastHud = img
            let r = parseHud(textLines(img))
            lastHudName = r.name
            guard let n = r.name, sameName(expect, n) else { return nil }
            return (h.bounds, r.values, r.showdowns)
        }
        for (seat, name) in seats {
            guard scanOK, let b = stableBounds(windowID) else { break }
            let content = CGRect(x: b.minX, y: b.minY + titleBarHeight, width: b.width, height: b.height - titleBarHeight)
            // The stats window can sit over a name plate: close it first (it reopens in the same place).
            let plate = CGPoint(x: content.minX + namePlates[seat].x * content.width, y: content.minY + namePlates[seat].y * content.height)
            if let h = hudWindow(), h.bounds.contains(plate) { _ = clickIn(h.bounds, hudClose); usleep(300_000) }
            // A second click if the first only brought the table window forward.
            var got: (bounds: CGRect, values: [Int]?, showdowns: Int?)? = nil
            lastHudName = nil
            for _ in 0..<2 where got == nil && scanOK {
                guard clickIn(content, namePlates[seat], above: windowID) else { break }
                for _ in 0..<6 where got == nil { usleep(120_000); got = hudNow(name) }
            }
            guard scanOK else { failed(name, "our turn came"); break }
            guard let first = got else { failed(name, lastHudName.map { "the stats window showed \"\($0)\"" } ?? "their stats window didn't open"); continue }
            // The showdown count shown right after switching players can still be the previous player's
            // (the name updates first), so it's only taken after clicking the Showdown tab.
            var st = PlayerStats(name: name, values: first.values ?? [], showdowns: nil, read: ProcessInfo.processInfo.systemUptime)
            func switchTo(_ tab: CGPoint, done: () -> Bool) {
                // the first click may only focus the window, and a just-opened window can still be settling
                for _ in 0..<3 where scanOK && !done() {
                    guard let h = hudWindow() else { return }
                    usleep(150_000)
                    guard let h2 = hudWindow(), h2.bounds == h.bounds else { continue }
                    // clicking a name plate raised the table, which may now cover the tabs
                    let pt = CGPoint(x: h2.bounds.minX + tab.x * h2.bounds.width, y: h2.bounds.minY + tab.y * h2.bounds.height)
                    if coveredByOtherWindow(pt, above: h2.id) { bringToFront(h2.id, bounds: h2.bounds); usleep(150_000) }
                    _ = clickIn(h2.bounds, tab)
                    for _ in 0..<4 where !done() {
                        usleep(120_000)
                        guard let r = hudNow(name) else { continue }
                        if tab == hudStatsTab, let v = r.values { st.values = v }
                        if tab == hudShowdownTab, let n = r.showdowns { st.showdowns = n }
                    }
                }
            }
            if st.values.isEmpty { switchTo(hudStatsTab) { !st.values.isEmpty } }
            switchTo(hudShowdownTab) { st.showdowns != nil }
            guard !st.values.isEmpty else { failed(name, scanOK ? "the Stats tab wasn't read" : "our turn came"); if scanOK { continue } else { break } }
            if st.showdowns == nil, let img = lastHud {
                // keep what the window showed, to see why
                let png = runDir + "/stats_" + nameKey(name) + ".png"
                if let dst = CGImageDestinationCreateWithURL(URL(fileURLWithPath: png) as CFURL, UTType.png.identifier as CFString, 1, nil) {
                    CGImageDestinationAddImage(dst, img, nil); CGImageDestinationFinalize(dst)
                }
                if debug { log("DEBUG: showdown count for \(name) not read (window saved to \(png))") }
            }
            sampleQueue.async { self.playerStats[nameKey(name)] = st; savePlayerStats(st); log("STATS: \(st.summary)") }
        }
        // Close the window and give the table back its focus, so the next action click isn't spent on it.
        for _ in 0..<2 {
            guard let h = hudWindow() else { break }
            _ = clickIn(h.bounds, hudClose)
            usleep(300_000)
        }
        if stayFront, let b = windowBounds(windowID) { bringToFront(windowID, bounds: b) }
    }
    var lastCur = 0.0

    func findAndStart() {
        guard stream == nil, !starting else { return }
        starting = true
        SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: true) { content, err in
            DispatchQueue.main.async {
                defer { self.starting = false }
                guard let content, let w = pickWindow(content.windows) else {
                    if !self.missing { self.missing = true; log(err.map { "ENGINE: \($0.localizedDescription)" } ?? "ENGINE: table window not found") }
                    return
                }
                self.missing = false
                self.start(w)
            }
        }
    }

    func makeConfig(_ filter: SCContentFilter) -> SCStreamConfiguration {
        let c = SCStreamConfiguration()
        // At least 2x: the card reader's templates come from Retina screenshots (1x content upscaled 2x reads exactly).
        let scale = max(CGFloat(filter.pointPixelScale), 2)
        c.width = max(1, Int(filter.contentRect.width * scale))
        c.height = max(1, Int(filter.contentRect.height * scale))
        c.pixelFormat = kCVPixelFormatType_32BGRA
        c.colorSpaceName = CGColorSpace.sRGB
        c.minimumFrameInterval = CMTime(value: 1, timescale: fps)
        c.queueDepth = 3
        c.showsCursor = false
        c.ignoreShadowsSingleWindow = true
        // A window moved to a non-Retina display draws at 1x, which left the table in the top-left
        // quarter of a 2x frame. Scaling to fit fills the frame either way.
        c.scalesToFit = true
        return c
    }

    func start(_ w: SCWindow) {
        let filter = SCContentFilter(desktopIndependentWindow: w)
        let s = SCStream(filter: filter, configuration: makeConfig(filter), delegate: self)
        do { try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue) }
        catch { log("ENGINE: \(error.localizedDescription)"); return }
        stream = s
        windowID = w.windowID
        windowSize = w.frame.size
        titleBarRows = Int((titleBarHeight * max(Double(filter.pointPixelScale), 2)).rounded())
        s.startCapture { err in
            if let err { DispatchQueue.main.async { log("ENGINE: \(err.localizedDescription)"); self.stream = nil } }
        }
    }

    func stop() {
        stream?.stopCapture(completionHandler: nil)
        stream = nil
    }

    // Called every second on main: notice closed/hidden/resized windows.
    func check() {
        guard stream != nil else { findAndStart(); return }
        sampleQueue.async { self.startScan() }
        guard let b = windowBounds(windowID) else {
            stop()
            if !missing { missing = true; log("ENGINE: table window not found") }
            return
        }
        if b.size != windowSize { stop(); findAndStart(); return }   // resized: restart at the new size
        if let p = preferredWindowID(), p != windowID { stop(); findAndStart() }   // a table opened: switch to it
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { if self.stream === stream { self.stream = nil } }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pb = CMSampleBufferGetImageBuffer(sb) else { return }

        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb)?.assumingMemoryBound(to: UInt8.self) else { return }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), stride = CVPixelBufferGetBytesPerRow(pb)

        let f = redFraction(base, width: w, height: h, stride: stride)

        let now = ProcessInfo.processInfo.systemUptime
        let top = min(titleBarRows, h - 1), outH = h - top
        let frame = Frame(base: base, width: w, height: h, stride: stride, top: top)
        let cashout = frame.cashoutVisible
        let turnOn = f > redThreshold && !cashout
        let premoveButtons = !turnOn && frame.premoveVisible
        // Pre-moves only preflop (no flop card yet): postflop they mostly came back "none" or too late,
        // and the extra model calls slowed the turn decisions running alongside them.
        let preflop = !boardHasCards(Pixels(base: base, width: w, height: h, stride: stride, top: top))
        inPremove = premoveButtons && frame.cardsFaceUp && preflop
        if debug {
            let open = !turnOn && frame.openVisible
            let state = cashout ? "cashout" : turnOn ? "turn" : open ? "open" : inPremove ? "premove" : premoveButtons ? (preflop ? "premove, no cards" : "premove, postflop (skipped)") : "idle"
            if state != debugState {
                debugState = state
                log(String(format: "DEBUG: state %@ (fold red %.2f, threshold %.2f)", state, f, redThreshold))
            }
        }
        // EV Cashout offer: answer it ourselves, again every 1.5s while it stays up.
        if cashout && now - lastCashout > 1.5 {
            lastCashout = now
            generation += 1                // the hand is all-in: nothing pending applies any more
            let wid = windowID, choice = acceptCashout ? "accept" : "reject"
            log("CASHOUT: \(choice)")
            DispatchQueue.main.async { act(choice, windowID: wid) }
        }
        // Cards dealt under the squeeze overlay: click OPEN, again every 1.5s while it stays up.
        let openVisible = !turnOn && frame.openVisible
        if openVisible { openSeenAt = now }
        turnOnNow = turnOn
        // Any time it isn't our turn (pre-moves are off once the charts are loaded, so there's nothing else to click).
        // End of hand for us: 2.5s after our cards left (a won pot has been pushed by then), read our
        // stack once, so the session's last hand is counted when the engine stops.
        if frame.cardsFaceUp || turnOn || openVisible { cardsGoneSince = nil }
        else if cardsGoneSince == nil { cardsGoneSince = now }
        if let t = cardsGoneSince, now - t > 2.5, endReadHand != hand, hand > 0 {
            endReadHand = hand
            let snap = Data(bytes: base + top * stride, count: stride * outH), handNo = hand
            writeQueue.async {
                guard let img = makeImage(snap, width: w, height: outH, stride: stride), let st = readAmount(img, stackBox) else { return }
                self.sampleQueue.async { self.endStack = (handNo, st) }
            }
        }
        let ok = !turnOn && !cashout && !openVisible && (!premoveButtons || preflopCharts.isEmpty == false)
        if ok && !scanOK { scanOKSince = now }
        scanOK = ok
        let newHand = openEdge.update(openVisible, now: now)
        if newHand || (seatNames.isEmpty && now - lastSeatRead > 5) {
            lastSeatRead = now
            // Read who sits where (in the background), for the stats: at each new hand, and right away at startup.
            let snap = Data(bytes: base + top * stride, count: stride * outH)
            writeQueue.async {
                guard let img = makeImage(snap, width: w, height: outH, stride: stride) else { return }
                var names: [Int: String] = [:]
                for seat in 1..<6 { names[seat] = seatName(img, seat) }
                self.sampleQueue.async {
                    if debug && names != self.seatNames { log("DEBUG: seats " + names.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")) }
                    self.seatNames = names
                }
            }
        }
        if newHand {
            hand += 1
            preflopNote = ""
            lastPF = nil
            // New hand: start its conversation now, so the model's startup overlaps the deal.
            session?.close()
            session = useSessions ? decideCmd.flatMap { HandSession($0) } : nil
        }
        if openVisible && now - lastOpen > 1.5 {
            lastOpen = now
            generation += 1                // a new hand: any pending answer is for the old one
            let wid = windowID
            DispatchQueue.main.async { act("open", windowID: wid) }
        }
        // Only with our cards face up: the Fold button can flash before the OPEN overlay hides them.
        // Wait (up to 1.5s) while a board card is face down or the board area is still changing
        // (cards flipping), so the screenshot shows the whole board.
        let turnRaw = turnOn && frame.cardsFaceUp
        if turnRaw { if turnSince == nil { turnSince = now } } else { turnSince = nil }
        let sum = frame.boardChecksum
        if sum != boardSum { boardSum = sum; boardChanged = now }
        let dealing = turnRaw && (frame.boardDealing || now - boardChanged < 0.3)
        if debug && dealing && turnSince == now { log("DEBUG: board still dealing, waiting") }
        let newTurn = turnEdge.update(turnRaw && (!dealing || now - turnSince! > 1.5), now: now)
        // With preflop charts, preflop turn decisions are instant, so pre-moves no longer save time.
        let newPre = preEdge.update(inPremove, now: now) && decideCmd != nil && preflopCharts.isEmpty

        let wantCur = now - lastCur >= curInterval
        guard newTurn || newPre || wantCur else { return }
        // Detection uses the full frame; saved PNGs drop the title bar.
        let data = Data(bytes: base + top * stride, count: stride * outH)   // copy so the buffer can be released
        if wantCur {
            lastCur = now
            writeQueue.async { writePNG(data, width: w, height: outH, stride: stride, to: out + "/cur.png") }
        }
        if newTurn || newPre {
            let read = readCards(Pixels(base: base, width: w, height: h, stride: stride, top: top))
            if debug { log("DEBUG: cards \(read.text)") }
            // h007_flop_turn.png: hand number, street (from the board cards read), and turn or pre-move;
            // a second screenshot of the same kind on the same street gets _turn2, and so on.
            let boardCount = read.cards.keys.filter { $0.hasPrefix("b") }.count
            let street = [0: "preflop", 3: "flop", 4: "turn", 5: "river"][boardCount] ?? "board\(boardCount)"
            let kind = newTurn ? "turn" : "pre"
            let stem = String(format: "h%03d_%@_%@", hand, street, kind)
            shots[stem, default: 0] += 1
            let name = shots[stem]! > 1 ? stem + "\(shots[stem]!)" : stem
            let dst = runDir + "/" + name + ".png"
            if newTurn { turnTag = name; pendingSize = nil }
            // write first so the file is complete when the line is printed
            writePNG(data, width: w, height: outH, stride: stride, to: dst)
            log((newTurn ? "YOUR TURN: " : "PRE-MOVE: ") + dst)
            let presets = Frame(base: base, width: w, height: h, stride: stride, top: top).presetKind
            // First preflop decision of the hand: read our stack and the pot (in the background) for the ledger.
            if newTurn && boardCount == 0 && name == stem {
                let pf0 = readPreflop(Frame(base: base, width: w, height: h, stride: stride, top: top))
                let hero = pf0.hero, foldedTo = pf0.key?.hasPrefix("RFI") == true
                let blind = hero == "BB" ? 1.0 : hero == "SB" ? 0.5 : 0.0, handNo = hand, ledgerFile = runDir + "/results.txt"
                writeQueue.async {
                    guard let img = makeImage(data, width: w, height: outH, stride: stride),
                          let stack = readAmount(img, stackBox) else { return }
                    let pot = readAmount(img, potBox), minRaise = foldedTo ? readAmount(img, raiseBox) : nil
                    DispatchQueue.main.async {
                        guard let line = self.ledger.record(hand: handNo, stack: stack, pot: pot, blind: blind, foldedTo: foldedTo, minRaise: minRaise) else { return }
                        log(line)
                        if let h = FileHandle(forWritingAtPath: ledgerFile) ?? {
                            FileManager.default.createFile(atPath: ledgerFile, contents: nil); return FileHandle(forWritingAtPath: ledgerFile) }() {
                            h.seekToEndOfFile(); h.write((line + "\n").data(using: .utf8)!); h.closeFile()
                        }
                    }
                }
            }
            // Preflop spots the charts cover are played straight from the chart, without the model.
            if newTurn && boardCount == 0 && !preflopCharts.isEmpty {
                var pf = readPreflop(Frame(base: base, width: w, height: h, stride: stride, top: top))
                // The sizing labels confirm the read: 2X-4X only show while nobody has raised, so a
                // "folded to us" read with 33%-Max showing (or the reverse) means a tag was misread.
                if let key = pf.key, presets != (key.hasPrefix("RFI") ? "multiplier" : "percent") {
                    pf.why += "; \(key) but \(presets) sizing buttons, not trusted"
                    pf.key = nil
                }
                if let note = adjustForOpener(&pf, pf.raiserSeat.flatMap { seatNames[$0] }.flatMap(stats(for:))) { log("CHART (\(name)): \(note)") }
                // 3-bet light against an opener who folds to 3-bets 55%+ (over 30+ showdowns)
                let opener = pf.key?.hasPrefix("VO:") == true ? pf.raiserSeat.flatMap { seatNames[$0] }.flatMap(stats(for:)) : nil
                let folder = opener.map { ($0.showdowns ?? 0) >= 30 && $0.values.count == statLabels.count && $0.values[3] >= 55 } ?? false
                if folder, let o = opener { pf.why += "; \(o.name) folds to 3-bets \(o.values[3])%: 3-bet light" }
                if let play = chartPlay(pf, read.cards, raiseAt: folder ? 0.05 : 0.15) {
                    let tag = name
                    log("CHART (\(tag)): \(play.summary)")
                    try? "chart: \(play.summary)\nread: \(pf.why)\ncards: \(read.text)\n\n\(play.action)\n"
                        .write(toFile: runDir + "/" + name + ".txt", atomically: true, encoding: .utf8)
                    preflopNote = preflopSummary(pf, play.action)
                    lastPF = pf
                    if !shadow && play.action == "fold" && name == stem { let n = hand; DispatchQueue.main.async { self.ledger.foldedFirst.insert(n) } }
                    generation += 1
                    let wid = windowID
                    DispatchQueue.main.async { act(play.action, windowID: wid, tag: tag, presets: presets) }
                    return
                }
                if debug { log("DEBUG: no chart spot (\(pf.hero) of \(pf.players): \(pf.why)), asking the model") }
            }
            let raised = Frame(base: base, width: w, height: h, stride: stride, top: top).seatTag(0) == .raise
            let facing = newTurn ? (makeImage(data, width: w, height: outH, stride: stride).map { facingLine($0, raised: raised, preflop: boardCount == 0) } ?? "") : ""
            let context = (boardCount > 0 && !preflopNote.isEmpty ? preflopNote + " " + read.text : read.text) + facing
                + statsLine(Frame(base: base, width: w, height: h, stride: stride, top: top))
            runDecider(png: dst, mode: newTurn ? "turn" : "premove", cards: context, presets: presets)
        }
    }

    // Asks the decide command in the background, then clicks. An answer is dropped if anything newer
    // was captured meanwhile (a later turn/pre-move, or a new hand opened), or if its state is gone.
    // Stale pre-moves matter most: their spots overlap Fold and the bet presets on our turn.
    func runDecider(png: String, mode: String, cards: String, presets: String) {
        guard let cmd = decideCmd else { return }
        generation += 1
        let gen = generation, wid = windowID, board = boardSum
        let tag = (png as NSString).lastPathComponent.replacingOccurrences(of: ".png", with: "")
        // Turn decisions go to the hand's conversation (started now if the hand had no OPEN overlay);
        // pre-moves stay one-shot so they never queue ahead of a turn decision.
        if mode == "turn" && session == nil && useSessions { session = HandSession(cmd) }
        let handSession = mode == "turn" ? session : nil
        DispatchQueue.global(qos: .userInitiated).async {
            let started = ProcessInfo.processInfo.systemUptime
            var text: String? = nil, via = "one-shot"
            if let s = handSession {
                text = s.ask(png: png, mode: mode, cards: cards)
                if text == nil { log("DECIDE (\(tag)): session failed, asking one-shot") } else { via = "session" }
            }
            if text == nil { text = decideOnce(cmd, png: png, mode: mode, cards: cards) }
            guard let text else { log("DECIDE (\(tag)): no action"); return }
            recordDecision(png: png, mode: mode, cards: cards, text: text, via: via,
                           secs: ProcessInfo.processInfo.systemUptime - started)
            guard let answer = lastLine(text) else { log("DECIDE (\(tag)): no action"); return }
            if answer.lowercased().filter(\.isLetter).hasSuffix("none") { log("DECIDE (\(tag)): none"); return }
            // Pre-move screens only have X/F, Check and Call Any; an answer like "raise" is not a pre-move.
            var a = answer
            if mode == "premove" {
                guard let seq = clicks(for: a), seq.count == 1, ["xf", "call", "fold"].contains(seq[0]) else {
                    log("DECIDE (\(tag)): '\(a)' isn't a pre-move, skipped"); return
                }
                if seq[0] == "fold" { a = "xf" }
            }
            self.sampleQueue.async {
                // A pre-move is also stale once the board changes: an X/F chosen preflop must not
                // land on the flop after the street ends.
                let stillOn = mode == "premove" ? self.inPremove && self.boardSum == board : self.turnEdge.had
                // (in shadow mode a late answer still counts: it's compared, not clicked)
                guard shadow || (gen == self.generation && stillOn) else { log("DECIDE (\(tag)): '\(a)' arrived too late, skipped"); return }
                DispatchQueue.main.async {
                    if !shadow, actionToken(a) == "fold", tag.range(of: #"^h[0-9]{3}_preflop_turn$"#, options: .regularExpression) != nil,
                       let n = Int(tag.dropFirst().prefix(3)) { self.ledger.foldedFirst.insert(n) }
                    act(a, windowID: wid, tag: tag, presets: mode == "turn" ? presets : "")
                }
            }
        }
    }
}
