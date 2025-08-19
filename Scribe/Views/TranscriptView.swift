import AVFoundation
import Foundation
import SwiftUI
import SwiftData
import FluidAudio
import WhisperKit

struct TranscriptView: View {
    @Binding var memo: Memo
    @Binding var isRecording: Bool
    @State var isPlaying = false
    @State var isGenerating = false

    @StateObject var speechTranscriber = WhisperTranscriber()
    @State var diarizationManager: DiarizationManager

    @State var downloadProgress = 0.0

    @State var currentPlaybackTime = 0.0

    @State var timer: Timer?

    // Recording timer state
    @State var recordingStartTime: Date?
    @State var recordingDuration: TimeInterval = 0
    @State var recordingTimer: Timer?

    // Enhancement state removed - AI features removed
    @State var enhancementError: String?
    
    // Speaker view state
    @State var showingSpeakerView = false
    @State var showingSpeakerManagement = false
    @State var isProcessingSpeakers = false
    @State var speakerProcessingProgress: Double = 0.0
    
    // Cached speaker data to prevent repeated fetches
    @State private var cachedSpeakers: [Speaker] = []
    @State private var cachedFormattedTranscript: AttributedString = AttributedString("")
    @State private var lastSpeakerDataUpdate: Date?
    @State private var speakerNamesHash: Int = 0

    @Environment(\.modelContext) private var modelContext
    @Environment(AppSettings.self) private var settings
    
    // Query all speakers to watch for changes
    @Query private var allSpeakers: [Speaker]
    
    init(memo: Binding<Memo>, isRecording: Binding<Bool>) {
        self._memo = memo
        self._isRecording = isRecording
        // WhisperTranscriber is initialized as @StateObject above
        
        // Initialize with default config - will be properly configured in setupOnAppear()
        diarizationManager = DiarizationManager(config: DiarizerConfig(), modelContext: nil)
    }

