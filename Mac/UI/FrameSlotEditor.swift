import SwiftUI

// MARK: - Resize handle types

private enum ResizeHandle: Sendable {
    case n, s, e, w, ne, nw, se, sw
    var isCorner: Bool { self == .ne || self == .nw || self == .se || self == .sw }
}

private struct ResizeDragState: Sendable {
    var handle: ResizeHandle
    var delta: CGSize
}

// MARK: - FrameSlotEditor

struct FrameSlotEditor: View {
    @Bindable var event: BoothEvent
    @Environment(\.dismiss) private var dismiss
    @State private var selectedSlotID: String?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            HStack(spacing: 0) {
                canvas
                Divider()
                slotInspector.frame(width: 220)
            }
        }
        .frame(minWidth: 720, minHeight: 560)
    }

    // MARK: - Toolbar

    var toolbar: some View {
        HStack {
            Button(action: addSlot) {
                Label("Add Slot", systemImage: "plus.rectangle.on.rectangle")
            }
            if let id = selectedSlotID, let idx = slotIndex(id: id) {
                Button(action: { duplicateSlot(at: idx) }) {
                    Label("Duplicate", systemImage: "plus.square.on.square")
                }
                Button(role: .destructive, action: { deleteSlot(at: idx) }) {
                    Label("Delete", systemImage: "trash")
                }
            }
            Spacer()
            Button("Done") {
                try? DataStore.shared.context.save()
                dismiss()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - Canvas

    var canvas: some View {
        GeometryReader { geo in
            let scale = min(geo.size.width / CGFloat(event.canvasWidth),
                           geo.size.height / CGFloat(event.canvasHeight))
            let displayW = CGFloat(event.canvasWidth) * scale
            let displayH = CGFloat(event.canvasHeight) * scale

            ZStack {
                Color(white: 0.2)

                ZStack {
                    if let framePath = event.framePNGPath,
                       let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
                        let frameURL = appSupport.appendingPathComponent("PRC-PhotoBooth").appendingPathComponent(framePath)
                        AsyncImage(url: frameURL) { img in
                            img.resizable()
                        } placeholder: { Color.gray.opacity(0.2) }
                    } else {
                        Color.white
                        canvasGrid(w: displayW, h: displayH)
                    }

                    ForEach(event.slots) { slot in
                        SlotView(
                            slot: slot,
                            canvasW: displayW,
                            canvasH: displayH,
                            isSelected: selectedSlotID == slot.id,
                            onTap: { selectedSlotID = slot.id },
                            onDrag: { delta in moveSlot(slot, by: delta, canvasW: displayW, canvasH: displayH) },
                            onResize: { newRect in resizeSlot(slot, to: newRect, canvasW: displayW, canvasH: displayH) }
                        )
                    }
                }
                .frame(width: displayW, height: displayH)
                .clipped()
            }
        }
        .onTapGesture { selectedSlotID = nil }
    }

    func canvasGrid(w: CGFloat, h: CGFloat) -> some View {
        Canvas { ctx, _ in
            let step: CGFloat = 40
            var x: CGFloat = 0
            while x <= w { ctx.stroke(Path { p in p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: h)) }, with: .color(.gray.opacity(0.2))); x += step }
            var y: CGFloat = 0
            while y <= h { ctx.stroke(Path { p in p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: w, y: y)) }, with: .color(.gray.opacity(0.2))); y += step }
        }
    }

    // MARK: - Inspector

    var slotInspector: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Slots (\(event.slots.count))")
                .font(.headline).padding(.top)

            List(event.slots.sorted { $0.zOrder < $1.zOrder }, id: \.id, selection: $selectedSlotID) { slot in
                HStack {
                    Text("Slot \(slot.zOrder + 1)")
                    Spacer()
                    Text("P\(slot.photoIndex + 1)")
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                }
            }

            if let id = selectedSlotID,
               let idx = event.slots.firstIndex(where: { $0.id == id }) {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("Inspector").font(.subheadline.bold())
                    @Bindable var s = event.slots[idx]

                    // Photo assignment (which capture this slot shows)
                    LabeledContent("Shows") {
                        Picker("", selection: $s.photoIndex) {
                            ForEach(0..<max(1, event.photoCount), id: \.self) { i in
                                Text("Photo \(i + 1)").tag(i)
                            }
                        }
                        .labelsHidden().frame(width: 90)
                    }

                    LabeledContent("X") { TextField("", value: $s.normX, format: .number.precision(.fractionLength(3))).frame(width: 70) }
                    LabeledContent("Y") { TextField("", value: $s.normY, format: .number.precision(.fractionLength(3))).frame(width: 70) }
                    LabeledContent("W") { TextField("", value: $s.normW, format: .number.precision(.fractionLength(3))).frame(width: 70) }
                    LabeledContent("H") { TextField("", value: $s.normH, format: .number.precision(.fractionLength(3))).frame(width: 70) }
                    LabeledContent("Rotation") { TextField("°", value: $s.rotation, format: .number.precision(.fractionLength(1))).frame(width: 70) }
                }
                .padding(.horizontal)
                .textFieldStyle(.roundedBorder)
            }
            Spacer()
        }
    }

    // MARK: - Slot operations

    private func addSlot() {
        let index = event.slots.count
        let photoIdx = index % max(1, event.photoCount)
        let gap = 1.0 / Double(max(1, event.photoCount))
        let slot = BoothSlot(
            normX: 0.05, normY: gap * Double(photoIdx),
            normW: 0.9,  normH: gap * 0.85,
            zOrder: index, photoIndex: photoIdx
        )
        event.slots.append(slot)
        selectedSlotID = slot.id
    }

    private func duplicateSlot(at index: Int) {
        let src = event.slots[index]
        let nx = min(src.normX + 0.02, max(0, 1 - src.normW))
        let ny = min(src.normY + 0.02, max(0, 1 - src.normH))
        let slot = BoothSlot(normX: nx, normY: ny,
                             normW: src.normW, normH: src.normH,
                             rotation: src.rotation,
                             zOrder: event.slots.count,
                             photoIndex: src.photoIndex)
        event.slots.append(slot)
        selectedSlotID = slot.id
    }

    private func deleteSlot(at index: Int) {
        event.slots.remove(at: index)
        selectedSlotID = nil
    }

    private func slotIndex(id: String) -> Int? {
        event.slots.firstIndex(where: { $0.id == id })
    }

    private func moveSlot(_ slot: BoothSlot, by delta: CGSize, canvasW: CGFloat, canvasH: CGFloat) {
        guard let idx = slotIndex(id: slot.id) else { return }
        event.slots[idx].normX = max(0, min(1 - slot.normW, slot.normX + delta.width / canvasW))
        event.slots[idx].normY = max(0, min(1 - slot.normH, slot.normY + delta.height / canvasH))
    }

    private func resizeSlot(_ slot: BoothSlot, to rect: CGRect, canvasW: CGFloat, canvasH: CGFloat) {
        guard let idx = slotIndex(id: slot.id) else { return }
        event.slots[idx].normX = max(0, rect.minX / canvasW)
        event.slots[idx].normY = max(0, rect.minY / canvasH)
        event.slots[idx].normW = min(1 - event.slots[idx].normX, rect.width / canvasW)
        event.slots[idx].normH = min(1 - event.slots[idx].normY, rect.height / canvasH)
    }
}

