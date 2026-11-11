import AppKit
import AVFoundation
import CoreMedia
import Network
import os
import SwiftUI
import UniversalKMCore

/// The phone's screen in a Mac window (openspec/changes/add-android-screen-mirror): scrcpy-server on the device
/// through `adb shell` (design D1, D2), its H.264 into a display layer (D3), mouse and keys back as control
/// messages (D4).
@MainActor
final class ScreenMirrorSession: ObservableObject {
    enum Phase: Equatable {
        case connecting
        case playing
        case failed(String)
    }

    let layer = AVSampleBufferDisplayLayer()
    @Published private(set) var phase = Phase.connecting
    /// The frame size of the current capture (changes when the device turns).
    @Published private(set) var videoSize = CGSize.zero
    /// Called with the first frame size and again when the device turns (portrait ↔ landscape): the window
    /// takes the device's proportions.
    var onOrientation: ((CGSize) -> Void)?

    private let adb: ADBClient
    private let transport: String
    private var process: Process?
    private var port: Int?
    private var video: NWConnection?
    private var control: NWConnection?
    private var parser = ScreenMirror.Parser()
    private var format: CMVideoFormatDescription?
    /// The server answered on the video socket (its dummy byte came).
    private var answered = false
    private var stopped = true
    private var deadline = Date()
    /// The server's last error line, shown when it stops.
    private var serverError: String?
    /// The lock pattern's nine dots in video pixels while the hint is shown. The pattern screen is a secure
    /// window, black in the capture; uiautomator still gives its place.
    @Published private(set) var patternDots: [CGPoint]?
    /// The mouse path of the pattern being drawn, in video pixels.
    @Published private(set) var patternTrail: [CGPoint] = []
    @Published private(set) var patternNote: String?
    @Published private(set) var findingPattern = false
    /// Where the current press started while no hint is shown (a swipe up looks for the pattern).
    private var swipeStart: CGPoint?
    /// Portrait or landscape of the last size passed to `onOrientation`; nil before the first.
    private var landscape: Bool?
    private let log = Logger(subsystem: "com.universalkm.UniversalKM", category: "screen")

    init(adb: ADBClient, transport: String) {
        self.adb = adb
        self.transport = transport
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = NSColor.black.cgColor
    }

    /// The server file in the app (or the repository's Resources under `swift run`).
    private static var serverJar: URL? {
        if let url = Bundle.main.url(forResource: "scrcpy-server", withExtension: "jar") { return url }
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/scrcpy-server.jar")
        return FileManager.default.fileExists(atPath: repo.path) ? repo : nil
    }

