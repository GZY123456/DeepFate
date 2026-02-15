import SwiftUI
import UIKit

struct MainView: View {
    @State private var chats: [ChatSession] = [ChatSession.default]
    @State private var currentChatId: UUID = ChatSession.default.id
    @AppStorage("lastChatId") private var lastChatIdString = ""
    @State private var isDrawerOpen = false
    @State private var drawerDragOffset: CGFloat = 0
    @State private var inputText = ""
    @State private var showProfileSheet = false
    @State private var showProfilePicker = false
    @State private var pendingPrompt = ""
    @EnvironmentObject private var profileStore: ProfileStore
    @EnvironmentObject private var locationStore: LocationStore
    @EnvironmentObject private var consultRouter: ConsultRouter
    @FocusState private var isInputFocused: Bool
    @State private var isSending = false
    @State private var currentTask: Task<Void, Never>?
    @State private var currentAssistantId: UUID?
    @State private var currentUserId: UUID?
    @State private var currentTargetAssistantId: UUID?
    @State private var currentAssistantText: String = ""
    @StateObject private var speechManager = SpeechManager()
    @State private var showCopyToast = false
    @State private var showScrollToBottom = false
    @State private var isUserDragging = false
    @State private var chatRatio: CGFloat = 0.5
    @AppStorage("isLoggedIn") private var isLoggedIn = false
    @AppStorage("selectedTianshiId") private var selectedTianshiId: String = Tianshi.soft.rawValue
    @State private var showTianshiPicker = false
    private let chatClient = SparkChatClient()

    private var currentTianshi: Tianshi { Tianshi(rawValue: selectedTianshiId) ?? .soft }
    private var currentTheme: ConsultTheme { currentTianshi.theme }

    private let suggestions = [
        "测算今日运势",
        "看看最近情感走向",
        "命格运势分析"
    ]

    private var activeProfile: UserProfile? {
        guard let activeProfileID = profileStore.activeProfileID else { return nil }
        return profileStore.profiles.first { $0.id == activeProfileID }
    }

    private var currentChatIndex: Int? {
        chats.firstIndex(where: { $0.id == currentChatId })
    }

    private var currentMessages: [ChatMessage] {
        guard let index = currentChatIndex else { return [] }
        return chats[index].messages
    }

    private var currentChatTitle: String {
        chats.first(where: { $0.id == currentChatId })?.title ?? "DeepFate"
    }

    private var profileButtonTitle: String {
        guard let profile = activeProfile else { return "档案" }
        let trimmed = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "档案" : String(trimmed.prefix(4))
    }

    var body: some View {
        if isLoggedIn {
            chatContent
        } else {
            LoginRequiredView()
        }
    }

