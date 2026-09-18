// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  PTBPMAnalyzer.h
//  Pocket Tandas
//
//  Objective-C face of `bpmcore` — the tempo and rhythm analysis carried over
//  verbatim from foo_rubato (see Analysis/PROVENANCE.md). Nothing algorithmic
//  lives here: this file is host glue only, so the vendored sources stay
//  byte-identical to upstream and what its documentation measured keeps
//  describing this port too.
//
//  Audio goes in as it is decoded and one measurement comes out at the end. The
//  onset envelope has to be normalised by the track's overall level before it is
//  compressed, and that isn't knowable until the whole side has been seen, so the
//  core buffers rather than streams — one mono float per sample at the analysis
//  rate, capped at `maximumDuration`. That rate is the decoder's own wherever it
//  already suits the model, so what a side costs depends on what it is decoded
//  at: 15 MB for three minutes at 22.05 kHz, twice that at 44.1.
//
//  Not thread-safe: one analyzer belongs to the one thread decoding its track.
//
//  Exposed to Swift through the target's bridging header.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Polled by the core between stages, on the thread that called
/// `finishUnlessCancelled:`. Return YES to abandon the analysis.
typedef BOOL (^PTBPMCancellationCheck)(void);

/// The four rhythms the classifier knows, plus everything else. Deliberately the
/// core's own set: mapping it onto what the app is willing to call a genre is
/// `AnalyzedRhythm`'s job, not this layer's.
typedef NS_ENUM(NSInteger, PTRhythmClass) {
    PTRhythmClassTango = 0,
    PTRhythmClassVals,
    PTRhythmClassMilonga,
    PTRhythmClassReggae,
    PTRhythmClassOther,
};

/// One track's measurement. `measured` is NO when the track was too short or too
/// quiet to find a beat in, in which case every figure below is meaningless.
@interface PTBPMMeasurement : NSObject

@property (nonatomic, readonly) BOOL measured;
/// Tempo on the metrical level a dancer taps — the beat for a tango, the bar for
/// a vals or a milonga.
@property (nonatomic, readonly) double bpm;
@property (nonatomic, readonly) PTRhythmClass rhythm;
/// Classifier probability for `rhythm`, 0…1.
@property (nonatomic, readonly) double confidence;
/// The underlying beat, before the tapped level was chosen.
@property (nonatomic, readonly) double beatBPM;
/// Beats per bar the grid settled on.
@property (nonatomic, readonly) NSInteger meter;
/// Seconds of audio analysed.
@property (nonatomic, readonly) double duration;
/// How far the tempo moves over the track, in BPM at `bpm`'s level; 0 when the
/// track was too short to say. A steady digital transfer reads near zero, a
/// shellac side with a wandering turntable does not.
@property (nonatomic, readonly) double bpmSpread;
/// The tempo the opening runs at, at `bpm`'s level; 0 where there was no beat to
/// measure there. A tango often opens faster than it settles.
@property (nonatomic, readonly) double initialBPM;

@end

@interface PTBPMAnalyzer : NSObject

/// Longest stretch of audio the core looks at. Only bounds memory on a
/// mis-tagged long file — a tango side is two to three minutes.
@property (class, nonatomic, readonly) NSTimeInterval maximumDuration;

/// `sampleRate` and `channels` are the decoder's, not the analysis's: the core
/// downmixes and resamples on the way in, so a 48 kHz stereo file costs no more
/// to collect than a 44.1 kHz mono one.
///
/// `expectedSeconds` is how long the track is, where the caller knows before it
/// starts decoding, and 0 where it does not. It sizes the buffer and nothing
/// else: told nothing, or told wrong, the analyzer holds the same audio and
/// still stops at `maximumDuration`. Telling it is what stops a side longer than
/// the default reserve from outgrowing the buffer and doubling it — the copy has
/// both the old and the new allocation resident at once.
- (instancetype)initWithSampleRate:(double)sampleRate
                          channels:(NSUInteger)channels
                   expectedSeconds:(NSTimeInterval)expectedSeconds NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// YES once `maximumDuration` has been reached; the caller can stop decoding.
@property (nonatomic, readonly, getter=isFull) BOOL full;

/// Interleaved 32-bit float, `channels` samples per frame.
- (void)addInterleavedFloats:(const float *)samples frameCount:(NSUInteger)frameCount;

/// Analyse everything added so far, polling `isCancelled` between the core's
/// stages. Returns nil only when that said to stop — a track the core simply
/// could not measure comes back as a measurement with `measured == NO`, which is
/// a different answer and worth recording.
- (nullable PTBPMMeasurement *)finishUnlessCancelled:(nullable PTBPMCancellationCheck)isCancelled;

@end

NS_ASSUME_NONNULL_END
