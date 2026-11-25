import Foundation
import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers
import Vision

// Runs `<cmd> <png> <turn|premove> <cards>` once and returns everything it prints.
// <cards> is what the card reader saw, e.g. "Your cards: A♣ 3♣ (suited). Board: Q♦ K♥ 2♣."
func decideOnce(_ cmd: String, png: String, mode: String, cards: String) -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", cmd + " \"$1\" \"$2\" \"$3\"", "sh", png, mode, cards]
    let pipe = Pipe()
    p.standardOutput = pipe
    do { try p.run() } catch { log("DECIDE: \(error.localizedDescription)"); return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

// One hand in one model conversation: `<cmd> --session` reads "png<TAB>mode<TAB>cards" lines and
// answers each with the reply plus a "<<END>>" line. Started when the hand's cards are dealt, so its
// startup is hidden; later decisions reuse the cached conversation (about half the time of a
// one-shot call) and the model remembers the hand's earlier actions.
final class HandSession {
    private let proc = Process()
    private let input: FileHandle
    private let lock = NSLock()
    private let ready = DispatchSemaphore(value: 0)
    private let serial = DispatchQueue(label: "engine.session")
    private var buffer = Data()
    private var eof = false

    init?(_ cmd: String) {
        let inPipe = Pipe(), outPipe = Pipe()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", cmd + " --session"]
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        do { try proc.run() } catch { return nil }
        input = inPipe.fileHandleForWriting
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard let self else { return }
            self.lock.lock()
            if d.isEmpty { self.eof = true; h.readabilityHandler = nil } else { self.buffer.append(d) }
            self.lock.unlock()
            self.ready.signal()
        }
    }

    // Blocking; returns nil if the session died or took longer than `timeout` (then it's ended).
    func ask(png: String, mode: String, cards: String, timeout: Double = 25) -> String? {
        serial.sync {
            guard proc.isRunning else { return nil }
            let line = "\(png)\t\(mode)\t\(cards.replacingOccurrences(of: "\t", with: " "))\n"
            do { try input.write(contentsOf: Data(line.utf8)) } catch { return nil }
            let marker = Data("<<END>>\n".utf8), deadline = Date().addingTimeInterval(timeout)
            while true {
                lock.lock()
                if let r = buffer.range(of: marker) {
                    let text = String(decoding: buffer[..<r.lowerBound], as: UTF8.self)
                    buffer.removeSubrange(..<r.upperBound)
                    lock.unlock()
                    return text
                }
                let done = eof
                lock.unlock()
                if done || ready.wait(timeout: .now() + deadline.timeIntervalSinceNow) == .timedOut, Date() >= deadline || done {
                    close(); return nil
                }
            }
        }
    }

    // Ending stdin makes the helper (and its claude process) exit.
    func close() { try? input.close() }
}

// <shot>.txt next to the screenshot: what the engine read and what the decider answered.
func recordDecision(png: String, mode: String, cards: String, text: String, via: String, secs: Double) {
    let note = "mode: \(mode) (\(via))\ncards: \(cards.isEmpty ? "(not read)" : cards)\n\n\(text)"
    try? note.write(toFile: (png as NSString).deletingPathExtension + ".txt", atomically: true, encoding: .utf8)
    if debug {
        let body = text.split(whereSeparator: \.isNewline).map { "    " + $0 }.joined(separator: "\n")
        log("DEBUG: decider (\((png as NSString).lastPathComponent), \(mode), \(via)) took \(String(format: "%.1f", secs))s:\n\(body)")
    }
}

func lastLine(_ text: String) -> String? {
    text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty }
}
