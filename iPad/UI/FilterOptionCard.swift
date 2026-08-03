import SwiftUI

struct FilterOptionCard: View {
    let filter: PhotoFilterID
    let isSelected: Bool
    let language: CustomerLanguage
    let action: () -> Void
    @State private var sample: CGImage?

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack(alignment: .topTrailing) {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color.white.opacity(0.08))
                    if let sample {
                        Image(sample, scale: 1, label: Text(filter.displayName(for: language)))
                            .resizable()
                            .scaledToFill()
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.white)
                            .padding(8)
                    }
                }
                .frame(width: 150, height: 105)
                Text(filter.displayName(for: language))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
            }
            .padding(10)
            .background(Color.white.opacity(isSelected ? 0.14 : 0.06), in: RoundedRectangle(cornerRadius: 18))
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .stroke(isSelected ? Color.white : Color.white.opacity(0.12), lineWidth: isSelected ? 3 : 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(filter.displayName(for: language))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .task(id: filter) {
            guard let source = FilterSampleRenderer.makeSampleImage() else { return }
            sample = try? await PhotoFilterPipeline().apply(filter, to: source)
        }
    }

}