    var body: some View {
        mainContent
            .navigationTitle(memo.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(isRecording)
            #endif
            .toolbar { toolbarContent }
            .onChange(of: isRecording) { oldValue, newValue in
                handleRecordingChange(oldValue: oldValue, newValue: newValue)
            }
            .onChange(of: speechTranscriber.currentTranscribedText) { oldText, newText in
                if !newText.isEmpty {
                    memo.text = AttributedString(newText)
                }
            }
            .onChange(of: isPlaying) {
                handlePlayback()
            }
            .onChange(of: showingSpeakerView) { oldValue, newValue in
                if newValue && memo.hasSpeakerData {
                    // Update cache when switching to speaker view
                    updateCachedSpeakerData()
                }
            }
            .onChange(of: settings.combineSameSpeakerSegments) { _, _ in
                if showingSpeakerView && memo.hasSpeakerData {
                    updateCachedSpeakerData()
                }
            }
            .onChange(of: settings.mergePartialSentences) { _, _ in
                if showingSpeakerView && memo.hasSpeakerData {
                    updateCachedSpeakerData()
                }
            }
            .onChange(of: allSpeakers) { _, _ in
                // Update cached data when any speaker changes (e.g., name or color)
                if showingSpeakerView && memo.hasSpeakerData {
                    updateCachedSpeakerData()
                }
            }
            .onAppear(perform: setupOnAppear)
            .onDisappear(perform: cleanupOnDisappear)
            .alert("Enhancement Error", isPresented: .constant(enhancementError != nil)) {
                Button("OK") {
                    enhancementError = nil
                }
            } message: {
                if let error = enhancementError {
                    Text(error)
                }
            }
            .sheet(isPresented: $showingSpeakerManagement, onDismiss: {
                // Refresh cached speaker data when management view closes
                if memo.hasSpeakerData {
                    updateCachedSpeakerData()
                }
            }) {
                SpeakerManagementView()
            }
    }
    
    @ViewBuilder
    private var mainContent: some View {
        ZStack {
            VStack(spacing: 0) {
                // Main content
                Group {
                    if !memo.isDone {
                        liveRecordingView
                    } else {
                        if memo.hasSpeakerData && showingSpeakerView {
                            speakerView
                        } else {
                            playbackView
                        }
                    }
                }

                // Add padding at bottom for floating buttons
                #if os(iOS)
                    Spacer().frame(height: 100)
                #else
                    Spacer()
                #endif
            }
            #if os(macOS)
                .padding(20)
            #endif

            // Floating buttons at the bottom for iOS
            #if os(iOS)
                VStack {
                    Spacer()
                    bottomButtonBar
                }
                .ignoresSafeArea(.keyboard)
            #endif
        }
    }
    
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        #if os(iOS)
            ToolbarItem(placement: .principal) {
                VStack(spacing: 2) {
                    Text(memo.title)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: 200)

                    if memo.isDone {
                        Text(memo.createdAt.formatted(date: .abbreviated, time: .omitted))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        #else
            macOSToolbarContent
        #endif
    }
    
    #if os(macOS)
    @ToolbarContentBuilder
    private var macOSToolbarContent: some ToolbarContent {
        // View controls
        if memo.isDone && memo.hasSpeakerData {
            ToolbarItem {
                speakerViewToggleButton
            }
            
            ToolbarItem {
                Button {
                    showingSpeakerManagement = true
                } label: {
                    Label("Manage Speakers", systemImage: "person.2.badge.gearshape")
                }
                .help("Manage speaker names and settings")
            }
        }

        ToolbarSpacer(.fixed)

        // Recording control
        if !memo.isDone {
            ToolbarItem {
                recordButton
            }
        }

        ToolbarSpacer(.fixed)

        // Playback control
        if memo.isDone {
            ToolbarItem {
                playButton
            }
        }

        ToolbarSpacer(.fixed)
    }
    #endif
    
    private func handleRecordingChange(oldValue: Bool, newValue: Bool) {

        if newValue == true {
            startRecording()
        } else {
            stopRecording()
        }
    }
    
    private func startRecording() {
        // Start recording timer
        recordingStartTime = Date()
        recordingDuration = 0
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            Task { @MainActor in
                if let startTime = recordingStartTime {
                    recordingDuration = Date().timeIntervalSince(startTime)
                }
            }
        }

        // If restarting recording on an existing memo, reset the transcriber
        if memo.isDone {
            memo.isDone = false
            speechTranscriber.resetState()
        }
        
        // Start recording with WhisperTranscriber
        Task {
            // Set up audio session
            do {
                try setUpAudioSession()
            } catch {
                await MainActor.run {
                    isRecording = false
                    enhancementError = "Failed to set up audio: \(error.localizedDescription)"
                }
                return
            }
            
            // Start recording
            speechTranscriber.toggleRecording(shouldLoop: true)
        }
    }
    
    private func stopRecording() {
        // Stop recording timer
        recordingTimer?.invalidate()
        recordingTimer = nil
        recordingStartTime = nil
        recordingDuration = 0

        // Stop recording
        Task {
            if speechTranscriber.isRecording {
                speechTranscriber.toggleRecording(shouldLoop: false)
                speechTranscriber.finalizeText()
                
                // Wait for transcription and diarization to complete
                await speechTranscriber.waitForTranscriptionCompletion()
            }
            
            
            // Process diarization if enabled - get the stored result from WhisperTranscriber
            if settings.diarizationEnabled, let diarizationResult = speechTranscriber.lastDiarizationResult {
                
                // Apply diarization results to memo with transcription segments for proper timestamp extraction
                memo.updateWithDiarizationResult(
                    diarizationResult, 
                    transcribedText: speechTranscriber.currentTranscribedText, 
                    transcriptionSegments: speechTranscriber.currentTranscriptionSegments,
                    in: modelContext
                )
                
                // Update cached speaker data after diarization
                updateCachedSpeakerData()
                
            }
            
            // Mark memo as done after recording stops
            memo.isDone = true
            
            // Generate title after recording stops
            await generateTitleIfNeeded()
        }
    }
    
    private func setupOnAppear() {
        // Re-initialize diarization manager with modelContext and settings
        diarizationManager = DiarizationManager(
            config: settings.diarizationConfig(),
            isEnabled: settings.diarizationEnabled,
            enableRealTimeProcessing: settings.enableRealTimeProcessing,
            modelContext: modelContext,
            settings: settings
        )
        
        // Apply advanced settings from FluidAudio integration
        diarizationManager.enableSpeakerMerging = settings.enableSpeakerMerging
        diarizationManager.speakerMergingThreshold = settings.speakerMergingThreshold
        diarizationManager.chunkDuration = settings.chunkDuration
        diarizationManager.chunkOverlap = settings.chunkOverlap
        diarizationManager.combineSameSpeakerSegments = settings.combineSameSpeakerSegments
        diarizationManager.mergePartialSentences = settings.mergePartialSentences
        
        // Set diarization manager on the transcriber
        speechTranscriber.diarizationManager = diarizationManager
        
        // Initialize diarization if enabled
        if settings.diarizationEnabled {
            Task {
                try? await diarizationManager.initialize()
                // Load known/enrolled speakers for recognition
                await diarizationManager.loadKnownSpeakers()
            }
        }
        
        // Update cached speaker data if available
        updateCachedSpeakerData()
        
        // Ensure WhisperKit model is loaded
        Task {
            await WhisperKitManager.shared.ensureModelLoaded()
        }
    }
    
    private func cleanupOnDisappear() {
        // Clean up timers
        timer?.invalidate()
        timer = nil
        recordingTimer?.invalidate()
        recordingTimer = nil
    }

    // MARK: - Bottom Button Bar for iOS

    #if os(iOS)
        @ViewBuilder
        private var bottomButtonBar: some View {
            HStack(spacing: 16) {
                // Recording/Stop button - always visible when recording
                if !memo.isDone {
                    recordButtonLarge
                } else {
                    // View toggle buttons
                    if memo.hasSpeakerData {
                        HStack(spacing: 16) {
                            Spacer()
                            
                            // Transcript/Speakers toggle
                            speakerViewToggleButtonCompact
                            
                            // Manage button
                            Button {
                                showingSpeakerManagement = true
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "person.2.badge.gearshape")
                                        .font(.callout)
                                    Text("Manage")
                                        .font(.callout)
                                        .fontWeight(.semibold)
                                }
                            }
                            .buttonStyle(.glass)
                            .controlSize(.regular)
                            .tint(.purple)
                            
                            Spacer()
                        }
                    } else {
                        Spacer()
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color.clear)
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }

        @ViewBuilder
        private var recordButtonLarge: some View {
            let isModelLoaded = WhisperKitManager.shared.isModelLoaded
            
            Button {
                if isModelLoaded {
                    handleRecordingButtonTap()
                }
            } label: {
                HStack(spacing: 12) {
                    if !isModelLoaded {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text(WhisperKitManager.shared.isModelLoaded ? "Ready" : "Loading...")
                            .font(.headline)
                            .fontWeight(.semibold)
                    } else {
                        Label(
                            isRecording ? "Stop Recording" : "Start Recording",
                            systemImage: isRecording ? "stop.circle.fill" : "record.circle.fill"
                        )
                        .font(.headline)
                        .fontWeight(.semibold)

                        if isRecording {
                            Text(formatDuration(recordingDuration))
                                .font(.headline)
                                .fontWeight(.semibold)
                                .monospacedDigit()
                        }
                    }
                }
            }
            .buttonStyle(.glass)
            .controlSize(.extraLarge)
            .tint(isModelLoaded ? (isRecording ? .red : Color(red: 0.36, green: 0.69, blue: 0.55)) : .gray)
            .disabled(!isModelLoaded)
        }

        
        @ViewBuilder
        private var speakerViewToggleButtonCompact: some View {
            Button {
                withAnimation(.smooth(duration: 0.3)) {
                    showingSpeakerView.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: showingSpeakerView ? "doc.plaintext" : "person.2")
                        .font(.callout)
                    Text(showingSpeakerView ? "Transcript" : "Speakers")
                        .font(.callout)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                }
            }
            .buttonStyle(.glass)
            .controlSize(.regular)
            .tint(showingSpeakerView ? .gray : .blue)
        }

