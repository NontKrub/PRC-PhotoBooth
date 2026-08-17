import SwiftUI
import AppKit

enum TemplateCanvasSelection: Hashable {
    case photo(String)
    case qrCode(String)
}
private enum TemplateCanvasElement: Identifiable {
    case photo(SharedPhotoSlot)
    case qrCode(SharedQRCodeElement)

    var id: String {
        switch self {
        case .photo(let slot): return "photo:\(slot.id)"
        case .qrCode(let element): return "qr:\(element.id)"
        }
    }

    var zOrder: Int {
        switch self {
        case .photo(let slot): return slot.zOrder
        case .qrCode(let element): return element.zOrder
        }
    }
}

struct TemplateFrameSlotEditor: View {
    @Binding var slots: [SharedPhotoSlot]
    @Binding var qrCodeElements: [SharedQRCodeElement]
    let canvasWidth: Double
    let canvasHeight: Double
    let photoCount: Int
    let frame: CGImage?
    let foregroundOverlay: CGImage?
    @Environment(\.dismiss) private var dismiss
    @State private var selection = Set<TemplateCanvasSelection>()
    @State private var selectionAnchor: TemplateCanvasSelection?
    @State private var undoStack: [EditorSnapshot] = []
    @State private var redoStack: [EditorSnapshot] = []
    @FocusState private var editorFocused: Bool

    private let previewPayload = "https://example.invalid/s/preview/"

    private var canvasSize: CGSize { CGSize(width: canvasWidth, height: canvasHeight) }

    private struct EditorSnapshot: Equatable {
        var slots: [SharedPhotoSlot]
        var qrCodeElements: [SharedQRCodeElement]
        var selection: Set<TemplateCanvasSelection>
    }

    private var snapshot: EditorSnapshot {
        EditorSnapshot(slots: slots, qrCodeElements: qrCodeElements, selection: selection)
    }

