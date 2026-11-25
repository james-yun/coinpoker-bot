import Foundation
import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers
import Vision

// MARK: hand strength
//
// The made hand and draws, worked out exactly from the cards, so the model doesn't have to count
// (it invented straight and flush draws, and called board pairs its own). E.g.
// "Your hand: second pair (8s, K kicker). Draws: flush draw (9 outs), gutshot (4 outs)."

typealias PCard = (rank: Int, suit: Character)    // rank 2...14

func parseCard(_ c: String) -> PCard? {
    guard c.count == 2, let s = c.last, s != "?" else { return nil }
    let r = c.first!
    let rank: Int? = ["T": 10, "J": 11, "Q": 12, "K": 13, "A": 14][r] ?? r.wholeNumberValue
    return rank.map { ($0, s) }
}

func rankName(_ r: Int, plural: Bool = false) -> String {
    let n = [14: "A", 13: "K", 12: "Q", 11: "J", 10: "T"][r] ?? String(r)
    return plural ? n + "s" : n
}

// Highest straight top among the ranks (ace also counts low), or 0.
func straightTop(_ ranks: Set<Int>) -> Int {
    var r = ranks
    if r.contains(14) { r.insert(1) }
    for top in stride(from: 14, through: 5, by: -1) where (top - 4...top).allSatisfy({ r.contains($0) }) { return top }
    return 0
}

// Hand value for comparing 5-7 cards: (category, tiebreak ranks). Categories: 0 high card, 1 pair,
// 2 two pair, 3 trips, 4 straight, 5 flush, 6 full house, 7 quads, 8 straight flush.
func handValue(_ cards: [PCard]) -> [Int] {
    var best: [Int] = []
    func better(_ a: [Int], _ b: [Int]) -> Bool { a.lexicographicallyPrecedes(b) == false && a != b }
    let n = cards.count
    var idx = [Int](repeating: 0, count: 5)
    func eval5(_ h: [PCard]) -> [Int] {
        let ranks = h.map(\.rank).sorted(by: >)
        let flush = Set(h.map(\.suit)).count == 1
        let st = straightTop(Set(ranks))
        let counts = Dictionary(grouping: ranks, by: { $0 }).map { ($0.value.count, $0.key) }.sorted { $0 > $1 }
        let byCount = counts.map(\.1)
        if flush && st > 0 { return [8, st] }
        if counts[0].0 == 4 { return [7] + byCount }
        if counts[0].0 == 3 && counts.count > 1 && counts[1].0 >= 2 { return [6] + byCount }
        if flush { return [5] + ranks }
        if st > 0 { return [4, st] }
        if counts[0].0 == 3 { return [3] + byCount }
        if counts[0].0 == 2 && counts[1].0 == 2 { return [2] + byCount }
        if counts[0].0 == 2 { return [1] + byCount }
        return [0] + ranks
    }
    func choose(_ start: Int, _ k: Int) {
        if k == 5 { let v = eval5(idx.map { cards[$0] }); if best.isEmpty || better(v, best) { best = v }; return }
        guard start < n else { return }
        for i in start..<n { idx[k] = i; choose(i + 1, k + 1) }
    }
    if n >= 5 { choose(0, 0) }
    return best
}

