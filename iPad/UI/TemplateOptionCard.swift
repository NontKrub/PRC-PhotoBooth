import SwiftUI

struct TemplateOptionCard: View {
    let option: CustomerTemplateOption
    let preview: CGImage?
    let isSelected: Bool
    let language: CustomerLanguage
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                ZStack(alignment: .topTrailing) {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color.white.opacity(0.08))
                    if let preview {
                        Image(preview, scale: 1, label: Text(option.name.value(for: language)))
                            .resizable()
                            .scaledToFit()
                            .padding(12)
                    } else {
                        Image(systemName: "rectangle.on.rectangle")
                            .font(.system(size: 38))
                            .foregroundStyle(.white.opacity(0.35))
                    }
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.white)
                            .padding(10)
                    }
                }
                .frame(height: 190)
                Text(option.name.value(for: language))
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                Text(photoCountLabel)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.55))
            }
            .padding(12)
            .background(Color.white.opacity(isSelected ? 0.14 : 0.06), in: RoundedRectangle(cornerRadius: 20))
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .stroke(isSelected ? Color.white : Color.white.opacity(0.12), lineWidth: isSelected ? 3 : 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.name.value(for: language))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var photoCountLabel: String {
        if language == .thai { return "\(option.photoCount) รูปภาพ" }
        return "\(option.photoCount) \(option.photoCount == 1 ? "photo" : "photos")"
    }
}
