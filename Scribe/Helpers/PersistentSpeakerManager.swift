import Foundation
import SwiftUI
import SwiftData
import Combine

// MARK: - Persistent Speaker Data Model

struct PersistentSpeakerProfile: Codable {
    let id: String
    let name: String
    let colorRed: Double
    let colorGreen: Double
    let colorBlue: Double
    let embedding: [Float]
    let createdAt: Date
    let lastSeenAt: Date?
    let totalSegments: Int
    let averageConfidence: Float
    
    init(from speaker: Speaker) {
        self.id = speaker.id
        self.name = speaker.name
        self.colorRed = speaker.colorRed
        self.colorGreen = speaker.colorGreen
        self.colorBlue = speaker.colorBlue
        self.embedding = speaker.embedding ?? []
        self.createdAt = speaker.createdAt
        self.lastSeenAt = speaker.lastSeenAt
        self.totalSegments = speaker.totalSegments
        self.averageConfidence = speaker.averageConfidence
    }
    
    func updateSpeaker(_ speaker: Speaker) {
        speaker.name = self.name
        speaker.colorRed = self.colorRed
        speaker.colorGreen = self.colorGreen
        speaker.colorBlue = self.colorBlue
        speaker.embedding = self.embedding.isEmpty ? nil : self.embedding
        speaker.lastSeenAt = self.lastSeenAt
        speaker.totalSegments = self.totalSegments
        speaker.averageConfidence = self.averageConfidence
        speaker.isUserNamed = true
        speaker.isPersistent = true
    }
}

// MARK: - Persistent Speaker Manager

final class PersistentSpeakerManager: ObservableObject, @unchecked Sendable {
    static let shared = PersistentSpeakerManager()
    
    @Published private(set) var persistentProfiles: [String: PersistentSpeakerProfile] = [:]
    
    private let queue = DispatchQueue(label: "com.diarization.speakermanager", attributes: .concurrent)
    
    private let documentsDirectory: URL
    private let speakersFile: URL
    private let embeddingsDirectory: URL
    
    private init() {
        // Setup directories
        documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let speakerDataDirectory = documentsDirectory.appendingPathComponent("SpeakerProfiles")
        speakersFile = speakerDataDirectory.appendingPathComponent("speakers.json")
        embeddingsDirectory = speakerDataDirectory.appendingPathComponent("embeddings")
        
        // Create directories if they don't exist
        try? FileManager.default.createDirectory(at: speakerDataDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: embeddingsDirectory, withIntermediateDirectories: true)
        
        // Load existing profiles
        loadProfiles()
    }
    
    // MARK: - Public Methods
    
    /// Save a speaker as persistent to disk
    func saveSpeaker(_ speaker: Speaker) {
        guard speaker.isPersistent, speaker.embedding != nil else { return }
        
        let profile = PersistentSpeakerProfile(from: speaker)
        let speakerId = speaker.id  // Capture the ID before the async closure
        let speakerName = speaker.name  // Capture the name for logging
        
        queue.async(flags: .barrier) { [weak self] in
            self?.persistentProfiles[speakerId] = profile
            self?.saveProfiles()
        }
        
        print("Saved persistent speaker: \(speakerName) with ID: \(speakerId)")
    }
    
    /// Remove a speaker from persistent storage
    func removeSpeaker(withId id: String) {
        queue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            self.persistentProfiles.removeValue(forKey: id)
            self.saveProfiles()
            
            // Remove embedding file if it exists
            let embeddingFile = self.embeddingsDirectory.appendingPathComponent("\(id).bin")
            try? FileManager.default.removeItem(at: embeddingFile)
        }
        
