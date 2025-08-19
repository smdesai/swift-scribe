import Speech
import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import AVFoundation
import FluidAudio
import WhisperKit

struct ContentView: View {
    @Query(sort: \Memo.createdAt, order: .reverse) private var memos: [Memo]
    @State var selection: Memo?
    @State var currentMemo: Memo = Memo.blank()
    @State private var showingSettings = false
    @State private var isRecording = false  // Track recording state globally
    @State private var showingImportPicker = false
    @State private var isImporting = false
    @State private var importProgress: Double = 0.0
    @State private var importingFileName: String = ""
    @State private var importStartTime: Date? = nil
    @Environment(AppSettings.self) private var settings
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        NavigationSplitView {
            ZStack {
                List(selection: $selection) {
                    ForEach(memos) { memo in
                        NavigationLink(value: memo) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(LocalizedStringKey(memo.title))
                                    .font(.headline)
                                Text(memo.createdAt.formatted(date: .abbreviated, time: .omitted))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if !memo.text.characters.isEmpty {
                                    Text(
                                        String(memo.text.characters.prefix(50))
                                            + (memo.text.characters.count > 50 ? "..." : "")
                                    )
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                }
                            }
                        }
                    }
                    .onDelete(perform: deleteMemos)
                }
                .navigationTitle("Memos")
                .navigationSplitViewColumnWidth(min: 250, ideal: 250, max: 400)
                .toolbar {
                    #if os(iOS)
                        // Keep only settings and edit buttons in toolbar
                        ToolbarItemGroup(placement: .navigationBarTrailing) {
                            if !memos.isEmpty {
                                EditButton()
                            }

                            Button {
                                showingSettings = true
                            } label: {
                                Label("Settings", systemImage: "gearshape")
                            }
                        }
                    #elseif os(macOS)
                        // On macOS, settings are in the app menu, so only show the Add button
                        ToolbarItemGroup(placement: .primaryAction) {
                            if !memos.isEmpty && selection != nil {
                                Button {
                                    if let selection = selection {
                                        deleteMemo(selection)
                                    }
                                } label: {
                                    Label("Delete Memo", systemImage: "trash")
                                }
                                .foregroundColor(.red)
                            }

                            if !isRecording {
                                Menu {
                                    Button {
                                        addMemo()
                                    } label: {
                                        Label("New Recording", systemImage: "mic.circle")
                                    }
                                    
                                    Button {
                                        showingImportPicker = true
                                    } label: {
                                        Label("Import Audio File", systemImage: "doc.badge.plus")
                                    }
                                } label: {
                                    Label("New Memo", systemImage: "plus")
                                }
                            }
                        }
                    #endif
                }
                .toolbarBackground(.hidden)

