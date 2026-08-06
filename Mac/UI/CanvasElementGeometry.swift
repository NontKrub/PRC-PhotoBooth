import SwiftUI
import CoreGraphics

enum CanvasElementResizeHandle: CaseIterable, Equatable, Sendable {
    case n, s, e, w, ne, nw, se, sw

    var isCorner: Bool {
        switch self {
        case .ne, .nw, .se, .sw: return true
        case .n, .s, .e, .w: return false
        }
    }
}

enum CanvasElementGeometry {
    static func canvasRect(_ normalizedRect: CGRect, in canvasSize: CGSize) -> CGRect {
        CGRect(
            x: normalizedRect.minX * canvasSize.width,
            y: normalizedRect.minY * canvasSize.height,
            width: normalizedRect.width * canvasSize.width,
            height: normalizedRect.height * canvasSize.height
        )
    }

    static func normalizedRect(_ rect: CGRect, in canvasSize: CGSize) -> CGRect {
        guard canvasSize.width > 0, canvasSize.height > 0 else { return .zero }
        return CGRect(
            x: rect.minX / canvasSize.width,
            y: rect.minY / canvasSize.height,
            width: rect.width / canvasSize.width,
            height: rect.height / canvasSize.height
        )
    }

    static func normalizedAndClampedRect(_ rect: CGRect, in canvasSize: CGSize) -> CGRect {
        guard rect.origin.x.isFinite,
              rect.origin.y.isFinite,
              rect.width.isFinite,
              rect.height.isFinite,
              canvasSize.width.isFinite,
              canvasSize.height.isFinite,
              canvasSize.width > 0,
              canvasSize.height > 0 else { return .zero }

        let left = min(max(rect.minX, 0), canvasSize.width)
        let top = min(max(rect.minY, 0), canvasSize.height)
        let right = min(max(rect.maxX, left), canvasSize.width)
        let bottom = min(max(rect.maxY, top), canvasSize.height)
        return CGRect(
            x: left / canvasSize.width,
            y: top / canvasSize.height,
            width: (right - left) / canvasSize.width,
            height: (bottom - top) / canvasSize.height
        )
    }

    static func moved(_ rect: CGRect, by delta: CGSize, in canvasSize: CGSize) -> CGRect {
        clamped(rect.offsetBy(dx: delta.width, dy: delta.height), in: canvasSize)
    }

    static func duplicated(_ rect: CGRect, offset: CGSize, in canvasSize: CGSize) -> CGRect {
        moved(rect, by: offset, in: canvasSize)
    }

    static func resized(
        _ rect: CGRect,
        by handle: CanvasElementResizeHandle,
        delta: CGSize,
        minimumSize: CGSize,
        in canvasSize: CGSize
    ) -> CGRect {
        guard rect.origin.x.isFinite,
              rect.origin.y.isFinite,
              rect.width.isFinite,
              rect.height.isFinite,
              delta.width.isFinite,
              delta.height.isFinite,
              canvasSize.width.isFinite,
              canvasSize.height.isFinite,
              canvasSize.width > 0,
              canvasSize.height > 0 else { return rect }

        let left = rect.minX
        let right = rect.maxX
        let top = rect.minY
        let bottom = rect.maxY
        let minimumWidth = min(max(1, minimumSize.width.isFinite ? minimumSize.width : 1), canvasSize.width)
        let minimumHeight = min(max(1, minimumSize.height.isFinite ? minimumSize.height : 1), canvasSize.height)
        var newLeft = left
        var newRight = right
        var newTop = top
        var newBottom = bottom

        switch handle {
        case .n:
            newTop = min(max(top + delta.height, 0), bottom - minimumHeight)
        case .s:
            newBottom = max(min(bottom + delta.height, canvasSize.height), top + minimumHeight)
        case .e:
            newRight = max(min(right + delta.width, canvasSize.width), left + minimumWidth)
        case .w:
            newLeft = min(max(left + delta.width, 0), right - minimumWidth)
        case .ne:
            newTop = min(max(top + delta.height, 0), bottom - minimumHeight)
            newRight = max(min(right + delta.width, canvasSize.width), left + minimumWidth)
        case .nw:
            newLeft = min(max(left + delta.width, 0), right - minimumWidth)
            newTop = min(max(top + delta.height, 0), bottom - minimumHeight)
        case .se:
            newRight = max(min(right + delta.width, canvasSize.width), left + minimumWidth)
            newBottom = max(min(bottom + delta.height, canvasSize.height), top + minimumHeight)
        case .sw:
            newLeft = min(max(left + delta.width, 0), right - minimumWidth)
            newBottom = max(min(bottom + delta.height, canvasSize.height), top + minimumHeight)
        }
        return CGRect(x: newLeft, y: newTop, width: newRight - newLeft, height: newBottom - newTop)
    }

