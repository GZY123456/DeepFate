import SwiftUI

struct ArchiveView: View {
    @EnvironmentObject private var profileStore: ProfileStore
    @EnvironmentObject private var locationStore: LocationStore
    @State private var showCreateSheet = false
    @State private var editingProfile: UserProfile?
    @State private var searchText = ""
    @State private var sortOption: SortOption = .createdAtDesc

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("档案馆")
                            .font(.headline)
                        Spacer()
                        Menu {
                            Picker("排序", selection: $sortOption) {
                                ForEach(SortOption.allCases) { option in
                                    Text(option.label).tag(option)
                                }
                            }
                        } label: {
                            Image(systemName: "arrow.up.arrow.down")
                        }
                        Button("创建档案") {
                            showCreateSheet = true
                        }
                        .buttonStyle(.bordered)
                    }

                    let profiles = sortedProfiles(from: filteredProfiles)
                    if profiles.isEmpty {
                        Text("暂无档案，先创建一份吧。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 8)
                    } else {
                        ForEach(profiles) { profile in
                            Button {
                                profileStore.setActive(profile.id)
                            } label: {
                                ArchiveCard(profile: profile, isActive: profile.id == profileStore.activeProfileID)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("编辑") {
                                    editingProfile = profile
                                }
                                Button("删除", role: .destructive) {
                                    profileStore.delete(id: profile.id)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.top, 12)
            }
        }
        .navigationTitle("档案馆")
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always))
        .sheet(isPresented: $showCreateSheet) {
            CreateProfileSheet(
                provinces: locationStore.provinces.isEmpty ? defaultLocationOptions : locationStore.provinces
            ) { profile in
                profileStore.add(profile)
                profileStore.setActive(profile.id)
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(item: $editingProfile) { profile in
            CreateProfileSheet(
                provinces: locationStore.provinces.isEmpty ? defaultLocationOptions : locationStore.provinces,
                existingProfile: profile
            ) { updated in
                profileStore.update(updated)
            }
            .presentationDetents([.medium, .large])
        }
    }

    private var filteredProfiles: [UserProfile] {
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if keyword.isEmpty {
            return profileStore.profiles
        }
        return profileStore.profiles.filter { profile in
            let haystack = [
                profile.name,
                profile.location.province,
                profile.location.city,
                profile.location.district
            ].joined(separator: " ")
            return haystack.localizedCaseInsensitiveContains(keyword)
        }
    }

    private func sortedProfiles(from profiles: [UserProfile]) -> [UserProfile] {
        switch sortOption {
        case .createdAtDesc:
            return profiles.sorted { $0.createdAt > $1.createdAt }
        case .birthTimeAsc:
            return profiles.sorted { birthDate(for: $0) < birthDate(for: $1) }
        }
    }

    private func birthDate(for profile: UserProfile) -> Date {
        var components = profile.birthInfo.solarComponents
        components.calendar = Calendar(identifier: .gregorian)
        return components.date ?? Date.distantPast
    }
}

private struct ArchiveCard: View {
    let profile: UserProfile
    let isActive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(profile.name)
                    .font(.headline)
                if let genderIcon = genderIcon {
                    Image(systemName: genderIcon)
                        .foregroundStyle(genderColor)
                }
                Spacer()
                if isActive {
                    Text("当前")
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.purple.opacity(0.15)))
                        .foregroundStyle(.purple)
                }
            }
            Text("\(profile.gender.rawValue) · \(formatDateComponents(profile.birthInfo.solarComponents))")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("出生地：\(profile.location.province) \(profile.location.city) \(profile.location.district)")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text("真太阳时：\(formatDateComponents(profile.trueSolarComponents))")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.secondarySystemBackground))
        )
    }

    private var genderIcon: String? {
        switch profile.gender {
        case .male:
            return "m.circle.fill"
        case .female:
            return "f.circle.fill"
        case .other:
            return nil
        }
    }

    private var genderColor: Color {
        switch profile.gender {
        case .male:
            return .blue
        case .female:
            return .pink
        case .other:
            return .secondary
        }
    }
}

private enum SortOption: String, CaseIterable, Identifiable {
    case createdAtDesc
    case birthTimeAsc

    var id: String { rawValue }

    var label: String {
        switch self {
        case .createdAtDesc:
            return "创建时间（新→旧）"
        case .birthTimeAsc:
            return "出生时间（早→晚）"
        }
    }
}
