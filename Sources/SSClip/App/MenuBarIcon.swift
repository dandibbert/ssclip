import AppKit

@MainActor
enum MenuBarIcon {
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.setShouldAntialias(true)
            context.setStrokeColor(NSColor.black.cgColor)
            context.setLineWidth(2.9)
            context.setLineCap(.round)

            for path in paths {
                context.beginPath()
                context.move(to: path.start)
                context.addCurve(
                    to: path.end,
                    control1: path.control1,
                    control2: path.control2
                )
                context.strokePath()
            }

            context.saveGState()
            context.setBlendMode(.clear)
            context.addPath(CGPath(
                roundedRect: CGRect(x: 7.1, y: 6.4, width: 4.2, height: 4.2),
                cornerWidth: 1,
                cornerHeight: 1,
                transform: nil
            ))
            context.fillPath()
            context.restoreGState()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "SSClip"
        return image
    }()

    private static let paths: [LinkedFlowPath] = [
        LinkedFlowPath(
            start: CGPoint(x: 3.2, y: 13.2),
            control1: CGPoint(x: 6.0, y: 15.2),
            control2: CGPoint(x: 11.3, y: 5.7),
            end: CGPoint(x: 14.8, y: 7.6)
        ),
        LinkedFlowPath(
            start: CGPoint(x: 3.2, y: 8.2),
            control1: CGPoint(x: 6.0, y: 10.2),
            control2: CGPoint(x: 11.3, y: 0.7),
            end: CGPoint(x: 14.8, y: 2.6)
        )
    ]
}

private struct LinkedFlowPath {
    let start: CGPoint
    let control1: CGPoint
    let control2: CGPoint
    let end: CGPoint
}
