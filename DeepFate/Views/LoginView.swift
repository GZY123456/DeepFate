import SwiftUI

struct LoginView: View {
    @AppStorage("isLoggedIn") private var isLoggedIn = false
    @AppStorage("loginName") private var loginName = ""
    @EnvironmentObject private var authViewModel: AuthViewModel
    @EnvironmentObject private var profileStore: ProfileStore
    @Environment(\.dismiss) private var dismiss

    @State private var mode: LoginMode = .sms
    @State private var phone = ""
    @State private var code = ""
    @State private var password = ""
    @State private var successMessage: String?
    @State private var showCreateAccount = false
    @State private var pendingDismiss = false
    @State private var showCreateAccountEntry = false
    @State private var showForgotPassword = false
    @State private var showFaceIdHelp = false

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("欢迎回来")
                        .font(.largeTitle.bold())
                    Text("使用手机号登录 DeepFate")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 10)

                Button("使用面容 ID 登录") {
                    if authViewModel.faceIdEnabled {
                        Task {
                            await authViewModel.signInWithFaceId(into: profileStore)
                            if authViewModel.isAuthenticated {
                                successMessage = "登录成功。"
                            }
                        }
                    } else {
                        showFaceIdHelp = true
                    }
                }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)

                Picker("登录方式", selection: $mode) {
                    ForEach(LoginMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                VStack(spacing: 14) {
                    TextField("手机号", text: $phone)
                        .keyboardType(.phonePad)
                        .textContentType(.telephoneNumber)
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))

                    if mode == .password {
                        SecureField("密码", text: $password)
                            .textContentType(.password)
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))
                    } else {
                        HStack(spacing: 12) {
                            TextField("短信验证码", text: $code)
                                .keyboardType(.numberPad)
                                .padding(12)
                                .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))
                            Button("发送验证码") {
                                sendCode()
                            }
                            .buttonStyle(.bordered)
                            .disabled(phoneTrimmed.isEmpty || authViewModel.isLoading)
                        }

                        if let debugCode = authViewModel.debugSMSCode {
                            Text("调试验证码：\(debugCode)")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Button(primaryButtonTitle) {
                    handlePrimaryAction()
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
                .disabled(isPrimaryDisabled || authViewModel.isLoading)

                HStack {
                    Button("忘记密码") {
                        showForgotPassword = true
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    Spacer()
                }

                Button("创建新账号") {
                    showCreateAccountEntry = true
                }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)

                if let errorMessage = authViewModel.errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let successMessage {
                    Text(successMessage)
                        .font(.footnote)
                        .foregroundStyle(.green)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let hasArchiveRecord = authViewModel.hasArchiveRecord, authViewModel.isAuthenticated {
                    Text(hasArchiveRecord ? "已找到你的档案记录。" : "暂未找到档案记录，可先创建档案。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 20)
        }
        .navigationTitle("登录")
        .onChange(of: authViewModel.isAuthenticated) {
            if authViewModel.isAuthenticated {
                loginName = authViewModel.displayName
                isLoggedIn = true
                if showCreateAccount {
                    pendingDismiss = true
                } else {
                    dismiss()
                }
            }
        }
        .onChange(of: authViewModel.needsAccountSetup) {
            if authViewModel.needsAccountSetup {
                showCreateAccount = true
            }
        }
        .sheet(isPresented: $showCreateAccount, onDismiss: {
            if pendingDismiss {
                pendingDismiss = false
                dismiss()
            }
        }) {
            CreateAccountView(phone: phoneTrimmed) {
                showCreateAccount = false
            }
            .environmentObject(authViewModel)
            .environmentObject(profileStore)
        }
        .sheet(isPresented: $showCreateAccountEntry) {
            CreateAccountView(phone: nil) {
                showCreateAccountEntry = false
            }
            .environmentObject(authViewModel)
            .environmentObject(profileStore)
        }
        .sheet(isPresented: $showForgotPassword) {
            ForgotPasswordView(prefilledPhone: phoneTrimmed)
                .environmentObject(authViewModel)
        }
        .alert("面容 ID 未绑定", isPresented: $showFaceIdHelp) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text("请先使用手机号登录，并在设置中绑定面容 ID。一个面容 ID 仅绑定一个账号。")
        }
    }
}

private extension LoginView {
    var phoneTrimmed: String {
        phone.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var codeTrimmed: String {
        code.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var passwordTrimmed: String {
        password.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var primaryButtonTitle: String {
        mode == .password ? "密码登录" : "验证码登录"
    }

    var isPrimaryDisabled: Bool {
        if mode == .password {
            return phoneTrimmed.isEmpty || passwordTrimmed.isEmpty
        }
        return phoneTrimmed.isEmpty || codeTrimmed.count != 6
    }

    func sendCode() {
        authViewModel.errorMessage = nil
        successMessage = nil
        Task {
            await authViewModel.sendSMSCode(to: phoneTrimmed)
            if authViewModel.errorMessage == nil {
                successMessage = "验证码已发送。"
            }
        }
    }

    func verifyCode() {
        authViewModel.errorMessage = nil
        successMessage = nil
        Task {
            await authViewModel.verifySMSCode(phone: phoneTrimmed, code: codeTrimmed)
            if authViewModel.isAuthenticated {
                successMessage = "登录成功。"
                await authViewModel.syncArchives(into: profileStore)
            }
        }
    }

    func signInWithPassword() {
        authViewModel.errorMessage = nil
        successMessage = nil
        Task {
            await authViewModel.signInWithPassword(phone: phoneTrimmed, password: passwordTrimmed)
            if authViewModel.isAuthenticated {
                successMessage = "登录成功。"
                await authViewModel.syncArchives(into: profileStore)
            }
        }
    }

    func handlePrimaryAction() {
        if mode == .password {
            signInWithPassword()
        } else {
            verifyCode()
        }
    }
}

private enum LoginMode: CaseIterable {
    case sms
    case password

    var title: String {
        switch self {
        case .sms:
            return "验证码"
        case .password:
            return "密码"
        }
    }
}

struct CreateAccountView: View {
    let phone: String?
    let onComplete: () -> Void

    @EnvironmentObject private var authViewModel: AuthViewModel
    @EnvironmentObject private var profileStore: ProfileStore
    @Environment(\.dismiss) private var dismiss

    @State private var phoneInput: String = ""
    @State private var nickname = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var successMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("账号信息") {
                    if let phone {
                        Text("手机号：\(phone)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        TextField("手机号", text: $phoneInput)
                            .keyboardType(.phonePad)
                    }
                    TextField("昵称", text: $nickname)
                    SecureField("设置密码（至少 6 位）", text: $password)
                    SecureField("确认密码", text: $confirmPassword)
                }

                if let errorMessage = authViewModel.errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                if let successMessage {
                    Text(successMessage)
                        .font(.footnote)
                        .foregroundStyle(.green)
                }

                Section {
                    Button("创建账号并登录") {
                        createAccount()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canCreateAccount)
                }
            }
            .navigationTitle("创建账号")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                }
            }
        }
    }

    private var canCreateAccount: Bool {
        let trimmedNickname = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPassword = password.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPhone = resolvedPhone.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmedNickname.isEmpty
            && trimmedPassword.count >= 6
            && trimmedPassword == confirmPassword.trimmingCharacters(in: .whitespacesAndNewlines)
            && !trimmedPhone.isEmpty
    }

    private func createAccount() {
        authViewModel.errorMessage = nil
        successMessage = nil
        Task {
            await authViewModel.registerAccount(phone: resolvedPhone, nickname: nickname, password: password)
            if authViewModel.isAuthenticated {
                successMessage = "账号创建成功。"
                await authViewModel.syncArchives(into: profileStore)
                onComplete()
                dismiss()
            }
        }
    }

    private var resolvedPhone: String {
        if let phone, !phone.isEmpty {
            return phone
        }
        return phoneInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct ForgotPasswordView: View {
    let prefilledPhone: String?
    @EnvironmentObject private var authViewModel: AuthViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var phone = ""
    @State private var code = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var successMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("账号信息") {
                    TextField("手机号", text: $phone)
                        .keyboardType(.phonePad)
                    HStack(spacing: 12) {
                        TextField("短信验证码", text: $code)
                            .keyboardType(.numberPad)
                        Button("发送验证码") {
                            sendCode()
                        }
                        .buttonStyle(.bordered)
                        .disabled(phoneTrimmed.isEmpty || authViewModel.isLoading)
                    }
                    SecureField("新密码（至少 6 位）", text: $password)
                    SecureField("确认新密码", text: $confirmPassword)
                }

                if let errorMessage = authViewModel.errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                if let successMessage {
                    Text(successMessage)
                        .font(.footnote)
                        .foregroundStyle(.green)
                }

                Section {
                    Button("重置密码") {
                        resetPassword()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSubmit)
                }
            }
            .navigationTitle("忘记密码")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                if let prefilledPhone, !prefilledPhone.isEmpty {
                    phone = prefilledPhone
                }
            }
        }
    }

    private var phoneTrimmed: String {
        phone.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var codeTrimmed: String {
        code.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var passwordTrimmed: String {
        password.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var confirmTrimmed: String {
        confirmPassword.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSubmit: Bool {
        !phoneTrimmed.isEmpty
            && codeTrimmed.count == 6
            && passwordTrimmed.count >= 6
            && passwordTrimmed == confirmTrimmed
    }

    private func sendCode() {
        authViewModel.errorMessage = nil
        successMessage = nil
        Task {
            await authViewModel.sendSMSCode(to: phoneTrimmed)
            if authViewModel.errorMessage == nil {
                successMessage = "验证码已发送。"
            }
        }
    }

    private func resetPassword() {
        authViewModel.errorMessage = nil
        successMessage = nil
        Task {
            await authViewModel.resetPassword(phone: phoneTrimmed, code: codeTrimmed, newPassword: passwordTrimmed)
            if authViewModel.errorMessage == nil {
                successMessage = "密码已重置。"
                dismiss()
            }
        }
    }
}
