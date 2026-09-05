// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  PTRestorationDSP.h
//  Pocket Tandas
//
//  Objective-C face of the two restoration DSP cores in this folder —
//  `declick_core` and `dehum_core`, both verbatim copies of the MIT-licensed
//  cores from the airwindows-foobar2000 tree (foo_dsp_declick / foo_dsp_dehum,
//  also ported to VirtualDJ and to an Audio Unit). Nothing algorithmic lives
//  here: this file is only the host glue, so the cores stay byte-identical to
//  upstream and the measurements in their READMEs keep describing this port too.
//
//  Everything below is realtime-safe on the render side: after `prepare…` no
//  call the audio thread makes allocates, and every hand-off from the UI or the
//  scout goes through an `os_unfair_lock_trylock` that the render thread is
//  free to walk away from.
//
//  Exposed to Swift through the target's bridging header.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - Parameters

/// Declick's user-facing controls, in core units (not slider positions).
/// See declick_core.h for what each one costs and buys.
typedef struct {
    float   sensitivity;    ///< 0…1 — 0 only the most obvious clicks, 1 aggressive
    float   extent;         ///< 0…1 — how far a detection spreads into its tail
    float   maxLengthMs;    ///< 0.2…20 ms — longest single repair
    float   depth;          ///< 0…1 — 0 adds least error, 1 replaces outright
    int32_t passes;         ///< 1…3
    int32_t order;          ///< 8…256, even — AR model order
    float   dryWet;         ///< 0…1
} PTDeclickParams;

/// Dehum's user-facing controls, in core units. See dehum_core.h.
typedef struct {
    float   sensitivity;    ///< 0…1 — maps onto the prominence threshold
    float   bandwidth;      ///< notch 3 dB half width, Hz
    float   searchTo;       ///< top of the automatic search range, Hz
    int32_t harmonics;      ///< 1…8 multiples of each line cancelled
    float   frequency;      ///< 0 = detect automatically, else pin here (Hz)
    float   rumbleHz;       ///< 0 = off, else high-pass corner (Hz)
    float   dryWet;         ///< 0…1
} PTDehumParams;

/// The calibrated defaults the cores ship with.
FOUNDATION_EXPORT PTDeclickParams PTDeclickParamsDefault(void);
FOUNDATION_EXPORT PTDehumParams PTDehumParamsDefault(void);

/// One narrowband line the dehum detector currently believes in — the scout's
/// output, the live unit's input, and what the parameters overlay shows.
typedef struct {
    double  frequency;      ///< Hz, as tracked
    double  detected;       ///< Hz, where the detector first put it
    double  prominence;     ///< dB above the local baseline
    double  amplitude;      ///< the tone amplitude being subtracted
    double  coherence;      ///< |w_narrow| / |w_wide|
    int32_t viaCoherence;   ///< non-zero when found by coherence, not prominence
    int32_t harmonics;      ///< multiples engaged
} PTDehumLine;

/// Slots in a `PTDehumLine` array — dehum::kMaxLines.
FOUNDATION_EXPORT const NSInteger PTDehumMaxLines;

#pragma mark - Declick

/// A multi-channel declicker, driven push/pull by the render thread.
///
/// The core holds `latencyFrames` samples, and this wrapper holds the same
/// delay when it is bypassed — through a plain ring, at no CPU cost — so
/// switching the filter on or off mid-track does not move the audio and
/// therefore cannot click. Enabling warms the core from that ring rather than
/// from silence, so its noise estimate is already settled when the first
/// repaired sample comes out.
@interface PTDeclickProcessor : NSObject

/// Pass-through (with the delay preserved). Settable from any thread.
@property (nonatomic) BOOL bypassed;

/// Frames of delay the unit imposes, bypassed or not. Changes only when
/// `maxLengthMs` or `order` does.
@property (nonatomic, readonly) NSInteger latencyFrames;

/// Allocates. Call from the render-resource setup, never from the audio thread.
/// Returns NO if the buffers could not be had, in which case the unit passes
/// audio through untouched.
- (BOOL)prepareWithSampleRate:(double)sampleRate
                 channelCount:(NSInteger)channelCount
                    maxFrames:(NSInteger)maxFrames
    NS_SWIFT_NAME(prepare(sampleRate:channelCount:maxFrames:));

