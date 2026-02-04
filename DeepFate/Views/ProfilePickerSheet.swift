import SwiftUI

struct ProfilePickerSheet: View {
    let profiles: [UserProfile]
    let activeProfileID: UUID?
    let provinces: [ProvinceOption]
    let onSelect: (UserProfile) -> Void
    let onCreate: (UserProfile) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var showCreate = false

    var body: some View {
        NavigationStack {
            List {
                if profiles.isEmpty {
                    Text("暂无档案，请先创建。")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(profiles) { profile in
                        Button {
                            onSelect(profile)
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                ProfileAvatarView(name: profile.name, size: 36)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(profile.name)
                                        .font(.headline)
                                    Text("\(profile.gender.rawValue) · \(formatDateComponents(profile.birthInfo.solarComponents))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if profile.id == activeProfileID {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.purple)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("选择档案")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("新建") {
                        showCreate = true
                    }
                }
            }
        }
        .sheet(isPresented: $showCreate) {
            CreateProfileSheet(
                provinces: provinces,
                existingProfile: nil
            ) { profile in
                onCreate(profile)
                dismiss()
            }
            .presentationDetents([.medium, .large])
        }
    }
}

struct ProfileAvatarView: View {
    let name: String
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(avatarColor)
            Text(avatarText)
                .font(.system(size: size * 0.45, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .accessibilityLabel(name)
    }

    private var avatarText: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "档" : String(trimmed.prefix(1))
    }

    private var avatarColor: Color {
        let palette: [Color] = [.purple, .blue, .pink, .orange, .green, .teal]
        let sum = name.unicodeScalars.map { Int($0.value) }.reduce(0, +)
        return palette.isEmpty ? .gray : palette[abs(sum) % palette.count]
    }
}
