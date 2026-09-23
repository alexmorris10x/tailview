import CoreGraphics
import Foundation

@main
struct ViewportSmoke {
    static func main() throws {
        let screen = CGSize(width: 1000, height: 1000)
        let image = CGSize(width: 1000, height: 500)
        let centered = ScreenViewport(viewportSize: screen, imageSize: image,
                                      zoom: 1, offset: .zero, alignTop: false)
        let top = ScreenViewport(viewportSize: screen, imageSize: image,
                                 zoom: 1, offset: .zero, alignTop: true)
        try check(centered.imageRect.minY == 250, "Centered screen moved")
        try check(top.imageRect.minY == 0, "Top setting did not align screen")
        try check(centered.normalizedPoint(CGPoint(x: 500, y: 500)) == CGPoint(x: 0.5, y: 0.5),
                  "Pointer coordinates are wrong")
        try check(top.normalizedPoint(CGPoint(x: 500, y: 750)) == nil,
                  "Touches outside the screen were accepted")
        let enlarged = centered.zoomed(by: 2, around: CGPoint(x: 500, y: 500))
        let zoomed = ScreenViewport(viewportSize: screen, imageSize: image,
                                    zoom: enlarged.zoom, offset: enlarged.offset, alignTop: false)
        try check(zoomed.normalizedPoint(CGPoint(x: 500, y: 500)) == CGPoint(x: 0.5, y: 0.5),
                  "Zoom changed the touched Mac point")
        let panned = ScreenViewport(viewportSize: screen, imageSize: image,
                                    zoom: 2, offset: CGSize(width: 10000, height: 10000), alignTop: false)
        try check(panned.panned(by: .zero).width == 500, "Pan escaped horizontal bounds")
        let moved = ScreenViewport(viewportSize: screen, imageSize: image,
                                   zoom: 2, offset: zoomed.panned(by: CGSize(width: -100, height: 0)),
                                   alignTop: false)
        try check(moved.normalizedPoint(CGPoint(x: 500, y: 500)) == CGPoint(x: 0.55, y: 0.5),
                  "Pan did not move the visible Mac point")
        print("Viewport smoke passed: top alignment, mapping, zoom focus, pan bounds")
    }

    private static func check(_ result: Bool, _ message: String) throws {
        if !result { throw ViewportError.message(message) }
    }

    private enum ViewportError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
    }
}