        print("Removed persistent speaker with ID: \(id)")
    }
    
    /// Clear all persistent speakers
    func clearAllSpeakers() {
        queue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            self.persistentProfiles.removeAll()
            self.saveProfiles()
            
            // Remove all embedding files
            if let files = try? FileManager.default.contentsOfDirectory(at: self.embeddingsDirectory, includingPropertiesForKeys: nil) {
                for file in files {
                    try? FileManager.default.removeItem(at: file)
                }
            }
        }
        
        print("Cleared all persistent speakers")
    }
    
    /// Find a persistent speaker by embedding similarity
    func findSpeakerByEmbedding(_ embedding: [Float], threshold: Float = 0.85) -> PersistentSpeakerProfile? {
        var bestMatch: (profile: PersistentSpeakerProfile, similarity: Float)?
        
        // Read with concurrent access
        let profiles = queue.sync { persistentProfiles }
        
        for profile in profiles.values {
            guard !profile.embedding.isEmpty else { continue }
            
            let similarity = cosineSimilarity(embedding, profile.embedding)
            if similarity >= threshold {
                if bestMatch == nil || similarity > bestMatch!.similarity {
                    bestMatch = (profile, similarity)
                }
            }
        }
        
        if let match = bestMatch {
            print("Found matching speaker: \(match.profile.name) with similarity: \(match.similarity)")
        }
        
        return bestMatch?.profile
    }
    
    /// Sync persistent speakers with SwiftData context
    func syncWithDatabase(context: ModelContext) {
        // First, load any speakers marked as persistent in the database
        let descriptor = FetchDescriptor<Speaker>(predicate: #Predicate { speaker in
            speaker.isPersistent == true
        })
        
        if let dbSpeakers = try? context.fetch(descriptor) {
            for speaker in dbSpeakers {
                if speaker.embedding != nil {
                    saveSpeaker(speaker)
                }
            }
        }
        
        // Then, ensure all persistent profiles exist in the database
        for profile in persistentProfiles.values {
            let speakerId = profile.id
            let descriptor = FetchDescriptor<Speaker>(predicate: #Predicate { speaker in
                speaker.id == speakerId
            })
            
            if let existingSpeaker = try? context.fetch(descriptor).first {
                // Update existing speaker with persistent data
                profile.updateSpeaker(existingSpeaker)
            } else {
                // Create new speaker from persistent profile
                let newSpeaker = Speaker(
                    id: profile.id,
                    name: profile.name,
                    displayColor: Color(red: profile.colorRed, green: profile.colorGreen, blue: profile.colorBlue),
                    embedding: profile.embedding.isEmpty ? nil : profile.embedding
                )
                profile.updateSpeaker(newSpeaker)
                context.insert(newSpeaker)
            }
        }
        
        // Save context
        try? context.save()
        
        print("Synced \(persistentProfiles.count) persistent speakers with database")
    }
    
    /// Get or create a speaker with embedding matching
    func getOrCreateSpeaker(withId id: String, embedding: [Float]?, in context: ModelContext) -> Speaker? {
        // First check if we have a persistent speaker with matching embedding
        if let embedding = embedding,
           let profile = findSpeakerByEmbedding(embedding) {
            
            // Found a matching persistent speaker profile
            let speakerId = profile.id
            let descriptor = FetchDescriptor<Speaker>(predicate: #Predicate { speaker in
                speaker.id == speakerId
            })
            
            if let existingSpeaker = try? context.fetch(descriptor).first {
                // Only return if the speaker is still persistent and has an embedding
                if existingSpeaker.isPersistent == true && existingSpeaker.embedding != nil {
                    existingSpeaker.lastSeenAt = Date()
                    existingSpeaker.totalSegments += 1
                    return existingSpeaker
                } else {
                    // Speaker exists but is no longer persistent, don't reuse
                    return nil
                }
            } else {
                // Create speaker from profile only if it should be persistent
                let speaker = Speaker(
                    id: profile.id,
                    name: profile.name,
                    displayColor: Color(red: profile.colorRed, green: profile.colorGreen, blue: profile.colorBlue),
                    embedding: profile.embedding
                )
                speaker.isPersistent = true  // Mark as persistent since it's from a profile
                profile.updateSpeaker(speaker)
                context.insert(speaker)
                return speaker
            }
        }
        
        return nil
    }
    
    // MARK: - Private Methods
    
    private func loadProfiles() {
        guard FileManager.default.fileExists(atPath: speakersFile.path) else {
            print("No persistent speaker profiles found")
            return
        }
        
        do {
            let data = try Data(contentsOf: speakersFile)
            let profiles = try JSONDecoder().decode([PersistentSpeakerProfile].self, from: data)
            
            queue.async(flags: .barrier) { [weak self] in
                self?.persistentProfiles = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
            }
            
            print("Loaded \(profiles.count) persistent speaker profiles")
        } catch {
            print("Failed to load speaker profiles: \(error)")
        }
    }
    
    private func saveProfiles() {
        let profiles = Array(persistentProfiles.values)
        
        do {
            let data = try JSONEncoder().encode(profiles)
            try data.write(to: speakersFile)
            
            print("Saved \(profiles.count) speaker profiles to disk")
        } catch {
            print("Failed to save speaker profiles: \(error)")
        }
    }
    
    private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
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
