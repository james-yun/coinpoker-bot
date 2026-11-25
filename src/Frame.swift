import Foundation
import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers
import Vision

// Pre-move buttons are neutral gray boxes; the table background there is dark teal.
// Pre-move state = gray in both the X/F and Call Any spots (fractions of the content area).
struct Frame {
    let base: UnsafePointer<UInt8>, width: Int, height: Int, stride: Int, top: Int

    // Fraction of pixels in a content-area rectangle (fractions, title bar excluded) matching an RGB test.
    func fraction(_ fx0: Double, _ fx1: Double, _ fy0: Double, _ fy1: Double, _ test: (Int, Int, Int) -> Bool) -> Double {
        let ch = height - top
        let x0 = Int(fx0 * Double(width)), x1 = Int(fx1 * Double(width))
        let y0 = top + Int(fy0 * Double(ch)), y1 = top + Int(fy1 * Double(ch))
        guard x1 > x0, y1 > y0 else { return 0 }
        var n = 0
        for y in y0..<y1 {
            let row = base + y * stride
            for x in x0..<x1 {
                let p = row + x * 4           // BGRA
                if test(Int(p[2]), Int(p[1]), Int(p[0])) { n += 1 }
            }
        }
        return Double(n) / Double((x1 - x0) * (y1 - y0))
    }

    // Pre-move buttons are neutral gray boxes; the table background there is dark teal.
    // Pre-move state = gray in both the X/F and Call Any spots.
    var premoveVisible: Bool {
        let gray = { (r: Int, g: Int, b: Int) in r >= 12 && max(r, g, b) <= 50 && abs(r - g) <= 8 && abs(b - g) <= 10 }
        return fraction(0.605, 0.635, 0.935, 0.985, gray) > 0.6 && fraction(0.745, 0.85, 0.86, 0.90, gray) > 0.5
    }

    // A board card is still face down (dealing animation): dark crimson card back in the board area.
    // Suit red on face-up cards is much brighter, so it doesn't count.
    var boardDealing: Bool {
        fraction(0.30, 0.70, 0.36, 0.53) { r, g, b in r > 100 && r < 180 && g < 80 && b > 45 && b < 120 && r > b + 30 } > 0.01
    }

    // Cheap checksum of the board area (below the pot label, above the chips), to notice when cards
    // are still flipping: a card turned edge-on doesn't look face down, but the area keeps changing.
    var boardChecksum: Int {
        let ch = height - top
        let x0 = Int(0.28 * Double(width)), x1 = Int(0.72 * Double(width))
        let y0 = top + Int(0.375 * Double(ch)), y1 = top + Int(0.52 * Double(ch))
        var sum = 0
        for y in Swift.stride(from: y0, to: y1, by: 4) {
            let row = base + y * stride
            for x in Swift.stride(from: x0, to: x1, by: 4) {
                let p = row + x * 4
                sum &+= Int(p[0]) &+ Int(p[1]) &* 3 &+ Int(p[2]) &* 7
            }
        }
        return sum
    }

    // Our hole cards are face up (white card faces at the bottom center). Off before cards are
    // opened and after we fold, so pre-moves aren't asked about without a hand to judge.
    var cardsFaceUp: Bool {
        fraction(0.44, 0.56, 0.73, 0.83) { r, g, b in r > 215 && g > 215 && b > 215 } > 0.3
    }

    // EV Cashout dialog: a green Accept button where Raise/Bet normally is, plus its red Reject
    // where Fold is (so without this check the dialog looks like our turn). Requiring both rules
    // out other green buttons there, like Join Now / Find Seat after leaving the seat.
    var cashoutVisible: Bool {
        fraction(0.87, 0.97, 0.92, 0.98) { r, g, b in r < 70 && g > 110 && b < 150 && g > r + 50 } > 0.5 &&
        fraction(0.61, 0.72, 0.925, 0.975) { r, g, b in r > 150 && g < 90 && b < 100 } > 0.5
    }

    // Which labels the four sizing buttons show: "2X 2.5X 3X 4X" (preflop, nobody in yet) or
    // "33% 50% 75% Max". Told apart by the width of the first button's text: "2X" spans about
    // 1.8% of the window, "33%" about 3.3%; no text means no sizing buttons (facing an all-in).
    var presetKind: String {
        let ch = height - top
        let y0 = top + Int(0.855 * Double(ch)), y1 = top + Int(0.89 * Double(ch))
        // width of the bright label text between two x fractions (0 if none)
        func textWidth(_ a: Double, _ b: Double) -> Double {
            var lo = Int.max, hi = Int.min
            for x in Int(a * Double(width))..<Int(b * Double(width)) {
                for y in y0..<y1 {
                    let p = base + y * stride + x * 4
                    if Int(p[0]) + Int(p[1]) + Int(p[2]) > 600 { lo = min(lo, x); hi = max(hi, x); break }
                }
            }
            return hi > lo ? Double(hi - lo) / Double(width) : 0
        }
        let first = textWidth(0.597, 0.652)
        if first > 0 { return first < 0.025 ? "multiplier" : "percent" }
        // In a tiny pot 33% is below the minimum bet and greyed out, but 50%/75%/Max still show.
        return textWidth(0.652, 0.70) > 0 ? "percent" : "none"
    }

    // Card-squeeze overlay: a red card back in the big circle plus the green OPEN button.
    var openVisible: Bool {
        fraction(0.42, 0.58, 0.74, 0.92) { r, g, b in r > 100 && g < 80 && b < 120 && r > b + 30 } > 0.2 &&
        fraction(0.74, 0.82, 0.92, 0.97) { r, g, b in r < 45 && g > 115 && b < 130 && g > b + 15 } > 0.5
    }
}

// Debounced rising edge: fires when a signal turns on after being off for more than offGrace.
struct Edge {
    var had = false
    var offSince: Double? = nil
    mutating func update(_ on: Bool, now: Double) -> Bool {
        var rose = false
        if on {
            if !had || (offSince.map { now - $0 > offGrace } ?? false) { rose = true }
            had = true; offSince = nil
        } else if had && offSince == nil {
            offSince = now
        } else if let t = offSince, now - t > offGrace {
            had = false; offSince = nil
        }
        return rose
    }
}

let writeQueue = DispatchQueue(label: "engine.write", qos: .utility)

func makeImage(_ data: Data, width: Int, height: Int, stride: Int) -> CGImage? {
    let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
    guard let provider = CGDataProvider(data: data as CFData) else { return nil }
    return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: stride,
                   space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: info),
                   provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
}

func writePNG(_ data: Data, width: Int, height: Int, stride: Int, to path: String) {
    guard let img = makeImage(data, width: width, height: height, stride: stride) else { return }
    let tmp = path + ".tmp"
    let url = URL(fileURLWithPath: tmp) as CFURL
    guard let dst = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(dst, img, nil)
    if CGImageDestinationFinalize(dst) { _ = rename(tmp, path) }   // atomic replace
}
