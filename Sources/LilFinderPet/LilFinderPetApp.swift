import AppKit
import ServiceManagement
import SwiftUI

@main
struct LilFinderPetApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

final class FocusablePetPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var petWindow: NSPanel?
    private var suggestionsWindow: NSPanel?
    private var settingsWindow: NSPanel?
    private var statusItem: NSStatusItem?
    private var contextTimer: Timer?
    private let settings = AppSettings()
    private lazy var animator = PetAnimator(settings: settings)
    private let bubbleModel = PetBubbleModel()
    private let speechListener = SpeechListener()
    private lazy var suggestionModel = ScreenSuggestionModel(settings: settings, speechListener: speechListener)
    private var lastPromptText = ""
    private var lastPromptDate = Date.distantPast
    private var lastPromptContext = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        ProcessInfo.processInfo.disableAutomaticTermination("Lil Finder Pet runs as a menu bar pet.")
        NSApp.setActivationPolicy(.accessory)
        NSApp.applicationIconImage = Self.resourceImage("AppIcon", extension: "png")
        NotificationCenter.default.addObserver(forName: .showLilFinderSuggestions, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.showSuggestions()
            }
        }
        NotificationCenter.default.addObserver(forName: .showLilFinderSettings, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.showSettings()
            }
        }
        NotificationCenter.default.addObserver(forName: .showLilFinderChat, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.showPetChat()
            }
        }
        suggestionModel.onAnalysisComplete = { [weak self] context, suggestions in
            self?.respondToScreenContext(context: context, suggestions: suggestions)
        }
        bubbleModel.chatResponder = { [weak self] prompt in
            self?.answerChat(prompt) ?? "I’m here. Ask me again after I look at the current screen."
        }
        bubbleModel.primaryAction = { [weak self] in
            self?.performTopSuggestionFromBubble()
        }
        settings.onChange = { [weak self] in
            self?.applySettings()
        }
        makeStatusItem()
        makePetWindow()
        applySettings()
        startContextTimer()
    }

    private func makeStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let image = Self.resourceImage("menubar-icon-template", extension: "png") {
            image.size = NSSize(width: 18, height: 18)
            image.isTemplate = false
            item.button?.image = image
            item.button?.imagePosition = .imageOnly
            item.button?.imageScaling = .scaleProportionallyDown
            item.button?.toolTip = "Lil Finder Pet"
        } else {
            item.button?.title = "◐"
            item.button?.toolTip = "Lil Finder Pet"
        }

        let menu = NSMenu()
        menu.addItem(menuItem("Talk to Lil Finder...", action: #selector(showChatFromMenu), keyEquivalent: "t"))
        menu.addItem(menuItem("Settings...", action: #selector(showSettings), keyEquivalent: ","))
        menu.addItem(menuItem("Suggestions...", action: #selector(showSuggestions), keyEquivalent: "s"))
        menu.addItem(menuItem("Refresh Suggestions", action: #selector(refreshSuggestions), keyEquivalent: "r"))
        menu.addItem(menuItem("Request Screen Recording Access", action: #selector(requestScreenRecording)))
        menu.addItem(.separator())
        menu.addItem(menuItem("Wave", action: #selector(wave), keyEquivalent: "w"))
        menu.addItem(menuItem("Nap", action: #selector(nap), keyEquivalent: "n"))
        menu.addItem(menuItem("Idle", action: #selector(idle), keyEquivalent: "i"))
        menu.addItem(.separator())
        menu.addItem(menuItem("Quit Lil Finder", action: #selector(quit), keyEquivalent: "q"))
        item.menu = menu

        statusItem = item
    }

    private func menuItem(_ title: String, action: Selector, keyEquivalent: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        return item
    }

    private static func resourceImage(_ name: String, extension ext: String) -> NSImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext)
            ?? Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Resources") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }

    private func makePetWindow() {
        let size = settings.windowSize
        let visible = NSScreen.main?.visibleFrame ?? .init(x: 0, y: 0, width: 1440, height: 900)
        let origin = NSPoint(x: visible.maxX - size.width - 34, y: visible.minY + 18)
        let panel = FocusablePetPanel(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.ignoresMouseEvents = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.isRestorable = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentView = NSHostingView(rootView: PetView(animator: animator, bubbleModel: bubbleModel, settings: settings))
        panel.orderFrontRegardless()

        petWindow = panel
        animator.start()
        suggestionModel.refresh()
    }

    private func startContextTimer() {
        contextTimer?.invalidate()
        contextTimer = Timer.scheduledTimer(withTimeInterval: settings.scanInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.suggestionModel.refresh(silent: true)
            }
        }
    }

    private func makeSuggestionsWindow() -> NSPanel {
        if let suggestionsWindow {
            return suggestionsWindow
        }
        let size = NSSize(width: 380, height: 460)
        let visible = NSScreen.main?.visibleFrame ?? .init(x: 0, y: 0, width: 1440, height: 900)
        let origin = NSPoint(x: visible.maxX - size.width - 28, y: visible.maxY - size.height - 40)
        let panel = NSPanel(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.titled, .closable, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "Lil Finder Suggestions"
        panel.isRestorable = false
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: SuggestionsView(model: suggestionModel, animator: animator))
        suggestionsWindow = panel
        return panel
    }

    private func makeSettingsWindow() -> NSPanel {
        if let settingsWindow {
            return settingsWindow
        }
        let size = NSSize(width: 620, height: 660)
        let visible = NSScreen.main?.visibleFrame ?? .init(x: 0, y: 0, width: 1440, height: 900)
        let origin = NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
        let panel = NSPanel(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "Lil Finder Settings"
        panel.isRestorable = false
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: SettingsPanel(settings: settings, animator: animator, suggestionModel: suggestionModel, speechListener: speechListener))
        settingsWindow = panel
        return panel
    }

    private func applySettings() {
        LoginItemController.setEnabled(settings.launchAtLogin)
        if settings.enableVideoCompanion && settings.enableVideoListening {
            speechListener.start()
        } else {
            speechListener.stop()
        }
        animator.applySettings()
        startContextTimer()
        if let petWindow {
            petWindow.setContentSize(settings.windowSize)
        }
    }

    @objc private func showSettings() {
        let panel = makeSettingsWindow()
        NSApp.activate(ignoringOtherApps: true)
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func showSuggestions() {
        let panel = makeSuggestionsWindow()
        panel.orderFrontRegardless()
        suggestionModel.refresh(silent: false)
        animator.play(.review)
        bubbleModel.dismiss()
    }

    @objc private func refreshSuggestions() {
        makeSuggestionsWindow().orderFrontRegardless()
        suggestionModel.refresh(silent: false)
        animator.play(.running)
        bubbleModel.show(text: "I’m checking what’s on screen.", primaryTitle: "Open", secondaryTitle: "Hide")
    }

    @objc private func requestScreenRecording() {
        suggestionModel.requestScreenRecordingAccess()
        makeSuggestionsWindow().orderFrontRegardless()
    }

    @objc private func wave() {
        animator.play(.waving)
    }

    @objc private func nap() {
        animator.play(.waiting)
    }

    @objc private func idle() {
        animator.play(.idle)
    }

    @objc private func showChatFromMenu() {
        showPetChat()
    }

    private func showPetChat() {
        NSApp.activate(ignoringOtherApps: true)
        petWindow?.makeKeyAndOrderFront(nil)
        bubbleModel.startChat()
        animator.play(.review)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func respondToScreenContext(context: ScreenContext, suggestions: [ScreenSuggestion]) {
        guard settings.enableBubbles || settings.autoOpenSuggestions else { return }
        let combined = "\(context.appName) \(context.windowTitle) \(context.recognizedText.joined(separator: " "))".lowercased()
        let strongest = suggestions.first
        let activeLevel = settings.activeLevel
        let isVideo = context.isVideoContext

        if combined.contains("error") || combined.contains("failed") || combined.contains("exception") {
            animator.play(.failed)
            showPrompt("I see a possible error. Want help triaging it?", force: true)
            return
        }

        let app = context.appName.lowercased()
        if settings.enableVideoCompanion && isVideo {
            animator.play(.review)
            showPrompt(strongest?.title ?? "Want to pause and unpack that part?", minimumActivity: 0.3)
        } else if app.contains("xcode") || app.contains("terminal") || app.contains("iterm") {
            animator.play(.running)
            showPrompt(strongest?.title ?? "Looks like work mode. Want a next-step suggestion?", minimumActivity: 0.35)
        } else if app.contains("mail") || app.contains("outlook") || app.contains("slack") || app.contains("teams") || app.contains("discord") {
            animator.play(.review)
            showPrompt(strongest?.title ?? "Want me to turn this into an action?", minimumActivity: 0.45)
        } else if app.contains("finder") {
            animator.play(.waving)
            if combined.contains("downloads") || combined.contains("desktop") || settings.activeLevel > 0.85 {
                showPrompt(strongest?.title ?? "Want a quick cleanup suggestion?", minimumActivity: 0.75, contextKey: "finder-\(context.windowTitle)")
            }
        } else if !suggestions.isEmpty && !suggestions[0].title.isEmpty {
            animator.play(.review)
            showPrompt(suggestions[0].title, minimumActivity: 0.6)
        } else if activeLevel > 0.85 {
            animator.play(.waving)
            showPrompt("Want me to look for a useful next step?", minimumActivity: 0.85)
        }
    }

    private func showPrompt(_ text: String, minimumActivity: Double = 0.0, force: Bool = false, contextKey: String = "") {
        guard force || settings.activeLevel >= minimumActivity else { return }
        let now = Date()
        let normalized = text.lowercased()
        if !force {
            if bubbleModel.isVisible && bubbleModel.mode == .prompt && normalized == lastPromptText {
                return
            }
            if normalized == lastPromptText && now.timeIntervalSince(lastPromptDate) < 600 {
                return
            }
            if !contextKey.isEmpty && contextKey == lastPromptContext && now.timeIntervalSince(lastPromptDate) < 900 {
                return
            }
        }
        lastPromptText = normalized
        lastPromptDate = now
        lastPromptContext = contextKey
        if settings.enableBubbles {
            let actionTitle = suggestionModel.suggestions.first?.actionTitle ?? "Do it"
            bubbleModel.primaryAction = { [weak self] in
                self?.performTopSuggestionFromBubble()
            }
            bubbleModel.show(text: text, primaryTitle: actionTitle, secondaryTitle: "Later")
        }
        if settings.autoOpenSuggestions && force {
            makeSuggestionsWindow().orderFrontRegardless()
        }
    }

    private func performTopSuggestionFromBubble() {
        if let suggestion = suggestionModel.suggestions.first {
            suggestionModel.perform(suggestion)
            animator.play(.waving)
            if suggestion.action == .openChat {
                return
            }
            let response: String
            switch suggestion.action {
            case .copyNote:
                response = "Copied that note for you."
            case .openChat:
                response = "Opened chat. Ask me what you want to do with it."
            case .openDownloads:
                response = "Opened Downloads."
            case .openDesktop:
                response = "Opened Desktop."
            case .openSettings:
                response = "Opened Settings."
            case .requestScreenRecording:
                response = "Started the Screen Recording permission flow."
            case .openScreenRecordingSettings:
                response = "Opened Screen Recording settings."
            case .refresh:
                response = "Refreshing suggestions."
            }
            bubbleModel.show(text: response, primaryTitle: "Suggestions", secondaryTitle: "Hide")
            bubbleModel.primaryAction = { [weak self] in
                self?.showSuggestions()
            }
        } else {
            suggestionModel.refresh(silent: false)
            bubbleModel.show(text: "I’m refreshing suggestions from the active app.", primaryTitle: "Suggestions", secondaryTitle: "Hide")
            bubbleModel.primaryAction = { [weak self] in
                self?.showSuggestions()
            }
        }
    }

    private func answerChat(_ prompt: String) -> String {
        let lower = prompt.lowercased()
        let context = suggestionModel.context
        let suggestions = suggestionModel.suggestions
        let transcript = context.audioTranscript.trimmingCharacters(in: .whitespacesAndNewlines)

        if lower.contains("what") && (lower.contains("screen") || lower.contains("doing")) {
            if let first = suggestions.first {
                return "I see \(context.summary). My first thought: \(first.title.lowercased())."
            }
            return "I see \(context.summary). I don’t have a strong read yet, but I can refresh if you want."
        }

        if lower.contains("youtube") || lower.contains("video") || lower.contains("watching") {
            if !transcript.isEmpty {
                return "From the video audio, I’d pause on: \(String(transcript.suffix(120)))"
            }
            if context.isVideoContext {
                return "This looks video-related. I can comment better if OCR and video listening are enabled."
            }
            return "I don’t think I’m looking at a video right now."
        }

        if lower.contains("suggest") || lower.contains("next") || lower.contains("help") {
            if let first = suggestions.first {
                return "\(first.title). \(first.detail)"
            }
            return "Try one tiny next step: make the current screen less ambiguous before switching tasks."
        }

        if lower.contains("hello") || lower.contains("hi") {
            return "Hi. I’m watching the active app quietly. Ask me what I see, what to do next, or what I think of a video."
        }

        if let first = suggestions.first {
            return "My take: \(first.title.lowercased()). \(first.detail)"
        }
        return "I’m not sure yet. Ask me what I see, or turn on OCR so I can read the active window."
    }
}

@MainActor
final class AppSettings: ObservableObject {
    private let defaults = UserDefaults.standard
    var onChange: (() -> Void)?

    @Published var animationSpeed: Double { didSet { save(animationSpeed, for: "animationSpeed") } }
    @Published var activeLevel: Double { didSet { save(activeLevel, for: "activeLevel") } }
    @Published var scanInterval: Double { didSet { save(scanInterval, for: "scanInterval") } }
    @Published var petScale: Double { didSet { save(petScale, for: "petScale") } }
    @Published var idleRow: Int { didSet { save(idleRow, for: "idleRow") } }
    @Published var idleColumn: Int { didSet { save(idleColumn, for: "idleColumn") } }
    @Published var enableBubbles: Bool { didSet { save(enableBubbles, for: "enableBubbles") } }
    @Published var enableOCR: Bool { didSet { save(enableOCR, for: "enableOCR") } }
    @Published var autoOpenSuggestions: Bool { didSet { save(autoOpenSuggestions, for: "autoOpenSuggestions") } }
    @Published var launchAtLogin: Bool { didSet { save(launchAtLogin, for: "launchAtLogin") } }
    @Published var enableVideoCompanion: Bool { didSet { save(enableVideoCompanion, for: "enableVideoCompanion") } }
    @Published var enableVideoListening: Bool { didSet { save(enableVideoListening, for: "enableVideoListening") } }

    init() {
        animationSpeed = defaults.object(forKey: "animationSpeed") as? Double ?? 0.75
        activeLevel = defaults.object(forKey: "activeLevel") as? Double ?? 0.7
        scanInterval = defaults.object(forKey: "scanInterval") as? Double ?? 28
        petScale = defaults.object(forKey: "petScale") as? Double ?? 0.9
        idleRow = defaults.object(forKey: "idleRow") as? Int ?? 0
        idleColumn = defaults.object(forKey: "idleColumn") as? Int ?? 0
        enableBubbles = defaults.object(forKey: "enableBubbles") as? Bool ?? true
        enableOCR = defaults.object(forKey: "enableOCR") as? Bool ?? true
        autoOpenSuggestions = defaults.object(forKey: "autoOpenSuggestions") as? Bool ?? false
        launchAtLogin = defaults.object(forKey: "launchAtLogin") as? Bool ?? LoginItemController.isEnabled
        enableVideoCompanion = defaults.object(forKey: "enableVideoCompanion") as? Bool ?? true
        enableVideoListening = defaults.object(forKey: "enableVideoListening") as? Bool ?? false
    }

    var petSize: NSSize {
        NSSize(width: PetLayout.basePetSize.width * petScale, height: PetLayout.basePetSize.height * petScale)
    }

    var windowSize: NSSize {
        NSSize(width: max(390, 420 * petScale), height: max(204, 220 * petScale))
    }

    private func save(_ value: Double, for key: String) {
        defaults.set(value, forKey: key)
        onChange?()
    }

    private func save(_ value: Int, for key: String) {
        defaults.set(value, forKey: key)
        onChange?()
    }

    private func save(_ value: Bool, for key: String) {
        defaults.set(value, forKey: key)
        onChange?()
    }
}

enum LoginItemController {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled, SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            } else if !enabled, SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Lil Finder Pet launch-at-login update failed: \(error.localizedDescription)")
        }
    }
}

enum PetState: Int, CaseIterable {
    case idle = 0
    case runningRight = 1
    case runningLeft = 2
    case waving = 3
    case jumping = 4
    case failed = 5
    case waiting = 6
    case running = 7
    case review = 8
}

@MainActor
final class PetAnimator: ObservableObject {
    @Published private(set) var currentFrame = SpriteFrame(row: PetState.idle.rawValue, column: 0)

    private let settings: AppSettings
    private var timer: Timer?
    private var sequence: [SpriteFrame] = AnimationSequences.idle
    private var sequenceIndex = 0
    private var mode: PetState = .idle
    private var loopsInMode = 0

    init(settings: AppSettings) {
        self.settings = settings
        currentFrame = SpriteFrame(row: settings.idleRow, column: settings.idleColumn)
        sequence = AnimationSequences.idle(settings: settings)
    }

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: settings.animationSpeed, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
    }

    func applySettings() {
        if mode == .idle {
            sequence = AnimationSequences.idle(settings: settings)
            currentFrame = sequence.first ?? SpriteFrame(row: settings.idleRow, column: settings.idleColumn)
        }
        start()
    }

    func play(_ newState: PetState) {
        mode = newState
        loopsInMode = 0
        sequenceIndex = 0
        sequence = AnimationSequences.sequence(for: newState, settings: settings)
        currentFrame = sequence[0]
    }

    func preview(_ frame: SpriteFrame) {
        mode = .idle
        loopsInMode = 0
        sequenceIndex = 0
        currentFrame = frame
        sequence = [frame]
    }

    func playRow(_ row: Int) {
        mode = .idle
        loopsInMode = 0
        sequenceIndex = 0
        sequence = AnimationSequences.row(row, columns: Array(0..<SpriteSheet.columns))
        currentFrame = sequence[0]
    }

    private func tick() {
        guard !sequence.isEmpty else { return }
        sequenceIndex += 1
        if sequenceIndex >= sequence.count {
            sequenceIndex = 0
            loopsInMode += 1
            advanceModeIfNeeded()
        }
        currentFrame = sequence[sequenceIndex]
    }

    private func advanceModeIfNeeded() {
        switch mode {
        case .idle:
            sequence = AnimationSequences.sequence(for: .idle, settings: settings)
        case .waving, .jumping, .review, .running:
            if loopsInMode >= 1 {
                mode = .idle
                loopsInMode = 0
            }
            sequence = AnimationSequences.sequence(for: mode, settings: settings)
        case .waiting:
            if loopsInMode >= 2 {
                mode = .idle
                loopsInMode = 0
            }
            sequence = AnimationSequences.sequence(for: mode, settings: settings)
        case .failed, .runningLeft, .runningRight:
            if loopsInMode >= 1 {
                mode = .idle
                loopsInMode = 0
            }
            sequence = AnimationSequences.sequence(for: mode, settings: settings)
        }
    }
}

struct SpriteFrame: Equatable {
    let row: Int
    let column: Int
}

@MainActor
enum AnimationSequences {
    static let idle = row(0, columns: [0, 2, 4, 7])

    static func idle(settings: AppSettings) -> [SpriteFrame] {
        let selected = SpriteFrame(row: settings.idleRow, column: settings.idleColumn)
        if settings.idleRow == 0 {
            return [selected, SpriteFrame(row: 0, column: 2), SpriteFrame(row: 0, column: 4), selected]
        }
        return [selected]
    }

    static func sequence(for state: PetState, settings: AppSettings) -> [SpriteFrame] {
        switch state {
        case .idle:
            return idle(settings: settings)
        case .runningRight:
            return row(1, columns: [0, 1, 2, 3, 4, 5, 6, 7])
        case .runningLeft:
            return row(2, columns: [0, 1, 2, 3, 4, 5, 6, 7])
        case .waving:
            return row(3, columns: [0, 1, 2, 3, 4, 5, 6, 7]) + row(8, columns: [0, 3, 6])
        case .jumping:
            return row(4, columns: [0, 1, 2, 3, 4, 5, 6, 7])
        case .failed:
            return row(5, columns: [0, 1, 2, 3, 4, 5, 6, 7])
        case .waiting:
            return row(6, columns: [0, 1, 2, 3, 4, 5, 6, 7])
        case .running:
            return row(7, columns: [0, 1, 2, 3, 4, 5, 6, 7]) + row(8, columns: [2, 5])
        case .review:
            return row(8, columns: [0, 1, 2, 3, 4, 5, 6, 7])
        }
    }

    static func row(_ row: Int, columns: [Int]) -> [SpriteFrame] {
        columns.map { SpriteFrame(row: row, column: $0) }
    }
}

enum PetLayout {
    static let basePetSize = NSSize(width: 124, height: 134)
    static let windowSize = NSSize(width: 300, height: 220)
}

struct PetView: View {
    @ObservedObject var animator: PetAnimator
    @ObservedObject var bubbleModel: PetBubbleModel
    @ObservedObject var settings: AppSettings
    @State private var dragStart: NSPoint?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if bubbleModel.isVisible {
                PetBubbleView(model: bubbleModel)
                    .frame(maxWidth: 230)
                    .padding(.leading, 112)
                    .padding(.bottom, 128)
                    .transition(.scale(scale: 0.92, anchor: .bottomLeading).combined(with: .opacity))
            }

            SpriteFrameView(row: animator.currentFrame.row, column: animator.currentFrame.column)
                .frame(width: settings.petSize.width, height: settings.petSize.height)
                .padding(.leading, 8)
                .padding(.bottom, 4)
                .contextMenu {
                    Button("Settings") {
                        NotificationCenter.default.post(name: .showLilFinderSettings, object: nil)
                    }
                    Button("Suggestions") {
                        NotificationCenter.default.post(name: .showLilFinderSuggestions, object: nil)
                    }
                    Button("Talk to Lil Finder") {
                        NotificationCenter.default.post(name: .showLilFinderChat, object: nil)
                    }
                    Button("Wave") { animator.play(.waving) }
                    Button("Nap") { animator.play(.waiting) }
                    Button("Jump") { animator.play(.jumping) }
                    Divider()
                    Button("Quit") { NSApp.terminate(nil) }
                }
        }
        .frame(width: settings.windowSize.width, height: settings.windowSize.height)
        .contentShape(Rectangle())
        .gesture(dragGesture)
        .animation(.spring(response: 0.24, dampingFraction: 0.86), value: bubbleModel.isVisible)
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                guard let window = NSApp.windows.first(where: { $0.contentView is NSHostingView<PetView> }) else { return }
                if dragStart == nil {
                    dragStart = window.frame.origin
                }
                let start = dragStart ?? window.frame.origin
                window.setFrameOrigin(NSPoint(x: start.x + value.translation.width, y: start.y - value.translation.height))
            }
            .onEnded { _ in
                dragStart = nil
            }
    }
}

@MainActor
final class PetBubbleModel: ObservableObject {
    enum Mode {
        case prompt
        case chat
    }

    @Published var isVisible = false
    @Published var mode: Mode = .prompt
    @Published var text = ""
    @Published var primaryTitle = "Show"
    @Published var secondaryTitle = "Later"
    @Published var chatInput = ""
    @Published var chatReply = "Ask me what I see, what to do next, or what I think about a video."

    private var dismissTask: Task<Void, Never>?
    var chatResponder: ((String) -> String)?
    var primaryAction: (() -> Void)?

    func show(text: String, primaryTitle: String = "Show", secondaryTitle: String = "Later") {
        mode = .prompt
        self.text = text
        self.primaryTitle = primaryTitle
        self.secondaryTitle = secondaryTitle
        isVisible = true
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            await MainActor.run {
                self?.isVisible = false
            }
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        isVisible = false
    }

    func startChat() {
        dismissTask?.cancel()
        mode = .chat
        isVisible = true
        if chatReply.isEmpty {
            chatReply = "Ask me what I see, what to do next, or what I think about a video."
        }
    }

    func sendChat() {
        let prompt = chatInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        chatInput = ""
        chatReply = chatResponder?(prompt) ?? "I’m not sure yet. Ask me what I see."
    }
}

struct PetBubbleView: View {
    @ObservedObject var model: PetBubbleModel

    var body: some View {
        Group {
            switch model.mode {
            case .prompt:
                promptBody
            case .chat:
                chatBody
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(alignment: .bottomLeading) {
            BubbleTail()
                .fill(.regularMaterial)
                .frame(width: 18, height: 14)
                .offset(x: 18, y: 10)
        }
        .shadow(color: .black.opacity(0.18), radius: 14, x: 0, y: 8)
    }

    private var promptBody: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(model.text)
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button(model.primaryTitle) {
                    model.dismiss()
                    model.primaryAction?()
                }
                Button(model.secondaryTitle) {
                    model.dismiss()
                }
            }
            .font(.caption2)
        }
    }

    private var chatBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Lil Finder")
                    .font(.caption.weight(.semibold))
                Spacer()
                Button {
                    model.dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Close chat")
            }

            Text(model.chatReply)
                .font(.caption)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(4)

            HStack(spacing: 6) {
                TextField("Ask...", text: $model.chatInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .onSubmit {
                        model.sendChat()
                    }
                Button {
                    model.sendChat()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                }
                .buttonStyle(.borderless)
                .help("Send")
                .disabled(model.chatInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}

struct BubbleTail: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

extension Notification.Name {
    static let showLilFinderSuggestions = Notification.Name("showLilFinderSuggestions")
    static let showLilFinderSettings = Notification.Name("showLilFinderSettings")
    static let showLilFinderChat = Notification.Name("showLilFinderChat")
}

struct SettingsPanel: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var animator: PetAnimator
    @ObservedObject var suggestionModel: ScreenSuggestionModel
    @ObservedObject var speechListener: SpeechListener

    private let columns = Array(repeating: GridItem(.fixed(54), spacing: 6), count: SpriteSheet.columns)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                behaviorSection
                animationSection
                spriteSection
                aiSection
            }
            .padding(20)
        }
        .frame(minWidth: 600, minHeight: 620)
        .background(.regularMaterial)
    }

    private var header: some View {
        HStack(spacing: 14) {
            SpriteFrameView(row: settings.idleRow, column: settings.idleColumn)
                .frame(width: 62, height: 68)
            VStack(alignment: .leading, spacing: 4) {
                Text("Lil Finder Settings")
                    .font(.title3.weight(.semibold))
                Text("Tune how often he moves, asks, and reads the active window.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                animator.play(.waving)
            } label: {
                Image(systemName: "sparkles")
            }
            .help("Preview an animation")
        }
    }

    private var behaviorSection: some View {
        SettingsGroup(title: "Assistant") {
            Toggle("Launch at Login", isOn: $settings.launchAtLogin)
            Toggle("Show pop-up bubble prompts", isOn: $settings.enableBubbles)
            Toggle("Use Screen Recording OCR when permission is enabled", isOn: $settings.enableOCR)
            Toggle("Open the suggestions panel for strong signals", isOn: $settings.autoOpenSuggestions)
            Button("Refresh Screen Suggestions Now") {
                animator.play(.review)
                suggestionModel.refresh()
            }
        }
    }

    private var animationSection: some View {
        SettingsGroup(title: "Animation") {
            LabeledSlider(
                title: "Frame pacing",
                value: $settings.animationSpeed,
                range: 0.35...1.8,
                format: { "\(String(format: "%.2f", $0))s" }
            )
            LabeledSlider(
                title: "Pet size",
                value: $settings.petScale,
                range: 0.65...1.15,
                format: { "\(Int($0 * 100))%" }
            )
            HStack(spacing: 8) {
                Button("Idle") { animator.play(.idle) }
                Button("Wave") { animator.play(.waving) }
                Button("Jump") { animator.play(.jumping) }
                Button("Think") { animator.play(.review) }
                Button("Nap") { animator.play(.waiting) }
                Spacer()
            }
        }
    }

    private var spriteSection: some View {
        SettingsGroup(title: "All Animation Sprites") {
            Text("Every bundled sprite is shown below. Click a sprite to set it as the idle pose, or play a whole row as an animation preview.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("Sprite sheet artwork credited to BasicAppleGuy at basicappleguy.com/basicappleblog/lil-finder-guy-blind-box.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(0..<SpriteSheet.rows, id: \.self) { row in
                SpriteRowPicker(
                    row: row,
                    title: SpriteSheet.rowName(row),
                    selectedFrame: SpriteFrame(row: settings.idleRow, column: settings.idleColumn),
                    onSelect: { column in
                        settings.idleRow = row
                        settings.idleColumn = column
                        animator.preview(SpriteFrame(row: row, column: column))
                    },
                    onPlay: {
                        animator.playRow(row)
                    }
                )
            }

            DisclosureGroup("Compact sheet view") {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                    ForEach(0..<SpriteSheet.rows, id: \.self) { row in
                        ForEach(0..<SpriteSheet.columns, id: \.self) { column in
                            spriteButton(row: row, column: column)
                        }
                    }
                }
                .padding(.top, 8)
            }
            .font(.caption)
        }
    }

    private var aiSection: some View {
        SettingsGroup(title: "Activity") {
            Toggle("Video Companion", isOn: $settings.enableVideoCompanion)
            Toggle("Listen with microphone for video commentary", isOn: $settings.enableVideoListening)
                .disabled(!settings.enableVideoCompanion)
            LabeledSlider(
                title: "Involvement",
                value: $settings.activeLevel,
                range: 0...1,
                format: { value in
                    switch value {
                    case 0..<0.34: return "Quiet"
                    case 0.34..<0.74: return "Helpful"
                    default: return "Very active"
                    }
                }
            )
            LabeledSlider(
                title: "Screen check interval",
                value: $settings.scanInterval,
                range: 12...120,
                format: { "\(Int($0))s" }
            )
            Text(suggestionModel.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            if settings.enableVideoCompanion {
                Text(speechListener.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if !speechListener.transcript.isEmpty {
                    Text(speechListener.transcript)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(3)
                }
            }
        }
    }

    private func spriteButton(row: Int, column: Int) -> some View {
        let isSelected = row == settings.idleRow && column == settings.idleColumn
        return Button {
            settings.idleRow = row
            settings.idleColumn = column
            animator.preview(SpriteFrame(row: row, column: column))
        } label: {
            SpriteFrameView(row: row, column: column)
                .frame(width: 46, height: 50)
                .padding(3)
                .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.18), lineWidth: isSelected ? 2 : 1)
                }
        }
        .buttonStyle(.plain)
        .help("Sprite row \(row + 1), frame \(column + 1)")
    }
}

struct SpriteRowPicker: View {
    let row: Int
    let title: String
    let selectedFrame: SpriteFrame
    let onSelect: (Int) -> Void
    let onPlay: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.caption.weight(.semibold))
                Spacer()
                Button {
                    onPlay()
                } label: {
                    Label("Play Row", systemImage: "play.fill")
                }
                .font(.caption)
            }
            HStack(spacing: 7) {
                ForEach(0..<SpriteSheet.columns, id: \.self) { column in
                    spriteButton(column: column)
                }
            }
        }
        .padding(9)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private func spriteButton(column: Int) -> some View {
        let isSelected = selectedFrame.row == row && selectedFrame.column == column
        return Button {
            onSelect(column)
        } label: {
            VStack(spacing: 3) {
                SpriteFrameView(row: row, column: column)
                    .frame(width: 48, height: 52)
                Text("\(column + 1)")
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .padding(4)
            .frame(width: 62, height: 76)
            .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: isSelected ? 2 : 1)
            }
        }
        .buttonStyle(.plain)
        .help("Use row \(row + 1), sprite \(column + 1) as idle")
    }
}

struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            VStack(alignment: .leading, spacing: 10) {
                content
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.opacity(0.48), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

struct LabeledSlider<ValueLabel: StringProtocol>: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: (Double) -> ValueLabel

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .frame(width: 150, alignment: .leading)
            Slider(value: $value, in: range)
            Text(String(format(value)))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 76, alignment: .trailing)
        }
        .font(.caption)
    }
}

struct SpriteFrameView: View {
    let row: Int
    let column: Int

    var body: some View {
        if let image = SpriteSheet.shared.frame(row: row, column: column) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .accessibilityLabel("Lil Finder Guy")
        } else {
            Color.clear
        }
    }
}