    private var chatContent: some View {
        DraggableChatLayout(chatRatio: $chatRatio) {
            Image(currentTianshi.backgroundImageName)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .clipped()
                .ignoresSafeArea()
        } chatContent: {
            chatMainColumn
        }
        .environment(\.consultTheme, currentTheme)
        .ignoresSafeArea(edges: .top)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    withAnimation(.easeOut) {
                        isDrawerOpen = true
                        drawerDragOffset = 0
                    }
                } label: {
                    Image(systemName: "line.3.horizontal")
                        .foregroundStyle(currentTheme.accent)
                }
            }
            ToolbarItem(placement: .principal) {
                Text(currentChatTitle)
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(1)
                    .foregroundStyle(currentTheme.primaryText)
            }
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 12) {
                    Button {
                        showTianshiPicker = true
                    } label: {
                        Image(systemName: "person.crop.circle.badge.plus")
                            .foregroundStyle(currentTheme.accent)
                    }
                    Button {
                        showProfilePicker = true
                    } label: {
                        HStack(spacing: 6) {
                            ProfileAvatarView(name: activeProfile?.name ?? "档", size: 22)
                            Text(profileButtonTitle)
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1)
                                .foregroundStyle(currentTheme.primaryText)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(
                            Capsule()
                                .fill(currentTheme.surface)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .overlay(alignment: .top) { copyToastOverlay }
        .overlay { drawerBackdropOverlay }
        .overlay(alignment: .leading) { drawerPanelOverlay }
        .contentShape(Rectangle())
        .onTapGesture {
            isInputFocused = false
            hideKeyboard()
        }
        .sheet(isPresented: $showProfileSheet) { createProfileSheet }
        .sheet(isPresented: $showProfilePicker) { profilePickerSheet }
        .sheet(isPresented: $showTianshiPicker) {
            TianshiPickerSheet(selectedTianshiId: $selectedTianshiId)
        }
        .onAppear {
            restoreLastChatIfNeeded()
            handlePendingPromptIfNeeded()
            syncCurrentChatGreetingToTianshi(selectedTianshiId)
        }
        .onChange(of: consultRouter.pendingChartPrompt) { _, newValue in
            guard let prompt = newValue, !prompt.isEmpty else { return }
            let displayText = consultRouter.pendingChartDisplayText
            sendUserMessage(prompt, displayText: displayText)
            consultRouter.clearPendingChart()
        }
        .onChange(of: selectedTianshiId) { _, newId in
            syncCurrentChatGreetingToTianshi(newId)
        }
        .gesture(drawerEdgeDragGesture)
    }

    private var chatMainColumn: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                chatScrollContent(proxy: proxy)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            SuggestionChipsView(suggestions: suggestions, isDisabled: isSending) { suggestion in
                guard !isSending else { return }
                pendingPrompt = suggestion
                if activeProfile == nil {
                    showProfileSheet = true
                } else {
                    sendUserMessage(suggestion)
                    pendingPrompt = ""
                }
            }
            .padding(.vertical, 10)

            chatInputSection
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    private func chatScrollContent(proxy: ScrollViewProxy) -> some View {
        ZStack(alignment: .bottomTrailing) {
            chatMessageScrollView(proxy: proxy)
            if showScrollToBottom {
                scrollToBottomButton(proxy: proxy)
            }
        }
    }

    private func chatMessageScrollView(proxy: ScrollViewProxy) -> some View {
        let lastUserId = currentMessages.last(where: { $0.isUser })?.id
        let initialAssistantId = currentMessages.first?.id
        return ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(currentMessages) { message in
                    ChatBubbleView(
                        message: message,
                        canEdit: message.isUser && message.id == lastUserId && !isSending,
                        showActionBar: !message.isUser && message.id != initialAssistantId,
                        isSpeaking: speechManager.speakingMessageId == message.id,
                        onRetry: { retryMessage(message) },
                        onEdit: { editMessage(message) },
                        onCopy: { copyMessage(message) },
                        onSpeak: { speakMessage(message) }
                    )
                    .id(message.id)
                }
                Color.clear
                    .frame(height: 1)
                    .id("BOTTOM_ANCHOR")
            }
            .padding(.horizontal)
            .padding(.top, 12)
            .padding(.bottom, 140)
        }
        .scrollDismissesKeyboard(.interactively)
        .contentShape(Rectangle())
        .onTapGesture {
            isInputFocused = false
            hideKeyboard()
        }
        .onChange(of: currentMessages.count) {
            if !isUserDragging {
                withAnimation(.easeOut) { proxy.scrollTo("BOTTOM_ANCHOR", anchor: .bottom) }
            }
            showScrollToBottom = isUserDragging
        }
        .onChange(of: currentAssistantText) {
            if !isUserDragging {
                withAnimation(.easeOut) { proxy.scrollTo("BOTTOM_ANCHOR", anchor: .bottom) }
            }
        }
        .simultaneousGesture(
            DragGesture()
                .onChanged { _ in
                    isUserDragging = true
                    showScrollToBottom = true
                }
                .onEnded { _ in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        isUserDragging = false
                    }
                }
        )
    }

    private func scrollToBottomButton(proxy: ScrollViewProxy) -> some View {
        Button {
            withAnimation(.easeOut) {
                proxy.scrollTo("BOTTOM_ANCHOR", anchor: .bottom)
                showScrollToBottom = false
            }
        } label: {
            Image(systemName: "arrow.down")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.white)
                .frame(width: 36, height: 36)
                .background(Circle().fill(currentTheme.accent))
        }
        .padding(.trailing, 18)
        .padding(.bottom, 128)
    }

    private var chatInputSection: some View {
        let theme = currentTheme
        return VStack(spacing: 6) {
            InputBar(text: $inputText, focus: $isInputFocused, isSending: isSending, theme: theme, onStop: stopSending) {
                guard !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                guard !isSending else { return }
                pendingPrompt = inputText
                inputText = ""
                if activeProfile == nil {
                    showProfileSheet = true
                } else {
                    let targetAssistantId = currentTargetAssistantId
                    sendUserMessage(pendingPrompt, replaceAssistantId: targetAssistantId)
                    currentTargetAssistantId = nil
                    pendingPrompt = ""
                }
            }
            Text("以上内容均由AI生成，请仔细甄别")
                .font(.footnote)
                .foregroundStyle(theme.primaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 14)
        .background(theme.surface)
    }

    @ViewBuilder private var copyToastOverlay: some View {
        if showCopyToast {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("已复制到剪贴板")
                    .font(.subheadline)
                    .foregroundStyle(.primary)
            }
            .frame(width: 220, height: 52)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: Color.black.opacity(0.15), radius: 12, x: 0, y: 6)
            .padding(.top, 12)
            .transition(.opacity)
        }
    }

    @ViewBuilder private var drawerBackdropOverlay: some View {
        if isDrawerOpen {
            Color.black.opacity(0.2)
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation(.easeOut) {
                        isDrawerOpen = false
                        drawerDragOffset = 0
                    }
                }
        }
    }

    private var drawerPanelOverlay: some View {
        let drawerWidth = UIScreen.main.bounds.width * 0.82
        return ChatDrawerView(
            chats: $chats,
            currentChatId: currentChatId,
            onSelect: { chatId in
                currentChatId = chatId
                lastChatIdString = chatId.uuidString
                withAnimation(.easeOut) {
                    isDrawerOpen = false
                    drawerDragOffset = 0
                }
            },
            onCreate: {
                let chat = ChatSession(initialMessage: currentTianshi.greeting)
                chats.insert(chat, at: 0)
                currentChatId = chat.id
                lastChatIdString = chat.id.uuidString
                withAnimation(.easeOut) {
                    isDrawerOpen = false
                    drawerDragOffset = 0
                }
            }
        )
        .frame(width: drawerWidth)
        .offset(x: (isDrawerOpen ? 0 : -drawerWidth) + drawerDragOffset)
        .gesture(
            DragGesture()
                .onChanged { value in
                    let translation = value.translation.width
                    if translation < 0 {
                        drawerDragOffset = max(translation, -drawerWidth)
                    }
                }
                .onEnded { value in
                    if value.translation.width < -drawerWidth * 0.3 {
                        withAnimation(.easeOut) {
                            isDrawerOpen = false
                            drawerDragOffset = 0
                        }
                    } else {
                        withAnimation(.easeOut) {
                            isDrawerOpen = true
                            drawerDragOffset = 0
                        }
                    }
                }
        )
    }

    @ViewBuilder private var createProfileSheet: some View {
        CreateProfileSheet(
            provinces: locationStore.provinces.isEmpty ? defaultLocationOptions : locationStore.provinces
        ) { profile in
            profileStore.add(profile)
            profileStore.setActive(profile.id)
            appendMockResponse()
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder private var profilePickerSheet: some View {
        ProfilePickerSheet(
            profiles: profileStore.profiles,
            activeProfileID: profileStore.activeProfileID,
            provinces: locationStore.provinces.isEmpty ? defaultLocationOptions : locationStore.provinces,
            onSelect: { profile in
                profileStore.setActive(profile.id)
            },
            onCreate: { profile in
                profileStore.add(profile)
                profileStore.setActive(profile.id)
            }
        )
        .presentationDetents([.medium, .large])
    }

    private func restoreLastChatIfNeeded() {
        if let id = UUID(uuidString: lastChatIdString),
           chats.contains(where: { $0.id == id }) {
            currentChatId = id
        }
    }

    /// 切换天师后，若当前会话的首条消息是某位天师的开场白，则替换为当前所选天师的开场白
    private func syncCurrentChatGreetingToTianshi(_ newTianshiId: String) {
        guard let tianshi = Tianshi(rawValue: newTianshiId),
              let index = currentChatIndex,
              !chats[index].messages.isEmpty else { return }
        let first = chats[index].messages[0]
        guard !first.isUser,
              Tianshi.allCases.contains(where: { $0.greeting == first.text }) else { return }
        chats[index].messages[0].text = tianshi.greeting
    }

    private var drawerEdgeDragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                guard !isDrawerOpen else { return }
                guard value.startLocation.x < 24 else { return }
                if value.translation.width > 0 {
                    let drawerWidth = UIScreen.main.bounds.width * 0.82
                    drawerDragOffset = min(value.translation.width - drawerWidth, 0)
                }
            }
            .onEnded { value in
                guard !isDrawerOpen else { return }
                let drawerWidth = UIScreen.main.bounds.width * 0.82
                if value.translation.width > drawerWidth * 0.25 {
                    withAnimation(.easeOut) {
                        isDrawerOpen = true
                        drawerDragOffset = 0
                    }
                } else {
                    withAnimation(.easeOut) {
                        drawerDragOffset = 0
                    }
                }
            }
    }

    private struct LoginRequiredView: View {
        var body: some View {
            VStack(spacing: 14) {
                Spacer()
                Image(systemName: "lock.circle.fill")
                    .font(.system(size: 54))
                    .foregroundStyle(.purple)
                Text("登录后查看历史对话")
                    .font(.headline)
                Text("请先完成登录，再开始你的命运探索。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                NavigationLink("去登录") {
                    LoginView()
                }
                .buttonStyle(.borderedProminent)
                Spacer()
            }
            .padding(.horizontal, 20)
        }
    }

    private func appendMockResponse() {
        if !pendingPrompt.isEmpty {
            sendUserMessage(pendingPrompt)
            pendingPrompt = ""
        }
    }

    private func handlePendingPromptIfNeeded() {
        guard let prompt = consultRouter.pendingChartPrompt, !prompt.isEmpty else { return }
        let displayText = consultRouter.pendingChartDisplayText
        sendUserMessage(prompt, displayText: displayText)
        consultRouter.clearPendingChart()
    }

    private func sendUserMessage(_ content: String, displayText: String? = nil, replaceAssistantId: UUID? = nil) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !isSending else { return }
        let showText = displayText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? trimmed
        let userMessage = ChatMessage(
            text: showText,
            apiContent: displayText != nil ? trimmed : nil,
            isUser: true,
            canRetry: false
        )
        appendMessage(userMessage)
        if let index = currentChatIndex {
            chats[index].lastMessageAt = Date()
        }
        lastChatIdString = currentChatId.uuidString
        sendChat(for: userMessage.id, content: trimmed, displayText: displayText, replaceAssistantId: replaceAssistantId)
        updateTitleIfNeeded(firstMessage: showText, chatId: currentChatId)
    }

    private func retryMessage(_ message: ChatMessage) {
        guard message.isUser else { return }
        guard !isSending else { return }
        if let chatIndex = currentChatIndex,
           let msgIndex = chats[chatIndex].messages.firstIndex(where: { $0.id == message.id }) {
            chats[chatIndex].messages[msgIndex].canRetry = false
        }
        let contentToSend = message.apiContent ?? message.text
        sendChat(for: message.id, content: contentToSend, displayText: message.apiContent != nil ? message.text : nil, replaceAssistantId: nil)
    }

    private func stopSending() {
        guard isSending else { return }
        currentTask?.cancel()
        isSending = false
        if let assistantId = currentAssistantId,
           let chatIndex = currentChatIndex,
           let msgIndex = chats[chatIndex].messages.firstIndex(where: { $0.id == assistantId }) {
            chats[chatIndex].messages[msgIndex].text = currentAssistantText
            chats[chatIndex].messages[msgIndex].isStreaming = false
            chats[chatIndex].messages[msgIndex].isIncomplete = true
        }
        if let userId = currentUserId,
           let chatIndex = currentChatIndex,
           let msgIndex = chats[chatIndex].messages.firstIndex(where: { $0.id == userId }) {
            chats[chatIndex].messages[msgIndex].canRetry = true
        }
        currentTask = nil
        currentAssistantId = nil
        currentUserId = nil
        currentAssistantText = ""
        currentTargetAssistantId = nil
    }

    private func editMessage(_ message: ChatMessage) {
        guard message.isUser else { return }
        guard !isSending else { return }
        if let chatIndex = currentChatIndex,
           let startIndex = chats[chatIndex].messages.firstIndex(where: { $0.id == message.id }) {
            let originalText = chats[chatIndex].messages[startIndex].text
            chats[chatIndex].messages[startIndex].text = ""
            inputText = message.text
            isInputFocused = true

            if let assistantIndex = chats[chatIndex].messages[(startIndex + 1)...].firstIndex(where: { !$0.isUser }) {
                currentTargetAssistantId = chats[chatIndex].messages[assistantIndex].id
            }
            pendingPrompt = originalText
        }
    }

    private func copyMessage(_ message: ChatMessage) {
        UIPasteboard.general.string = message.text
        withAnimation(.easeInOut(duration: 0.2)) {
            showCopyToast = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation(.easeInOut(duration: 0.2)) {
                showCopyToast = false
            }
        }
    }

    private func speakMessage(_ message: ChatMessage) {
        speechManager.toggleSpeak(messageId: message.id, text: message.text)
    }

    private func sendChat(for userMessageId: UUID, content: String, displayText: String? = nil, replaceAssistantId: UUID?) {
        let assistantId = replaceAssistantId ?? UUID()
        if let replaceAssistantId,
           let chatIndex = currentChatIndex,
           let msgIndex = chats[chatIndex].messages.firstIndex(where: { $0.id == replaceAssistantId }) {
            chats[chatIndex].messages[msgIndex].text = ""
            chats[chatIndex].messages[msgIndex].isStreaming = true
            chats[chatIndex].messages[msgIndex].isIncomplete = false
        } else {
            appendMessage(ChatMessage(id: assistantId, text: "", isUser: false, isStreaming: true))
        }
        isSending = true
        currentAssistantId = assistantId
        currentUserId = userMessageId
        currentAssistantText = ""

        let history = currentMessages.filter { !$0.text.isEmpty }
        let backendMessages = history.map { $0.asBackendMessage }
        let profileId = activeProfile?.id.uuidString

        currentTask = chatClient.send(messages: backendMessages, profileId: profileId, onDelta: { delta in
            DispatchQueue.main.async {
                if let chatIndex = currentChatIndex,
                   let msgIndex = chats[chatIndex].messages.firstIndex(where: { $0.id == assistantId }) {
                    chats[chatIndex].messages[msgIndex].text += delta
                    chats[chatIndex].messages[msgIndex].isIncomplete = false
                    currentAssistantText = chats[chatIndex].messages[msgIndex].text
                }
            }
        }, onComplete: { result in
            DispatchQueue.main.async {
                isSending = false
                if currentAssistantId == assistantId {
                    currentAssistantId = nil
                    currentUserId = nil
                    currentTask = nil
                    currentAssistantText = ""
                }
                if let chatIndex = currentChatIndex,
                   let msgIndex = chats[chatIndex].messages.firstIndex(where: { $0.id == assistantId }) {
                    chats[chatIndex].messages[msgIndex].isStreaming = false
                }
                switch result {
                case .success:
                    if let chatIndex = currentChatIndex,
                       let msgIndex = chats[chatIndex].messages.firstIndex(where: { $0.id == userMessageId }) {
                        chats[chatIndex].messages[msgIndex].canRetry = false
                    }
                case let .failure(error):
                    if error is CancellationError {
                        // 已在 stopSending 处理中保留半段回复
                        return
                    }
                    removeMessage(id: assistantId)
                    if let chatIndex = currentChatIndex,
                       let msgIndex = chats[chatIndex].messages.firstIndex(where: { $0.id == userMessageId }) {
                        chats[chatIndex].messages[msgIndex].canRetry = true
                    } else {
                        appendMessage(ChatMessage(text: displayText ?? content, apiContent: displayText != nil ? content : nil, isUser: true, canRetry: true))
                    }
                    if currentMessages.last?.text != "请求失败：\(error.localizedDescription)" {
                        appendMessage(ChatMessage(text: "请求失败：\(error.localizedDescription)", isUser: false))
                    }
                }
            }
        })
    }

    private func appendMessage(_ message: ChatMessage) {
        guard let index = currentChatIndex else { return }
        chats[index].messages.append(message)
    }

    private func removeMessage(id: UUID) {
        guard let index = currentChatIndex else { return }
        chats[index].messages.removeAll { $0.id == id }
    }

    private func updateTitleIfNeeded(firstMessage: String, chatId: UUID) {
        guard let index = chats.firstIndex(where: { $0.id == chatId }) else { return }
        guard chats[index].title == "新建聊天" else { return }
        let userCount = chats[index].messages.filter { $0.isUser }.count
        guard userCount == 1 else { return }
        chatClient.fetchTitle(for: firstMessage) { result in
            DispatchQueue.main.async {
                if let idx = chats.firstIndex(where: { $0.id == chatId }) {
                    switch result {
                    case let .success(title) where !title.isEmpty:
                        chats[idx].title = title
                    default:
                        chats[idx].title = "新建聊天"
                    }
                }
            }
        }
    }
}

