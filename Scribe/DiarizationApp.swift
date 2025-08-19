import SwiftData
import SwiftUI

@main
struct DiarizationApp: App {
    @State private var settings = AppSettings()
    @StateObject private var whisperKitManager = WhisperKitManager.shared

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Memo.self,
            Speaker.self,
            SpeakerSegment.self,
            SpeakerDatabase.self
        ])
        let modelConfiguration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,  // Changed to persist data
            allowsSave: true
        )

        do {
            let container = try ModelContainer(for: schema, configurations: [modelConfiguration])
            
            // Sync persistent speakers on app launch
            Task { @MainActor in
                PersistentSpeakerManager.shared.syncWithDatabase(context: container.mainContext)
            }
            
            return container
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(settings)
                .preferredColorScheme(settings.colorScheme)
                .modelLoadingOverlay()
                .onAppear {
                    // Load WhisperKit model on app launch
                    Task {
                        await whisperKitManager.loadModel(modelName: "openai_whisper-small")
                    }
                    
                    // Ensure persistent speakers are synced when app appears
                    Task { @MainActor in
                        PersistentSpeakerManager.shared.syncWithDatabase(
                            context: sharedModelContainer.mainContext
                        )
                    }
                }
        }
        .modelContainer(sharedModelContainer)

        #if os(macOS)
            Settings {
                SettingsView(settings: settings)
            }
        #endif
    }
}
