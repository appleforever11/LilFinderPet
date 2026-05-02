import AppKit
import CoreGraphics
import SwiftUI
import Vision

struct ScreenSuggestion: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let detail: String
}

struct ScreenContext {
    let appName: String
    let windowTitle: String
    let recognizedText: [String]
    let audioTranscript: String

    var summary: String {
        if windowTitle.isEmpty {
            return appName
        }
        return "\(appName) - \(windowTitle)"
    }

    var isVideoContext: Bool {
        let combined = "\(appName) \(windowTitle) \(recognizedText.joined(separator: " "))".lowercased()
        return combined.contains("youtube")
            || combined.contains("youtu.be")
            || combined.contains("netflix")
            || combined.contains("video")
            || combined.contains("watch")
            || combined.contains("player")
    }
}

@MainActor
final class ScreenSuggestionModel: ObservableObject {
    @Published private(set) var isRefreshing = false
    @Published private(set) var hasScreenRecordingAccess = CGPreflightScreenCaptureAccess()
    @Published private(set) var context = ScreenContext(appName: "Unknown", windowTitle: "", recognizedText: [], audioTranscript: "")
    @Published private(set) var suggestions: [ScreenSuggestion] = []
    @Published private(set) var statusMessage = "Ready"

    private let settings: AppSettings
    private let speechListener: SpeechListener
    var onAnalysisComplete: ((ScreenContext, [ScreenSuggestion]) -> Void)?

    init(settings: AppSettings, speechListener: SpeechListener) {
        self.settings = settings
        self.speechListener = speechListener
    }

    func refresh(silent: Bool = false) {
        guard !isRefreshing else { return }
        isRefreshing = true
        if !silent {
            statusMessage = "Looking at the active window..."
        }
        hasScreenRecordingAccess = CGPreflightScreenCaptureAccess()

        Task {
            let result = await ScreenSuggestionAnalyzer.analyze(
                enableOCR: settings.enableOCR,
                audioTranscript: settings.enableVideoCompanion ? speechListener.transcript : ""
            )
            context = result.context
            suggestions = result.suggestions
            hasScreenRecordingAccess = CGPreflightScreenCaptureAccess()
            statusMessage = result.status
            isRefreshing = false
            onAnalysisComplete?(result.context, result.suggestions)
        }
    }

    func requestScreenRecordingAccess() {
        if CGPreflightScreenCaptureAccess() {
            hasScreenRecordingAccess = true
            refresh()
            return
        }
        _ = CGRequestScreenCaptureAccess()
        openScreenRecordingSettings()
    }

    func openScreenRecordingSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        if let url {
            NSWorkspace.shared.open(url)
        }
    }
}

enum ScreenSuggestionAnalyzer {
    static func analyze(enableOCR: Bool, audioTranscript: String) async -> (context: ScreenContext, suggestions: [ScreenSuggestion], status: String) {
        let app = NSWorkspace.shared.frontmostApplication?.localizedName ?? "Unknown"
        let window = activeWindow(for: app)
        var recognized: [String] = []
        var status = "Suggestions are based on the active app and window title."

        if !enableOCR {
            status = "OCR is off. Suggestions use the active app and window title."
        } else if CGPreflightScreenCaptureAccess(), let image = captureActiveWindow(window) {
            recognized = await recognizeText(in: image)
            if recognized.isEmpty {
                status = "Screen Recording is enabled, but no readable text was found."
            } else {
                status = "Read \(recognized.count) text snippets from the active window."
            }
        } else if !CGPreflightScreenCaptureAccess() {
            status = "Enable Screen Recording for OCR-based suggestions."
        }

        let context = ScreenContext(appName: app, windowTitle: window?.title ?? "", recognizedText: recognized, audioTranscript: audioTranscript)
        return (context, makeSuggestions(context: context), status)
    }

