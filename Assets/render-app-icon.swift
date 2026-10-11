// Original ComicReader panel-book mark. Rebuild from the repository root:
// swift Assets/render-app-icon.swift
import AppKit
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconDirectory = root.appendingPathComponent("Resources/Assets.xcassets/AppIcon.appiconset")
func render(size: Int, mac: Bool = false) -> Data {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: (mac ? CGImageAlphaInfo.premultipliedLast : CGImageAlphaInfo.noneSkipLast).rawValue)!
    ctx.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    let ink = CGColor(red: 0.10, green: 0.09, blue: 0.13, alpha: 1)
    let red = CGColor(red: 0.89, green: 0.16, blue: 0.20, alpha: 1)
    let yellow = CGColor(red: 1, green: 0.80, blue: 0.20, alpha: 1)
    if mac {
        ctx.translateBy(x: 64, y: 64); ctx.scaleBy(x: 0.875, y: 0.875)
        ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: 1024, height: 1024), cornerWidth: 210, cornerHeight: 210, transform: nil))
    } else { ctx.addRect(CGRect(x: 0, y: 0, width: 1024, height: 1024)) }
    ctx.setFillColor(red); ctx.fillPath()
    ctx.setFillColor(yellow.copy(alpha: 0.42)!)
    for x in stride(from: 64, through: 970, by: 64) {
        for y in stride(from: 64, through: 970, by: 64) {
            if mac && (x < 128 || x > 896) && (y < 128 || y > 896) { continue }
            ctx.fillEllipse(in: CGRect(x: x, y: y, width: 12, height: 12))
        }
    }
    func panel(_ points: [CGPoint], fill: CGColor) {
        ctx.beginPath(); ctx.move(to: points[0]); points.dropFirst().forEach { ctx.addLine(to: $0) }; ctx.closePath()
        ctx.setFillColor(fill); ctx.setStrokeColor(ink); ctx.setLineWidth(22); ctx.setLineJoin(.round)
        ctx.drawPath(using: .fillStroke)
    }
    // Offset paper shadow, then two open pages with a clear central spine.
    panel([CGPoint(x: 169,y: 248), CGPoint(x: 507,y: 157), CGPoint(x: 873,y: 247), CGPoint(x: 873,y: 729), CGPoint(x: 516,y: 650), CGPoint(x: 169,y: 730)], fill: ink)
    panel([CGPoint(x: 147,y: 285), CGPoint(x: 505,y: 196), CGPoint(x: 505,y: 723), CGPoint(x: 147,y: 812)], fill: CGColor(gray: 1, alpha: 1))
    panel([CGPoint(x: 505,y: 196), CGPoint(x: 854,y: 285), CGPoint(x: 854,y: 812), CGPoint(x: 505,y: 723)], fill: CGColor(gray: 1, alpha: 1))
    panel([CGPoint(x: 207,y: 522), CGPoint(x: 445,y: 463), CGPoint(x: 445,y: 676), CGPoint(x: 207,y: 735)], fill: yellow)
    panel([CGPoint(x: 565,y: 463), CGPoint(x: 794,y: 522), CGPoint(x: 794,y: 735), CGPoint(x: 565,y: 676)], fill: red)
    ctx.setStrokeColor(ink); ctx.setLineWidth(24); ctx.setLineCap(.round)
    for y in [361, 420] {
        ctx.move(to: CGPoint(x: 207,y: y)); ctx.addLine(to: CGPoint(x: 445,y: y-59)); ctx.strokePath()
        ctx.move(to: CGPoint(x: 565,y: y-59)); ctx.addLine(to: CGPoint(x: 794,y: y)); ctx.strokePath()
    }
    let result = NSMutableData()
    let destination = CGImageDestinationCreateWithData(result, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, ctx.makeImage()!, nil); CGImageDestinationFinalize(destination)
    return result as Data
}
var images: [[String:String]] = []
for (idiom, sizes, scales) in [("iphone", [20.0,29,40,60], [2,3]), ("ipad", [20.0,29,40,76], [1,2]), ("mac", [16.0,32,128,256,512], [1,2])] {
    for size in sizes { for scale in scales {
        let pixels = Int(size * Double(scale)); let filename = "\(idiom)-\(pixels).png"
        try render(size: pixels, mac: idiom == "mac").write(to: iconDirectory.appendingPathComponent(filename))
        images.append(["idiom":idiom,"filename":filename,"size":"\(Int(size))x\(Int(size))","scale":"\(scale)x"])
    }}
}
try render(size: 167).write(to: iconDirectory.appendingPathComponent("167.png"))
images.append(["idiom":"ipad","filename":"167.png","size":"83.5x83.5","scale":"2x"])
try render(size: 1024).write(to: iconDirectory.appendingPathComponent("appstore.png"))
images.append(["idiom":"ios-marketing","filename":"appstore.png","size":"1024x1024","scale":"1x"])
try JSONSerialization.data(withJSONObject:["images":images,"info":["author":"xcode","version":1]], options:[.prettyPrinted,.sortedKeys]).write(to: iconDirectory.appendingPathComponent("Contents.json"))
let launchDirectory = root.appendingPathComponent("Resources/Images.xcassets/LaunchMark.imageset")
try render(size: 256).write(to: launchDirectory.appendingPathComponent("LaunchMark.png"))
try JSONSerialization.data(withJSONObject:["images":[["idiom":"universal","filename":"LaunchMark.png"]],"info":["author":"xcode","version":1]], options:[.prettyPrinted,.sortedKeys]).write(to: launchDirectory.appendingPathComponent("Contents.json"))
