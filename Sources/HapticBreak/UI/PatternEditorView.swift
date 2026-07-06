import SwiftUI

/// Pattern editor, built around direct manipulation so a first-time user can compose by feel:
/// - **Canvas**: every beat is a bar — tap to select & preview, drag vertically to set strength.
/// - **Tap a rhythm**: literally tap the rhythm you have in mind; the gaps are captured for you.
/// - **Inspector**: one compact row of controls for the selected beat only (timbre / strength / gap).
/// - Dullness and JSON import/export live under an "Advanced" disclosure for power users.
struct PatternEditorView: View {
    @ObservedObject var viewModel: AppViewModel
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
        .frame(minWidth: 620, maxWidth: .infinity, minHeight: 540, maxHeight: .infinity)
        .sheet(isPresented: $showFormatHelp) { formatHelpSheet }
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
    }

    // MARK: - Canvas (tap to select & preview, drag vertically for strength)

    private static let canvasHeight: CGFloat = 132

    private var canvas: some View {
        ScrollView(.horizontal, showsIndicators: false) {
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

    // MARK: - Rhythm recording (tap the rhythm, gaps are captured)

    private var recordPad: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L.t("editor.recordHint"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                recordTap()
            } label: {
                VStack(spacing: 6) {
                    Image(systemName: "hand.tap.fill").font(.system(size: 28))
                    Text(L.t("editor.recordPad")).font(.callout)
                    Text(recordedSteps.isEmpty ? " " : L.t("editor.steps", recordedSteps.count))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 150)
            }
            .buttonStyle(.plain)
            .background(Color.accentColor.opacity(0.10))
            .overlay(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
            .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))

            HStack {
                Button(L.t("btn.cancel")) { recording = false }
                Spacer()
                Button {
                    finishRecording()
                } label: { Label(L.t("editor.recordUse", recordedSteps.count), systemImage: "checkmark") }
                .buttonStyle(.borderedProminent)
                .disabled(recordedSteps.count < 2)
            }
        }
    }

    private func startRecording() {
        recordedSteps = []
        lastTapAt = nil
        recording = true
    }

    private func recordTap() {
        let now = Date()
        if let last = lastTapAt, let lastIndex = recordedSteps.indices.last {
            let gap = Int(now.timeIntervalSince(last) * 1000)
            recordedSteps[lastIndex].gapMsAfter = max(60, min(2000, gap))
        }
        let step = HapticStep(timbre: .crisp, strength: 6, dullness: 0.3, gapMsAfter: 0)
        recordedSteps.append(step)
        lastTapAt = now
        viewModel.testStep(step)
    }

    private func finishRecording() {
        guard recordedSteps.count >= 2 else { recording = false; return }
        draft.steps = recordedSteps
        selectedID = recordedSteps.first?.id
        recording = false
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