// MARK: - SlotView (drag + 8 resize handles)

struct SlotView: View {
    let slot: BoothSlot
    let canvasW: CGFloat
    let canvasH: CGFloat
    let isSelected: Bool
    var onTap: () -> Void
    var onDrag: (CGSize) -> Void
    var onResize: (CGRect) -> Void

    @GestureState private var dragOffset: CGSize = .zero
    @GestureState private var resizeState: ResizeDragState? = nil

    var slotRect: CGRect {
        CGRect(x: slot.normX * canvasW, y: slot.normY * canvasH,
               width: slot.normW * canvasW, height: slot.normH * canvasH)
    }

    // Live rect: slotRect modified by active resize gesture
    var liveRect: CGRect {
        guard let state = resizeState else { return slotRect }
        return resized(slotRect, by: state.handle, delta: state.delta)
    }

    // Displayed rect: live rect shifted by active body drag
    var displayRect: CGRect {
        liveRect.offsetBy(dx: dragOffset.width, dy: dragOffset.height)
    }

    var body: some View {
        let dr = displayRect
        ZStack {
            slotBody(dr: dr)
            if isSelected { handles(dr: dr) }
        }
    }

    @ViewBuilder
    private func slotBody(dr: CGRect) -> some View {
        let borderColor: Color = isSelected ? .accentColor : .white.opacity(0.7)
        let fillOpacity: Double = isSelected ? 0.25 : 0.15
        Rectangle()
            .strokeBorder(borderColor, lineWidth: isSelected ? 2 : 1)
            .background(Rectangle().fill(Color.blue.opacity(fillOpacity)))
            .overlay {
                VStack(spacing: 2) {
                    Text("Photo \(slot.photoIndex + 1)")
                        .font(.caption.bold()).foregroundStyle(.white)
                    Text("Slot \(slot.zOrder + 1)")
                        .font(.caption2).foregroundStyle(.white.opacity(0.6))
                }
            }
            .frame(width: dr.width, height: dr.height)
            .position(x: dr.midX, y: dr.midY)
            .gesture(DragGesture()
                .updating($dragOffset) { val, state, _ in state = val.translation }
                .onEnded { val in onDrag(val.translation) })
            .onTapGesture { onTap() }
    }