@MainActor
final class SpriteSheet {
    static let shared = SpriteSheet()
    static let columns = 8
    static var rows: Int { shared.rowCount }

    private let cgImage: CGImage?
    private let cellWidth = 192
    private let cellHeight = 208
    private let rowCount: Int
    private var cache: [String: NSImage] = [:]

    private init() {
        guard
            let url = Self.spriteSheetURL(),
            let image = NSImage(contentsOf: url),
            let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else {
            cgImage = nil
            rowCount = 0
            return
        }
        cgImage = cg
        rowCount = max(1, cg.height / cellHeight)
    }

    private static func spriteSheetURL() -> URL? {
        if let appResourceURL = Bundle.main.resourceURL?.appendingPathComponent("lil-finder-spritesheet.png"),
           FileManager.default.fileExists(atPath: appResourceURL.path) {
            return appResourceURL
        }
        return Bundle.module.url(forResource: "lil-finder-spritesheet", withExtension: "png", subdirectory: "Resources")
    }

    func frame(row: Int, column: Int) -> NSImage? {
        let key = "\(row)-\(column)"
        if let cached = cache[key] {
            return cached
        }
        guard let cgImage, row >= 0, column >= 0, row < rowCount, column < Self.columns else { return nil }

        let rect = CGRect(x: column * cellWidth, y: row * cellHeight, width: cellWidth, height: cellHeight)
        guard let cropped = cgImage.cropping(to: rect) else { return nil }
        let image = NSImage(cgImage: cropped, size: NSSize(width: cellWidth, height: cellHeight))
        cache[key] = image
        return image
    }

    static func rowName(_ row: Int) -> String {
        let names = [
            "Row 1 - Idle and Standing",
            "Row 2 - Side Poses and Wave",
            "Row 3 - Wave and Work Props",
            "Row 4 - Alternate Standing",
            "Row 5 - Sitting and Falling",
            "Row 6 - Tired and Resting",
            "Row 7 - Sleeping",
            "Row 8 - Work Props",
            "Row 9 - Final Pose Set"
        ]
        if row < names.count {
            return names[row]
        }
        return "Row \(row + 1)"
    }
}
