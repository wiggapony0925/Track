//
//  ModalNavbar.swift
//  Track
//
//  Modal navbar component displayed at the top of the dashboard sheet.
//  Contains search bar, settings, and drop pin buttons.
//  Styled to match Apple Maps modal design.
//

import SwiftUI
import CoreLocation
import Speech
import AVFoundation

struct ModalNavbar: View {
    @Binding var searchText: String
    @Binding var showSettings: Bool
    var lastUpdated: Date?
    var onDropPin: () -> Void
    
    // Speech recognition state
    @State private var isRecording = false
    @State private var speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    @State private var recognitionTask: SFSpeechRecognitionTask?
    @State private var audioEngine = AVAudioEngine()
    @State private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    
    var body: some View {
        VStack(spacing: 0) {
            // Search bar + buttons row
            HStack(spacing: 8) {
                // Search bar
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(AppTheme.Colors.textSecondary)
                    
                    TextField("Search trains, buses, stations…", text: $searchText)
                        .font(.system(size: 15, weight: .regular))
                        .foregroundColor(AppTheme.Colors.textPrimary)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    
                    // Mic button (inside search bar)
                    Button {
                        if isRecording {
                            stopRecording()
                        } else {
                            startRecording()
                        }
                    } label: {
                        Image(systemName: isRecording ? "mic.fill" : "mic.fill")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(isRecording ? AppTheme.Colors.alertRed : AppTheme.Colors.textSecondary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(AppTheme.Colors.cardBackground)
                .cornerRadius(10)
                
                // Drop pin button
                Button(action: onDropPin) {
                    Image(systemName: "mappin.and.ellipse")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundColor(AppTheme.Colors.mtaBlue)
                        .frame(width: 36, height: 36)
                        .background(AppTheme.Colors.cardBackground)
                        .clipShape(Circle())
                }
                .accessibilityLabel("Drop search pin")
                
                // Settings button
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundColor(AppTheme.Colors.textSecondary)
                        .frame(width: 36, height: 36)
                        .background(AppTheme.Colors.cardBackground)
                        .clipShape(Circle())
                }
                .accessibilityLabel("Settings")
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 16)
            
            // Last updated timestamp (moved to content area below navbar)
            if let lastUpdated = lastUpdated {
                HStack(spacing: 4) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 11, weight: .medium))
                    Text("Updated \(lastUpdated, style: .relative)")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(AppTheme.Colors.textSecondary)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
        }
        .background(AppTheme.Colors.background)
    }
    
    // MARK: - Speech Recognition
    
    private func startRecording() {
        SFSpeechRecognizer.requestAuthorization { authStatus in
            DispatchQueue.main.async {
                guard authStatus == .authorized else { return }
                
                do {
                    try startRecognition()
                } catch {
                    print("Speech recognition error: \(error.localizedDescription)")
                }
            }
        }
    }
    
    private func startRecognition() throws {
        recognitionTask?.cancel()
        recognitionTask = nil
        
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        
        let inputNode = audioEngine.inputNode
        guard let recognitionRequest = recognitionRequest else {
            throw NSError(domain: "SpeechRecognition", code: -1)
        }
        
        recognitionRequest.shouldReportPartialResults = true
        
        recognitionTask = speechRecognizer?.recognitionTask(with: recognitionRequest) { result, error in
            if let result = result {
                DispatchQueue.main.async {
                    self.searchText = result.bestTranscription.formattedString
                }
            }
            
            if error != nil || result?.isFinal == true {
                DispatchQueue.main.async {
                    self.stopRecording()
                }
            }
        }
        
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            recognitionRequest.append(buffer)
        }
        
        audioEngine.prepare()
        try audioEngine.start()
        isRecording = true
    }
    
    private func stopRecording() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        isRecording = false
    }
}

#Preview {
    ModalNavbar(
        searchText: .constant(""),
        showSettings: .constant(false),
        lastUpdated: Date(),
        onDropPin: {}
    )
    .background(AppTheme.Colors.background)
}
