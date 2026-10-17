import SwiftUI
import UniformTypeIdentifiers

/// App Settings (StemsCraft > Settings…): where the music library lives.
/// Analysis results and separated stems are cached there, so reopening a song is instant.
struct SettingsView: View {
    @EnvironmentObject private var state: AppState
    @State private var showFolderPicker = false

    var body: some View {
        Form {
            Section("Music library") {
                Text("Analysed songs and their stems are kept here.")
                    .font(Fonts.body(12))
                    .foregroundStyle(Theme.textDim)
                HStack {
                    Text(state.library.root.path)
                        .font(Fonts.body(12))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Choose…") { showFolderPicker = true }
                        .buttonStyle(PillButtonStyle(compact: true))
                }
                Text("Switching folders keeps both; nothing is moved or deleted.")
                    .font(Fonts.body(11))
                    .foregroundStyle(Theme.textFaint)
            }
        }
        .padding()
        .frame(width: 480)
        .background(AppBackground())
        .preferredColorScheme(.dark)
        .fileImporter(isPresented: $showFolderPicker, allowedContentTypes: [.folder]) { r in
            if case let .success(url) = r { state.moveLibraryRoot(to: url) }
        }
    }
}

#Preview("settings") {
    SettingsView()
        .environmentObject(AppState())
        .preferredColorScheme(.dark)
}
