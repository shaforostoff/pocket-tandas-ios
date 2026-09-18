// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  PTBPMAnalyzer.mm
//  Pocket Tandas
//
//  Glue over `bpmcore::collector`. See PTBPMAnalyzer.h.
//

#import "PTBPMAnalyzer.h"

#include <memory>

#include <bpmcore/bpmcore.h>

#pragma mark - Measurement

@interface PTBPMMeasurement ()
- (instancetype)initWithAnalysis:(const bpmcore::analysis &)a;
@end

@implementation PTBPMMeasurement

- (instancetype)initWithAnalysis:(const bpmcore::analysis &)a {
    if ((self = [super init])) {
        _measured   = a.ok ? YES : NO;
        _bpm        = a.bpm;
        _rhythm     = (PTRhythmClass)a.rhythm;
        _confidence = a.confidence;
        _beatBPM    = a.beat_bpm;
        _meter      = a.meter;
        _duration   = a.duration;
        _bpmSpread  = a.bpm_spread;
        _initialBPM = a.initial_bpm;
    }
    return self;
}

@end

#pragma mark - Cancellation

namespace {

/// Hands the core's abort hook to the caller's block. Nothing else is reported
/// back — the app shows no per-track progress, so the listener's other hook is
/// left at its default.
class block_listener final : public bpmcore::listener {
public:
    explicit block_listener(PTBPMCancellationCheck check) : m_check(check) {}
    bool cancelled() override { return m_check != nil && m_check(); }

private:
    __unsafe_unretained PTBPMCancellationCheck m_check;
};

}   // namespace

#pragma mark - Analyzer

@implementation PTBPMAnalyzer {
    std::unique_ptr<bpmcore::collector> _collector;
    unsigned _channels;
}

+ (NSTimeInterval)maximumDuration {
    return bpmcore::max_seconds();
}

- (instancetype)initWithSampleRate:(double)sampleRate
                          channels:(NSUInteger)channels
                   expectedSeconds:(NSTimeInterval)expectedSeconds {
    if ((self = [super init])) {
        _channels = channels > 0 ? (unsigned)channels : 1;
        _collector.reset(new bpmcore::collector(sampleRate > 0 ? (unsigned)sampleRate : 0,
                                                expectedSeconds));
    }
    return self;
}

- (BOOL)isFull {
    return _collector->full() ? YES : NO;
}

- (void)addInterleavedFloats:(const float *)samples frameCount:(NSUInteger)frameCount {
    if (samples == nullptr || frameCount == 0) return;
    _collector->add_interleaved(samples, (std::size_t)frameCount, _channels);
}

- (nullable PTBPMMeasurement *)finishUnlessCancelled:(nullable PTBPMCancellationCheck)isCancelled {
    block_listener listener(isCancelled);
    if (listener.cancelled()) return nil;

    // One thread, always. Whole tracks already run side by side — see
    // TrackAnalysisQueue — and the core's own note is that asking for one thread
    // and asking for eight produce the identical answer, so this costs nothing
    // but the scheduler noise it avoids.
    bpmcore::options options;
    options.threads = 1;

    const bpmcore::analysis result = _collector->finish(&listener, &options);
    if (listener.cancelled()) return nil;
    return [[PTBPMMeasurement alloc] initWithAnalysis:result];
}

@end
