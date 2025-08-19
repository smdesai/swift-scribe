import AVFoundation
import Foundation
import FluidAudio
import SwiftData
import SwiftUI
import WhisperKit

@Model
class Memo {
    typealias StartTime = CMTime

    var title: String
    var text: AttributedString
    var url: URL?  // Audio file URL
    var isDone: Bool
    var createdAt: Date
    var duration: TimeInterval?


    // Speaker diarization data
    var hasSpeakerData: Bool = false
    var speakerSegments: [SpeakerSegment] = []

    // This can't be persisted with SwiftData since DiarizationResult isn't a @Model
    @Transient var diarizationResult: DiarizationResult?
    
    // Cache for merged speaker segments to avoid reprocessing
    @Transient var cachedMergedSegments: [SpeakerSegment]?
    @Transient var cachedMergedSegmentsHash: Int = 0

    init(
        title: String, text: AttributedString, url: URL? = nil, isDone: Bool = false,
        duration: TimeInterval? = nil
    ) {
        self.title = title
        self.text = text
        self.url = url
        self.isDone = isDone
        self.duration = duration
        self.createdAt = Date()
        self.hasSpeakerData = false
        self.speakerSegments = []
        self.diarizationResult = nil
        self.cachedMergedSegments = nil
        self.cachedMergedSegmentsHash = 0
    }

}

extension Memo {
    static func blank() -> Memo {
        return .init(title: "New Memo", text: AttributedString(""))
    }

    // MARK: - Speaker Diarization Methods

        /// Updates the memo with diarization results
    func updateWithDiarizationResult(
        _ result: DiarizationResult, 
        transcribedText: String, 
        transcriptionSegments: [TranscriptionSegment],
        in context: ModelContext
    ) {
        self.diarizationResult = result
        self.hasSpeakerData = !result.segments.isEmpty

        // Clear existing segments and cache
        for segment in self.speakerSegments {
            context.delete(segment)
        }
        self.speakerSegments.removeAll()
        self.cachedMergedSegments = nil
        self.cachedMergedSegmentsHash = 0

        // Track which transcription segments have been assigned to avoid duplication
        var assignedTranscriptionSegments = Set<Int>()
        
        // Sort speaker segments by start time to process chronologically
        let sortedDiarizationSegments = result.segments.sorted { $0.startTimeSeconds < $1.startTimeSeconds }
        
        // Debug: Check for duplicate segments
        var seenTimeRanges: [(Float, Float)] = []
        for segment in sortedDiarizationSegments {
            let timeRange = (segment.startTimeSeconds, segment.endTimeSeconds)
            if seenTimeRanges.contains(where: { abs($0.0 - timeRange.0) < 0.01 && abs($0.1 - timeRange.1) < 0.01 }) {
                print("Warning: Duplicate time range detected: \(timeRange)")
            }
            seenTimeRanges.append(timeRange)
        }
        
        // Create speaker segments and ensure speakers exist in database
        for (index, segment) in sortedDiarizationSegments.enumerated() {
            // Use proper timestamp-based text extraction with transcription segments
            let segmentText = extractTextForTimeRangeExclusive(
                from: transcribedText,
                startTime: segment.startTimeSeconds,
                endTime: segment.endTimeSeconds,
                transcriptionSegments: transcriptionSegments,
                assignedIndices: &assignedTranscriptionSegments
            )
            
            // Log segment info only if text is empty (for debugging)
            if segmentText.isEmpty {
                print("Warning: Empty text for speaker segment \(index) at \(segment.startTimeSeconds)-\(segment.endTimeSeconds)s")
            }
            
            let speakerSegment = SpeakerSegment(
                speakerId: segment.speakerId,
                startTime: TimeInterval(segment.startTimeSeconds),
                endTime: TimeInterval(segment.endTimeSeconds),
                text: segmentText,
                confidence: segment.qualityScore,
                embedding: segment.embedding
            )
            speakerSegment.memo = self
            self.speakerSegments.append(speakerSegment)
            context.insert(speakerSegment)

            // Ensure speaker exists in database (pass embedding for matching)
            let speaker = Speaker.findOrCreate(
                withId: segment.speakerId, 
                embedding: segment.embedding,
                in: context
            )
            speaker.updateStatistics(confidence: segment.qualityScore)
        }
        
        // Save context to persist speakers
        do {
            try context.save()
        } catch {
            print("Failed to save context after updating speakers: \(error)")
        }
    }