private struct ChatSession: Identifiable, Equatable {
    let id: UUID
    var title: String
    var messages: [ChatMessage]
    var isPinned: Bool
    let createdAt: Date
    var lastMessageAt: Date?

    static let `default` = ChatSession(initialMessage: Tianshi.soft.greeting)

    init(id: UUID = UUID(), title: String = "新建聊天", initialMessage: String? = nil) {
        self.id = id
        self.title = title
        self.messages = [
            ChatMessage(text: initialMessage ?? Tianshi.soft.greeting, isUser: false)
        ]
        self.isPinned = false
        self.createdAt = Date()
        self.lastMessageAt = nil
    }
}

private struct ChatDrawerView: View {
    @Binding var chats: [ChatSession]
    let currentChatId: UUID
    let onSelect: (UUID) -> Void
    let onCreate: () -> Void
    @State private var renamingChatId: UUID?
    @State private var renameText = ""
    @State private var searchText = ""
    @AppStorage("loginName") private var loginName = ""

    private let tags = ["紫微斗数", "星盘合盘", "奇门遁甲", "八字命盘"]

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("聊天列表")
                    .font(.title2.weight(.bold))
                Spacer()
                Button {
                    onCreate()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                        Text("新建")
                    }
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.purple.opacity(0.18)))
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 6)

            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("搜索...", text: $searchText)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))
            .padding(.top, 10)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(tags, id: \.self) { tag in
                        Button {} label: {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(Color.purple.opacity(0.6))
                                    .frame(width: 10, height: 10)
                                Text(tag)
                                    .font(.subheadline.weight(.semibold))
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(Color(.secondarySystemBackground))
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Divider()

            ScrollView {
                VStack(spacing: 12) {
                    ForEach(sortedChats) { chat in
                        Button {
                            onSelect(chat.id)
                        } label: {
                            HStack {
                                Text(chat.title)
                                Spacer()
                                if chat.id == currentChatId {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.purple)
                                }
                            }
                            .padding(.vertical, 6)
                        }
                        .contextMenu {
                            Button(chat.isPinned ? "取消置顶" : "置顶") {
                                togglePin(chat.id)
                            }
                            Button("重命名") {
                                renamingChatId = chat.id
                                renameText = chat.title
                            }
                            Button("删除", role: .destructive) {
                                deleteChat(chat.id)
                            }
                        }
                    }
                }
            }

            HStack(spacing: 10) {
                ProfileAvatarView(name: displayName, size: 36)
                VStack(alignment: .leading, spacing: 4) {
                    Text(displayName)
                        .font(.subheadline)
                    Text("ID: \(displayName)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))
            .padding(.bottom, 8)
        }
        .padding(.horizontal, 14)
        .background(Color(.systemBackground))
        .alert("重命名", isPresented: Binding(
            get: { renamingChatId != nil },
            set: { if !$0 { renamingChatId = nil } }
        )) {
            TextField("聊天名称", text: $renameText)
            Button("取消", role: .cancel) {}
            Button("确认") {
                if let id = renamingChatId {
                    renameChat(id, to: renameText)
                }
            }
        }
    }

    private var displayName: String {
        let trimmed = loginName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "游客" : trimmed
    }

    private var sortedChats: [ChatSession] {
        chats.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned {
                return lhs.isPinned && !rhs.isPinned
            }
            let lhsDate = lhs.lastMessageAt ?? lhs.createdAt
            let rhsDate = rhs.lastMessageAt ?? rhs.createdAt
            return lhsDate > rhsDate
        }
    }

    private func togglePin(_ id: UUID) {
        if let index = chats.firstIndex(where: { $0.id == id }) {
            chats[index].isPinned.toggle()
        }
    }

    private func renameChat(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let index = chats.firstIndex(where: { $0.id == id }) {
            chats[index].title = trimmed
        }
        renamingChatId = nil
    }

    private func deleteChat(_ id: UUID) {
        chats.removeAll { $0.id == id }
        if chats.isEmpty {
            chats = [ChatSession.default]
        }
    }
}

