import SwiftUI

struct TemplateListView: View {
    @Environment(\.locale) private var locale
    @Binding var templates: [EventTemplateDefinition]
    @Binding var defaultTemplateID: String
    let previews: [String: CGImage]
    let onAdd: () -> Void
    let onEdit: (String) -> Void
    let onDuplicate: (String) -> Void
    let onDelete: (String) -> Void
    let onMove: (String, Int) -> Void

    private var orderedTemplates: [EventTemplateDefinition] {
        templates.sorted { $0.sortOrder < $1.sortOrder }
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(orderedTemplates) { template in
                    templateRow(template)
                    if template.id != orderedTemplates.last?.id {
                        Divider()
                    }
                }
            }
        } label: {
            HStack {
                Text("Templates")
                Spacer()
                Button("Add Template", systemImage: "plus") { onAdd() }
                    .disabled(templates.count >= 8)
            }
        }
    }

    private func templateRow(_ template: EventTemplateDefinition) -> some View {
        HStack(spacing: 12) {
            if let image = previews[template.id] {
                Image(nsImage: NSImage(cgImage: image, size: .zero))
                    .resizable()
                    .scaledToFit()
                    .frame(width: 54, height: 54)
                    .background(.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            } else {
                Image(systemName: "rectangle.on.rectangle")
                    .frame(width: 54, height: 54)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(template.name.value(for: operatorLanguage)).font(.headline)
                HStack(spacing: 4) {
                    Text("\(template.photoCount) photos")
                    Text("·")
                    Text(LocalizedStringKey(template.isEnabled ? "Enabled" : "Disabled"))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if template.id == defaultTemplateID {
                Text("Default").font(.caption.bold()).foregroundStyle(.green)
            }
            Button("Edit") { onEdit(template.id) }
            Menu {
                Button("Set Default") { defaultTemplateID = template.id }
                Button {
                    guard let index = templates.firstIndex(where: { $0.id == template.id }) else { return }
                    templates[index].isEnabled.toggle()
                    if !templates[index].isEnabled, defaultTemplateID == template.id {
                        defaultTemplateID = templates.first(where: { $0.id != template.id && $0.isEnabled })?.id ?? template.id
                    }
                } label: {
                    Text(LocalizedStringKey(template.isEnabled ? "Disable" : "Enable"))
                }
                Button("Duplicate") { onDuplicate(template.id) }
                Button("Move Up") { onMove(template.id, -1) }
                Button("Move Down") { onMove(template.id, 1) }
                Divider()
                Button("Delete", role: .destructive) { onDelete(template.id) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture { onEdit(template.id) }
    }

    private var operatorLanguage: CustomerLanguage {
        locale.identifier.lowercased().hasPrefix("th") ? .thai : .english
    }
}
