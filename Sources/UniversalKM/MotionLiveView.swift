import AppKit
import AVFoundation
import CoreMedia
import Network
import os
import SwiftUI
import UniversalKMCore

/// One camera's live picture (add-android-motion-camera design D11): `adb forward` to the app's local socket,
/// then the encoder's H.264 frames straight into a display layer. No decoding of our own, no extra encoder on
/// the device.
@MainActor
final class MotionLiveStream: ObservableObject {
    enum Phase: Equatable {
        case connecting
        case playing
        case failed(String)
    }

    let facing: MotionLive.Facing
    let layer = AVSampleBufferDisplayLayer()
    @Published private(set) var phase = Phase.connecting
    /// Clockwise turn that shows the picture upright; the picture's size before the turn.
    @Published private(set) var rotation = 0
    @Published private(set) var size = CGSize(width: 16, height: 9)

    private let adb: ADBClient
    private let transport: String
    private var port: Int?
    private var connection: NWConnection?
    private var parser = MotionLive.Parser()
    private var format: CMVideoFormatDescription?
    private var stopped = false
    /// Connection attempts give up after this (the camera did not come up on the device).
    private var deadline = Date()
    private let log = Logger(subsystem: "com.universalkm.UniversalKM", category: "motion")

    init(adb: ADBClient, transport: String, facing: MotionLive.Facing) {
        self.adb = adb
        self.transport = transport
        self.facing = facing
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = NSColor.black.cgColor
    }

    func start() {
        stopped = false
        phase = .connecting
        deadline = Date().addingTimeInterval(20)
        if port != nil { connect(); return }
        adb.run(["-s", transport, "forward", "tcp:0", MotionLive.socket], on: .main) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self, !self.stopped else { return }
                guard result.ok, let port = Int(result.output.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                    self.phase = .failed(result.error.trimmingCharacters(in: .whitespacesAndNewlines))
                    return
                }
                self.port = port
                self.connect()
            }
        }
    }

    func stop() {
        stopped = true
        connection?.cancel()
        connection = nil
        if let port {
            adb.run(["-s", transport, "forward", "--remove", "tcp:\(port)"], on: .main) { _ in }
            self.port = nil
        }
        layer.sampleBufferRenderer.flush(removingDisplayedImage: true) {}
    }

    private func connect() {
        guard !stopped, let port, let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else { return }
        connection?.cancel()
        parser = MotionLive.Parser()
        format = nil
        let c = NWConnection(host: "127.0.0.1", port: nwPort, using: .tcp)
        connection = c
        c.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self, self.connection === c else { return }
                switch state {
                case .ready:
                    c.send(content: self.facing.request, completion: .contentProcessed { _ in })
                    self.receive(c)
                case .failed, .waiting:
                    self.retry(c)
                default:
                    break
                }
            }
        }
        c.start(queue: .main)
    }

    /// adb accepts the TCP connection even while the socket on the device is not there yet, then closes it:
    /// try again until the camera is up.
    private func retry(_ c: NWConnection) {
        guard !stopped, connection === c else { return }
        c.cancel()
        connection = nil
        if Date() > deadline {
            phase = .failed(String(localized: "The camera does not answer. It may be busy, or turned off on the device."))
            return
        }
        if phase == .playing { phase = .connecting }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.connect() }
    }

    private func receive(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
            MainActor.assumeIsolated {
                guard let self, self.connection === c else { return }
                if let data, !data.isEmpty {
                    do {
                        for p in try self.parser.append(data) { self.handle(p) }
                    } catch {
                        self.log.error("motion live: \(String(describing: error), privacy: .public)")
                        self.retry(c)
                        return
                    }
                }
                if done || error != nil {
                    self.retry(c)
                } else {
                    self.receive(c)
                }
            }
        }
    }

    private func handle(_ packet: MotionLive.Packet) {
        switch packet {
        case let .config(width, height, sps, pps):
            format = Self.formatDescription(sps: sps, pps: pps)
            size = CGSize(width: width, height: height)
        case let .frame(_, _, rotation, annexB):
            guard let format, let sample = Self.sampleBuffer(MotionLive.avcc(annexB), format: format) else { return }
            let renderer = layer.sampleBufferRenderer
            if renderer.status == .failed {
                log.error("motion live \(self.facing.rawValue, privacy: .public): renderer failed: \(String(describing: renderer.error), privacy: .public)")
                renderer.flush()
            }
            renderer.enqueue(sample)
            if self.rotation != rotation { self.rotation = rotation }
            if phase != .playing {
                log.info("motion live \(self.facing.rawValue, privacy: .public): playing, rotation \(rotation)")
                phase = .playing
                deadline = Date().addingTimeInterval(20)
            }
        }
    }

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

    /// A frame shown as soon as it arrives: live, not played on a timeline.
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

/// The live picture of one device: which cameras, their streams, and telling the device (design D11).
@MainActor
final class MotionLiveSession: ObservableObject {
    @Published private(set) var selection: Set<MotionLive.Facing>
    @Published private(set) var streams: [MotionLive.Facing: MotionLiveStream] = [:]
    let peer: UInt16
    private let cameras: MotionCameras
    private static let selectionKey = "motionLiveCameras"

    init(cameras: MotionCameras, peer: UInt16) {
        self.cameras = cameras
        self.peer = peer
        let saved = (UserDefaults.standard.array(forKey: Self.selectionKey) as? [String] ?? ["back"])
            .compactMap(MotionLive.Facing.init(rawValue:))
        selection = saved.isEmpty ? [.back] : Set(saved)
        // "Both" only where the device can.
        if selection.count == 2, cameras.camera(peer).status?.bothSupported == false { selection = [.back] }
    }

