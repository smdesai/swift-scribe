import SwiftUI
import SwiftData

struct SpeakerManagementView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    
    @Query(sort: \Speaker.lastSeenAt, order: .reverse) private var speakers: [Speaker]
    @State private var editingSpeaker: Speaker?
    @State private var showingMergeAlert = false
    @State private var speakerToMerge: Speaker?
    @State private var mergeTarget: Speaker?
    
    var body: some View {
        NavigationStack {
            List {
                ForEach(speakers) { speaker in
                    SpeakerRow(
                        speaker: speaker,
                        onEdit: { editingSpeaker = speaker },
                        onMerge: { initiateMerge(speaker) }
                    )
                }
                .onDelete(perform: deleteSpeakers)
            }
            .onAppear {
                print("DEBUG [SpeakerManagementView]: View appeared with \(speakers.count) speakers")
                // Try fetching speakers directly
                let allSpeakers = (try? modelContext.fetch(FetchDescriptor<Speaker>())) ?? []
                print("DEBUG [SpeakerManagementView]: Direct fetch shows \(allSpeakers.count) speakers")
                for speaker in allSpeakers {
                    print("DEBUG [SpeakerManagementView]: Speaker: \(speaker.id) - \(speaker.name)")
                }
            }
            .navigationTitle("Manage Speakers")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
                
//                #if os(iOS)
//                ToolbarItem(placement: .bottomBar) {
//                    Text("\(speakers.count) speakers")
//                        .font(.caption)
//                        .foregroundStyle(.secondary)
//                }
//                #endif
            }
            .sheet(item: $editingSpeaker) { speaker in
                SpeakerEditView(speaker: speaker)
            }
            .alert("Merge Speakers", isPresented: $showingMergeAlert) {
                if let speakerToMerge = speakerToMerge {
                    ForEach(speakers.filter { $0.id != speakerToMerge.id }) { target in
                        Button(target.name) {
                            mergeSpeakers(speakerToMerge, into: target)
                        }
                    }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Select which speaker to merge into")
            }
        }
    }
    
    private func initiateMerge(_ speaker: Speaker) {
        speakerToMerge = speaker
        showingMergeAlert = true
    }
    
    private func mergeSpeakers(_ source: Speaker, into target: Speaker) {
        // Update all segments that reference the source speaker
        let sourceId = source.id
        let descriptor = FetchDescriptor<SpeakerSegment>(
            predicate: #Predicate { segment in
                segment.speakerId == sourceId
            }
        )
        
        if let segments = try? modelContext.fetch(descriptor) {
            for segment in segments {
                segment.speakerId = target.id
            }
        }
        
        // Update target speaker statistics
        target.totalSegments += source.totalSegments
        target.averageConfidence = (
            (target.averageConfidence * Float(target.totalSegments - source.totalSegments)) +
            (source.averageConfidence * Float(source.totalSegments))
        ) / Float(target.totalSegments)
        
        // Delete the source speaker
        modelContext.delete(source)
        
        do {
            try modelContext.save()
        } catch {
            print("Failed to merge speakers: \(error)")
        }
    }
    
    private func deleteSpeakers(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(speakers[index])
        }
        
        do {
            try modelContext.save()
        } catch {
            print("Failed to delete speakers: \(error)")
        }
    }
}

// MARK: - Speaker Row

struct SpeakerRow: View {
    let speaker: Speaker
    let onEdit: () -> Void
    let onMerge: () -> Void
    
    var body: some View {
        HStack {
            // Speaker color indicator
            Circle()
                .fill(speaker.displayColor)
                .frame(width: 24, height: 24)
            
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(speaker.name)
                        .font(.headline)
                    
                    if speaker.isPersistent {
                        Image(systemName: "person.crop.circle.badge.checkmark")
                            .font(.caption)
                            .foregroundStyle(.green)
                    } else if speaker.isUserNamed {
                        Image(systemName: "pencil.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                
                HStack(spacing: 12) {
                    Label("\(speaker.totalSegments)", systemImage: "waveform")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    
                    if speaker.averageConfidence > 0 {
                        Label(
                            "\(Int(speaker.averageConfidence * 100))%",
                            systemImage: "checkmark.shield"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    
                    if let lastSeen = speaker.lastSeenAt {
                        Text(lastSeen.formatted(.relative(presentation: .named)))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            
            Spacer()
            
            Menu {
                Button {
                    onEdit()
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                
                Button {
                    onMerge()
                } label: {
                    Label("Merge with Another", systemImage: "arrow.triangle.merge")
                }
                
                Button(role: .destructive) {
                    // Deletion handled by swipe
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Speaker Edit View

struct SpeakerEditView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    
    @Bindable var speaker: Speaker
    @State private var newName: String = ""
    @State private var selectedColor: Color = .blue
    @State private var isPersistent: Bool = false
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Speaker Information") {
                    TextField("Name", text: $newName)
                        .textFieldStyle(.roundedBorder)
                    
                    ColorPicker("Color", selection: $selectedColor)
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Remember for Future Recordings", isOn: $isPersistent)
                        
                        Text("When enabled, this speaker will be automatically recognized in future recordings based on voice characteristics")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                
                Section("Statistics") {
                    LabeledContent("Total Segments", value: "\(speaker.totalSegments)")
                    LabeledContent("Average Confidence", value: "\(Int(speaker.averageConfidence * 100))%")
                    LabeledContent("First Seen", value: speaker.createdAt.formatted(date: .abbreviated, time: .shortened))
                    if let lastSeen = speaker.lastSeenAt {
                        LabeledContent("Last Seen", value: lastSeen.formatted(date: .abbreviated, time: .shortened))
                    }
                }
            }
            .navigationTitle("Edit Speaker")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveSpeaker()
                    }
                    .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .onAppear {
            newName = speaker.name
            selectedColor = speaker.displayColor
            // Default to persistent if speaker has been named by user, otherwise use existing value
            isPersistent = speaker.isUserNamed || speaker.isPersistent
        }
    }
    
    private func saveSpeaker() {
        speaker.name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        speaker.displayColor = selectedColor
        speaker.isUserNamed = true
        speaker.isPersistent = isPersistent
        
        do {
            try modelContext.save()
            
            // Save to persistent storage if marked as persistent
            if isPersistent {
                PersistentSpeakerManager.shared.saveSpeaker(speaker)
            } else {
                // Remove from persistent storage if unmarked
                PersistentSpeakerManager.shared.removeSpeaker(withId: speaker.id)
            }
            
            dismiss()
        } catch {
            print("Failed to save speaker: \(error)")
        }
    }
}

// MARK: - Speaker Badge View (for inline display)

struct SpeakerBadge: View {
    let speaker: Speaker
    let confidence: Float?
    
    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(speaker.displayColor)
                .frame(width: 8, height: 8)
            
            Text(speaker.name)
                .font(.caption)
                .fontWeight(.medium)
            
            if let confidence = confidence {
                Text("•")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                Text("\(Int(confidence * 100))%")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(speaker.displayColor.opacity(0.1))
        .clipShape(Capsule())
    }
}

#Preview {
    SpeakerManagementView()
        .modelContainer(for: [Speaker.self, SpeakerSegment.self])
}
