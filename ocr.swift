// Screen reading helper for the Shimlar script (macOS Vision).
//
//   ocr <image.png>
//     Prints one line per word: "x y w h text", the box in 1/10000ths of the
//     image size, origin top-left.
//
//   ocr --grid <image.png>
//     Finds the zone map (a grid of light tiles on the dark page) and prints
//       grid <cols> <rows>
//       cell <col> <row> <mark>     for every tile that is not plain
//     with <mark> "@" for the dark tile you stand on, else the tile's letter
//     ("?" when it has one that could not be read). Row 0 is the top row.
import Foundation
import Vision
import ImageIO
import CoreGraphics

func load(_ path: String) -> CGImage? {
  guard let data = FileManager.default.contents(atPath: path),
        let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
  return CGImageSourceCreateImageAtIndex(src, 0, nil)
}

func recognise(_ image: CGImage, minHeight: Float = 0.004) -> [(String, CGRect)] {
  let request = VNRecognizeTextRequest()
  request.recognitionLevel = .accurate
  request.usesLanguageCorrection = false
  request.recognitionLanguages = ["en-US"]
  request.minimumTextHeight = minHeight
  try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
  var words: [(String, CGRect)] = []
  for obs in request.results ?? [] {
    guard let cand = obs.topCandidates(1).first else { continue }
    let s = cand.string
    var i = s.startIndex
    while i < s.endIndex {
      while i < s.endIndex, s[i] == " " { i = s.index(after: i) }
      var j = i
      while j < s.endIndex, s[j] != " " { j = s.index(after: j) }
      if i < j, let box = try? cand.boundingBox(for: i..<j) {
        words.append((String(s[i..<j]), box.boundingBox))
      }
      i = j
    }
  }
  return words
}

// ---- grid mode

struct Bitmap {
  let w: Int, h: Int
  var px: [UInt8] // RGBA
  init?(_ image: CGImage) {
    w = image.width; h = image.height
    px = [UInt8](repeating: 0, count: w * h * 4)
    guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
  }
  // 0 other, 1 white line, 2 light tile, 3 dark
  func kind(_ x: Int, _ y: Int) -> Int {
    let o = (y * w + x) * 4
    let r = Int(px[o]), g = Int(px[o + 1]), b = Int(px[o + 2])
    let sum = r + g + b, sat = max(r, g, b) - min(r, g, b)
    if sum > 690 && sat < 30 { return 1 }
    if sum > 420 && sat < 40 { return 2 }
    if sum < 200 && sat < 30 { return 3 }
    return 0
  }
}

// runs of indices where flag is true, merged when closer than `gap`
func groups(_ flags: [Bool], gap: Int) -> [(Int, Int)] {
  var out: [(Int, Int)] = []
  for (i, f) in flags.enumerated() where f {
    if let last = out.last, i - last.1 <= gap { out[out.count - 1].1 = i } else { out.append((i, i)) }
  }
  return out
}

