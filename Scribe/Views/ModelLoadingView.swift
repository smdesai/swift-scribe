import SwiftUI

struct ModelLoadingView: View {
    @ObservedObject var whisperKitManager = WhisperKitManager.shared
    @State private var animationAmount = 1.0
    
    var body: some View {
        ZStack {
            // Background
            Color.black.opacity(0.4)
                .ignoresSafeArea()
            
            // Loading card
            VStack(spacing: 24) {
                // Icon with animation
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 60))
                    .foregroundStyle(.blue.gradient)
                    .scaleEffect(animationAmount)
                    .animation(
                        Animation.easeInOut(duration: 1.5)
                            .repeatForever(autoreverses: true),
                        value: animationAmount
                    )
                
                VStack(spacing: 12) {
                    Text("Loading Speech Recognition")
                        .font(.title2)
                        .fontWeight(.semibold)
                    
                    Text(whisperKitManager.loadingStatus)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                
                // Progress bar
                VStack(spacing: 8) {
                    ProgressView(value: whisperKitManager.loadingProgress)
                        .progressViewStyle(.linear)
                        .tint(.blue)
                        .scaleEffect(y: 2)
                    
                    Text("\(Int(whisperKitManager.loadingProgress * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .frame(maxWidth: 250)
                
                if whisperKitManager.loadingProgress < 0.3 {
                    Text("First time setup may take a few minutes")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(32)
            .background {
                RoundedRectangle(cornerRadius: 20)
                    .fill(.regularMaterial)
                    .shadow(radius: 20)
            }
            .frame(maxWidth: 350)
            .padding()
        }
        .onAppear {
            animationAmount = 1.2
        }
    }
}

// MARK: - Loading Overlay Modifier

struct ModelLoadingOverlay: ViewModifier {
    @ObservedObject var whisperKitManager = WhisperKitManager.shared
    
    func body(content: Content) -> some View {
        ZStack {
            content
                .disabled(whisperKitManager.isLoading)
            
            if whisperKitManager.isLoading {
                ModelLoadingView()
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .animation(.easeInOut(duration: 0.3), value: whisperKitManager.isLoading)
    }
}

extension View {
    func modelLoadingOverlay() -> some View {
        modifier(ModelLoadingOverlay())
    }
}

#Preview {
    VStack {
        Text("Main Content")
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .modelLoadingOverlay()
}