import SwiftUI
import Foundation
@preconcurrency import WhisperKit
import AVFoundation
import CoreML
import Combine
import FluidAudio

@MainActor
class WhisperTranscriber: ObservableObject {
    private var whisperKit: WhisperKit? {
        return WhisperKitManager.shared.getWhisperKit()
    }
    @Published public var isRecording: Bool = false
    @Published public var isTranscribing: Bool = false
    public var currentText: String = ""
    private var shouldRestartRecording: Bool = false
    var currentChunks: [Int: (chunkText: [String], fallbacks: Int)] = [:]

    private var transcriptionTask: Task<Void, Never>? = nil
    @Published public var currentTranscribedText: String = ""
    @Published public var currentTranscriptionSegments: [TranscriptionSegment] = []
    
    // Diarization support
    var diarizationManager: DiarizationManager?
    private var audioProcessor: AVAudioEngine?
    @Published var lastDiarizationResult: DiarizationResult?

    // MARK: Model management

    @AppStorage("selectedAudioInput") private var selectedAudioInput: String = "No Audio Input"
    @AppStorage("selectedModel") public var selectedModel: String = WhisperKit.recommendedModels().default // "openai_whisper-base"
    @AppStorage("selectedTab") private var selectedTab: String = "Transcribe"
    @AppStorage("selectedTask") private var selectedTask: String = "translate"
    @AppStorage("selectedLanguage") private var selectedLanguage: String = "english"
    @AppStorage("repoName") private var repoName: String = "argmaxinc/whisperkit-coreml"
    @AppStorage("enableTimestamps") private var enableTimestamps: Bool = true
    @AppStorage("enablePromptPrefill") private var enablePromptPrefill: Bool = true
    @AppStorage("enableCachePrefill") private var enableCachePrefill: Bool = true
    @AppStorage("enableSpecialCharacters") private var enableSpecialCharacters: Bool = false
    @AppStorage("enableEagerDecoding") private var enableEagerDecoding: Bool = false
    @AppStorage("enableDecoderPreview") private var enableDecoderPreview: Bool = true
    @AppStorage("temperatureStart") private var temperatureStart: Double = 0
    @AppStorage("fallbackCount") private var fallbackCount: Double = 5
    @AppStorage("compressionCheckWindow") private var compressionCheckWindow: Double = 20
    @AppStorage("sampleLength") private var sampleLength: Double = 224
    @AppStorage("silenceThreshold") private var silenceThreshold: Double = 0.3
    @AppStorage("realtimeDelayInterval") private var realtimeDelayInterval: Double = 1
    @AppStorage("useVAD") private var useVAD: Bool = true
    @AppStorage("tokenConfirmationsNeeded") private var tokenConfirmationsNeeded: Double = 2
    @AppStorage("concurrentWorkerCount") private var concurrentWorkerCount: Int = 4
    @AppStorage("chunkingStrategy") private var chunkingStrategy: ChunkingStrategy = .none
    @AppStorage("encoderComputeUnits") private var encoderComputeUnits: MLComputeUnits =
    .cpuAndNeuralEngine
    @AppStorage("decoderComputeUnits") private var decoderComputeUnits: MLComputeUnits = .cpuAndNeuralEngine

    // MARK: Standard properties

    private var modelLoadingTime: TimeInterval = 0
    private var firstTokenTime: TimeInterval = 0
    private var pipelineStart: TimeInterval = 0
    private var effectiveRealTimeFactor: TimeInterval = 0
    private var effectiveSpeedFactor: TimeInterval = 0
    private var totalInferenceTime: TimeInterval = 0
    private var tokensPerSecond: TimeInterval = 0
    private var currentLag: TimeInterval = 0
    private var currentFallbacks: Int = 0
    private var currentEncodingLoops: Int = 0
    private var currentDecodingLoops: Int = 0
    private var lastBufferSize: Int = 0
    private var lastConfirmedSegmentEndSeconds: Float = 0
    private var requiredSegmentsForConfirmation: Int = 4
    private var bufferEnergy: [Float] = []
    private var bufferSeconds: Double = 0
    private var confirmedSegments: [TranscriptionSegment] = []
    private var unconfirmedSegments: [TranscriptionSegment] = []

    // MARK: Eager mode properties

