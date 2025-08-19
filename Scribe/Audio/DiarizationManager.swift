import Foundation
import AVFoundation
import FluidAudio
import SwiftData
import Accelerate


@MainActor
@Observable
final class DiarizationManager {
    private var fluidDiarizer: DiarizerManager?
    var isInitialized = false
    private var audioBuffer: [Float] = []
    private let sampleRate: Float = 16000.0
    
    // Buffer management optimizations
    private let maxBufferSize = 16000 * 60 * 10  // 10 minutes max buffer
    private var bufferWriteIndex = 0
    
    // Configuration
    var config: DiarizerConfig = DiarizerConfig()
    var isEnabled: Bool = true
    var enableRealTimeProcessing: Bool = false
    
    // Chunking parameters optimized for performance (FluidAudio v3)
    var chunkDuration: Float = 5.0  // Reduced to 5 seconds for lower latency
    var chunkOverlap: Float = 1.0    // Reduced overlap for faster processing
    
    // State
    var isProcessing = false
    var lastError: (any Error)?
    var processingProgress: Double = 0.0
    
    // Results
    private(set) var lastResult: DiarizationResult?
    
    // Model context for speaker database
    private var modelContext: ModelContext?
    
    // Persistent speaker database
    private var speakerDatabase: [String: [Float]] = [:]
    
    // Speaker quality tracking
    private var speakerQualityScores: [String: Float] = [:]
    
    // Performance optimization: Speaker similarity cache
    // Cache key format: "originalSpeakerId_embeddingHash" -> "matchedSpeakerId"
    private var similarityCache: [String: String] = [:]
    private let maxCacheSize = 1000
    
    // Post-processing options
    var enableSpeakerMerging: Bool = true
    var speakerMergingThreshold: Float = 0.3
    var combineSameSpeakerSegments: Bool = false
    var mergePartialSentences: Bool = false
    
    init(config: DiarizerConfig = DiarizerConfig(), isEnabled: Bool = true, enableRealTimeProcessing: Bool = false, modelContext: ModelContext? = nil, settings: AppSettings? = nil) {
        self.config = config
        self.isEnabled = isEnabled
        self.enableRealTimeProcessing = enableRealTimeProcessing
        self.modelContext = modelContext
        
        // Load settings if provided
        if let settings = settings {
            self.enableSpeakerMerging = settings.enableSpeakerMerging
            self.speakerMergingThreshold = settings.speakerMergingThreshold
            self.combineSameSpeakerSegments = settings.combineSameSpeakerSegments
            self.mergePartialSentences = settings.mergePartialSentences
            self.chunkDuration = settings.chunkDuration
            self.chunkOverlap = settings.chunkOverlap
        }
        
        // Load persistent speaker database if available
        if let context = modelContext {
            loadSpeakerDatabase(from: context)
        }
    }
    
    // MARK: - Initialization
    
    func initialize() async throws {
        print("[DiarizationManager] Initializing FluidAudio diarizer...")

        guard isEnabled else {
            print("[DiarizationManager] Diarization is disabled in config")
            return
        }

        do {
            // Create FluidAudio diarizer with custom config
            let fluidConfig = createFluidAudioConfig()
            let diarizer = DiarizerManager(config: fluidConfig)
            
            // Note: chunkDuration and chunkOverlap are used internally by our processAccumulatedAudio
            // FluidAudio's DiarizerManager uses its own internal chunking parameters
            
            let diarizerModels = try await DiarizerModels.downloadIfNeeded()
            diarizer.initialize(models: diarizerModels)
            self.fluidDiarizer = diarizer
            isInitialized = true
            print("[DiarizationManager] FluidAudio diarizer initialized successfully")
        } catch {
            print("[DiarizationManager] Failed to initialize diarizer: \(error)")
            lastError = error
            throw error
        }
    }
    
    private func createFluidAudioConfig() -> DiarizerConfig {
        return config
    }
    
    // MARK: - Audio Processing
    
