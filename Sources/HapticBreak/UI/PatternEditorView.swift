import SwiftUI

/// Thread-safe cancellation token for background playback loops.
private final class PlaybackToken {
    private var _cancelled = false
    private let lock = NSLock()
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }
    func cancel() { lock.lock(); _cancelled = true; lock.unlock() }
}

/// Pattern editor, built around direct manipulation so a first-time user can compose by feel:
/// - **Canvas**: every beat is a bar — tap to select & preview, drag vertically to set strength.
/// - **Tap a rhythm**: literally tap the rhythm you have in mind; the gaps are captured for you.
/// - **Inspector**: one compact row of controls for the selected beat only (timbre / strength / gap).
/// - Dullness and JSON import/export live under an "Advanced" disclosure for power users.
struct PatternEditorView: View {
    /// Action entry points only (test playback) — deliberately NOT `@ObservedObject`: the view model
    /// ticks once per second, and this window stays alive after close (WindowManager reuse). Observing
    /// it would re-layout the whole hidden editor every second (docs/PANEL_CPU_INVESTIGATION.md §12).
    let viewModel: AppViewModel
    @ObservedObject var settings = Settings.shared
    @ObservedObject private var l10n = L10n.shared

    @State private var draft = PatternEditorView.newDraft()
    @State private var selectedID: UUID?
    @State private var fireOnDrag = true
    @State private var suppressFire = false
    @State private var showFormatHelp = false
    @State private var showAdvanced = false
    @State private var ioNotice: String?

