import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct ImportPlaylistSheet: View {
    @Environment(LibraryRepository.self) private var library
    @Environment(UIState.self) private var ui: UIState?
    @Environment(\.dismiss) private var dismiss

    @State private var inputText = ""
    @State private var isImporting = false
    @State private var currentTrack = ""
    @State private var progressValue: Double = 0
    @State private var progressText = ""
    @State private var errorMessage: String?
    @State private var showError = false

    var isSpotify: Bool {
        PlaylistImporter.isSpotifyURL(inputText)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 12) {
                            Image(systemName: isSpotify ? "link.circle.fill" : "square.and.arrow.down.fill")
                                .font(.system(size: 28))
                                .foregroundStyle(Theme.accent)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(isSpotify ? "Spotify Playlist" : "Import Playlist")
                                    .font(.headline)
                                Text("Paste a Spotify link or a list of songs")
                                    .font(.caption)
                                    .foregroundStyle(Theme.secondaryLabel)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section("Playlist Link or Tracklist") {
                    ZStack(alignment: .topLeading) {
                        if inputText.isEmpty {
                            Text("https://open.spotify.com/playlist/...\nor:\nArtist - Song Title\nSong Title by Artist")
                                .font(.subheadline)
                                .foregroundStyle(Theme.tertiaryLabel)
                                .padding(.top, 8)
                                .padding(.leading, 4)
                        }

                        TextEditor(text: $inputText)
                            .frame(minHeight: 120)
                            .disabled(isImporting)
                    }

                    HStack {
                        Button {
                            #if canImport(UIKit)
                            if let paste = UIPasteboard.general.string {
                                inputText = paste.trimmingCharacters(in: .whitespacesAndNewlines)
                            }
                            #endif
                        } label: {
                            Label("Paste from Clipboard", systemImage: "doc.on.clipboard")
                                .font(.subheadline)
                        }
                        .disabled(isImporting)

                        Spacer()

                        if !inputText.isEmpty {
                            Button("Clear") {
                                inputText = ""
                            }
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .disabled(isImporting)
                        }
                    }
                }

                if isImporting {
                    Section("Importing") {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                ProgressView()
                                    .padding(.trailing, 4)
                                Text(progressText.isEmpty ? "Preparing..." : progressText)
                                    .font(.subheadline)
                                    .bold()
                            }

                            if !currentTrack.isEmpty {
                                Text(currentTrack)
                                    .font(.caption)
                                    .foregroundStyle(Theme.secondaryLabel)
                                    .lineLimit(1)
                            }

                            ProgressView(value: progressValue, total: 1.0)
                                .tint(Theme.accent)
                        }
                        .padding(.vertical, 6)
                    }
                }

                Section {
                    Button {
                        startImport()
                    } label: {
                        HStack {
                            Spacer()
                            if isImporting {
                                ProgressView()
                                    .tint(.white)
                            } else {
                                Text("Start Import")
                                    .bold()
                            }
                            Spacer()
                        }
                    }
                    .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isImporting)
                    .listRowBackground(
                        inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isImporting
                            ? Color.gray.opacity(0.3)
                            : Theme.accent
                    )
                    .foregroundStyle(.white)
                }
            }
            .navigationTitle("Import Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .disabled(isImporting)
                }
            }
            .alert("Import Failed", isPresented: $showError, actions: {
                Button("OK", role: .cancel) {}
            }, message: {
                Text(errorMessage ?? "An error occurred while importing.")
            })
        }
    }

    private func startImport() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        isImporting = true
        progressValue = 0
        progressText = "Reading playlist..."
        currentTrack = ""

        Task {
            do {
                let result = try await library.importPlaylist(input: text) { current, total, track in
                    Task { @MainActor in
                        self.progressValue = total > 0 ? Double(current) / Double(total) : 0
                        self.progressText = "Matching song \(current) of \(total)"
                        self.currentTrack = track
                    }
                }
                await MainActor.run {
                    isImporting = false
                    Haptics.success()
                    ui?.showToast("Imported “\(result.playlist.name)” (\(result.count) songs)")
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    isImporting = false
                    errorMessage = error.localizedDescription
                    showError = true
                    Haptics.error()
                }
            }
        }
    }
}