    private var eagerResults: [TranscriptionResult?] = []
    private var prevResult: TranscriptionResult?
    private var lastAgreedSeconds: Float = 0.0
    private var prevWords: [WordTiming] = []
    private var lastAgreedWords: [WordTiming] = []
    private var confirmedWords: [WordTiming] = []
    private var confirmedText: String = ""
    private var hypothesisWords: [WordTiming] = []
    private var hypothesisText: String = ""

    // MARK: UI Properties

    private var transcribeTask: Task<Void, Never>? = nil

    private var isStreamMode: Bool {
        return true
    }

    func getComputeOptions() -> ModelComputeOptions {
        return ModelComputeOptions(audioEncoderCompute: encoderComputeUnits, textDecoderCompute: decoderComputeUnits)
    }

    func resetState() {
        transcribeTask?.cancel()
        isRecording = false
        isTranscribing = false
        whisperKit?.audioProcessor.stopRecording()
        currentText = ""
        currentChunks = [:]

        currentTranscribedText = ""
        currentTranscriptionSegments = []
        lastDiarizationResult = nil

        pipelineStart = Double.greatestFiniteMagnitude
        firstTokenTime = Double.greatestFiniteMagnitude
        effectiveRealTimeFactor = 0
        effectiveSpeedFactor = 0
        totalInferenceTime = 0
        tokensPerSecond = 0

        currentLag = 0
        currentFallbacks = 0
        currentEncodingLoops = 0
        currentDecodingLoops = 0
        lastBufferSize = 0
        lastConfirmedSegmentEndSeconds = 0
        requiredSegmentsForConfirmation = 2
        bufferEnergy = []
        bufferSeconds = 0
        confirmedSegments = []
        unconfirmedSegments = []

        eagerResults = []
        prevResult = nil
        lastAgreedSeconds = 0.0
        prevWords = []
        lastAgreedWords = []
        confirmedWords = []
        confirmedText = ""
        hypothesisWords = []
        hypothesisText = ""
    }

    // MARK: - Logic
    // Model loading is now handled by WhisperKitManager.shared

    func transcribeFile(path: String, progressCallback: (@Sendable (Double) -> Void)? = nil, completion: @escaping ([TranscriptionSegment]) -> Void) {
        resetState()
        whisperKit?.audioProcessor = AudioProcessor()
        self.transcribeTask = Task {
            isTranscribing = true
            do {
                try await transcribeCurrentFile(path: path, progressCallback: progressCallback, completion: completion)
            } catch {
                Logging.error("File selection error: \(error.localizedDescription)")
            }
            isTranscribing = false
        }
    }

    func toggleRecording(shouldLoop: Bool)  {
        isRecording.toggle()

        if isRecording {
            resetState()
            startRecording(shouldLoop)
        } else {
            stopRecording(shouldLoop)
        }
    }

    func startRecording(_ loop: Bool) {
        if let audioProcessor = whisperKit?.audioProcessor {
            Task(priority: .userInitiated) {
                guard await AudioProcessor.requestRecordPermission() else {
                    Logging.error("Microphone access was not granted.")
                    return
                }

                let deviceId: DeviceID? = nil
                let bufferCallback: @Sendable ([Float]) -> Void = { [weak self] buffer in
                    Task { @MainActor in
                        guard let self else { return }
                        self.bufferEnergy = self.whisperKit?.audioProcessor.relativeEnergy ?? []
                        self.bufferSeconds = Double(self.whisperKit?.audioProcessor.audioSamples.count ?? 0) / Double(WhisperKit.sampleRate)
                        
                        // Don't process incremental buffers for diarization during live recording
                        // We'll process the full audio buffer at the end instead
                        // This avoids the issue where only partial audio is diarized
                    }
                }
                try? audioProcessor.startRecordingLive(inputDeviceID: deviceId, callback: bufferCallback)

                // Delay the timer start by 1 second

                self.isRecording = true
                self.isTranscribing = true
                if loop {
                    realtimeLoop()
                }
            }
        }
    }

