import SwiftUI

struct CustomerLanguagePicker: View {
    @EnvironmentObject private var vm: iPadViewModel

    var body: some View {
        HStack(spacing: 8) {
            ForEach(CustomerLanguage.allCases, id: \.self) { language in
                Button {
                    vm.selectLanguage(language)
                } label: {
                    Text(language == .english ? "English" : "ไทย")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(vm.selectedLanguage == language ? .black : .white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(
                            vm.selectedLanguage == language ? Color.white : Color.white.opacity(0.1),
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(vm.selectedLanguage == .thai ? "ภาษา" : "Language")
    }
}
