import CoreGraphics

/// Describes the displayed screen rectangle and maps touches to Mac coordinates.
struct ScreenViewport {
    let viewportSize: CGSize
    let imageSize: CGSize
    let zoom: CGFloat
    let offset: CGSize
    let alignTop: Bool

    private var fittedSize: CGSize {
        guard viewportSize.width > 0, viewportSize.height > 0,
              imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let fit = min(viewportSize.width / imageSize.width, viewportSize.height / imageSize.height)
        return CGSize(width: imageSize.width * fit, height: imageSize.height * fit)
    }

    var contentSize: CGSize {
        CGSize(width: fittedSize.width * zoom, height: fittedSize.height * zoom)
    }

    private var baseOrigin: CGPoint {
        CGPoint(x: (viewportSize.width - contentSize.width) / 2,
                y: alignTop ? 0 : (viewportSize.height - contentSize.height) / 2)
    }

    var imageRect: CGRect {
        CGRect(origin: CGPoint(x: baseOrigin.x + offset.width, y: baseOrigin.y + offset.height),
               size: contentSize)
    }

    func normalizedPoint(_ point: CGPoint) -> CGPoint? {
        let rect = imageRect
        guard rect.width > 0, rect.height > 0, rect.contains(point) else { return nil }
        return CGPoint(x: min(1, max(0, (point.x - rect.minX) / rect.width)),
                       y: min(1, max(0, (point.y - rect.minY) / rect.height)))
    }

    func panned(by delta: CGSize) -> CGSize {
        clamped(CGSize(width: offset.width + delta.width, height: offset.height + delta.height))
    }

    func zoomed(by factor: CGFloat, around focus: CGPoint) -> (zoom: CGFloat, offset: CGSize) {
        let nextZoom = min(4, max(1, zoom * factor))
        guard nextZoom != zoom, contentSize.width > 0, contentSize.height > 0 else {
            return (zoom, offset)
        }
        let before = imageRect
        let fractionX = min(1, max(0, (focus.x - before.minX) / before.width))
        let fractionY = min(1, max(0, (focus.y - before.minY) / before.height))
        let next = ScreenViewport(viewportSize: viewportSize, imageSize: imageSize,
                                  zoom: nextZoom, offset: .zero, alignTop: alignTop)
        let nextBase = next.baseOrigin
        let proposed = CGSize(width: focus.x - fractionX * next.contentSize.width - nextBase.x,
                              height: focus.y - fractionY * next.contentSize.height - nextBase.y)
        return (nextZoom, next.clamped(proposed))
    }

    private func clamped(_ proposed: CGSize) -> CGSize {
        let excessX = max(0, contentSize.width - viewportSize.width)
        let excessY = max(0, contentSize.height - viewportSize.height)
        return CGSize(width: min(excessX / 2, max(-excessX / 2, proposed.width)),
                      height: alignTop ? min(0, max(-excessY, proposed.height))
                                       : min(excessY / 2, max(-excessY / 2, proposed.height)))
    }
}
