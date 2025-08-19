import SwiftUI
import AVFoundation
import Combine

struct SpeakerEnrollmentView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    
    @State private var speakerName: String = ""
    @State private var isRecording: Bool = false
    @State private var recordingDuration: TimeInterval = 0
    @State private var audioSamples: [Float] = []
    @State private var isProcessing: Bool = false
    @State private var showError: Bool = false
    @State private var errorMessage: String = ""
    @State private var enrollmentSuccess: Bool = false
    
    @StateObject private var audioRecorder = EnrollmentAudioRecorder()
    
    private let requiredDuration: TimeInterval = 10.0 // 10 seconds minimum
    private let timer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()
    
    var body: some View {
        NavigationView {
            VStack(spacing: 24) {
                // Header
                VStack(spacing: 8) {
                    Image(systemName: "person.wave.2.fill")
                        .font(.system(size: 60))
                        .foregroundColor(.accentColor)
                    
                    Text("Speaker Enrollment")
                        .font(.title)
                        .fontWeight(.bold)
                    
                    Text("Record your voice to be recognized in future recordings")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                .padding(.top)
                
                // Name Input
                VStack(alignment: .leading, spacing: 8) {
                    Text("Your Name")
                        .font(.headline)
                    
                    TextField("Enter your name", text: $speakerName)
                        .textFieldStyle(.roundedBorder)
                        .disabled(isRecording || isProcessing)
                }
                .padding(.horizontal)
                
                // Recording Instructions
                VStack(spacing: 12) {
                    if !isRecording && recordingDuration == 0 {
                        Text("Instructions")
                            .font(.headline)
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Speak naturally for at least 10 seconds", systemImage: "mic.fill")
                            Label("Introduce yourself and speak clearly", systemImage: "person.fill")
                            Label("Avoid background noise", systemImage: "speaker.slash.fill")
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding()
                        .background(Color(.systemGray6))
                        .cornerRadius(10)
                    }
                }
                .padding(.horizontal)
                
                // Recording Status
                if isRecording || recordingDuration > 0 {
                    VStack(spacing: 16) {
                        // Recording indicator
                        HStack(spacing: 8) {
                            if isRecording {
                                Image(systemName: "record.circle.fill")
                                    .foregroundColor(.red)
                                    .font(.title2)
                                    .symbolEffect(.pulse)
                            }
                            
                            Text(formatDuration(recordingDuration))
                                .font(.system(.title2, design: .monospaced))
                                .fontWeight(.semibold)
                        }
                        
                        // Progress bar
                        ProgressView(value: min(recordingDuration / requiredDuration, 1.0))
                            .progressViewStyle(LinearProgressViewStyle(tint: recordingDuration >= requiredDuration ? .green : .blue))
                            .frame(width: 200)
                        
                        if recordingDuration < requiredDuration {
                            Text("Keep speaking for \(Int(requiredDuration - recordingDuration)) more seconds")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Great! You can stop recording now")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
                    }
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(10)
                    .padding(.horizontal)
                }
                
                Spacer()
                
                // Action Buttons
                VStack(spacing: 16) {
                    // Record Button
                    Button(action: toggleRecording) {
                        HStack {
                            Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                            Text(isRecording ? "Stop Recording" : "Start Recording")
                        }
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(isRecording ? Color.red : Color.blue)
                        .cornerRadius(10)
                    }
                    .disabled(speakerName.isEmpty || isProcessing)
                    
                    // Enroll Button
                    if recordingDuration >= requiredDuration && !isRecording {
                        Button(action: enrollSpeaker) {
                            if isProcessing {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            } else {
                                HStack {
                                    Image(systemName: "checkmark.circle.fill")
                                    Text("Complete Enrollment")
                                }
                            }
                        }
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.green)
                        .cornerRadius(10)
                        .disabled(isProcessing)
                    }
                    
                    // Reset Button
                    if recordingDuration > 0 && !isRecording && !isProcessing {
                        Button(action: resetRecording) {
                            Text("Record Again")
                                .font(.subheadline)
                                .foregroundColor(.red)
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.bottom)
            }
            .navigationBarItems(
                leading: Button("Cancel") {
                    dismiss()
                }
            )
            .alert("Enrollment Successful", isPresented: $enrollmentSuccess) {
                Button("OK") {
                    dismiss()
                }
            } message: {
                Text("\(speakerName) has been enrolled successfully. Your voice will be recognized in future recordings.")
            }
            .alert("Enrollment Error", isPresented: $showError) {
                Button("OK") {
                    showError = false
                }
            } message: {
                Text(errorMessage)
            }
            .onReceive(timer) { _ in
                if isRecording {
                    recordingDuration += 0.1
                }
            }
        }
    }
    
    private func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }
    
    private func startRecording() {
        Task {
            let authorized = await audioRecorder.requestPermission()
            guard authorized else {
                errorMessage = "Microphone permission is required for speaker enrollment"
                showError = true
                return
            }
            
            await MainActor.run {
                isRecording = true
                recordingDuration = 0
                audioSamples = []
            }
            
            audioRecorder.startRecording { samples in
                self.audioSamples.append(contentsOf: samples)
            }
        }
    }
    
    private func stopRecording() {
        audioRecorder.stopRecording()
        isRecording = false
    }
    
    private func resetRecording() {
        recordingDuration = 0
        audioSamples = []
    }
    
    private func enrollSpeaker() {
        guard !audioSamples.isEmpty else { return }
        
        isProcessing = true
        
        Task {
            do {
                // Get the diarization manager from the app
                let diarizationManager = DiarizationManager(
                    config: AppSettings().diarizationConfig(),
                    isEnabled: true,
                    modelContext: modelContext
                )
                
                // Initialize if needed
                try await diarizationManager.initialize()
                
                // Enroll the speaker
                let speakerId = try await diarizationManager.enrollSpeaker(
                    name: speakerName,
                    audioSample: audioSamples
                )
                
                await MainActor.run {
                    isProcessing = false
                    if speakerId != nil {
                        enrollmentSuccess = true
                    } else {
                        errorMessage = "Failed to enroll speaker. Please try again."
                        showError = true
                    }
                }
            } catch {
                await MainActor.run {
                    isProcessing = false
                    errorMessage = "Enrollment failed: \(error.localizedDescription)"
                    showError = true
                }
            }
        }
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        let tenths = Int((duration.truncatingRemainder(dividingBy: 1)) * 10)
        return String(format: "%d:%02d.%d", minutes, seconds, tenths)
    }
}

// Simple audio recorder for enrollment
final class EnrollmentAudioRecorder: NSObject, ObservableObject {
    private var audioEngine: AVAudioEngine?
    private var inputNode: AVAudioInputNode?
    private var recordingFormat: AVAudioFormat?
    private var bufferCallback: (([Float]) -> Void)?
    
    func requestPermission() async -> Bool {
        #if os(iOS)
        if #available(iOS 17.0, *) {
            await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        } else {
            await withCheckedContinuation { continuation in
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        }
        #else
        await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
        #endif
    }
    
    func startRecording(bufferCallback: @escaping ([Float]) -> Void) {
        self.bufferCallback = bufferCallback
        
        // Configure audio session
        #if os(iOS)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: [])
            try session.setActive(true)
        } catch {
            print("Failed to configure audio session: \(error)")
            return
        }
        #endif
        
        audioEngine = AVAudioEngine()
        guard let audioEngine = audioEngine else { return }
        
        inputNode = audioEngine.inputNode
        guard let inputNode = inputNode else { return }
        let inputFormat = inputNode.outputFormat(forBus: 0)
        
        // Use the input node's actual format for the tap
        inputNode.installTap(
            onBus: 0,
            bufferSize: 1024,
            format: inputFormat
        ) { [weak self] buffer, _ in
            // Convert to mono float array at 16kHz if needed
            guard let channelData = buffer.floatChannelData else { return }
            
            let frameCount = Int(buffer.frameLength)
            let channelCount = Int(buffer.format.channelCount)
            
            var samples: [Float] = []
            
            // Handle multi-channel audio by averaging channels
            if channelCount == 1 {
                samples = Array(UnsafeBufferPointer(start: channelData[0], count: frameCount))
            } else {
                // Average multiple channels
                samples = [Float](repeating: 0, count: frameCount)
                for channel in 0..<channelCount {
                    let channelSamples = UnsafeBufferPointer(start: channelData[channel], count: frameCount)
                    for i in 0..<frameCount {
                        samples[i] += channelSamples[i]
                    }
                }
                // Divide by channel count to get average
                for i in 0..<frameCount {
                    samples[i] /= Float(channelCount)
                }
            }
            
            // If sample rate is not 16kHz, we need to resample
            if buffer.format.sampleRate != 16000 {
                // Simple downsampling by taking every Nth sample
                let ratio = Int(buffer.format.sampleRate / 16000)
                if ratio > 1 {
                    var downsampled: [Float] = []
                    for i in stride(from: 0, to: samples.count, by: ratio) {
                        downsampled.append(samples[i])
                    }
                    samples = downsampled
                }
            }
            
            self?.bufferCallback?(samples)
        }
        
        do {
            try audioEngine.start()
        } catch {
            print("Failed to start audio engine: \(error)")
        }
    }
    
    func stopRecording() {
        audioEngine?.stop()
        inputNode?.removeTap(onBus: 0)
        audioEngine = nil
        bufferCallback = nil
        
        // Deactivate audio session
        #if os(iOS)
        do {
            try AVAudioSession.sharedInstance().setActive(false)
        } catch {
            print("Failed to deactivate audio session: \(error)")
        }
        #endif
    }
}

#Preview {
    SpeakerEnrollmentView()
}