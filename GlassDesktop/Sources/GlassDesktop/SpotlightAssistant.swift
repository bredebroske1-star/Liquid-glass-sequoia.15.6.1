import AppKit
import Carbon.HIToolbox
import GlassDesktopCore
import ImageIO
import Security
import SwiftUI
import UniformTypeIdentifiers
import Vision

@MainActor
final class SpotlightPanelController {
    static let shared = SpotlightPanelController()

    private var panel: NSPanel?

    func show() {
        let panel = makePanelIfNeeded()
        if let screen = NSScreen.main {
            panel.setFrame(
                NSRect(x: screen.frame.midX - 360, y: screen.frame.midY - 280, width: 720, height: 560),
                display: true
            )
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func toggle() {
        guard let panel, panel.isVisible else {
            show()
            return
        }
        dismiss()
    }

    func dismiss() {
        guard let panel else { return }
        panel.orderOut(nil)
    }

    private func makePanelIfNeeded() -> NSPanel {
        if let panel { return panel }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
            styleMask: [.titled, .fullSizeContentView, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Glass Search"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: SpotlightAssistantView())
        self.panel = panel
        return panel
    }

    private init() {}
}

@MainActor
final class GlobalShortcutManager: ObservableObject {
    static let shared = GlobalShortcutManager()

    @Published private(set) var status = "Starting shortcut…"

    private var eventHandler: EventHandlerRef?
    private var hotKeys: [EventHotKeyRef] = []

    func register() throws {
        guard eventHandler == nil, hotKeys.isEmpty else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            glassSearchHotKeyHandler,
            1,
            &eventType,
            nil,
            &eventHandler
        )
        guard installStatus == noErr else {
            throw ShortcutError(statuses: [installStatus])
        }

        let shortcuts: [(UInt32, UInt32)] = [
            (UInt32(cmdKey | shiftKey), 1),
            (UInt32(cmdKey | optionKey), 2)
        ]
        var failures: [OSStatus] = []

        for (modifiers, identifier) in shortcuts {
            var hotKey: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: OSType(0x474C4153), id: identifier)
            let status = RegisterEventHotKey(
                UInt32(kVK_Space),
                modifiers,
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &hotKey
            )
            if status == noErr, let hotKey {
                hotKeys.append(hotKey)
            } else {
                failures.append(status)
            }
        }

        if hotKeys.isEmpty {
            if let eventHandler {
                RemoveEventHandler(eventHandler)
            }
            eventHandler = nil
            status = "Unavailable: macOS or another app is using both shortcuts."
            throw ShortcutError(statuses: failures)
        }

        status = hotKeys.count == shortcuts.count
            ? "Ready: ⌘⇧Space or ⌘⌥Space"
            : "Ready: one shortcut registered; the other is already in use."
    }

    func setError(_ message: String) {
        status = "Unavailable: \(message)"
    }

    private init() {}
}

private struct ShortcutError: LocalizedError {
    let statuses: [OSStatus]

    var errorDescription: String {
        "The global shortcuts could not be registered (status \(statuses.map { String($0) }.joined(separator: ", ")))."
    }
}

private func glassSearchHotKeyHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    Task { @MainActor in
        SpotlightPanelController.shared.toggle()
    }
    return noErr
}

private enum SearchResultKind: Equatable, Sendable {
    case application
    case file

    var symbol: String {
        switch self {
        case .application: "app"
        case .file: "doc"
        }
    }

    var label: String {
        switch self {
        case .application: "App"
        case .file: "File"
        }
    }
}

private struct SearchResult: Identifiable, Sendable {
    let url: URL
    let title: String
    let kind: SearchResultKind

    var id: String { url.path }
    var detail: String { url.deletingLastPathComponent().path }
}

private struct WebBrowser: Identifiable {
    let id: String
    let name: String
    let appURL: URL
}

@MainActor
private enum WebSearch {
    static let supportedBrowsers: [String: String] = [
        "com.apple.Safari": "Safari",
        "com.google.Chrome": "Google Chrome",
        "com.google.Chrome.beta": "Google Chrome Beta",
        "com.google.Chrome.canary": "Google Chrome Canary",
        "com.operasoftware.Opera": "Opera",
        "com.operasoftware.OperaNext": "Opera Beta",
        "org.mozilla.firefox": "Firefox",
        "org.mozilla.firefoxdeveloperedition": "Firefox Developer Edition",
        "org.mozilla.nightly": "Firefox Nightly",
        "com.brave.Browser": "Brave",
        "com.microsoft.edgemac": "Microsoft Edge",
        "com.vivaldi.Vivaldi": "Vivaldi"
    ]

    static let installedBrowsers = discoverBrowsers()