private struct TianshiPickerSheet: View {
    @Binding var selectedTianshiId: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Text("选择天师")
                    .font(.headline)
                    .padding(.top, 8)
                HStack(spacing: 32) {
                    ForEach(Tianshi.allCases) { tianshi in
                        Button {
                            selectedTianshiId = tianshi.rawValue
                            dismiss()
                        } label: {
                            VStack(spacing: 10) {
                                Image(tianshi.avatarImageName)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: 80, height: 80)
                                    .clipShape(Circle())
                                    .overlay(
                                        Circle()
                                            .stroke(selectedTianshiId == tianshi.rawValue ? tianshi.theme.accent : Color.clear, lineWidth: 3)
                                    )
                                Text(tianshi.displayName)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.primary)
                            }
                            .frame(width: 100)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 20)
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .background(Color(.systemGroupedBackground))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }
}

private struct ProfileSelectionBar: View {
    let profile: UserProfile?
    let onSelect: () -> Void
    let onCreate: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if let profile {
                ProfileAvatarView(name: profile.name, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.name)
                        .font(.headline)
                    Text("已选择档案")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("切换") {
                    onSelect()
                }
                .buttonStyle(.bordered)
            } else {
                ProfileAvatarView(name: "档", size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("请选择档案")
                        .font(.headline)
                    Text("用于提供出生信息")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("创建档案") {
                    onCreate()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemBackground)))
    }
}

private struct InputBar: View {
    @Binding var text: String
    let focus: FocusState<Bool>.Binding
    let isSending: Bool
    let theme: ConsultTheme
    let onStop: () -> Void
    let onSend: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            TextField(
                "",
                text: $text,
                prompt: Text("输入你的问题...")
                    .foregroundColor(theme.primaryTextMuted)
            )
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .foregroundStyle(theme.primaryText)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(theme.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(theme.primaryTextBorder, lineWidth: 0.8)
                )
                .focused(focus)
                .submitLabel(.send)
                .onSubmit {
                    onSend()
                }

            if isSending {
                Button("停止") {
                    onStop()
                }
                .buttonStyle(.bordered)
            } else {
            Button(action: onSend) {
                Image(systemName: "paperplane.fill")
                    .foregroundStyle(Color.white)
                    .padding(10)
                    .background(Circle().fill(theme.accent))
                }
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.vertical, 10)
    }
}



private func hideKeyboard() {
    UIApplication.shared.sendAction(
        #selector(UIResponder.resignFirstResponder),
        to: nil,
        from: nil,
        for: nil
    )
}
