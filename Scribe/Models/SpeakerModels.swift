import Foundation
import SwiftData
import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

// MARK: - Speaker Model

@Model
class Speaker {
    var id: String
    var name: String
    var colorRed: Double
    var colorGreen: Double
    var colorBlue: Double
    var createdAt: Date
    var embedding: [Float]?
    var lastSeenAt: Date?
    var totalSegments: Int = 0
    var averageConfidence: Float = 0.0
    var isUserNamed: Bool = false  // True if user manually set the name
    var isPersistent: Bool = false  // True if this speaker should be retained for future memos
    
    // Computed property for SwiftUI Color
    var displayColor: Color {
        get {
            return Color(red: colorRed, green: colorGreen, blue: colorBlue)
        }
        set {
            // Convert SwiftUI Color to RGB components using platform-specific methods
            #if os(iOS)
            let uiColor = UIColor(newValue)
            var red: CGFloat = 0
            var green: CGFloat = 0
            var blue: CGFloat = 0
            var alpha: CGFloat = 0
            uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            colorRed = Double(red)
            colorGreen = Double(green)
            colorBlue = Double(blue)
            #else
            let nsColor = NSColor(newValue)
            let rgbColor = nsColor.usingColorSpace(.sRGB) ?? NSColor.blue
            colorRed = Double(rgbColor.redComponent)
            colorGreen = Double(rgbColor.greenComponent)
            colorBlue = Double(rgbColor.blueComponent)
            #endif
        }
    }
    
    init(id: String = UUID().uuidString, name: String, displayColor: Color = .blue, embedding: [Float]? = nil) {
        self.id = id
        self.name = name
        self.createdAt = Date()
        self.embedding = embedding
        
        // Initialize color components using platform-specific methods
        #if os(iOS)
        let uiColor = UIColor(displayColor)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        self.colorRed = Double(red)
        self.colorGreen = Double(green)
        self.colorBlue = Double(blue)
        #else
        let nsColor = NSColor(displayColor)
        let rgbColor = nsColor.usingColorSpace(.sRGB) ?? NSColor.blue
        self.colorRed = Double(rgbColor.redComponent)
        self.colorGreen = Double(rgbColor.greenComponent)
        self.colorBlue = Double(rgbColor.blueComponent)
        #endif
    }
    
    // Generate a unique color for a new speaker
    static func generateSpeakerColor(for speakerIndex: Int) -> Color {
        let colors: [Color] = [
            .blue, .green, .orange, .purple, .pink, .yellow, .cyan, .mint, .indigo, .brown
        ]
        return colors[speakerIndex % colors.count]
    }
}

// MARK: - Speaker Segment Model

@Model
class SpeakerSegment {
    var id: String
    var speakerId: String
    var startTime: TimeInterval
    var endTime: TimeInterval
    var text: String
    var confidence: Float
    var embedding: [Float]?
    
    // Relationship to the memo this segment belongs to
    var memo: Memo?
    
    var duration: TimeInterval {
        endTime - startTime
    }
    
    init(
        id: String = UUID().uuidString,
        speakerId: String,
        startTime: TimeInterval,
        endTime: TimeInterval,
        text: String = "",
        confidence: Float = 0.0,
        embedding: [Float]? = nil
    ) {
        self.id = id
        self.speakerId = speakerId
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
        self.confidence = confidence
        self.embedding = embedding
    }
}

// MARK: - Diarization Result
// Note: Using FluidAudio.DiarizationResult and FluidAudio.TimedSpeakerSegment directly

// MARK: - Diarization Configuration

struct DiarizationConfig {
    var isEnabled: Bool = true
    var clusteringThreshold: Float = 0.7
    var minSegmentDuration: TimeInterval = 0.5
    var maxSpeakers: Int? = nil
    var enableRealTimeProcessing: Bool = false
    var persistSpeakerDatabase: Bool = true
    var minActivityThreshold: Float = 10.0
    
    static let `default` = DiarizationConfig()
}

// MARK: - Global Speaker Database

@Model
class SpeakerDatabase {
    var id: String
    var speakerEmbeddings: Data? // Serialized dictionary of speaker ID to embedding
    var lastUpdated: Date
    
    @Transient private var _embeddingsCache: [String: [Float]]?
    
    var embeddings: [String: [Float]] {
        get {
            if let cache = _embeddingsCache {
                return cache
            }
            guard let data = speakerEmbeddings,
                  let decoded = try? JSONDecoder().decode([String: [Float]].self, from: data) else {
                return [:]
            }
            _embeddingsCache = decoded
            return decoded
        }
        set {
            _embeddingsCache = newValue
            speakerEmbeddings = try? JSONEncoder().encode(newValue)
            lastUpdated = Date()
        }
    }
    
    init() {
        self.id = "global_speaker_db"
        self.lastUpdated = Date()
        self.speakerEmbeddings = nil
    }
    
