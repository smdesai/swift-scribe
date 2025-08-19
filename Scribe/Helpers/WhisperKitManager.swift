import Foundation
import SwiftUI
import WhisperKit
import Combine
import CoreML

// MARK: - WhisperKit Manager

@MainActor
class WhisperKitManager: ObservableObject {
    static let shared = WhisperKitManager()
    
    @Published var isLoading = false
    @Published var loadingProgress: Float = 0.0
    @Published var loadingStatus: String = "Initializing..."
    @Published var isModelLoaded = false
    @Published var currentModel: String = ""
    
    private(set) var whisperKit: WhisperKit?
    private var loadingTask: Task<Void, Never>?
    
    private init() {
        self.currentModel = UserDefaults.standard.string(forKey: "selectedModel") ?? WhisperKit.recommendedModels().default
    }
    
    // MARK: - Public Methods
    
    /// Load the WhisperKit model
    func loadModel(modelName: String? = nil) async {
        // Don't reload if already loading or loaded with same model
        if isLoading {
            return
        }
        
        let targetModel = modelName ?? currentModel
        
        if isModelLoaded, targetModel == currentModel, whisperKit != nil {
            print("WhisperKit model already loaded: \(targetModel)")
            return
        }
        
        await MainActor.run {
            isLoading = true
            loadingProgress = 0.0
            loadingStatus = "Preparing WhisperKit..."
        }
        
        do {
            await MainActor.run {
                loadingStatus = "Initializing speech recognition..."
                loadingProgress = 0.1
            }
            
            // Initialize WhisperKit with configuration
            // Create compute options inline to avoid Sendable issues
            let encoderComputeUnits = MLComputeUnits.cpuAndNeuralEngine
            let decoderComputeUnits = MLComputeUnits.cpuAndNeuralEngine
            
            whisperKit = try await WhisperKit(
                WhisperKitConfig(
                    computeOptions: ModelComputeOptions(
                        audioEncoderCompute: encoderComputeUnits,
                        textDecoderCompute: decoderComputeUnits
                    ),
                    verbose: false,
                    logLevel: .info,
                    prewarm: false,
                    load: false,
                    download: false
                )
            )
            
            guard let whisperKit = whisperKit else {
                throw WhisperKitError.initializationFailed
            }
            
            await MainActor.run {
                loadingStatus = "Downloading model: \(targetModel)"
                loadingProgress = 0.2
            }
            
            // Download the model with progress callback
            let progressCallback: @Sendable (Progress) -> Void = { progress in
                Task { @MainActor in
                    // Model download is 20% to 60% of total progress
                    WhisperKitManager.shared.loadingProgress = 0.2 + Float(progress.fractionCompleted) * 0.4
                    
                    let downloadedMB = Int(Double(progress.completedUnitCount) / 1_000_000)
                    let totalMB = Int(Double(progress.totalUnitCount) / 1_000_000)
                    
                    if totalMB > 0 {
                        WhisperKitManager.shared.loadingStatus = "Downloading model: \(downloadedMB)MB / \(totalMB)MB"
                    }
                }
            }
            
            let modelFolder = try await WhisperKit.download(
                variant: targetModel,
                from: "argmaxinc/whisperkit-coreml",
                progressCallback: progressCallback
            )
            
            whisperKit.modelFolder = modelFolder
            
            await MainActor.run {
                loadingStatus = "Loading model into memory..."
                loadingProgress = 0.6
            }
            
            // Prewarm the models
            try await whisperKit.prewarmModels()
            
            await MainActor.run {
                loadingProgress = 0.8
                loadingStatus = "Finalizing..."
            }
            
            // Load the models
            try await whisperKit.loadModels()
            
            await MainActor.run {
                self.currentModel = targetModel
                self.loadingProgress = 1.0
                self.loadingStatus = "Model loaded successfully"
                self.isModelLoaded = true
                
                // Save the selected model
                UserDefaults.standard.set(targetModel, forKey: "selectedModel")
            }
            
            print("WhisperKit model loaded successfully: \(targetModel)")
            
            // Hide loading UI after a short delay
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
            
            await MainActor.run {
                self.isLoading = false
            }
            
        } catch {
            print("Failed to load WhisperKit model: \(error)")
            
            await MainActor.run {
                self.loadingStatus = "Failed to load model"
                self.isLoading = false
                self.isModelLoaded = false
            }
        }
    }
    
    /// Get the current WhisperKit instance
    func getWhisperKit() -> WhisperKit? {
        return whisperKit
    }
    
    /// Check if model needs loading
    func ensureModelLoaded() async {
        if !isModelLoaded {
            await loadModel(modelName: "openai_whisper-small")
        }
    }
    
    // MARK: - Private Methods
    
    // Helper method for getting compute options (if needed elsewhere)
    private func getDefaultComputeUnits() -> (encoder: MLComputeUnits, decoder: MLComputeUnits) {
        // Read from UserDefaults or use defaults
        return (
            encoder: .cpuAndNeuralEngine,
            decoder: .cpuAndNeuralEngine
        )
    }
}

// MARK: - Custom Errors

enum WhisperKitError: LocalizedError {
    case initializationFailed
    case downloadFailed
    case loadingFailed
    
    var errorDescription: String? {
        switch self {
        case .initializationFailed:
            return "Failed to initialize WhisperKit"
        case .downloadFailed:
            return "Failed to download model"
        case .loadingFailed:
            return "Failed to load model"
        }
    }
}
