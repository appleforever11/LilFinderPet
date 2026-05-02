import AVFoundation
import Speech
import SwiftUI

@MainActor
final class SpeechListener: ObservableObject {
    @Published private(set) var isListening = false
    @Published private(set) var transcript = ""
    @Published private(set) var statusMessage = "Video listening is off."

    private let recognizer = SFSpeechRecognizer()
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    func start() {
        guard !isListening else { return }
        statusMessage = "Requesting microphone and speech recognition access..."

        Self.requestPermissions { [weak self] speechStatus, micAllowed in
            Task { @MainActor in
                guard let self else { return }
                guard speechStatus == .authorized else {
                    self.statusMessage = "Speech Recognition permission is needed for video listening."
                    return
                }
                guard micAllowed else {
                    self.statusMessage = "Microphone permission is needed for video listening."
                    return
                }
                self.startRecording()
            }
        }
    }

    nonisolated private static func requestPermissions(_ completion: @escaping @Sendable (SFSpeechRecognizerAuthorizationStatus, Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { speechStatus in
            AVCaptureDevice.requestAccess(for: .audio) { micAllowed in
                completion(speechStatus, micAllowed)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil
        if audioEngine.isRunning {
            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.stop()
        }
        isListening = false
        statusMessage = "Video listening is off."
    }

    private func startRecording() {
        stop()

        guard let recognizer, recognizer.isAvailable else {
            statusMessage = "Speech recognizer is not available right now."
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        self.request = request

        Self.installTap(on: audioEngine.inputNode, request: request)

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            statusMessage = "Could not start microphone listening: \(error.localizedDescription)"
            return
        }

        isListening = true
        statusMessage = "Listening for video audio through the microphone."
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let result {
                    self.transcript = String(result.bestTranscription.formattedString.suffix(600))
                    self.statusMessage = "Listening: captured \(self.transcript.count) transcript characters."
                }
                if error != nil {
                    self.stop()
                }
            }
        }
    }

    nonisolated private static func installTap(on input: AVAudioInputNode, request: SFSpeechAudioBufferRecognitionRequest) {
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak request] buffer, _ in
            request?.append(buffer)
        }
    }
}
