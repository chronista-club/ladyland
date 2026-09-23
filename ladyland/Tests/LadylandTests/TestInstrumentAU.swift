//! Process-local real AU fixture: no installation, licence, samples, or network.
//! Reuses LadySynth's MIDI/DSP; adds a gain parameter, state and a one-shot editor.
//! Compiled only into the test target, never registered in the shipping app.
import AppKit
import AVFoundation
import CoreAudioKit
import Testing
@testable import Ladyland

final class TestInstrumentAU: AUAudioUnit, @unchecked Sendable {
    static let manufacturer: OSType = 0x4C4C5453 // LLTS
    static let subtypes: [OSType] = [0x74737431, 0x74737432] // tst1, tst2
    private static let registration: Void = {
        for (index, subtype) in subtypes.enumerated() {
            AUAudioUnit.registerSubclass(TestInstrumentAU.self, as: AudioComponentDescription(
                componentType: kAudioUnitType_MusicDevice, componentSubType: subtype,
                componentManufacturer: manufacturer, componentFlags: 0, componentFlagsMask: 0),
                name: "Ladyland Test Tone \(index + 1)", version: 1)
        }
    }()
    static func register() { _ = registration }

    /// `registerSubclass` reaches `AVAudioUnitComponentManager` asynchronously: a
    /// catalog enumerated right after registration can miss the fixture (seen as a
    /// flaky first test). Yield to the main actor until it appears, then give up.
    @MainActor
    static func component(in rack: InstrumentRack, index: Int = 0) async throws -> InstrumentComponent {
        func find(_ catalog: [InstrumentComponent]) -> InstrumentComponent? {
            catalog.first {
                $0.description.componentManufacturer == manufacturer &&
                $0.description.componentSubType == subtypes[index]
            }
        }
        if let found = find(rack.catalog) { return found }
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(20))
            if let found = find(PluginCatalog.instruments()) { return found }
        }
        return try #require(nil as InstrumentComponent?,
            "Test AU must be registered; never silently skip host coverage")
    }

    private let synth: LadySynth
    private let bus: AUAudioUnitBus
    private var buses: AUAudioUnitBusArray!
    private var parameters: AUParameterTree!
    private let lock = NSLock()
    private var gain: AUValue = 0.5
    private var editorRequested = false

    override init(componentDescription: AudioComponentDescription,
                  options: AudioComponentInstantiationOptions = []) throws {
        synth = try LadySynth(componentDescription: componentDescription, options: options)
        bus = try AUAudioUnitBus(format: AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!)
        try super.init(componentDescription: componentDescription, options: options)
        buses = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [bus])
        let level = AUParameterTree.createParameter(withIdentifier: "level", name: "Level",
            address: 0, min: 0, max: 1, unit: .linearGain, unitName: nil,
            flags: [.flag_IsReadable, .flag_IsWritable], valueStrings: nil, dependentParameters: nil)
        parameters = AUParameterTree.createTree(withChildren: [level])
        parameters.implementorValueObserver = { [weak self] _, value in
            guard let self else { return }
            self.lock.lock(); self.gain = value; self.lock.unlock()
        }
        parameters.implementorValueProvider = { [weak self] _ in
            guard let self else { return 0 }
            self.lock.lock(); defer { self.lock.unlock() }; return self.gain
        }
        level.value = 0.5
    }
    override var outputBusses: AUAudioUnitBusArray { buses }
    override var parameterTree: AUParameterTree? {
        get { parameters }
        set { parameters = newValue }
    }
    override func allocateRenderResources() throws {
        try synth.outputBusses[0].setFormat(bus.format)
        synth.maximumFramesToRender = maximumFramesToRender
        try synth.allocateRenderResources()
        do { try super.allocateRenderResources() }
        catch { synth.deallocateRenderResources(); throw error }
    }
    override func deallocateRenderResources() {
        synth.deallocateRenderResources()
        super.deallocateRenderResources()
    }
    override var scheduleMIDIEventBlock: AUScheduleMIDIEventBlock? { synth.scheduleMIDIEventBlock }
    override var internalRenderBlock: AUInternalRenderBlock {
        let render = synth.internalRenderBlock
        return { [weak self] flags, time, frames, bus, output, events, pull in
            let status = render(flags, time, frames, bus, output, events, pull)
            guard status == noErr, let self else { return status }
            self.lock.lock(); let gain = self.gain; self.lock.unlock()
            for buffer in UnsafeMutableAudioBufferListPointer(output) {
                guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                for i in 0..<(Int(frames) * Int(buffer.mNumberChannels)) { data[i] *= gain }
            }
            return noErr
        }
    }
    override var fullState: [String: Any]? {
        get {
            var state = super.fullState ?? [:]
            state["testLevel"] = parameters.parameter(withAddress: 0)!.value
            return state
        }
        set {
            super.fullState = newValue
            if let value = newValue?["testLevel"] as? NSNumber {
                parameters.parameter(withAddress: 0)?.value = value.floatValue
            }
        }
    }
    override func supportedViewConfigurations(_ configurations: [AUAudioUnitViewConfiguration]) -> IndexSet {
        IndexSet(configurations.indices.filter {
            let c = configurations[$0]
            return c.width.isFinite && c.height.isFinite && c.width > 0 && c.height > 0
        })
    }
    override func requestViewController(completionHandler: @escaping (NSViewController?) -> Void) {
        Task { @MainActor in
            // Enforce the one-request lifetime seen in third-party AUs.
            guard !self.editorRequested else { completionHandler(nil); return }
            self.editorRequested = true
            let controller = NSViewController()
            controller.view = TestInstrumentView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
            let label = NSTextField(labelWithString: "Ladyland Test AU")
            label.frame = NSRect(x: 20, y: 20, width: 200, height: 24)
            controller.view.addSubview(label)
            controller.preferredContentSize = NSSize(width: 640, height: 360)
            completionHandler(controller)
        }
    }
}

// Large contrasting regions survive the thumbnail's sparse blank-image sampling.
private final class TestInstrumentView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemBlue.setFill()
        bounds.fill()
        NSColor.white.setFill()
        NSRect(x: bounds.midX, y: bounds.minY, width: bounds.width / 2, height: bounds.height).fill()
    }
}