    func stopRecording(_ loop: Bool) {
        isRecording = false
        stopRealtimeTranscription()
        if let audioProcessor = whisperKit?.audioProcessor {
            audioProcessor.stopRecording()
        }

        // If not looping, transcribe the full buffer
        if !loop {
            self.transcribeTask = Task {
                isTranscribing = true
                do {
                    try await transcribeCurrentBuffer()
                } catch {
                    Logging.error("Error: \(error.localizedDescription)")
                }
                finalizeText()
                
                // Finalize diarization if available
                if let diarizationManager = self.diarizationManager {
                    // Process the FULL audio buffer for diarization
                    if let audioProcessor = self.whisperKit?.audioProcessor {
                        let fullAudioBuffer = audioProcessor.audioSamples
                        if !fullAudioBuffer.isEmpty {
                            // Convert the complete audio to PCM buffer and process it
                            if let pcmBuffer = self.createPCMBuffer(from: Array(fullAudioBuffer)) {
                                await diarizationManager.processAudioBuffer(pcmBuffer)
                            }
                        }
                    }
                    
                    let diarizationResult = await diarizationManager.finishProcessing()
                    self.lastDiarizationResult = diarizationResult
                }
                
                isTranscribing = false
            }
        }

        finalizeText()
    }
    
    // Add a method to wait for transcription and diarization to complete
    func waitForTranscriptionCompletion() async {
        if let task = transcribeTask {
            await task.value
        }
    }

    func finalizeText() {
        // Finalize unconfirmed text
        if hypothesisText != "" {
            confirmedText += hypothesisText
            hypothesisText = ""
        }

        if unconfirmedSegments.count > 0 {
            confirmedSegments.append(contentsOf: unconfirmedSegments)
            unconfirmedSegments = []
        }
        
        // Store final segments for timestamp extraction
        if !confirmedSegments.isEmpty {
            currentTranscriptionSegments = confirmedSegments
        }
        
        // Clean the transcribed text
        currentTranscribedText = cleanTranscribedText(currentTranscribedText)
    }
    
    private func cleanTranscribedText(_ text: String) -> String {
        // Remove any text in square brackets like [music], [applause], etc.
        let pattern = "\\[.*?\\]"
        let cleanedText = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        
        // Clean up any double spaces that might result from removal
        let finalText = cleanedText.replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        
        return finalText
    }

    // MARK: - Transcribe Logic

    func transcribeCurrentFile(path: String, progressCallback: (@Sendable (Double) -> Void)? = nil, completion: @escaping ([TranscriptionSegment]) -> Void) async throws {
        // Load and convert buffer in a limited scope
        Logging.debug("Loading audio file: \(path)")
        let loadingStart = Date()
        let audioFileSamples = try await Task {
            try autoreleasepool {
                let audioFileBuffer = try AudioProcessor.loadAudio(fromPath: path)
                return AudioProcessor.convertBufferToArray(buffer: audioFileBuffer)
            }
        }.value
        Logging.debug("Loaded audio file in \(Date().timeIntervalSince(loadingStart)) seconds")

        let transcription = try await transcribeAudioSamples(audioFileSamples, progressCallback: progressCallback)

        currentText = ""
        guard let segments = transcription?.segments else {
            return
        }

        tokensPerSecond = transcription?.timings.tokensPerSecond ?? 0
        effectiveRealTimeFactor = transcription?.timings.realTimeFactor ?? 0
        effectiveSpeedFactor = transcription?.timings.speedFactor ?? 0
        currentEncodingLoops = Int(transcription?.timings.totalEncodingRuns ?? 0)
        firstTokenTime = transcription?.timings.firstTokenTime ?? 0
        pipelineStart = transcription?.timings.pipelineStart ?? 0
        currentLag = transcription?.timings.decodingLoop ?? 0

        confirmedSegments = segments
        
        completion(segments)
    }

