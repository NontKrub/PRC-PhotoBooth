import SwiftUI

struct ExternalExperienceSelectionView: View {
    @Environment(BoothCoordinator.self) private var coordinator
    @Environment(SessionStateMachine.self) private var stateMachine

    private var language: CustomerLanguage { coordinator.externalSelection.language }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text(coordinator.activeEvent?.name ?? "PRC PhotoBooth")
                    .font(.system(size: 42, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                if let catalog = coordinator.experienceCatalog {
                    Text("Choose your experience")
                        .font(.title2)
                        .foregroundStyle(.white.opacity(0.7))
                    if catalog.guestLanguageSelectionEnabled {
                        Picker("Language", selection: Binding(
                            get: { coordinator.externalSelection.language },
                            set: { coordinator.externalSelection.language = $0 }
                        )) {
                            Text("English").tag(CustomerLanguage.english)
                            Text("ไทย").tag(CustomerLanguage.thai)
                        }
                        .pickerStyle(.segmented)
                    }
                    if catalog.guestTemplateSelectionEnabled {
                        Text("Template").font(.title3.bold()).foregroundStyle(.white)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                            ForEach(catalog.templates) { template in
                                Button {
                                    coordinator.externalSelection.templateID = template.id
                                } label: {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(template.name.value(for: language))
                                        Text("\(template.photoCount) photos")
                                            .font(.caption)
                                            .foregroundStyle(.white.opacity(0.65))
                                    }
                                    .foregroundStyle(.white)
                                    .padding(16)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(
                                        coordinator.externalSelection.templateID == template.id
                                            ? Color.white.opacity(0.2)
                                            : Color.white.opacity(0.08),
                                        in: RoundedRectangle(cornerRadius: 14)
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 14)
                                            .stroke(
                                                coordinator.externalSelection.templateID == template.id ? .white : .white.opacity(0.15),
                                                lineWidth: 2
                                            )
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    if catalog.guestFilterSelectionEnabled {
                        Text("Filter").font(.title3.bold()).foregroundStyle(.white)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                            ForEach(catalog.allowedFilterIDs) { filter in
                                Button {
                                    coordinator.externalSelection.filterID = filter
                                } label: {
                                    Text(filter.displayName(for: language))
                                        .foregroundStyle(.white)
                                        .frame(maxWidth: .infinity)
                                        .padding(14)
                                        .background(
                                            coordinator.externalSelection.filterID == filter
                                                ? Color.white.opacity(0.2)
                                                : Color.white.opacity(0.08),
                                            in: RoundedRectangle(cornerRadius: 12)
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    HStack {
                        Button("Back") {
                            guard CustomerDisplayWorkflow.canApply(.back, in: stateMachine.phase) else { return }
                            stateMachine.reset()
                        }
                            .buttonStyle(.bordered)
                        Button("Continue") {
                            guard CustomerDisplayWorkflow.canApply(.confirmSelection, in: stateMachine.phase) else { return }
                            coordinator.confirmExternalExperienceSelection()
                        }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
            .padding(60)
        }
        .background(Color.black)
        .environment(\.locale, Locale(identifier: language.localeIdentifier))
    }
}