    #endif

    
    // MARK: - Speaker View
    
    @ViewBuilder
    private var speakerView: some View {
        // Use cached speakers instead of fetching every time
        let speakers = cachedSpeakers
        
        VStack(alignment: .leading, spacing: 0) {
            #if os(iOS)
                // Simplified header for iOS
                HStack(spacing: 8) {
                    Image(systemName: "person.2.fill")
                        .font(.body)
                        .foregroundStyle(.blue)

                    Text("Speakers")
                        .font(.headline)
                        .foregroundStyle(.primary)

                    Spacer()
                    
                    // Speaker count badge
                    if !speakers.isEmpty {
                        Text("\(speakers.count)")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.blue, in: Capsule())
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            #endif

            #if os(macOS)
                // Header section with better spacing
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        Image(systemName: "person.2.fill")
                            .font(.title2)
                            .foregroundStyle(.blue)
                            .symbolRenderingMode(.monochrome)

                        Text("Speaker Diarization")
                            .font(.title2)
                            .fontWeight(.semibold)
                            .foregroundStyle(.primary)

                        Spacer()
                        
                        // Speaker count and processing info
                        if !speakers.isEmpty {
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("\(speakers.count) speakers")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("\(memo.speakerSegments.count) segments")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 20)
            #endif

            // Speaker transcript content
            Group {
                if memo.hasSpeakerData {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            // Speaker legend
                            speakerLegend
                            
                            Divider()
                            
                            // Speaker-segmented transcript (cached)
                            Text(cachedFormattedTranscript)
                                .font(.body)
                                .lineSpacing(6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                #if os(iOS)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 8)
                                #else
                                    .padding(.horizontal, 20)
                                    .padding(.vertical, 16)
                                #endif
                                .textSelection(.enabled)
                        }
                    }
                    #if os(macOS)
                        .padding(.horizontal, 16)
                    #endif
                    .scrollEdgeEffectStyle(.soft, for: .all)
                } else {
                    // No speaker data state
                    VStack(spacing: 20) {
                        Image(systemName: "person.2.slash")
                            .font(.system(size: 48))
                            .foregroundStyle(.secondary)

                        VStack(spacing: 8) {
                            Text("No Speaker Data")
                                .font(.headline)
                                .foregroundStyle(.primary)

                            Text("Speaker diarization was not performed for this recording")
                                .font(.body)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        #if os(macOS)
            .background(.background.secondary.opacity(0.3))
        #endif
    }
    
    @ViewBuilder
    private var speakerLegend: some View {
        // Use cached speakers
        let speakers = cachedSpeakers
        
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Speakers")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                
                Spacer()
                
                Button {
                    showingSpeakerManagement = true
                } label: {
                    Label("Manage", systemImage: "pencil.circle")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
            }
            
            // Use the cached speakers
            LazyVGrid(columns: [
                GridItem(.adaptive(minimum: 150))
            ], spacing: 8) {
                ForEach(speakers, id: \.id) { speaker in
                    SpeakerBadge(
                        speaker: speaker,
                        confidence: speaker.averageConfidence > 0 ? speaker.averageConfidence : nil
                    )
                }
            }
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Individual Toolbar Buttons

    @ViewBuilder
    private var playButton: some View {
        Button {
            handlePlayButtonTap()
        } label: {
            Label(
                isPlaying ? "Pause" : "Play",
                systemImage: isPlaying ? "pause.fill" : "play.fill"
            )
        }
        .buttonStyle(.glass)
    }

    @ViewBuilder
    private var recordButton: some View {
        let isModelLoaded = WhisperKitManager.shared.isModelLoaded
        
        Button {
            if isModelLoaded {
                handleRecordingButtonTap()
            }
        } label: {
            HStack(spacing: 8) {
                if !isModelLoaded {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text(WhisperKitManager.shared.isModelLoaded ? "Ready" : "Loading...")
                        .font(.caption)
                } else {
                    Label(
                        isRecording ? "Stop" : "Record",
                        systemImage: isRecording ? "stop.fill" : "record.circle"
                    )

                    if isRecording {
                        Text(formatDuration(recordingDuration))
                            .font(.body)
                            .monospacedDigit()
                    }
                }
            }
        }
        .tint(isModelLoaded ? (isRecording ? .red : Color(red: 0.36, green: 0.69, blue: 0.55)) : .gray)
        .disabled(!isModelLoaded)
    }

    
    @ViewBuilder
    private var speakerViewToggleButton: some View {
        Button {
            withAnimation(.smooth(duration: 0.3)) {
                showingSpeakerView.toggle()
            }
        } label: {
            Label(
                showingSpeakerView ? "Transcript" : "Speakers",
                systemImage: showingSpeakerView ? "doc.plaintext.fill" : "person.2.fill"
            )
        }
        .buttonStyle(.glass)
    }


    @ViewBuilder
    var liveRecordingView: some View {
        ScrollView {
            VStack(alignment: .leading) {
                if speechTranscriber.currentTranscribedText.isEmpty
                {
                    VStack(spacing: 20) {
                        // Recording indicator with glass effect
                        VStack(spacing: 12) {
                            Image(systemName: "mic.fill")
                                .font(.system(size: 48))
                                .foregroundStyle(.red)
                                .symbolEffect(.pulse, isActive: isRecording)

                            // Recording timer
                            Text(formatDuration(recordingDuration))
                                .font(.system(size: 32, weight: .medium, design: .monospaced))
                                .foregroundStyle(.primary)

                            Text("Listening...")
                                .font(.title2)
                                .fontWeight(.medium)
                                .foregroundStyle(.primary)

                            Text("Start speaking into the microphone")
                                .font(.body)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .padding(.vertical, 32)
                        .padding(.horizontal, 24)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    #if os(iOS)
                        .padding(.top, 40)
                    #else
                        .padding()
                    #endif
                } else {
                    VStack(alignment: .leading, spacing: 16) {
                        // Live transcript with glass container
                        Text(speechTranscriber.currentTranscribedText)
                        .font(.body)
                        .lineSpacing(4)
                        #if os(iOS)
                            .padding(.horizontal, 20)
                            .padding(.top, 12)
                        #else
                            .padding(20)
                        #endif
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                Spacer()
            }
        }
        .scrollEdgeEffectStyle(.soft, for: .all)
    }

    @ViewBuilder
    var playbackView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                #if os(macOS)
                    Text("Transcript")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                #endif
                
                // Show speaker detection option if no speaker data exists
                if !memo.hasSpeakerData && memo.url != nil && settings.diarizationEnabled && !isProcessingSpeakers {
                    VStack(spacing: 12) {
                        HStack {
                            Image(systemName: "person.2.circle")
                                .font(.title2)
                                .foregroundStyle(.blue)
                            
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Speaker Detection Available")
                                    .font(.headline)
                                Text("Process this audio to identify different speakers")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            
                            Spacer()
                            
                            Button {
                                Task {
                                    await processSpeakers()
                                }
                            } label: {
                                Label("Process", systemImage: "waveform.badge.magnifyingglass")
                                    .font(.callout)
                                    .fontWeight(.semibold)
                            }
                            .buttonStyle(.glass)
                            .controlSize(.regular)
                            .tint(.blue)
                        }
                        .padding()
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.blue.opacity(0.1))
                        )
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                } else if isProcessingSpeakers {
                    VStack(spacing: 12) {
                        HStack {
                            ProgressView()
                                .scaleEffect(0.8)
                            Text("Processing speakers...")
                                .font(.callout)
                            Spacer()
                            Text("\(Int(speakerProcessingProgress * 100))%")
                                .font(.caption)
                                .fontDesign(.monospaced)
                                .foregroundStyle(.secondary)
                        }
                        
                        ProgressView(value: speakerProcessingProgress)
                            .progressViewStyle(LinearProgressViewStyle())
                    }
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.blue.opacity(0.1))
                    )
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }

                Text(memo.textBrokenUpByParagraphs())
                    .font(.body)
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    #if os(iOS)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                    #else
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    #endif
                    .textSelection(.enabled)
            }
        }
        .scrollEdgeEffectStyle(.soft, for: .all)
    }

    private var progressView: some View {
        ProgressView(value: downloadProgress, total: 100)
            .progressViewStyle(LinearProgressViewStyle())
            .opacity(downloadProgress > 0 && downloadProgress < 100 ? 1 : 0)
            .animation(.easeInOut(duration: 0.3), value: downloadProgress)
    }
}

// MARK: - TranscriptView Extension

extension TranscriptView {

    // Format duration for display
    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    func handlePlayback() {
        guard memo.url != nil else {
            return
        }

        if isPlaying {
            // TODO: Implement playback functionality
        } else {
            currentPlaybackTime = 0.0
            timer = nil
        }
    }
    
    #if os(iOS)
    func setUpAudioSession() throws {
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playAndRecord, mode: .spokenAudio)
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
    }
    #else
    // macOS audio session setup
    func setUpAudioSession() throws {
        
        // Request microphone access
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            break
        case .denied, .restricted:
            throw TranscriptionError.failedToSetupRecognitionStream
        @unknown default:
            throw TranscriptionError.failedToSetupRecognitionStream
        }
    }
    #endif

    func handleRecordingButtonTap() {
        isRecording.toggle()
    }

    func handlePlayButtonTap() {
        isPlaying.toggle()
    }


    @MainActor
    private func generateTitleIfNeeded() async {
        // Only update title if we have content and the current title is generic
        guard !memo.text.characters.isEmpty,
            memo.title == "New Memo" || memo.title.isEmpty
        else {
            return
        }

        // Generate a simple title based on the first few words of the transcript
        let text = String(memo.text.characters)
        let words = text.split(separator: " ").prefix(5).joined(separator: " ")
        memo.title = words.isEmpty ? "New Memo" : words
    }

    @ViewBuilder func textScrollView(attributedString: AttributedString) -> some View {
        ScrollView {
            VStack(alignment: .leading) {
                textWithHighlighting(attributedString: attributedString)
                Spacer()
            }
        }
    }

    func attributedStringWithCurrentValueHighlighted(attributedString: AttributedString)
        -> AttributedString
    {
        var copy = attributedString
        copy.runs.forEach { run in
            if shouldBeHighlighted(attributedStringRun: run) {
                let range = run.range
                copy[range].backgroundColor = .mint.opacity(0.2)
            }
        }
        return copy
    }

    func shouldBeHighlighted(attributedStringRun: AttributedString.Runs.Run) -> Bool {
        guard isPlaying else { return false }
        let start = attributedStringRun.audioTimeRange?.start.seconds
        let end = attributedStringRun.audioTimeRange?.end.seconds
        guard let start, let end else {
            return false
        }

        if end < currentPlaybackTime { return false }

        if start < currentPlaybackTime, currentPlaybackTime < end {
            return true
        }

        return false
    }

    @ViewBuilder func textWithHighlighting(attributedString: AttributedString) -> some View {
        Group {
            Text(attributedStringWithCurrentValueHighlighted(attributedString: attributedString))
                .font(.body)
        }
    }
    
    // MARK: - Speaker Processing
    
    private func updateCachedSpeakerData() {
        // Only update if we have speaker data
        guard memo.hasSpeakerData else {
            cachedSpeakers = []
            cachedFormattedTranscript = memo.textBrokenUpByParagraphs()
            return
        }
        
        // Clear the memo's cached merged segments to force regeneration
        memo.cachedMergedSegments = nil
        memo.cachedMergedSegmentsHash = 0
        
        // Update cached speakers (fetch fresh from database)
        cachedSpeakers = memo.speakers(in: modelContext)
        
        // Calculate hash of speaker names to detect changes
        let newHash = cachedSpeakers.map { $0.name }.joined().hashValue
        
        // Update cached formatted transcript (will use fresh speaker names)
        cachedFormattedTranscript = memo.formattedTranscriptWithSpeakers(
            context: modelContext,
            combineSameSpeaker: settings.combineSameSpeakerSegments,
            mergePartialSentences: settings.mergePartialSentences
        )
        
        // Mark update time and hash
        lastSpeakerDataUpdate = Date()
        speakerNamesHash = newHash
    }
    
    @MainActor
    private func processSpeakers() async {
        guard let audioURL = memo.url else { return }
        
        isProcessingSpeakers = true
        speakerProcessingProgress = 0.0
        
        // Initialize diarization manager
        let localDiarizationManager = DiarizationManager(
            config: settings.diarizationConfig(),
            isEnabled: true,
            enableRealTimeProcessing: false,
            modelContext: modelContext
        )
        
        // Apply settings
        localDiarizationManager.enableSpeakerMerging = settings.enableSpeakerMerging
        localDiarizationManager.speakerMergingThreshold = settings.speakerMergingThreshold
        
        do {
            // Initialize diarization
            speakerProcessingProgress = 0.1
            try await localDiarizationManager.initialize()
            speakerProcessingProgress = 0.3
            
            // Extract audio buffer
            if let audioBuffer = extractAudioBuffer(from: audioURL) {
                speakerProcessingProgress = 0.4
                
                // Process audio for diarization
                await localDiarizationManager.processAudioBuffer(audioBuffer)
                speakerProcessingProgress = 0.6
                
                // Re-transcribe to get proper segments with timestamps
                speakerProcessingProgress = 0.65
                let transcriber = WhisperTranscriber()
                
                // Ensure model is loaded
                await WhisperKitManager.shared.ensureModelLoaded()
                
                speakerProcessingProgress = 0.75
                
                // Get transcription segments with timestamps
                var transcriptionSegments: [TranscriptionSegment] = []
                await withCheckedContinuation { continuation in
                    transcriber.transcribeFile(path: audioURL.path) { segments in
                        transcriptionSegments = segments
                        continuation.resume()
                    }
                }
                
                speakerProcessingProgress = 0.85
                
                // Finish processing and get results
                if let diarizationResult = await localDiarizationManager.finishProcessing() {
                    speakerProcessingProgress = 0.9
                    
                    // Get full text from transcription
                    let fullText = transcriptionSegments.map { $0.text }.joined(separator: " ")
                    
                    // Update memo with diarization using proper transcription segments
                    memo.updateWithDiarizationResult(
                        diarizationResult,
                        transcribedText: fullText,
                        transcriptionSegments: transcriptionSegments,
                        in: modelContext
                    )
                    
                    // Also update the memo text if it differs
                    if fullText != String(memo.text.characters) {
                        memo.text = AttributedString(fullText)
                    }
                    
                    // Save changes
                    try? modelContext.save()
                    
                    speakerProcessingProgress = 1.0
                    
                    // Update cached speaker data after processing
                    updateCachedSpeakerData()
                    
                    // Show speaker view after processing
                    if memo.hasSpeakerData {
                        showingSpeakerView = true
                    }
                }
            }
        } catch {
            print("Failed to process speakers: \(error)")
            enhancementError = "Failed to process speakers: \(error.localizedDescription)"
        }
        
        isProcessingSpeakers = false
    }
    
    private func extractAudioBuffer(from url: URL) -> AVAudioPCMBuffer? {
        do {
            // Create an audio file from the URL
            let audioFile = try AVAudioFile(forReading: url)
            let format = audioFile.processingFormat
            let frameCount = UInt32(audioFile.length)
            
            // Create a buffer to hold the audio data
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
                print("Failed to create audio buffer")
                return nil
            }
            
            // Read the audio file into the buffer
            try audioFile.read(into: buffer)
            buffer.frameLength = frameCount
            
            // Convert to 16kHz mono if needed (for diarization)
            if format.sampleRate != 16000 || format.channelCount != 1 {
                return convertTo16kHzMono(buffer: buffer)
            }
            
            return buffer
        } catch {
            print("Error extracting audio buffer: \(error)")
            return nil
        }
    }
    
    private func convertTo16kHzMono(buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let format16k = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1) else {
            return nil
        }
        
        // If already in the correct format, return as is
        if buffer.format.sampleRate == 16000 && buffer.format.channelCount == 1 {
            return buffer
        }
        
        // Create a converter
        guard let converter = AVAudioConverter(from: buffer.format, to: format16k) else {
            return nil
        }
        
        // Calculate the output frame capacity - need to account for potential upsampling
        // Add some buffer to ensure we have enough space
        let conversionRatio = 16000.0 / buffer.format.sampleRate
        let outputFrameCapacity = UInt32(ceil(Double(buffer.frameLength) * conversionRatio * 1.1))
        
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: format16k, frameCapacity: outputFrameCapacity) else {
            return nil
        }
        