    private static func discoverBrowsers() -> [WebBrowser] {
        guard let sampleURL = URL(string: "https://www.google.com") else { return [] }
        let urls = NSWorkspace.shared.urlsForApplications(toOpen: sampleURL)
        var seen = Set<String>()

        return urls.compactMap { appURL in
            guard
                let bundle = Bundle(url: appURL),
                let identifier = bundle.bundleIdentifier,
                let name = supportedBrowsers[identifier],
                seen.insert(identifier).inserted
            else {
                return nil
            }
            return WebBrowser(id: identifier, name: name, appURL: appURL)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func searchURL(for query: String) -> URL? {
        var components = URLComponents(string: "https://www.google.com/search")
        components?.queryItems = [URLQueryItem(name: "q", value: query)]
        return components?.url
    }
}

private struct IndexedApplication: Sendable {
    let url: URL
    let name: String
    let foldedName: String
}

private enum ApplicationSearchIndex {
    private static let applications = loadApplications()

    static func matching(_ query: String) -> [SearchResult] {
        let foldedQuery = query.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        return applications
            .filter { $0.foldedName.contains(foldedQuery) }
            .prefix(10)
            .map { SearchResult(url: $0.url, title: $0.name, kind: .application) }
    }

    private static func loadApplications() -> [IndexedApplication] {
        let fileManager = FileManager.default
        let directories = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/System/Applications"),
            URL(fileURLWithPath: "/System/Applications/Utilities"),
            fileManager.homeDirectoryForCurrentUser.appending(path: "Applications")
        ]
        let options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]
        var seen = Set<String>()

        return directories.flatMap { directory -> [IndexedApplication] in
            guard let children = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isApplicationKey],
                options: options
            ) else {
                return []
            }

            return children.compactMap { url in
                guard seen.insert(url.path).inserted,
                      (try? url.resourceValues(forKeys: [.isApplicationKey]).isApplication) == true
                else {
                    return nil
                }

                let name = (Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? url.deletingPathExtension().lastPathComponent
                let foldedName = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
                return IndexedApplication(url: url, name: name, foldedName: foldedName)
            }
        }
    }
}

@MainActor
private final class SpotlightSearchModel: ObservableObject {
    @Published private(set) var results: [SearchResult] = []
    @Published private(set) var isSearching = false
    @Published private(set) var errorMessage: String?

    private var searchTask: Task<Void, Never>?
    private var processHandle: SearchProcessHandle?

    func search(_ rawQuery: String) {
        searchTask?.cancel()
        processHandle?.cancel()
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            results = []
            errorMessage = nil
            isSearching = false
            return
        }

        isSearching = true
        results = []
        errorMessage = nil
        let processHandle = SearchProcessHandle()
        self.processHandle = processHandle
        searchTask = Task {
            do {
                try await Task.sleep(nanoseconds: 350_000_000)
                let matches = try await Task.detached(priority: .utility) {
                    try Self.performSearch(query, processHandle: processHandle)
                }.value
                guard !Task.isCancelled else { return }
                results = matches
                isSearching = false
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
                results = []
                isSearching = false
            }
        }
    }

    nonisolated private static func performSearch(
        _ query: String,
        processHandle: SearchProcessHandle
    ) throws -> [SearchResult] {
        let appResults = ApplicationSearchIndex.matching(query)
        let fileURLs = try fileURLsFromSpotlight(matching: query, processHandle: processHandle)
        var seen = Set(appResults.map(\.id))
        let fileResults = fileURLs.compactMap { url -> SearchResult? in
            guard seen.insert(url.path).inserted else { return nil }
            return SearchResult(url: url, title: url.lastPathComponent, kind: .file)
        }
        return Array((appResults + fileResults).prefix(10))
    }

    nonisolated private static func fileURLsFromSpotlight(
        matching query: String,
        processHandle: SearchProcessHandle
    ) throws -> [URL] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        process.arguments = [
            "-onlyin",
            FileManager.default.homeDirectoryForCurrentUser.path,
            NSPredicate(format: "kMDItemDisplayName CONTAINS[cd] %@", query).predicateFormat
        ]

        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        guard processHandle.attach(process) else {
            process.terminate()
            throw CancellationError()
        }
        defer { processHandle.detach(process) }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        if processHandle.isCancelled {
            throw CancellationError()
        }
        guard process.terminationStatus == 0 else {
            throw SearchError.spotlight("macOS Spotlight search exited with status \(process.terminationStatus).")
        }

        return String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .prefix(20)
            .map { URL(fileURLWithPath: String($0)) }
            .filter { $0.pathExtension.lowercased() != "app" }
    }
}

private final class SearchProcessHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func attach(_ process: Process) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return false }
        self.process = process
        return true
    }

    func detach(_ process: Process) {
        lock.lock()
        defer { lock.unlock() }
        if self.process === process {
            self.process = nil
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let process = self.process
        lock.unlock()
        if process?.isRunning == true {
            process?.terminate()
        }
    }
}

private enum SearchError: LocalizedError {
    case spotlight(String)

    var errorDescription: String? {
        switch self {
        case .spotlight(let message): "Spotlight search failed: \(message)"
        }
    }
}

private struct ChatMessage: Identifiable {
    enum Role: String {
        case user
        case assistant
    }

    let id = UUID()
    let role: Role
    var text: String
    var images: [ChatImage] = []
}

private struct ChatImage: Identifiable, Sendable {
    let id = UUID()
    let name: String
    let data: Data

