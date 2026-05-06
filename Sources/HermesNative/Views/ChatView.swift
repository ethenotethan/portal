import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// Main chat interface — skin-aware layout.
/// Delegates all visual rendering to the active ChatSkinProvider,
/// so switching skins changes everything: bubbles, streaming panel, background.
struct ChatView: View {
    @EnvironmentObject var chatViewModel: ChatViewModel
    @EnvironmentObject var settings: SettingsViewModel
    @EnvironmentObject var gatewayClientWrapper: GatewayClientWrapper
    @EnvironmentObject var personaManager: PersonaManager
    @EnvironmentObject var capabilitiesStore: HermesCapabilitiesStore
    @State private var showPersonaPicker = false
    @State private var showSkinPicker = false
    @State private var showGatewayDebug = false
    #if os(iOS)
    @State private var showSettings = false
    #endif
    @State private var avatarY: CGFloat = 0

    /// The active skin — change this to swap the entire visual personality
    @AppStorage("chatSkin") private var activeSkin: ChatSkin = .tui

    /// Current skin provider (recomputed when skin changes)
    private var skinProvider: ChatSkinProviding {
        activeSkin.makeProvider()
    }

    /// Reserve the avatar rail only for skins that render the floating avatar.
    /// TUI uses the full transcript width.
    private var messageLeadingPadding: CGFloat {
        activeSkin == .darkManga ? 72 : 16
    }

    /// Whether any bot content exists (for floating avatar visibility)
    private var hasBotContent: Bool {
        chatViewModel.messages.contains { $0.role == .assistant } || chatViewModel.isStreaming
    }

    private var chatBottomContentPadding: CGFloat {
        #if os(macOS)
        if !chatViewModel.isSessionReady { return 260 }
        if chatViewModel.pendingApproval != nil { return 190 }
        return 132
        #else
        8
        #endif
    }

