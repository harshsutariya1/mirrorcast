import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// Hardware H.264 / H.265 decoder built on VideoToolbox.
///
/// Flow for every stream:
/// 1. `reset(codec:)` when a VIDEO_FORMAT packet announces the codec.
/// 2. `handleConfig` with the parameter sets (SPS/PPS, +VPS for H.265): builds
///    a `CMVideoFormatDescription` and a decompression session.
/// 3. `decode` for every frame: Annex-B -> AVCC, wrap in a `CMSampleBuffer`,
///    decode. Output frames are BGRA, IOSurface-backed `CVPixelBuffer`s that
///    Flutter can draw directly from GPU memory (zero copy).
///
/// If anything goes wrong it drops frames until the next keyframe and asks the
/// phone for one via `onNeedKeyframe`, so a glitch never lasts long.
///
/// Not thread-safe: call from the receiver queue. `onFrame` is called on a
/// VideoToolbox thread.
final class VideoDecoder {
    enum Codec: String {
        case avc
        case hevc
    }

    var onFrame: ((CVPixelBuffer, Int64) -> Void)?
    var onNeedKeyframe: (() -> Void)?
    var onDimensionsChanged: ((Int, Int) -> Void)?

    private(set) var codec: Codec = .avc
    private(set) var decodeErrors = 0
    private var formatDescription: CMVideoFormatDescription?
    private var session: VTDecompressionSession?
    private var waitingForKeyframe = true
    private var dimensions: (width: Int, height: Int)?

    deinit { invalidateSession() }

    /// Forgets the current stream. The next config + keyframe starts a new one.
    func reset(codec: Codec) {
        invalidateSession()
        self.codec = codec
        formatDescription = nil
        dimensions = nil
        waitingForKeyframe = true
    }

    func handleConfig(_ data: Data) {
        let units = AnnexB.split(data).filter { NalKind.of($0, hevc: codec == .hevc) == .parameterSet }
        guard let description = makeFormatDescription(units) else {
            decodeErrors += 1
            onNeedKeyframe?()
            return
        }
        apply(description)
    }

    func decode(_ data: Data, ptsUs: Int64, isKeyframe: Bool) {
        let hevc = codec == .hevc
        var parameterSets: [ArraySlice<UInt8>] = []
        var frameUnits: [ArraySlice<UInt8>] = []
        var containsKeyframe = isKeyframe
        for unit in AnnexB.split(data) {
            switch NalKind.of(unit, hevc: hevc) {
            case .parameterSet: parameterSets.append(unit)
            case .keyframe:
                containsKeyframe = true
                frameUnits.append(unit)
            case .frame: frameUnits.append(unit)
            case .ignorable: break
            }
        }
        // Some encoders repeat parameter sets inside keyframes.
        if !parameterSets.isEmpty, let description = makeFormatDescription(parameterSets) {
            apply(description)
        }
        guard !frameUnits.isEmpty else { return }

        if waitingForKeyframe {
            guard containsKeyframe else { return } // a P-frame without its reference is garbage
            waitingForKeyframe = false
        }
        guard let session, let formatDescription else {
            requestRecovery()
            return
        }
        guard let sample = makeSampleBuffer(AnnexB.avcc(frameUnits), ptsUs: ptsUs, format: formatDescription) else {
            requestRecovery()
            return
        }

        var infoFlags = VTDecodeInfoFlags()
        let status = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sample,
            flags: [._1xRealTimePlayback],
            infoFlagsOut: &infoFlags
        ) { [weak self] status, flags, imageBuffer, presentationTime, _ in
            guard status == noErr, let imageBuffer, !flags.contains(.frameDropped) else { return }
            // Timescale is 1,000,000, so `value` is the phone's timestamp in microseconds.
            self?.onFrame?(imageBuffer, presentationTime.value)
        }

