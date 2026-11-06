// SPDX-License-Identifier: MIT
import AppKit

// Compact native-style silhouette. Solid template fill and reversed digits avoid gray tint.
@MainActor func makeMenuBarIcon(percent: Double?, state: PowerDisplayState) -> NSImage {
    let image = NSImage(size: NSSize(width: 39, height: 16), flipped: false) { _ in
        let body = NSRect(x: 0.75, y: 2, width: 24, height: 12)
        let outline = NSBezierPath(roundedRect: body, xRadius: 2, yRadius: 2)
        NSColor.black.setStroke(); outline.lineWidth = 1; outline.stroke()
        NSColor.black.setFill()
        NSBezierPath(roundedRect: NSRect(x: 25.5, y: 5.5, width: 1.6, height: 5), xRadius: 0.7, yRadius: 0.7).fill()
        let level = min(1, max(0, (percent ?? 0) / 100))
        let fill = NSBezierPath(roundedRect: NSRect(x: 2.25, y: 3.5, width: 21*level, height: 9), xRadius: 0.8, yRadius: 0.8)
        if level > 0 {
            NSColor.black.setFill(); fill.fill()
        }
        let value = percent.map { "\(Int(min(100,max(0,$0)).rounded()))%" } ?? "—"
        let text = NSAttributedString(string: value, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 7.5, weight: .bold),
            .foregroundColor: NSColor.black
        ])
        let size = text.size()
        let origin = NSPoint(x: body.midX-size.width/2, y: body.midY-size.height/2+0.35)
        text.draw(at: origin)
        if level > 0 {
            NSGraphicsContext.saveGraphicsState()
            fill.addClip()
            NSGraphicsContext.current?.cgContext.setBlendMode(.destinationOut)
            text.draw(at: origin)
            NSGraphicsContext.restoreGraphicsState()
        }
        if let symbol = NSImage(systemSymbolName: state.symbol, accessibilityDescription: state.title)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)) {
            symbol.draw(in: NSRect(x: 29, y: 3, width: 10, height: 10))
        }
        return true
    }
    image.isTemplate = true
    image.accessibilityDescription = "\(state.title)，电量 \(percent.map { "\(Int($0.rounded()))%" } ?? "未知")"
    return image
}
