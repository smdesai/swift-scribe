import SwiftUI
import FluidAudio

@Observable
class AppSettings {
    var colorScheme: ColorScheme?
    
    // Diarization settings
    var diarizationEnabled: Bool = true
    var clusteringThreshold: Float = 0.7
    var minSegmentDuration: TimeInterval = 0.5
    var maxSpeakers: Int? = nil
    var enableRealTimeProcessing: Bool = false
    var combineSameSpeakerSegments: Bool = false
    var mergePartialSentences: Bool = false
    
    // Advanced diarization settings from FluidAudio
    var enableSpeakerMerging: Bool = true
    var speakerMergingThreshold: Float = 0.3
    var chunkDuration: Float = 10.0
    var chunkOverlap: Float = 2.0

    init() {
        // Load saved settings
        if let savedScheme = UserDefaults.standard.object(forKey: "colorScheme") as? Int {
            switch savedScheme {
            case 0:
                self.colorScheme = .light
            case 1:
                self.colorScheme = .dark
            default:
                self.colorScheme = nil
            }
        } else {
            self.colorScheme = nil
        }
        
        // Load diarization settings
        loadDiarizationSettings()
    }

    func setColorScheme(_ scheme: ColorScheme?) {
        self.colorScheme = scheme

        // Save to UserDefaults
        if let scheme = scheme {
            UserDefaults.standard.set(scheme == .light ? 0 : 1, forKey: "colorScheme")
        } else {
            UserDefaults.standard.removeObject(forKey: "colorScheme")
        }
    }

    var themeDisplayName: String {
        switch colorScheme {
        case .light:
            return "Light"
        case .dark:
            return "Dark"
        case nil:
            return "System"
        case .some(_):
            return "System"
        }
    }
    
    // MARK: - Diarization Settings
    
    private func loadDiarizationSettings() {
        diarizationEnabled = UserDefaults.standard.object(forKey: "diarizationEnabled") as? Bool ?? true
        clusteringThreshold = UserDefaults.standard.object(forKey: "clusteringThreshold") as? Float ?? 0.7
        minSegmentDuration = UserDefaults.standard.object(forKey: "minSegmentDuration") as? TimeInterval ?? 0.5
        maxSpeakers = UserDefaults.standard.object(forKey: "maxSpeakers") as? Int
        enableRealTimeProcessing = UserDefaults.standard.object(forKey: "enableRealTimeProcessing") as? Bool ?? false
        combineSameSpeakerSegments = UserDefaults.standard.object(forKey: "combineSameSpeakerSegments") as? Bool ?? false
        mergePartialSentences = UserDefaults.standard.object(forKey: "mergePartialSentences") as? Bool ?? false
        
        // Load advanced settings
        enableSpeakerMerging = UserDefaults.standard.object(forKey: "enableSpeakerMerging") as? Bool ?? true
        speakerMergingThreshold = UserDefaults.standard.object(forKey: "speakerMergingThreshold") as? Float ?? 0.3
        chunkDuration = UserDefaults.standard.object(forKey: "chunkDuration") as? Float ?? 10.0
        chunkOverlap = UserDefaults.standard.object(forKey: "chunkOverlap") as? Float ?? 2.0
    }
    
    func setDiarizationEnabled(_ enabled: Bool) {
        self.diarizationEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "diarizationEnabled")
    }
    
    func setClusteringThreshold(_ threshold: Float) {
        self.clusteringThreshold = threshold
        UserDefaults.standard.set(threshold, forKey: "clusteringThreshold")
    }
    
    func setMinSegmentDuration(_ duration: TimeInterval) {
        self.minSegmentDuration = duration
        UserDefaults.standard.set(duration, forKey: "minSegmentDuration")
    }
    
    func setMaxSpeakers(_ speakers: Int?) {
        self.maxSpeakers = speakers
        if let speakers = speakers {
            UserDefaults.standard.set(speakers, forKey: "maxSpeakers")
        } else {
            UserDefaults.standard.removeObject(forKey: "maxSpeakers")
        }
    }
    
    func setEnableRealTimeProcessing(_ enabled: Bool) {
        self.enableRealTimeProcessing = enabled
        UserDefaults.standard.set(enabled, forKey: "enableRealTimeProcessing")
    }
    
    func setCombineSameSpeakerSegments(_ enabled: Bool) {
        self.combineSameSpeakerSegments = enabled
        UserDefaults.standard.set(enabled, forKey: "combineSameSpeakerSegments")
    }
    
    func setMergePartialSentences(_ enabled: Bool) {
        self.mergePartialSentences = enabled
        UserDefaults.standard.set(enabled, forKey: "mergePartialSentences")
    }
    
    func setEnableSpeakerMerging(_ enabled: Bool) {
        self.enableSpeakerMerging = enabled
        UserDefaults.standard.set(enabled, forKey: "enableSpeakerMerging")
    }
    
    func setSpeakerMergingThreshold(_ threshold: Float) {
        self.speakerMergingThreshold = threshold
        UserDefaults.standard.set(threshold, forKey: "speakerMergingThreshold")
    }
    
    func setChunkDuration(_ duration: Float) {
        self.chunkDuration = duration
        UserDefaults.standard.set(duration, forKey: "chunkDuration")
    }
    
    func setChunkOverlap(_ overlap: Float) {
        self.chunkOverlap = overlap
        UserDefaults.standard.set(overlap, forKey: "chunkOverlap")
    }
    
    /// Returns the current diarization configuration for FluidAudio v3
    func diarizationConfig() -> DiarizerConfig {
        // Optimize based on performance preference
        let performanceMode = UserDefaults.standard.string(forKey: "diarizationPerformanceMode") ?? "balanced"
        
        // FluidAudio v3 configuration with new parameter names
        var config = DiarizerConfig(
            clusteringThreshold: clusteringThreshold,
            minSpeechDuration: Float(minSegmentDuration), // v3: renamed from minDurationOn
            minSilenceGap: 0.5, // v3: renamed from minDurationOff
            minActiveFramesCount: 10.0, // v3: renamed from minActivityThreshold
            debugMode: false
        )
        
        // Adjust parameters based on performance mode
        switch performanceMode {
        case "fast":
            // Optimize for speed - less accurate but faster
            config.clusteringThreshold = min(0.4, clusteringThreshold + 0.05) // More lenient clustering
            config.minSpeechDuration = max(1.0, Float(minSegmentDuration)) // Longer minimum segments
        case "accurate":
            // Optimize for accuracy - slower but more precise
            config.clusteringThreshold = max(0.25, clusteringThreshold - 0.05) // Stricter clustering
            config.minSpeechDuration = min(0.5, Float(minSegmentDuration)) // Shorter minimum segments
        default: // "balanced"
            // Use default settings
            break
        }
        
        return config
    }
}
