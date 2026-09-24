import SwiftUI
import UIKit

struct RemoteScreenView: View {
    let image: UIImage
    let alignTop: Bool
    let controlAllowed: Bool
    let isDraggingRemote: Bool
    @Binding var pointer: CGPoint
    @Binding var zoom: CGFloat
    @Binding var offset: CGSize
    let onCommand: (ControlCommand) -> Void

    var body: some View {
        GeometryReader { geometry in
            let viewport = ScreenViewport(viewportSize: geometry.size, imageSize: image.size,
                                          zoom: zoom, offset: offset, alignTop: alignTop)
            let rect = viewport.imageRect
            ZStack(alignment: .topLeading) {
                Color.black
                Image(uiImage: image)
                    .resizable()
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                ScreenGestures(controlAllowed: controlAllowed,
                               onTap: { point, secondary in
                                   guard controlAllowed, !isDraggingRemote,
                                         let normalized = viewport.normalizedPoint(point) else { return }
                                   pointer = normalized
                                   onCommand(ControlCommand(kind: secondary ? .rightClick : .leftClick,
                                                            x: Double(normalized.x), y: Double(normalized.y)))
                               },
                               onPointerMove: { point in
                                   guard controlAllowed, let normalized = viewport.normalizedPoint(point) else { return }
                                   pointer = normalized
                                   onCommand(ControlCommand(kind: isDraggingRemote ? .leftDrag : .move,
                                                            x: Double(normalized.x), y: Double(normalized.y)))
                               },
                               onPan: { delta in
                                   offset = ScreenViewport(viewportSize: geometry.size, imageSize: image.size,
                                                           zoom: zoom, offset: offset, alignTop: alignTop).panned(by: delta)
                               },
                               onZoom: { factor, focus in
                                   let next = ScreenViewport(viewportSize: geometry.size, imageSize: image.size,
                                                             zoom: zoom, offset: offset, alignTop: alignTop)
                                       .zoomed(by: factor, around: focus)
                                   zoom = next.zoom
                                   offset = next.offset
                               })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .clipped()
            .onChange(of: image.size) { _, _ in zoom = 1; offset = .zero }
            .onChange(of: geometry.size) { _, size in
                offset = ScreenViewport(viewportSize: size, imageSize: image.size,
                                        zoom: zoom, offset: offset, alignTop: alignTop).panned(by: .zero)
            }
            .onChange(of: alignTop) { _, _ in
                offset = ScreenViewport(viewportSize: geometry.size, imageSize: image.size,
                                        zoom: zoom, offset: offset, alignTop: alignTop).panned(by: .zero)
            }
        }
        .background(.black)
    }
}

private struct ScreenGestures: UIViewRepresentable {
    let controlAllowed: Bool
    let onTap: (CGPoint, Bool) -> Void
    let onPointerMove: (CGPoint) -> Void
    let onPan: (CGSize) -> Void
    let onZoom: (CGFloat, CGPoint) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let oneTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.oneTap(_:)))
        oneTap.numberOfTouchesRequired = 1
        view.addGestureRecognizer(oneTap)
        let twoTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.twoTap(_:)))
        twoTap.numberOfTouchesRequired = 2
        view.addGestureRecognizer(twoTap)
        let onePan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.onePan(_:)))
        onePan.minimumNumberOfTouches = 1
        onePan.maximumNumberOfTouches = 1
        view.addGestureRecognizer(onePan)
        let twoPan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.twoPan(_:)))
        twoPan.minimumNumberOfTouches = 2
        twoPan.maximumNumberOfTouches = 2
        twoPan.delegate = context.coordinator
        view.addGestureRecognizer(twoPan)
        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pinch(_:)))
        pinch.delegate = context.coordinator
        view.addGestureRecognizer(pinch)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) { context.coordinator.parent = self }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: ScreenGestures
        init(_ parent: ScreenGestures) { self.parent = parent }

        @objc func oneTap(_ sender: UITapGestureRecognizer) {
            guard sender.state == .ended, let view = sender.view else { return }
            parent.onTap(sender.location(in: view), false)
        }

        @objc func twoTap(_ sender: UITapGestureRecognizer) {
            guard sender.state == .ended, let view = sender.view else { return }
            parent.onTap(sender.location(in: view), true)
        }

        @objc func onePan(_ sender: UIPanGestureRecognizer) {
            guard let view = sender.view, sender.state == .began || sender.state == .changed else { return }
            if parent.controlAllowed {
                parent.onPointerMove(sender.location(in: view))
            } else {
                let delta = sender.translation(in: view)
                parent.onPan(CGSize(width: delta.x, height: delta.y))
                sender.setTranslation(.zero, in: view)
            }
        }

        @objc func twoPan(_ sender: UIPanGestureRecognizer) {
            guard let view = sender.view, sender.state == .began || sender.state == .changed else { return }
            let delta = sender.translation(in: view)
            parent.onPan(CGSize(width: delta.x, height: delta.y))
            sender.setTranslation(.zero, in: view)
        }

        @objc func pinch(_ sender: UIPinchGestureRecognizer) {
            guard let view = sender.view, sender.state == .began || sender.state == .changed else { return }
            parent.onZoom(sender.scale, sender.location(in: view))
            sender.scale = 1
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            gestureRecognizer is UIPinchGestureRecognizer || otherGestureRecognizer is UIPinchGestureRecognizer
        }
    }
}