    /// Current avatar expression based on streaming state
    private var currentAvatarExpression: CharacterExpression {
        if chatViewModel.isStreaming {
            switch chatViewModel.avatarState {
            case .thinking: .thinking
            case .speaking: .happy
            case .toolUse:  .thinking
            case .error:    .confused
            default:        .idle
            }
        } else {
            .idle
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Top toolbar row. On macOS this aligns with the sidebar-owned row
            // and the system traffic lights in the transparent titlebar.
            chatToolbar
                #if os(macOS)
                .frame(height: 40)
                #endif

            Divider()

            // Message list
            ScrollViewReader { proxy in
                ZStack(alignment: .bottom) {
                    #if os(macOS)
                    MacScrollViewIntrospection()
                        .frame(width: 0, height: 0)
                        .allowsHitTesting(false)
                    #endif

                    ScrollView {
                        GeometryReader { viewport in
                            Color.clear.preference(
                                key: ChatViewportHeightKey.self,
                                value: viewport.size.height
                            )
                        }
                        .frame(height: 0)

                        ZStack(alignment: .topLeading) {
                            LazyVStack(alignment: .leading, spacing: 2) {
                                ForEach(Array(chatViewModel.messages.enumerated()), id: \.element.id) { index, message in
                                let msgs = chatViewModel.messages
                                // Next message in same role group?
                                let nextIsSameRole = index < msgs.count - 1 &&
                                    msgs[index + 1].role == message.role
                                let isLastInGroup = !nextIsSameRole

                                // Timestamp: only on the last message in a consecutive same-role group
                                let showTimestamp = isLastInGroup

                                skinProvider.messageBubble(
                                    message: {
                                        var m = message
                                        m.showAvatar = false
                                        m.showTimestamp = showTimestamp
                                        return m
                                    }(),
                                    persona: personaManager.activePersona
                                )
                                .id(message.id)
                                // Report the latest assistant turn's bottom edge so the
                                // singleton avatar can travel through the conversation.
                            }

                            // Streaming panel — skin-provided
                            if chatViewModel.isStreaming {
                                skinProvider.streamingPanel(
                                    state: chatViewModel.avatarState,
                                    activeToolCalls: chatViewModel.activeToolCalls,
                                    personaName: personaManager.activePersona.name,
                                    accentColor: personaManager.activePersona.accentColor
                                )
                                .id("streaming-status")
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                            }
                        }
                        .padding(.leading, messageLeadingPadding)
                        .padding(.trailing, 16)
                        .padding(.top, 8)
                        .padding(.bottom, chatBottomContentPadding)
                        .frame(maxWidth: .infinity, alignment: .leading)

                        // Track the latest assistant turn once at the stack level.
                        // Per-row preferences can emit multiple values in the same frame
                        // while streaming/interrupting and trigger SwiftUI preference
                        // warnings/crashes.
                        latestAssistantTurnProbe

                        // ── Singleton traveling avatar ──
                        // Exactly one avatar element. Animated Y tracks the latest bot turn,
                        // matching Claude Code's bottom-left traveling assistant marker.
                        // The avatar is part of the Dark Manga presentation only; TUI skin
                        // should stay terminal-native and sprite-free.
                        if activeSkin == .darkManga && hasBotContent {
                            FloatingAvatarView(
                                expression: currentAvatarExpression,
                                persona: personaManager.activePersona
                            )
                            .offset(y: avatarY)
                            .padding(.leading, 16)
                        }
                    }
                    .coordinateSpace(name: "chatContent")
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                    #if os(macOS)
                    VStack(spacing: 8) {
                        if chatViewModel.pendingApproval != nil {
                            ApprovalBanner()
                                .environmentObject(chatViewModel)
                                .padding(.horizontal, 24)
                        }

                        if !chatViewModel.isSessionReady {
                            DebugLogPanel(wrapper: gatewayClientWrapper)
                                .padding(.horizontal, 24)
                        }

                        ChatInputBar()
                            .environmentObject(chatViewModel)
                    }
                    .padding(.bottom, 18)
                    .frame(maxWidth: 808, alignment: .bottom)
                    #endif
                }
                .background(activeSkin.background)
                #if os(macOS)
                .scrollIndicators(.hidden, axes: .horizontal)
                #else
                .scrollDismissesKeyboard(.interactively)
                #endif
                .onPreferenceChange(LatestBotTurnYKey.self) { y in
                    if let y = y {
                        Task { @MainActor in
                            withAnimation(.easeInOut(duration: 0.4)) {
                                avatarY = y
                            }
                        }
                    }
                }
                .onPreferenceChange(ChatViewportHeightKey.self) { height in
                    if !hasBotContent {
                        Task { @MainActor in
                            await Task.yield()
                            avatarY = max(0, height - 72)
                        }
                    }
                }
                .onChange(of: chatViewModel.messages.count) { _, _ in
                    scrollToBottom(proxy: proxy)
                }
                .onChange(of: chatViewModel.messages.last?.content) { _, _ in
                    scrollToBottom(proxy: proxy)
                }
                .onChange(of: chatViewModel.avatarState) { _, _ in
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo("streaming-status", anchor: .bottom)
                    }
                }
            }

            #if os(iOS)
            Divider()

            // Approval sheet (if pending)
            if chatViewModel.pendingApproval != nil {
                ApprovalBanner()
                    .environmentObject(chatViewModel)
            }

            // Input bar
            ChatInputBar()
                .environmentObject(chatViewModel)

            // Debug log (always visible while not session-ready)
            if !chatViewModel.isSessionReady {
                DebugLogPanel(wrapper: gatewayClientWrapper)
            }
            #endif
        }
        #if os(macOS)
        .frame(minWidth: 600, minHeight: 400)
        #endif
        #if os(iOS)
        .sheet(isPresented: $showSettings) {
            settingsSheet
        }
        .onTapGesture {
            dismissKeyboard()
        }
        #endif
        .sheet(isPresented: $showGatewayDebug) {
            GatewayDebugPanelView(client: gatewayClientWrapper.client)
                #if os(iOS)
                .presentationDetents([.large])
                #else
                .frame(minWidth: 560, minHeight: 620)
                #endif
        }
        .onAppear {
            chatViewModel.personaManager = personaManager
            // Do NOT auto-create session here — ContentView owns session lifecycle.
            // This .onAppear fires every time the view is recreated (session switch),
            // which was causing duplicate session creation.
        }
        #if os(macOS)
        .navigationTitle("")
        .toolbar(.hidden, for: .windowToolbar)
        .toolbarBackground(.hidden, for: .windowToolbar)
        .background(activeSkin.background.ignoresSafeArea())
        #else
        .navigationTitle(chatViewModel.sessionTitle)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    @ViewBuilder
    private var latestAssistantTurnProbe: some View {
        if hasBotContent {
            GeometryReader { geo in
                Color.clear.preference(
                    key: LatestBotTurnYKey.self,
                    value: max(0, geo.frame(in: .named("chatContent")).maxY - 60)
                )
            }
            .frame(height: 0)
        }
    }

    private var chatToolbar: some View {
        HStack {
            // Persona badge — tap to switch persona
            Button {
                showPersonaPicker = true
            } label: {
                HStack(spacing: 6) {
                    personaManager.activePersona.bubbleAvatar(size: 22)
                    Text(personaManager.usesAgentDefault ? "Agent Default" : personaManager.activePersona.name)
                        .font(.caption)
                        .fontWeight(.medium)
                        .lineLimit(1)

                    Circle()
                        .fill(chatViewModel.isStreaming ? Color.orange : Color.green)
                        .frame(width: 6, height: 6)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.quaternary, in: Capsule())
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showPersonaPicker) {
                PersonaPickerView()
                    .environmentObject(personaManager)
            }

            // Skin badge — tap to switch skin
            Button {
                showSkinPicker = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: activeSkin.icon)
                        .font(.caption2)
                    Text(activeSkin.displayName)
                        .font(.caption2)
                        .fontWeight(.medium)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.quaternary, in: Capsule())
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showSkinPicker) {
                SkinPickerView(activeSkin: $activeSkin)
            }

            // Model badge
            Text(chatViewModel.currentModel.isEmpty ? "No model" : chatViewModel.currentModel)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.quaternary.opacity(0.6), in: Capsule())

