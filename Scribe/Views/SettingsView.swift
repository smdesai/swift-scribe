import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case appearance = "Appearance"
    case diarization = "Speaker Diarization"
    case speakers = "Known Speakers"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .appearance:
            return "paintpalette"
        case .diarization:
            return "person.2"
        case .speakers:
            return "person.crop.circle.badge.checkmark"
        }
    }
}

enum ThemeOption: CaseIterable {
    case system
    case light
    case dark

    var displayName: String {
        switch self {
        case .system:
            return "System"
        case .light:
            return "Light"
        case .dark:
            return "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system:
            return nil
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }

    static func from(colorScheme: ColorScheme?) -> ThemeOption {
        switch colorScheme {
        case .light:
            return .light
        case .dark:
            return .dark
        case .none:
            return .system
        case .some(_):
            return .system
        }
    }
}

struct SettingsView: View {
    @Bindable var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTheme: ThemeOption = .system
    @State private var selectedTab: SettingsTab = .appearance
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    private var isPhone: Bool {
        #if os(iOS)
            return UIDevice.current.userInterfaceIdiom == .phone
        #else
            return false
        #endif
    }

    var body: some View {
        #if os(iOS)
            phoneLayout
        #else
            splitViewLayout
        #endif
    }

    #if os(iOS)
        private var phoneLayout: some View {
            NavigationStack {
                List {
                    ForEach(SettingsTab.allCases) { tab in
                        NavigationLink(destination: settingsContent(for: tab)) {
                            Label(tab.rawValue, systemImage: tab.icon)
                        }
                    }
                }
                .navigationTitle("Settings")
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        dismissButton
                    }
                }
            }
        }
    #endif

    private var splitViewLayout: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebarContent
        } detail: {
            detailContent
        }
        .frame(minWidth: 600, minHeight: 400)
        .onAppear {
            selectedTheme = ThemeOption.from(colorScheme: settings.colorScheme)
        }
    }

    private var sidebarContent: some View {
        #if os(macOS)
            List(SettingsTab.allCases, selection: $selectedTab) { tab in
                Label(tab.rawValue, systemImage: tab.icon)
                    .tag(tab)
            }
            .navigationTitle("Settings")
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 250)
            .toolbarBackground(.hidden)
            .padding(.top, 10)
            .toolbar(removing: .sidebarToggle)
        #else
            List(SettingsTab.allCases) { tab in
                Button(action: { selectedTab = tab }) {
                    Label(tab.rawValue, systemImage: tab.icon)
                        .foregroundColor(selectedTab == tab ? .accentColor : .primary)
                }
                .listRowBackground(
                    selectedTab == tab ? Color.accentColor.opacity(0.1) : Color.clear
                )
            }
            .navigationTitle("Settings")
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 250)
            .toolbarBackground(.hidden)
        #endif
    }

    private var detailContent: some View {
        settingsContent(for: selectedTab)
            .navigationTitle(selectedTab.rawValue)
            #if os(macOS)
                .navigationSplitViewStyle(.balanced)
                .navigationSubtitle("")
            #endif
            .toolbar {
                #if os(iOS)
                    ToolbarItem(placement: .navigationBarTrailing) {
                        dismissButton
                    }
                #endif
            }
            .toolbarBackground(.hidden)
    }

    private var dismissButton: some View {
        Button(action: { dismiss() }) {
            Image(systemName: "xmark")
        }
    }

    @ViewBuilder
    private func settingsContent(for tab: SettingsTab) -> some View {
        switch tab {
        case .appearance:
            AppearanceSettingsView(settings: settings, selectedTheme: $selectedTheme)
                .onAppear {
                    selectedTheme = ThemeOption.from(colorScheme: settings.colorScheme)
                }
        case .diarization:
            DiarizationSettingsView(settings: settings)
        case .speakers:
            KnownSpeakersView()
        }
    }
}

struct AppearanceSettingsView: View {
    @Bindable var settings: AppSettings
    @Binding var selectedTheme: ThemeOption

    var body: some View {
        SettingsPageView(
            title: "Appearance",
            subtitle: "Customize the look and feel of the app."
        ) {
            SettingsGroup(title: "Theme") {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("Color Scheme")
                            .fontWeight(.medium)
                        Spacer()
                    }

                    Picker("Theme", selection: $selectedTheme) {
                        ForEach(ThemeOption.allCases, id: \.self) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: selectedTheme) { _, newValue in
                        settings.setColorScheme(newValue.colorScheme)
                    }

                    Text(
                        "Choose how the app appears. System uses your device's appearance setting."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
//                .padding(.horizontal, 12)
            }
        }
    }
}

struct DiarizationSettingsView: View {
    @Bindable var settings: AppSettings
    @State private var performanceMode: String = UserDefaults.standard.string(forKey: "diarizationPerformanceMode") ?? "balanced"
    
    private var performanceModeDescription: String {
        switch performanceMode {
        case "fast":
            return "Optimized for speed. Processing is faster but may be less accurate at distinguishing similar voices."
        case "accurate":
            return "Optimized for accuracy. Better at distinguishing similar voices but processing takes longer."
        default: // "balanced"
            return "Balanced performance and accuracy. Recommended for most use cases."
        }
    }
    
