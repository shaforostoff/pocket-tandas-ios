// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  RestorationAudioUnit.swift
//  Pocket Tandas
//
//  One in-process Audio Unit carrying both restoration filters in series —
//  Declick first, then Dehum — so the master bus gains a single insert rather
//  than two. Clicks are broadband impulses and would blow up the hum detector's
//  spectrum, so removing them first is the order that costs the tone detector
//  least; it is also the order the offline tools run them in.
//
//  There is no AVFoundation effect node for this, so the unit is an `AUAudioUnit`
//  subclass registered in-process and instantiated through `AVAudioUnitEffect` —
//  the same shape the system's own effects present to `AVAudioEngine`. The DSP
//  itself lives in DSP/PTRestorationDSP.{h,mm} over the two portable cores.
//
//  The render block is realtime code: everything it touches is allocated in
//  `allocateRenderResources()` and nothing in it can block. It renders IN PLACE,
//  pulling the upstream audio straight into the output buffer list, which is
//  what `canProcessInPlace` promises the host.
//

import Foundation
import AVFoundation

final class RestorationAudioUnit: AUAudioUnit {

    /// Ceiling on channels — matches `kMaxChannels` in PTRestorationDSP.mm. The
    /// master bus is stereo; this only bounds the render scratch.
    private static let maxChannels = 8

    /// The two filters, exposed so `RestorationFilters` can drive them.
    let declick = PTDeclickProcessor()
    let dehum = PTDehumProcessor()

    private var _inputBus: AUAudioUnitBus
    private var _outputBus: AUAudioUnitBus
    private var _inputBusArray: AUAudioUnitBusArray!
    private var _outputBusArray: AUAudioUnitBusArray!

    /// Render scratch. `scratch` backs any output buffer the host hands over with
    /// a null pointer; `pointers` is the argument vector the DSP takes, so the
    /// render block never has to build an array.
    ///
    /// Boxed rather than held in properties because a host may ask for
    /// `internalRenderBlock` before `allocateRenderResources()` and keep what it
    /// gets: the block captures the box, so it sees whatever the allocation later
    /// put in it.
    private final class RenderContext {
        var scratch: UnsafeMutablePointer<Float>?
        var pointers: UnsafeMutablePointer<UnsafeMutablePointer<Float>>?
        var stride = 0
    }
    private let context = RenderContext()

    override init(componentDescription: AudioComponentDescription,
                  options: AudioComponentInstantiationOptions = []) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        _inputBus = try AUAudioUnitBus(format: format)
        _outputBus = try AUAudioUnitBus(format: format)
        _inputBus.maximumChannelCount = UInt32(Self.maxChannels)
        _outputBus.maximumChannelCount = UInt32(Self.maxChannels)

        try super.init(componentDescription: componentDescription, options: options)