        // Use @unchecked Sendable to handle the conversion state
        final class ConversionState: @unchecked Sendable {
            var inputProvided = false
            let buffer: AVAudioPCMBuffer
            
            init(buffer: AVAudioPCMBuffer) {
                self.buffer = buffer
            }
        }
        
        let state = ConversionState(buffer: buffer)
        
        let inputBlock: AVAudioConverterInputBlock = { inNumPackets, outStatus in
            if state.inputProvided {
                outStatus.pointee = .noDataNow
                return nil
            }
            state.inputProvided = true
            outStatus.pointee = .haveData
            return state.buffer
        }
        
        var error: NSError?
        let status = converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)
        
        if status == .error {
            print("Conversion error: \(error?.localizedDescription ?? "Unknown")")
            // If conversion fails, try a simpler approach
            return fallbackConversion(buffer: buffer, to: format16k)
        }
        
        return outputBuffer
    }
    
    private func fallbackConversion(buffer: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        // Simple fallback that just creates a buffer without conversion
        // This will at least prevent crashes even if audio quality isn't perfect
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameLength) else {
            return nil
        }
        
        // Copy what we can
        let frameCount = min(buffer.frameLength, outputBuffer.frameCapacity)
        outputBuffer.frameLength = frameCount
        
        if let inputChannelData = buffer.floatChannelData,
           let outputChannelData = outputBuffer.floatChannelData {
            // Simple copy of first channel
            for frame in 0..<Int(frameCount) {
                outputChannelData[0][frame] = inputChannelData[0][frame]
            }
        }
        
        return outputBuffer
    }
}