    func processAudioBuffer(_ buffer: AVAudioPCMBuffer) async {
        guard isEnabled, isInitialized else { return }
        
        // Convert audio buffer to Float array at 16kHz
        guard let floatSamples = convertBufferToFloatArray(buffer) else {
            print("[DiarizationManager] Failed to convert audio buffer")
            return
        }
        
        // Optimize buffer management - prevent unbounded growth
        if audioBuffer.count + floatSamples.count > maxBufferSize {
            // Keep only the last 80% of max buffer to maintain context
            let keepCount = Int(Double(maxBufferSize) * 0.8)
            let dropCount = audioBuffer.count - keepCount
            if dropCount > 0 {
                audioBuffer.removeFirst(dropCount)
                print("[DiarizationManager] Buffer overflow - dropped \(dropCount) samples")
            }
        }
        
        // Accumulate audio for batch processing
        audioBuffer.append(contentsOf: floatSamples)
        
        // Process in real-time if enabled and we have enough audio
        if enableRealTimeProcessing && audioBuffer.count >= Int(sampleRate * 10) {
            _ = await processAccumulatedAudio()
        }
    }
    
    func finishProcessing() async -> DiarizationResult? {
        print("[DiarizationManager] finishProcessing called - enabled: \(isEnabled), initialized: \(isInitialized), buffer size: \(audioBuffer.count)")
        
        guard isEnabled, isInitialized, !audioBuffer.isEmpty else {
            print("[DiarizationManager] Cannot finish processing - missing requirements")
            return nil
        }
        
        let result = await processAccumulatedAudio()
        print("[DiarizationManager] Processing completed with result: \(result?.segments.count ?? 0) segments")
        return result
    }
    
    private func processAccumulatedAudio() async -> DiarizationResult? {
        guard let diarizer = fluidDiarizer, !audioBuffer.isEmpty else {
            return nil
        }
        
        isProcessing = true
        processingProgress = 0.0
        
        do {
            print("[DiarizationManager] Processing \(audioBuffer.count) audio samples...")
            let startTime = Date()
            
            // Use @unchecked Sendable wrapper to handle the non-Sendable type
            struct DiarizerWrapper: @unchecked Sendable {
                let diarizer: DiarizerManager
                let audioBuffer: [Float]
                let sampleRate: Int
            }
            
            let wrapper = DiarizerWrapper(
                diarizer: diarizer,
                audioBuffer: audioBuffer,
                sampleRate: Int(sampleRate)
            )
            
            // Perform diarization using FluidAudio
            let fluidResult = try await Task.detached {
                try wrapper.diarizer.performCompleteDiarization(
                    wrapper.audioBuffer,
                    sampleRate: wrapper.sampleRate
                )
            }.value
            
            let processingTime = Date().timeIntervalSince(startTime)
            print("[DiarizationManager] Diarization completed in \(processingTime)s")
            
            // Process result with persistent speaker database
            var enhancedResult = await enhanceResultWithPersistentSpeakers(fluidResult)
            
            // Apply post-processing based on settings
            if combineSameSpeakerSegments {
                enhancedResult = await combineSameSpeakerSegments(enhancedResult)
            }
            
            if mergePartialSentences {
                enhancedResult = await mergePartialSentences(enhancedResult)
            }
            
            // Apply speaker merging if enabled (for similar embeddings)
            if enableSpeakerMerging {
                enhancedResult = await mergeSimilarSpeakers(enhancedResult)
            }
            
            lastResult = enhancedResult
            processingProgress = 1.0
            isProcessing = false
            
            // Clear the buffer after processing
            audioBuffer.removeAll()
            
            return enhancedResult
            
        } catch {
            print("[DiarizationManager] Diarization failed: \(error)")
            lastError = error
            isProcessing = false
            return nil
        }
    }
    
    // MARK: - Speaker Enrollment and Management (FluidAudio v3)
    
