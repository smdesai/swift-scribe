import SwiftUI

struct ImportingOverlay: View {
    let fileName: String
    let progress: Double
    let startTime: Date?
    
    private var elapsedTime: String {
        guard let startTime = startTime else { return "0:00" }
        let elapsed = Date().timeIntervalSince(startTime)
        let minutes = Int(elapsed) / 60
        let seconds = Int(elapsed) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
    
    private func statusText(for progress: Double) -> String {
        switch progress {
        case 0..<0.1:
            return "Loading model..."
        case 0.1..<0.2:
            return "Analyzing audio..."
        case 0.2..<0.6:
            return "Transcribing speech..."
        case 0.6..<0.7:
            return "Finalizing transcription..."
        case 0.7..<0.8:
            return "Initializing speaker identification..."
        case 0.8..<0.9:
            return "Processing speakers..."
        case 0.9..<0.95:
            return "Completing diarization..."
        case 0.95...1.0:
            return "Saving memo..."
        default:
            return "Processing..."
        }
    }
    
    var body: some View {
        ZStack {
            // Background
            Color.black.opacity(0.4)
                .ignoresSafeArea()
            
            // Content
            VStack(spacing: 20) {
                // Icon
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 50))
                    .foregroundColor(.white)
                
                // Title
                Text("Transcribing Audio")
                    .font(.title2)
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
                
                // File name
                Text(fileName)
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.8))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal)
                
                // Progress bar
                ProgressView(value: progress)
                    .progressViewStyle(LinearProgressViewStyle(tint: .white))
                    .frame(width: 200)
                
                // Progress text with timing
                HStack(spacing: 16) {
                    // Progress percentage
                    Text("\(Int(progress * 100))%")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.8))
                        .fontDesign(.monospaced)
                    
                    // Elapsed time
                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                            .font(.caption2)
                        Text(elapsedTime)
                            .font(.caption)
                            .fontDesign(.monospaced)
                    }
                    .foregroundColor(.white.opacity(0.6))
                }
                
                // Status text with dynamic message based on progress
                Text(statusText(for: progress))
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.6))
            }
            .padding(30)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color.black.opacity(0.8))
                    .background(
                        RoundedRectangle(cornerRadius: 20)
                            .stroke(Color.white.opacity(0.2), lineWidth: 1)
                    )
            )
            .shadow(radius: 20)
        }
        .animation(.easeInOut(duration: 0.3), value: progress)
    }
}

#Preview {
    ImportingOverlay(
        fileName: "meeting-recording.m4a",
        progress: 0.35,
        startTime: Date().addingTimeInterval(-15) // Simulating 15 seconds elapsed
    )
}