func handStrength(hole holeText: [String], board boardText: [String]) -> String? {
    let hole = holeText.compactMap(parseCard), board = boardText.compactMap(parseCard)
    guard hole.count == 2, board.count == boardText.count, board.count >= 3 else { return nil }
    let all = hole + board
    let boardRanks = Array(Set(board.map(\.rank))).sorted(by: >)          // distinct, high to low
    let boardCount = Dictionary(grouping: board.map(\.rank), by: { $0 }).mapValues(\.count)
    let v = handValue(all)
    let cat = v[0]
    var made: String
    // where a rank sits among the board's distinct ranks: top, second, ..., bottom
    func pairName(_ r: Int) -> String {
        guard let i = boardRanks.firstIndex(of: r) else { return "pair" }
        if i == 0 { return "top pair" }
        if i == boardRanks.count - 1 { return "bottom pair" }
        return ["top", "second", "third", "fourth"][i] + " pair"
    }
    let (a, b) = (hole[0].rank, hole[1].rank)
    let pocket = a == b
    let hitA = boardCount[a] != nil, hitB = boardCount[b] != nil
    // a pocket pair against the board's cards, e.g. "pocket 9s below 1 board card"
    func pocketName() -> String {
        let above = boardRanks.filter { $0 > a }.count
        return above == 0 ? "overpair (\(rankName(a, plural: true)))" :
            above == boardRanks.count ? "underpair (\(rankName(a, plural: true)), below every board card)" :
            "pocket \(rankName(a, plural: true)) below \(above) board card\(above == 1 ? "" : "s")"
    }
    switch cat {
    case 0:
        made = "no pair (\(rankName(max(a, b))) high)"
        if boardCount.values.contains(2) { made = "no pair of your own (the pair is on the board; \(rankName(max(a, b))) high)" }
    case 1:
        if pocket {
            made = pocketName()
        } else if hitA || hitB {
            let r = hitA ? a : b, kicker = hitA ? b : a
            made = "\(pairName(r)) (\(rankName(r, plural: true)), \(rankName(kicker)) kicker)"
        } else {
            made = "no pair of your own (the pair is on the board)"
        }
    case 2:
        if pocket {
            // the board's pair is everyone's: describe the pocket pair the way one pair would be
            let boardPair = boardCount.filter { $0.value == 2 }.keys.max() ?? 0
            made = pocketName() + "; the \(rankName(boardPair, plural: true)) pair is on the board"
        } else if hitA && hitB && boardCount[a] == 1 && boardCount[b] == 1 {
            made = "two pair using both your cards (\(rankName(max(a, b), plural: true)) and \(rankName(min(a, b), plural: true)))"
        } else if hitA || hitB {
            let r = hitA && boardCount[a] == 1 ? a : b
            made = "one pair of your own (\(pairName(r)), \(rankName(r, plural: true))) plus the board's pair"
        } else {
            made = "no pair of your own (both pairs are on the board)"
        }
    case 3:
        if pocket { made = "set of \(rankName(a, plural: true))" }
        else if (boardCount[a] ?? 0) == 2 || (boardCount[b] ?? 0) == 2 { made = "trips (one card plus the board pair)" }
        else { made = "trips on the board (no help from your cards)" }
    default:
        made = ["", "", "", "", "straight", "flush", "full house", "quads", "straight flush"][cat]
        if cat == 4 { made += " (\(rankName(v[1]))-high)" }
    }
    // the board alone has the same hand: it plays for everyone
    if board.count == 5 && cat >= 2 && handValue(board) == v { made += "; the board plays, you hold nothing better" }

    var draws: [String] = []
    if board.count < 5 && cat < 5 {
        // flush draws: four of a suit including at least one of your cards
        for s in Set(all.map(\.suit)) {
            let suited = all.filter { $0.suit == s }
            let mine = hole.filter { $0.suit == s }
            guard !mine.isEmpty else { continue }
            if suited.count == 4 {
                let nut = mine.contains { $0.rank == 14 } ? "nut " : ""
                draws.append("\(nut)flush draw (9 outs)")
            } else if suited.count == 3 && board.count == 3 && mine.count >= 1 && board.filter({ $0.suit == s }).count <= 2 {
                draws.append("backdoor flush draw (needs two more \(s))")
            }
        }
        // straight draws: ranks that would make a straight your cards are part of
        if cat < 4 {
            let mineRanks = Set(hole.map(\.rank)), allRanks = Set(all.map(\.rank))
            var completing = 0
            for r in 2...14 where !allRanks.contains(r) {
                var with = allRanks; with.insert(r)
                let top = straightTop(with)
                guard top > 0 else { continue }
                let lowStraight = top == 5 ? Set([14, 2, 3, 4, 5]) : Set(top - 4...top)
                if !lowStraight.isDisjoint(with: mineRanks) { completing += 1 }
            }
            if completing >= 2 { draws.append("open-ended straight draw (8 outs)") }
            else if completing == 1 { draws.append("gutshot straight draw (4 outs)") }
        }
        if cat == 0 {
            let over = hole.filter { $0.rank > (boardRanks.first ?? 0) }.count
            if over > 0 { draws.append("\(over) overcard\(over == 1 ? "" : "s")") }
        }
    }
    var text = "Your hand: \(made)."
    if board.count < 5 { text += " Draws: \(draws.isEmpty ? "none" : draws.joined(separator: ", "))." }
    return text
}