    func start() {
        select(selection, force: true)
    }

    func select(_ next: Set<MotionLive.Facing>, force: Bool = false) {
        guard !next.isEmpty, force || next != selection else { return }
        selection = next
        UserDefaults.standard.set(next.map(\.rawValue), forKey: Self.selectionKey)
        for (facing, stream) in streams where !next.contains(facing) {
            stream.stop()
            streams[facing] = nil
        }
        cameras.send(peer, MotionCamera.liveCommand(next)) { [weak self] _ in
            guard let self, let adb = self.cameras.adb, let t = self.cameras.transport(self.peer) else { return }
            for facing in MotionLive.Facing.allCases where self.selection.contains(facing) {
                if let s = self.streams[facing] {
                    if case .failed = s.phase { s.start() }
                    continue
                }
                let s = MotionLiveStream(adb: adb, transport: t, facing: facing)
                self.streams[facing] = s
                s.start()
            }
        }
    }

    /// Again after "The camera does not answer".
    func retry() {
        select(selection, force: true)
    }

    func stop() {
        for s in streams.values { s.stop() }
        streams = [:]
        cameras.send(peer, MotionCamera.liveCommand([]))
    }
}

/// The video of one stream, turned upright and fitted into the view.
struct LiveVideo: NSViewRepresentable {
    @ObservedObject var stream: MotionLiveStream

    func makeNSView(context: Context) -> LiveVideoView {
        let v = LiveVideoView()
        v.attach(stream.layer)
        return v
    }

    func updateNSView(_ v: LiveVideoView, context: Context) {
        v.rotation = stream.rotation
    }

    final class LiveVideoView: NSView {
        private var video: CALayer?
        var rotation = 0 {
            didSet { if rotation != oldValue { needsLayout = true } }
        }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.backgroundColor = NSColor.black.cgColor
        }

        required init?(coder: NSCoder) { nil }

        func attach(_ l: CALayer) {
            video = l
            layer?.addSublayer(l)
        }

        override func layout() {
            super.layout()
            guard let video else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let b = bounds
            let turned = rotation % 180 != 0
            video.setAffineTransform(.identity)
            video.bounds = CGRect(x: 0, y: 0, width: turned ? b.height : b.width, height: turned ? b.width : b.height)
            video.position = CGPoint(x: b.midX, y: b.midY)
            // Layer angles go counterclockwise; the device gives a clockwise turn.
            video.setAffineTransform(CGAffineTransform(rotationAngle: -CGFloat(rotation) * .pi / 180))
            CATransaction.commit()
        }
    }
}

struct MotionLiveWindowView: View {
    @ObservedObject var cameras: MotionCameras
    @ObservedObject var session: MotionLiveSession

    private var status: MotionStatus? { cameras.camera(session.peer).status }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("Camera", selection: Binding(get: { choice }, set: { session.select(Self.facings($0)) })) {
                    Text("Rear").tag(MotionSettings.Camera.back)
                    Text("Front").tag(MotionSettings.Camera.front)
                    if status?.bothSupported == true {
                        Text("Both").tag(MotionSettings.Camera.both)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                if status?.state == .recording {
                    Label("Recording", systemImage: "record.circle.fill")
                        .foregroundStyle(.red).font(.callout)
                }
                Spacer()
                if let note {
                    Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        .multilineTextAlignment(.trailing)
                }
            }
            .padding(10)
            HStack(spacing: 2) {
                ForEach(MotionLive.Facing.allCases, id: \.self) { facing in
                    if let stream = session.streams[facing] {
                        StreamPane(stream: stream, retry: session.retry)
                    }
                }
            }
            .background(Color.black)
        }
        .frame(minWidth: 360, minHeight: 300)
    }

    private var choice: MotionSettings.Camera {
        session.selection.count == 2 ? .both : session.selection.contains(.front) ? .front : .back
    }

    private static func facings(_ c: MotionSettings.Camera) -> Set<MotionLive.Facing> {
        switch c {
        case .back: [.back]
        case .front: [.front]
        case .both: [.back, .front]
        }
    }

    /// A camera asked for but not open: the device cannot use two at once and records with the other one.
    private var note: String? {
        guard let status, !status.live.isEmpty else { return nil }
        let missing = session.selection.filter { !status.live.contains($0.statusName) }
        guard !missing.isEmpty else { return nil }
        return String(localized: "This device cannot use two cameras at once: while it records, only the recording camera can be shown.")
    }

    private struct StreamPane: View {
        @ObservedObject var stream: MotionLiveStream
        let retry: () -> Void

        var body: some View {
            ZStack {
                LiveVideo(stream: stream)
                switch stream.phase {
                case .connecting:
                    VStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Connecting…").font(.callout)
                    }
                    .foregroundStyle(.white)
                case .playing:
                    EmptyView()
                case let .failed(message):
                    VStack(spacing: 8) {
                        Text(message).font(.callout).multilineTextAlignment(.center)
                        Button("Try Again", action: retry)
                    }
                    .foregroundStyle(.white)
                    .padding()
                }
            }
            .overlay(alignment: .topLeading) {
                Text(stream.facing == .front ? String(localized: "Front") : String(localized: "Rear"))
                    .font(.caption.weight(.medium)).foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 4))
                    .padding(6)
            }
            .frame(minWidth: 240, maxWidth: .infinity, minHeight: 240, maxHeight: .infinity)
        }
    }
}