    @ViewBuilder
    private func handles(dr: CGRect) -> some View {
        resizeHandle(.nw, at: CGPoint(x: dr.minX, y: dr.minY))
        resizeHandle(.n,  at: CGPoint(x: dr.midX, y: dr.minY))
        resizeHandle(.ne, at: CGPoint(x: dr.maxX, y: dr.minY))
        resizeHandle(.w,  at: CGPoint(x: dr.minX, y: dr.midY))
        resizeHandle(.e,  at: CGPoint(x: dr.maxX, y: dr.midY))
        resizeHandle(.sw, at: CGPoint(x: dr.minX, y: dr.maxY))
        resizeHandle(.s,  at: CGPoint(x: dr.midX, y: dr.maxY))
        resizeHandle(.se, at: CGPoint(x: dr.maxX, y: dr.maxY))
    }

    @ViewBuilder
    private func resizeHandle(_ h: ResizeHandle, at point: CGPoint) -> some View {
        let size: CGFloat = h.isCorner ? 10 : 8
        Circle()
            .fill(Color.white)
            .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 1.5))
            .frame(width: size, height: size)
            .position(x: point.x, y: point.y)
            .gesture(
                DragGesture()
                    .updating($resizeState) { val, state, _ in
                        state = ResizeDragState(handle: h, delta: val.translation)
                    }
                    .onEnded { val in
                        onResize(resized(slotRect, by: h, delta: val.translation))
                    }
            )
    }

    // Compute new CGRect given base rect, which edge/corner was dragged, and how far
    private func resized(_ r: CGRect, by h: ResizeHandle, delta: CGSize) -> CGRect {
        let dx = delta.width, dy = delta.height
        let minW: CGFloat = 40, minH: CGFloat = 40

        switch h {
        // Corners
        case .se:
            return CGRect(x: r.minX, y: r.minY,
                          width: max(minW, r.width + dx), height: max(minH, r.height + dy))
        case .sw:
            let w = max(minW, r.width - dx)
            return CGRect(x: r.maxX - w, y: r.minY, width: w, height: max(minH, r.height + dy))
        case .ne:
            let h2 = max(minH, r.height - dy)
            return CGRect(x: r.minX, y: r.maxY - h2, width: max(minW, r.width + dx), height: h2)
        case .nw:
            let w = max(minW, r.width - dx); let h2 = max(minH, r.height - dy)
            return CGRect(x: r.maxX - w, y: r.maxY - h2, width: w, height: h2)
        // Edges
        case .s:
            return CGRect(x: r.minX, y: r.minY, width: r.width, height: max(minH, r.height + dy))
        case .n:
            let h2 = max(minH, r.height - dy)
            return CGRect(x: r.minX, y: r.maxY - h2, width: r.width, height: h2)
        case .e:
            return CGRect(x: r.minX, y: r.minY, width: max(minW, r.width + dx), height: r.height)
        case .w:
            let w = max(minW, r.width - dx)
            return CGRect(x: r.maxX - w, y: r.minY, width: w, height: r.height)
        }
    }
}