        _inputBusArray = AUAudioUnitBusArray(audioUnit: self, busType: .input, busses: [_inputBus])
        _outputBusArray = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [_outputBus])
        maximumFramesToRender = 4096
    }

    override var inputBusses: AUAudioUnitBusArray { _inputBusArray }
    override var outputBusses: AUAudioUnitBusArray { _outputBusArray }

    override var canProcessInPlace: Bool { true }

    /// What the declicker holds. Dehum is a zero-latency notch, so it adds none.
    /// The figure stands whether the filter is engaged or not — the unit keeps
    /// the same delay when bypassed, so switching it cannot move the audio.
    override var latency: TimeInterval {
        let rate = _outputBus.format.sampleRate
        guard rate > 0 else { return 0 }
        return Double(declick.latencyFrames) / rate
    }

    // MARK: - Render resources

    override func allocateRenderResources() throws {
        try super.allocateRenderResources()

        let format = _outputBus.format
        let channels = min(Int(format.channelCount), Self.maxChannels)
        let frames = Int(maximumFramesToRender)

        let scratch = UnsafeMutablePointer<Float>.allocate(capacity: Self.maxChannels * frames)
        scratch.initialize(repeating: 0, count: Self.maxChannels * frames)
        context.scratch = scratch
        context.pointers = .allocate(capacity: Self.maxChannels)
        context.stride = frames

        guard declick.prepare(sampleRate: format.sampleRate,
                              channelCount: channels, maxFrames: frames),
              dehum.prepare(sampleRate: format.sampleRate,
                            channelCount: channels, maxFrames: frames)
        else {
            deallocateRenderResources()
            throw NSError(domain: NSOSStatusErrorDomain,
                          code: Int(kAudioUnitErr_FailedInitialization))
        }
    }

    override func deallocateRenderResources() {
        declick.unprepare()
        dehum.unprepare()
        context.scratch?.deallocate()
        context.scratch = nil
        context.pointers?.deallocate()
        context.pointers = nil
        context.stride = 0
        super.deallocateRenderResources()
    }

    // MARK: - Render

    override var internalRenderBlock: AUInternalRenderBlock {
        // Captured by value so the block never reaches back through `self`.
        let declick = self.declick
        let dehum = self.dehum
        let context = self.context
        let maxChannels = Self.maxChannels

        return { _, timestamp, frameCount, _, outputData, _, pullInputBlock in
            guard let pullInputBlock,
                  let scratch = context.scratch,
                  let pointers = context.pointers else {
                return kAudioUnitErr_NoConnection
            }
            let stride = context.stride

            let buffers = UnsafeMutableAudioBufferListPointer(outputData)
            let channels = min(buffers.count, maxChannels)
            guard channels > 0, Int(frameCount) <= stride else {
                return kAudioUnitErr_TooManyFramesToProcess
            }

            // A host may hand over a buffer list with null pointers, meaning
            // "render into memory of your own". Point those at the scratch, then
            // pull the upstream audio straight into the list and work in place.
            let byteSize = UInt32(frameCount) * UInt32(MemoryLayout<Float>.size)
            for channel in 0..<channels {
                if buffers[channel].mData == nil {
                    buffers[channel].mData = UnsafeMutableRawPointer(scratch + channel * stride)
                }
                buffers[channel].mDataByteSize = byteSize
            }

            var pullFlags = AudioUnitRenderActionFlags(rawValue: 0)
            let status = pullInputBlock(&pullFlags, timestamp, frameCount, 0, outputData)
            guard status == noErr else { return status }

            for channel in 0..<channels {
                guard let data = buffers[channel].mData else { return kAudioUnitErr_InvalidParameter }
                pointers[channel] = data.assumingMemoryBound(to: Float.self)
            }

            declick.render(pointers, channelCount: channels, frameCount: Int(frameCount))
            dehum.render(pointers, channelCount: channels, frameCount: Int(frameCount))
            return noErr
        }
    }
}

// MARK: - In-process registration

/// Registers `RestorationAudioUnit` with the component system so
/// `AVAudioUnitEffect` can instantiate it like any system effect, and hands back
/// the node. In-process, so nothing is installed and no extension is involved.
enum RestorationAudioUnitFactory {
    static let componentDescription = AudioComponentDescription(
        componentType: kAudioUnitType_Effect,
        componentSubType: fourCharCode("ptrs"),
        componentManufacturer: fourCharCode("PkTd"),
        componentFlags: 0,
        componentFlagsMask: 0)

    private static var registered = false

    /// Builds the node, or nil if the component could not be instantiated — in
    /// which case the caller wires the graph up without it and the app plays on
    /// unrestored rather than not at all.
    static func makeNode() -> AVAudioUnitEffect? {
        if !registered {
            AUAudioUnit.registerSubclass(RestorationAudioUnit.self,
                                         as: componentDescription,
                                         name: "Pocket Tandas Restoration",
                                         version: 1)
            registered = true
        }
        // AVAudioUnitEffect raises rather than returning nil for a description
        // nothing answers to, and an Objective-C exception is not catchable from
        // Swift — so ask the component system first.
        var description = componentDescription
        guard AudioComponentFindNext(nil, &description) != nil else { return nil }
        let node = AVAudioUnitEffect(audioComponentDescription: componentDescription)
        return node.auAudioUnit is RestorationAudioUnit ? node : nil
    }

    private static func fourCharCode(_ string: StaticString) -> OSType {
        var code: OSType = 0
        let bytes = UnsafeBufferPointer(start: string.utf8Start, count: string.utf8CodeUnitCount)
        for byte in bytes.prefix(4) { code = (code << 8) | OSType(byte) }
        return code
    }
}
