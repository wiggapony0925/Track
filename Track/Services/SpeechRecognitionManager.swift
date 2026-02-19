//
//  SpeechRecognitionManager.swift
//  Track
//
//  Shared speech-to-text manager used by the search bar and any
//  future voice input features. Centralises AVAudioEngine and
//  SFSpeechRecognizer handling so multiple views don't duplicate
//  the same boilerplate.
//

import Foundation
import Speech
import AVFoundation

@Observable
@MainActor
final class SpeechRecognitionManager {

    /// Whether the microphone is currently recording.
    private(set) var isRecording = false

    /// Callback invoked with the latest transcription text.
    var onTranscription: ((String) -> Void)?

    private var speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?

    /// Toggles recording on/off.
    func toggle() {
        if isRecording {
            stop()
        } else {
            start()
        }
    }

    /// Begins speech recognition after requesting authorisation.
    func start() {
        SFSpeechRecognizer.requestAuthorization { [weak self] authStatus in
            Task { @MainActor in
                guard authStatus == .authorized else { return }
                try? self?.beginRecognition()
            }
        }
    }

    /// Stops the current recording session and tears down audio resources.
    func stop() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        isRecording = false
    }

    // MARK: - Private

    private func beginRecognition() throws {
        guard speechRecognizer != nil else { return }
        recognitionTask?.cancel()
        recognitionTask = nil

        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        recognitionRequest = request

        let inputNode = audioEngine.inputNode

        recognitionTask = speechRecognizer?.recognitionTask(with: request) { [weak self] result, error in
            if let result = result {
                Task { @MainActor in
                    self?.onTranscription?(result.bestTranscription.formattedString)
                }
            }
            if error != nil || result?.isFinal == true {
                Task { @MainActor in
                    self?.stop()
                }
            }
        }

        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            request.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()
        isRecording = true
    }
}
