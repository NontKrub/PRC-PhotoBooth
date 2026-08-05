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

struct CanvasElementResizeState: Sendable {
    var handle: CanvasElementResizeHandle
    var delta: CGSize
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
        var result = rect
        switch handle {
        case .n:
            result.origin.y += delta.height
            result.size.height -= delta.height
        case .s:
            result.size.height += delta.height
        case .e:
            result.size.width += delta.width
        case .w:
            result.origin.x += delta.width
            result.size.width -= delta.width
        case .ne:
            result.origin.y += delta.height
            result.size.height -= delta.height
            result.size.width += delta.width
        case .nw:
            result.origin.x += delta.width
            result.size.width -= delta.width
            result.origin.y += delta.height
            result.size.height -= delta.height
        case .se:
            result.size.width += delta.width
            result.size.height += delta.height
        case .sw:
            result.origin.x += delta.width
            result.size.width -= delta.width
            result.size.height += delta.height
        }
        return clamped(result, in: canvasSize, minimumSize: minimumSize)
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
    @GestureState private var resizeState: CanvasElementResizeState? = nil

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
        let liveRect = CanvasElementGeometry.resized(
            rect,
            by: resizeState?.handle ?? .se,
            delta: resizeState?.delta ?? .zero,
            minimumSize: minimumSize,
            in: canvasSize
        )
        let displayRect = liveRect.offsetBy(dx: dragOffset.width, dy: dragOffset.height)

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
                }
            }
        }
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
        return Circle()
            .fill(.white)
            .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 1.5))
            .frame(width: size, height: size)
            .position(point)
            .gesture(
                DragGesture()
                    .updating($resizeState) { value, state, _ in
                        state = CanvasElementResizeState(handle: handle, delta: value.translation)
                    }
                    .onEnded { value in
                        onResize(CanvasElementGeometry.resized(rect, by: handle, delta: value.translation, minimumSize: minimumSize, in: canvasSize))
                    }
            )
    }
}
