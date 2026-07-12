// prep-bg.swift — prepare a trace-art image for use as the iTerm2 terminal wallpaper.
//
// iTerm2's `SetBackgroundImageFile` escape can ONLY set the file — it can't set the scaling MODE
// (so a square 1024x1024 image gets stretched to a wide window) or a BLEND/overlay (so bright art
// drowns the text). So we bake both fixes into a processed copy here:
//
//   1. ASPECT — size the output to the terminal's own pixel aspect ratio (queried via the CSI 14t
//      escape) and draw the source aspect-FILLED (cover, centre-crop). Then whatever mode iTerm2 is
//      in — stretch / fit / fill — the image scales uniformly, so it never looks distorted.
//   2. CONTRAST — composite a semi-transparent black layer over the whole thing so text stays legible.
//
// Usage:  swift prep-bg.swift <src.png> <out.png>
// Env:    MUD_ART_BG_DIM   overlay blackness 0..1              (default 0.55)
//         MUD_ART_BG_FIT   "cover" (fill, crop) | "contain" (letterbox)   (default cover)
//         MUD_ART_BG_MAXPX cap on the output's long side in px  (default 2560)
// Falls back gracefully: if the terminal size can't be read, uses the main display's aspect; if that
// fails too, keeps the source's own (square) size — the overlay still applies. Prints nothing on
// success except... nothing (the caller already knows the out path); errors go to stderr, exit != 0.

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

func die(_ msg: String) -> Never { FileHandle.standardError.write(Data(("prep-bg: " + msg + "\n").utf8)); exit(1) }

let args = CommandLine.arguments
guard args.count >= 3 else { die("usage: prep-bg.swift <src.png> <out.png>") }
let srcPath = args[1], outPath = args[2]

let dim = max(0.0, min(1.0, Double(ProcessInfo.processInfo.environment["MUD_ART_BG_DIM"] ?? "") ?? 0.55))
let fitCover = (ProcessInfo.processInfo.environment["MUD_ART_BG_FIT"] ?? "cover").lowercased() != "contain"
let maxPx = max(256, Int(ProcessInfo.processInfo.environment["MUD_ART_BG_MAXPX"] ?? "") ?? 2560)

// --- load the source image ---------------------------------------------------------------------
guard let srcData = FileManager.default.contents(atPath: srcPath),
      let srcSrc = CGImageSourceCreateWithData(srcData as CFData, nil),
      let src = CGImageSourceCreateImageAtIndex(srcSrc, 0, nil) else { die("can't read image: \(srcPath)") }
let iw = src.width, ih = src.height

// --- target aspect: terminal pixels (CSI 14t) → main display → source's own size ----------------
func terminalPixelSize() -> (w: Int, h: Int)? {
    let fd = open("/dev/tty", O_RDWR)
    if fd < 0 { return nil }
    defer { close(fd) }
    var orig = termios()
    if tcgetattr(fd, &orig) != 0 { return nil }
    var raw = orig
    cfmakeraw(&raw)
    // read() returns after up to 0.3s even with no data, so a terminal that ignores the query can't hang us
    raw.c_cc.16 = 0     // VMIN
    raw.c_cc.17 = 3     // VTIME = 0.3s
    if tcsetattr(fd, TCSANOW, &raw) != 0 { return nil }
    defer { tcsetattr(fd, TCSANOW, &orig) }
    _ = "\u{1B}[14t".withCString { write(fd, $0, 5) }   // request text-area size in pixels
    // response: ESC [ 4 ; <height> ; <width> t
    var out = [UInt8]()
    var buf = [UInt8](repeating: 0, count: 64)
    for _ in 0..<8 {
        let n = read(fd, &buf, buf.count)
        if n <= 0 { break }
        out.append(contentsOf: buf[0..<n])
        if out.last == UInt8(ascii: "t") { break }
    }
    guard let s = String(bytes: out, encoding: .ascii), s.contains("[4;") else { return nil }
    let nums = s.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
    // nums = [4, height, width]; guard against the leading 4 and zero/garbage
    guard nums.count >= 3, nums[1] > 0, nums[2] > 0 else { return nil }
    return (w: nums[2], h: nums[1])
}

func targetSize() -> (w: Int, h: Int) {
    if let t = terminalPixelSize() { return t }
    let disp = CGMainDisplayID()
    let dw = CGDisplayPixelsWide(disp), dh = CGDisplayPixelsHigh(disp)
    if dw > 0 && dh > 0 { return (w: dw, h: dh) }
    return (w: iw, h: ih)
}

var (tw, th) = targetSize()
// cap the long side so the PNG stays small; keep the aspect exact
let longSide = max(tw, th)
if longSide > maxPx {
    let scale = Double(maxPx) / Double(longSide)
    tw = max(1, Int((Double(tw) * scale).rounded()))
    th = max(1, Int((Double(th) * scale).rounded()))
}

// --- composite: aspect-placed source + dark overlay -> RGBA context -> PNG ----------------------
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
guard let ctx = CGContext(data: nil, width: tw, height: th, bitsPerComponent: 8, bytesPerRow: 0,
                          space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    die("can't create \(tw)x\(th) context")
}
// black backdrop (shows through as letterbox bars in "contain" mode)
ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: tw, height: th))

let sx = Double(tw) / Double(iw), sy = Double(th) / Double(ih)
let scale = fitCover ? max(sx, sy) : min(sx, sy)   // cover = fill+crop, contain = fit+letterbox
let dw = Double(iw) * scale, dh = Double(ih) * scale
let dx = (Double(tw) - dw) / 2, dy = (Double(th) - dh) / 2
ctx.interpolationQuality = .high
ctx.draw(src, in: CGRect(x: dx, y: dy, width: dw, height: dh))   // overflow is clipped to the context

// semi-transparent black overlay for text contrast
ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: CGFloat(dim)))
ctx.fill(CGRect(x: 0, y: 0, width: tw, height: th))

guard let out = ctx.makeImage() else { die("compositing failed") }
let outURL = URL(fileURLWithPath: outPath) as CFURL
guard let dest = CGImageDestinationCreateWithURL(outURL, UTType.png.identifier as CFString, 1, nil) else {
    die("can't create PNG at \(outPath)")
}
CGImageDestinationAddImage(dest, out, nil)
if !CGImageDestinationFinalize(dest) { die("can't write PNG at \(outPath)") }