    func start() {
        stop()
        stopped = false
        phase = .connecting
        serverError = nil
        guard let jar = Self.serverJar else {
            phase = .failed(String(localized: "The screen server is missing from the app."))
            return
        }
        let remote = ScreenMirror.remotePath
        adb.run(["-s", transport, "shell", "ls \(remote)"], timeout: 10, on: .main) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self, !self.stopped else { return }
                if result.ok && result.output.contains(remote) {
                    self.launch()
                    return
                }
                self.log.info("pushing scrcpy-server to \(self.transport, privacy: .public)")
                self.adb.run(["-s", self.transport, "push", jar.path, remote], timeout: 30, on: .main) { [weak self] result in
                    MainActor.assumeIsolated {
                        guard let self, !self.stopped else { return }
                        if result.ok {
                            self.launch()
                        } else {
                            self.fail(result.error.trimmingCharacters(in: .whitespacesAndNewlines))
                        }
                    }
                }
            }
        }
    }

    func stop() {
        stopped = true
        video?.cancel()
        video = nil
        control?.cancel()
        control = nil
        if let process, process.isRunning { process.terminate() }
        process = nil
        if let port {
            adb.run(["-s", transport, "forward", "--remove", "tcp:\(port)"], on: .main) { _ in }
            self.port = nil
        }
        layer.sampleBufferRenderer.flush(removingDisplayedImage: true) {}
    }

    private func fail(_ message: String) {
        guard !stopped else { return }
        log.error("screen \(self.transport, privacy: .public): \(message, privacy: .public)")
        stop()
        phase = .failed(message.isEmpty ? String(localized: "The connection to the device was lost.") : message)
    }

    private func launch() {
        let scid = UInt32.random(in: 1...0x7FFF_FFFF)
        let p = Process()
        p.executableURL = adb.url
        p.arguments = ["-s", transport, "shell", ScreenMirror.serverCommand(scid: scid)]
        let output = Pipe()
        p.standardOutput = output
        p.standardError = output
        p.standardInput = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { handle.readabilityHandler = nil; return }
            let text = String(decoding: chunk, as: UTF8.self)
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.serverSaid(text) } }
        }
        p.terminationHandler = { [weak self] p in
            let status = p.terminationStatus
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.process === p else { return }
                    self.process = nil
                    self.fail(self.serverError ?? String(localized: "The screen server on the device stopped (\(Int(status))).")
                    )
                }
            }
        }
        do {
            try p.run()
        } catch {
            fail(error.localizedDescription)
            return
        }
        process = p
        adb.run(["-s", transport, "forward", "tcp:0", ScreenMirror.socket(scid: scid)], on: .main) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self, !self.stopped else { return }
                guard result.ok, let port = Int(result.output.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                    self.fail(result.error.trimmingCharacters(in: .whitespacesAndNewlines))
                    return
                }
                self.port = port
                self.deadline = Date().addingTimeInterval(10)
                self.connectVideo()
            }
        }
    }

    private func serverSaid(_ text: String) {
        for line in text.split(whereSeparator: \.isNewline) {
            let s = String(line)
            log.info("scrcpy: \(s, privacy: .public)")
            if let r = s.range(of: "ERROR: ") { serverError = String(s[r.upperBound...]) }
        }
    }

    private func endpoint() -> NWEndpoint? {
        guard let port, let p = NWEndpoint.Port(rawValue: UInt16(port)) else { return nil }
        return .hostPort(host: "127.0.0.1", port: p)
    }

    /// The first connection is the video one. Until the server listens, adb accepts it and closes it at once:
    /// try again until the dummy byte comes.
    private func connectVideo() {
        guard !stopped, let ep = endpoint() else { return }
        video?.cancel()
        answered = false
        parser = ScreenMirror.Parser()
        format = nil
        let c = NWConnection(to: ep, using: .tcp)
        video = c
        c.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self, self.video === c else { return }
                switch state {
                case .ready: self.receiveVideo(c)
                case .failed, .waiting: self.videoClosed(c)
                default: break
                }
            }
        }
        c.start(queue: .main)
    }

    private func videoClosed(_ c: NWConnection) {
        guard !stopped, video === c else { return }
        c.cancel()
        video = nil
        if answered {
            fail(serverError ?? String(localized: "The connection to the device was lost."))
            return
        }
        guard Date() < deadline else {
            fail(serverError ?? String(localized: "The screen server on the device does not answer."))
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.connectVideo() }
    }

    private func receiveVideo(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
            MainActor.assumeIsolated {
                guard let self, self.video === c else { return }
                if let data, !data.isEmpty {
                    if !self.answered {
                        self.answered = true
                        self.connectControl()
                    }
                    do {
                        for p in try self.parser.append(data) { self.handle(p) }
                    } catch {
                        self.fail(String(describing: error))
                        return
                    }
                }
                if done || error != nil {
                    self.videoClosed(c)
                } else {
                    self.receiveVideo(c)
                }
            }
        }
    }

    /// The second connection carries the control messages; the server sends nothing on it that we use.
    private func connectControl() {
        guard let ep = endpoint() else { return }
        let c = NWConnection(to: ep, using: .tcp)
        control = c
        c.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self, self.control === c else { return }
                if case .ready = state { self.drainControl(c) }
                if case .failed = state { self.fail(String(localized: "The connection to the device was lost.")) }
            }
        }
        c.start(queue: .main)
    }

    private func drainControl(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] _, _, done, error in
            MainActor.assumeIsolated {
                guard let self, self.control === c, !done, error == nil else { return }
                self.drainControl(c)
            }
        }
    }

    private func handle(_ packet: ScreenMirror.Packet) {
        switch packet {
        case let .codec(id):
            if id != ScreenMirror.h264 {
                fail(serverError ?? String(localized: "The device cannot show its screen."))
            }
        case let .session(width, height):
            if videoSize != CGSize(width: width, height: height) { hidePattern() }
            videoSize = CGSize(width: width, height: height)
            if width > 0, height > 0, landscape != (width > height) {
                landscape = width > height
                onOrientation?(videoSize)
            }
        case let .config(annexB):
            guard let sets = ScreenMirror.parameterSets(annexB) else { return }
            format = Self.formatDescription(sps: sets.sps, pps: sets.pps)
        case let .frame(_, _, annexB):
            guard let format, let sample = Self.sampleBuffer(MotionLive.avcc(annexB), format: format) else { return }
            let renderer = layer.sampleBufferRenderer
            if renderer.status == .failed {
                log.error("screen renderer failed: \(String(describing: renderer.error), privacy: .public)")
                renderer.flush()
            }
            renderer.enqueue(sample)
            if phase != .playing { phase = .playing }
        }
    }

    // MARK: Input (design D4)

    private func send(_ data: Data) {
        guard let control, phase == .playing else { return }
        control.send(content: data, completion: .contentProcessed { _ in })
    }

    private var width: Int { Int(videoSize.width) }
    private var height: Int { Int(videoSize.height) }

    func touch(_ action: ScreenMirror.Control.TouchAction, x: Int, y: Int) {
        send(ScreenMirror.Control.touch(action, x: x, y: y, width: width, height: height))
        if action != .move { log.debug("touch \(action == .down ? "down" : "up", privacy: .public) \(x),\(y) of \(self.width)×\(self.height)") }
        let p = CGPoint(x: x, y: y)
        guard patternDots != nil else {
            // A swipe up over a quarter of the screen may have opened the pattern screen: look for it, quietly.
            switch action {
            case .down: swipeStart = p
            case .move: break
            case .up:
                if let start = swipeStart, start.y - p.y > videoSize.height / 4, !findingPattern {
                    log.info("swipe up: looking for the lock pattern")
                    findingPattern = true
                    probePattern(attempt: 0, quiet: true)
                }
                swipeStart = nil
            }
            return
        }
        switch action {
        case .down: patternTrail = [p]
        case .move: patternTrail.append(p)
        case .up:
            patternTrail.append(p)
            // The pattern is entered: the hint goes once the phone had a moment to take it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                MainActor.assumeIsolated { self?.hidePattern() }
            }
        }
    }

    // MARK: Lock pattern hint

    /// "Pattern dots": finds the pattern field on the device and shows its dots over the black picture.
    func findPattern() {
        guard !findingPattern, phase == .playing else { return }
        findingPattern = true
        patternNote = nil
        probePattern(attempt: 0, quiet: false)
    }

    /// `quiet`: after a swipe, not asked for: no note when there is no pattern.
    private func probePattern(attempt: Int, quiet: Bool) {
        adb.run(["-s", transport, "shell", ScreenMirror.lockScreenProbe], timeout: 15, on: .main) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self, !self.stopped else { return }
                guard let found = ScreenMirror.lockPattern(probe: result.output), self.videoSize.width > 0 else {
                    self.log.info("no lock pattern on the screen (try \(attempt + 1), \(result.output.count) bytes)")
                    // uiautomator fails while the screen still animates: once more.
                    if attempt == 0 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                            MainActor.assumeIsolated { self?.probePattern(attempt: 1, quiet: quiet) }
                        }
                        return
                    }
                    self.findingPattern = false
                    if !quiet { self.showPatternNote(String(localized: "No pattern on the screen. Swipe the lock screen up first, then press this button again.")) }
                    return
                }
                self.findingPattern = false
                let sx = self.videoSize.width / found.display.width, sy = self.videoSize.height / found.display.height
                self.patternDots = ScreenMirror.patternDots(found.field).map { CGPoint(x: $0.x * sx, y: $0.y * sy) }
                self.patternTrail = []
            }
        }
    }

    private func hidePattern() {
        patternDots = nil
        patternTrail = []
    }

    private func showPatternNote(_ note: String) {
        patternNote = note
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            MainActor.assumeIsolated { if self?.patternNote == note { self?.patternNote = nil } }
        }
    }

    func scroll(x: Int, y: Int, horizontal: Double, vertical: Double) {
        send(ScreenMirror.Control.scroll(x: x, y: y, width: width, height: height,
                                         horizontal: horizontal, vertical: vertical))
    }

    func press(_ key: ScreenMirror.Control.Key) {
        send(ScreenMirror.Control.key(.down, key))
        send(ScreenMirror.Control.key(.up, key))
    }

    func back() {
        send(ScreenMirror.Control.backOrScreenOn(.down))
        send(ScreenMirror.Control.backOrScreenOn(.up))
    }

    func type(_ text: String) {
        guard !text.isEmpty else { return }
        send(ScreenMirror.Control.text(text))
    }

    // MARK: Video

    private static func formatDescription(sps: Data, pps: Data) -> CMVideoFormatDescription? {
        var format: CMVideoFormatDescription?
        let status = sps.withUnsafeBytes { s in
            pps.withUnsafeBytes { p in
                let pointers = [s.bindMemory(to: UInt8.self).baseAddress!, p.bindMemory(to: UInt8.self).baseAddress!]
                let sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: 2, parameterSetPointers: pointers,
                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &format)
            }
        }
        return status == noErr ? format : nil
    }

    /// A frame shown as soon as it arrives.
    private static func sampleBuffer(_ avcc: Data, format: CMVideoFormatDescription) -> CMSampleBuffer? {
        guard !avcc.isEmpty else { return nil }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: avcc.count,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
                                                 offsetToData: 0, dataLength: avcc.count, flags: 0,
                                                 blockBufferOut: &block) == noErr, let block else { return nil }
        let copied = avcc.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
                                                                           offsetIntoDestination: 0, dataLength: avcc.count) }
        guard copied == noErr else { return nil }
        var sample: CMSampleBuffer?
        var size = avcc.count
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
                                        sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
                                        sampleSizeEntryCount: 1, sampleSizeArray: &size,
                                        sampleBufferOut: &sample) == noErr, let sample else { return nil }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }
}

