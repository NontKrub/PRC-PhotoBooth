import SwiftUI

struct ExperienceSelectionView: View {
    @Environment(iPadViewModel.self) private var vm

    private var catalog: CustomerExperienceCatalog? { vm.experienceCatalog }
    private var language: CustomerLanguage { vm.selectedLanguage }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(catalog?.eventName ?? vm.eventConfig.eventName)
                            .font(.system(size: 38, weight: .black, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                        Text("Choose your experience")
                            .font(.title3.weight(.medium))
                            .foregroundStyle(.white.opacity(0.65))
                    }
                    Spacer()
                    if catalog?.guestLanguageSelectionEnabled == true {
                        CustomerLanguagePicker()
                    }
                }

                if let catalog, catalog.guestTemplateSelectionEnabled, catalog.templates.count > 1 {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Template")
                            .font(.title2.bold())
                            .foregroundStyle(.white)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 16)], spacing: 16) {
                            ForEach(catalog.templates) { option in
                                TemplateOptionCard(
                                    option: option,
                                    preview: vm.experienceAssets[option.previewAssetID],
                                    isSelected: vm.selectedTemplateID == option.id,
                                    language: language
                                ) {
                                    vm.selectTemplate(option.id)
                                }
                            }
                        }
                    }
                }

                if let catalog, catalog.guestFilterSelectionEnabled, catalog.allowedFilterIDs.count > 1 {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Filter")
                            .font(.title2.bold())
                            .foregroundStyle(.white)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                            ForEach(catalog.allowedFilterIDs) { filter in
                                FilterOptionCard(filter: filter, isSelected: vm.selectedFilterID == filter, language: language) {
                                    vm.selectFilter(filter)
                                }
                            }
                        }
                    }
                }

                if let error = vm.sessionRequestError {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.orange)
                }

                HStack(spacing: 14) {
                    Button("Back") {
                        vm.customerDone()
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)

                    Button("Continue") {
                        vm.confirmExperienceSelection()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(vm.selectedTemplateID == nil || vm.selectedFilterID == nil)
                }
            }
            .padding(.horizontal, 44)
            .padding(.vertical, 38)
        }
        .environment(\.locale, Locale(identifier: language.localeIdentifier))
    }
}