func grid(_ image: CGImage) {
  guard let bmp = Bitmap(image) else { print("grid 0 0"); return }
  // the grid is where light pixels are dense in both directions
  var colCount = [Int](repeating: 0, count: bmp.w), rowCount = [Int](repeating: 0, count: bmp.h)
  for y in 0..<bmp.h { for x in 0..<bmp.w {
    let k = bmp.kind(x, y)
    if k == 1 || k == 2 { colCount[x] += 1; rowCount[y] += 1 }
  } }
  let colMax = colCount.max() ?? 0, rowMax = rowCount.max() ?? 0
  guard colMax > 20, rowMax > 20 else { print("grid 0 0"); return }
  let xs = groups(colCount.map { $0 * 2 > colMax }, gap: 12).max { $0.1 - $0.0 < $1.1 - $1.0 }!
  let ys = groups(rowCount.map { $0 * 2 > rowMax }, gap: 12).max { $0.1 - $0.0 < $1.1 - $1.0 }!
  let (x0, x1, y0, y1) = (xs.0, xs.1, ys.0, ys.1)
  // tiles are the stretches between the white lines
  func tiles(_ from: Int, _ to: Int, _ lineAt: (Int) -> Bool) -> [(Int, Int)] {
    let lines = groups((from...to).map(lineAt), gap: 6)
    var out: [(Int, Int)] = []
    for i in 0..<max(0, lines.count - 1) {
      let a = from + lines[i].1 + 1, b = from + lines[i + 1].0 - 1
      if b - a > 6 { out.append((a, b)) }
    }
    return out
  }
  let cols = tiles(x0, x1) { x in
    var n = 0
    for y in y0...y1 where bmp.kind(x, y) == 1 { n += 1 }
    return n * 10 > (y1 - y0) * 6
  }
  let rows = tiles(y0, y1) { y in
    var n = 0
    for x in x0...x1 where bmp.kind(x, y) == 1 { n += 1 }
    return n * 10 > (x1 - x0) * 6
  }
  print("grid \(cols.count) \(rows.count)")
  // look inside each tile
  var letters: [(Int, Int, CGRect)] = []
  for (r, ry) in rows.enumerated() { for (c, cx) in cols.enumerated() {
    let mx = (cx.1 - cx.0) / 8, my = (ry.1 - ry.0) / 8
    var dark = 0, total = 0
    for y in (ry.0 + my)...(ry.1 - my) { for x in (cx.0 + mx)...(cx.1 - mx) {
      total += 1
      if bmp.kind(x, y) == 3 { dark += 1 }
    } }
    if dark * 10 > total * 7 { print("cell \(c) \(r) @") }
    else if dark * 100 > total * 3 {
      letters.append((c, r, CGRect(x: cx.0 + 1, y: ry.0 + 1, width: cx.1 - cx.0 - 1, height: ry.1 - ry.0 - 1)))
    }
  } }
  // Read each letter: enlarge the tile, push its marble to white, and put
  // three copies side by side, which reads better than one letter alone.
  for (c, r, rect) in letters {
    var ch = "?"
    // a few renderings, until one of them reads
    for (scale, copies) in [(6, 3), (4, 3), (8, 2), (5, 5), (3, 4), (10, 1)] where ch == "?" {
      let gw = Int(rect.width) * scale, gh = Int(rect.height) * scale, pad = 10 * scale
      let W = pad * 2 + gw * copies, H = pad * 2 + gh
      var tile = [UInt8](repeating: 255, count: gw * gh)
      guard let crop = image.cropping(to: rect),
            let tctx = CGContext(data: &tile, width: gw, height: gh, bitsPerComponent: 8, bytesPerRow: gw,
                                 space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
      else { break }
      tctx.interpolationQuality = .high
      tctx.draw(crop, in: CGRect(x: 0, y: 0, width: gw, height: gh))
      var buf = [UInt8](repeating: 255, count: W * H)
      for y in 0..<gh { for x in 0..<gw {
        let v = (Int(tile[y * gw + x]) - 50) * 255 / 90
        let level = UInt8(max(0, min(255, v)))
        for copy in 0..<copies { buf[(pad + y) * W + pad + copy * gw + x] = level }
      } }
      guard let provider = CGDataProvider(data: Data(buf) as CFData),
            let img = CGImage(width: W, height: H, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: W,
                              space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                              provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
      else { break }
      let text = recognise(img, minHeight: 0.2).map { $0.0 }.joined()
      var counts: [Character: Int] = [:]
      for k in text where k.isLetter || k.isNumber { counts[k, default: 0] += 1 }
      if let best = counts.max(by: { $0.value < $1.value }) { ch = String(best.key) }
      if CommandLine.arguments.contains("--debug") {
        FileHandle.standardError.write(Data("\(c),\(r) x\(scale) n\(copies): \(text)\n".utf8))
      }
    }
    print("cell \(c) \(r) \(ch)")
  }
}

// ---- main

let args = CommandLine.arguments
if args.count >= 3, args[1] == "--grid", let image = load(args[2]) {
  grid(image)
} else if args.count == 2, let image = load(args[1]) {
  var out = ""
  func n(_ v: CGFloat) -> Int { Int((v * 10000).rounded()) }
  for (t, r) in recognise(image) {
    out += "\(n(r.minX)) \(n(1 - r.maxY)) \(n(r.width)) \(n(r.height)) \(t)\n"
  }
  FileHandle.standardOutput.write(Data(out.utf8))
} else {
  FileHandle.standardError.write(Data("usage: ocr <image.png> | ocr --grid <image.png>\n".utf8))
  exit(2)
}