    var preview: NSImage? { NSImage(data: data) }
}

private enum AssistantProvider: String, CaseIterable, Identifiable {
    case ollamaCloud
    case ollamaLocal

    var id: String { rawValue }
    var title: String {
        switch self {
        case .ollamaCloud: "Ollama Cloud"
        case .ollamaLocal: "On this Mac"
        }
    }
}

private enum AssistantKeychain {
    private static let service = "com.glassdesktop.app"
    private static let account = "ollama-cloud-api-key"

    static func loadAPIKey() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let key = String(data: data, encoding: .utf8)
        else {
            throw KeychainError(operation: "read", status: status)
        }
        return key
    }

    static func saveAPIKey(_ key: String) throws {
        let data = Data(key.utf8)
        let status = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else {
            throw KeychainError(operation: "update", status: status)
        }

        var query = baseQuery
        query[kSecValueData as String] = data
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError(operation: "save", status: addStatus)
        }
    }

    static func deleteAPIKey() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(operation: "remove", status: status)
        }
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private struct KeychainError: LocalizedError {
        let operation: String
        let status: OSStatus

        var errorDescription: String? {
            let detail = SecCopyErrorMessageString(status, nil) as String?
                ?? "Security framework error \(status)"
            return "Could not \(operation) the Ollama Cloud API key in Keychain: \(detail)"
        }
    }
}

private enum HomeworkImageLoader {
    static func load(urls: [URL]) async throws -> [ChatImage] {
        try await Task.detached(priority: .userInitiated) {
            try urls.map { url in
                let didAccess = url.startAccessingSecurityScopedResource()
                defer {
                    if didAccess { url.stopAccessingSecurityScopedResource() }
                }
                let data = try compressedJPEG(at: url)
                return ChatImage(name: url.lastPathComponent, data: data)
            }
        }.value
    }

    private static func compressedJPEG(at url: URL) throws -> Data {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw AssistantError.message("Could not read \(url.lastPathComponent) as an image.")
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1024,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw AssistantError.message("Could not decode \(url.lastPathComponent). Try a JPEG, PNG, or HEIC photo.")
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw AssistantError.message("Could not prepare the selected photo for the local AI model.")
        }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: 0.68] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            throw AssistantError.message("Could not compress \(url.lastPathComponent).")
        }
        return output as Data
    }

    static func recognizeText(in images: [ChatImage]) async throws -> String {
        let task = Task.detached(priority: .userInitiated) { () throws -> String in
            try images.map { image -> String in
                let request = VNRecognizeTextRequest()
                let handler = VNImageRequestHandler(data: image.data)
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = false
                request.minimumTextHeight = 0.01
                do {
                    try handler.perform([request])
                } catch {
                    throw AssistantError.message(
                        "Could not read text from \(image.name). Try enabling full photo vision."
                    )
                }
                return (request.results ?? [])
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: "\n")
            }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")
        }
        return try await task.value
    }
}

@MainActor
private final class AssistantModel: ObservableObject {
    @Published var provider: AssistantProvider = AssistantProvider(
        rawValue: UserDefaults.standard.string(forKey: "assistantProvider") ?? ""
    ) ?? .ollamaCloud {
        didSet { UserDefaults.standard.set(provider.rawValue, forKey: "assistantProvider") }
    }
    @Published var cloudModelName = UserDefaults.standard.string(forKey: "ollamaCloudModel") ?? "gemma4:31b" {
        didSet { UserDefaults.standard.set(cloudModelName, forKey: "ollamaCloudModel") }
    }
    @Published var modelName = UserDefaults.standard.string(forKey: "ollamaLocalModel") ?? "qwen2.5:3b" {
        didSet { UserDefaults.standard.set(modelName, forKey: "ollamaLocalModel") }
    }
    @Published var cloudAPIKeyInput = ""
    @Published private(set) var hasCloudAPIKey = false
    @Published private(set) var cloudKeyStatus: String?
    @Published private(set) var messages = [
        ChatMessage(role: .assistant, text: "Hi! Ask me something, or attach a homework photo.")
    ]
    @Published private(set) var isSending = false
    @Published private(set) var isPreparingImages = false
    @Published private(set) var pendingImages: [ChatImage] = []
    @Published var errorMessage: String?
    @Published var useFullPhotoVision = false
    @Published private(set) var progressMessage = "Thinking…"