    /// Enroll a new speaker with their voice sample and name
    func enrollSpeaker(name: String, audioSample: [Float]) async throws -> String? {
        guard let diarizer = fluidDiarizer else {
            throw DiarizationError.notInitialized
        }
        
        // Extract embedding from the audio sample
        let embedding = try await extractSpeakerEmbedding(from: audioSample)
        guard let embedding = embedding else {
            throw DiarizationError.processingFailed("Failed to extract speaker embedding")
        }
        
        // Generate a unique speaker ID
        let speakerId = "speaker_\(UUID().uuidString.prefix(8))"
        
        // Assign the speaker with name in FluidAudio's SpeakerManager
        diarizer.speakerManager.assignSpeaker(
            embedding,
            speechDuration: Float(audioSample.count) / sampleRate,
            confidence: 1.0
        )
        
        // Also save to our persistent storage
        if let context = modelContext {
            let speaker = Speaker.findOrCreate(withId: speakerId, in: context)
            speaker.name = name
            speaker.embedding = embedding
            speaker.isPersistent = true
            speaker.lastSeenAt = Date()
            
            // Save to persistent speaker manager
            PersistentSpeakerManager.shared.saveSpeaker(speaker)
            
            try? context.save()
        }
        
        return speakerId
    }
    
    /// Initialize known speakers from persistent storage
    func loadKnownSpeakers() async {
        guard let diarizer = fluidDiarizer, let context = modelContext else { return }
        
        // Load speakers from PersistentSpeakerManager
        PersistentSpeakerManager.shared.syncWithDatabase(context: context)
        
        // Get all persistent speakers with embeddings
        let descriptor = FetchDescriptor<Speaker>(predicate: #Predicate { speaker in
            speaker.isPersistent == true
        })
        
