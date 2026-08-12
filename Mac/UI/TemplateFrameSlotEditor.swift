import SwiftUI

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
    @Environment(\.dismiss) private var dismiss
    @State private var selection: TemplateCanvasSelection?

    private let previewPayload = "https://example.invalid/s/preview/"

    private var canvasSize: CGSize { CGSize(width: canvasWidth, height: canvasHeight) }

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
    }

    private var toolbar: some View {
        HStack {
            Button(action: addPhotoSlot) {
                Label("Add Photo Slot", systemImage: "photo.on.rectangle.angled")
            }
            Button(action: addQRCode) {
                Label("Add QR Code", systemImage: "qrcode")
            }
            if selection != nil {
                Button(action: duplicateSelection) {
                    Label("Duplicate", systemImage: "plus.square.on.square")
                }
                Button(role: .destructive, action: deleteSelection) {
                    Label("Delete", systemImage: "trash")
                }
            }
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
                        .onTapGesture { selection = nil }
                    canvasGrid(w: displaySize.width, h: displaySize.height)
                    ForEach(elements) { element in
                        elementView(element, in: displaySize)
                    }
                }
                .frame(width: displaySize.width, height: displaySize.height)
                .clipped()
                .coordinateSpace(name: "templateCanvas")
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
        switch element {
        case .photo(let slot):
            ResizableCanvasElementView(
                rect: CanvasElementGeometry.canvasRect(slot.normalizedRect, in: displaySize),
                rotation: slot.rotation,
                isSelected: selection == .photo(slot.id),
                minimumSize: CGSize(width: 40, height: 40),
                canvasSize: displaySize,
                onTap: { selection = .photo(slot.id) },
                onMove: { move(.photo(slot.id), by: $0, in: displaySize) },
                onResize: { resize(.photo(slot.id), to: $0, in: displaySize) }
            ) {
                Rectangle()
                    .fill(Color.blue.opacity(selection == .photo(slot.id) ? 0.25 : 0.15))
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
                isSelected: selection == .qrCode(element.id),
                minimumSize: CGSize(width: 40, height: 40),
                canvasSize: displaySize,
                onTap: { selection = .qrCode(element.id) },
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
            List(elements) { element in
                Button {
                    switch element {
                    case .photo(let slot): selection = .photo(slot.id)
                    case .qrCode(let qrCode): selection = .qrCode(qrCode.id)
                    }
                } label: {
                    HStack {
                        Text(elementLabel(element))
                        Spacer()
                        Text("Z\(element.zOrder + 1)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }

            if let selection {
                Divider()
                selectionInspector(selection)
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
        slots.append(slot)
        selection = .photo(slot.id)
    }

    private func addQRCode() {
        let side = min(canvasWidth, canvasHeight) * 0.14
        let margin = min(canvasWidth, canvasHeight) * 0.04
        let rect = CGRect(x: margin, y: canvasHeight - side - margin, width: side, height: side)
        let element = SharedQRCodeElement(
            normalizedRect: CanvasElementGeometry.normalizedRect(rect, in: canvasSize),
            zOrder: nextZOrder
        )
        qrCodeElements.append(element)
        selection = .qrCode(element.id)
    }

    private var nextZOrder: Int {
        (slots.map(\.zOrder) + qrCodeElements.map(\.zOrder)).max().map { $0 + 1 } ?? 0
    }

    private func duplicateSelection() {
        guard let selection else { return }
        let offset = CGSize(width: min(canvasWidth, canvasHeight) * 0.02, height: min(canvasWidth, canvasHeight) * 0.02)
        switch selection {
        case .photo(let id):
            guard let index = slotIndex(id) else { return }
            var duplicate = slots[index]
            duplicate.id = UUID().uuidString
            duplicate.zOrder = nextZOrder
            duplicate.normalizedRect = CanvasElementGeometry.normalizedRect(
                CanvasElementGeometry.duplicated(CanvasElementGeometry.canvasRect(duplicate.normalizedRect, in: canvasSize), offset: offset, in: canvasSize),
                in: canvasSize
            )
            slots.append(duplicate)
            self.selection = .photo(duplicate.id)
        case .qrCode(let id):
            guard let index = qrIndex(id) else { return }
            var duplicate = qrCodeElements[index]
            duplicate.id = UUID().uuidString
            duplicate.zOrder = nextZOrder
            duplicate.normalizedRect = CanvasElementGeometry.normalizedRect(
                CanvasElementGeometry.duplicated(CanvasElementGeometry.canvasRect(duplicate.normalizedRect, in: canvasSize), offset: offset, in: canvasSize),
                in: canvasSize
            )
            qrCodeElements.append(duplicate)
            self.selection = .qrCode(duplicate.id)
        }
    }

    private func deleteSelection() {
        guard let selection else { return }
        switch selection {
        case .photo(let id): slots.removeAll { $0.id == id }
        case .qrCode(let id): qrCodeElements.removeAll { $0.id == id }
        }
        self.selection = nil
    }

    private func move(_ selection: TemplateCanvasSelection, by delta: CGSize, in displaySize: CGSize) {
        let current = CanvasElementGeometry.canvasRect(rect(for: selection), in: displaySize)
        let moved = CanvasElementGeometry.moved(current, by: delta, in: displaySize)
        setRect(for: selection, to: CanvasElementGeometry.normalizedRect(moved, in: displaySize))
    }

    private func resize(_ selection: TemplateCanvasSelection, to rect: CGRect, in displaySize: CGSize) {
        setRect(for: selection, to: CanvasElementGeometry.normalizedRect(rect, in: displaySize))
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

    private enum RectField { case x, y, width, height }

    private func rectBinding(_ selection: TemplateCanvasSelection, field: RectField) -> Binding<Double> {
        Binding(
            get: { value(of: rect(for: selection), field: field) },
            set: { newValue in
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
                switch selection {
                case .photo(let id): slots[slotIndex(id)!].rotation = newValue
                case .qrCode(let id): qrCodeElements[qrIndex(id)!].rotation = newValue
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
            set: { slots[slotIndex(id)!].photoIndex = min(max($0, 0), max(0, photoCount - 1)) }
        )
    }
}