/// The picture, taking the mouse, the wheel and the keyboard.
struct ScreenMirrorVideo: NSViewRepresentable {
    let session: ScreenMirrorSession

    func makeNSView(context: Context) -> ScreenView {
        ScreenView(session: session)
    }

    func updateNSView(_ v: ScreenView, context: Context) {}

    final class ScreenView: NSView {
        private let session: ScreenMirrorSession
        /// A finger is down on the device (the press started on the picture).
        private var touching = false

        init(session: ScreenMirrorSession) {
            self.session = session
            super.init(frame: .zero)
            wantsLayer = true
            layer?.backgroundColor = NSColor.black.cgColor
            layer?.addSublayer(session.layer)
        }

        required init?(coder: NSCoder) { nil }

        override var isFlipped: Bool { true }
        override var acceptsFirstResponder: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.makeFirstResponder(self)
        }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            session.layer.frame = bounds
            CATransaction.commit()
        }

        private func location(_ event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }

        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            guard let p = ScreenMirror.videoPoint(location(event), view: bounds.size, video: session.videoSize) else { return }
            touching = true
            session.touch(.down, x: p.x, y: p.y)
        }

        override func mouseDragged(with event: NSEvent) {
            guard touching else { return }
            let p = ScreenMirror.clampedVideoPoint(location(event), view: bounds.size, video: session.videoSize)
            session.touch(.move, x: p.x, y: p.y)
        }

        override func mouseUp(with event: NSEvent) {
            guard touching else { return }
            touching = false
            let p = ScreenMirror.clampedVideoPoint(location(event), view: bounds.size, video: session.videoSize)
            session.touch(.up, x: p.x, y: p.y)
        }

        override func rightMouseDown(with event: NSEvent) {
            session.back()
        }

        override func scrollWheel(with event: NSEvent) {
            let p = ScreenMirror.clampedVideoPoint(location(event), view: bounds.size, video: session.videoSize)
            // A wheel gives whole clicks; a trackpad gives points, about ten per click.
            let k = event.hasPreciseScrollingDeltas ? 0.1 : 1.0
            let h = -Double(event.scrollingDeltaX) * k, v = Double(event.scrollingDeltaY) * k
            guard h != 0 || v != 0 else { return }
            session.scroll(x: p.x, y: p.y, horizontal: h, vertical: v)
        }

        override func keyDown(with event: NSEvent) {
            if event.modifierFlags.contains(.command) {
                super.keyDown(with: event)
                return
            }
            switch event.keyCode {
            case 36, 76: session.press(.enter)
            case 51: session.press(.delete)
            case 117: session.press(.forwardDelete)
            case 123: session.press(.left)
            case 124: session.press(.right)
            case 125: session.press(.down)
            case 126: session.press(.up)
            case 48: session.press(.tab)
            case 53: session.back()
            default:
                let text = (event.characters ?? "").filter { c in
                    !c.unicodeScalars.contains { $0.properties.generalCategory == .control || (0xF700...0xF8FF).contains($0.value) }
                }
                session.type(text)
            }
        }
    }
}

