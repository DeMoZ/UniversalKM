import CoreMedia
import CoreVideo
import Foundation
import Network
import ScreenCaptureKit
import UniversalKMCore
import VideoToolbox

// The media half of the second display (openspec/changes/add-android-second-display, design D2, D3, D4):
// ScreenCaptureKit takes the virtual display, VideoToolbox encodes it, the link sends it. None of it touches the
// main actor: frames go from the capture queue through the encoder's callback to the socket.

/// The socket to the receiver, safe to use from any thread. Frames are dropped when the link falls behind: a
/// late picture is worse than a skipped one, and the encoder is asked for a key frame to start over.
final class DisplayLink: @unchecked Sendable {
    private let lock = NSLock()
    private var connection: NWConnection?
    private var pending = 0
    private var droppingUntilKey = false
    /// More frames than this waiting in the socket means the link is slower than the stream.
    static let maxPending = 6

    func attach(_ c: NWConnection?) {
        lock.lock(); defer { lock.unlock() }
        connection = c
    }

    func send(_ message: SecondDisplay.Message) {
        lock.lock()
        let c = connection
        lock.unlock()
        c?.send(content: SecondDisplay.encode(message), completion: .contentProcessed { _ in })
    }

    /// Returns false when the frame was dropped (the caller should ask for a key frame).
    @discardableResult
    func sendFrame(ptsUs: UInt64, key: Bool, data: Data) -> Bool {
        lock.lock()
        guard let c = connection else { lock.unlock(); return true }
        if pending >= Self.maxPending, !key { droppingUntilKey = true }
        if droppingUntilKey {
            if key, pending < Self.maxPending { droppingUntilKey = false } else {
                lock.unlock()
                return false
            }
        }
        pending += 1
        lock.unlock()
        c.send(content: SecondDisplay.encode(.frame(ptsUs: ptsUs, key: key, data: data)),
               completion: .contentProcessed { [weak self] _ in
                   guard let self else { return }
                   self.lock.lock(); self.pending -= 1; self.lock.unlock()
               })
        return true
    }
}

/// How long a frame took from the capture to the socket on the Mac (design D2, tasks 4.1): once a second the
/// average and the worst of the last second, and the frame rate. Capture and frame times share the host clock.
final class LatencyMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var sum = 0.0, worst = 0.0, count = 0
    private var since = CFAbsoluteTimeGetCurrent()
    private let report: (_ averageMs: Double, _ worstMs: Double, _ fps: Int) -> Void

    init(report: @escaping (Double, Double, Int) -> Void) {
        self.report = report
    }

    func record(ptsUs: UInt64) {
        let nowUs = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock())) * 1_000_000
        let ms = max(0, (nowUs - Double(ptsUs)) / 1000)
        lock.lock()
        sum += ms
        worst = max(worst, ms)
        count += 1
        let now = CFAbsoluteTimeGetCurrent()
        guard now - since >= 1 else { lock.unlock(); return }
        let line = (sum / Double(count), worst, count)
        sum = 0; worst = 0; count = 0; since = now
        lock.unlock()
        report(line.0, line.1, line.2)
    }
}

/// H.264 for the virtual display in low-latency mode (design D3): no B-frames, real time, a key frame on request
/// and every 120 frames. The parameter sets are reported (once per change) before the first key frame and put
/// in front of every key frame.
final class DisplayEncoder: @unchecked Sendable {
    struct Failure: Error { let message: String }

    let width: Int
    let height: Int
    private var session: VTCompressionSession?
    private let lock = NSLock()
    private var lastBuffer: CVPixelBuffer?
    private var lastEncode = CFAbsoluteTimeGetCurrent()
    private var lastSets = Data()
    private var wantKey = true
    private let onConfig: (Int, Int, Data) -> Void
    private let onFrame: (UInt64, Bool, Data) -> Void