    /// Returns an attributed string with speaker information embedded
    func textWithSpeakerAttributes(context: ModelContext) -> AttributedString {
        guard hasSpeakerData else { return text }

        var attributedText = AttributedString(String(text.characters))

                // Apply speaker attributes to segments
        for segment in speakerSegments.sorted(by: { $0.startTime < $1.startTime }) {
            // Find the corresponding speaker
            let speakerId = segment.speakerId
            let descriptor = FetchDescriptor<Speaker>(predicate: #Predicate { speaker in
                speaker.id == speakerId
            })
            if let speaker = try? context.fetch(descriptor).first {

                // Estimate character positions based on timing (rough approximation)
                let totalDuration = duration ?? 1.0
                let totalLength = attributedText.characters.count

                let startPosition = max(0, Int((segment.startTime / totalDuration) * Double(totalLength)))
                let endPosition = min(totalLength, Int((segment.endTime / totalDuration) * Double(totalLength)))

                if startPosition < endPosition {
                    let range = attributedText.characters.index(attributedText.startIndex, offsetBy: startPosition)..<attributedText.characters.index(attributedText.startIndex, offsetBy: endPosition)

                    attributedText[range].foregroundColor = speaker.displayColor
                    attributedText[range][AttributedString.speakerIDKey] = speaker.id
                    attributedText[range][AttributedString.speakerConfidenceKey] = segment.confidence
                }
            }
        }

