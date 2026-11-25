import Foundation
import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers
import Vision

// MARK: chip counts
//
// Our stack (under our name) and the pot, read with macOS text recognition (about 50ms, run off the
// click path). Content-area fractions: x, y, width, height.
let stackBox = CGRect(x: 0.427, y: 0.883, width: 0.146, height: 0.042)
let potBox = CGRect(x: 0.40, y: 0.325, width: 0.20, height: 0.055)
let raiseBox = CGRect(x: 0.87, y: 0.915, width: 0.12, height: 0.08)   // the Raise button's amount

// Text recognized in a region (fractions of the image), with each line's center as fractions of the region (y down).
func textLines(_ img: CGImage, _ r: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)) -> [(text: String, x: Double, y: Double)] {
    let box = CGRect(x: r.minX * Double(img.width), y: r.minY * Double(img.height),
                     width: r.width * Double(img.width), height: r.height * Double(img.height))
    guard let crop = img.cropping(to: box) else { return [] }
    let req = VNRecognizeTextRequest()
    req.recognitionLevel = .accurate
    req.usesLanguageCorrection = false
    try? VNImageRequestHandler(cgImage: crop).perform([req])
    return (req.results ?? []).compactMap { o in
        o.topCandidates(1).first.map { ($0.string, Double(o.boundingBox.midX), 1 - Double(o.boundingBox.midY)) }
    }
}

// Text recognition sometimes reads a zero as the letter O ("Raise O.1"): next to a digit or a decimal
// point it is a zero. (Reading "O.1" as 1 once made the big blind 0.50 at a 0.02/0.05 table.)
func digitFix(_ t: String) -> String {
    t.replacingOccurrences(of: #"[Oo](?=[.,]?[0-9])|(?<=[0-9][.,])[Oo]|(?<=[0-9])[Oo]"#, with: "0", options: .regularExpression)
}

func readAmount(_ img: CGImage, _ r: CGRect) -> Double? {
    let text = digitFix(textLines(img, r).map(\.text).joined(separator: " "))
    guard let m = text.range(of: #"[0-9][0-9,]*(\.[0-9]+)?"#, options: .regularExpression) else { return nil }
    return Double(text[m].replacingOccurrences(of: ",", with: ""))
}

// Chips won or lost per hand: our stack at our first preflop decision, plus the blind we had posted,
// is the stack the hand started with; the next hand's start minus this one's is the result.
// The big blind is the pot at our first decision when it was folded to us (SB + BB = 1.5bb).
// Chips added between hands (a top-up) would read as a win: a hand we folded at our first decision
// can't have won anything, so a gain after one is taken out of the results.
struct Ledger {
    var entries: [(hand: Int, stack: Double, blind: Double, added: Double)] = []   // blind posted (bb); chips added so far
    var foldedPot = Double.infinity
    var minRaiseBB = Double.infinity    // half the Raise button's amount when folded to us (min raise = 2bb)
    var foldedFirst: Set<Int> = []      // hands we folded at our first decision
    // The Raise button is exact; the pot (SB + BB) assumes the small blind is half the big blind,
    // which isn't true at every table (0.02/0.05).
    var bb: Double? { minRaiseBB.isFinite ? minRaiseBB : foldedPot.isFinite ? foldedPot / 1.5 : nil }
    func start(_ i: Int) -> Double { entries[i].stack + entries[i].blind * (bb ?? 0) - entries[i].added }

    // Records a hand's start; returns the line describing the previous hand(s), if any.
    mutating func record(hand: Int, stack: Double, pot: Double?, blind: Double, foldedTo: Bool, minRaise: Double? = nil) -> String? {
        if foldedTo, let pot, pot > 0 { foldedPot = min(foldedPot, pot) }
        if foldedTo, let r = minRaise, r > 0 { minRaiseBB = min(minRaiseBB, r / 2) }
        entries.append((hand, stack, blind, entries.last?.added ?? 0))
        guard entries.count > 1 else { return nil }
        let i = entries.count - 1, prev = entries[i - 1]
        var note = ""
        if hand - prev.hand == 1 && foldedFirst.contains(prev.hand) {
            let gain = start(i) - start(i - 1) + prev.blind * (bb ?? 0)   // folding loses exactly the blind
            if gain > max(0.005, 0.5 * (bb ?? 0)) { entries[i].added += gain; note = String(format: " (%.2f added to the stack, not counted)", gain) }
        }
        let delta = start(i) - start(i - 1), total = start(i) - start(0)
        let hands = hand - entries[0].hand
        let label = hand - prev.hand > 1 ? String(format: "h%03d-h%03d", prev.hand, hand - 1) : String(format: "h%03d", prev.hand)
        func chips(_ x: Double) -> String { String(format: "%+.2f", x) }
        guard let bb else { return "RESULT \(label): \(chips(delta)); session \(chips(total)) in \(hands) hands" + note }
        return "RESULT \(label): \(chips(delta)) (\(String(format: "%+.1f", delta / bb))bb); session \(chips(total)) " +
            "(\(String(format: "%+.1f", total / bb))bb in \(hands) hands, \(String(format: "%+.0f", total / bb / Double(hands) * 100)) bb/100)" + note
    }
}