/// Drops every buffer. Pairs with `deallocateRenderResources`.
- (void)unprepare;

/// From any thread. Applied at the top of the next render call.
- (void)setParams:(PTDeclickParams)params;

/// Realtime. `data` is `channelCount` pointers to `frameCount` floats,
/// deinterleaved, processed in place.
- (void)renderInPlace:(float * const _Nonnull * _Nonnull)data
         channelCount:(NSInteger)channelCount
           frameCount:(NSInteger)frameCount
    NS_SWIFT_NAME(render(_:channelCount:frameCount:));

/// Diagnostics: samples repaired / samples seen, summed over the channels.
@property (nonatomic, readonly) uint64_t repairedSamples;
@property (nonatomic, readonly) uint64_t seenSamples;

@end

#pragma mark - Dehum

/// A multi-channel hum and rumble remover. Zero latency, so bypassing it is a
/// no-op rather than something that has to be compensated for.
@interface PTDehumProcessor : NSObject

/// Pass-through. While bypassed the detector is not fed either, so nothing is
/// spent on an FFT the user has switched off. Settable from any thread.
@property (nonatomic) BOOL bypassed;

- (BOOL)prepareWithSampleRate:(double)sampleRate
                 channelCount:(NSInteger)channelCount
                    maxFrames:(NSInteger)maxFrames
    NS_SWIFT_NAME(prepare(sampleRate:channelCount:maxFrames:));

- (void)unprepare;

/// From any thread. Applied at the top of the next render call.
- (void)setParams:(PTDehumParams)params;

/// A new record: forget every line, since each one carries its own hum.
/// Deferred to the next render call, so it is safe from the main thread.
- (void)resetLines;

/// Start from lines somebody else has already found — see PTDehumScout. The
/// detector keeps running afterwards, so it still tracks them, still drops them
/// if the evidence is not really there, and can still find others. Safe from
/// any thread; applied at the top of the next render call.
- (void)adoptLines:(const PTDehumLine *)lines count:(NSInteger)count;

/// Realtime, in place.
- (void)renderInPlace:(float * const _Nonnull * _Nonnull)data
         channelCount:(NSInteger)channelCount
           frameCount:(NSInteger)frameCount
    NS_SWIFT_NAME(render(_:channelCount:frameCount:));

/// What channel 0's detector currently holds, for the parameters overlay.
/// Takes the same lock the render thread only ever tries, so call it from the
/// UI and not from audio. Returns how many lines were written.
- (NSInteger)copyLines:(PTDehumLine *)out max:(NSInteger)max;

@end

#pragma mark - Scout

/// A throwaway dehum detector run over a whole track off the audio path.
///
/// The live detector will not commit to a line until it has several seconds of
/// steady evidence — about 9 s for a line the prominence route can see, and
/// some 43 s for one only the coherence route can reach, because that ratio
/// accumulates over dehum::kCohWindowSec. All of it is time the record plays
/// with the hum still in it, and a file player does not have to spend it: the
/// track is on disk, so it can be decoded ahead of the play head and what this
/// finds handed to `-[PTDehumProcessor adoptLines:count:]`.
///
/// Deliberately per track — one scout per record, feed it, read it once.
/// Not thread-safe; belongs to whichever background queue is decoding.
@interface PTDehumScout : NSObject

/// `sampleRate` is the rate of the audio that will be fed, which need not be
/// the rate the live unit runs at: a line sits at the same frequency in Hz
/// whichever rate you look at it from.
- (instancetype)initWithSampleRate:(double)sampleRate
                            params:(PTDehumParams)params NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// One slice of mono audio. Hum is common mode, so a downmix finds it for a
/// fraction of the work of running every channel through its own detector.
- (void)feedMono:(const float *)mono frames:(NSInteger)frames;

/// Lines confirmed so far. Non-zero is the early-exit signal: once the scout
/// has something and has read enough of the record to trust it, there is
/// nothing to be gained by reading the rest.
@property (nonatomic, readonly) NSInteger lineCount;

/// Writes what the detector holds. Returns how many were written.
- (NSInteger)report:(PTDehumLine *)out max:(NSInteger)max;

@end

NS_ASSUME_NONNULL_END
