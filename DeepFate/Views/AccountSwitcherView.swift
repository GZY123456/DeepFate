import SwiftUI
import UIKit

struct AccountSwitcherView: View {
    @AppStorage("isLoggedIn") private var isLoggedIn = false
    @AppStorage("loginName") private var loginName = ""
    @EnvironmentObject private var authViewModel: AuthViewModel
    @EnvironmentObject private var profileStore: ProfileStore
    @Environment(\.dismiss) private var dismiss
    @State private var showingAvatarOptions = false
    @State private var showCameraPicker = false
    @State private var showPhotoPicker = false
    @State private var selectedAccountId: String?
    @State private var isManaging = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if authViewModel.accounts.isEmpty {
                    Text("暂无已登录账号")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 8)
                } else {
                    ForEach(authViewModel.accounts) { account in
                        HStack(spacing: 14) {
                            Button {
                                selectedAccountId = account.id
                                showingAvatarOptions = true
                            } label: {
                                AccountAvatarView(account: account)
                            }
                            .buttonStyle(.plain)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(account.nickname)
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                Text("用户 \(account.phone)")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if account.id == authViewModel.userId {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.red)
                                    .font(.title3)
                            } else {
                                Image(systemName: "circle")
                                    .foregroundStyle(.secondary)
                                    .font(.title3)
                            }
                        }
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if !isManaging {
                                select(account)
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                authViewModel.deleteAccount(id: account.id)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                        .overlay(alignment: .trailing) {
                            if isManaging {
                                Button(role: .destructive) {
                                    authViewModel.deleteAccount(id: account.id)
                                } label: {
                                    Image(systemName: "trash")
                                        .foregroundStyle(.red)
                                        .padding(8)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                Divider()
                    .padding(.top, 8)

                NavigationLink {
                    LoginView()
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "plus")
                            .font(.title3)
                            .frame(width: 44, height: 44)
                            .background(Circle().fill(Color(.secondarySystemBackground)))
                        Text("添加已有账号")
                            .font(.headline)
                        Spacer()
                    }
                    .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
        }
        .navigationTitle("切换账号")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(isManaging ? "完成" : "管理") {
                    withAnimation(.easeInOut) {
                        isManaging.toggle()
                    }
                }
            }
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

    private func select(_ account: LocalAccount) {
        authViewModel.selectAccount(account)
        loginName = account.nickname
        isLoggedIn = true
        Task {
            await authViewModel.syncArchives(into: profileStore)
            dismiss()
        }
    }

    private func updateAvatar(_ image: UIImage?) {
        guard let accountId = selectedAccountId else { return }
        if let image, let data = image.jpegData(compressionQuality: 0.9) {
            authViewModel.updateAvatar(for: accountId, data: data)
        }
        selectedAccountId = nil
        showCameraPicker = false
        showPhotoPicker = false
    }
}

private struct AccountAvatarView: View {
    let account: LocalAccount

    var body: some View {
        if let image = loadImage() {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 48, height: 48)
                .clipShape(Circle())
        } else {
            ProfileAvatarView(name: account.nickname, size: 48)
        }
    }

    private func loadImage() -> UIImage? {
        if let path = account.avatarPath {
            let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let url = base.appendingPathComponent("avatars", isDirectory: true)
                .appendingPathComponent(path)
            if let data = try? Data(contentsOf: url), let image = UIImage(data: data) {
                return image
            }
        }
        if let data = account.avatarData, let image = UIImage(data: data) {
            return image
        }
        return nil
    }
}