            Spacer()

            Button {
                showGatewayDebug = true
            } label: {
                Label("Debug Connection", systemImage: "wave.3.right.circle")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.accent)
            .accessibilityLabel("Debug Connection")

            #if os(iOS)
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            #endif

            if chatViewModel.isStreaming {
                Button {
                    Task { await chatViewModel.interrupt() }
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }

            if !chatViewModel.isSessionReady && chatViewModel.error == nil {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.small)
                    Text("Creating session…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let error = chatViewModel.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        #if os(macOS)
        .padding(.vertical, 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .background(activeSkin.background)
        #else
        .padding(.vertical, 6)
        #endif
    }

    #if os(iOS)
    private var settingsSheet: some View {
        SettingsView()
            .environmentObject(settings)
            .environmentObject(personaManager)
            .environmentObject(capabilitiesStore)
    }
    #endif

    private func scrollToBottom(proxy: ScrollViewProxy) {
        if let lastMsg = chatViewModel.messages.last {
            withAnimation(.easeOut(duration: 0.15)) {
                if chatViewModel.isStreaming {
                    proxy.scrollTo("streaming-status", anchor: .bottom)
                } else {
                    proxy.scrollTo(lastMsg.id, anchor: .bottom)
                }
            }
        }
    }
}

// MARK: - Floating Avatar (Singleton)
// Exactly one instance. Y position driven by LatestBotTurnYKey preference.
// Animated with easeInOut 400ms.

private struct FloatingAvatarView: View {
    let expression: CharacterExpression
    let persona: Persona

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Theme.surface.opacity(0.96))
                    .shadow(color: .black.opacity(0.22), radius: 8, x: 0, y: 4)

                LottieCharacterView(
                    expression: expression,
                    size: CGSize(width: 48, height: 48)
                )
                .frame(width: 48, height: 48)
            }
            .frame(width: 52, height: 52)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(persona.accentColor.opacity(0.55), lineWidth: 1)
            )

            Text(persona.name)
                .font(.system(size: 9, weight: .medium))
                .lineLimit(1)
                .frame(width: 58)
                .foregroundStyle(persona.accentColor.opacity(0.75))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Preference Key
// Tracks Y position of the latest bot turn within the scroll content coordinate space.
// Multiple assistant messages and the streaming panel report their Y;
// reduce takes the last non-nil value (bottom-most in view tree = latest turn).

private struct LatestBotTurnYKey: PreferenceKey {
    nonisolated(unsafe) static var defaultValue: CGFloat? = nil
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        if let next = nextValue() { value = next }
    }
}

private struct ChatViewportHeightKey: PreferenceKey {
    nonisolated(unsafe) static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - Skin Picker

struct SkinPickerView: View {
    @Binding var activeSkin: ChatSkin