    private static func activeWindow(for appName: String) -> WindowInfo? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        let candidates = list.compactMap(WindowInfo.init(dictionary:))
            .filter { !$0.title.isEmpty && $0.ownerName == appName && $0.layer == 0 && $0.bounds.width > 80 && $0.bounds.height > 80 }
        return candidates.max { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }
    }

    private static func captureActiveWindow(_ window: WindowInfo?) -> CGImage? {
        guard let window else { return nil }
        return CGWindowListCreateImage(.null, [.optionIncludingWindow], window.id, [.bestResolution, .boundsIgnoreFraming])
    }

    private static func recognizeText(in image: CGImage) async -> [String] {
        await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .fast
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: image)
            do {
                try handler.perform([request])
                let snippets = request.results?
                    .compactMap { $0.topCandidates(1).first?.string.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty } ?? []
                return Array(snippets.prefix(12))
            } catch {
                return []
            }
        }.value
    }

    private static func makeSuggestions(context: ScreenContext) -> [ScreenSuggestion] {
        let app = context.appName.lowercased()
        let title = context.windowTitle.lowercased()
        let text = context.recognizedText.joined(separator: " ").lowercased()
        let transcript = context.audioTranscript.lowercased()
        let combined = "\(app) \(title) \(text) \(transcript)"
        var items: [ScreenSuggestion] = []

        if context.isVideoContext {
            items.append(contentsOf: videoSuggestions(context: context))
        } else if app.contains("xcode") || combined.contains("swift") || combined.contains("build failed") {
            items.append(.init(title: "Check the smallest failing build issue", detail: "Open the first compiler error, fix that one, then rebuild before changing anything else."))
            items.append(.init(title: "Name the next test", detail: "If you are editing behavior, add one focused test around the visible failure or UI state."))
            if combined.contains("warning") {
                items.append(.init(title: "Decide whether the warning matters", detail: "Fix warnings that indicate deprecated APIs, missing permissions, or lifecycle behavior before packaging."))
            }
        } else if app.contains("terminal") || app.contains("iterm") || combined.contains("zsh") {
            items.append(.init(title: "Capture the command outcome", detail: "If a command just failed, copy the exact command and the final 20 lines before retrying."))
            items.append(.init(title: "Keep one shell for long runs", detail: "Start long-running servers in a dedicated terminal so the prompt stays usable."))
            if combined.contains("swift build") || combined.contains("xcodebuild") {
                items.append(.init(title: "Re-run only after one focused change", detail: "Treat each build as a checkpoint so you can connect failures to the smallest edit."))
            }
        } else if app.contains("safari") || app.contains("chrome") || app.contains("arc") {
            items.append(.init(title: "Summarize the page before acting", detail: "Write down the page goal, the primary CTA, and what you need from it."))
            items.append(.init(title: "Look for source authority", detail: "Prefer docs, changelogs, or first-party pages when the content affects spending or implementation."))
            if combined.contains("download") || combined.contains("dmg") || combined.contains("install") {
                items.append(.init(title: "Verify the download source", detail: "Check publisher, version, and signature before installing or sharing the file."))
            }
        } else if app.contains("finder") {
            items.append(.init(title: "Use Quick Look", detail: "Tap Space on the selected file to verify it before opening a full app."))
            if combined.contains("downloads") || combined.contains("desktop") {
                items.append(.init(title: "Move finished exports", detail: "Put final apps and DMGs somewhere stable so drafts and completed builds do not mix."))
            }
            items.append(.init(title: "Clean up the current folder", detail: "Group related files, archive old exports, and rename one unclear item before moving on."))
        } else if app.contains("mail") || app.contains("outlook") || app.contains("gmail") {
            items.append(.init(title: "Draft the reply in three lines", detail: "Decision, context, next step. Keep the ask explicit."))
            items.append(.init(title: "Separate FYI from action", detail: "If it does not require a response or task, archive it after reading."))
        } else if app.contains("slack") || app.contains("teams") || app.contains("discord") {
            items.append(.init(title: "Turn the thread into an action", detail: "Extract owner, decision, and deadline before the conversation scrolls away."))
            items.append(.init(title: "Pause before sending", detail: "If the reply is longer than one screen, move it to a doc or issue."))
        }

        if combined.contains("error") || combined.contains("failed") || combined.contains("exception") {
            items.append(.init(title: "Save the failure text", detail: "Keep the exact error visible while you fix; avoid relying on memory."))
        }
        if combined.contains("todo") || combined.contains("fixme") {
            items.append(.init(title: "Promote a TODO", detail: "Either resolve it now or turn it into a tracked task with enough context."))
        }
        if combined.contains("permission") || combined.contains("privacy") {
            items.append(.init(title: "Check the needed permission", detail: "Open System Settings only for the permission the current feature actually needs."))
        }
        if combined.contains("large") || combined.contains("slow") || combined.contains("fast") {
            items.append(.init(title: "Tune the visible pacing", detail: "Adjust the pet animation speed and involvement level in Settings until it feels calm."))
        }
        if combined.contains("meeting") || combined.contains("calendar") {
            items.append(.init(title: "Prep one outcome", detail: "Write the decision you need from the meeting before joining."))
        }

        if items.isEmpty {
            items = [
                .init(title: "Pick the next tiny step", detail: "Choose one action that takes under five minutes and makes the current screen less ambiguous."),
                .init(title: "Reduce visual clutter", detail: "Close one unused window or tab before continuing."),
                .init(title: "Ask Lil Finder to refresh", detail: "Enable Screen Recording for OCR if you want suggestions based on visible text.")
            ]
        }

        return Array(items.prefix(5))
    }

    private static func videoSuggestions(context: ScreenContext) -> [ScreenSuggestion] {
        let visible = context.recognizedText.joined(separator: " ")
        let transcript = context.audioTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        let topic = videoTopic(from: context)
        var items: [ScreenSuggestion] = []

        if !transcript.isEmpty {
            items.append(.init(title: "That point about \(topic) seems worth pausing on", detail: "I heard: \"\(String(transcript.suffix(140)))\". Want to turn it into a quick note or question?"))
            if transcript.localizedCaseInsensitiveContains("because") || transcript.localizedCaseInsensitiveContains("why") {
                items.append(.init(title: "What is the cause-and-effect here?", detail: "The video sounds like it is explaining a reason or tradeoff. Ask whether the claim is evidence, opinion, or a setup for the next point."))
            } else {
                items.append(.init(title: "What would you ask the creator?", detail: "Pause for one question: what is missing, surprising, or worth checking after this segment?"))
            }
        } else if !visible.isEmpty {
            items.append(.init(title: "Want me to react to this video?", detail: "I can read the visible title/captions and ask questions. Turn on microphone listening for spoken commentary too."))
            items.append(.init(title: "What is the main claim?", detail: "Before the video moves on, name the claim and whether the screen is showing evidence, opinion, or entertainment."))
        } else {
            items.append(.init(title: "Watching YouTube?", detail: "Turn on Screen Recording/OCR and microphone listening so I can comment on titles, captions, and spoken audio."))
        }

        return items
    }

    private static func videoTopic(from context: ScreenContext) -> String {
        let candidates = [context.windowTitle] + context.recognizedText
        let text = candidates
            .joined(separator: " ")
            .replacingOccurrences(of: "YouTube", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            return "this"
        }
        return String(text.prefix(44))
    }
}