    init(width: Int, height: Int, bitrate: Int, onConfig: @escaping (Int, Int, Data) -> Void,
         onFrame: @escaping (UInt64, Bool, Data) -> Void) throws {
        self.width = width
        self.height = height
        self.onConfig = onConfig
        self.onFrame = onFrame
        var created: VTCompressionSession?
        let lowLatency = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true] as CFDictionary
        var status = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height),
                                                codecType: kCMVideoCodecType_H264, encoderSpecification: lowLatency,
                                                imageBufferAttributes: nil, compressedDataAllocator: nil,
                                                outputCallback: nil, refcon: nil, compressionSessionOut: &created)
        if status != noErr || created == nil {
            status = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height),
                                                codecType: kCMVideoCodecType_H264, encoderSpecification: nil,
                                                imageBufferAttributes: nil, compressedDataAllocator: nil,
                                                outputCallback: nil, refcon: nil, compressionSessionOut: &created)
        }
        guard status == noErr, let s = created else { throw Failure(message: "VideoToolbox error \(status)") }
        func set(_ key: CFString, _ value: CFTypeRef) { _ = VTSessionSetProperty(s, key: key, value: value) }
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        set(kVTCompressionPropertyKey_AverageBitRate, bitrate as CFNumber)
        set(kVTCompressionPropertyKey_DataRateLimits, [bitrate / 8, 1] as CFArray)
        set(kVTCompressionPropertyKey_ExpectedFrameRate, 60 as CFNumber)
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, 120 as CFNumber)
        set(kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, kCFBooleanTrue)
        VTCompressionSessionPrepareToEncodeFrames(s)
        session = s
    }

    func forceKeyFrame() {
        lock.lock(); wantKey = true; lock.unlock()
    }

    func encode(_ buffer: CVPixelBuffer, pts: CMTime) {
        lock.lock()
        guard let s = session else { lock.unlock(); return }
        lastBuffer = buffer
        lastEncode = CFAbsoluteTimeGetCurrent()
        let key = wantKey
        wantKey = false
        lock.unlock()
        let props = key ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        VTCompressionSessionEncodeFrame(s, imageBuffer: buffer, presentationTimeStamp: pts, duration: .invalid,
                                        frameProperties: props, infoFlagsOut: nil) { [weak self] status, _, sample in
            self?.output(status, sample)
        }
    }

    /// The display is idle: send the last picture again so the decoder does not take the quiet for a lost link
    /// (design D2).
    func repeatIfIdle(after seconds: Double = 1) {
        lock.lock()
        let buffer = lastBuffer
        let idle = CFAbsoluteTimeGetCurrent() - lastEncode >= seconds
        lock.unlock()
        guard idle, let buffer else { return }
        encode(buffer, pts: CMClockGetTime(CMClockGetHostTimeClock()))
    }

    func invalidate() {
        lock.lock()
        let s = session
        session = nil
        lastBuffer = nil
        lock.unlock()
        if let s {
            VTCompressionSessionCompleteFrames(s, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(s)
        }
    }

    private func output(_ status: OSStatus, _ sample: CMSampleBuffer?) {
        guard status == noErr, let sample, CMSampleBufferDataIsReady(sample),
              let block = CMSampleBufferGetDataBuffer(sample) else { return }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let key = !((attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false)
        var out = Data()
        let startCode = Data([0, 0, 0, 1])
        if key, let format = CMSampleBufferGetFormatDescription(sample) {
            var sets = Data()
            var count = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                               parameterSetSizeOut: nil, parameterSetCountOut: &count,
                                                               nalUnitHeaderLengthOut: nil)
            for i in 0..<count {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: i,
                        parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: nil,
                        nalUnitHeaderLengthOut: nil) == noErr, let pointer else { continue }
                sets += startCode + Data(bytes: pointer, count: size)
            }
            lock.lock()
            let changed = sets != lastSets
            if changed { lastSets = sets }
            lock.unlock()
            if changed { onConfig(width, height, sets) }
            out += sets
        }
        var length = 0
        var base: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length,
                                          dataPointerOut: &base) == noErr, let base else { return }
        let bytes = UnsafeRawBufferPointer(start: base, count: length)
        var at = 0
        while at + 4 <= length {
            let n = Int(bytes[at]) << 24 | Int(bytes[at + 1]) << 16 | Int(bytes[at + 2]) << 8 | Int(bytes[at + 3])
            at += 4
            guard n > 0, at + n <= length else { break }
            out += startCode + Data(bytes[at..<at + n])
            at += n
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        let us = UInt64(max(0, CMTimeGetSeconds(pts) * 1_000_000))
        onFrame(us, key, out)
    }
}

/// ScreenCaptureKit on one display (design D2): 60 frames a second, cursor included, in the encoder's format.
final class DisplayCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    struct Failure: Error { let message: String }

    private let displayID: CGDirectDisplayID
    private let width: Int
    private let height: Int
    private let onFrame: (CVPixelBuffer, CMTime) -> Void
    private let onStop: (Error) -> Void
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "ukm.display.capture", qos: .userInteractive)

    init(displayID: CGDirectDisplayID, width: Int, height: Int, onFrame: @escaping (CVPixelBuffer, CMTime) -> Void,
         onStop: @escaping (Error) -> Void) {
        self.displayID = displayID
        self.width = width
        self.height = height
        self.onFrame = onFrame
        self.onStop = onStop
    }

    /// The new display needs a moment before ScreenCaptureKit lists it.
    func start() async throws {
        var found: SCDisplay?
        for _ in 0..<30 {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            found = content.displays.first { $0.displayID == displayID }
            if found != nil { break }
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        guard let display = found else { throw Failure(message: "ScreenCaptureKit does not see the new display") }
        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        configuration.showsCursor = true
        configuration.queueDepth = 3
        let s = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: configuration,
                         delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await s.startCapture()
        stream = s
    }

    func stop() async {
        let s = stream
        stream = nil
        try? await s?.stopCapture()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                  as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        onFrame(buffer, CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStop(error)
    }
}