    var body: some View {
        SettingsPageView(
            title: "Speaker Diarization",
            subtitle: "Configure speaker identification and transcription display."
        ) {
            SettingsGroup(title: "Speaker Identification") {
                VStack(alignment: .leading, spacing: 16) {
                    Toggle("Enable Speaker Diarization", isOn: $settings.diarizationEnabled)
                        .onChange(of: settings.diarizationEnabled) { _, newValue in
                            settings.setDiarizationEnabled(newValue)
                        }
                }
            }
            
            if settings.diarizationEnabled {
                SettingsGroup(title: "Display Options") {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle("Combine Same Speaker Segments", isOn: $settings.combineSameSpeakerSegments)
                                .onChange(of: settings.combineSameSpeakerSegments) { _, newValue in
                                    settings.setCombineSameSpeakerSegments(newValue)
                                }
                            
                            Text("When enabled, consecutive segments from the same speaker are combined into a single block.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        
                        Divider()
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle("Merge Partial Sentences", isOn: $settings.mergePartialSentences)
                                .onChange(of: settings.mergePartialSentences) { _, newValue in
                                    settings.setMergePartialSentences(newValue)
                                }
                            
                            Text("Automatically merge sentence fragments across speaker transitions based on which speaker has the larger portion.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            
            if settings.diarizationEnabled {
                SettingsGroup(title: "Performance") {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Performance Mode")
                                .font(.subheadline)
                                .fontWeight(.medium)
                            
                            Picker("Performance Mode", selection: $performanceMode) {
                                Text("Fast").tag("fast")
                                Text("Balanced").tag("balanced")
                                Text("Accurate").tag("accurate")
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .onChange(of: performanceMode) { _, newValue in
                                UserDefaults.standard.set(newValue, forKey: "diarizationPerformanceMode")
                            }
                            
                            Text(performanceModeDescription)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        
                        Divider()
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle("Enable Real-Time Processing", isOn: $settings.enableRealTimeProcessing)
                                .onChange(of: settings.enableRealTimeProcessing) { _, newValue in
                                    settings.setEnableRealTimeProcessing(newValue)
                                }
                            
                            Text("Process speaker identification during recording. May impact performance.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                
                SettingsGroup(title: "Speaker Detection") {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("Clustering Threshold")
                                    .font(.subheadline)
                                Spacer()
                                Text("\(Int(settings.clusteringThreshold * 100))%")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .fontDesign(.monospaced)
                            }
                            
                            Slider(value: $settings.clusteringThreshold, in: 0.5...0.9, step: 0.05)
                                .onChange(of: settings.clusteringThreshold) { _, newValue in
                                    settings.setClusteringThreshold(Float(newValue))
                                }
                            
                            Text("Higher values result in fewer speakers but better accuracy.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        
                        Divider()
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle("Auto-Merge Similar Speakers", isOn: $settings.enableSpeakerMerging)
                                .onChange(of: settings.enableSpeakerMerging) { _, newValue in
                                    settings.setEnableSpeakerMerging(newValue)
                                }
                            
                            Text("Automatically merge speakers with similar voice characteristics.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        
                        if settings.enableSpeakerMerging {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Text("Merge Similarity")
                                        .font(.subheadline)
                                    Spacer()
                                    Text("\(Int((1.0 - settings.speakerMergingThreshold) * 100))%")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .fontDesign(.monospaced)
                                }
                                
                                Slider(value: $settings.speakerMergingThreshold, in: 0.2...0.5, step: 0.05)
                                    .onChange(of: settings.speakerMergingThreshold) { _, newValue in
                                        settings.setSpeakerMergingThreshold(Float(newValue))
                                    }
                                
                                Text("Lower values merge more speakers. Useful for handling voice variations.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                
                SettingsGroup(title: "Processing Options") {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("Chunk Duration")
                                    .font(.subheadline)
                                Spacer()
                                Text("\(Int(settings.chunkDuration)) seconds")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            
                            Slider(value: $settings.chunkDuration, in: 5...30, step: 5)
                                .onChange(of: settings.chunkDuration) { _, newValue in
                                    settings.setChunkDuration(Float(newValue))
                                }
                            
                            Text("Audio chunk duration for processing. Shorter chunks provide faster updates.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        
                        Divider()
                        
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("Chunk Overlap")
                                    .font(.subheadline)
                                Spacer()
                                Text("\(Int(settings.chunkOverlap)) seconds")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            
                            Slider(value: $settings.chunkOverlap, in: 0...5, step: 1)
                                .onChange(of: settings.chunkOverlap) { _, newValue in
                                    settings.setChunkOverlap(Float(newValue))
                                }
                            
                            Text("Overlap between chunks for better speaker continuity.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Reusable Components

struct SettingsPageView<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(title)
                            .font(.title2)
                            .fontWeight(.semibold)
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    content
                }
                .padding(.vertical, 8)
                .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

// Custom GroupBox style with reduced padding
struct CompactGroupBoxStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            configuration.label
                .font(.headline)
                .foregroundStyle(.primary)
            
            configuration.content
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
        }
        .padding(10)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        GroupBox(title) {
            content
        }
        .groupBoxStyle(CompactGroupBoxStyle())
    }
}

struct SettingsInfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .fontWeight(.medium)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .fontDesign(.monospaced)
        }
    }
}

// MARK: - Known Speakers Management

import SwiftData

struct KnownSpeakersView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<Speaker> { speaker in
        speaker.isPersistent == true
    }, sort: \Speaker.name) private var persistentSpeakers: [Speaker]
    
    @State private var showingDeleteAllAlert = false
    @State private var speakerToDelete: Speaker?
    @State private var showingEnrollmentView = false
    
    var body: some View {
        SettingsPageView(
            title: "Known Speakers",
            subtitle: "Manage speakers that are remembered across recordings."
        ) {
            SettingsGroup(title: "Persistent Speakers") {
                VStack(spacing: 16) {
                    // Enroll New Speaker Button
                    Button {
                        showingEnrollmentView = true
                    } label: {
                        HStack {
                            Image(systemName: "person.badge.plus")
                            Text("Enroll New Speaker")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    
                    Divider()
                    
                    if persistentSpeakers.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "person.crop.circle.badge.questionmark")
                                .font(.largeTitle)
                                .foregroundStyle(.secondary)
                            
                            Text("No Known Speakers")
                                .font(.headline)
                                .foregroundStyle(.secondary)
                            
                            Text("Speakers marked as 'Remember for Future Recordings' will appear here")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                    } else {
                        ForEach(persistentSpeakers) { speaker in
                            HStack {
                                Circle()
                                    .fill(speaker.displayColor)
                                    .frame(width: 20, height: 20)
                                
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(speaker.name)
                                        .font(.system(.body, weight: .medium))
                                    
                                    Text("Last seen: \(speaker.lastSeenAt?.formatted(.relative(presentation: .named)) ?? "Never")")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                
                                Spacer()
                                
                                Button {
                                    speakerToDelete = speaker
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.caption)
                                        .foregroundStyle(.red)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.vertical, 4)
                        }
                        
                        Divider()
                        
                        Button(role: .destructive) {
                            showingDeleteAllAlert = true
                        } label: {
                            HStack {
                                Image(systemName: "trash.fill")
                                Text("Clear All Known Speakers")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    
                    Text("Known speakers are automatically recognized in new recordings based on their voice characteristics. Edit any speaker during or after a recording to mark them as persistent.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
            }
        }
        .onAppear {
            // Migrate any existing named speakers to be persistent
            Speaker.migrateNamedSpeakersToPersistent(in: modelContext)
        }
        .alert("Delete All Known Speakers", isPresented: $showingDeleteAllAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Delete All", role: .destructive) {
                deleteAllPersistentSpeakers()
            }
        } message: {
            Text("This will remove all known speakers from the database. They will no longer be automatically recognized in future recordings.")
        }
        .alert(
            "Delete Speaker",
            isPresented: .init(
                get: { speakerToDelete != nil },
                set: { if !$0 { speakerToDelete = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) { 
                speakerToDelete = nil
            }
            Button("Delete", role: .destructive) {
                if let speaker = speakerToDelete {
                    deleteSpeaker(speaker)
                }
            }
        } message: {
            if let speaker = speakerToDelete {
                Text("Delete \(speaker.name)? This speaker will no longer be automatically recognized in future recordings.")
            }
        }
        .sheet(isPresented: $showingEnrollmentView) {
            SpeakerEnrollmentView()
        }
    }
    
    private func deleteAllPersistentSpeakers() {
        // Fetch ALL speakers (not just persistent ones) and clear their persistent data
        let descriptor = FetchDescriptor<Speaker>()
        if let allSpeakers = try? modelContext.fetch(descriptor) {
            for speaker in allSpeakers {
                // Clear persistent flag for ALL speakers
                speaker.isPersistent = false
                // Clear embeddings so they can't be matched
                speaker.embedding = nil
                // Reset names to generic if they were customized
                if !speaker.name.starts(with: "Speaker ") {
                    // Generate a new generic name based on speaker count
                    let index = allSpeakers.firstIndex(of: speaker) ?? 0
                    speaker.name = "Speaker \(index + 1)"
                }
            }
        }
        
        // Clear from persistent storage
        PersistentSpeakerManager.shared.clearAllSpeakers()
        
        do {
            try modelContext.save()
        } catch {
            print("Failed to clear persistent speakers: \(error)")
        }
    }
    
    private func deleteSpeaker(_ speaker: Speaker) {
        speaker.isPersistent = false
        speakerToDelete = nil
        
        // Remove from persistent storage
        PersistentSpeakerManager.shared.removeSpeaker(withId: speaker.id)
        
        do {
            try modelContext.save()
        } catch {
            print("Failed to remove persistent speaker: \(error)")
        }
    }
}

#Preview {
    SettingsView(settings: AppSettings())
}
