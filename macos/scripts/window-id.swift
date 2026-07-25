import CoreGraphics
import Foundation
import ImageIO

// Prints the CGWindowID of the largest on-screen window owned by argv[1]
// whose width falls within [minWidth, maxWidth]. The upper bound is what
// lets you target the small floating HUD panel while the main window is open.
//
// Secondary mode `--stddev <png>` reports the luminance spread of an image, so
// the capture script can tell a real screenshot from the uniformly black PNG
// that comes back when Screen Recording has not been granted.
if CommandLine.arguments.count > 2, CommandLine.arguments[1] == "--stddev" {
    let path = CommandLine.arguments[2]
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(src, 0, nil)
    else {
        FileHandle.standardError.write("unreadable image: \(path)\n".data(using: .utf8)!)
        exit(1)
    }
    let w = image.width, h = image.height
    var pixels = [UInt8](repeating: 0, count: w * h)
    guard let ctx = CGContext(
        data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
    ) else { exit(1) }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    let values: [Double] = pixels.map { Double($0) / 255.0 }
    let count = Double(values.count)
    let mean: Double = values.reduce(0.0, +) / count
    var sumSquares = 0.0
    for value in values {
        let delta = value - mean
        sumSquares += delta * delta
    }
    print(String(format: "%.6f", (sumSquares / count).squareRoot()))
    exit(0)
}

let owner = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "NexVoice"
let minW = CommandLine.arguments.count > 2 ? Double(CommandLine.arguments[2]) ?? 400 : 400
let maxW = CommandLine.arguments.count > 3 ? Double(CommandLine.arguments[3]) ?? .infinity : .infinity

guard let list = CGWindowListCopyWindowInfo(
    [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
) as? [[String: Any]] else {
    FileHandle.standardError.write("window list unavailable\n".data(using: .utf8)!)
    exit(1)
}

var best: (Double, Int, String)?
for w in list {
    guard (w[kCGWindowOwnerName as String] as? String) == owner,
          let boundsDict = w[kCGWindowBounds as String] as? [String: Any],
          let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
          let number = w[kCGWindowNumber as String] as? Int
    else { continue }
    if Double(bounds.width) < minW || Double(bounds.width) > maxW { continue }
    let area = Double(bounds.width * bounds.height)
    let desc = "\(Int(bounds.width))x\(Int(bounds.height))@\(Int(bounds.minX)),\(Int(bounds.minY))"
    if best == nil || area > best!.0 { best = (area, number, desc) }
}

guard let hit = best else {
    FileHandle.standardError.write("no window for \(owner)\n".data(using: .utf8)!)
    exit(1)
}
print("\(hit.1) \(hit.2)")
