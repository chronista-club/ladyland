import CreoUI
import StoryKit
import SwiftUI
import UniformTypeIdentifiers

struct StoryPatternView: View {
    @Environment(\.creoTheme) private var theme
    @EnvironmentObject private var appState: AppState
    @ObservedObject var controller: PatternStoryController

    @State private var selectedStep: String?
    @State private var selectedOverride: String?
    @State private var startBar = 1.0
    @State private var overrideBars = 1.0
    @State private var overrideMode = OverrideMode.replace
    @State private var audioImportID: String?
    @State private var midiNote = 60
    @State private var importsAudio = false
    @State private var importing = false

    private var selectedPattern: StoryKit.Pattern? {
        controller.selectedPatternID.flatMap(controller.document.pattern)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: CreoUITokens.spacingS) {
            transport
            if let message = controller.message {
                Label(message, systemImage: "exclamationmark.circle")
                    .foregroundStyle(theme.textSecondary)
                    .textSelection(.enabled)
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: CreoUITokens.spacingM) {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: CreoUITokens.spacingM) {
                            pool.frame(width: 210)
                            Divider()
                            editor.frame(minWidth: 325, maxWidth: .infinity, alignment: .leading)
                        }
                        VStack(alignment: .leading, spacing: CreoUITokens.spacingM) {
                            pool
                            Divider()
                            editor
                        }
                    }
                    Divider()
                    arrangement
                }
                .padding(.trailing, CreoUITokens.spacingS)
            }
        }
        .padding(CreoUITokens.spacingS)
        .font(LadylandFont.caption)
        .onDisappear {
            controller.sculptsWithKnobs = false
            controller.flushEdits()
        }
        .fileImporter(isPresented: $importsAudio, allowedContentTypes: [.audio], onCompletion: importAudio)
    }

    private var transport: some View {
        VStack(alignment: .leading, spacing: CreoUITokens.spacingXs) {
            HStack {
                Button(controller.isPlaying ? "Stop" : "Play",
                       systemImage: controller.isPlaying ? "stop.fill" : "play.fill") {
                    appState.transport(controller.isPlaying ? .stop : .play)
                }
                .disabled(!controller.isPlaying && controller.timeline.totalBeats == 0)
                Toggle("Loop", isOn: $controller.loop).toggleStyle(.button)
                Button(controller.isRecording ? "Finish Rec" : "Rec", systemImage: "record.circle") {
                    appState.transport(.record)
                }
                .tint(controller.isRecording ? .red : theme.brandPrimary)
                Spacer(minLength: 0)
                Text("\(position(controller.currentBeat)) / \(bars(controller.timeline.totalBeats)) bars")
                    .monospacedDigit()
                Button("Reload JSON", systemImage: "arrow.clockwise") { controller.reload() }
                    .help(StoryStore.defaultURL.path)
            }
            HStack {
                Picker("Record", selection: $controller.recording) {
                    ForEach(PatternStoryController.Recording.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .fixedSize()
                if controller.recording == .punchIn {
                    Stepper("\(controller.punchBars) bars", value: $controller.punchBars, in: 1...64)
                        .fixedSize()
                }
            }
            .disabled(controller.isRecording)
        }
    }

    private var pool: some View {
        VStack(alignment: .leading, spacing: CreoUITokens.spacingS) {
            HStack {
                Text("Pattern Pool").font(LadylandFont.bodyBold)
                Spacer()
                Menu("Add Pattern", systemImage: "plus") {
                    Button("Parametric") { add(.parametric(rule: .init(knob: 0, steps: 0), points: [])) }
                    Button("MIDI") { add(.midi(notes: [])) }
                    Button("Raw Audio") { add(.rawAudio(clip: .init())) }
                }
                .labelStyle(.iconOnly)
            }
            ScrollView {
                LazyVStack(spacing: CreoUITokens.spacingXs) {
                    ForEach(controller.document.patterns) { pattern in
                        Button {
                            controller.selectedPatternID = pattern.id
                        } label: {
                            VStack(alignment: .leading, spacing: CreoUITokens.spacingXs) {
                                Text(pattern.name).lineLimit(1).font(LadylandFont.bodyBold)
                                Text("\(pattern.kind.label)  ·  T\(pattern.trackIndex + 1)  ·  \(bars(pattern.lengthBeats)) bars")
                                    .foregroundStyle(theme.textSecondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(CreoUITokens.spacingS)
                            .background(
                                controller.selectedPatternID == pattern.id
                                    ? theme.brandPrimary.opacity(0.18)
                                    : theme.surfaceBgBase,
                                in: RoundedRectangle(cornerRadius: 5))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(minHeight: 96, maxHeight: 264)
        }
    }

    @ViewBuilder
    private var editor: some View {
        if let pattern = selectedPattern {
            VStack(alignment: .leading, spacing: CreoUITokens.spacingS) {
                Text(pattern.name).font(LadylandFont.bodyBold)
                Picker("Track", selection: Binding(get: { pattern.trackIndex }, set: { track in
                    edit(pattern.id) { $0.trackIndex = track }
                })) {
                    ForEach(0..<StoryDocument.trackCount, id: \.self) { Text("T\($0 + 1)").tag($0) }
                }
                .fixedSize()
                switch pattern.kind {
                case let .parametric(rule, points): parameterEditor(pattern, rule: rule, points: points)
                case let .midi(notes): midiEditor(pattern, notes: notes)
                case let .rawAudio(clip): audioEditor(pattern, clip: clip)
                }
            }
        } else {
            Text("Add a pattern to begin.").foregroundStyle(theme.textSecondary)
        }
    }

    private func parameterEditor(_ pattern: StoryKit.Pattern, rule: ParametricRule, points: [ParametricPoint]) -> some View {
        VStack(alignment: .leading, spacing: CreoUITokens.spacingS) {
            let samples = rule.preview(lengthBeats: pattern.lengthBeats, points: points, segments: 160)
            curve(samples, points: points, length: pattern.lengthBeats)
            HStack {
                Picker("Knob", selection: Binding(get: { rule.knob }, set: { knob in
                    let updated = changing(rule, \.knob, to: knob)
                    controller.stageRule(updated, for: pattern.id)
                })) {
                    ForEach(0..<StoryDocument.knobCount, id: \.self) { Text("Knob \($0 + 1)").tag($0) }
                }
                Picker("Waveform", selection: Binding(get: { rule.waveform }, set: { wave in
                    controller.stageRule(changing(rule, \.waveform, to: wave), for: pattern.id)
                })) {
                    ForEach(ParametricWaveform.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }
            Grid(alignment: .leading, horizontalSpacing: CreoUITokens.spacingS, verticalSpacing: CreoUITokens.spacingXs) {
                ruleRow("Cycles", rule.cyclesPerPattern, in: 0.25...max(8, rule.cyclesPerPattern)) {
                    controller.stageRule(changing(rule, \.cyclesPerPattern, to: $0), for: pattern.id)
                }
                ruleRow("Min", Double(rule.minValue), in: 0...1) {
                    controller.stageRule(changing(rule, \.minValue, to: min(Float($0), rule.maxValue)), for: pattern.id)
                }
                ruleRow("Max", Double(rule.maxValue), in: 0...1) {
                    controller.stageRule(changing(rule, \.maxValue, to: max(Float($0), rule.minValue)), for: pattern.id)
                }
                ruleRow("Phase", rule.phase, in: 0...1) {
                    controller.stageRule(changing(rule, \.phase, to: $0), for: pattern.id)
                }
                ruleRow("Skew", rule.skew, in: -1...1) {
                    controller.stageRule(changing(rule, \.skew, to: $0), for: pattern.id)
                }
                ruleRow("Steps", Double(rule.steps), in: 0...32, decimals: 0) {
                    controller.stageRule(changing(rule, \.steps, to: Int($0.rounded())), for: pattern.id)
                }
            }
            let source = appState.rack.selectedSlot
            let liveValue = FaceKnobController.normalizedValue(knob: rule.knob, in: source)
            Button("Sample T\(source.index + 1) Knob \(rule.knob + 1)", systemImage: "point.topleft.down.to.point.bottomright.curvepath") {
                guard let value = FaceKnobController.normalizedValue(knob: rule.knob, in: appState.rack.selectedSlot)
                else { return }
                let head = controller.currentBeat
                let placements = controller.timeline.steps + controller.timeline.overrides
                let placement = placements.last {
                    $0.pattern.id == pattern.id && $0.startBeat <= head && head < $0.startBeat + $0.lengthBeats
                }
                let beat = min(max(head - (placement?.startBeat ?? 0), 0), pattern.lengthBeats)
                edit(pattern.id) {
                    guard case let .parametric(rule, previous) = $0.kind else { return }
                    var points = previous.filter { $0.beat != beat }
                    points.append(.init(beat: beat, value: min(max(value, 0), 1)))
                    $0.kind = .parametric(rule: rule, points: points)
                }
            }
            .disabled(liveValue == nil)
            Toggle("Shape waveform with ROTO / face knobs", isOn: $controller.sculptsWithKnobs)
        }
    }

    private func ruleRow(_ label: String, _ value: Double, in range: ClosedRange<Double>, decimals: Int = 2,
                         set: @escaping (Double) -> Void) -> some View {
        GridRow {
            Text(label)
            Slider(value: Binding(get: { value }, set: set), in: range) { Text(label) }
                .labelsHidden()
            Text(value.formatted(.number.precision(.fractionLength(decimals))))
                .monospacedDigit().frame(minWidth: 38, alignment: .trailing)
        }
    }

    private func midiEditor(_ pattern: StoryKit.Pattern, notes: [MIDINoteEvent]) -> some View {
        VStack(alignment: .leading, spacing: CreoUITokens.spacingS) {
            Canvas { context, size in
                let lowest = min(notes.map(\.note).min() ?? 60, 60)
                let highest = max(notes.map(\.note).max() ?? 71, 71)
                let row = size.height / Double(Int(highest) - Int(lowest) + 1)
                var grid = Path()
                for division in 0...16 {
                    let x = size.width * Double(division) / 16
                    grid.move(to: CGPoint(x: x, y: 0))
                    grid.addLine(to: CGPoint(x: x, y: size.height))
                }
                context.stroke(grid, with: .color(theme.textTertiary.opacity(0.3)))
                for note in notes {
                    let y = Double(highest - note.note) * row
                    let x = note.beat / pattern.lengthBeats * size.width
                    let width = min(note.durationBeats / pattern.lengthBeats * size.width, size.width - x)
                    context.fill(Path(CGRect(x: x, y: y, width: width, height: max(1, row - 1))),
                                 with: .color(theme.brandPrimary))
                }
            }
            .frame(height: 96)
            .background(theme.surfaceBgBase)
            .accessibilityLabel("MIDI roll, \(notes.count) notes")
            HStack {
                Stepper("Note \(midiNote)", value: $midiNote, in: 0...127).fixedSize()
                let nextBeat = notes.map(\.beat).max().map { $0 + 0.25 } ?? 0
                Button("Add Note") {
                    let note = UInt8(midiNote)
                    edit(pattern.id) {
                        guard case var .midi(current) = $0.kind, nextBeat < $0.lengthBeats else { return }
                        current.append(.init(beat: nextBeat, durationBeats: min(0.25, $0.lengthBeats - nextBeat),
                                             note: note, velocity: 96))
                        $0.kind = .midi(notes: current)
                    }
                }
                .disabled(nextBeat >= pattern.lengthBeats)
                Button("Clear Notes") { edit(pattern.id) { $0.kind = .midi(notes: []) } }
                    .disabled(notes.isEmpty)
            }
            Text("Use Rec and play your keyboard to create a MIDI take.").foregroundStyle(theme.textSecondary)
        }
    }

    private func audioEditor(_ pattern: StoryKit.Pattern, clip: RawAudioClip) -> some View {
        VStack(alignment: .leading, spacing: CreoUITokens.spacingS) {
            curve(clip.peaks, mirror: true)
            if let path = clip.filePath {
                Text(URL(fileURLWithPath: path).lastPathComponent).lineLimit(1)
            }
            Button(importing ? "Reading…" : "Choose Audio File", systemImage: "waveform") {
                audioImportID = pattern.id
                importsAudio = true
            }
            .disabled(importing)
        }
    }

    private var arrangement: some View {
        VStack(alignment: .leading, spacing: CreoUITokens.spacingS) {
            HStack {
                Text("Story Timeline").font(LadylandFont.bodyBold)
                Spacer()
                Button("Append Pattern", systemImage: "plus") {
                    if let pattern = selectedPattern {
                        let step = StoryStep(patternID: pattern.id)
                        if controller.edit({ $0.steps.append(step) }) != nil { selectedStep = step.id }
                    }
                }
                .disabled(selectedPattern == nil)
                Button("Earlier", systemImage: "arrow.left") { moveStep(-1) }.labelStyle(.iconOnly)
                    .disabled(stepIndex.map { $0 == 0 } ?? true)
                Button("Later", systemImage: "arrow.right") { moveStep(1) }.labelStyle(.iconOnly)
                    .disabled(stepIndex.map { $0 + 1 >= controller.document.steps.count } ?? true)
                Button("Remove Step", systemImage: "trash") {
                    let id = selectedStep
                    controller.edit { $0.steps.removeAll { $0.id == id } }
                    selectedStep = nil
                }
                .labelStyle(.iconOnly)
                .disabled(stepIndex == nil)
            }
            timeline
            ViewThatFits(in: .horizontal) {
                HStack { overrideControls }
                VStack(alignment: .leading) { overrideControls }
            }
        }
    }

    @ViewBuilder
    private var overrideControls: some View {
        HStack {
            LabeledContent("Start Bar") {
                TextField("Start Bar", value: $startBar, format: .number).frame(width: 52)
                    .help("1 = first bar")
            }
            .fixedSize()
            LabeledContent("Bars") {
                TextField("Bars", value: $overrideBars, format: .number).frame(width: 45)
            }
            .fixedSize()
            Picker("Mode", selection: $overrideMode) {
                Text("Replace").tag(OverrideMode.replace)
                Text("Layer").tag(OverrideMode.layer)
            }
            .fixedSize()
        }
        HStack {
            Button("Place Override", systemImage: "plus.rectangle.on.rectangle") {
                guard let pattern = selectedPattern else { return }
                let region = StoryOverride(startBeat: (startBar - 1) * StoryDocument.beatsPerBar,
                    lengthBeats: overrideBars * StoryDocument.beatsPerBar, overridePatternID: pattern.id, mode: overrideMode)
                if controller.edit({ $0.overrides.append(region) }) != nil { selectedOverride = region.id }
            }
            .disabled(selectedPattern == nil || !startBar.isFinite || startBar < 1 ||
                      !overrideBars.isFinite || overrideBars <= 0)
            Button("Remove Override", systemImage: "trash") {
                let id = selectedOverride
                controller.edit { $0.overrides.removeAll { $0.id == id } }
                selectedOverride = nil
            }
            .labelStyle(.iconOnly)
            .disabled(!controller.document.overrides.contains { $0.id == selectedOverride })
        }
    }

    private var timeline: some View {
        let total = max(controller.timeline.totalBeats, StoryDocument.beatsPerBar)
        let width = min(max(total / StoryDocument.beatsPerBar * 104, 380), 15_000)
        let rowHeight = 26.0
        let height = rowHeight * Double(3 + controller.timeline.overrides.count)
        return ScrollView(.horizontal) {
            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    var grid = Path()
                    let strideBeats = StoryDocument.beatsPerBar * max(1, ceil(total / StoryDocument.beatsPerBar / 320))
                    let count = max(1, Int(ceil(total / strideBeats)))
                    for bar in 0..<count {
                        let x = Double(bar) * strideBeats / total * size.width
                        grid.move(to: CGPoint(x: x, y: rowHeight))
                        grid.addLine(to: CGPoint(x: x, y: size.height))
                        let title = (Double(bar) * strideBeats / 4 + 1).formatted(.number.precision(.fractionLength(0)))
                        context.draw(Text(title).foregroundStyle(theme.textSecondary),
                                     at: CGPoint(x: x + 4, y: 5), anchor: .topLeading)
                    }
                    context.stroke(grid, with: .color(theme.textTertiary.opacity(0.25)))
                }
                .contentShape(Rectangle())
                .onTapGesture(coordinateSpace: .local) { controller.seek(to: $0.x / width * total) }

                ForEach(controller.timeline.steps) { step in
                    block(step.pattern.name, step: step, width: width, total: total, row: 1,
                          selected: step.id == selectedStep, color: theme.brandPrimary) {
                        selectedStep = step.id
                        controller.seek(to: step.startBeat)
                    }
                }
                Text("Partial Overrides").foregroundStyle(theme.textSecondary)
                    .padding(.leading, 4).offset(y: rowHeight * 2 + 4)
                ForEach(Array(controller.timeline.overrides.enumerated()), id: \.element.id) { index, region in
                    block("\(region.pattern.name) · T\(region.pattern.trackIndex + 1) \(region.pattern.kind.label) · \(region.mode?.rawValue ?? "")",
                          step: region, width: width, total: total, row: index + 3,
                          selected: region.id == selectedOverride, color: theme.brandSecondary) {
                        selectedOverride = region.id
                        controller.seek(to: region.startBeat)
                    }
                }
                Rectangle().fill(theme.brandPrimary).frame(width: 2, height: height)
                    .offset(x: min(width - 2, controller.currentBeat / total * width))
                    .allowsHitTesting(false)
            }
            .frame(width: width, height: height)
            .background(theme.surfaceBgBase)
        }
    }

    private func block(_ title: String, step: StoryTimeline.Placement, width: Double, total: Double,
                       row: Int, selected: Bool, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .lineLimit(1)
                .padding(.horizontal, 4)
                .frame(width: max(2, step.lengthBeats / total * width - 1), height: 24, alignment: .leading)
                .clipped()
                .background(color.opacity(selected ? 0.50 : 0.22), in: RoundedRectangle(cornerRadius: 3))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
        .offset(x: step.startBeat / total * width, y: Double(row) * 26)
    }

    private func curve(_ values: [Float], points: [ParametricPoint] = [], length: Double = 1,
                       mirror: Bool = false) -> some View {
        Canvas { context, size in
            let center = size.height / 2
            if mirror {
                var envelope = Path()
                for (index, value) in values.enumerated() {
                    let x = (Double(index) + 0.5) / Double(values.count) * size.width
                    let amplitude = Double(value) * center
                    envelope.move(to: CGPoint(x: x, y: center - amplitude))
                    envelope.addLine(to: CGPoint(x: x, y: center + amplitude))
                }
                context.stroke(envelope, with: .color(theme.brandPrimary), lineWidth: 2)
            } else {
                var line = Path()
                for (index, value) in values.enumerated() {
                    let point = CGPoint(x: Double(index) / Double(max(1, values.count - 1)) * size.width,
                                        y: (1 - Double(value)) * size.height)
                    if index == 0 { line.move(to: point) } else { line.addLine(to: point) }
                }
                context.stroke(line, with: .color(theme.brandPrimary), lineWidth: 1.5)
                for point in points {
                    let x = point.beat / length * size.width
                    let y = (1 - Double(point.value)) * size.height
                    context.fill(Path(ellipseIn: CGRect(x: x - 2, y: y - 2, width: 4, height: 4)),
                                 with: .color(theme.brandPrimary))
                }
            }
        }
        .frame(height: 82)
        .background(theme.surfaceBgBase)
        .accessibilityLabel(mirror ? "Audio waveform" : "Parametric waveform")
    }

    private var stepIndex: Int? { controller.document.steps.firstIndex { $0.id == selectedStep } }

    private func moveStep(_ offset: Int) {
        let id = selectedStep
        controller.edit {
            guard let from = $0.steps.firstIndex(where: { $0.id == id }),
                  $0.steps.indices.contains(from + offset) else { return }
            $0.steps.swapAt(from, from + offset)
        }
    }

    private func add(_ kind: PatternKind) {
        let pattern = StoryKit.Pattern(name: kind.label, trackIndex: appState.rack.selected, lengthBeats: 4, kind: kind)
        if controller.edit({ $0.patterns.append(pattern) }) != nil {
            controller.selectedPatternID = pattern.id
        }
    }

    private func edit(_ id: String, _ change: (inout StoryKit.Pattern) -> Void) {
        controller.edit {
            guard let index = $0.patterns.firstIndex(where: { $0.id == id }) else { return }
            change(&$0.patterns[index])
        }
    }

    private func changing<Value>(_ rule: ParametricRule, _ field: WritableKeyPath<ParametricRule, Value>,
                                 to value: Value) -> ParametricRule {
        var rule = rule
        rule[keyPath: field] = value
        return rule
    }

    private func importAudio(_ result: Result<URL, Error>) {
        guard let id = audioImportID else { return }
        do {
            let url = try result.get()
            importing = true
            Task { @MainActor in
                defer { importing = false }
                do {
                    let clip = try await Task.detached(priority: .userInitiated) {
                        let access = url.startAccessingSecurityScopedResource()
                        defer { if access { url.stopAccessingSecurityScopedResource() } }
                        return try RawAudioClip.load(url)
                    }.value
                    let bpm = controller.tempo()
                    edit(id) {
                        $0.lengthBeats = max(0.001, clip.durationSeconds * bpm / 60)
                        $0.kind = .rawAudio(clip: clip)
                    }
                } catch { controller.report(error) }
            }
        } catch { controller.report(error) }
    }

    private func bars(_ beats: Double) -> String {
        (beats / StoryDocument.beatsPerBar).formatted(.number.precision(.fractionLength(0...2)))
    }

    private func position(_ beat: Double) -> String {
        let bar = floor(beat / StoryDocument.beatsPerBar) + 1
        let beatInBar = floor(beat.truncatingRemainder(dividingBy: StoryDocument.beatsPerBar)) + 1
        return "\(bar.formatted(.number.grouping(.never))).\(Int(beatInBar))"
    }
}