    func transcribeAudioSamples(_ samples: [Float], progressCallback: (@Sendable (Double) -> Void)? = nil) async throws -> TranscriptionResult? {
        guard let whisperKit = whisperKit else { return nil }

        let languageCode = Constants.languages[selectedLanguage, default: Constants.defaultLanguageCode]
        let task: DecodingTask = selectedTask == "transcribe" ? .transcribe : .translate
        let seekClip: [Float] = [lastConfirmedSegmentEndSeconds]

        let options = DecodingOptions(
             verbose: false,
             task: task,
             language: languageCode,
             temperature: Float(temperatureStart),
             temperatureFallbackCount: Int(fallbackCount),
             sampleLength: Int(sampleLength),
             usePrefillPrompt: enablePromptPrefill,
             usePrefillCache: enableCachePrefill,
             skipSpecialTokens: !enableSpecialCharacters,
             withoutTimestamps: !enableTimestamps,
             wordTimestamps: true,
             clipTimestamps: seekClip,
             concurrentWorkerCount: concurrentWorkerCount,
             chunkingStrategy: chunkingStrategy
        )

        // Calculate total chunks for progress tracking
        let totalDuration = Float(samples.count) / Float(WhisperKit.sampleRate)
        let chunkDuration = Float(30.0) // WhisperKit typically processes 30-second chunks
        let estimatedChunks = max(1, Int(ceil(totalDuration / chunkDuration)))
        
        // Use a class to allow mutation in the closure
        final class ProgressTracker: @unchecked Sendable {
            var processedWindows = 0
        }
        let tracker = ProgressTracker()
        
        // Capture values needed for early stopping before the closure
        let capturedCompressionCheckWindow = Int(compressionCheckWindow)
        let capturedIsStreamMode = isStreamMode
        
        // Early stopping checks
        let decodingCallback: @Sendable (TranscriptionProgress) -> Bool? = { [weak self] (progress: TranscriptionProgress) in
            Task { @MainActor in
                guard let self else { return }
                let fallbacks = Int(progress.timings.totalDecodingFallbacks)
                let chunkId = capturedIsStreamMode ? 0 : progress.windowId
                
                // Calculate and report progress if callback provided
                if let progressCallback = progressCallback {
                    // Track unique windows processed
                    tracker.processedWindows = max(tracker.processedWindows, progress.windowId + 1)
                    
                    // Calculate progress based on windows processed vs estimated chunks
                    // Use a more realistic progress calculation considering that processing
                    // might require multiple passes for accuracy
                    let baseProgress = Double(tracker.processedWindows) / Double(estimatedChunks)
                    let adjustedProgress = min(0.95, baseProgress * 0.9) // Cap at 95% during processing
                    
                    await MainActor.run {
                        progressCallback(adjustedProgress)
                    }
                }

                // First check if this is a new window for the same chunk, append if so
                var updatedChunk = (chunkText: [progress.text], fallbacks: fallbacks)
                if var currentChunk = self.currentChunks[chunkId], let previousChunkText = currentChunk.chunkText.last {
                    if progress.text.count >= previousChunkText.count {
                        // This is the same window of an existing chunk, so we just update the last value
                        currentChunk.chunkText[currentChunk.chunkText.endIndex - 1] = progress.text
                        updatedChunk = currentChunk
                    } else {
                        // This is either a new window or a fallback (only in streaming mode)
                        if fallbacks == currentChunk.fallbacks && capturedIsStreamMode {
                            // New window (since fallbacks havent changed)
                            updatedChunk.chunkText = currentChunk.chunkText + [progress.text]
                        } else {
                            // Fallback, overwrite the previous bad text
                            updatedChunk.chunkText[currentChunk.chunkText.endIndex - 1] = progress.text
                            updatedChunk.fallbacks = fallbacks
                        }
                    }
                }

                // Set the new text for the chunk
                self.currentChunks[chunkId] = updatedChunk
                let joinedChunks = self.currentChunks.sorted { $0.key < $1.key }.flatMap { $0.value.chunkText }.joined(separator: "\n")

                self.currentText = self.cleanTranscribedText(joinedChunks)
                self.currentFallbacks = fallbacks
                self.currentDecodingLoops += 1
            }

            // Check early stopping
            let currentTokens = progress.tokens
            let checkWindow = capturedCompressionCheckWindow
            if currentTokens.count > checkWindow {
                let checkTokens: [Int] = currentTokens.suffix(checkWindow)
                let compressionRatio = TextUtilities.compressionRatio(of: checkTokens)
                if compressionRatio > options.compressionRatioThreshold! {
                    Logging.debug("Early stopping due to compression threshold")
                    return false
                }
            }
            if progress.avgLogprob! < options.logProbThreshold! {
                Logging.debug("Early stopping due to logprob threshold")
                return false
            }
            return nil
        }

        let transcriptionResults: [TranscriptionResult] = try await whisperKit.transcribe(
            audioArray: samples,
            decodeOptions: options,
            callback: decodingCallback
        )

        let mergedResults = TranscriptionUtilities.mergeTranscriptionResults(transcriptionResults)

        return mergedResults
    }

    // MARK: Streaming Logic

