import AudioToolbox
import CoreMedia
import Foundation

/// ReplayKit app-audio buffers → interleaved little-endian Int16 LPCM chunks
/// (WirelessAudioChunk). ReplayKit's `.audioApp` buffers are commonly 16-bit
/// BIG-endian interleaved; float and non-interleaved layouts are handled too.
nonisolated enum AppAudioPacker {
    struct Packed {
        var format: WirelessAudioFormat
        var chunk: WirelessAudioChunk
    }

    static func pack(_ sample: CMSampleBuffer) -> Packed? {
        guard let description = CMSampleBufferGetFormatDescription(sample),
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(description) else { return nil }
        let asbd = asbdPointer.pointee
        guard asbd.mFormatID == kAudioFormatLinearPCM else { return nil }
        let frames = CMSampleBufferGetNumSamples(sample)
        let channels = Int(asbd.mChannelsPerFrame)
        guard frames > 0, channels > 0, channels <= 8 else { return nil }

        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let isBigEndian = asbd.mFormatFlags & kAudioFormatFlagIsBigEndian != 0
        let nonInterleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let bits = Int(asbd.mBitsPerChannel)
        guard (isFloat && bits == 32) || (!isFloat && bits == 16) else { return nil }

        var blockBuffer: CMBlockBuffer?
        var listSize = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sample, bufferListSizeNeededOut: &listSize, bufferListOut: nil,
                                                                bufferListSize: 0, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
                                                                flags: 0, blockBufferOut: nil)
        let raw = UnsafeMutableRawPointer.allocate(byteCount: listSize, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sample, bufferListSizeNeededOut: nil, bufferListOut: list,
                                                                      bufferListSize: listSize, blockBufferAllocator: nil,
                                                                      blockBufferMemoryAllocator: nil,
                                                                      flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
                                                                      blockBufferOut: &blockBuffer) == noErr else { return nil }
        let buffers = UnsafeMutableAudioBufferListPointer(list)

        var out = [Int16](repeating: 0, count: frames * channels)
        func sampleAt(frame: Int, channel: Int) -> Int16 {
            let bufferIndex = nonInterleaved ? channel : 0
            guard bufferIndex < buffers.count, let data = buffers[bufferIndex].mData else { return 0 }
            let index = nonInterleaved ? frame : frame * channels + channel
            if isFloat {
                let value = data.assumingMemoryBound(to: Float32.self)[index]
                return Int16(max(-1, min(1, value)) * 32767)
            }
            let value = data.assumingMemoryBound(to: Int16.self)[index]
            return isBigEndian ? Int16(bigEndian: value) : Int16(littleEndian: value)
        }
        for frame in 0..<frames {
            for channel in 0..<channels {
                out[frame * channels + channel] = sampleAt(frame: frame, channel: channel).littleEndian
            }
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        let data = out.withUnsafeBytes { Data($0) }
        return Packed(
            format: WirelessAudioFormat(sampleRate: asbd.mSampleRate, channels: channels),
            chunk: WirelessAudioChunk(pts: StreamEncoder.nanos(pts), frameCount: UInt32(frames), samples: data)
        )
    }
}
