import AppKit
import StemsCore
import SwiftUI
import UniformTypeIdentifiers

/// Layout constants. The window is sized so every element is visible at launch:
/// top bar 52 + 8 + tool strip 32 + 6 + original row 52 + 6 + mix actions 26 + 6
/// + 4 stem rows (4x52 + 3x6) + 16 bottom = ~434.
enum Layout {
    static let minWidth: CGFloat = 860
    static let defaultWidth: CGFloat = 960
    static let height: CGFloat = 435
    static let topBar: CGFloat = 52
}

struct ContentView: View {
    @EnvironmentObject private var state: AppState
    @State private var showAudioPicker = false
    @State private var showExportPicker = false
    @State private var exportIndex: Int? // nil = all
    @State private var editingBPM = false
    @State private var bpmText = ""
    @State private var sidebarVisible = true
    @State private var filterText = ""

    private var visibleRecords: [SongRecord] {
        let q = filterText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return state.records }
        return state.records.filter { $0.title.localizedCaseInsensitiveContains(q) }
    }
    @FocusState private var bpmFocused: Bool

    private static let noSongName = "No song loaded"

    // MARK: - AppKit drop catcher (synchronous URLs; SwiftUI onDrop needs
    // async loading and sometimes ignores the first drop).

    final class LibraryDropView: NSView {
        var onHighlight: ((Bool) -> Void)?
        var onURLs: (([URL]) -> Void)?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            registerForDraggedTypes([.fileURL])
        }

        required init?(coder: NSCoder) { nil }

        private static let exts = ["mp3", "wav", "flac", "m4a", "aac", "aif", "aiff", "caf"]

        private func urls(from sender: NSDraggingInfo) -> [URL] {
            let raw = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
            return raw.filter { Self.exts.contains($0.pathExtension.lowercased()) }
        }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            let ok = !urls(from: sender).isEmpty
            onHighlight?(ok)
            return ok ? .copy : []
        }

        override func draggingExited(_ sender: NSDraggingInfo?) {
            onHighlight?(false)
        }

        override func draggingEnded(_ sender: NSDraggingInfo) {
            onHighlight?(false)
        }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            let urls = urls(from: sender)
            guard !urls.isEmpty else { return false }
            onURLs?(urls)
            return true
        }
    }

    struct LibraryDropBridge: NSViewRepresentable {
        var onHighlight: (Bool) -> Void
        var onURLs: ([URL]) -> Void

        func makeNSView(context: Context) -> LibraryDropView {
            let v = LibraryDropView()
            v.onHighlight = onHighlight
            v.onURLs = onURLs
            return v
        }

        func updateNSView(_ view: LibraryDropView, context: Context) {
            view.onHighlight = onHighlight
            view.onURLs = onURLs
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            HSplitView {
                if sidebarVisible {
                    // Fixed width: a flexible range makes HSplitView snap on launch.
                    sidebar.frame(width: 250)
                } else {
                    // Slim rail: library icon reopens the sidebar.
                    VStack {
                        Button {
                            sidebarVisible = true
                        } label: {
                            Image(systemName: "music.note.list")
                                .font(.system(size: 15))
                                .foregroundStyle(Theme.textDim)
                                .frame(width: 28, height: 28)
                        }
                        .buttonStyle(.plain)
                        .modifier(Hoverable())
                        .help("Show library")
                        Spacer()
                    }
                    .padding(.top, 10)
                    .frame(width: 40)
                }
                stage
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: Layout.minWidth, minHeight: Layout.height)
        .background(AppBackground())
        .background(
            LibraryDropBridge(
                onHighlight: { on in Task { @MainActor in state.dropTargeted = on } },
                onURLs: { urls in Task { @MainActor in state.enqueueImport(urls) } }
            )
            .ignoresSafeArea()
        )
        .overlay { dropOverlay }
        .animation(.easeOut(duration: 0.15), value: state.dropTargeted)
        .fileImporter(isPresented: $showAudioPicker, allowedContentTypes: [.audio],
                      allowsMultipleSelection: true) { r in
            if case let .success(urls) = r { state.enqueueImport(urls) }
        }
        .fileImporter(isPresented: $showExportPicker, allowedContentTypes: [.folder]) { r in
            if case let .success(url) = r {
                if let i = exportIndex {
                    try? state.exportStem(i, to: url)
                } else {
                    try? state.exportAll(to: url)
                }
            }
        }
    }

    // MARK: - Sidebar (library)

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Button {
                    sidebarVisible = false
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.textDim)
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .modifier(Hoverable())
                .help("Hide library")
                TextField("Filter", text: $filterText)
                    .textFieldStyle(.plain)
                    .font(Fonts.body(13))
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 8)
                    .frame(height: 26)
                    // Solid fill (not just an overlay shape): the AppKit field
                    // underneath is white and can show through on first paint.
                    .background(Theme.surfaceHi, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(Theme.line, lineWidth: 1))
                Text("\(visibleRecords.count)")
                    .font(Fonts.body(11))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textFaint)
                Button {
                    showAudioPicker = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .frame(width: 26, height: 26)
                        .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Theme.surfaceHi))
                        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(Theme.line, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .modifier(Hoverable())
                .help("Add songs to the library (they are analysed one by one)")
            }
            Rectangle().fill(Theme.line).frame(height: 1)
            // Explicit dark backing: a bare ScrollView can show one white frame
            // behind lazily materializing rows on first paint.
            ScrollView {
                VStack(spacing: 4) {
                    // Fresh file loading without a record yet (record loads
                    // spin on their own row instead).
                    if let title = state.loadingName, state.loadingID == nil {
                        HStack(spacing: 6) {
                            ProgressView()
                                .scaleEffect(0.6)
                                .frame(width: 16, height: 16)
                            Text(title)
                                .font(Fonts.body(13))
                                .foregroundStyle(Theme.text)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if state.isSeparating {
                                Text("\(Int(state.progress * 100))%")
                                    .font(Fonts.body(11))
                                    .monospacedDigit()
                                    .foregroundStyle(Theme.accent)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                    }
                    ForEach(visibleRecords) { r in
                        libraryRow(r)
                    }
                    ForEach(state.importQueue, id: \.self) { url in
                        let active = state.importingPath == url.path
                        HStack(spacing: 6) {
                            ProgressView()
                                .scaleEffect(0.6)
                                .frame(width: 16, height: 16)
                            Text(url.deletingPathExtension().lastPathComponent)
                                .font(Fonts.body(13))
                                .foregroundStyle(Theme.textFaint)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if active {
                                Text("\(Int(state.importingPct * 100))%")
                                    .font(Fonts.body(11))
                                    .monospacedDigit()
                                    .foregroundStyle(Theme.textFaint)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                    }
                }
            }
            .background(Theme.bg)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func libraryRow(_ r: SongRecord) -> some View {
        // Manual double-click detection (single count:1 gesture only):
        // two taps within 0.35 s load, one tap highlights.
        // The loading record shows a spinner (and % while separating).
        let highlighted = state.highlightedID == r.id
        let loading = state.loadingID == r.id
        return HStack(spacing: 6) {
            if loading {
                ProgressView()
                    .scaleEffect(0.6)
                    .frame(width: 16, height: 16)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(r.title)
                    .font(Fonts.body(13, .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    Text(fmtDuration(r.duration))
                        .foregroundStyle(Theme.textFaint)
                    if let bpm = r.bpm {
                        Text("\(formatBPM(bpm)) BPM")
                            .foregroundStyle(Theme.textFaint)
                    }
                    if loading, state.isSeparating {
                        Text("\(Int(state.progress * 100))%")
                            .foregroundStyle(Theme.accent)
                    }
                }
                .font(Fonts.body(11))
                .monospacedDigit()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(highlighted ? Theme.accent.opacity(0.18) : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .strokeBorder(highlighted ? Theme.accent : Color.clear, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture(count: 1) {
            if state.registerTap(id: r.id) { state.selectRecord(r) }
        }
        .contextMenu {
            Button("Show in Finder") {
                _ = NSWorkspace.shared.open(state.library.songDir(id: r.id))
            }
            Button("Remove from library", role: .destructive) {
                state.deleteRecord(r)
            }
        }
    }

    private func fmtDuration(_ s: Double) -> String {
        String(format: "%d:%02d", Int(s) / 60, Int(s) % 60)
    }

    // MARK: - State helpers

    private var hasSong: Bool { state.songName != Self.noSongName }

    /// Show the player only when separated tracks and their waveforms are actually available.
    /// (While a new song is being separated `trackNames` is cleared, so the progress view shows.)
    private var showResult: Bool {
        state.hasResult && state.trackNames.count > 1 && !state.peaks.isEmpty
    }

    // MARK: - Top bar (brand, transport, actions)

    private var topBar: some View {
        HStack(spacing: 14) {
            (Text("Stems").foregroundColor(Theme.text) + Text("Craft").foregroundColor(Theme.accent))
                .font(Fonts.condensed(22, bold: true))

            if showResult {
                Rectangle().fill(Theme.line).frame(width: 1, height: 22)
                transportControls
            } else {
                Spacer(minLength: 8)
            }
        }
        .padding(.leading, 82) // clears the traffic lights
        .padding(.trailing, 20)
        .frame(height: Layout.topBar)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    /// Play button, time, and the timeline with the song name centered above it.
    private var transportControls: some View {
        let p = state.player
        let frac = p.duration > 0 ? p.position / p.duration : 0
        return HStack(spacing: 10) {
            Button {
                p.toggle()
            } label: {
                Image(systemName: p.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(p.isPlaying ? Theme.bg : Theme.text)
                    .frame(width: 32, height: 32)
                    .background(RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(p.isPlaying ? Theme.text : Theme.surfaceHi))
                    .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(p.isPlaying ? Theme.text : Theme.line, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .modifier(Hoverable())
            .keyboardShortcut(.space)
            .disabled(p.starting)
            .help(p.starting ? "Starting audio…" : p.engineNote)

            HStack(alignment: .lastTextBaseline, spacing: 5) {
                Text(fmt(p.position))
                    .font(Fonts.condensed(20))
                    .monospacedDigit()
                    .foregroundStyle(Theme.text)
                Text("/ \(fmt(p.duration))")
                    .font(Fonts.condensed(13))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textFaint)
            }
            .frame(width: 92, alignment: .leading)

            // Song name sits above the timeline (own row, so it never overlaps the bar).
            VStack(spacing: 3) {
                Text(state.songName)
                    .font(Fonts.body(13, .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .center)
                Scrubber(progress: frac) { p.seek($0 * p.duration) }
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Stage

    @ViewBuilder
    private var stage: some View {
        Group {
            if showResult {
                resultView
            } else if state.isSeparating {
                progressHero
            } else {
                emptyHero
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var resultView: some View {
        VStack(spacing: 6) {
            if let e = state.player.audioError {
                Text(e)
                    .font(Fonts.body(12))
                    .foregroundStyle(Theme.bad)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
            toolStrip
            trackRow(0)
            mixActions
            ForEach(1 ..< state.trackNames.count, id: \.self) { i in
                trackRow(i)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 16)
    }

    /// Between Original and the stems, right aligned. Trailing geometry mirrors
    /// the track rows (26 chip + 92 slider + 26 save) so every control lines up
    /// with the column below it; R sits left of the speaker, master fader in
    /// the slider column.
    private var mixActions: some View {
        let p = state.player
        return HStack(spacing: 10) {
            Spacer(minLength: 0)
            ChipToggle(on: false, tint: Theme.text, action: { p.resetMix() }) {
                Text("R")
            }
            .help("Reset mix: all stems on, original muted, volumes to 100%")
            ChipToggle(on: p.anyStemAudible, tint: Theme.text,
                       action: { p.setAllStems(!p.anyStemAudible) }) {
                Image(systemName: p.anyStemAudible ? "speaker.wave.2.fill" : "speaker.slash.fill")
            }
            .help(p.anyStemAudible ? "Mute all stems" : "Unmute all stems")
            VolumeSlider(
                value: Binding(get: { Double(p.masterVolume) },
                               set: { p.setMasterVolume(Float($0)) }),
                tint: Theme.text)
                .frame(width: 92)
                .help("Master volume for the four stems")
            Button {
                exportIndex = nil; showExportPicker = true
            } label: {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .frame(width: 26, height: 26)
                    .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Theme.surfaceHi))
                    .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(Theme.line, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .modifier(Hoverable())
            .help("Export all stems as WAV")
        }
        .frame(height: 26)
        .padding(.trailing, 8)
    }

    // MARK: - Tool strip: BPM, speed, metronome

    private var toolStrip: some View {
        HStack(spacing: 18) {
            tempoGroup
            Spacer(minLength: 8)
            metronomeGroup
        }
        .frame(height: 32)
    }

    private var stripDivider: some View {
        Rectangle().fill(Theme.line).frame(width: 1, height: 20)
    }

    private func stripLabel(_ text: String) -> some View {
        Text(text)
            .font(Fonts.body(11, .semibold))
            .tracking(1.2)
            .foregroundStyle(Theme.textFaint)
    }

    private func formatBPM(_ v: Double) -> String {
        abs(v - v.rounded()) < 0.05 ? String(format: "%.0f", v) : String(format: "%.1f", v)
    }

    /// 1 BPM per step, 0.1 with Option held (read at every repeat, so it can change mid-hold).
    private var fineStep: Bool { NSEvent.modifierFlags.contains(.option) }

    private func commitBPMEdit() {
        guard editingBPM else { return }
        editingBPM = false
        let t = bpmText.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
        if let v = Double(t) { state.setBPM(v) }
    }

    private func beginBPMEdit() {
        guard let d = state.displayBPM else { return }
        bpmText = formatBPM(d)
        editingBPM = true
        DispatchQueue.main.async {
            bpmFocused = true
            // Select the whole number so typing replaces it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
            }
        }
    }

    /// BPM readout with − / +: starts at the song's own tempo and always shows the music's real tempo.
    /// Hold − / + to run, click the number to type one, click "orig" to go back to the original.
    private var tempoGroup: some View {
        let changed = state.player.rate != 1
        return HStack(spacing: 8) {
            stripLabel("BPM")
            HoldChip(action: { state.nudgeBPM(-1, fine: fineStep) }) {
                Image(systemName: "minus")
            }
            .help("Slower by 1 BPM; hold to keep going (Option: 0.1)")
            Group {
                if editingBPM {
                    TextField("", text: $bpmText)
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.center)
                        .focused($bpmFocused)
                        .onSubmit { commitBPMEdit() }
                        .onExitCommand { editingBPM = false }
                        .onChange(of: bpmFocused) { _, focused in
                            if !focused { commitBPMEdit() }
                        }
                } else {
                    Text(state.displayBPM.map(formatBPM) ?? "—")
                        .contentShape(Rectangle())
                        .onTapGesture { beginBPMEdit() }
                        .help("Click to type a tempo")
                }
            }
            .font(Fonts.condensed(22))
            .monospacedDigit()
            .foregroundStyle(state.bpm == nil ? Theme.textFaint : (changed ? Theme.accent : Theme.text))
            .frame(width: 58)
            HoldChip(action: { state.nudgeBPM(1, fine: fineStep) }) {
                Image(systemName: "plus")
            }
            .help("Faster by 1 BPM; hold to keep going (Option: 0.1)")
            Button { state.resetSpeed() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 10, weight: .semibold))
                    Text("orig \(state.originalBPM.map(formatBPM) ?? "")")
                        .font(Fonts.body(11, .semibold))
                }
                .foregroundStyle(Theme.textDim)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Theme.surfaceHi))
                .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(Theme.line, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .modifier(Hoverable())
            .help("Back to the original tempo")
            .opacity(changed ? 1 : 0)
            .allowsHitTesting(changed)
        }
        .disabled(state.bpm == nil)
    }

    private var metronomeGroup: some View {
        HStack(spacing: 8) {
            Image(systemName: "metronome")
                .font(.system(size: 13))
                .foregroundStyle(Theme.sky)
                .frame(width: 20, height: 26)
                .help("Metronome")
            ChipToggle(on: state.clickOffbeat, tint: Theme.text, action: { state.toggleOffbeat() }) {
                BeatPhaseGlyph(offbeat: state.clickOffbeat)
            }
            .help(state.clickOffbeat ? "Clicks are on the off-beat (halfway between beats)" : "Clicks are on the beat")
            .accessibilityLabel("On-beat or off-beat")
            ChipToggle(on: state.clickFactor == 0.5, tint: Theme.text, action: { state.setClickFactor(0.5) }) {
                Text("½")
            }
            .help("Click every other beat (use when the clicks come twice per beat)")
            ChipToggle(on: state.clickFactor == 2, tint: Theme.text, action: { state.setClickFactor(2) }) {
                Text("2×")
            }
            .help("Click twice per beat (use when the clicks come every other beat)")
            // Speaker + slider mirror the track rows (26 chip + 92 slider, 10 gap)
            // so they line up with the mute/volume columns below. A blank slot
            // at the end stands in for the save column.
            HStack(spacing: 10) {
                ChipToggle(on: state.metronomeOn, tint: Theme.warn, action: { state.toggleMetronome() }) {
                    Image(systemName: state.metronomeOn ? "speaker.wave.2.fill" : "speaker.slash.fill")
                }
                .help("Metronome: one click per beat of the song; follows the tempo")
                .accessibilityLabel("Metronome")
                VolumeSlider(
                    value: Binding(get: { Double(state.player.clickVolume) },
                                   set: { state.player.setClickVolume(Float($0)) }),
                    tint: Theme.text)
                    .frame(width: 92)
                    .opacity(state.metronomeOn ? 1 : 0.4)
                Color.clear.frame(width: 26, height: 26)
            }
        }
        .padding(.trailing, 8)
        .disabled(state.bpm == nil)
    }

    // MARK: - Empty / progress states

    private var emptyHero: some View {
        VStack(spacing: 16) {
            VStack(spacing: 4) {
                Text("Drop songs into the library, or press +")
                    .font(Fonts.body(16, .semibold))
                    .foregroundStyle(Theme.text)
                Text("MP3, WAV, FLAC, AAC, M4A, AIFF")
                    .font(Fonts.body(13))
                    .foregroundStyle(Theme.textDim)
            }
            .frame(width: 520)
            .padding(.vertical, 34)
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Theme.line, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
            statusNote
        }
        .padding(.bottom, 12)
    }

    /// Model / error notes, shown under the empty state.
    /// Loading and progress live on the list rows; the empty stage stays quiet otherwise.
    @ViewBuilder
    private var statusNote: some View {
        if state.modelPath.isEmpty {
            note("exclamationmark.triangle.fill", Theme.warn, "Model not found")
        } else if !hasSong && state.songInfo.hasPrefix("Couldn't") {
            note("exclamationmark.triangle.fill", Theme.bad, state.songInfo)
        } else if state.status.hasPrefix("Failed") {
            note("exclamationmark.triangle.fill", Theme.bad, state.status)
        }
    }

    private func note(_ icon: String, _ tint: Color, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .font(.system(size: 11, weight: .semibold))
            Text(text)
                .font(Fonts.body(12))
                .foregroundStyle(Theme.textDim)
                .lineLimit(2)
        }
        .frame(maxWidth: 460)
    }

    private var progressHero: some View {        VStack(spacing: 18) {
            ZStack {
                Circle().stroke(Theme.line, lineWidth: 8)
                Circle()
                    .trim(from: 0, to: max(0.02, min(1, state.progress)))
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.4), value: state.progress)
                VStack(spacing: 2) {
                    Text("\(Int(state.progress * 100))%")
                        .font(Fonts.condensed(40, bold: true))
                        .monospacedDigit()
                        .foregroundStyle(Theme.text)
                    Text("SEPARATING")
                        .font(Fonts.body(10, .semibold))
                        .tracking(1.6)
                        .foregroundStyle(Theme.textFaint)
                }
            }
            .frame(width: 168, height: 168)

            VStack(spacing: 4) {
                Text(state.songName)
                    .font(Fonts.condensed(22, bold: true))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 420)
                Text(state.status)
                    .font(Fonts.body(12))
                    .foregroundStyle(Theme.textDim)
            }
            Button("Cancel") { state.cancel() }
                .buttonStyle(PillButtonStyle())
        }
        .padding(.bottom, 12)
    }

    // MARK: - Pieces

    private func fmt(_ s: Double) -> String {
        String(format: "%d:%02d", Int(s) / 60, Int(s) % 60)
    }

    @ViewBuilder
    private var dropOverlay: some View {
        if state.dropTargeted {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Theme.accent.opacity(0.10))
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [10, 8]))
                VStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 40))
                    Text("Drop to split into stems")
                        .font(Fonts.body(17, .semibold))
                }
                .foregroundStyle(Theme.text)
            }
            .padding(12)
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private func trackRow(_ i: Int) -> some View {
        let p = state.player
        let style = StemStyle.at(i)
        TrackRowView(
            name: i < state.trackNames.count ? state.trackNames[i] : style.name,
            color: style.color,
            peaks: i < state.peaks.count ? state.peaks[i] : [],
            progress: p.duration > 0 ? p.position / p.duration : 0,
            muted: p.mute.count > i && p.mute[i],
            volume: i < p.volume.count ? Double(p.volume[i]) : 1,
            showSave: i > 0,
            onMute: { p.setMute(i, !p.mute[i]) },
            onVolume: { p.setVolume(i, Float($0)) },
            onSeek: { p.seek($0 * p.duration) },
            onSave: { exportIndex = i - 1; showExportPicker = true }
        )
    }
}

#Preview("app empty") {
    ContentView()
        .environmentObject(AppState())
        .preferredColorScheme(.dark)
        .frame(width: Layout.defaultWidth, height: Layout.height)
}
