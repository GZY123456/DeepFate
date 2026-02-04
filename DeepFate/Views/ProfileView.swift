import SwiftUI
import UIKit

struct ProfileView: View {
    @AppStorage("isLoggedIn") private var isLoggedIn = false
    @AppStorage("loginName") private var loginName = ""
    @EnvironmentObject private var authViewModel: AuthViewModel
    @EnvironmentObject private var profileStore: ProfileStore
    @State private var showingAvatarOptions = false
    @State private var showCameraPicker = false
    @State private var showPhotoPicker = false
    @State private var showSettings = false

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                Color(red: 0.09, green: 0.26, blue: 0.32)
                    .ignoresSafeArea()

                Image("personal_background")
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: geometry.size.width)
                    .clipped()
                    .ignoresSafeArea(edges: .top)

                ScrollView {
                    VStack(spacing: 0) {
                        Color.clear
                            .frame(height: 280)

                        VStack(spacing: 0) {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("藏经阁")
                                    .font(.system(.title2, design: .serif).weight(.semibold))
                                    .foregroundStyle(.white)
                                    .padding(.leading, 24)
                                
                                if isLoggedIn {
                                    BookShelfView()
                                        .padding(.vertical, 8)
                                } else {
                                    Text("登录后查看档案馆")
                                        .font(.footnote)
                                        .foregroundStyle(.white.opacity(0.7))
                                        .padding(.leading, 24)
                                        .padding(.vertical, 8)
                                }
                            }
                            .padding(.top, 50)
                        }
                        .padding(.bottom, 40)
                }
            }

            VStack(spacing: 12) {
                Button {
                    showingAvatarOptions = true
                } label: {
                    if let image = currentAvatarImage {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 108, height: 108)
                            .clipShape(Circle())
                            .overlay(Circle().stroke(Color.white.opacity(0.7), lineWidth: 2))
                    } else {
                        ZStack {
                            Circle()
                                .fill(Color.white.opacity(0.1))
                                .frame(width: 108, height: 108)
                            Circle()
                                .stroke(Color.white.opacity(0.7), lineWidth: 2)
                                .frame(width: 108, height: 108)
                            ProfileAvatarView(name: loginName.isEmpty ? "用户" : loginName, size: 108)
                        }
                    }
                }
                .buttonStyle(.plain)

                VStack(spacing: 4) {
                    Text(isLoggedIn ? loginName : "匿名占星师")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text(isLoggedIn ? "已登录，可跨档案使用" : "欢迎回来，探索你的命运线索")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
            .frame(maxWidth: .infinity)
            .position(x: geometry.size.width / 2, y: 218.5)
        }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("个人中心")
                    .font(.headline)
                    .foregroundStyle(.white)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape.fill")
                        .foregroundStyle(.white)
                }
            }
        }
        .toolbarBackground(.hidden, for: .navigationBar)
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .confirmationDialog("选择头像来源", isPresented: $showingAvatarOptions, titleVisibility: .visible) {
            Button("拍摄照片") {
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    showCameraPicker = true
                }
            }
            Button("从相册选择") {
                showPhotoPicker = true
            }
            Button("取消", role: .cancel) {}
        }
        .sheet(isPresented: $showCameraPicker) {
            ImagePicker(sourceType: .camera) { image in
                updateAvatar(image)
            }
        }
        .sheet(isPresented: $showPhotoPicker) {
            ImagePicker(sourceType: .photoLibrary) { image in
                updateAvatar(image)
            }
        }
    }

    private var currentAvatarImage: UIImage? {
        guard let userId = authViewModel.userId,
              let account = authViewModel.accounts.first(where: { $0.id == userId }) else { return nil }
        if let path = account.avatarPath {
            let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let url = base.appendingPathComponent("avatars", isDirectory: true)
                .appendingPathComponent(path)
            if let data = try? Data(contentsOf: url), let image = UIImage(data: data) {
                return image
            }
        }
        if let data = account.avatarData {
            return UIImage(data: data)
        }
        return nil
    }

    private func updateAvatar(_ image: UIImage?) {
        guard let userId = authViewModel.userId else { return }
        if let image, let data = image.jpegData(compressionQuality: 0.9) {
            authViewModel.updateAvatar(for: userId, data: data)
        }
        showCameraPicker = false
        showPhotoPicker = false
    }
}

private struct BookCard: View {
    let title: String
    let subtitle: String?
    let tint: Color
    let titleFont: Font
    let subtitleFont: Font

    init(
        title: String,
        subtitle: String? = nil,
        tint: Color,
        titleFont: Font = .title3.weight(.semibold),
        subtitleFont: Font = .caption
    ) {
        self.title = title
        self.subtitle = subtitle
        self.tint = tint
        self.titleFont = titleFont
        self.subtitleFont = subtitleFont
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [tint.opacity(0.85), tint.opacity(0.55)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(tint.opacity(0.9), lineWidth: 1)
                .blendMode(.overlay)
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(0.18))
                    .frame(width: 10)
                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(titleFont)
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(subtitleFont)
                            .foregroundStyle(.white.opacity(0.8))
                    }
                }
            }
            .padding(12)
        }
        .frame(width: 120, height: 150, alignment: .topLeading)
        .shadow(color: Color.black.opacity(0.15), radius: 6, x: 0, y: 4)
    }
}

private struct BookShelfView: View {
    var body: some View {
        HStack {
            NavigationLink {
                ArchiveView()
            } label: {
                BookCard(title: "档案", tint: .purple)
            }
            .buttonStyle(.plain)
            .padding(.leading, 24)
            
            Spacer()
        }
    }
}
