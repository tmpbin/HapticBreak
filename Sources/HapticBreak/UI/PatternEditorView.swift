import SwiftUI

/// Pattern editor · single-beat sequencer.
/// A pattern = a string of "beats", each with its own timbre / strength (1–10) / dullness / gap; the top
/// timeline visualizes the whole rhythm.
/// Supports import / export (friendly JSON, convenient for external text editing or AI authoring).
struct PatternEditorView: View {
    @ObservedObject var viewModel: AppViewModel
    @ObservedObject var settings = Settings.shared
    @ObservedObject private var l10n = L10n.shared

    @State private var draft = PatternEditorView.newDraft()
    @State private var fireOnDrag = true
    @State private var suppressFire = false
    @State private var showFormatHelp = false
    @State private var ioNotice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ioBar
                    existingList
                    Divider()
                    editor
                }
                .padding(16)
            }
        }
        .frame(minWidth: 580, maxWidth: .infinity, minHeight: 500, maxHeight: .infinity)
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
                draft = PatternEditorView.newDraft()
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

    // MARK: - Import / export toolbar

    private var ioBar: some View {
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
            if let ioNotice {
                Text(ioNotice).font(.caption).foregroundStyle(.secondary).transition(.opacity)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
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
                        Button { draft = pattern } label: { Image(systemName: "pencil") }
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
                unifyMenu
            }

            HStack {
                Text(L.t("editor.name"))
                TextField(L.t("editor.namePlaceholder"), text: $draft.name)
                    .textFieldStyle(.roundedBorder)
            }

            timeline

            ForEach(Array(draft.steps.enumerated()), id: \.element.id) { index, _ in
                stepRow(index: index)
            }

            Button {
                draft.steps.append(nextStep())
            } label: { Label(L.t("editor.addStep"), systemImage: "plus.circle") }
            .buttonStyle(.borderless)

            Text(L.t("editor.hint"))
                .font(.caption2).foregroundStyle(.secondary)

            HStack {
                Button { viewModel.testPattern(draft) } label: { Label(L.t("editor.testAll"), systemImage: "play.fill") }
                Text(L.t("editor.duration", draft.estimatedDuration)).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    save()
                } label: { Label(L.t("editor.save"), systemImage: "tray.and.arrow.down.fill") }
                .buttonStyle(.borderedProminent)
                .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty || draft.steps.isEmpty)
            }
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

    // MARK: - Timeline visualization (height = strength, color = timbre, horizontal spacing ∝ gap)

    private var timeline: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .bottom, spacing: 0) {
                ForEach(Array(draft.steps.enumerated()), id: \.element.id) { index, step in
                    Button { fire(step) } label: {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(timbreColor(step.timbre).opacity(0.4))
                            .frame(width: 14, height: 10 + CGFloat(step.strength) * 6)
                            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(timbreColor(step.timbre), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .help("\(step.timbre.displayName) · \(step.strength)")
                    if index < draft.steps.count - 1 {
                        Spacer().frame(width: max(6, min(48, CGFloat(step.gapMsAfter) / 12)))
                    }
                }
            }
            .frame(height: 80, alignment: .bottom)
            .padding(.horizontal, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Theme.neutralFill)
        .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
    }

    private func stepRow(index: Int) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                Text(L.t("editor.stepN", index + 1)).font(.caption.weight(.semibold)).frame(width: 52, alignment: .leading)

                Picker("", selection: Binding(
                    get: { draft.steps[index].timbre },
                    set: { draft.steps[index].timbre = $0; fire(draft.steps[index]) })) {
                    ForEach(HapticTimbre.allCases) { t in Text(t.displayName).tag(t) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 200)

                Stepper(L.t("editor.stepDelay", draft.steps[index].gapMsAfter),
                        value: Binding(get: { draft.steps[index].gapMsAfter },
                                       set: { draft.steps[index].gapMsAfter = $0 }),
                        in: 0...2000, step: 10)
                    .fixedSize()
                    .opacity(index == draft.steps.count - 1 ? 0.35 : 1)
                    .disabled(index == draft.steps.count - 1)

                Spacer()

                Button { fire(draft.steps[index]) } label: { Image(systemName: "hand.tap") }
                    .buttonStyle(.borderless).help(L.t("editor.testStep")).accessibilityLabel(L.t("editor.testStepN", index + 1))
                rowMenu(index: index)
                Button { draft.steps.remove(at: index) } label: {
                    Image(systemName: "minus.circle").foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
                .disabled(draft.steps.count <= 1)
                .help(L.t("editor.deleteStep")).accessibilityLabel(L.t("editor.deleteStepN", index + 1))
            }

            HStack(spacing: 10) {
                Text(L.t("editor.strength")).font(.caption2).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
                Slider(value: Binding(
                    get: { Double(draft.steps[index].strength) },
                    set: { draft.steps[index].strength = Int($0.rounded()) }),
                    in: 1...10, step: 1)
                    .onChange(of: draft.steps[index].strength) { _ in fire(draft.steps[index]) }
                Text("\(draft.steps[index].strength)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary).frame(width: 20)

                Text(L.t("editor.dullness")).font(.caption2).foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
                Slider(value: Binding(
                    get: { draft.steps[index].dullness },
                    set: { draft.steps[index].dullness = $0 }),
                    in: 0...1, step: 0.05)
                    .onChange(of: draft.steps[index].dullness) { _ in fire(draft.steps[index]) }
                Text(String(format: "%.2f", draft.steps[index].dullness)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary).frame(width: 32)
            }
        }
        .padding(8)
        .background(Theme.neutralFill.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
    }

    private func rowMenu(index: Int) -> some View {
        Menu {
            Button { move(index, by: -1) } label: { Label(L.t("editor.moveUp"), systemImage: "arrow.up") }
                .disabled(index == 0)
            Button { move(index, by: 1) } label: { Label(L.t("editor.moveDown"), systemImage: "arrow.down") }
                .disabled(index == draft.steps.count - 1)
            Button { duplicate(index) } label: { Label(L.t("editor.duplicateStep"), systemImage: "plus.square.on.square") }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton).fixedSize()
        .help(L.t("editor.stepMore"))
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

    /// New beat: inherit the previous beat's timbre/dullness, take a mid-level strength, for quickly
    /// extending the rhythm.
    private func nextStep() -> HapticStep {
        let last = draft.steps.last
        return HapticStep(timbre: last?.timbre ?? .crisp, strength: 6,
                          dullness: last?.dullness ?? 0.3, gapMsAfter: 150)
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
    }

    private func loadCopy(of pattern: HapticPattern) {
        draft = HapticPattern(
            id: "custom.\(UUID().uuidString)",
            name: L.t("editor.copySuffix", pattern.displayName),
            symbol: "waveform",
            steps: pattern.steps.map {
                HapticStep(timbre: $0.timbre, strength: $0.strength, dullness: $0.dullness, gapMsAfter: $0.gapMsAfter)
            },
            isBuiltin: false)
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