    private var elements: [TemplateCanvasElement] {
        (slots.map(TemplateCanvasElement.photo) + qrCodeElements.map(TemplateCanvasElement.qrCode))
            .sorted { lhs, rhs in lhs.zOrder == rhs.zOrder ? lhs.id < rhs.id : lhs.zOrder < rhs.zOrder }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            HStack(spacing: 0) {
                canvas
                Divider()
                inspector.frame(width: 250)
            }
        }
        .frame(minWidth: 820, minHeight: 600)
        .focusable()
        .focused($editorFocused)
        .onAppear { editorFocused = true }
        .onDeleteCommand { deleteSelection() }
        .onKeyPress(phases: .down) { press in
            if press.modifiers.contains(.command), press.characters.lowercased() == "a" {
                selectAll()
                return .handled
            }
            if press.modifiers.contains(.command), press.characters.lowercased() == "d" {
                duplicateSelection()
                return .handled
            }
            if press.modifiers.contains(.command), press.characters.lowercased() == "z" {
                press.modifiers.contains(.shift) ? redo() : undo()
                return .handled
            }
            if press.key == .escape {
                selection.removeAll()
                selectionAnchor = nil
                return .handled
            }
            let step = press.modifiers.contains(.shift) ? 10.0 : 1.0
            switch press.key {
            case .leftArrow: nudgeSelection(by: CGSize(width: -step, height: 0))
            case .rightArrow: nudgeSelection(by: CGSize(width: step, height: 0))
            case .upArrow: nudgeSelection(by: CGSize(width: 0, height: -step))
            case .downArrow: nudgeSelection(by: CGSize(width: 0, height: step))
            default: return .ignored
            }
            return .handled
        }
    }

    private var toolbar: some View {
        HStack {
            Button(action: addPhotoSlot) {
                Label("Add Photo Slot", systemImage: "photo.on.rectangle.angled")
            }
            Button(action: addQRCode) {
                Label("Add QR Code", systemImage: "qrcode")
            }
            if !selection.isEmpty {
                Button(action: duplicateSelection) {
                    Label("Duplicate", systemImage: "plus.square.on.square")
                }
                Button(role: .destructive, action: deleteSelection) {
                    Label("Delete", systemImage: "trash")
                }
            }
            Button("Select All", action: selectAll)
            Button("Undo", systemImage: "arrow.uturn.backward", action: undo)
                .disabled(undoStack.isEmpty)
            Button("Redo", systemImage: "arrow.uturn.forward", action: redo)
                .disabled(redoStack.isEmpty)
            Spacer()
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var canvas: some View {
        GeometryReader { geometry in
            let scale = min(geometry.size.width / canvasWidth, geometry.size.height / canvasHeight)
            let displaySize = CGSize(width: canvasWidth * scale, height: canvasHeight * scale)
            ZStack {
                Color(white: 0.2)
                ZStack {
                    if let frame {
                        Image(frame, scale: 1, orientation: .up, label: Text("Template frame"))
                            .resizable()
                            .scaledToFill()
                            .frame(width: displaySize.width, height: displaySize.height)
                            .clipped()
                    } else {
                        Color.white
                    }
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selection.removeAll()
                            selectionAnchor = nil
                        }
                    canvasGrid(w: displaySize.width, h: displaySize.height)
                    ForEach(elements.filter { if case .photo = $0 { true } else { false } }) { element in
                        elementView(element, in: displaySize)
                    }
                    if let foregroundOverlay {
                        Image(foregroundOverlay, scale: 1, orientation: .up, label: Text("Foreground overlay"))
                            .resizable()
                            .scaledToFill()
                            .frame(width: displaySize.width, height: displaySize.height)
                            .clipped()
                            .allowsHitTesting(false)
                    }
                    ForEach(elements.filter { if case .qrCode = $0 { true } else { false } }) { element in
                        elementView(element, in: displaySize)
                    }
                    selectionChrome(in: displaySize)
                }
                .frame(width: displaySize.width, height: displaySize.height)
                .clipped()
                .coordinateSpace(name: "templateCanvas")
            }
        }
    }

    @ViewBuilder
    private func selectionChrome(in displaySize: CGSize) -> some View {
        ForEach(Array(selection), id: \.self) { item in
            if let rect = displayRect(for: item, in: displaySize) {
                Rectangle()
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                    .allowsHitTesting(false)
                if selection.count == 1 {
                    ForEach([CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)], id: \.self) { point in
                        Circle().fill(.white).overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 1.5))
                            .frame(width: 10, height: 10).position(point).allowsHitTesting(false)
                    }
                }
            }
        }
    }

    private func canvasGrid(w: CGFloat, h: CGFloat) -> some View {
        Canvas { context, _ in
            let step: CGFloat = 40
            stride(from: CGFloat.zero, through: w, by: step).forEach { x in
                context.stroke(Path { path in
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: h))
                }, with: .color(.gray.opacity(0.2)))
            }
            stride(from: CGFloat.zero, through: h, by: step).forEach { y in
                context.stroke(Path { path in
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: w, y: y))
                }, with: .color(.gray.opacity(0.2)))
            }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func elementView(_ element: TemplateCanvasElement, in displaySize: CGSize) -> some View {
        let minimumElementSize = CGSize(
            width: displaySize.width / CGFloat(max(canvasWidth, 1)),
            height: displaySize.height / CGFloat(max(canvasHeight, 1))
        )

        switch element {
        case .photo(let slot):
            ResizableCanvasElementView(
                rect: CanvasElementGeometry.canvasRect(slot.normalizedRect, in: displaySize),
                rotation: slot.rotation,
                isSelected: selection.contains(.photo(slot.id)),
                minimumSize: minimumElementSize,
                canvasSize: displaySize,
                onTap: { select(.photo(slot.id)) },
                onMove: { move(.photo(slot.id), by: $0, in: displaySize) },
                onResize: { resize(.photo(slot.id), to: $0, in: displaySize) }
            ) {
                Rectangle()
                    .fill(Color.blue.opacity(selection.contains(.photo(slot.id)) ? 0.25 : 0.15))
                    .overlay {
                        VStack(spacing: 2) {
                            Text("Photo \(slot.photoIndex + 1)").font(.caption.bold()).foregroundStyle(.white)
                            Text("Slot \(slot.zOrder + 1)").font(.caption2).foregroundStyle(.white.opacity(0.6))
                        }
                    }
            }
        case .qrCode(let element):
            ResizableCanvasElementView(
                rect: CanvasElementGeometry.canvasRect(element.normalizedRect, in: displaySize),
                rotation: element.rotation,
                isSelected: selection.contains(.qrCode(element.id)),
                minimumSize: minimumElementSize,
                canvasSize: displaySize,
                onTap: { select(.qrCode(element.id)) },
                onMove: { move(.qrCode(element.id), by: $0, in: displaySize) },
                onResize: { resize(.qrCode(element.id), to: $0, in: displaySize) }
            ) {
                ZStack {
                    Color.white
                    if let image = QRCodeGenerator.makeImage(payload: previewPayload, correctionLevel: "M", scale: 4, quietZoneModules: 4) {
                        Image(image, scale: 1, orientation: .up, label: Text("QR code"))
                            .resizable()
                            .interpolation(.none)
                            .scaledToFit()
                            .padding(4)
                    }
                    Text("QR")
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.65), in: Capsule())
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(4)
                }
            }
        }
    }

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Canvas Elements (\(elements.count))")
                .font(.headline)
                .padding(.top)
            List(elements, selection: $selection) { element in
                    HStack {
                        Text(elementLabel(element))
                        Spacer()
                        Text("Z\(element.zOrder + 1)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(canvasSelection(element))
            }

            if selection.count == 1, let selected = selection.first {
                Divider()
                selectionInspector(selected)
                    .padding(.horizontal)
            } else if selection.count > 1 {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(selection.count) Elements Selected")
                        .font(.subheadline.bold())
                    HStack {
                        Button("Duplicate", action: duplicateSelection)
                        Button("Delete", role: .destructive, action: deleteSelection)
                    }
                }
                .padding(.horizontal)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func selectionInspector(_ selection: TemplateCanvasSelection) -> some View {
        switch selection {
        case .photo(let id):
            if slotIndex(id) != nil {
                Text("Photo Slot").font(.subheadline.bold())
                LabeledContent("Shows") {
                    Picker("", selection: photoIndexBinding(id)) {
                        ForEach(0..<max(1, photoCount), id: \.self) { index in
                            Text("Photo \(index + 1)").tag(index)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 95)
                }
                geometryFields(for: selection)
            }
        case .qrCode(let id):
            if qrIndex(id) != nil {
                Text("Session QR Code").font(.subheadline.bold())
                Text("Element type: Session QR Code")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                geometryFields(for: selection)
                LabeledContent("Source") {
                    Text("Session download link")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func geometryFields(for selection: TemplateCanvasSelection) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent("X") { TextField("", value: rectBinding(selection, field: .x), format: .number.precision(.fractionLength(3))) }
            LabeledContent("Y") { TextField("", value: rectBinding(selection, field: .y), format: .number.precision(.fractionLength(3))) }
            LabeledContent("Width") { TextField("", value: rectBinding(selection, field: .width), format: .number.precision(.fractionLength(3))) }
            LabeledContent("Height") { TextField("", value: rectBinding(selection, field: .height), format: .number.precision(.fractionLength(3))) }
            LabeledContent("Rotation") { TextField("°", value: rotationBinding(selection), format: .number.precision(.fractionLength(1))) }
        }
        .textFieldStyle(.roundedBorder)
    }

    private func elementLabel(_ element: TemplateCanvasElement) -> String {
        switch element {
        case .photo(let slot): return "Photo \(slot.photoIndex + 1)"
        case .qrCode: return "Session QR Code"
        }
    }

    private func addPhotoSlot() {
        let index = slots.count
        let photoIndex = index % max(1, photoCount)
        let gap = 1.0 / Double(max(1, photoCount))
        let slot = SharedPhotoSlot(
            normalizedRect: CGRect(x: 0.05, y: gap * Double(photoIndex), width: 0.9, height: gap * 0.85),
            zOrder: nextZOrder,
            photoIndex: photoIndex
        )
        recordMutation {
            slots.append(slot)
            selection = [.photo(slot.id)]
            selectionAnchor = .photo(slot.id)
        }
    }

    private func addQRCode() {
        let side = min(canvasWidth, canvasHeight) * 0.14
        let margin = min(canvasWidth, canvasHeight) * 0.04
        let rect = CGRect(x: margin, y: canvasHeight - side - margin, width: side, height: side)
        let element = SharedQRCodeElement(
            normalizedRect: CanvasElementGeometry.normalizedRect(rect, in: canvasSize),
            zOrder: nextZOrder
        )
        recordMutation {
            qrCodeElements.append(element)
            selection = [.qrCode(element.id)]
            selectionAnchor = .qrCode(element.id)
        }
    }

    private var nextZOrder: Int {
        (slots.map(\.zOrder) + qrCodeElements.map(\.zOrder)).max().map { $0 + 1 } ?? 0
    }

    private func duplicateSelection() {
        guard !selection.isEmpty else { return }
        let offset = CGSize(width: min(canvasWidth, canvasHeight) * 0.02, height: min(canvasWidth, canvasHeight) * 0.02)
        let selected = elements.filter { selection.contains(canvasSelection($0)) }
        guard !selected.isEmpty else { return }
        let sourceRects = selected.compactMap { element -> CGRect? in
            switch element {
            case .photo(let slot): return CanvasElementGeometry.canvasRect(slot.normalizedRect, in: canvasSize)
            case .qrCode(let qrCode): return CanvasElementGeometry.canvasRect(qrCode.normalizedRect, in: canvasSize)
            }
        }
        guard sourceRects.count == selected.count else { return }
        let duplicateRects = CanvasElementGeometry.groupMoved(sourceRects, by: offset, in: canvasSize)
        let newIDs = SelectionLogic.uniqueIDs(
            count: selected.count,
            existing: Set(elements.map(\.id))
        ) { UUID().uuidString }
        let newZOrders = SelectionLogic.nextZOrders(
            existing: elements.map(\.zOrder),
            count: selected.count
        )
        recordMutation {
            var newSelection = Set<TemplateCanvasSelection>()
            for (index, element) in selected.enumerated() {
                switch element {
                case .photo(let slot):
                    var duplicate = slot
                    duplicate.id = newIDs[index]
                    duplicate.zOrder = newZOrders[index]
                    duplicate.normalizedRect = CanvasElementGeometry.normalizedRect(duplicateRects[index], in: canvasSize)
                    slots.append(duplicate)
                    newSelection.insert(.photo(duplicate.id))
                case .qrCode(let qrCode):
                    var duplicate = qrCode
                    duplicate.id = newIDs[index]
                    duplicate.zOrder = newZOrders[index]
                    duplicate.normalizedRect = CanvasElementGeometry.normalizedRect(duplicateRects[index], in: canvasSize)
                    qrCodeElements.append(duplicate)
                    newSelection.insert(.qrCode(duplicate.id))
                }
            }
            selection = newSelection
            selectionAnchor = newSelection.first
        }
    }

    private func deleteSelection() {
        guard !selection.isEmpty else { return }
        let deleting = selection
        recordMutation {
            slots.removeAll { deleting.contains(.photo($0.id)) }
            qrCodeElements.removeAll { deleting.contains(.qrCode($0.id)) }
            selection.removeAll()
            selectionAnchor = nil
        }
    }

    private func move(_ dragged: TemplateCanvasSelection, by delta: CGSize, in displaySize: CGSize) {
        let moving = selection.contains(dragged) ? elements.filter { selection.contains(canvasSelection($0)) }.map(canvasSelection) : [dragged]
        let current = moving.compactMap { displayRect(for: $0, in: displaySize) }
        guard current.count == moving.count else { return }
        let moved = CanvasElementGeometry.groupMoved(current, by: delta, in: displaySize)
        recordMutation {
            for (item, rect) in zip(moving, moved) {
                setRect(for: item, to: CanvasElementGeometry.normalizedRect(rect, in: displaySize))
            }
            if !selection.contains(dragged) {
                selection = [dragged]
                selectionAnchor = dragged
            }
        }
    }

    private func resize(_ item: TemplateCanvasSelection, to rect: CGRect, in displaySize: CGSize) {
        recordMutation {
            setRect(for: item, to: CanvasElementGeometry.normalizedRect(rect, in: displaySize))
        }
    }

    private func rect(for selection: TemplateCanvasSelection) -> CGRect {
        switch selection {
        case .photo(let id): return slots[slotIndex(id)!].normalizedRect
        case .qrCode(let id): return qrCodeElements[qrIndex(id)!].normalizedRect
        }
    }

    private func setRect(for selection: TemplateCanvasSelection, to rect: CGRect) {
        switch selection {
        case .photo(let id): slots[slotIndex(id)!].normalizedRect = rect
        case .qrCode(let id): qrCodeElements[qrIndex(id)!].normalizedRect = rect
        }
    }

    private func slotIndex(_ id: String) -> Int? { slots.firstIndex { $0.id == id } }
    private func qrIndex(_ id: String) -> Int? { qrCodeElements.firstIndex { $0.id == id } }

    private func canvasSelection(_ element: TemplateCanvasElement) -> TemplateCanvasSelection {
        switch element {
        case .photo(let slot): return .photo(slot.id)
        case .qrCode(let qrCode): return .qrCode(qrCode.id)
        }
    }

    private func displayRect(for selection: TemplateCanvasSelection, in displaySize: CGSize) -> CGRect? {
        guard let rect = rectIfPresent(for: selection) else { return nil }
        return CanvasElementGeometry.canvasRect(rect, in: displaySize)
    }

    private func rectIfPresent(for selection: TemplateCanvasSelection) -> CGRect? {
        switch selection {
        case .photo(let id): return slotIndex(id).map { slots[$0].normalizedRect }
        case .qrCode(let id): return qrIndex(id).map { qrCodeElements[$0].normalizedRect }
        }
    }

    private func select(_ item: TemplateCanvasSelection) {
        let modifiers = NSEvent.modifierFlags
        if modifiers.contains(.shift), let anchor = selectionAnchor {
            let ordered = elements.map(canvasSelection)
            selection = SelectionLogic.range(from: anchor, to: item, in: ordered)
        } else if modifiers.contains(.command) {
            selection = SelectionLogic.toggled(selection, id: item)
        } else {
            selection = [item]
        }
        selectionAnchor = item
    }

    private func selectAll() {
        selection = Set(elements.map(canvasSelection))
        selectionAnchor = elements.last.map(canvasSelection)
    }

    private func nudgeSelection(by delta: CGSize) {
        guard !selection.isEmpty else { return }
        let items = elements.filter { selection.contains(canvasSelection($0)) }.map(canvasSelection)
        let rects = items.compactMap { displayRect(for: $0, in: canvasSize) }
        guard rects.count == items.count else { return }
        let moved = CanvasElementGeometry.groupMoved(rects, by: delta, in: canvasSize)
        recordMutation {
            for (item, rect) in zip(items, moved) {
                setRect(for: item, to: CanvasElementGeometry.normalizedRect(rect, in: canvasSize))
            }
        }
    }

    private func recordMutation(_ mutation: () -> Void) {
        let before = snapshot
        mutation()
        guard before != snapshot else { return }
        undoStack.append(before)
        redoStack.removeAll()
    }

    private func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(snapshot)
        slots = previous.slots
        qrCodeElements = previous.qrCodeElements
        selection = previous.selection
    }

    private func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(snapshot)
        slots = next.slots
        qrCodeElements = next.qrCodeElements
        selection = next.selection
    }

    private enum RectField { case x, y, width, height }

    private func rectBinding(_ selection: TemplateCanvasSelection, field: RectField) -> Binding<Double> {
        Binding(
            get: { value(of: rect(for: selection), field: field) },
            set: { newValue in
                recordMutation {
                    var rect = rect(for: selection)
                    let value = newValue.isFinite ? newValue : 0
                    switch field {
                    case .x: rect.origin.x = value
                    case .y: rect.origin.y = value
                    case .width: rect.size.width = max(0.001, value)
                    case .height: rect.size.height = max(0.001, value)
                    }
                    setRect(for: selection, to: rect)
                }
            }
        )
    }

    private func rotationBinding(_ selection: TemplateCanvasSelection) -> Binding<Double> {
        Binding(
            get: {
                switch selection {
                case .photo(let id): return slots[slotIndex(id)!].rotation
                case .qrCode(let id): return qrCodeElements[qrIndex(id)!].rotation
                }
            },
            set: { newValue in
                guard newValue.isFinite else { return }
                recordMutation {
                    switch selection {
                    case .photo(let id): slots[slotIndex(id)!].rotation = newValue
                    case .qrCode(let id): qrCodeElements[qrIndex(id)!].rotation = newValue
                    }
                }
            }
        )
    }

    private func value(of rect: CGRect, field: RectField) -> Double {
        switch field {
        case .x: return rect.minX
        case .y: return rect.minY
        case .width: return rect.width
        case .height: return rect.height
        }
    }

    private func photoIndexBinding(_ id: String) -> Binding<Int> {
        Binding(
            get: { slots[slotIndex(id)!].photoIndex },
            set: {
                let value = min(max($0, 0), max(0, photoCount - 1))
                recordMutation { slots[slotIndex(id)!].photoIndex = value }
            }
        )
    }
}
