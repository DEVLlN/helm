import AVFoundation
import Foundation
import Speech

@MainActor
final class MacCommandSpeechRecognizer: NSObject {
    enum RecognizerError: LocalizedError {
        case speechUnavailable
        case recognizerUnavailable

        var errorDescription: String? {
            switch self {
            case .speechUnavailable:
                return "Speech recognition is not available on this Mac."
            case .recognizerUnavailable:
                return "helm could not create a speech recognizer."
            }
        }
    }

    struct AuthorizationSnapshot {
        let speech: String
        let microphone: String
        let ready: Bool
    }

    private let audioEngine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var silenceTimer: Timer?
    private var currentTranscript = ""

    var onPartialTranscript: ((String) -> Void)?
    var onFinalTranscript: ((String) -> Void)?
    var onStateChanged: ((String) -> Void)?
    var onStopped: (() -> Void)?

    func authorizationSnapshot() async -> AuthorizationSnapshot {
        let speechStatus = await requestSpeechAuthorizationIfNeeded()
        let microphoneStatus = await requestMicrophoneAuthorizationIfNeeded()

        return AuthorizationSnapshot(
            speech: describeSpeechAuthorization(speechStatus),
            microphone: describeMicrophoneAuthorization(microphoneStatus),
            ready: speechStatus == .authorized && microphoneStatus == true
        )
    }

    func start() async throws {
        let authorization = await authorizationSnapshot()
        guard authorization.ready else {
            onStateChanged?("Speech permission is required before helm can listen.")
            return
        }

        guard let recognizer else {
            throw RecognizerError.recognizerUnavailable
        }

        guard recognizer.isAvailable else {
            throw RecognizerError.speechUnavailable
        }

        stop(notify: false)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = false
        self.request = request
        currentTranscript = ""

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()
        onStateChanged?("Listening for Command on this Mac.")

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            Task { @MainActor in
                if let result {
                    let transcript = result.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.currentTranscript = transcript
                    self.onPartialTranscript?(transcript)
                    self.bumpSilenceTimer()

                    if result.isFinal, !transcript.isEmpty {
                        self.finish(with: transcript)
                        return
                    }
                }

                if let error {
                    self.onStateChanged?(error.localizedDescription)
                    self.stop()
                }
            }
        }
    }

    func stop(notify: Bool = true) {
        silenceTimer?.invalidate()
        silenceTimer = nil
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        request = nil
        task?.cancel()
        task = nil
        currentTranscript = ""
        if notify {
            onStopped?()
        }
    }

    private func finish(with transcript: String) {
        stop(notify: false)
        onFinalTranscript?(transcript)
        onStateChanged?("Captured spoken Command.")
    }

    private func bumpSilenceTimer() {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 1.4, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let transcript = self.currentTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
                if !transcript.isEmpty {
                    self.finish(with: transcript)
                } else {
                    self.stop()
                }
            }
        }
    }

    private func requestSpeechAuthorizationIfNeeded() async -> SFSpeechRecognizerAuthorizationStatus {
        await Self.requestSpeechAuthorizationIfNeeded()
    }

    private nonisolated static func requestSpeechAuthorizationIfNeeded() async -> SFSpeechRecognizerAuthorizationStatus {
        let current = SFSpeechRecognizer.authorizationStatus()
        if current != .notDetermined {
            return current
        }

        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    private func requestMicrophoneAuthorizationIfNeeded() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }

    private func describeSpeechAuthorization(_ status: SFSpeechRecognizerAuthorizationStatus) -> String {
        switch status {
        case .authorized:
            return "Enabled"
        case .denied:
            return "Denied"
        case .restricted:
            return "Restricted"
        case .notDetermined:
            return "Not requested"
        @unknown default:
            return "Unknown"
        }
    }

    private func describeMicrophoneAuthorization(_ granted: Bool) -> String {
        granted ? "Enabled" : "Denied"
    }
}