    // Rhythm recording
    @State private var recording = false
    @State private var recordedSteps: [HapticStep] = []
    @State private var lastTapAt: Date?
    @State private var keyMonitor: Any?
    @State private var recordPaused = false
    @State private var recordStartDate: Date?
    @State private var recordElapsed: TimeInterval = 0
    @State private var elapsedTimer: Timer?
    @State private var pauseStartDate: Date?
    @State private var playbackHighlight: Int?
    @State private var activePlaybackToken: PlaybackToken?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    existingList
                    Divider()
                    editor
                }
                .padding(16)
            }
        }
        .frame(minWidth: 660, maxWidth: .infinity, minHeight: 540, maxHeight: .infinity)
        .sheet(isPresented: $showFormatHelp) { formatHelpSheet }
        // The editor window is cached and reused (WindowManager.present), so @State survives a
        // close/reopen. Tear down the whole recording session here — otherwise the window reopens
        // in a dead "recording" state whose key monitor and clock are gone.
        .onDisappear { stopRecording() }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Label(L.t("editor.title"), systemImage: "slider.horizontal.3").font(.headline)
            Spacer()
            Toggle(isOn: $fireOnDrag) { Text(L.t("editor.fireOnDrag")).font(.caption) }
                .toggleStyle(.switch).controlSize(.mini).fixedSize()
            copyBuiltinMenu
            Button {
                loadDraft(PatternEditorView.newDraft())
            } label: { Label(L.t("editor.new"), systemImage: "plus") }
        }
        .padding(12)
    }

    private var copyBuiltinMenu: some View {
        Menu(L.t("editor.copyBuiltin")) {
            ForEach([HapticPatternCategory.basic, .nature, .rhythm]) { cat in
                let items = HapticPattern.builtins(in: cat)
                if !items.isEmpty {
                    Section(cat.displayName) {
                        ForEach(items) { p in Button(p.displayName) { loadCopy(of: p) } }
                    }
                }
            }
        }
        .menuStyle(.borderlessButton).fixedSize()
    }

    // MARK: - Existing custom patterns list

    private var existingList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L.t("editor.myPatterns")).font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Text(L.t("editor.currentSelected", settings.selectedPattern.displayName))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if settings.customPatterns.isEmpty {
                Text(L.t("editor.empty"))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(settings.customPatterns) { pattern in
                    HStack(spacing: 8) {
                        Image(systemName: "waveform")
                        Text(pattern.displayName)
                        if pattern.id == settings.selectedPatternID {
                            Text(L.t("editor.current"))
                                .font(.caption2)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Color.accentColor.opacity(0.15))
                                .foregroundStyle(Color.accentColor)
                                .clipShape(Capsule())
                        }
                        Text(L.t("editor.steps", pattern.steps.count)).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button { settings.selectedPatternID = pattern.id } label: {
                            Image(systemName: pattern.id == settings.selectedPatternID ? "star.fill" : "star")
                        }
                        .buttonStyle(.borderless).help(L.t("editor.setCurrent")).accessibilityLabel(L.t("editor.setCurrent"))
                        Button { viewModel.testPattern(pattern) } label: { Image(systemName: "play.circle") }
                            .buttonStyle(.borderless).help(L.t("editor.testShort")).accessibilityLabel(L.t("editor.testThis"))
                        Button { loadDraft(pattern) } label: { Image(systemName: "pencil") }
                            .buttonStyle(.borderless).help(L.t("editor.edit")).accessibilityLabel(L.t("editor.editThis"))
                        Button { settings.deleteCustomPattern(id: pattern.id) } label: {
                            Image(systemName: "trash").foregroundStyle(.red)
                        }
                        .buttonStyle(.borderless).help(L.t("editor.delete")).accessibilityLabel(L.t("editor.deleteThis"))
                    }
                    .padding(8)
                    .background(Theme.neutralFill)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
                }
            }
        }
    }

    // MARK: - Editor

    private var editor: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L.t("editor.edit")).font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                if !recording {
                    Button {
                        startRecording()
                    } label: { Label(L.t("editor.record"), systemImage: "hand.tap") }
                }
            }

            HStack {
                Text(L.t("editor.name"))
                TextField(L.t("editor.namePlaceholder"), text: $draft.name)
                    .textFieldStyle(.roundedBorder)
                Text(L.t("editor.duration", draft.estimatedDuration))
                    .font(.caption).foregroundStyle(.secondary).fixedSize()
            }

            if recording {
                recordPad
            } else {
                canvas
                Text(L.t("editor.canvasHint"))
                    .font(.caption2).foregroundStyle(.secondary)
                if let index = selectedIndex {
                    inspector(index: index)
                }
                advancedSection
                HStack {
                    Button { viewModel.testPattern(draft) } label: { Label(L.t("editor.testAll"), systemImage: "play.fill") }
                    Spacer()
                    Button {
                        save()
                    } label: { Label(L.t("editor.save"), systemImage: "tray.and.arrow.down.fill") }
                    .buttonStyle(.borderedProminent)
                    .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty || draft.steps.isEmpty)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { resignTextFocus() }
    }

    // MARK: - Canvas (tap to select & preview, drag vertically for strength)

    private static let canvasHeight: CGFloat = 132

    private var canvas: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            HStack(alignment: .bottom, spacing: 0) {
                ForEach(Array(draft.steps.enumerated()), id: \.element.id) { index, step in
                    BeatBar(step: step,
                            selected: step.id == selectedID,
                            color: timbreColor(step.timbre),
                            canvasHeight: Self.canvasHeight,
                            onSelect: {
                                selectedID = step.id
                                fire(step)
                            },
                            onStrength: { newValue in
                                guard draft.steps.indices.contains(index),
                                      draft.steps[index].strength != newValue else { return }
                                draft.steps[index].strength = newValue
                                selectedID = step.id
                                fire(draft.steps[index])
                            })
                    if index < draft.steps.count - 1 {
                        Spacer().frame(width: gapWidth(draft.steps[index].gapMsAfter))
                    }
                }

                Button {
                    let step = nextStep()
                    draft.steps.append(step)
                    selectedID = step.id
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.leading, 14)
                .padding(.bottom, Self.canvasHeight / 2 - 10)
                .help(L.t("editor.addStep"))
                .accessibilityLabel(L.t("editor.addStep"))
            }
            .frame(height: Self.canvasHeight, alignment: .bottom)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.neutralFill)
        .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
    }

    private func gapWidth(_ gapMs: Int) -> CGFloat {
        max(8, min(56, CGFloat(gapMs) / 12))
    }

    // MARK: - Inspector (selected beat only)

    private var selectedIndex: Int? {
        guard let selectedID else { return draft.steps.isEmpty ? nil : draft.steps.count - 1 }
        return draft.steps.firstIndex { $0.id == selectedID }
    }

    private func inspector(index: Int) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Text(L.t("editor.stepN", index + 1))
                    .font(.caption.weight(.semibold)).frame(width: 56, alignment: .leading)

                Picker("", selection: Binding(
                    get: { draft.steps[index].timbre },
                    set: { draft.steps[index].timbre = $0; fire(draft.steps[index]) })) {
                    ForEach(HapticTimbre.allCases) { t in Text(t.displayName).tag(t) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 210)
                .id("editor.timbre.\(l10n.language.rawValue)")

                Spacer()

                Button { move(index, by: -1) } label: { Image(systemName: "arrow.left") }
                    .buttonStyle(.borderless).disabled(index == 0)
                    .help(L.t("editor.moveLeft")).accessibilityLabel(L.t("editor.moveLeft"))
                Button { move(index, by: 1) } label: { Image(systemName: "arrow.right") }
                    .buttonStyle(.borderless).disabled(index == draft.steps.count - 1)
                    .help(L.t("editor.moveRight")).accessibilityLabel(L.t("editor.moveRight"))
                Button { duplicate(index) } label: { Image(systemName: "plus.square.on.square") }
                    .buttonStyle(.borderless)
                    .help(L.t("editor.duplicateStep")).accessibilityLabel(L.t("editor.duplicateStep"))
                Button {
                    let removed = draft.steps.remove(at: index)
                    if removed.id == selectedID { selectedID = draft.steps.last?.id }
                } label: {
                    Image(systemName: "trash").foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
                .disabled(draft.steps.count <= 1)
                .help(L.t("editor.deleteStep")).accessibilityLabel(L.t("editor.deleteStep"))
            }

            HStack(spacing: 10) {
                Text(L.t("editor.strength")).font(.caption2).foregroundStyle(.secondary)
                    .frame(width: 56, alignment: .leading)
                Slider(value: Binding(
                    get: { Double(draft.steps[index].strength) },
                    set: { draft.steps[index].strength = Int($0.rounded()) }),
                    in: 1...10, step: 1)
                    .onChange(of: draft.steps[index].strength) { _ in fire(draft.steps[index]) }
                Text("\(draft.steps[index].strength)")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary).frame(width: 20)

                Text(L.t("editor.gapToNext")).font(.caption2).foregroundStyle(.secondary)
                    .frame(width: 76, alignment: .trailing)
                Slider(value: Binding(
                    get: { Double(draft.steps[index].gapMsAfter) },
                    set: { draft.steps[index].gapMsAfter = Int(($0 / 10).rounded()) * 10 }),
                    in: 0...1500)
                    .disabled(index == draft.steps.count - 1)
                    .opacity(index == draft.steps.count - 1 ? 0.35 : 1)
                Text("\(draft.steps[index].gapMsAfter)ms")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary).frame(width: 48)
            }
        }
        .padding(8)
        .background(Theme.neutralFill.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
    }

    // MARK: - Rhythm recording (three drum pads — click or play the keyboard; gaps are captured)

    /// Drum kit: one pad per timbre, with a home-row key each (J/K/L) so a rhythm can be *played*.
    private static let drums: [(timbre: HapticTimbre, key: String)] = [
        (.soft, "J"), (.crisp, "K"), (.buzz, "L"),
    ]

    private var recordPad: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L.t("editor.recordHint"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            recordCanvas

            HStack(spacing: 12) {
                ForEach(Self.drums, id: \.key) { drum in
                    drumPad(drum.timbre, key: drum.key)
                }
            }
            .opacity(recordPaused ? 0.4 : 1)
            .allowsHitTesting(!recordPaused)

            recordTransportBar
        }
        .onDisappear { removeKeyMonitor(); stopElapsedTimer() }
    }

    // MARK: - Record canvas (column bars + timeline)

    private static let recordCanvasHeight: CGFloat = 100

    private var recordCanvas: some View {
        VStack(alignment: .leading, spacing: 0) {
            recordStatusBar
            if recordedSteps.isEmpty {
                recordEmptyPlaceholder
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: true) {
                        recordBarsWithTimeline
                    }
                    .onChange(of: recordedSteps.count) { _ in
                        if let lastID = recordedSteps.last?.id {
                            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(lastID, anchor: .trailing) }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .background(Theme.neutralFill)
        .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
    }

    private var recordStatusBar: some View {
        HStack(spacing: 8) {
            Circle().fill(recording && !recordPaused ? Color.red : Color.gray)
                .frame(width: 7, height: 7)
                .overlay(Circle().stroke(Color.red.opacity(recording && !recordPaused ? 0.4 : 0), lineWidth: 2)
                    .scaleEffect(recording && !recordPaused ? 1.6 : 1)
                    .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: recording && !recordPaused))
            Text(recordPaused ? L.t("editor.rec.paused") : L.t("editor.rec.recording"))
                .font(.caption2.weight(.medium))
                .foregroundStyle(recording && !recordPaused ? .red : .secondary)
            Spacer()
            Text(Self.formatElapsed(recordElapsed))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Text(L.t("editor.steps", recordedSteps.count))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    private var recordEmptyPlaceholder: some View {
        Text(L.t("editor.rec.empty"))
            .font(.caption).foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, minHeight: Self.recordCanvasHeight)
    }

    private var recordBarsWithTimeline: some View {
        VStack(spacing: 0) {
            HStack(alignment: .bottom, spacing: 0) {
                ForEach(Array(recordedSteps.enumerated()), id: \.element.id) { index, step in
                    recordBar(step: step, index: index)
                    if index < recordedSteps.count - 1 {
                        recordGapIndicator(gapMs: step.gapMsAfter)
                    }
                }
            }
            .frame(height: Self.recordCanvasHeight, alignment: .bottom)
            .padding(.horizontal, 10)
            .padding(.top, 6)

            recordTimeline
        }
    }

    private func recordBar(step: HapticStep, index: Int) -> some View {
        let color = timbreColor(step.timbre)
        let barHeight: CGFloat = 12 + CGFloat(step.strength) * (Self.recordCanvasHeight - 18) / 10.0
        let highlighted = playbackHighlight == index
        return VStack(spacing: 2) {
            Spacer(minLength: 0)
            Text("\(step.strength)")
                .font(.system(size: 8, weight: .semibold).monospacedDigit())
                .foregroundStyle(color.opacity(0.8))
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(color.opacity(highlighted ? 0.85 : 0.45))
                .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(color, lineWidth: highlighted ? 2 : 0.8))
                .frame(height: barHeight)
        }
        .frame(width: 20)
        .id(step.id)
    }

    private func recordGapIndicator(gapMs: Int) -> some View {
        let width = max(16, min(48, CGFloat(gapMs) / 14))
        return VStack(spacing: 0) {
            Spacer(minLength: 0)
            Text("\(gapMs)")
                .font(.system(size: 7).monospacedDigit())
                .foregroundStyle(.secondary.opacity(0.6))
                .lineLimit(1)
                .frame(width: width)
                .padding(.bottom, 2)
        }
    }

    private var recordTimeline: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.secondary.opacity(0.15)).frame(height: 1)
                if !recordedSteps.isEmpty {
                    let total = recordedSteps.dropLast().reduce(0) { $0 + $1.gapMsAfter }
                    if total > 0 {
                        let marks = stride(from: 500, through: total, by: 500)
                        ForEach(Array(marks.enumerated()), id: \.offset) { _, ms in
                            let x = CGFloat(ms) / CGFloat(total) * (w - 20) + 10
                            VStack(spacing: 1) {
                                Rectangle().fill(Color.secondary.opacity(0.3)).frame(width: 1, height: ms % 1000 == 0 ? 6 : 3)
                                if ms % 1000 == 0 {
                                    Text(String(format: "%.0fs", Double(ms) / 1000))
                                        .font(.system(size: 7).monospacedDigit())
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .position(x: x, y: 8)
                        }
                    }
                }
            }
        }
        .frame(height: 20)
        .padding(.horizontal, 4)
    }

    private static func formatElapsed(_ t: TimeInterval) -> String {
        let s = Int(t)
        let ms = Int((t - Double(s)) * 10)
        return String(format: "%d:%02d.%d", s / 60, s % 60, ms)
    }

    // MARK: - Transport bar (clear / pause / play / cancel / use)

    private var recordTransportBar: some View {
        HStack(spacing: 8) {
            Button {
                clearRecording()
            } label: {
                Label(L.t("editor.rec.clear"), systemImage: "trash")
            }
            .buttonStyle(.bordered).controlSize(.small)
            .disabled(recordedSteps.isEmpty)

            Button {
                toggleRecordPause()
            } label: {
                Label(recordPaused ? L.t("editor.rec.resume") : L.t("editor.rec.pause"),
                      systemImage: recordPaused ? "record.circle" : "pause.fill")
            }
            .buttonStyle(.bordered).controlSize(.small)
            .disabled(activePlaybackToken != nil)

            Button {
                playbackRecorded()
            } label: {
                Label(L.t("editor.rec.play"), systemImage: "play.fill")
            }
            .buttonStyle(.bordered).controlSize(.small)
            .disabled(recordedSteps.count < 2 || activePlaybackToken != nil)

            Button {
                clearRecording()
            } label: {
                Label(L.t("editor.rec.rerecord"), systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(.bordered).controlSize(.small)
            .disabled(recordedSteps.isEmpty)

            Spacer()

            Button(L.t("btn.cancel")) { stopRecording() }
                .controlSize(.small)

            Button {
                finishRecording()
            } label: { Label(L.t("editor.recordUse", recordedSteps.count), systemImage: "checkmark") }
            .buttonStyle(.borderedProminent).controlSize(.small)
            .disabled(recordedSteps.count < 2)
        }
    }

    // MARK: - Drum pad

    private func drumPad(_ timbre: HapticTimbre, key: String) -> some View {
        let color = timbreColor(timbre)
        return Button {
            recordTap(timbre)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: timbre.symbol).font(.system(size: 20))
                Text(timbre.displayName).font(.callout)
                Text(key)
                    .font(.caption.weight(.semibold).monospaced())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Theme.neutralFill)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(Color.secondary.opacity(0.4), lineWidth: 1))
            }
            .frame(maxWidth: .infinity, minHeight: 56)
        }
        .buttonStyle(.plain)
        .foregroundStyle(color)
        .background(color.opacity(0.10))
        .overlay(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
            .strokeBorder(color.opacity(0.55), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
        .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
    }

    private func startRecording() {
        recordedSteps = []
        lastTapAt = nil
        recordPaused = false
        pauseStartDate = nil
        recordElapsed = 0
        recordStartDate = Date()
        recording = true
        resignTextFocus()
        installKeyMonitor()
        startElapsedTimer()
    }

    private func stopRecording() {
        recording = false
        stopPlayback()
        recordPaused = false
        pauseStartDate = nil
        stopElapsedTimer()
        removeKeyMonitor()
    }

    private func resignTextFocus() {
        DispatchQueue.main.async {
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
    }

    private func startElapsedTimer() {
        stopElapsedTimer()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            guard recording, !recordPaused, let start = recordStartDate else { return }
            recordElapsed = Date().timeIntervalSince(start)
        }
    }

    private func stopElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
    }

    private func toggleRecordPause() {
        setRecordPaused(!recordPaused)
    }

    /// Single entry point for pausing/resuming the recording clock. Every pause — manual or the
    /// implicit one during audition playback — books its span here, so on resume the wall-clock
    /// anchors (recordStartDate, lastTapAt) shift forward and paused time never leaks into the
    /// elapsed readout or the next tap's gap.
    private func setRecordPaused(_ paused: Bool) {
        guard paused != recordPaused else { return }
        recordPaused = paused
        if paused {
            pauseStartDate = Date()
        } else if let pauseStart = pauseStartDate {
            let pauseDuration = Date().timeIntervalSince(pauseStart)
            if let start = recordStartDate {
                recordStartDate = start.addingTimeInterval(pauseDuration)
            }
            if let tap = lastTapAt {
                lastTapAt = tap.addingTimeInterval(pauseDuration)
            }
            pauseStartDate = nil
        }
    }

    private func clearRecording() {
        stopPlayback()
        recordedSteps = []
        lastTapAt = nil
        recordElapsed = 0
        recordStartDate = Date()
        resignTextFocus()
    }

    private func playbackRecorded() {
        guard recordedSteps.count >= 2 else { return }
        stopPlayback()
        let token = PlaybackToken()
        activePlaybackToken = token
        let steps = recordedSteps
        let vm = viewModel
        setRecordPaused(true)

        DispatchQueue.global(qos: .userInteractive).async {
            for (i, step) in steps.enumerated() {
                if token.isCancelled { return }
                DispatchQueue.main.async { self.playbackHighlight = i }
                vm.testStep(step)
                if i < steps.count - 1 {
                    usleep(useconds_t(step.gapMsAfter * 1000))
                }
            }
            DispatchQueue.main.async {
                guard !token.isCancelled else { return }
                self.playbackHighlight = nil
                self.setRecordPaused(false)
                self.activePlaybackToken = nil
            }
        }
    }

    private func stopPlayback() {
        activePlaybackToken?.cancel()
        activePlaybackToken = nil
        playbackHighlight = nil
        setRecordPaused(false)
    }

    /// While recording, J/K/L play the drums. The first-responder guard prevents
    /// accidental triggers when a text field is focused, but we also explicitly resign
    /// focus on record-start so the title field doesn't eat keys.
    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard recording, !recordPaused,
                  !(NSApp.keyWindow?.firstResponder is NSTextView),
                  let chars = event.charactersIgnoringModifiers?.uppercased(),
                  let drum = Self.drums.first(where: { $0.key == chars })
            else { return event }
            recordTap(drum.timbre)
            return nil
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private func recordTap(_ timbre: HapticTimbre) {
        let now = Date()
        if let last = lastTapAt, let lastIndex = recordedSteps.indices.last {
            let gap = Int(now.timeIntervalSince(last) * 1000)
            recordedSteps[lastIndex].gapMsAfter = max(60, min(2000, gap))
        }
        let dullness: Double = timbre == .buzz ? 0.6 : 0.3
        let step = HapticStep(timbre: timbre, strength: timbre == .buzz ? 7 : 6,
                              dullness: dullness, gapMsAfter: 0)
        recordedSteps.append(step)
        lastTapAt = now
        viewModel.testStep(step)
    }

    private func finishRecording() {
        defer { stopRecording() }
        guard recordedSteps.count >= 2 else { return }
        draft.steps = recordedSteps
        selectedID = recordedSteps.first?.id
    }

    // MARK: - Advanced (dullness + unify + JSON)

    private var advancedSection: some View {
        DisclosureGroup(isExpanded: $showAdvanced) {
            VStack(alignment: .leading, spacing: 10) {
                if let index = selectedIndex {
                    HStack(spacing: 10) {
                        Text(L.t("editor.dullness")).font(.caption2).foregroundStyle(.secondary)
                            .frame(width: 56, alignment: .leading)
                        Slider(value: Binding(
                            get: { draft.steps[index].dullness },
                            set: { draft.steps[index].dullness = $0 }),
                            in: 0...1, step: 0.05)
                            .onChange(of: draft.steps[index].dullness) { _ in fire(draft.steps[index]) }
                        Text(String(format: "%.2f", draft.steps[index].dullness))
                            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary).frame(width: 32)
                        unifyMenu
                    }
                }
                HStack(spacing: 10) {
                    Button { importFile() } label: { Label(L.t("editor.import"), systemImage: "square.and.arrow.down") }
                    Button { exportAll() } label: { Label(L.t("editor.export"), systemImage: "square.and.arrow.up") }
                        .disabled(settings.customPatterns.isEmpty)
                    Divider().frame(height: 16)
                    Button { copyDraft() } label: { Label(L.t("editor.copyJSON"), systemImage: "doc.on.clipboard") }
                    Button { pasteImport() } label: { Label(L.t("editor.pasteJSON"), systemImage: "clipboard") }
                    Spacer()
                    Button { showFormatHelp = true } label: { Label(L.t("editor.format"), systemImage: "questionmark.circle") }
                        .buttonStyle(.borderless)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                if let ioNotice {
                    Text(ioNotice).font(.caption).foregroundStyle(.secondary).transition(.opacity)
                }
            }
            .padding(.top, 8)
        } label: {
            Text(L.t("editor.advanced")).font(.caption).foregroundStyle(.secondary)
        }
    }

    /// "Unify whole pattern": one click to set all beats to the same timbre, or apply the first beat's
    /// dullness to all — building common presets in seconds.
    private var unifyMenu: some View {
        Menu {
            Section(L.t("editor.unifyTimbre")) {
                ForEach(HapticTimbre.allCases) { t in
                    Button { unifyTimbre(t) } label: { Label(t.displayName, systemImage: t.symbol) }
                }
            }
            Button { unifyDullness() } label: { Label(L.t("editor.unifyDullness"), systemImage: "equal.circle") }
        } label: {
            Label(L.t("editor.unify"), systemImage: "wand.and.stars").font(.caption)
        }
        .menuStyle(.borderlessButton).fixedSize()
    }

    // MARK: - Format help panel

    private var formatHelpSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L.t("editor.format.title")).font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L.t("editor.format.body"))
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(PatternIO.exampleJSON())
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.neutralFill)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
            HStack {
                Button { PatternIO.copyToClipboard(PatternIO.exampleJSON()); flash(L.t("editor.copied")) } label: {
                    Label(L.t("editor.copyExample"), systemImage: "doc.on.doc")
                }
                Spacer()
                Button(L.t("btn.cancel")) { showFormatHelp = false }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 460, height: 420)
    }

    // MARK: - Logic

    private func fire(_ step: HapticStep) {
        guard fireOnDrag, !suppressFire else { return }
        viewModel.testStep(step)
    }

    private func loadDraft(_ pattern: HapticPattern) {
        draft = pattern
        selectedID = pattern.steps.first?.id
        recording = false
    }

    /// New beat: inherit the previous beat's timbre/dullness, take a mid-level strength, for quickly
    /// extending the rhythm.
    private func nextStep() -> HapticStep {
        if let last = draft.steps.indices.last, draft.steps[last].gapMsAfter == 0 {
            draft.steps[last].gapMsAfter = 150
        }
        let last = draft.steps.last
        return HapticStep(timbre: last?.timbre ?? .crisp, strength: 6,
                          dullness: last?.dullness ?? 0.3, gapMsAfter: 0)
    }

    private func move(_ index: Int, by delta: Int) {
        let j = index + delta
        guard draft.steps.indices.contains(j) else { return }
        draft.steps.swapAt(index, j)
    }

    private func duplicate(_ index: Int) {
        guard draft.steps.indices.contains(index) else { return }
        var copy = draft.steps[index]
        copy.id = UUID()
        draft.steps.insert(copy, at: index + 1)
        selectedID = copy.id
    }

    private func unifyTimbre(_ t: HapticTimbre) {
        batch { for i in draft.steps.indices { draft.steps[i].timbre = t } }
    }

    private func unifyDullness() {
        guard let d = draft.steps.first?.dullness else { return }
        batch { for i in draft.steps.indices { draft.steps[i].dullness = d } }
    }

    /// Suppress the "buzz-on-slide" burst when batch-editing multiple beats.
    private func batch(_ work: () -> Void) {
        suppressFire = true
        work()
        DispatchQueue.main.async { suppressFire = false }
    }

    // MARK: - Import / export

    private func exportAll() { PatternIO.exportToFile(settings.customPatterns) }

    private func importFile() {
        guard let ps = PatternIO.importFromFile() else { return }
        ps.forEach { settings.upsertCustomPattern($0) }
        flash(L.t("editor.imported", ps.count))
    }

    private func copyDraft() {
        PatternIO.copyToClipboard(PatternIO.exportText([draft]))
        flash(L.t("editor.copied"))
    }

    private func pasteImport() {
        guard let t = PatternIO.clipboardText(), let ps = PatternIO.parse(t) else {
            flash(L.t("editor.pasteFailed")); return
        }
        ps.forEach { settings.upsertCustomPattern($0) }
        flash(L.t("editor.imported", ps.count))
    }

    private func flash(_ msg: String) {
        withAnimation { ioNotice = msg }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            withAnimation { if ioNotice == msg { ioNotice = nil } }
        }
    }

    private func save() {
        draft.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !draft.name.isEmpty, !draft.steps.isEmpty else { return }
        settings.upsertCustomPattern(draft)
        settings.selectedPatternID = draft.id
        flash(L.t("editor.saved"))
    }

    private func loadCopy(of pattern: HapticPattern) {
        loadDraft(HapticPattern(
            id: "custom.\(UUID().uuidString)",
            name: L.t("editor.copySuffix", pattern.displayName),
            symbol: "waveform",
            steps: pattern.steps.map {
                HapticStep(timbre: $0.timbre, strength: $0.strength, dullness: $0.dullness, gapMsAfter: $0.gapMsAfter)
            },
            isBuiltin: false))
    }

    private func timbreColor(_ t: HapticTimbre) -> Color {
        switch t {
        case .soft:  return .teal
        case .crisp: return .accentColor
        case .buzz:  return .purple
        }
    }

    static func newDraft() -> HapticPattern {
        HapticPattern(
            id: "custom.\(UUID().uuidString)",
            name: L.t("editor.newPatternName"),
            symbol: "waveform",
            steps: [HapticStep(timbre: .crisp, strength: 6, dullness: 0.3, gapMsAfter: 150),
                    HapticStep(timbre: .crisp, strength: 6, dullness: 0.3, gapMsAfter: 0)],
            isBuiltin: false)
    }
}

/// One beat on the canvas: bar height = strength, color = timbre. Tap to select & preview; drag
/// vertically to set strength directly (the gesture owns both, so a still press-and-release is a tap).
private struct BeatBar: View {
    var step: HapticStep
    var selected: Bool
    var color: Color
    var canvasHeight: CGFloat
    var onSelect: () -> Void
    var onStrength: (Int) -> Void

    @State private var dragging = false

    private var barHeight: CGFloat { 16 + CGFloat(step.strength) * 10.5 }

    var body: some View {
        // A full-height transparent hit area so drags anywhere in the column adjust this beat.
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(color.opacity(selected ? 0.75 : 0.38))
                .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(color, lineWidth: selected ? 1.8 : 1))
                .frame(height: barHeight)
        }
        .frame(width: 24, height: canvasHeight)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if !dragging && abs(value.translation.height) < 5 { return }
                    dragging = true
                    let fraction = 1 - min(max(value.location.y / canvasHeight, 0), 1)
                    onStrength(1 + Int((fraction * 9).rounded()))
                }
                .onEnded { _ in
                    if !dragging { onSelect() }
                    dragging = false
                }
        )
        .help("\(step.timbre.displayName) · \(step.strength)")
    }
}