        return attributedText
    }

        /// Returns speakers present in this memo that have actual content
    func speakers(in context: ModelContext) -> [Speaker] {
        guard hasSpeakerData else { 
            return [] 
        }

        // Filter segments to only include those with non-empty text
        let speakerIdsWithContent = Set(speakerSegments
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { $0.speakerId })
        
        // If no speakers have content, return empty array
        guard !speakerIdsWithContent.isEmpty else {
            return []
        }
        
        // Fetch all speakers and filter in memory to avoid predicate issues
        let allSpeakers = (try? context.fetch(FetchDescriptor<Speaker>())) ?? []
        
        let matchingSpeakers = allSpeakers.filter { speakerIdsWithContent.contains($0.id) }
        
        return matchingSpeakers
    }
    
    // Helper method to find the last sentence break in text
    private func findLastSentenceBreak(_ text: String) -> Int? {
        let sentenceEnders = [".", "!", "?", "..."]
        var lastBreakIndex: Int? = nil
        
        // Search backwards for sentence-ending punctuation followed by space or end of string
        for (index, _) in text.enumerated().reversed() {
            for ender in sentenceEnders {
                if text[text.index(text.startIndex, offsetBy: index)...].hasPrefix(ender) {
                    // Check if this is followed by a space or is at the end
                    let nextIndex = text.index(text.startIndex, offsetBy: index + ender.count)
                    if nextIndex >= text.endIndex || text[nextIndex].isWhitespace {
                        lastBreakIndex = index + ender.count - 1
                        break
                    }
                }
            }
            if lastBreakIndex != nil { break }
        }
        
        return lastBreakIndex
    }
    
    // Helper method to find the first sentence break in text
    private func findFirstSentenceBreak(_ text: String) -> Int? {
        let sentenceEnders = [".", "!", "?"]
        
        // Search forwards for sentence-ending punctuation
        for (index, char) in text.enumerated() {
            if sentenceEnders.contains(String(char)) {
                // Check if this is followed by a space or is at the end
                let nextIndex = text.index(text.startIndex, offsetBy: index + 1)
                if nextIndex >= text.endIndex || text[nextIndex].isWhitespace || text[nextIndex].isUppercase {
                    return index
                }
            }
        }
        
        return nil
    }
    
    // Helper method to merge partial sentences across speaker transitions
    private func mergePartialSentencesAcrossSpeakers(_ segments: [SpeakerSegment]) -> [SpeakerSegment] {
        guard segments.count > 1 else { return segments }
        
        var mergedSegments: [SpeakerSegment] = []
        var i = 0
        
        while i < segments.count {
            let currentSegment = segments[i]
            
            // Check if we have a next segment and they are from different speakers
            if i < segments.count - 1 {
                let nextSegment = segments[i + 1]
                
                if currentSegment.speakerId != nextSegment.speakerId {
                    let currentText = currentSegment.text.trimmingCharacters(in: .whitespaces)
                    let nextText = nextSegment.text.trimmingCharacters(in: .whitespaces)
                    
                    // Find the last complete sentence in current segment
                    let lastBreakInCurrent = findLastSentenceBreak(currentText)
                    
                    // Find the first sentence break in next segment
                    let firstBreakInNext = findFirstSentenceBreak(nextText)
                    
                    // Check if we have a partial sentence spanning speakers
                    // This happens when current doesn't end with sentence break OR next doesn't start with uppercase after potential break
                    let currentEndsPartial = lastBreakInCurrent == nil || lastBreakInCurrent! < currentText.count - 1
                    
                    if currentEndsPartial {
                        // Extract the partial sentence from current segment
                        var currentComplete = ""
                        var currentPartial = currentText
                        
                        if let lastBreak = lastBreakInCurrent {
                            let breakIndex = currentText.index(currentText.startIndex, offsetBy: lastBreak + 1)
                            currentComplete = String(currentText[..<breakIndex]).trimmingCharacters(in: .whitespaces)
                            currentPartial = String(currentText[breakIndex...]).trimmingCharacters(in: .whitespaces)
                        }
                        
                        // Extract the completion from next segment
                        var nextPartial = ""
                        var nextRemaining = nextText
                        
                        if let firstBreak = firstBreakInNext {
                            let breakIndex = nextText.index(nextText.startIndex, offsetBy: firstBreak + 1)
                            nextPartial = String(nextText[..<breakIndex]).trimmingCharacters(in: .whitespaces)
                            nextRemaining = String(nextText[breakIndex...]).trimmingCharacters(in: .whitespaces)
                        } else {
                            // Entire next segment is part of the partial sentence
                            nextPartial = nextText
                            nextRemaining = ""
                        }
                        
                        // Combine the partial sentence
                        let combinedPartial = currentPartial.isEmpty ? nextPartial : 
                                            (nextPartial.isEmpty ? currentPartial : "\(currentPartial) \(nextPartial)")
                        
                        // Decide ownership based on which segment contributes more to the partial sentence
                        let currentContribution = currentPartial.count
                        let nextContribution = nextPartial.count
                        
                        if currentContribution > nextContribution {
                            // Current speaker gets the combined partial
                            var newCurrentText = currentComplete
                            if !newCurrentText.isEmpty && !combinedPartial.isEmpty {
                                newCurrentText += " "
                            }
                            newCurrentText += combinedPartial
                            
                            if !newCurrentText.isEmpty {
                                let newCurrentSegment = SpeakerSegment(
                                    speakerId: currentSegment.speakerId,
                                    startTime: currentSegment.startTime,
                                    endTime: currentSegment.endTime,
                                    text: newCurrentText,
                                    confidence: currentSegment.confidence,
                                    embedding: currentSegment.embedding
                                )
                                newCurrentSegment.memo = currentSegment.memo
                                mergedSegments.append(newCurrentSegment)
                            }
                            
                            // Next speaker gets only the remaining text
                            if !nextRemaining.isEmpty {
                                let newNextSegment = SpeakerSegment(
                                    speakerId: nextSegment.speakerId,
                                    startTime: nextSegment.startTime,
                                    endTime: nextSegment.endTime,
                                    text: nextRemaining,
                                    confidence: nextSegment.confidence,
                                    embedding: nextSegment.embedding
                                )
                                newNextSegment.memo = nextSegment.memo
                                mergedSegments.append(newNextSegment)
                            }
                        } else {
                            // Next speaker gets the combined partial
                            if !currentComplete.isEmpty {
                                let newCurrentSegment = SpeakerSegment(
                                    speakerId: currentSegment.speakerId,
                                    startTime: currentSegment.startTime,
                                    endTime: currentSegment.endTime,
                                    text: currentComplete,
                                    confidence: currentSegment.confidence,
                                    embedding: currentSegment.embedding
                                )
                                newCurrentSegment.memo = currentSegment.memo
                                mergedSegments.append(newCurrentSegment)
                            }
                            
                            // Next speaker gets combined partial plus remaining
                            var newNextText = combinedPartial
                            if !newNextText.isEmpty && !nextRemaining.isEmpty {
                                newNextText += " "
                            }
                            newNextText += nextRemaining
                            
                            if !newNextText.isEmpty {
                                let newNextSegment = SpeakerSegment(
                                    speakerId: nextSegment.speakerId,
                                    startTime: nextSegment.startTime,
                                    endTime: nextSegment.endTime,
                                    text: newNextText,
                                    confidence: nextSegment.confidence,
                                    embedding: nextSegment.embedding
                                )
                                newNextSegment.memo = nextSegment.memo
                                mergedSegments.append(newNextSegment)
                            }
                        }
                        
                        i += 2 // Skip both segments as we've processed them
                        continue
                    }
                }
            }
            
            // If no merging happened, just add the current segment
            mergedSegments.append(currentSegment)
            i += 1
        }
        
        return mergedSegments
    }
    
    // Helper method to split text into sentences
    private func splitIntoSentences(_ text: String) -> [String] {
        let trimmedText = text.trimmingCharacters(in: .whitespaces)
        
        // If text doesn't contain any sentence-ending punctuation, return it as a single sentence
        if !trimmedText.contains(".") && !trimmedText.contains("!") && !trimmedText.contains("?") {
            return [trimmedText]
        }
        
        // Use NSLinguisticTagger for more accurate sentence detection
        var sentences: [String] = []        
        trimmedText.enumerateSubstrings(in: trimmedText.startIndex..<trimmedText.endIndex, options: [.bySentences, .localized]) { (substring, _, _, _) in
            if let sentence = substring?.trimmingCharacters(in: .whitespaces), !sentence.isEmpty {
                sentences.append(sentence)
            }
        }
        
        // If no sentences were found, return the whole text
        if sentences.isEmpty {
            return [trimmedText]
        }
        
        
        return sentences
    }
    
    // Helper method to extract text exclusively (each transcription segment used only once)
    private func extractTextForTimeRangeExclusive(
        from fullText: String,
        startTime: Float,
        endTime: Float,
        transcriptionSegments: [TranscriptionSegment],
        assignedIndices: inout Set<Int>
    ) -> String {
        
        // For live recording, transcription segments might not have valid timestamps
        // Check if segments have reasonable timestamps
        let hasValidTimestamps = !transcriptionSegments.isEmpty && 
            transcriptionSegments.allSatisfy { $0.end > $0.start && $0.end > 0 }
        
        // If no valid transcription segments available, use proportion-based fallback
        if transcriptionSegments.isEmpty || !hasValidTimestamps {
            // For live recording, distribute text proportionally based on time
            return extractTextProportionally(
                from: fullText, 
                startTime: startTime, 
                endTime: endTime,
                totalDuration: endTime // Use the last segment's end time as total duration
            )
        }
        
        var extractedText: [String] = []
        
        // Find transcription segments that best match this speaker segment
        for (index, segment) in transcriptionSegments.enumerated() {
            // Skip if already assigned to another speaker
            if assignedIndices.contains(index) {
                continue
            }
            
            let segmentStart = segment.start
            let segmentEnd = segment.end
            let segmentMidpoint = (segmentStart + segmentEnd) / 2
            
            // Check if this segment's midpoint falls within the speaker's time range
            // Also ensure the segment has substantial overlap (>50% of segment duration)
            if segmentMidpoint >= startTime && segmentMidpoint <= endTime {
                // Calculate overlap percentage
                let overlapStart = max(segmentStart, startTime)
                let overlapEnd = min(segmentEnd, endTime)
                let overlapDuration = max(0, overlapEnd - overlapStart)
                let segmentDuration = segmentEnd - segmentStart
                
                if segmentDuration > 0 {
                    let overlapRatio = overlapDuration / segmentDuration
                    // Only assign if >50% overlap
                    if overlapRatio > 0.5 {
                        extractedText.append(segment.text)
                        assignedIndices.insert(index)
                    }
                }
            }
        }
        
        let result = extractedText.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return result
    }
    
    // New method for proportional text extraction for live recordings
    private func extractTextProportionally(
        from fullText: String,
        startTime: Float,
        endTime: Float,
        totalDuration: Float
    ) -> String {
        guard totalDuration > 0, !fullText.isEmpty else { return "" }
        
        // Split text into words
        let words = fullText.split(separator: " ", omittingEmptySubsequences: true)
        guard !words.isEmpty else { return "" }
        
        // Calculate word indices based on time proportion
        let wordsPerSecond = Float(words.count) / totalDuration
        let startWordIndex = Int(startTime * wordsPerSecond)
        let endWordIndex = min(Int(endTime * wordsPerSecond), words.count)
        
        // Ensure valid range
        guard startWordIndex < words.count && startWordIndex < endWordIndex else {
            return ""
        }
        
        // Extract words for this time range
        let extractedWords = words[startWordIndex..<endWordIndex]
        return extractedWords.joined(separator: " ")
    }
    
    // Helper method to extract text for a given time range using actual transcription timestamps
    private func extractTextForTimeRange(
        from fullText: String,
        startTime: Float,
        endTime: Float,
        transcriptionSegments: [TranscriptionSegment]
    ) -> String {
        
        // If no transcription segments available, fall back to simple text extraction
        guard !transcriptionSegments.isEmpty else {
            // Return a portion of the text based on time ratio (fallback)
            return extractTextFallback(from: fullText, startTime: startTime, endTime: endTime)
        }
        
        var extractedText: [String] = []
        
        // Find all transcription segments that overlap with our time range
        for segment in transcriptionSegments {
            // Check if this transcription segment overlaps with our speaker time range
            let segmentStart = segment.start
            let segmentEnd = segment.end
            
            // Calculate overlap
            let overlapStart = max(segmentStart, startTime)
            let overlapEnd = min(segmentEnd, endTime)
            
            if overlapStart < overlapEnd {
                // There's an overlap - determine how much of this segment to include
                let segmentDuration = segmentEnd - segmentStart
                let overlapDuration = overlapEnd - overlapStart
                
                if segmentDuration > 0 {
                    let overlapRatio = overlapDuration / segmentDuration
                    
                    
                    // Only include segments that mostly belong to this speaker (>50% overlap)
                    if overlapRatio > 0.5 {
                        // Check if another speaker segment would have more claim to this text
                        // by checking the segment's midpoint
                        let segmentMidpoint = (segmentStart + segmentEnd) / 2
                        if segmentMidpoint >= startTime && segmentMidpoint <= endTime {
                            extractedText.append(segment.text)
                        } else {
                        }
                    } else {
                    }
                }
            }
        }
        
        let result = extractedText.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        
        // If we couldn't extract any text using timestamps, fall back to simple extraction
        if result.isEmpty {
            return extractTextFallback(from: fullText, startTime: startTime, endTime: endTime)
        }
        
        return result
    }
    
    // Fallback method for when transcription segments are not available
    private func extractTextFallback(from fullText: String, startTime: Float, endTime: Float) -> String {
        // Simple fallback: return a portion of the text
        // This is a last resort when we don't have proper timestamp data
        let words = fullText.split(separator: " ").map { String($0) }
        guard !words.isEmpty else { return "" }
        
        // Use a simple heuristic: assume ~2 words per second of speech
        let wordsPerSecond: Float = 2.5
        let expectedWords = Int((endTime - startTime) * wordsPerSecond)
        let limitedWords = min(expectedWords, 50) // Cap at 50 words per segment to avoid duplication
        
        // Try to find a reasonable starting point based on the start time
        // Assume the full text spans roughly evenly across time
        let totalEstimatedDuration = Float(words.count) / wordsPerSecond
        let startRatio = startTime / max(totalEstimatedDuration, 1.0)
        let startWordIndex = Int(Float(words.count) * startRatio)
        
        let safeStartIndex = min(max(0, startWordIndex), words.count - 1)
        let safeEndIndex = min(safeStartIndex + limitedWords, words.count)
        
        if safeStartIndex < safeEndIndex {
            let extractedWords = Array(words[safeStartIndex..<safeEndIndex])
            return extractedWords.joined(separator: " ")
        }
        
        return ""
    }

    /// Returns a formatted transcript with speaker labels
    func formattedTranscriptWithSpeakers(context: ModelContext, combineSameSpeaker: Bool = false, mergePartialSentences: Bool = false) -> AttributedString {
        guard hasSpeakerData else { return textBrokenUpByParagraphs() }

        var result = AttributedString("")
        // Filter out segments with empty text and then sort
        var sortedSegments = speakerSegments
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted(by: { $0.startTime < $1.startTime })
        
        // First, merge partial sentences if enabled (with caching)
        if mergePartialSentences {
            // Create a simple hash based on segment count and settings
            let currentHash = speakerSegments.count.hashValue ^ mergePartialSentences.hashValue
            
            // Check if we have cached merged segments
            if let cached = cachedMergedSegments, cachedMergedSegmentsHash == currentHash {
                sortedSegments = cached
            } else {
                // Perform the merge and cache the result
                sortedSegments = mergePartialSentencesAcrossSpeakers(sortedSegments)
                cachedMergedSegments = sortedSegments
                cachedMergedSegmentsHash = currentHash
            }
        }
        
        if combineSameSpeaker {
            // Combine consecutive segments from the same speaker
            var combinedSegments: [(speakerId: String, text: String, confidence: Float, startTime: TimeInterval, endTime: TimeInterval)] = []
            
            for segment in sortedSegments {
                // Skip empty segments (double-check after filtering)
                let trimmedText = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmedText.isEmpty { continue }
                
                if let lastIndex = combinedSegments.indices.last,
                   combinedSegments[lastIndex].speakerId == segment.speakerId {
                    // Combine with previous segment
                    combinedSegments[lastIndex].text += " " + trimmedText
                    combinedSegments[lastIndex].endTime = segment.endTime
                    // Average confidence
                    let count = Float(combinedSegments[lastIndex].text.split(separator: " ").count)
                    let newCount = Float(segment.text.split(separator: " ").count)
                    combinedSegments[lastIndex].confidence = (combinedSegments[lastIndex].confidence * count + segment.confidence * newCount) / (count + newCount)
                } else {
                    // Add as new segment (using trimmed text)
                    combinedSegments.append((
                        speakerId: segment.speakerId,
                        text: trimmedText,
                        confidence: segment.confidence,
                        startTime: segment.startTime,
                        endTime: segment.endTime
                    ))
                }
            }
            
            // Format combined segments
            for (index, combinedSegment) in combinedSegments.enumerated() {
                // Get speaker information
                let speakerId = combinedSegment.speakerId
                let descriptor = FetchDescriptor<Speaker>(predicate: #Predicate { speaker in
                    speaker.id == speakerId
                })
                let speaker = try? context.fetch(descriptor).first
                let speakerName = speaker?.name ?? "Speaker \(speakerId)"

                // Add speaker label with confidence
                var speakerLabel = AttributedString("\(speakerName)")
                speakerLabel.font = .headline
                speakerLabel.foregroundColor = speaker?.displayColor ?? .primary
                result.append(speakerLabel)
                
                // Add confidence indicator if available
                if combinedSegment.confidence > 0 {
                    var confidenceText = AttributedString(" (\(Int(combinedSegment.confidence * 100))%)")
                    confidenceText.font = .caption
                    confidenceText.foregroundColor = .secondary
                    result.append(confidenceText)
                }
                
                result.append(AttributedString(": "))

                // Add segment text
                var segmentText = AttributedString(combinedSegment.text)
                segmentText.foregroundColor = .primary
                result.append(segmentText)

                // Add line break between segments
                if index < combinedSegments.count - 1 {
                    result.append(AttributedString("\n\n"))
                }
            }
        } else {
            // Original behavior - show each segment separately
            for (index, segment) in sortedSegments.enumerated() {
                // Skip empty segments (double-check)
                let trimmedText = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmedText.isEmpty { continue }
                
                // Get speaker information
                let speakerId = segment.speakerId
                let descriptor = FetchDescriptor<Speaker>(predicate: #Predicate { speaker in
                    speaker.id == speakerId
                })
                let speaker = try? context.fetch(descriptor).first
                let speakerName = speaker?.name ?? "Speaker \(segment.speakerId)"

                // Add speaker label with confidence
                var speakerLabel = AttributedString("\(speakerName)")
                speakerLabel.font = .headline
                speakerLabel.foregroundColor = speaker?.displayColor ?? .primary
                result.append(speakerLabel)
                
                // Add confidence indicator if available
                if segment.confidence > 0 {
                    var confidenceText = AttributedString(" (\(Int(segment.confidence * 100))%)")
                    confidenceText.font = .caption
                    confidenceText.foregroundColor = .secondary
                    result.append(confidenceText)
                }
                
                result.append(AttributedString(": "))

                // Add segment text (using trimmed text)
                var segmentText = AttributedString(trimmedText)
                segmentText.foregroundColor = .primary
                result.append(segmentText)

                // Add line break between segments
                if index < sortedSegments.count - 1 {
                    result.append(AttributedString("\n\n"))
                }
            }
        }

        return result
    }

    func textBrokenUpByParagraphs() -> AttributedString {
        // For new memos during recording, URL is nil - this is normal
        if url == nil {
            return text
        } else {
            var final = AttributedString("")
            var working = AttributedString("")
            let copy = text
            copy.runs.forEach { run in
                if copy[run.range].characters.contains(".") {
                    working.append(copy[run.range])
                    final.append(working)
                    final.append(AttributedString("\n\n"))
                    working = AttributedString("")
                } else {
                    if working.characters.isEmpty {
                        let newText = copy[run.range].characters
                        let attributes = run.attributes
                        let trimmed = newText.trimmingPrefix(" ")
                        let newAttributed = AttributedString(trimmed, attributes: attributes)
                        working.append(newAttributed)
                    } else {
                        working.append(copy[run.range])
                    }
                }
            }

            if final.characters.isEmpty {
                return working
            }

            return final
        }
    }
}
