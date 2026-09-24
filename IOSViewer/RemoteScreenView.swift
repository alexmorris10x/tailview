import SwiftUI
import UIKit

struct RemoteScreenView: View {
    let image: UIImage
    let alignTop: Bool
    let controlAllowed: Bool
    let isDraggingRemote: Bool
    let panView: Bool
    @Binding var isTouchDraggingRemote: Bool
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
                if isTouchDraggingRemote {
                    Label("Dragging", systemImage: "hand.draw.fill")
                        .font(.caption.bold())
                        .padding(8)
                        .background(.regularMaterial, in: Capsule())
                        .padding(12)
                        .allowsHitTesting(false)
                }
                ScreenGestures(controlAllowed: controlAllowed,
                               panView: panView,
                               onTap: { point, secondary in
                                   guard controlAllowed, !isDraggingRemote, !isTouchDraggingRemote,
                                         let normalized = viewport.normalizedPoint(point) else { return }
                                   pointer = normalized
                                   onCommand(ControlCommand(kind: secondary ? .rightClick : .leftClick,
                                                            x: Double(normalized.x), y: Double(normalized.y)))
                               },
                               onPointerMove: { point in
                                   guard controlAllowed, !isTouchDraggingRemote,
                                         let normalized = viewport.normalizedPoint(point) else { return }
                                   pointer = normalized
                                   onCommand(ControlCommand(kind: isDraggingRemote ? .leftDrag : .move,
                                                            x: Double(normalized.x), y: Double(normalized.y)))
                               },
                               onHoldDrag: { phase, point in
                                   switch phase {
                                   case .began:
                                       guard controlAllowed, !isDraggingRemote,
                                             let normalized = viewport.normalizedPoint(point) else { return false }
                                       pointer = normalized
                                       isTouchDraggingRemote = true
                                       onCommand(ControlCommand(kind: .leftDown,
                                                                x: Double(normalized.x), y: Double(normalized.y)))
                                       return true
                                   case .changed:
                                       if let normalized = viewport.normalizedPoint(point) {
                                           pointer = normalized
                                           onCommand(ControlCommand(kind: .leftDrag,
                                                                    x: Double(normalized.x), y: Double(normalized.y)))
                                       }
                                       return true
                                   case .ended:
                                       let normalized = viewport.normalizedPoint(point) ?? pointer
                                       pointer = normalized
                                       onCommand(ControlCommand(kind: .leftUp,
                                                                x: Double(normalized.x), y: Double(normalized.y)))
                                       isTouchDraggingRemote = false
                                       return false
                                   }
                               },
                               onScroll: { vertical, horizontal, point, isStarting in
                                   guard controlAllowed, !isDraggingRemote, !isTouchDraggingRemote else { return }
                                   if let normalized = viewport.normalizedPoint(point) {
                                       pointer = normalized
                                       if isStarting {
                                           onCommand(ControlCommand(kind: .move,
                                                                    x: Double(normalized.x), y: Double(normalized.y)))
                                       }
                                   }
                                   if vertical != 0 || horizontal != 0 {
                                       onCommand(ControlCommand(kind: .scroll,
                                                                amount: vertical == 0 ? nil : vertical,
                                                                horizontalAmount: horizontal == 0 ? nil : horizontal))
                                   }
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
            .onDisappear {
                if isTouchDraggingRemote {
                    onCommand(ControlCommand(kind: .leftUp,
                                             x: Double(pointer.x), y: Double(pointer.y)))
                    isTouchDraggingRemote = false
                }
            }
        }
        .background(.black)
    }
}

private struct ScreenGestures: UIViewRepresentable {
    enum HoldDragPhase { case began, changed, ended }

