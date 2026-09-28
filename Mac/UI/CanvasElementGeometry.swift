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

    static func groupMoved(_ rects: [CGRect], by delta: CGSize, in canvasSize: CGSize) -> [CGRect] {
        guard !rects.isEmpty else { return [] }
        let minimumX = rects.map { -$0.minX }.max() ?? 0
        let maximumX = rects.map { canvasSize.width - $0.maxX }.min() ?? 0
        let minimumY = rects.map { -$0.minY }.max() ?? 0
        let maximumY = rects.map { canvasSize.height - $0.maxY }.min() ?? 0
        let x = min(max(delta.width, minimumX), maximumX)
        let y = min(max(delta.height, minimumY), maximumY)
        return rects.map { $0.offsetBy(dx: x, dy: y) }
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
        let canvasWidth = max(0, canvasSize.width)
        let canvasHeight = max(0, canvasSize.height)
        let minimumWidth = min(max(0, minimumSize.width), canvasWidth)
        let minimumHeight = min(max(0, minimumSize.height), canvasHeight)
        var minX = rect.minX
        var maxX = rect.maxX
        var minY = rect.minY
        var maxY = rect.maxY

        switch handle {
        case .e, .ne, .se:
            maxX = min(canvasWidth, max(rect.minX + minimumWidth, rect.maxX + delta.width))
        case .w, .nw, .sw:
            minX = max(0, min(rect.maxX - minimumWidth, rect.minX + delta.width))
        case .n, .s:
            break
        }

        switch handle {
        case .s, .se, .sw:
            maxY = min(canvasHeight, max(rect.minY + minimumHeight, rect.maxY + delta.height))
        case .n, .ne, .nw:
            minY = max(0, min(rect.maxY - minimumHeight, rect.minY + delta.height))
        case .e, .w:
            break
        }

        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
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
                    DragGesture(minimumDistance: 0, coordinateSpace: .named("templateCanvas"))
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

    private func resizeHandle(_ handle: CanvasElementResizeHandle, in displayRect: CGRect) -> some View {
        let point: CGPoint
        switch handle {
        case .nw: point = CGPoint(x: displayRect.minX, y: displayRect.minY)
        case .n: point = CGPoint(x: displayRect.midX, y: displayRect.minY)
        case .ne: point = CGPoint(x: displayRect.maxX, y: displayRect.minY)
        case .w: point = CGPoint(x: displayRect.minX, y: displayRect.midY)
        case .e: point = CGPoint(x: displayRect.maxX, y: displayRect.midY)
        case .sw: point = CGPoint(x: displayRect.minX, y: displayRect.maxY)
        case .s: point = CGPoint(x: displayRect.midX, y: displayRect.maxY)
        case .se: point = CGPoint(x: displayRect.maxX, y: displayRect.maxY)
        }
        let size: CGFloat = handle.isCorner ? 10 : 8
        return Circle()
            .fill(.white)
            .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 1.5))
            .frame(width: size, height: size)
            .position(point)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("templateCanvas"))
                    .updating($resizeState) { value, state, _ in
                        state = CanvasElementResizeState(handle: handle, delta: value.translation)
                    }
                    .onEnded { value in
                        let finalRect = CanvasElementGeometry.resized(
                            self.rect,
                            by: handle,
                            delta: value.translation,
                            minimumSize: minimumSize,
                            in: canvasSize
                        )
                        onResize(finalRect)
                    }
            )
    }
}
