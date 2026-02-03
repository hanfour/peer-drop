import SwiftUI

struct UserProfileView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var displayName: String
    @State private var avatarImage: UIImage?

    init() {
        let profile = UserProfile.current
        _displayName = State(initialValue: profile.displayName)
        if let data = profile.avatarData, let img = UIImage(data: data) {
            _avatarImage = State(initialValue: img)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        if let avatarImage {
                            Image(uiImage: avatarImage)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 80, height: 80)
                                .clipShape(Circle())
                        } else {
                            Image(systemName: "person.crop.circle.fill")
                                .font(.system(size: 60))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }

                Section("Display Name") {
                    TextField("Display Name", text: $displayName)
                        .autocorrectionDisabled()
                }
            }
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func save() {
        var profile = UserProfile.current
        profile.displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let img = avatarImage, let data = img.jpegData(compressionQuality: 0.8) {
            profile.avatarData = data
        }
        profile.save()
    }
}