    let controlAllowed: Bool
    let panView: Bool
    let onTap: (CGPoint, Bool) -> Void
    let onPointerMove: (CGPoint) -> Void
    let onHoldDrag: (HoldDragPhase, CGPoint) -> Bool
    let onScroll: (Int, Int, CGPoint, Bool) -> Void
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
        onePan.delegate = context.coordinator
        view.addGestureRecognizer(onePan)
        let hold = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.holdDrag(_:)))
        hold.minimumPressDuration = 0.35
        hold.allowableMovement = 12
        hold.numberOfTouchesRequired = 1
        hold.delegate = context.coordinator
        view.addGestureRecognizer(hold)
        let twoPan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.twoPan(_:)))
        twoPan.minimumNumberOfTouches = 2
        twoPan.maximumNumberOfTouches = 2
        twoPan.delegate = context.coordinator
        view.addGestureRecognizer(twoPan)
        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pinch(_:)))
        pinch.delegate = context.coordinator
        view.addGestureRecognizer(pinch)
        context.coordinator.onePanRecognizer = onePan
        context.coordinator.holdRecognizer = hold
        context.coordinator.twoPanRecognizer = twoPan
        context.coordinator.pinchRecognizer = pinch
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) { context.coordinator.parent = self }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: ScreenGestures
        weak var onePanRecognizer: UIPanGestureRecognizer?
        weak var twoPanRecognizer: UIPanGestureRecognizer?
        weak var holdRecognizer: UILongPressGestureRecognizer?
        weak var pinchRecognizer: UIPinchGestureRecognizer?
        private var dragActive = false
        private var pinchActive = false
        private var twoPanPansView = false
        private var scrollRemainder = CGPoint.zero
        private let pixelsPerScrollLine: CGFloat = 28
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
            guard !dragActive else { return }
            if parent.controlAllowed {
                parent.onPointerMove(sender.location(in: view))
            } else {
                let delta = sender.translation(in: view)
                parent.onPan(CGSize(width: delta.x, height: delta.y))
                sender.setTranslation(.zero, in: view)
            }
        }

        @objc func holdDrag(_ sender: UILongPressGestureRecognizer) {
            guard let view = sender.view else { return }
            let point = sender.location(in: view)
            switch sender.state {
            case .began:
                dragActive = parent.onHoldDrag(.began, point)
            case .changed:
                if dragActive { _ = parent.onHoldDrag(.changed, point) }
            case .ended, .cancelled, .failed:
                if dragActive { _ = parent.onHoldDrag(.ended, point) }
                dragActive = false
            default: break
            }
        }

        @objc func twoPan(_ sender: UIPanGestureRecognizer) {
            guard let view = sender.view else { return }
            if sender.state == .ended || sender.state == .cancelled || sender.state == .failed {
                twoPanPansView = false
                scrollRemainder = .zero
                return
            }
            guard sender.state == .began || sender.state == .changed else { return }
            if sender.state == .began {
                twoPanPansView = parent.panView || !parent.controlAllowed || pinchActive
                scrollRemainder = .zero
                if !twoPanPansView {
                    parent.onScroll(0, 0, sender.location(in: view), true)
                }
            }
            let delta = sender.translation(in: view)
            if twoPanPansView || pinchActive {
                parent.onPan(CGSize(width: delta.x, height: delta.y))
            } else {
                // Finger movement is opposite the direction the page should travel.
                scrollRemainder.x -= delta.x
                scrollRemainder.y -= delta.y
                let horizontal = max(-8, min(8, Int(scrollRemainder.x / pixelsPerScrollLine)))
                let vertical = max(-8, min(8, Int(scrollRemainder.y / pixelsPerScrollLine)))
                scrollRemainder.x -= CGFloat(horizontal) * pixelsPerScrollLine
                scrollRemainder.y -= CGFloat(vertical) * pixelsPerScrollLine
                if vertical != 0 || horizontal != 0 {
                    parent.onScroll(vertical, horizontal, sender.location(in: view), false)
                }
            }
            sender.setTranslation(.zero, in: view)
        }

        @objc func pinch(_ sender: UIPinchGestureRecognizer) {
            if sender.state == .ended || sender.state == .cancelled || sender.state == .failed {
                pinchActive = false
                return
            }
            guard let view = sender.view, sender.state == .began || sender.state == .changed else { return }
            pinchActive = true
            twoPanPansView = true
            scrollRemainder = .zero
            parent.onZoom(sender.scale, sender.location(in: view))
            sender.scale = 1
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            let pair = [gestureRecognizer, otherGestureRecognizer]
            return (pair.contains { $0 === pinchRecognizer } && pair.contains { $0 === twoPanRecognizer })
                || (pair.contains { $0 === holdRecognizer } && pair.contains { $0 === onePanRecognizer })
        }
    }
}