    func realtimeLoop() {
        transcriptionTask = Task {
            // Track buffer size to detect and handle memory issues
            let maxBufferDuration: Float = 120.0 // Monitor for 2 minutes of audio
            let maxBufferSamples = Int(maxBufferDuration * Float(WhisperKit.sampleRate))
            var lastWarningTime = Date()
            
            while isRecording && isTranscribing {
                do {
                    // Monitor buffer growth and warn if it gets too large
                    if let audioProcessor = whisperKit?.audioProcessor {
                        let currentSamples = audioProcessor.audioSamples.count
                        if currentSamples > maxBufferSamples {
                            let now = Date()
                            // Warn every 30 seconds if buffer is growing too large
                            if now.timeIntervalSince(lastWarningTime) > 30 {
                                Logging.debug("Audio buffer growing large: \(currentSamples) samples (\(currentSamples/16000) seconds)")
                                lastWarningTime = now
                                
                                // Reset the audio processor if buffer gets critically large (5+ minutes)
                                if currentSamples > maxBufferSamples * 2 {
                                    Logging.error("Resetting audio processor due to excessive buffer size")
                                    // We'll need to restart recording after this transcription cycle
                                    shouldRestartRecording = true
                                }
                            }
                        }
                    }
                    
                    try await transcribeCurrentBuffer(delayInterval: Float(realtimeDelayInterval))
                } catch {
                    Logging.error("Error: \(error.localizedDescription)")
                    break
                }
            }
        }
    }

    func stopRealtimeTranscription() {
        isTranscribing = false
        transcriptionTask?.cancel()
    }

    func transcribeCurrentBuffer(delayInterval: Float = 1.0) async throws {
        guard let whisperKit = whisperKit else { 
            return 
        }

        // Retrieve the current audio buffer from the audio processor
        let currentBuffer = whisperKit.audioProcessor.audioSamples

        // Calculate the size and duration of the next buffer segment
        let nextBufferSize = currentBuffer.count - lastBufferSize
        let nextBufferSeconds = Float(nextBufferSize) / Float(WhisperKit.sampleRate)

        // Only run the transcribe if the next buffer has at least 1 second of audio
        guard nextBufferSeconds > 1 else {
            if currentText == "" {
                currentText = "Waiting for speech..."
            }
            try await Task.sleep(nanoseconds: 100_000_000) // sleep for 100ms for next buffer
            return
        }

        if useVAD {
             let voiceDetected = AudioProcessor.isVoiceDetected(
                in: whisperKit.audioProcessor.relativeEnergy,
                nextBufferInSeconds: nextBufferSeconds,
                silenceThreshold: Float(silenceThreshold)
            )
            // Only run the transcribe if the next buffer has voice
            guard voiceDetected else {
                if currentText == "" {
                    currentText = "Waiting for speech..."
                }

                // Sleep for 100ms and check the next buffer
                try await Task.sleep(nanoseconds: 100_000_000)
                return
            }
        }

        // Store this for next iterations VAD
        lastBufferSize = currentBuffer.count

        if enableEagerDecoding && isStreamMode {
            // Run realtime transcribe using word timestamps for segmentation
            let transcription = try await transcribeEagerMode(Array(currentBuffer))
            currentText = ""
            tokensPerSecond = transcription?.timings.tokensPerSecond ?? 0
            firstTokenTime = transcription?.timings.firstTokenTime ?? 0
            modelLoadingTime = transcription?.timings.modelLoading ?? 0
            pipelineStart = transcription?.timings.pipelineStart ?? 0
            currentLag = transcription?.timings.decodingLoop ?? 0
            currentEncodingLoops = Int(transcription?.timings.totalEncodingRuns ?? 0)

            let totalAudio = Double(currentBuffer.count) / Double(WhisperKit.sampleRate)
            totalInferenceTime = transcription?.timings.fullPipeline ?? 0
            effectiveRealTimeFactor = Double(totalInferenceTime) / totalAudio
            effectiveSpeedFactor = totalAudio / Double(totalInferenceTime)
            
            // Update the current transcribed text with confirmed + hypothesis text
            currentTranscribedText = confirmedText
            if !hypothesisText.isEmpty {
                currentTranscribedText += " " + hypothesisText
            }
            
            // Store segments if available
            if let segments = transcription?.segments {
                currentTranscriptionSegments = segments
            }
        } else {
            // Run realtime transcribe using timestamp tokens directly
            let transcription = try await transcribeAudioSamples(Array(currentBuffer))

            currentText = ""
            guard let segments = transcription?.segments else {
                return
            }

            tokensPerSecond = transcription?.timings.tokensPerSecond ?? 0
            firstTokenTime = transcription?.timings.firstTokenTime ?? 0
            pipelineStart = transcription?.timings.pipelineStart ?? 0
            currentLag = transcription?.timings.decodingLoop ?? 0
            currentEncodingLoops += Int(transcription?.timings.totalEncodingRuns ?? 0)

            let totalAudio = Double(currentBuffer.count) / Double(WhisperKit.sampleRate)
            totalInferenceTime += transcription?.timings.fullPipeline ?? 0
            effectiveRealTimeFactor = Double(totalInferenceTime) / totalAudio
            effectiveSpeedFactor = totalAudio / Double(totalInferenceTime)

            // Logic for moving segments to confirmedSegments
            if segments.count > requiredSegmentsForConfirmation {
                // Calculate the number of segments to confirm
                let numberOfSegmentsToConfirm = segments.count - requiredSegmentsForConfirmation

                // Confirm the required number of segments
                let confirmedSegmentsArray = Array(segments.prefix(numberOfSegmentsToConfirm))
                let remainingSegments = Array(segments.suffix(requiredSegmentsForConfirmation))

                // Update lastConfirmedSegmentEnd based on the last confirmed segment
                if let lastConfirmedSegment = confirmedSegmentsArray.last, lastConfirmedSegment.end > lastConfirmedSegmentEndSeconds {
                    lastConfirmedSegmentEndSeconds = lastConfirmedSegment.end
                    
                    // Remove any existing confirmed segments that overlap with new ones
                    // This prevents duplicate text from accumulating
                    let newSegmentTimeRanges = confirmedSegmentsArray.map { ($0.start, $0.end) }
                    confirmedSegments = confirmedSegments.filter { existing in
                        // Keep segment only if it doesn't overlap with any new segment
                        !newSegmentTimeRanges.contains { newStart, newEnd in
                            // Check for time overlap
                            let overlapStart = max(existing.start, newStart)
                            let overlapEnd = min(existing.end, newEnd)
                            return overlapStart < overlapEnd
                        }
                    }
                    
                    // Add new confirmed segments
                    confirmedSegments.append(contentsOf: confirmedSegmentsArray)
                }

                // Update transcriptions to reflect the remaining segments
                unconfirmedSegments = remainingSegments
            } else {
                // Handle the case where segments are fewer or equal to required
                unconfirmedSegments = segments
            }
            
            // Build the complete transcribed text from confirmed and unconfirmed segments
            // Sort by start time to ensure chronological order
            let allSegments = (confirmedSegments + unconfirmedSegments).sorted { $0.start < $1.start }
            
            let fullText = allSegments.map { $0.text }.joined(separator: " ")
            currentTranscribedText = cleanTranscribedText(fullText)
            
            // Store all segments for timestamp-based extraction
            currentTranscriptionSegments = allSegments
        }
    }

