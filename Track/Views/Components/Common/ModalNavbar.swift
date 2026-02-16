//
//  ModalNavbar.swift
//  Track
//
//  Modal navbar component displayed at the top of the dashboard sheet.
//  Contains search bar, transport mode filter icons, and settings button.
//  Styled to match Apple Maps modal design.
//

import SwiftUI
import CoreLocation
import Speech
import AVFoundation

struct ModalNavbar: View {
    @Binding var searchText: String
    @Binding var showSettings: Bool
    @Binding var selectedMode: TransportMode
    var lastUpdated: Date?
    
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
                    
                    // Clear button when text is present
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundColor(AppTheme.Colors.textSecondary)
                        }
                    }
                    
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
                .cornerRadius(12)
                
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
            .padding(.bottom, 10)
            
            // MARK: - Transport Mode Filter Icons
            ModeFilterStrip(selectedMode: $selectedMode)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
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

// MARK: - Mode Filter Strip

/// Compact icon-only transport mode filter strip
struct ModeFilterStrip: View {
    @Binding var selectedMode: TransportMode
    
    var body: some View {
        HStack(spacing: 0) {
            ForEach(TransportMode.allCases, id: \.self) { mode in
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        selectedMode = mode
                    }
                    HapticManager.impact(.light)
                } label: {
                    Image(systemName: mode.icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(selectedMode == mode ? .white : AppTheme.Colors.textSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 34)
                        .background(
                            selectedMode == mode
                                ? modeColor(for: mode)
                                : Color.clear
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .accessibilityLabel(mode.label)
                .accessibilityAddTraits(selectedMode == mode ? .isSelected : [])
            }
        }
        .padding(4)
        .background(AppTheme.Colors.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
    
    private func modeColor(for mode: TransportMode) -> Color {
        switch mode {
        case .nearby: return AppTheme.Colors.successGreen
        case .subway: return AppTheme.Colors.subwayBlack
        case .bus: return AppTheme.Colors.mtaBlue
        case .lirr: return AppTheme.CommuterRailColors.lirrBlue
        case .mnr: return AppTheme.CommuterRailColors.mnrBlue
        }
    }
}

#Preview {
    ModalNavbar(
        searchText: .constant(""),
        showSettings: .constant(false),
        selectedMode: .constant(.nearby),
        lastUpdated: Date()
    )
    .background(AppTheme.Colors.background)
}
