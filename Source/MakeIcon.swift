// SPDX-License-Identifier: MIT
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Vector-drawn local app icon. No network or image dependencies.
let folder = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
for (points, scale) in [(16,1),(16,2),(32,1),(32,2),(128,1),(128,2),(256,1),(256,2),(512,1),(512,2)] {
    let size = points * scale
    guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fatalError("Icon context") }
    context.scaleBy(x: CGFloat(size)/1024, y: CGFloat(size)/1024)
    context.setShadow(offset: CGSize(width:0,height:-12), blur:24, color:CGColor(gray:0,alpha:0.15))
    let tile = CGPath(roundedRect: CGRect(x:64,y:64,width:896,height:896), cornerWidth:202,cornerHeight:202,transform:nil)
    context.addPath(tile);context.setFillColor(CGColor(red:1,green:0.96,blue:0.90,alpha:1));context.fillPath()
    context.setShadow(offset:.zero,blur:0,color:nil)
    let battery = CGPath(roundedRect:CGRect(x:195,y:326,width:594,height:372),cornerWidth:76,cornerHeight:76,transform:nil)
    context.addPath(battery);context.setFillColor(CGColor(red:0.96,green:0.47,blue:0.16,alpha:1));context.fillPath()
    context.addPath(CGPath(roundedRect:CGRect(x:812,y:433,width:44,height:158),cornerWidth:18,cornerHeight:18,transform:nil))
    context.setFillColor(CGColor(red:0.96,green:0.47,blue:0.16,alpha:1));context.fillPath()
    let bolt = CGMutablePath();bolt.move(to:CGPoint(x:530,y:654));bolt.addLine(to:CGPoint(x:410,y:492));bolt.addLine(to:CGPoint(x:490,y:492))
    bolt.addLine(to:CGPoint(x:458,y:370));bolt.addLine(to:CGPoint(x:599,y:543));bolt.addLine(to:CGPoint(x:515,y:543));bolt.closeSubpath()
    context.addPath(bolt);context.setFillColor(CGColor(gray:1,alpha:1));context.fillPath()
    guard let image=context.makeImage() else { fatalError("Icon image") }
    let name="icon_\(points)x\(points)" + (scale == 2 ? "@2x" : "") + ".png"
    guard let destination=CGImageDestinationCreateWithURL(folder.appendingPathComponent(name) as CFURL,UTType.png.identifier as CFString,1,nil) else {fatalError("Icon output")}
    CGImageDestinationAddImage(destination,image,nil)
    guard CGImageDestinationFinalize(destination) else {fatalError("Icon write")}
}
// Modern ICNS stores PNG representations in a big-endian length-prefixed container.
func length(_ value: Int) -> Data { var v=UInt32(value).bigEndian; return withUnsafeBytes(of:&v) { Data($0) } }
var entries=Data()
for (type,name) in [("icp4","icon_16x16.png"),("icp5","icon_32x32.png"),("icp6","icon_32x32@2x.png"),
                    ("ic07","icon_128x128.png"),("ic08","icon_256x256.png"),("ic09","icon_512x512.png"),("ic10","icon_512x512@2x.png")] {
    let png=try Data(contentsOf:folder.appendingPathComponent(name))
    entries.append(Data(type.utf8));entries.append(length(png.count+8));entries.append(png)
}
var container=Data("icns".utf8);container.append(length(entries.count+8));container.append(entries)
let iconURL=URL(fileURLWithPath:CommandLine.arguments[2]);try container.write(to:iconURL)
guard let source=CGImageSourceCreateWithURL(iconURL as CFURL,nil),CGImageSourceGetCount(source)>0,
      CGImageSourceCreateImageAtIndex(source,0,nil) != nil else {fatalError("Icon verification")}