    static func centeredSquare(in rect: CGRect) -> CGRect {
        let side = min(rect.width, rect.height)
        return CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
    }

    private static func clamped(_ rect: CGRect, in canvasSize: CGSize, minimumSize: CGSize = .zero) -> CGRect {
        let minWidth = min(max(0, minimumSize.width), max(0, canvasSize.width))
        let minHeight = min(max(0, minimumSize.height), max(0, canvasSize.height))
        let width = min(max(rect.width, minWidth), max(0, canvasSize.width))
        let height = min(max(rect.height, minHeight), max(0, canvasSize.height))
        let x = min(max(rect.minX, 0), max(0, canvasSize.width - width))
        let y = min(max(rect.minY, 0), max(0, canvasSize.height - height))
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

struct ResizableCanvasElementView<Content: View>: View {
    let rect: CGRect
    let rotation: Double
    let isSelected: Bool
    let minimumSize: CGSize
    let canvasSize: CGSize
    let onTap: () -> Void
    let onMove: (CGSize) -> Void
    let onResize: (CGRect) -> Void
    @ViewBuilder let content: () -> Content

    @GestureState private var dragOffset: CGSize = .zero
    @State private var resizeStartRect: CGRect?
    @State private var liveResizeRect: CGRect?

    init(
        rect: CGRect,
        rotation: Double,
        isSelected: Bool,
        minimumSize: CGSize,
        canvasSize: CGSize,
        onTap: @escaping () -> Void,
        onMove: @escaping (CGSize) -> Void,
        onResize: @escaping (CGRect) -> Void,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.rect = rect
        self.rotation = rotation
        self.isSelected = isSelected
        self.minimumSize = minimumSize
        self.canvasSize = canvasSize
        self.onTap = onTap
        self.onMove = onMove
        self.onResize = onResize
        self.content = content
    }

    var body: some View {
        let displayRect = (liveResizeRect ?? rect).offsetBy(dx: dragOffset.width, dy: dragOffset.height)

        ZStack {
            content()
                .frame(width: displayRect.width, height: displayRect.height)
                .contentShape(Rectangle())
                .overlay {
                    Rectangle().strokeBorder(isSelected ? Color.accentColor : .white.opacity(0.7), lineWidth: isSelected ? 2 : 1)
                }
                .rotationEffect(.degrees(rotation))
                .position(x: displayRect.midX, y: displayRect.midY)
                .gesture(
                    DragGesture()
                        .updating($dragOffset) { value, state, _ in state = value.translation }
                        .onEnded { value in onMove(value.translation) }
                )
                .onTapGesture(perform: onTap)

            if isSelected {
                ForEach(CanvasElementResizeHandle.allCases, id: \.self) { handle in
                    resizeHandle(handle, in: displayRect)
                        .zIndex(1)
                }
            }
        }
        .frame(width: canvasSize.width, height: canvasSize.height, alignment: .topLeading)
        .zIndex(isSelected ? 1 : 0)
    }

    private func resizeHandle(_ handle: CanvasElementResizeHandle, in rect: CGRect) -> some View {
        let point: CGPoint
        switch handle {
        case .nw: point = CGPoint(x: rect.minX, y: rect.minY)
        case .n: point = CGPoint(x: rect.midX, y: rect.minY)
        case .ne: point = CGPoint(x: rect.maxX, y: rect.minY)
        case .w: point = CGPoint(x: rect.minX, y: rect.midY)
        case .e: point = CGPoint(x: rect.maxX, y: rect.midY)
        case .sw: point = CGPoint(x: rect.minX, y: rect.maxY)
        case .s: point = CGPoint(x: rect.midX, y: rect.maxY)
        case .se: point = CGPoint(x: rect.maxX, y: rect.maxY)
        }
        let size: CGFloat = handle.isCorner ? 10 : 8
        return ZStack {
            Color.clear
                .frame(width: 24, height: 24)
            Circle()
                .fill(.white)
                .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 1.5))
                .frame(width: size, height: size)
        }
            .contentShape(Rectangle())
            .position(point)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if resizeStartRect == nil {
                            onTap()
                            resizeStartRect = rect
                        }
                        let start = resizeStartRect ?? rect
                        liveResizeRect = CanvasElementGeometry.resized(
                            start,
                            by: handle,
                            delta: value.translation,
                            minimumSize: minimumSize,
                            in: canvasSize
                        )
                    }
                    .onEnded { value in
                        let start = resizeStartRect ?? rect
                        let finalRect = CanvasElementGeometry.resized(
                            start,
                            by: handle,
                            delta: value.translation,
                            minimumSize: minimumSize,
                            in: canvasSize
                        )
                        resizeStartRect = nil
                        liveResizeRect = nil
                        onResize(finalRect)
                    }
            )
    }
}