        if let persistentSpeakers = try? context.fetch(descriptor) {
            var knownSpeakers: [String: [Float]] = [:]
            
            for speaker in persistentSpeakers {
                if let embedding = speaker.embedding {
                    knownSpeakers[speaker.id] = embedding
                    
                    // Assign to FluidAudio's SpeakerManager
                    diarizer.speakerManager.assignSpeaker(
                        embedding,
                        speechDuration: 10.0, // Default duration
                        confidence: 1.0
                    )
                }
            }
            
            // Initialize known speakers in FluidAudio
            // Initialize known speakers in FluidAudio v3
            // Note: v3 may not have initializeKnownSpeakers method
            // Speakers are already assigned via assignSpeaker above
            
            print("[DiarizationManager] Loaded \(knownSpeakers.count) known speakers")
        }
    }
    
    /// Export all speakers to JSON
    func exportSpeakers() -> String? {
        guard let context = modelContext else { return nil }
        
        let descriptor = FetchDescriptor<Speaker>(predicate: #Predicate { speaker in
            speaker.isPersistent == true
        })
        
        if let speakers = try? context.fetch(descriptor) {
            let speakerData = speakers.compactMap { speaker -> [String: Any]? in
                guard let embedding = speaker.embedding else { return nil }
                return [
                    "id": speaker.id,
                    "name": speaker.name,
                    "embedding": embedding
                ]
            }
            
            if let jsonData = try? JSONSerialization.data(withJSONObject: speakerData),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                return jsonString
            }
        }
        return nil
    }
    
    /// Import speakers from JSON
    func importSpeakers(from json: String) {
        guard let context = modelContext,
              let jsonData = json.data(using: .utf8),
              let speakerData = try? JSONSerialization.jsonObject(with: jsonData) as? [[String: Any]] else { return }
        
        for data in speakerData {
            if let id = data["id"] as? String,
               let name = data["name"] as? String,
               let embedding = data["embedding"] as? [Float] {
                
                let speaker = Speaker.findOrCreate(withId: id, in: context)
                speaker.name = name
                speaker.embedding = embedding
                speaker.isPersistent = true
                
                // Save to persistent manager
                PersistentSpeakerManager.shared.saveSpeaker(speaker)
            }
        }
        
        try? context.save()
    }
    
    // MARK: - Speaker Comparison
    
    // Extract speaker embedding from audio sample (FluidAudio v3 API)
    func extractSpeakerEmbedding(from audio: [Float]) async throws -> [Float]? {
        guard let diarizer = fluidDiarizer else {
            throw DiarizationError.notInitialized
        }
        
        // Use @unchecked Sendable wrapper to handle the non-Sendable type
        struct DiarizerWrapper: @unchecked Sendable {
            let diarizer: DiarizerManager
            let audio: [Float]
        }
        
        let wrapper = DiarizerWrapper(diarizer: diarizer, audio: audio)
        
        return try await Task.detached {
            // Process the audio to extract speaker embeddings
            // FluidAudio v3 uses performCompleteDiarization
            let result = try wrapper.diarizer.performCompleteDiarization(
                wrapper.audio,
                sampleRate: 16000
            )
            
            // Get the most representative embedding by finding the longest segment
            var longestSegment: TimedSpeakerSegment?
            var maxDuration: Float = 0
            
            for segment in result.segments {
                let duration = segment.endTimeSeconds - segment.startTimeSeconds
                if duration > maxDuration {
                    maxDuration = duration
                    longestSegment = segment
                }
            }
            
            // Return the embedding from the longest segment (most representative)
            return longestSegment?.embedding
        }.value
    }
    
    // Compare two speaker embeddings using cosine similarity
    func compareSpeakers(embedding1: [Float], embedding2: [Float]) -> Float {
        // Use the SpeakerManager's verification method
        guard let diarizer = fluidDiarizer else { return 0.0 }
        // Calculate cosine similarity directly
        return calculateCosineSimilarity(embedding1, embedding2)
    }
    
    // MARK: - Utility Methods
    
    private func convertBufferToFloatArray(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        guard let channelData = buffer.floatChannelData else { return nil }
        
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        
        // Pre-allocate array for better performance
        var samples: [Float]
        
        if buffer.format.sampleRate != 16000 {
            // Optimized downsampling using vDSP
            let ratio = buffer.format.sampleRate / 16000.0
            let targetFrameCount = Int(Double(frameCount) / ratio)
            samples = [Float](repeating: 0, count: targetFrameCount)
            
            if channelCount == 1 {
                // Use simple decimation for mono channel
                let decimationFactor = Int(ratio)
                if decimationFactor > 1 {
                    // Simple decimation - take every Nth sample
                    for i in 0..<targetFrameCount {
                        let sourceIndex = i * decimationFactor
                        if sourceIndex < frameCount {
                            samples[i] = channelData[0][sourceIndex]
                        }
                    }
                } else {
                    // Direct copy if no decimation needed
                    samples = Array(UnsafeBufferPointer(start: channelData[0], count: targetFrameCount))
                }
            } else {
                // Multi-channel - use vDSP for efficient averaging
                var tempBuffer = [Float](repeating: 0, count: frameCount)
                
                // Sum all channels using vDSP
                for channel in 0..<channelCount {
                    let channelPtr = UnsafeBufferPointer(start: channelData[channel], count: frameCount)
                    vDSP_vadd(tempBuffer, 1, channelPtr.baseAddress!, 1, &tempBuffer, 1, vDSP_Length(frameCount))
                }
                
                // Divide by channel count for average
                var divisor = Float(channelCount)
                vDSP_vsdiv(tempBuffer, 1, &divisor, &tempBuffer, 1, vDSP_Length(frameCount))
                
                // Decimate if needed
                let decimationFactor = Int(ratio)
                if decimationFactor > 1 {
                    // Simple decimation - take every Nth sample
                    for i in 0..<targetFrameCount {
                        let sourceIndex = i * decimationFactor
                        if sourceIndex < tempBuffer.count {
                            samples[i] = tempBuffer[sourceIndex]
                        }
                    }
                } else {
                    samples = Array(tempBuffer.prefix(targetFrameCount))
                }
            }
        } else {
            // Already at 16kHz - optimize using vDSP
            samples = [Float](repeating: 0, count: frameCount)
            
            if channelCount == 1 {
                // Direct copy for mono
                samples = Array(UnsafeBufferPointer(start: channelData[0], count: frameCount))
            } else {
                // Use vDSP for efficient multi-channel averaging
                // Sum all channels
                for channel in 0..<channelCount {
                    let channelPtr = UnsafeBufferPointer(start: channelData[channel], count: frameCount)
                    vDSP_vadd(samples, 1, channelPtr.baseAddress!, 1, &samples, 1, vDSP_Length(frameCount))
                }
                
                // Divide by channel count
                var divisor = Float(channelCount)
                vDSP_vsdiv(samples, 1, &divisor, &samples, 1, vDSP_Length(frameCount))
            }
        }
        
        return samples
    }
    
    
    // MARK: - Speaker Database Management
    
    private func loadSpeakerDatabase(from context: ModelContext) {
        let db = SpeakerDatabase.shared(in: context)
        speakerDatabase = db.embeddings
    }
    
    private func saveSpeakerDatabase(to context: ModelContext) {
        let db = SpeakerDatabase.shared(in: context)
        db.embeddings = speakerDatabase
        try? context.save()
    }
    
    private func enhanceResultWithPersistentSpeakers(_ result: DiarizationResult) async -> DiarizationResult {
        guard let context = modelContext else { return result }
        
        var updatedSegments: [TimedSpeakerSegment] = []
        var updatedDatabase = speakerDatabase
        
        // Batch process segments for better performance
        let segmentGroups = Dictionary(grouping: result.segments) { $0.speakerId }
        
        for (originalSpeakerId, segments) in segmentGroups {
            guard let firstSegment = segments.first else { continue }
            
            var finalSpeakerId = originalSpeakerId
            let avgConfidence = segments.reduce(0) { $0 + $1.qualityScore } / Float(segments.count)
            
            // Only try to match with persistent speakers (enrolled speakers)
            // Use a reasonable threshold to avoid over-fragmenting
            if let persistentSpeaker = Speaker.findPersistentSpeakerBySimilarity(
                embedding: firstSegment.embedding,
                threshold: 0.75, // Balanced threshold - not too strict, not too loose
                in: context
            ) {
                finalSpeakerId = persistentSpeaker.id
                persistentSpeaker.lastSeenAt = Date()
                persistentSpeaker.updateStatistics(confidence: avgConfidence)
                print("[DiarizationManager] Matched to known speaker: \(persistentSpeaker.name)")
            } else {
                // Create or get speaker for this ID
                // FluidAudio has already done the clustering, so trust its speaker IDs
                let speaker = Speaker.findOrCreate(withId: originalSpeakerId, embedding: firstSegment.embedding, in: context)
                speaker.updateStatistics(confidence: avgConfidence)
                finalSpeakerId = speaker.id
            }
            
            // Track quality scores
            speakerQualityScores[finalSpeakerId] = max(
                speakerQualityScores[finalSpeakerId] ?? 0,
                avgConfidence
            )
            
            // Update database
            updatedDatabase[finalSpeakerId] = firstSegment.embedding
            
            // Create updated segments for this speaker
            for segment in segments {
                let updatedSegment = TimedSpeakerSegment(
                    speakerId: finalSpeakerId,
                    embedding: segment.embedding,
                    startTimeSeconds: segment.startTimeSeconds,
                    endTimeSeconds: segment.endTimeSeconds,
                    qualityScore: segment.qualityScore
                )
                updatedSegments.append(updatedSegment)
            }
        }
        
        // Batch save operations
        speakerDatabase = updatedDatabase
        saveSpeakerDatabase(to: context)
        
        // Single context save for all updates
        try? context.save()
        
        // Log speaker information
        let uniqueSpeakers = Set(updatedSegments.map { $0.speakerId })
        print("[DiarizationManager] Enhanced result with \(updatedSegments.count) segments and \(uniqueSpeakers.count) unique speakers")
        
        // Sort segments by start time for consistency
        updatedSegments.sort { $0.startTimeSeconds < $1.startTimeSeconds }
        
        // Create enhanced result
        return DiarizationResult(
            segments: updatedSegments,
            speakerDatabase: updatedDatabase,
            timings: result.timings
        )
    }
    
    // MARK: - Post-Processing Methods
    
    private func combineSameSpeakerSegments(_ result: DiarizationResult) async -> DiarizationResult {
        var combinedSegments: [TimedSpeakerSegment] = []
        var currentSegment: TimedSpeakerSegment?
        
        // Sort segments by start time
        let sortedSegments = result.segments.sorted { $0.startTimeSeconds < $1.startTimeSeconds }
        
        for segment in sortedSegments {
            if let current = currentSegment {
                // Check if this segment is from the same speaker and close in time
                let timeDifference = segment.startTimeSeconds - current.endTimeSeconds
                if current.speakerId == segment.speakerId && timeDifference < 1.0 { // Within 1 second
                    // Extend the current segment
                    currentSegment = TimedSpeakerSegment(
                        speakerId: current.speakerId,
                        embedding: current.embedding, // Keep first embedding
                        startTimeSeconds: current.startTimeSeconds,
                        endTimeSeconds: segment.endTimeSeconds,
                        qualityScore: max(current.qualityScore, segment.qualityScore)
                    )
                } else {
                    // Different speaker or too far apart, save current and start new
                    combinedSegments.append(current)
                    currentSegment = segment
                }
            } else {
                currentSegment = segment
            }
        }
        
        // Add the last segment
        if let current = currentSegment {
            combinedSegments.append(current)
        }
        
        print("[DiarizationManager] Combined segments: \(sortedSegments.count) -> \(combinedSegments.count)")
        
        return DiarizationResult(
            segments: combinedSegments,
            speakerDatabase: result.speakerDatabase,
            timings: result.timings
        )
    }
    
    private func mergePartialSentences(_ result: DiarizationResult) async -> DiarizationResult {
        var mergedSegments: [TimedSpeakerSegment] = []
        var pendingSegment: TimedSpeakerSegment?
        
        for segment in result.segments {
            if let pending = pendingSegment {
                // Check if segments are very close (partial sentence split)
                let timeDifference = segment.startTimeSeconds - pending.endTimeSeconds
                if timeDifference < 0.3 { // Within 300ms - likely same sentence
                    // Merge with pending segment
                    let merged = TimedSpeakerSegment(
                        speakerId: pending.speakerId, // Keep first speaker if different
                        embedding: pending.embedding,
                        startTimeSeconds: pending.startTimeSeconds,
                        endTimeSeconds: segment.endTimeSeconds,
                        qualityScore: max(pending.qualityScore, segment.qualityScore)
                    )
                    pendingSegment = merged
                } else {
                    // Too far apart, save pending and process current
                    mergedSegments.append(pending)
                    pendingSegment = segment
                }
            } else {
                pendingSegment = segment
            }
        }
        
        // Add the last segment
        if let pending = pendingSegment {
            mergedSegments.append(pending)
        }
        
        return DiarizationResult(
            segments: mergedSegments,
            speakerDatabase: result.speakerDatabase,
            timings: result.timings
        )
    }
    
    // MARK: - Speaker Merging (from FluidAudio)
    
    private func mergeSimilarSpeakers(_ result: DiarizationResult) async -> DiarizationResult {
        var mergedSegments = result.segments
        var mergedDatabase = result.speakerDatabase
        var mergedPairs: [(from: String, to: String)] = []
        
        // Find similar speakers to merge
        let speakerIds = Array(Set(result.segments.map { $0.speakerId }))
        
        for i in 0..<speakerIds.count {
            for j in (i + 1)..<speakerIds.count {
                let id1 = speakerIds[i]
                let id2 = speakerIds[j]
                
                // Skip if already merged
                if mergedPairs.contains(where: { $0.from == id2 }) { continue }
                
                if let emb1 = mergedDatabase?[id1], let emb2 = mergedDatabase?[id2] {
                    let similarity = calculateCosineSimilarity(emb1, emb2)
                    
                    // Merge if similarity is above threshold (default 0.7 when speakerMergingThreshold = 0.3)
                    let mergeThreshold = 1.0 - speakerMergingThreshold
                    if similarity >= mergeThreshold {
                        print("[DiarizationManager] Merging similar speakers: \(id2) into \(id1) (similarity: \(similarity), threshold: \(mergeThreshold))")
                        mergedPairs.append((from: id2, to: id1))
                        
                        // Update the embedding with weighted average
                        if let quality1 = speakerQualityScores[id1],
                           let quality2 = speakerQualityScores[id2] {
                            let totalQuality = quality1 + quality2
                            let weight1 = quality1 / totalQuality
                            let weight2 = quality2 / totalQuality
                            
                            // Weighted average of embeddings
                            var mergedEmbedding: [Float] = []
                            for k in 0..<min(emb1.count, emb2.count) {
                                mergedEmbedding.append(emb1[k] * weight1 + emb2[k] * weight2)
                            }
                            mergedDatabase?[id1] = mergedEmbedding
                            
                            // Update quality score
                            speakerQualityScores[id1] = max(quality1, quality2)
                        }
                    }
                }
            }
        }
        
        // Apply merges to segments
        for pair in mergedPairs {
            mergedSegments = mergedSegments.map { segment in
                if segment.speakerId == pair.from {
                    return TimedSpeakerSegment(
                        speakerId: pair.to,
                        embedding: segment.embedding,
                        startTimeSeconds: segment.startTimeSeconds,
                        endTimeSeconds: segment.endTimeSeconds,
                        qualityScore: segment.qualityScore
                    )
                }
                return segment
            }
            
            // Remove merged speaker from database
            mergedDatabase?.removeValue(forKey: pair.from)
        }
        
        print("[DiarizationManager] Merged \(mergedPairs.count) speaker pairs")
        
        return DiarizationResult(
            segments: mergedSegments,
            speakerDatabase: mergedDatabase,
            timings: result.timings
        )
    }
    
    // MARK: - Embedding Quality Calculation
    
    private func calculateEmbeddingQuality(_ embedding: [Float]) -> Float {
        // Calculate magnitude-based quality score (from FluidAudio)
        let magnitude = sqrt(embedding.map { $0 * $0 }.reduce(0, +))
        return min(1.0, magnitude / 10.0)
    }
    
    // MARK: - Overlap Detection
    
    func detectOverlappingSpeakers(in segments: [TimedSpeakerSegment]) -> [(TimeInterval, TimeInterval, [String])] {
        var overlaps: [(TimeInterval, TimeInterval, [String])] = []
        
        for i in 0..<segments.count {
            for j in (i + 1)..<segments.count {
                let seg1 = segments[i]
                let seg2 = segments[j]
                
                // Check for overlap
                let overlapStart = max(seg1.startTimeSeconds, seg2.startTimeSeconds)
                let overlapEnd = min(seg1.endTimeSeconds, seg2.endTimeSeconds)
                
                if overlapStart < overlapEnd {
                    // Found overlap
                    let speakers = [seg1.speakerId, seg2.speakerId]
                    overlaps.append((TimeInterval(overlapStart), TimeInterval(overlapEnd), speakers))
                }
            }
        }
        
        return overlaps
    }
    
    // MARK: - Cosine Similarity Helper
    
    private func calculateCosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        
        var dotProduct: Float = 0
        var magnitudeA: Float = 0
        var magnitudeB: Float = 0
        
        for i in 0..<a.count {
            dotProduct += a[i] * b[i]
            magnitudeA += a[i] * a[i]
            magnitudeB += b[i] * b[i]
        }
        
        let magnitude = sqrt(magnitudeA) * sqrt(magnitudeB)
        return magnitude > 0 ? dotProduct / magnitude : 0
    }
    
    // MARK: - Reset and Cleanup
    
    func reset() {
        audioBuffer.removeAll()
        lastResult = nil
        lastError = nil
        processingProgress = 0.0
        isProcessing = false
    }
    
    func validateAudio(_ audio: [Float]) async -> AudioValidationResult? {
        guard let diarizer = fluidDiarizer else { return nil }
        return diarizer.validateAudio(audio)
    }
}

// MARK: - Error Types

enum DiarizationError: LocalizedError {
    case notInitialized
    case processingFailed(String)
    case invalidAudioFormat
    case configurationError(String)
    
    var errorDescription: String? {
        switch self {
        case .notInitialized:
            return "Diarization manager not initialized"
        case .processingFailed(let message):
            return "Diarization processing failed: \(message)"
        case .invalidAudioFormat:
            return "Invalid audio format for diarization"
        case .configurationError(let message):
            return "Diarization configuration error: \(message)"
        }
    }
}

// MARK: - Progress Tracking

extension DiarizationManager {
    func estimateProgress(for audioLength: TimeInterval) -> Double {
        // Rough estimation based on typical processing speed
        let estimatedProcessingTime = audioLength * 0.1 // 10% of real-time
        return min(processingProgress / estimatedProcessingTime, 1.0)
    }
}