    static func shared(in context: ModelContext) -> SpeakerDatabase {
        let descriptor = FetchDescriptor<SpeakerDatabase>(predicate: #Predicate { $0.id == "global_speaker_db" })
        
        if let existing = try? context.fetch(descriptor).first {
            return existing
        }
        
        let new = SpeakerDatabase()
        context.insert(new)
        return new
    }
}

// MARK: - Speaker Attribution Extension

extension AttributedString {
    static let speakerIDKey = AttributeScopes.FoundationAttributes.SpeakerIDAttribute.self
    static let speakerConfidenceKey = AttributeScopes.FoundationAttributes.SpeakerConfidenceAttribute.self
}

extension AttributeScopes.FoundationAttributes {
    enum SpeakerIDAttribute: CodableAttributedStringKey, MarkdownDecodableAttributedStringKey {
        typealias Value = String
        static let name = "speakerID"
    }
    
    enum SpeakerConfidenceAttribute: CodableAttributedStringKey, MarkdownDecodableAttributedStringKey {
        typealias Value = Float
        static let name = "speakerConfidence"
    }
}

// MARK: - Speaker Management Extensions

extension Speaker {
    static func findOrCreate(withId id: String, embedding: [Float]? = nil, in context: ModelContext) -> Speaker {
        let speakerId = id
        let descriptor = FetchDescriptor<Speaker>(predicate: #Predicate { speaker in
            speaker.id == speakerId
        })
        
        // First check if speaker with this ID already exists
        if let existingSpeaker = try? context.fetch(descriptor).first {
            existingSpeaker.lastSeenAt = Date()
            // Update embedding if provided and speaker doesn't have one
            if existingSpeaker.embedding == nil, let embedding = embedding {
                existingSpeaker.embedding = embedding
            }
            return existingSpeaker
        }
        
        // Note: Speaker matching by embedding should be done in DiarizationManager
        // This method should only create a speaker with the given ID
        // The ID should already be determined by the matching logic
        
        // Create new speaker with generated name and color
        let speakerCount = (try? context.fetch(FetchDescriptor<Speaker>()).count) ?? 0
        let newSpeaker = Speaker(
            id: id,
            name: "Speaker \(speakerCount + 1)",
            displayColor: Speaker.generateSpeakerColor(for: speakerCount),
            embedding: embedding
        )
        newSpeaker.lastSeenAt = Date()
        
        context.insert(newSpeaker)
        
        // Try to save immediately
        do {
            try context.save()
        } catch {
            // Silently handle save errors - the context will be saved later
        }
        
        return newSpeaker
    }
    
    // Find persistent speaker by embedding similarity
    static func findPersistentSpeakerBySimilarity(embedding: [Float], threshold: Float = 0.85, in context: ModelContext) -> Speaker? {
        let descriptor = FetchDescriptor<Speaker>(predicate: #Predicate { speaker in
            speaker.isPersistent == true
        })
        guard let speakers = try? context.fetch(descriptor) else { return nil }
        
        var bestMatch: (speaker: Speaker, similarity: Float)?
        
        for speaker in speakers {
            // Skip speakers without embeddings or with isPersistent = false
            guard speaker.isPersistent == true,
                  let speakerEmbedding = speaker.embedding else { continue }
            let similarity = cosineSimilarity(embedding, speakerEmbedding)
            if similarity >= threshold {
                if bestMatch == nil || similarity > bestMatch!.similarity {
                    bestMatch = (speaker, similarity)
                }
            }
        }
        
        return bestMatch?.speaker
    }
    
    // Update speaker statistics
    func updateStatistics(confidence: Float) {
        totalSegments += 1
        // Update running average confidence
        averageConfidence = ((averageConfidence * Float(totalSegments - 1)) + confidence) / Float(totalSegments)
        lastSeenAt = Date()
    }
    
    // Migrate existing named speakers to be persistent
    static func migrateNamedSpeakersToPersistent(in context: ModelContext) {
        let descriptor = FetchDescriptor<Speaker>(predicate: #Predicate { speaker in
            speaker.isUserNamed == true && speaker.isPersistent == false
        })
        
        if let speakers = try? context.fetch(descriptor) {
            for speaker in speakers {
                speaker.isPersistent = true
                
                // Save to persistent storage
                PersistentSpeakerManager.shared.saveSpeaker(speaker)
            }
            
            do {
                try context.save()
                print("Migrated \(speakers.count) named speakers to persistent storage")
            } catch {
                print("Failed to migrate speakers: \(error)")
            }
        }
        
        // Also ensure all persistent speakers in database are saved to disk
        let persistentDescriptor = FetchDescriptor<Speaker>(predicate: #Predicate { speaker in
            speaker.isPersistent == true
        })
        
        if let persistentSpeakers = try? context.fetch(persistentDescriptor) {
            for speaker in persistentSpeakers {
                if speaker.embedding != nil {
                    PersistentSpeakerManager.shared.saveSpeaker(speaker)
                }
            }
        }
    }
    
    // Find speaker by embedding similarity
    static func findBySimilarity(embedding: [Float], threshold: Float = 0.7, in context: ModelContext) -> Speaker? {
        let descriptor = FetchDescriptor<Speaker>()
        guard let speakers = try? context.fetch(descriptor) else { return nil }
        
        for speaker in speakers {
            guard let speakerEmbedding = speaker.embedding else { continue }
            let similarity = cosineSimilarity(embedding, speakerEmbedding)
            if similarity >= threshold {
                return speaker
            }
        }
        return nil
    }
    
    // Calculate cosine similarity between embeddings
    static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
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
}