    var body: some View {
        VStack(spacing: 12) {
            Text("Chat Style")
                .font(.headline)

            ForEach(ChatSkin.allCases) { skin in
                Button {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        activeSkin = skin
                    }
                } label: {
                    HStack {
                        Image(systemName: skin.icon)
                            .frame(width: 20)
                        Text(skin.displayName)
                            .fontWeight(activeSkin == skin ? .bold : .regular)
                        Spacer()
                        if activeSkin == skin {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.blue)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(activeSkin == skin ? Color.accentColor.opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .frame(width: 200)
    }
}

// MARK: - Input Bar

struct ChatInputBar: View {
    @EnvironmentObject var chatViewModel: ChatViewModel
    @EnvironmentObject var personaManager: PersonaManager
    @EnvironmentObject var capabilitiesStore: HermesCapabilitiesStore
    @FocusState private var isInputFocused: Bool

    #if os(iOS)
    @State private var selectedPhotosPickerItems: [PhotosPickerItem] = []
    #endif

    private var isSendDisabled: Bool {
        let textEmpty = chatViewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let noAttachments = chatViewModel.pendingAttachments.isEmpty
        return (textEmpty && noAttachments) || chatViewModel.isStreaming
    }

    var body: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            // Attachment preview strip above input
            if !chatViewModel.pendingAttachments.isEmpty {
                attachmentPreviewStrip
                    .padding(.horizontal, 14)
                    .padding(.top, 6)
            }
            HStack(alignment: .center, spacing: 10) {
                attachButton
                inputField
                sendButton
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(maxWidth: 760)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Theme.border.opacity(0.9), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.28), radius: 18, x: 0, y: 8)
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            // ── macOS focus-recovery ──
            // After the bridged NSTextField resigns first-responder (e.g. user
            // clicks the sidebar), SwiftUI's hit-test may still land on the
            // card but the AppKit field editor won't reactivate.  A lightweight
            // tap gesture on the card shell forces FocusState back to true so
            // the text field becomes editable again.  Using simultaneousGesture
            // ensures the TextField's own click→cursor placement still fires.
            .simultaneousGesture(
                TapGesture().onEnded { isInputFocused = true }
            )
            .background {
                MacScrollViewIntrospection()
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false)
            }
            .onDrop(of: [.image, .fileURL], isTargeted: nil) { providers in
                handleDrop(providers: providers)
            }
        }
        #else
        VStack(spacing: 0) {
            // Attachment preview strip above input
            if !chatViewModel.pendingAttachments.isEmpty {
                attachmentPreviewStrip
                    .padding(.horizontal, 14)
                    .padding(.top, 6)
            }
            HStack(alignment: .bottom, spacing: 10) {
                attachButton
                inputField
                sendButton
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.bar)
        }
        #endif
    }

    // MARK: - Attachment Preview Strip