                #if os(iOS)
                    // Floating New button at the bottom for iOS
                    if !isRecording {
                        VStack {
                            Spacer()
                            
                            HStack(spacing: 16) {
                                Button {
                                    showingImportPicker = true
                                } label: {
                                    Label("Import", systemImage: "doc.badge.plus")
                                        .font(.headline)
                                        .fontWeight(.semibold)
                                }
                                .buttonStyle(.glass)
                                .controlSize(.large)
                                .tint(Color(red: 0.36, green: 0.69, blue: 0.55))

                                Button {
                                    addMemo()
                                } label: {
                                    Label("New", systemImage: "plus.circle.fill")
                                        .font(.headline)
                                        .fontWeight(.semibold)
                                }
                                .buttonStyle(.glass)
                                .controlSize(.extraLarge)
                                .tint(Color(red: 0.36, green: 0.69, blue: 0.55))  // Using the app's green color
                            }
                            .padding(.bottom, 24)
                        }
                    }
                #endif
            }
        } detail: {
            if selection != nil {
                TranscriptView(memo: $currentMemo, isRecording: $isRecording)
            } else {
                Text("Select an item")
            }
        }
        .onChange(of: selection) {
            if let selection {
                currentMemo = selection
            }
        }
        #if os(iOS)
            .sheet(isPresented: $showingSettings) {
                SettingsView(settings: settings)
            }
        #endif
        .fileImporter(
            isPresented: $showingImportPicker,
            allowedContentTypes: [.audio, .mpeg4Audio, .mp3, .wav, .aiff],
            onCompletion: handleFileImport
        )
        .overlay {
            if isImporting {
                ImportingOverlay(
                    fileName: importingFileName,
                    progress: importProgress,
                    startTime: importStartTime
                )
            }
        }
    }

    private func addMemo() {
        let newMemo = Memo.blank()
        modelContext.insert(newMemo)
        selection = newMemo
        currentMemo = newMemo
    }

    private func deleteMemos(offsets: IndexSet) {
        for index in offsets {
            deleteMemo(memos[index])
        }
    }

    private func deleteMemo(_ memo: Memo) {
        if selection == memo {
            selection = nil
        }
        modelContext.delete(memo)
    }
    
    private func handleFileImport(result: Result<URL, any Error>) {
        switch result {
        case .success(let url):
            importAudioFile(from: url)
        case .failure(let error):
            print("Error importing file: \(error.localizedDescription)")
        }
    }
    
    private func importAudioFile(from url: URL) {
        // Start security-scoped access
        guard url.startAccessingSecurityScopedResource() else {
            print("Failed to access security-scoped resource")
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }
        
        // Copy file to app's documents directory
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let destinationURL = documentsPath.appendingPathComponent(url.lastPathComponent)
        
        do {
            // Copy file if it doesn't exist
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.copyItem(at: url, to: destinationURL)
            
            // Start transcription
            Task {
                await transcribeImportedFile(at: destinationURL, originalName: url.lastPathComponent)
            }
        } catch {
            print("Error copying file: \(error.localizedDescription)")
        }
    }
    
    @MainActor
    private func transcribeImportedFile(at url: URL, originalName: String) async {
        isImporting = true
        importingFileName = originalName
        importProgress = 0.0
        importStartTime = Date()
        
        // Create a new memo for the imported audio
        // Set isDone to true since this is a completed recording
        let newMemo = Memo(title: "Importing: \(originalName)", text: AttributedString(""), url: url, isDone: false)
        modelContext.insert(newMemo)
        
        // Create transcriber
        let transcriber = WhisperTranscriber()
        
        // Ensure WhisperKit model is loaded
        await WhisperKitManager.shared.ensureModelLoaded()
        
        // Update progress while ensuring model is loaded
        await MainActor.run {
            importProgress = 0.1
        }
        
        // Transcribe the file with real-time progress updates
        var transcriptionSegments: [TranscriptionSegment] = []
        
        await withCheckedContinuation { continuation in
            let progressCallback: @Sendable (Double) -> Void = { progress in
                Task { @MainActor in
                    // Map transcription progress (0-0.95) to overall progress (0.1-0.7)
                    // 0.1 = model loaded, 0.7 = transcription complete
                    importProgress = 0.1 + (progress * 0.6)
                }
            }
            
            transcriber.transcribeFile(
                path: url.path,
                progressCallback: progressCallback
            ) { segments in
                transcriptionSegments = segments
                continuation.resume()
            }
        }
        
        // Update progress after transcription completes
        await MainActor.run {
            importProgress = 0.7
        }
        
        // Combine all segments into text
        let fullText = transcriptionSegments.map { $0.text }.joined(separator: " ")
        newMemo.text = AttributedString(fullText)
        
        // Generate a better title from the first few words
        let words = fullText.split(separator: " ").prefix(10).joined(separator: " ")
        newMemo.title = words.isEmpty ? originalName : words
        
        // Mark as done since transcription is complete
        newMemo.isDone = true
        
        // Process diarization if enabled
        if settings.diarizationEnabled {
            await MainActor.run {
                importProgress = 0.8
            }
            
            // Initialize diarization manager
            let diarizationManager = DiarizationManager(
                config: settings.diarizationConfig(),
                isEnabled: true,
                enableRealTimeProcessing: false,
                modelContext: modelContext
            )
            
            // Apply settings
            diarizationManager.enableSpeakerMerging = settings.enableSpeakerMerging
            diarizationManager.speakerMergingThreshold = settings.speakerMergingThreshold
            
            do {
                // Initialize diarization
                try await diarizationManager.initialize()
                
                // Load and process audio file
                if let audioBuffer = extractAudioBuffer(from: url) {
                    print("Processing diarization for imported file...")
                    
                    // Process audio for diarization
                    await diarizationManager.processAudioBuffer(audioBuffer)
                    
                    // Update progress
                    await MainActor.run {
                        importProgress = 0.9
                    }
                    
                    // Finish processing and get results
                    if let diarizationResult = await diarizationManager.finishProcessing() {
                        print("Diarization completed with \(diarizationResult.segments.count) segments")
                        
                        // Update memo with diarization
                        newMemo.updateWithDiarizationResult(
                            diarizationResult,
                            transcribedText: fullText,
                            transcriptionSegments: transcriptionSegments,
                            in: modelContext
                        )
                        
                        print("Memo updated with \(newMemo.speakers(in: modelContext).count) speakers")
                    } else {
                        print("Diarization processing returned no results")
                    }
                } else {
                    print("Failed to extract audio buffer from imported file")
                }
            } catch {
                print("Diarization failed for imported file: \(error)")
            }
        }
        
        // Update progress
        await MainActor.run {
            importProgress = 0.95
        }
        
        // Save the memo
        try? modelContext.save()
        
        // Select the new memo
        selection = newMemo
        currentMemo = newMemo
        
        // Hide import overlay
        await MainActor.run {
            isImporting = false
            importProgress = 1.0
            importStartTime = nil
        }
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
