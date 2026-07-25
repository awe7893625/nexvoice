import CoreGraphics
import Foundation

// Prints the CGWindowID of the largest on-screen window owned by argv[1].
let owner = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "NexVoice"
let minW = CommandLine.arguments.count > 2 ? Double(CommandLine.arguments[2]) ?? 400 : 400

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
    if Double(bounds.width) < minW { continue }
    let area = Double(bounds.width * bounds.height)
    let desc = "\(Int(bounds.width))x\(Int(bounds.height))@\(Int(bounds.minX)),\(Int(bounds.minY))"
    if best == nil || area > best!.0 { best = (area, number, desc) }
}

guard let hit = best else {
    FileHandle.standardError.write("no window for \(owner)\n".data(using: .utf8)!)
    exit(1)
}
print("\(hit.1) \(hit.2)")