struct WindowInfo {
    let id: CGWindowID
    let ownerName: String
    let title: String
    let layer: Int
    let bounds: CGRect

    init?(dictionary: [String: Any]) {
        guard
            let id = dictionary[kCGWindowNumber as String] as? UInt32,
            let ownerName = dictionary[kCGWindowOwnerName as String] as? String,
            let layer = dictionary[kCGWindowLayer as String] as? Int,
            let boundsDict = dictionary[kCGWindowBounds as String] as? [String: Any],
            let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
        else {
            return nil
        }
        self.id = CGWindowID(id)
        self.ownerName = ownerName
        self.title = dictionary[kCGWindowName as String] as? String ?? ""
        self.layer = layer
        self.bounds = bounds
    }
}

struct SuggestionsView: View {
    @ObservedObject var model: ScreenSuggestionModel
    @ObservedObject var animator: PetAnimator

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            contextBlock
            suggestionList
            Spacer(minLength: 0)
            footer
        }
        .padding(18)
        .frame(minWidth: 360, minHeight: 430)
        .background(.regularMaterial)
    }

    private var header: some View {
        HStack(spacing: 12) {
            SpriteFrameView(row: 0, column: 0)
                .frame(width: 54, height: 58)
            VStack(alignment: .leading, spacing: 3) {
                Text("Lil Finder Suggestions")
                    .font(.headline)
                Text(model.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Button {
                animator.play(.running)
                model.refresh()
            } label: {
                Image(systemName: model.isRefreshing ? "hourglass" : "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh suggestions")
        }
    }

    private var contextBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(model.context.appName, systemImage: "macwindow")
                .font(.subheadline.weight(.semibold))
            if !model.context.windowTitle.isEmpty {
                Text(model.context.windowTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if !model.context.recognizedText.isEmpty {
                Text(model.context.recognizedText.prefix(3).joined(separator: "  "))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
            if !model.context.audioTranscript.isEmpty {
                Text(model.context.audioTranscript)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
        }
    }

    private var permissionBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Screen Recording unlocks OCR suggestions from the active window.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Enable Screen Recording") {
                    model.requestScreenRecordingAccess()
                }
                Button("Open Privacy Settings") {
                    model.openScreenRecordingSettings()
                }
            }
            .font(.caption)
        }
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private var suggestionList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Suggestions")
                .font(.subheadline.weight(.semibold))
            ForEach(model.suggestions) { suggestion in
                VStack(alignment: .leading, spacing: 3) {
                    Text(suggestion.title)
                        .font(.callout.weight(.semibold))
                    Text(suggestion.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var footer: some View {
        Text(model.hasScreenRecordingAccess ? "Runs locally. OCR uses Apple Vision on your Mac." : "Runs locally. Enable Screen Recording from the menu if you want OCR.")
            .font(.caption2)
            .foregroundStyle(.tertiary)
    }
}
