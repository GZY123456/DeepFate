import SwiftUI

struct SettingsView: View {
    @AppStorage("isLoggedIn") private var isLoggedIn = false
    @AppStorage("loginName") private var loginName = ""
    @AppStorage("backendBaseURL") private var backendBaseURL = "http://192.168.0.103:8000"
    @EnvironmentObject private var authViewModel: AuthViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showFaceIdBind = false
    @State private var showBackendTip = false
    
    var body: some View {
        NavigationStack {
            Form {
                Section("账户") {
                    NavigationLink(isLoggedIn ? "切换账号" : "登录账号") {
                        if isLoggedIn {
                            AccountSwitcherView()
                        } else {
                            LoginView()
                        }
                    }
                    
                    if isLoggedIn, authViewModel.userId != nil {
                        Button(authViewModel.faceIdEnabled ? "关闭面容 ID 登录" : "绑定面容 ID 登录") {
                            if authViewModel.faceIdEnabled {
                                authViewModel.disableFaceId()
                            } else {
                                showFaceIdBind = true
                            }
                        }
                    }
                    
                    if isLoggedIn {
                        Button("退出登录") {
                            Task {
                                await authViewModel.signOut()
                                isLoggedIn = false
                                loginName = ""
                                dismiss()
                            }
                        }
                        .foregroundStyle(.red)
                    }
                }
                
                Section("其他") {
                    NavigationLink("历史记录") {
                        Text("历史记录页面")
                    }
                    NavigationLink("隐私协议") {
                        Text("隐私协议页面")
                    }
                }
                
                Section("服务") {
                    TextField("后端服务地址", text: $backendBaseURL)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                    Button("保存服务地址") {
                        backendBaseURL = backendBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
                        showBackendTip = true
                    }
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
            .alert("已保存", isPresented: $showBackendTip) {
                Button("知道了", role: .cancel) {}
            } message: {
                Text("服务地址将用于后续登录和排盘请求。")
            }
            .sheet(isPresented: $showFaceIdBind) {
                FaceIdBindSheet(
                    phone: currentAccountPhone,
                    onConfirm: { password in
                        Task {
                            await authViewModel.signInWithPassword(phone: currentAccountPhone, password: password)
                            if authViewModel.isAuthenticated, let userId = authViewModel.userId {
                                authViewModel.enableFaceId(for: userId)
                                showFaceIdBind = false
                            }
                        }
                    }
                )
            }
        }
    }
    
    private var currentAccountPhone: String {
        guard let userId = authViewModel.userId,
              let account = authViewModel.accounts.first(where: { $0.id == userId }) else {
            return ""
        }
        return account.phone
    }
}

private struct FaceIdBindSheet: View {
    let phone: String
    let onConfirm: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    
    var body: some View {
        NavigationStack {
            Form {
                Section("安全确认") {
                    Text("请先输入密码以绑定面容 ID。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("手机号：\(phone)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    SecureField("登录密码", text: $password)
                }
                Section {
                    Button("确认绑定") {
                        onConfirm(password)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .navigationTitle("绑定面容 ID")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                }
            }
        }
    }
}