    private var attachmentPreviewStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(chatViewModel.pendingAttachments) { attachment in
                    PendingAttachmentThumbnail(
                        attachment: attachment,
                        onRemove: {
                            chatViewModel.removeAttachment(attachment)
                        }
                    )
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Attach Button

    @ViewBuilder
    private var attachButton: some View {
        if capabilitiesStore.hasImageInput || capabilitiesStore.hasACPImagePrompts {
            #if os(macOS)
            Button {
                showMacFilePicker()
            } label: {
                Image(systemName: "photo.badge.plus")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.secondary)
                    .frame(width: 28, height: 28)
                    .background(Theme.surfaceHover, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Attach image")
            .help("Attach an image to your message")
            #else
            Menu {
                PhotosPicker(
                    "Photo Library",
                    selection: $selectedPhotosPickerItems,
                    maxSelectionCount: 5,
                    matching: .images
                )
                Button("Choose File") {
                    showiOSDocumentPicker()
                }
            } label: {
                Image(systemName: "photo.badge.plus")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.secondary)
                    .frame(width: 28, height: 28)
                    .background(Theme.surfaceHover, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Attach image")
            .onChange(of: selectedPhotosPickerItems) { _, newItems in
                handlePhotosPickerItems(newItems)
                selectedPhotosPickerItems = []
            }
            #endif
        }
    }

    // MARK: - Input Field

    private var inputField: some View {
        #if os(macOS)
        TextField("Message \(personaManager.activePersona.name)…", text: $chatViewModel.inputText)
            .accessibilityIdentifier("chatInput")
            .textFieldStyle(.plain)
            .font(.system(size: 15, weight: .regular))
            .frame(minHeight: 32, alignment: .center)
            .focused($isInputFocused)
            .onSubmit {
                Task { await chatViewModel.submitPrompt() }
            }
            .onPasteCommand(of: [.image, .fileURL]) { providers in
                handlePaste(providers: providers)
            }
        #else
        TextField("Message \(personaManager.activePersona.name)…", text: $chatViewModel.inputText, axis: .vertical)
            .accessibilityIdentifier("chatInput")
            .textFieldStyle(.plain)
            .font(.body)
            .lineLimit(1...8)
            .focused($isInputFocused)
            .onSubmit {
                Task { await chatViewModel.submitPrompt() }
            }
        #endif
    }

    // MARK: - Send Button

    private var sendButton: some View {
        Button {
            Task { await chatViewModel.submitPrompt() }
        } label: {
            Image(systemName: "arrow.up")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(isSendDisabled ? Theme.tertiary : Theme.primary)
                .frame(width: 30, height: 30)
                .background(isSendDisabled ? Theme.surfaceHover : Theme.accent, in: Circle())
        }
        .accessibilityLabel("Send")
        .accessibilityIdentifier("sendButton")
        .disabled(isSendDisabled)
        .buttonStyle(.plain)
    }

    // MARK: - macOS File Picker

    #if os(macOS)
    private func showMacFilePicker() {
        let panel = NSOpenPanel()
        panel.title = "Select Images"
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        guard panel.runModal() == .OK else { return }

        for url in panel.urls {
            let path = url.path
            chatViewModel.addAttachment(path: path)
        }
    }
    #endif

    // MARK: - iOS Document Picker

    #if os(iOS)
    @MainActor
    private func showiOSDocumentPicker() {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootVC = scene.windows.first?.rootViewController else { return }

        let docPicker = UIDocumentPickerViewController(forOpeningContentTypes: [.image], asCopy: true)
        docPicker.allowsMultipleSelection = true
        docPicker.delegate = DocumentPickerDelegate.shared

        DocumentPickerDelegate.shared.onSelect = { urls in
            for url in urls {
                let cachedPath = Self.copyToCache(url: url)
                chatViewModel.addAttachment(path: cachedPath)
            }
        }

        var topVC = rootVC
        while let presented = topVC.presentedViewController {
            topVC = presented
        }
        topVC.present(docPicker, animated: true)
    }
    #endif

    // MARK: - iOS Photos Picker Handler

    #if os(iOS)
    private func handlePhotosPickerItems(_ items: [PhotosPickerItem]) {
        for item in items {
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self) else { return }
                let cachedPath = Self.saveImageDataToCache(data: data, ext: "png")
                await MainActor.run {
                    chatViewModel.addAttachment(path: cachedPath)
                }
            }
        }
    }
    #endif

    // MARK: - Paste Handler (macOS)

    #if os(macOS)
    private func handlePaste(providers: [NSItemProvider]) {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.image.identifier, options: nil) { item, _ in
                    if let url = item as? URL {
                        let cachedPath = Self.copyToCache(url: url)
                        Task { @MainActor in
                            chatViewModel.addAttachment(path: cachedPath)
                        }
                    } else if let data = item as? Data {
                        let cachedPath = Self.saveImageDataToCache(data: data, ext: "png")
                        Task { @MainActor in
                            chatViewModel.addAttachment(path: cachedPath)
                        }
                    }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    if let url = item as? URL {
                        let ext = url.pathExtension.lowercased()
                        let imageExts = ["png", "jpg", "jpeg", "gif", "webp", "svg", "bmp", "tiff", "heic", "heif"]
                        guard imageExts.contains(ext) else { return }
                        let cachedPath = Self.copyToCache(url: url)
                        Task { @MainActor in
                            chatViewModel.addAttachment(path: cachedPath)
                        }
                    }
                }
            }
        }
    }
    #endif

    // MARK: - Drop Handler

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                handled = true
                provider.loadItem(forTypeIdentifier: UTType.image.identifier, options: nil) { item, _ in
                    if let url = item as? URL {
                        let cachedPath = Self.copyToCache(url: url)
                        Task { @MainActor in
                            chatViewModel.addAttachment(path: cachedPath)
                        }
                    } else if let data = item as? Data {
                        let cachedPath = Self.saveImageDataToCache(data: data, ext: "png")
                        Task { @MainActor in
                            chatViewModel.addAttachment(path: cachedPath)
                        }
                    }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    if let url = item as? URL {
                        let ext = url.pathExtension.lowercased()
                        let imageExts = ["png", "jpg", "jpeg", "gif", "webp", "svg", "bmp", "tiff", "heic", "heif"]
                        guard imageExts.contains(ext) else { return }
                        let cachedPath = Self.copyToCache(url: url)
                        Task { @MainActor in
                            chatViewModel.addAttachment(path: cachedPath)
                        }
                    }
                }
            }
        }
        return handled
    }

    // MARK: - Cache Helpers

    /// Directory for cached user-sent images.
    private static var hermesImagesDir: String {
        let home = NSHomeDirectory()
        let dir = "\(home)/.hermes/images"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Copy a file URL into the hermes images cache, returning the cached path.
    private static func copyToCache(url: URL) -> String {
        let dir = hermesImagesDir
        let ext = url.pathExtension.isEmpty ? "png" : url.pathExtension
        let fileName = "\(UUID().uuidString).\(ext)"
        let dest = "\(dir)/\(fileName)"
        try? FileManager.default.copyItem(atPath: url.path, toPath: dest)
        // If copy fails (e.g. same file), use the original path
        if FileManager.default.fileExists(atPath: dest) {
            return dest
        }
        return url.path
    }

    /// Save raw image data into the hermes images cache, returning the cached path.
    private static func saveImageDataToCache(data: Data, ext: String) -> String {
        let dir = hermesImagesDir
        let fileName = "\(UUID().uuidString).\(ext)"
        let dest = "\(dir)/\(fileName)"
        try? data.write(to: URL(fileURLWithPath: dest))
        return dest
    }
}