    init() {
        do {
            hasCloudAPIKey = try AssistantKeychain.loadAPIKey() != nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func saveCloudAPIKey() {
        let key = cloudAPIKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            errorMessage = "Enter an Ollama Cloud API key before saving."
            return
        }
        do {
            try AssistantKeychain.saveAPIKey(key)
            cloudAPIKeyInput = ""
            hasCloudAPIKey = true
            cloudKeyStatus = "API key saved in macOS Keychain."
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func removeCloudAPIKey() {
        do {
            try AssistantKeychain.deleteAPIKey()
            hasCloudAPIKey = false
            cloudAPIKeyInput = ""
            cloudKeyStatus = "API key removed from macOS Keychain."
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func openOllamaAPIKeySettings() {
        guard let url = URL(string: "https://ollama.com/settings/keys") else { return }
        NSWorkspace.shared.open(url)
    }

    func addPhotos(from urls: [URL]) {
        guard !isSending, !isPreparingImages else { return }
        let remainingSlots = 3 - pendingImages.count
        guard remainingSlots > 0 else {
            errorMessage = "You can attach up to 3 photos per message."
            return
        }

        isPreparingImages = true
        errorMessage = nil
        Task {
            defer { isPreparingImages = false }
            do {
                let loaded = try await HomeworkImageLoader.load(urls: Array(urls.prefix(remainingSlots)))
                pendingImages.append(contentsOf: loaded)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func removePhoto(_ image: ChatImage) {
        pendingImages.removeAll { $0.id == image.id }
    }

    func send(_ prompt: String) {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!text.isEmpty || !pendingImages.isEmpty), !isSending, !isPreparingImages else { return }

        let imageAttachments = pendingImages
        let userMessage = ChatMessage(role: .user, text: text, images: imageAttachments)
        messages.append(userMessage)
        messages.append(ChatMessage(role: .assistant, text: ""))
        pendingImages = []
        errorMessage = nil
        isSending = true

        Task {
            defer { isSending = false }
            do {
                var recognizedText = ""
                if !imageAttachments.isEmpty && !useFullPhotoVision {
                    progressMessage = "Reading photo on this Mac…"
                    recognizedText = try await HomeworkImageLoader.recognizeText(in: imageAttachments)
                }
                let useVisionModel = !imageAttachments.isEmpty
                    && (useFullPhotoVision || recognizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if provider == .ollamaCloud {
                    progressMessage = useVisionModel
                        ? "Analyzing photo with Ollama Cloud…"
                        : "Thinking with Ollama Cloud…"
                } else {
                    progressMessage = useVisionModel ? "Analyzing photo locally…" : "Thinking locally…"
                }
                _ = try await askOllama(
                    recognizedText: recognizedText,
                    useVisionModel: useVisionModel
                ) { [weak self] text in
                    guard let self, let lastIndex = self.messages.indices.last,
                          self.messages[lastIndex].role == .assistant
                    else { return }
                    self.messages[lastIndex].text = text
                }
            } catch {
                if messages.last?.role == .assistant, messages.last?.text.isEmpty == true {
                    messages.removeLast()
                }
                errorMessage = error.localizedDescription
            }
        }
    }

    private func askOllama(
        recognizedText: String,
        useVisionModel: Bool,
        onText: @MainActor (String) -> Void
    ) async throws -> String {
        let isCloud = provider == .ollamaCloud
        let model = isCloud
            ? cloudModelName.trimmingCharacters(in: .whitespacesAndNewlines)
            : (useVisionModel ? "qwen2.5vl:3b" : modelName.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !model.isEmpty else {
            throw AssistantError.message("Enter the name of an Ollama model.")
        }
        let apiKey: String?
        if isCloud {
            apiKey = try AssistantKeychain.loadAPIKey()
            guard let apiKey, !apiKey.isEmpty else {
                throw AssistantError.message("Add your Ollama Cloud API key above before sending a request.")
            }
        } else {
            apiKey = nil
        }
        let recentMessages = Array(messages.suffix(8))
        let requestBody = OllamaChatRequest(
            model: model,
            messages: [
                OllamaMessage(
                    role: "system",
                    content: """
                    You are a patient math tutor. Help the student learn, not just copy an answer. For homework, identify what is asked, show numbered steps, explain why each step is valid, and verify the result by substitution or an independent check when possible. Use readable equations, define variables, and state units. For arithmetic, calculate carefully and check the result. Text recognized from a photo may contain OCR mistakes: if a symbol or number is ambiguous, explain the uncertainty and ask the student to confirm it rather than guessing. Keep explanations focused and clear. You cannot control this Mac or search its files.
                    """
                )
            ] + recentMessages.enumerated().map { index, message in
                OllamaMessage(
                    role: message.role.rawValue,
                    content: index == recentMessages.count - 1 && !recognizedText.isEmpty
                        ? "\(message.text)\n\nText recognized from the attached photo on this Mac (verify any unclear symbols with the student):\n\(recognizedText)"
                        : message.text,
                    images: useVisionModel && index == recentMessages.count - 1 && !message.images.isEmpty
                        ? message.images.map { $0.data.base64EncodedString() }
                        : nil
                )
            },
            options: isCloud ? nil : OllamaOptions(contextSize: 2048, maxTokens: 384),
            keepAlive: isCloud ? nil : "2m",
            stream: true
        )

        let endpointString = isCloud
            ? "https://ollama.com/api/chat"
            : "http://127.0.0.1:11434/api/chat"
        guard let endpoint = URL(string: endpointString) else {
            throw AssistantError.message("The Ollama endpoint is invalid.")
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = isCloud ? 180 : 240
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(requestBody)

        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await URLSession.shared.bytes(for: request)
        } catch {
            let message = isCloud
                ? "Could not reach Ollama Cloud. Check your internet connection and try again."
                : "Could not reach Ollama at 127.0.0.1:11434. Start Ollama, then try again."
            throw AssistantError.message(message)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AssistantError.message("Ollama returned an invalid response.")
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            var responseBody = ""
            for try await line in bytes.lines {
                responseBody += line
            }
            let message = (try? JSONDecoder().decode(OllamaErrorResponse.self, from: Data(responseBody.utf8)).error)
                ?? "Ollama returned HTTP \(httpResponse.statusCode)."
            if isCloud && (httpResponse.statusCode == 401 || httpResponse.statusCode == 403) {
                throw AssistantError.message("Ollama Cloud rejected the API key. Check it or create a replacement key.")
            }
            if isCloud && httpResponse.statusCode == 429 {
                throw AssistantError.message("Ollama Cloud request limit reached. Check your Ollama usage and plan.")
            }
            if message.localizedCaseInsensitiveContains("model")
                && (message.localizedCaseInsensitiveContains("not found") || message.localizedCaseInsensitiveContains("pull")) {
                if isCloud {
                    throw AssistantError.message("Ollama Cloud could not use “\(requestBody.model)”. Check the cloud model name.")
                }
                throw AssistantError.message("The model “\(requestBody.model)” is not installed. Run: ollama pull \(requestBody.model)")
            }
            throw AssistantError.message(message)
        }

        var answer = ""
        for try await line in bytes.lines {
            guard !line.isEmpty else { continue }
            let chunk = try JSONDecoder().decode(OllamaChatResponse.self, from: Data(line.utf8))
            if let error = chunk.error {
                throw AssistantError.message(error)
            }
            if let content = chunk.message?.content, !content.isEmpty {
                answer += content
                onText(answer)
            }
            if chunk.done == true { break }
        }
        guard !answer.isEmpty else {
            throw AssistantError.message("Ollama returned an empty response.")
        }
        return answer
    }
}

private struct OllamaChatRequest: Encodable {
    let model: String
    let messages: [OllamaMessage]
    let options: OllamaOptions?
    let keepAlive: String?
    let stream: Bool

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case options
        case keepAlive = "keep_alive"
        case stream
    }
}

private struct OllamaOptions: Encodable {
    let contextSize: Int
    let maxTokens: Int

    enum CodingKeys: String, CodingKey {
        case contextSize = "num_ctx"
        case maxTokens = "num_predict"
    }
}

private struct OllamaMessage: Codable {
    let role: String
    let content: String
    var images: [String]? = nil
}

private struct OllamaChatResponse: Decodable {
    let message: OllamaMessage?
    let done: Bool?
    let error: String?
}

private struct OllamaErrorResponse: Decodable {
    let error: String?
}

private enum AssistantError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let message): message
        }
    }
}

private struct LibraryApplication: Identifiable, Sendable {
    let url: URL
    let name: String

    var id: String { url.path }
}

@MainActor
private final class AppLibraryModel: ObservableObject {
    @Published private(set) var applications: [LibraryApplication] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    func loadIfNeeded() {
        guard applications.isEmpty, !isLoading, errorMessage == nil else { return }
        isLoading = true
        Task {
            do {
                applications = try await Task.detached(priority: .utility) {
                    try Self.findApplications()
                }.value
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }

    nonisolated private static func findApplications() throws -> [LibraryApplication] {
        let fileManager = FileManager.default
        let directories = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/System/Applications"),
            fileManager.homeDirectoryForCurrentUser.appending(path: "Applications")
        ]
        var seen = Set<String>()
        var applications: [LibraryApplication] = []

        for directory in directories where fileManager.fileExists(atPath: directory.path) {
            let children = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isApplicationKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )
            for url in children where url.pathExtension.lowercased() == "app" {
                guard seen.insert(url.path).inserted else { continue }
                let name = (Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? url.deletingPathExtension().lastPathComponent
                applications.append(LibraryApplication(url: url, name: name))
            }
        }

        return applications.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

private struct SpotlightAssistantView: View {
    @StateObject private var searchModel = SpotlightSearchModel()
    @StateObject private var assistantModel = AssistantModel()
    @StateObject private var appLibraryModel = AppLibraryModel()
    @State private var query = ""
    @State private var prompt = ""
    @State private var webLaunchError: String?
    @State private var calculationCopied = false
    @State private var selectedMode = AssistantMode.search
    @FocusState private var isQueryFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchHeader
            Divider().overlay(.white.opacity(0.1))
            if selectedMode == .search {
                searchResults
            } else if selectedMode == .apps {
                appLibrary
            } else {
                assistantChat
            }
            footer
        }
        .background(.ultraThinMaterial)
        .preferredColorScheme(.dark)
        .onExitCommand {
            SpotlightPanelController.shared.dismiss()
        }
        .onAppear {
            isQueryFocused = true
            appLibraryModel.loadIfNeeded()
        }
        .onChange(of: query) { value in
            calculationCopied = false
            if selectedMode == .search { searchModel.search(value) }
        }
        .onChange(of: selectedMode) { mode in
            if mode == .search { searchModel.search(query) }
        }
    }

    private var searchHeader: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: selectedMode.symbol)
                    .font(.system(size: 21, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
                TextField(searchPlaceholder, text: $query)
                    .font(.system(size: 21, weight: .regular))
                    .textFieldStyle(.plain)
                    .focused($isQueryFocused)
                    .onSubmit {
                        if selectedMode == .assistant {
                            submitPrompt()
                        } else if selectedMode == .apps {
                            openFirstMatchingApp()
                        } else if quickCalculation != nil {
                            copyCalculation()
                        } else if let firstResult = searchModel.results.first {
                            open(firstResult)
                        } else {
                            searchWeb(in: WebSearch.installedBrowsers.first)
                        }
                    }
                if !query.isEmpty {
                    Button {
                        query = ""
                        prompt = ""
                        appLibraryModel.loadIfNeeded()
                        isQueryFocused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 36)

            HStack(spacing: 8) {
                ForEach(AssistantMode.allCases) { mode in
                    Button {
                        selectedMode = mode
                        isQueryFocused = true
                        if mode == .apps { appLibraryModel.loadIfNeeded() }
                    } label: {
                        Label(mode.title, systemImage: mode.symbol)
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 13)
                            .padding(.vertical, 8)
                            .background {
                                Capsule()
                                    .fill(selectedMode == mode ? .white.opacity(0.18) : .clear)
                            }
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Text("⌘ ⇧ Space")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }
    }

    private var searchPlaceholder: String {
        switch selectedMode {
        case .search: "Search apps, files, or the web"
        case .apps: "Filter your app library"
        case .assistant: "Ask anything…"
        }
    }

    private var filteredApplications: [LibraryApplication] {
        let filter = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !filter.isEmpty else { return appLibraryModel.applications }
        return appLibraryModel.applications.filter {
            $0.name.localizedCaseInsensitiveContains(filter)
        }
    }

    private var appLibrary: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("APP LIBRARY")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(appLibraryModel.isLoading
                             ? "Finding your apps…"
                             : "\(filteredApplications.count) apps")
                            .font(.title2.weight(.medium))
                    }
                    Spacer()
                    Image(systemName: "square.grid.2x2.fill")
                        .font(.title2)
                        .foregroundStyle(.white.opacity(0.7))
                }
                .padding(.horizontal, 4)

                if let error = appLibraryModel.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                } else if appLibraryModel.isLoading {
                    ProgressView("Loading app library…")
                        .frame(maxWidth: .infinity, minHeight: 180)
                } else if filteredApplications.isEmpty {
                    emptyState(
                        appLibraryModel.applications.isEmpty ? "No apps found" : "No matching apps",
                        symbol: "square.grid.2x2",
                        detail: appLibraryModel.applications.isEmpty
                            ? "Apps in Applications folders appear here."
                            : "Try a different app name."
                    )
                    .frame(maxWidth: .infinity, minHeight: 180)
                } else {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 96), spacing: 12)],
                        spacing: 14
                    ) {
                        ForEach(filteredApplications) { application in
                            Button {
                                NSWorkspace.shared.open(application.url)
                                SpotlightPanelController.shared.dismiss()
                            } label: {
                                VStack(spacing: 9) {
                                    GlassAppIcon(url: application.url, size: 42)
                                    Text(application.name)
                                        .font(.caption)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .foregroundStyle(.primary)
                                }
                                .frame(maxWidth: .infinity, minHeight: 92)
                                .contentShape(RoundedRectangle(cornerRadius: 16))
                            }
                            .buttonStyle(.plain)
                            .help("Open \(application.name)")
                        }
                    }
                }
            }
            .padding(18)
        }
    }

    private func openFirstMatchingApp() {
        guard let app = filteredApplications.first else { return }
        NSWorkspace.shared.open(app.url)
        SpotlightPanelController.shared.dismiss()
    }

    private var searchResults: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    calculatorSuggestion
                    webSearchSuggestion
                }

                if searchModel.isSearching {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Searching this Mac…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }

                if let error = searchModel.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 16)
                }

                if !searchModel.results.isEmpty {
                    Text("ON THIS MAC")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 16)
                        .padding(.top, 8)

                    ForEach(searchModel.results) { result in
                            Button {
                                open(result)
                            } label: {
                                HStack(spacing: 12) {
                                    Image(nsImage: NSWorkspace.shared.icon(forFile: result.url.path))
                                        .resizable()
                                        .frame(width: 34, height: 34)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(result.title)
                                            .font(.system(size: 15, weight: .medium))
                                            .lineLimit(1)
                                        Text(result.detail)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    Text(result.kind.label)
                                        .font(.caption2.weight(.medium))
                                        .foregroundStyle(.tertiary)
                                    Image(systemName: "arrow.up.left")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .contentShape(RoundedRectangle(cornerRadius: 12))
                            }
                            .buttonStyle(.plain)
                    }
                }

                if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    emptyState(
                        "Search this Mac or the web",
                        symbol: "sparkle.magnifyingglass",
                        detail: "Search apps and files, or type anything to search Google in a browser."
                    )
                    .frame(maxWidth: .infinity, minHeight: 250)
                } else if !searchModel.isSearching && searchModel.results.isEmpty && searchModel.errorMessage == nil {
                    Text("No local matches. Try the web search above.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(16)
                }

                if let webLaunchError {
                    Label(webLaunchError, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .padding(16)
                }
            }
            .padding(14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var quickCalculation: Calculation? {
        QuickCalculator.evaluate(query)
    }

    private var calculatorSuggestion: some View {
        Group {
            if let calculation = quickCalculation {
                VStack(alignment: .leading, spacing: 8) {
                    Text("CALCULATE")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                    Button(action: copyCalculation) {
                        HStack(spacing: 12) {
                            Image(systemName: "function")
                                .font(.system(size: 18, weight: .medium))
                                .foregroundStyle(.mint)
                                .frame(width: 36, height: 36)
                                .background(.mint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(calculation.formattedValue)
                                    .font(.system(size: 19, weight: .semibold, design: .rounded))
                                Text(calculation.expression)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Label(
                                calculationCopied ? "Copied" : "Copy",
                                systemImage: calculationCopied ? "checkmark" : "doc.on.doc"
                            )
                            .font(.caption.weight(.medium))
                            .foregroundStyle(calculationCopied ? Color.mint : Color.secondary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .contentShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                }
                .padding(12)
                .background(.mint.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
    }

    private var webSearchSuggestion: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SEARCH THE WEB")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 2)

            let browsers = WebSearch.installedBrowsers
            if browsers.isEmpty {
                Button {
                    searchWebInDefaultBrowser()
                } label: {
                    webSearchRow(title: "Search Google for “\(query)”", browserName: "Default Browser")
                }
                .buttonStyle(.plain)
            } else {
                ForEach(browsers) { browser in
                    Button {
                        searchWeb(in: browser)
                    } label: {
                        webSearchRow(title: "Search “\(query)”", browserName: browser.name)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(12)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func webSearchRow(title: String, browserName: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "globe")
                .font(.system(size: 18))
                .foregroundStyle(.cyan)
                .frame(width: 36, height: 36)
                .background(.cyan.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
                Text("Google · \(browserName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Image(systemName: "arrow.up.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .contentShape(RoundedRectangle(cornerRadius: 12))
    }

    private var assistantChat: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("AI service")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("AI service", selection: $assistantModel.provider) {
                        ForEach(AssistantProvider.allCases) { provider in
                            Text(provider.title).tag(provider)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 145)

                    if assistantModel.provider == .ollamaCloud {
                        TextField("gemma4:31b", text: $assistantModel.cloudModelName)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 150)
                        Text("Hosted by Ollama")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    } else {
                        TextField("qwen2.5:3b", text: $assistantModel.modelName)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 150)
                        Text("Runs on this Mac")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                }

                if assistantModel.provider == .ollamaCloud {
                    HStack(spacing: 8) {
                        SecureField(
                            assistantModel.hasCloudAPIKey
                                ? "Key saved — enter to replace"
                                : "Ollama Cloud API key",
                            text: $assistantModel.cloudAPIKeyInput
                        )
                        .textFieldStyle(.roundedBorder)
                        Button("Save key") { assistantModel.saveCloudAPIKey() }
                            .disabled(assistantModel.cloudAPIKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if assistantModel.hasCloudAPIKey {
                            Button("Remove") { assistantModel.removeCloudAPIKey() }
                        }
                        Button("Get key") { assistantModel.openOllamaAPIKeySettings() }
                    }
                    if let cloudKeyStatus = assistantModel.cloudKeyStatus {
                        Text(cloudKeyStatus)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)

            HStack(spacing: 6) {
                Image(systemName: "photo")
                Text("Photo text is read on this Mac; full vision sends the photo to the selected AI service.")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
            Toggle("Use full photo vision (for diagrams)", isOn: $assistantModel.useFullPhotoVision)
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(.cyan)
                .padding(.horizontal, 20)
                .padding(.bottom, 8)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(assistantModel.messages) { message in
                            HStack {
                                if message.role == .user { Spacer(minLength: 60) }
                                VStack(alignment: .leading, spacing: 8) {
                                    if !message.images.isEmpty {
                                        ScrollView(.horizontal) {
                                            HStack(spacing: 8) {
                                                ForEach(message.images) { image in
                                                    if let preview = image.preview {
                                                        Image(nsImage: preview)
                                                            .resizable()
                                                            .scaledToFit()
                                                            .frame(maxWidth: 180, maxHeight: 120)
                                                            .clipShape(RoundedRectangle(cornerRadius: 10))
                                                    }
                                                }
                                            }
                                        }
                                    }
                                    if !message.text.isEmpty {
                                        Text(message.text)
                                            .textSelection(.enabled)
                                    }
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .background(
                                    message.role == .user ? .cyan.opacity(0.22) : .white.opacity(0.08),
                                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                                )
                                if message.role == .assistant { Spacer(minLength: 40) }
                            }
                            .id(message.id)
                        }
                        if assistantModel.isSending {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text(assistantModel.progressMessage)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if let error = assistantModel.errorMessage {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .font(.callout)
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(18)
                }
                .onChange(of: assistantModel.messages.count) { _ in
                    if let lastMessage = assistantModel.messages.last {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(lastMessage.id, anchor: .bottom)
                        }
                    }
                }
            }

            if assistantModel.isPreparingImages || !assistantModel.pendingImages.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 10) {
                        if assistantModel.isPreparingImages {
                            ProgressView("Preparing photos…")
                                .controlSize(.small)
                        }
                        ForEach(assistantModel.pendingImages) { image in
                            HStack(spacing: 6) {
                                if let preview = image.preview {
                                    Image(nsImage: preview)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 48, height: 48)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                }
                                Text(image.name)
                                    .font(.caption)
                                    .lineLimit(1)
                                    .frame(maxWidth: 100)
                                Button {
                                    assistantModel.removePhoto(image)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Remove \(image.name)")
                            }
                            .padding(5)
                            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.bottom, 8)
            }

            HStack(spacing: 10) {
                Button(action: choosePhotos) {
                    Image(systemName: "photo.badge.plus")
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(.cyan)
                }
                .buttonStyle(.plain)
                .disabled(assistantModel.isSending || assistantModel.isPreparingImages || assistantModel.pendingImages.count >= 3)
                .help("Attach up to 3 photos of your homework")
                .accessibilityLabel("Attach photos")

                TextField("Message your assistant…", text: $prompt, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...4)
                    .onSubmit { submitPrompt(prompt) }
                Button {
                    submitPrompt(prompt)
                } label: {
                    if assistantModel.isSending {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(canSubmitAssistantMessage ? Color.cyan : Color.secondary)
                    }
                }
                .buttonStyle(.plain)
                .disabled(!canSubmitAssistantMessage || assistantModel.isSending || assistantModel.isPreparingImages)
            }
            .padding(12)
            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
        }
    }

    private var canSubmitAssistantMessage: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !assistantModel.pendingImages.isEmpty
    }

    private func choosePhotos() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "Add Photos"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        assistantModel.addPhotos(from: panel.urls)
    }

    private var footer: some View {
        HStack {
            Text(footerMessage)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer()
            Text("ESC to dismiss")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
        .background(.black.opacity(0.08))
        .overlay(alignment: .top) { Divider().overlay(.white.opacity(0.08)) }
    }

    private var footerMessage: String {
        switch selectedMode {
        case .search: "Tip: type a calculation for an instant copyable answer."
        case .apps: "Glass-styled icons are only changed inside this app."
        case .assistant:
            assistantModel.provider == .ollamaCloud
                ? "Prompts and OCR text go to Ollama Cloud; your API key is stored in macOS Keychain."
                : "Your prompts are processed by Ollama on this Mac."
        }
    }

    private func submitPrompt(_ value: String? = nil) {
        let text = value ?? (query.isEmpty ? prompt : query)
        assistantModel.send(text)
        query = ""
        prompt = ""
        isQueryFocused = false
    }

    private func open(_ result: SearchResult) {
        NSWorkspace.shared.open(result.url)
        SpotlightPanelController.shared.dismiss()
    }

    private func copyCalculation() {
        guard let calculation = quickCalculation else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(calculation.formattedValue, forType: .string)
        calculationCopied = true
    }

    private func searchWebInDefaultBrowser() {
        guard let url = WebSearch.searchURL(for: query) else {
            webLaunchError = "Could not create a web search URL."
            return
        }
        guard NSWorkspace.shared.open(url) else {
            webLaunchError = "macOS could not open the search in your default browser."
            return
        }
        SpotlightPanelController.shared.dismiss()
    }

    private func searchWeb(in browser: WebBrowser?) {
        guard let browser else {
            searchWebInDefaultBrowser()
            return
        }
        guard let url = WebSearch.searchURL(for: query) else {
            webLaunchError = "Could not create a web search URL."
            return
        }

        webLaunchError = nil
        NSWorkspace.shared.open(
            [url],
            withApplicationAt: browser.appURL,
            configuration: NSWorkspace.OpenConfiguration()
        ) { _, error in
            guard let error else { return }
            Task { @MainActor in
                webLaunchError = "Could not open \(browser.name): \(error.localizedDescription)"
            }
        }
        SpotlightPanelController.shared.dismiss()
    }

    private func emptyState(_ title: String, symbol: String, detail: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
    }
}

private enum AssistantMode: String, CaseIterable, Identifiable {
    case search
    case apps
    case assistant

    var id: String { rawValue }
    var title: String {
        switch self {
        case .search: "Search"
        case .apps: "Apps"
        case .assistant: "Ask AI"
        }
    }
    var symbol: String {
        switch self {
        case .search: "magnifyingglass"
        case .apps: "square.grid.2x2"
        case .assistant: "sparkles"
        }
    }
}