        switch status {
        case noErr:
            break
        case kVTInvalidSessionErr:
            // Happens after sleep/wake or a GPU change: rebuild and resync.
            invalidateSession()
            createSession()
            requestRecovery()
        default:
            NSLog("MirrorCast: decode failed (\(status))")
            requestRecovery()
        }
    }

    // MARK: - Private

    private func requestRecovery() {
        decodeErrors += 1
        waitingForKeyframe = true
        onNeedKeyframe?()
    }

    private func apply(_ description: CMVideoFormatDescription) {
        if let current = formatDescription, CMFormatDescriptionEqual(current, otherFormatDescription: description), session != nil {
            return
        }
        formatDescription = description
        if let session, VTDecompressionSessionCanAcceptFormatDescription(session, formatDescription: description) {
            // Same decoder can continue with the new parameters.
        } else {
            invalidateSession()
            createSession()
            waitingForKeyframe = true
        }

        let size = CMVideoFormatDescriptionGetPresentationDimensions(
            description, usePixelAspectRatio: true, useCleanAperture: true
        )
        let next = (width: Int(size.width.rounded()), height: Int(size.height.rounded()))
        if dimensions == nil || dimensions! != next {
            dimensions = next
            onDimensionsChanged?(next.width, next.height)
        }
    }

    private func createSession() {
        guard let formatDescription else { return }
        let decoderSpecification: [String: Any] = [
            kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder as String: true,
        ]
        // BGRA + IOSurface + Metal compatibility is what lets Flutter's macOS
        // engine render the decoded frame without copying it.
        let imageBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ]
        var created: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDescription,
            decoderSpecification: decoderSpecification as CFDictionary,
            imageBufferAttributes: imageBufferAttributes as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &created
        )
        guard status == noErr, let created else {
            NSLog("MirrorCast: VTDecompressionSessionCreate failed (\(status))")
            decodeErrors += 1
            return
        }
        VTSessionSetProperty(created, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        session = created
    }

    private func invalidateSession() {
        if let session {
            VTDecompressionSessionInvalidate(session)
        }
        session = nil
    }

    private func makeFormatDescription(_ units: [ArraySlice<UInt8>]) -> CMVideoFormatDescription? {
        let hevc = codec == .hevc
        func first(_ type: Int) -> [UInt8]? {
            units.first { NalKind.parameterSetType($0, hevc: hevc) == type }.map { [UInt8]($0) }
        }

        let sets: [[UInt8]]
        if hevc {
            guard let vps = first(32), let sps = first(33), let pps = first(34) else { return nil }
            sets = [vps, sps, pps]
        } else {
            guard let sps = first(7), let pps = first(8) else { return nil }
            sets = [sps, pps]
        }

        var description: CMFormatDescription?
        let status: OSStatus = withParameterSets(sets) { pointers, sizes, count in
            if hevc {
                return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: count,
                    parameterSetPointers: pointers,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    extensions: nil,
                    formatDescriptionOut: &description
                )
            }
            return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault,
                parameterSetCount: count,
                parameterSetPointers: pointers,
                parameterSetSizes: sizes,
                nalUnitHeaderLength: 4,
                formatDescriptionOut: &description
            )
        }
        guard status == noErr else {
            NSLog("MirrorCast: invalid parameter sets (\(status))")
            return nil
        }
        return description
    }

    /// Gives CoreMedia stable C pointers to each parameter set for the duration of `body`.
    private func withParameterSets<R>(
        _ sets: [[UInt8]],
        _ body: (UnsafePointer<UnsafePointer<UInt8>>, UnsafePointer<Int>, Int) -> R
    ) -> R {
        let buffers: [UnsafeMutablePointer<UInt8>] = sets.map { set in
            let pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: max(set.count, 1))
            pointer.initialize(from: set, count: set.count)
            return pointer
        }
        defer { buffers.forEach { $0.deallocate() } }
        let pointers = buffers.map { UnsafePointer($0) }
        let sizes = sets.map(\.count)
        return pointers.withUnsafeBufferPointer { pointerBuffer in
            sizes.withUnsafeBufferPointer { sizeBuffer in
                body(pointerBuffer.baseAddress!, sizeBuffer.baseAddress!, sets.count)
            }
        }
    }

    private func makeSampleBuffer(_ avcc: [UInt8], ptsUs: Int64, format: CMVideoFormatDescription) -> CMSampleBuffer? {
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: avcc.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: avcc.count,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &blockBuffer
        )
        guard status == kCMBlockBufferNoErr, let blockBuffer else { return nil }
        status = avcc.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(
                with: raw.baseAddress!, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: avcc.count
            )
        }
        guard status == kCMBlockBufferNoErr else { return nil }

        var sampleBuffer: CMSampleBuffer?
        var sampleSize = avcc.count
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: ptsUs, timescale: 1_000_000),
            decodeTimeStamp: .invalid
        )
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        return status == noErr ? sampleBuffer : nil
    }
}