// MARK: - Pending Attachment Thumbnail

private struct PendingAttachmentThumbnail: View {
    let attachment: MediaAttachment
    let onRemove: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // Thumbnail
            ThumbnailImageView(data: attachment.thumbnailData, fallbackIcon: attachment.category.icon)
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Theme.border, lineWidth: 0.5)
                )

            // Remove button
            Button {
                onRemove()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.primary)
                    .background(Circle().fill(Theme.surface).opacity(0.8))
            }
            .buttonStyle(.plain)
            .offset(x: 6, y: -6)
        }
    }
}

// MARK: - iOS Document Picker Delegate

#if os(iOS)
final class DocumentPickerDelegate: NSObject, UIDocumentPickerDelegate {
    static let shared = DocumentPickerDelegate()
    var onSelect: ([URL]) -> Void = { _ in }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        onSelect(urls)
    }
}
#endif

// MARK: - Debug Log Panel

struct DebugLogPanel: View {
    @ObservedObject var wrapper: GatewayClientWrapper

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(wrapper.log) { entry in
                        Text(entry.text)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(entry.isError ? .red : .secondary)
                            .id(entry.id)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 150)
            .padding(8)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .onChange(of: wrapper.log.count) { _, _ in
                if let last = wrapper.log.last {
                    proxy.scrollTo(last.id)
                }
            }
        }
    }
}

// MARK: - Approval Banner

struct ApprovalBanner: View {
    @EnvironmentObject var chatViewModel: ChatViewModel

    var body: some View {
        if let approval = chatViewModel.pendingApproval {
            HStack {
                Image(systemName: "exclamationmark.shield.fill")
                    .foregroundStyle(.yellow)

                VStack(alignment: .leading) {
                    Text("Approval Required")
                        .font(.caption)
                        .fontWeight(.semibold)
                    Text(approval.command.truncated(to: 100))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer()

                Button("Deny") {
                    Task { await chatViewModel.respondApproval(choice: "deny") }
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .controlSize(.small)

                Button("Approve") {
                    Task { await chatViewModel.respondApproval(choice: "approve") }
                }
                .buttonStyle(.bordered)
                .tint(.green)
                .controlSize(.small)
            }
            .padding(10)
            .background(.yellow.opacity(0.1))
        }
    }
}

// MARK: - Keyboard Dismissal (iOS)

#if os(iOS)
private func dismissKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}
#endif