struct ScreenMirrorWindowView: View {
    @ObservedObject var session: ScreenMirrorSession

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                ScreenMirrorVideo(session: session)
                PatternHint(session: session).allowsHitTesting(false)
                switch session.phase {
                case .connecting:
                    VStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Connecting…").font(.callout)
                    }
                    .foregroundStyle(.white)
                    .allowsHitTesting(false)
                case .playing:
                    EmptyView()
                case let .failed(message):
                    VStack(spacing: 8) {
                        Text(message).font(.callout).multilineTextAlignment(.center)
                        Button("Try Again") { session.start() }
                    }
                    .foregroundStyle(.white)
                    .padding()
                }
            }
            .background(Color.black)
            HStack(spacing: 28) {
                navButton("chevron.backward", String(localized: "Back")) { session.back() }
                navButton("circle", String(localized: "Home")) { session.press(.home) }
                navButton("square.on.square", String(localized: "Recent Apps")) { session.press(.appSwitch) }
                navButton("circle.grid.3x3", String(localized: "Show the lock pattern dots")) { session.findPattern() }
                    .disabled(session.findingPattern)
            }
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .disabled(session.phase != .playing)
        }
        .frame(minWidth: 240, minHeight: 320)
    }

    /// The nine dots of the lock pattern over the black picture, and the path being drawn through them.
    private struct PatternHint: View {
        @ObservedObject var session: ScreenMirrorSession

        var body: some View {
            GeometryReader { geo in
                ZStack(alignment: .top) {
                    if let dots = session.patternDots {
                        Canvas { ctx, size in draw(ctx, size, dots) }
                        Text("Draw your pattern through the dots")
                            .font(.callout).foregroundStyle(.white)
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(.black.opacity(0.6), in: Capsule())
                            .padding(.top, 12)
                    }
                    if let note = session.patternNote {
                        VStack {
                            Spacer()
                            Text(note).font(.callout).foregroundStyle(.white).multilineTextAlignment(.center)
                                .padding(10)
                                .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 8))
                                .padding(12)
                        }
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }

        private func draw(_ ctx: GraphicsContext, _ size: CGSize, _ dots: [CGPoint]) {
            let video = session.videoSize
            let place = { (p: CGPoint) in ScreenMirror.viewPoint(p, view: size, video: video) }
            let shown = dots.map(place)
            // Cell size on the screen: the distance between neighbouring dots.
            let cell = hypot(shown[1].x - shown[0].x, shown[1].y - shown[0].y)
            let trail = session.patternTrail.map(place)
            // A dot counts as passed when the path came within a third of a cell (Android is about as generous).
            let passed = shown.map { d in trail.contains { hypot($0.x - d.x, $0.y - d.y) < cell / 3 } }
            if trail.count > 1 {
                var path = Path()
                path.addLines(trail)
                ctx.stroke(path, with: .color(.accentColor.opacity(0.8)),
                           style: StrokeStyle(lineWidth: max(4, cell * 0.08), lineCap: .round, lineJoin: .round))
            }
            for (i, d) in shown.enumerated() {
                let r = max(6, cell * 0.1)
                let dot = Path(ellipseIn: CGRect(x: d.x - r, y: d.y - r, width: 2 * r, height: 2 * r))
                ctx.fill(dot, with: .color(passed[i] ? .accentColor : .white.opacity(0.85)))
                let ring = Path(ellipseIn: CGRect(x: d.x - r * 2.2, y: d.y - r * 2.2, width: 4.4 * r, height: 4.4 * r))
                ctx.stroke(ring, with: .color(.white.opacity(passed[i] ? 0.6 : 0.25)), lineWidth: 1.5)
            }
        }
    }

    private func navButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.body.weight(.medium)).frame(width: 28, height: 22)
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(help)
    }
}