    func transcribeEagerMode(_ samples: [Float]) async throws -> TranscriptionResult? {
        guard let whisperKit = whisperKit else { return nil }

        guard whisperKit.textDecoder.supportsWordTimestamps else {
            confirmedText = "Eager mode requires word timestamps, which are not supported by the current model: \(selectedModel)."
            return nil
        }

        let languageCode = Constants.languages[selectedLanguage, default: Constants.defaultLanguageCode]
        let task: DecodingTask = selectedTask == "transcribe" ? .transcribe : .translate

        let options = DecodingOptions(
            verbose: false,
            task: task,
            language: languageCode,
            temperature: Float(temperatureStart),
            temperatureFallbackCount: Int(fallbackCount),
            sampleLength: Int(sampleLength),
            usePrefillPrompt: enablePromptPrefill,
            usePrefillCache: enableCachePrefill,
            skipSpecialTokens: !enableSpecialCharacters,
            withoutTimestamps: !enableTimestamps,
            wordTimestamps: true, // required for eager mode
            firstTokenLogProbThreshold: -1.5 // higher threshold to prevent fallbacks from running to often
        )

        // Capture values needed for early stopping before the closure
        let capturedCompressionCheckWindow = Int(compressionCheckWindow)
        
        // Early stopping checks
        let decodingCallback: @Sendable (TranscriptionProgress) -> Bool? = { [weak self] progress in
            Task { @MainActor in
                guard let self else { return }
                let fallbacks = Int(progress.timings.totalDecodingFallbacks)
                if progress.text.count < self.currentText.count {
                    if fallbacks == self.currentFallbacks {
                        //  self.unconfirmedText.append(currentText)
                    }
                }
                self.currentText = progress.text
                self.currentFallbacks = fallbacks
                self.currentDecodingLoops += 1
            }
            // Check early stopping
            let currentTokens = progress.tokens
            let checkWindow = capturedCompressionCheckWindow
            if currentTokens.count > checkWindow {
                let checkTokens: [Int] = currentTokens.suffix(checkWindow)
                let compressionRatio = TextUtilities.compressionRatio(of: checkTokens)
                if compressionRatio > options.compressionRatioThreshold! {
                    Logging.debug("Early stopping due to compression threshold")
                    return false
                }
            }
            if progress.avgLogprob! < options.logProbThreshold! {
                Logging.debug("Early stopping due to logprob threshold")
                return false
            }

            return nil
        }

        Logging.info("[EagerMode] \(lastAgreedSeconds)-\(Double(samples.count) / 16000.0) seconds")

        let streamingAudio = samples
        var streamOptions = options
        streamOptions.clipTimestamps = [lastAgreedSeconds]
        let lastAgreedTokens = lastAgreedWords.flatMap { $0.tokens }
        streamOptions.prefixTokens = lastAgreedTokens
        do {
            let transcription: TranscriptionResult? = try await whisperKit.transcribe(audioArray: streamingAudio, decodeOptions: streamOptions, callback: decodingCallback).first
            var skipAppend = false
            if let result = transcription {
                hypothesisWords = result.allWords.filter { $0.start >= lastAgreedSeconds }

                if let prevResult = prevResult {
                    prevWords = prevResult.allWords.filter { $0.start >= lastAgreedSeconds }
                    let commonPrefix = TranscriptionUtilities.findLongestCommonPrefix(prevWords, hypothesisWords)
                    Logging.info("[EagerMode] Prev \"\((prevWords.map { $0.word }).joined())\"")
                    Logging.info("[EagerMode] Next \"\((hypothesisWords.map { $0.word }).joined())\"")
                    Logging.info("[EagerMode] Found common prefix \"\((commonPrefix.map { $0.word }).joined())\"")

                    if commonPrefix.count >= Int(tokenConfirmationsNeeded) {
                        lastAgreedWords = commonPrefix.suffix(Int(tokenConfirmationsNeeded))
                        lastAgreedSeconds = lastAgreedWords.first!.start
                        Logging.info("[EagerMode] Found new last agreed word \"\(lastAgreedWords.first!.word)\" at \(lastAgreedSeconds) seconds")

                        confirmedWords.append(contentsOf: commonPrefix.prefix(commonPrefix.count - Int(tokenConfirmationsNeeded)))
                        let currentWords = confirmedWords.map { $0.word }.joined()
                        Logging.info("[EagerMode] Current:  \(lastAgreedSeconds) -> \(Double(samples.count) / 16000.0) \(currentWords)")
                    } else {
                        Logging.info("[EagerMode] Using same last agreed time \(lastAgreedSeconds)")
                        skipAppend = true
                    }
                }
                prevResult = result
            }

            if !skipAppend {
                eagerResults.append(transcription)
            }

            let finalWords = confirmedWords.map { $0.word }.joined()
            confirmedText = cleanTranscribedText(finalWords)

            // Accept the final hypothesis because it is the last of the available audio
            let lastHypothesis = lastAgreedWords + TranscriptionUtilities.findLongestDifferentSuffix(prevWords, hypothesisWords)
            hypothesisText = cleanTranscribedText(lastHypothesis.map { $0.word }.joined())
        } catch {
            Logging.error("[EagerMode] Error: \(error)")
            finalizeText()
        }

        let mergedResult = TranscriptionUtilities.mergeTranscriptionResults(eagerResults, confirmedWords: confirmedWords)

        return mergedResult
    }
    
    // MARK: - Diarization Support
    
    private func createPCMBuffer(from floatArray: [Float]) -> AVAudioPCMBuffer? {
        // WhisperKit uses 16kHz sampling rate
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(WhisperKit.sampleRate),
            channels: 1,
            interleaved: false
        )
        
        guard let format = format,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(floatArray.count)) else {
            return nil
        }
        
        buffer.frameLength = UInt32(floatArray.count)
        
        // Copy the float data to the buffer
        if let channelData = buffer.floatChannelData {
            floatArray.withUnsafeBufferPointer { sourceBuffer in
                channelData[0].update(from: sourceBuffer.baseAddress!, count: floatArray.count)
            }
        }
        
        return buffer
    }
}
