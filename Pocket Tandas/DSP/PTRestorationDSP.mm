// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  PTRestorationDSP.mm
//  Pocket Tandas
//
//  Host glue for declick_core / dehum_core. See PTRestorationDSP.h.
//

#import "PTRestorationDSP.h"

#import <os/lock.h>

#include <algorithm>
#include <atomic>
#include <new>
#include <vector>

#include "declick_core.h"
#include "dehum_core.h"

const NSInteger PTDehumMaxLines = (NSInteger)dehum::kMaxLines;

#pragma mark - Parameter conversion

PTDeclickParams PTDeclickParamsDefault(void) {
    const declick::Params d = declick::Params::defaults();
    PTDeclickParams p;
    p.sensitivity = d.sensitivity;
    p.extent      = d.extent;
    p.maxLengthMs = d.maxLengthMs;
    p.depth       = d.depth;
    p.passes      = (int32_t)d.passes;
    p.order       = (int32_t)d.order;
    p.dryWet      = d.dryWet;
    return p;
}

PTDehumParams PTDehumParamsDefault(void) {
    const dehum::Params d = dehum::Params::defaults();
    PTDehumParams p;
    p.sensitivity = d.sensitivity;
    p.bandwidth   = d.bandwidth;
    p.searchTo    = d.searchTo;
    p.harmonics   = (int32_t)d.harmonics;
    p.frequency   = d.frequency;
    p.rumbleHz    = d.rumbleHz;
    p.dryWet      = d.dryWet;
    return p;
}

namespace {

declick::Params toCore(const PTDeclickParams & p) {
    declick::Params c = declick::Params::defaults();
    c.sensitivity = p.sensitivity;
    c.extent      = p.extent;
    c.maxLengthMs = p.maxLengthMs;
    c.depth       = p.depth;
    c.passes      = (int)p.passes;
    c.order       = (int)p.order;
    c.dryWet      = p.dryWet;
    c.sanitize();
    return c;
}

dehum::Params toCore(const PTDehumParams & p) {
    dehum::Params c = dehum::Params::defaults();
    c.sensitivity = p.sensitivity;
    c.bandwidth   = p.bandwidth;
    c.searchTo    = p.searchTo;
    c.harmonics   = (int)p.harmonics;
    c.frequency   = p.frequency;
    c.rumbleHz    = p.rumbleHz;
    c.dryWet      = p.dryWet;
    c.sanitize();
    return c;
}

PTDehumLine toWire(const dehum::LineReport & r) {
    PTDehumLine l;
    l.frequency    = r.frequency;
    l.detected     = r.detected;
    l.prominence   = r.prominence;
    l.amplitude    = r.amplitude;
    l.coherence    = r.coherence;
    l.viaCoherence = r.viaCoherence ? 1 : 0;
    l.harmonics    = (int32_t)r.harmonics;
    return l;
}

dehum::LineReport fromWire(const PTDehumLine & l) {
    dehum::LineReport r;
    r.frequency    = l.frequency;
    r.detected     = l.detected;
    r.prominence   = l.prominence;
    r.amplitude    = l.amplitude;
    r.coherence    = l.coherence;
    r.viaCoherence = l.viaCoherence != 0;
    r.harmonics    = (int)l.harmonics;
    return r;
}

//! Ceiling on channels either unit will carry. The master bus is stereo; this
//! is only so a surround route cannot walk off the end of a vector.
const int kMaxChannels = 8;

} // anonymous namespace

#pragma mark - Declick

namespace {

//! Everything the declicker owns. In a struct rather than in ivars because the
//! render path touches it through one pointer and never through objc_msgSend.
struct DeclickImpl {
    std::vector<declick::Channel> chan;

    //! History of the input, one ring per channel, holding the last
    //! `ringFrames` samples. Two jobs: it IS the bypass path's delay line, and
    //! it is what a newly engaged core is warmed from - see the class comment.
    std::vector<std::vector<float>> ring;
    int      ringFrames = 0;
    uint64_t written    = 0;      //!< absolute count of frames written to the ring

    std::vector<float> dump;      //!< warm-up output, discarded

    declick::Config cfg;
    declick::Params active = declick::Params::defaults();
    double rate      = 0.0;
    int    channels  = 0;
    int    maxFrames = 0;
    bool   ready     = false;

    //! Audio thread only: whether the cores are currently being fed.
    bool engaged = false;

    std::atomic<bool> bypass { true };
    std::atomic<uint64_t> repaired { 0 };
    std::atomic<uint64_t> seen { 0 };
    //! Published for -latencyFrames, which the AU reads from the main thread.
    std::atomic<int> latency { 0 };

    os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
    declick::Params pending = declick::Params::defaults();
    bool pendingDirty = false;
};

} // anonymous namespace

@implementation PTDeclickProcessor {
    DeclickImpl _im;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _im.pending = declick::Params::defaults();
        _im.active  = _im.pending;
    }
    return self;
}

- (BOOL)bypassed { return _im.bypass.load(std::memory_order_relaxed); }
- (void)setBypassed:(BOOL)b { _im.bypass.store(b ? true : false, std::memory_order_relaxed); }

- (NSInteger)latencyFrames { return (NSInteger)_im.latency.load(std::memory_order_relaxed); }
- (uint64_t)repairedSamples { return _im.repaired.load(std::memory_order_relaxed); }
- (uint64_t)seenSamples { return _im.seen.load(std::memory_order_relaxed); }

- (void)setParams:(PTDeclickParams)params {
    const declick::Params p = toCore(params);
    os_unfair_lock_lock(&_im.lock);
    _im.pending = p;
    _im.pendingDirty = true;
    os_unfair_lock_unlock(&_im.lock);
}

- (BOOL)prepareWithSampleRate:(double)sampleRate
                 channelCount:(NSInteger)channelCount
                    maxFrames:(NSInteger)maxFrames {
    [self unprepare];

    const int nch = (int)std::min<NSInteger>(std::max<NSInteger>(channelCount, 1), kMaxChannels);
    const int mf  = (int)std::max<NSInteger>(maxFrames, 1);

    os_unfair_lock_lock(&_im.lock);
    const declick::Params p = _im.pending;
    _im.pendingDirty = false;
    os_unfair_lock_unlock(&_im.lock);

    // Everything the core allocates is sized from the sample rate alone, so the
    // worst case any later parameter move can reach is known here and the ring
    // never has to grow again. See the buffer envelope note in declick::Config.
    declick::Config probe;
    probe.compute(declick::Params::defaults(), sampleRate);
    const int latencyMax = probe.bufPad + (int)declick::kBlock;
    const int warmMax    = probe.madWindow;
    const int historyMax = latencyMax + warmMax;

    declick::Config cfg;
    // The out ring has to swallow the whole warm-up push in one go, so it is
    // sized from that rather than from the render block alone.
    cfg.maxBlock = std::max(mf, historyMax);
    cfg.compute(p, sampleRate);

    try {
        _im.chan.resize((size_t)nch);
        for (int c = 0; c < nch; ++c) _im.chan[(size_t)c].configure(cfg);

        _im.ringFrames = historyMax + mf + 1;
        _im.ring.assign((size_t)nch, std::vector<float>((size_t)_im.ringFrames, 0.0f));
        _im.dump.assign((size_t)(warmMax + (int)declick::kBlock), 0.0f);
    } catch (const std::bad_alloc &) {
        [self unprepare];
        return NO;
    }

    _im.cfg       = cfg;
    _im.active    = p;
    _im.rate      = sampleRate;
    _im.channels  = nch;
    _im.maxFrames = mf;
    _im.written   = 0;
    _im.engaged   = false;
    _im.ready     = true;
    _im.latency.store(cfg.latency, std::memory_order_relaxed);
    return YES;
}

- (void)unprepare {
    _im.ready = false;
    _im.engaged = false;
    _im.chan.clear();
    _im.ring.clear();
    _im.dump.clear();
    _im.ringFrames = 0;
    _im.written = 0;
}

/// Feed one core `historyMax` frames of the audio that has just gone past, so
/// the robust noise estimate its thresholds are relative to is settled before
/// the first sample anyone hears comes out. The `warm` frames it produces are
/// audio the bypass path has already delivered, so they go in the bin; what is
/// left in the pipeline is exactly the cushion push/pull needs to stay fed.
static void warmChannel(DeclickImpl & im, int c) {
    declick::Channel & ch = im.chan[(size_t)c];
    const std::vector<float> & ring = im.ring[(size_t)c];
    const int history = im.cfg.latency + im.cfg.madWindow;

    ch.reset();
    // Absolute [written - history, written), which is still intact: the ring is
    // longer than history plus one render block. It wraps at most once, so it
    // goes in as one or two contiguous runs rather than a sample at a time.
    //
    // Exactly `history` samples, always - the count is what buys the push/pull
    // invariant below, not their content. Early in a stream the front of the
    // window is before the audio started; the ring is zeroed and longer than
    // anything written so far, so those reads land on untouched slots and the
    // core is primed with silence, which is what a cold start is anyway.
    const int64_t start = (int64_t)im.written - (int64_t)history;
    const int64_t wrapped = ((start % im.ringFrames) + im.ringFrames) % im.ringFrames;
    const int head = (int)wrapped;
    const int first = std::min(history, im.ringFrames - head);
    ch.push(ring.data() + head, (size_t)first, 1);
    if (first < history) ch.push(ring.data(), (size_t)(history - first), 1);
    const size_t warm = (size_t)im.cfg.madWindow;
    const size_t got  = std::min(warm, ch.available());
    if (got > 0) ch.pull(im.dump.data(), got, 1);
    // Whatever is left in the out ring is the cushion push/pull runs on.
}

- (void)renderInPlace:(float * const *)data
         channelCount:(NSInteger)channelCount
           frameCount:(NSInteger)frameCount {
    DeclickImpl & im = _im;
    if (!im.ready) return;

    const int n   = (int)frameCount;
    const int nch = (int)std::min<NSInteger>(channelCount, im.channels);
    if (n <= 0 || nch <= 0 || n > im.maxFrames) return;

    declick::scoped_flush_denormals ftz;

    // Pick up a parameter move without ever waiting for the UI to let go.
    bool restructured = false;
    if (os_unfair_lock_trylock(&im.lock)) {
        if (im.pendingDirty) {
            const declick::Params p = im.pending;
            im.pendingDirty = false;
            os_unfair_lock_unlock(&im.lock);

            if (p != im.active) {
                declick::Config next;
                next.maxBlock = im.cfg.maxBlock;
                next.compute(p, im.rate);
                bool retuned = next.structurallyEquals(im.cfg);
                for (int c = 0; c < im.channels && retuned; ++c) {
                    retuned = im.chan[(size_t)c].retune(next);
                }
                if (!retuned) {
                    // Max repair or Model order: the pipeline is a different
                    // length, so it has to be rebuilt and re-warmed.
                    for (int c = 0; c < im.channels; ++c) im.chan[(size_t)c].configure(next);
                    restructured = true;
                }
                im.cfg    = next;
                im.active = p;
                im.latency.store(next.latency, std::memory_order_relaxed);
            }
        } else {
            os_unfair_lock_unlock(&im.lock);
        }
    }

    const bool wanted = !im.bypass.load(std::memory_order_relaxed);
    const bool warm   = wanted && (!im.engaged || restructured);
    const int  ring   = im.ringFrames;
    const uint64_t base = im.written;

    for (int c = 0; c < nch; ++c) {
        float * const io = data[c];
        std::vector<float> & hist = im.ring[(size_t)c];

        if (warm) warmChannel(im, c);

        // The new block joins the history before anything reads back from it,
        // so the bypass path can serve a delay shorter than one block.
        for (int i = 0; i < n; ++i) {
            hist[(size_t)((base + (uint64_t)i) % (uint64_t)ring)] = io[i];
        }

        if (wanted) {
            declick::Channel & ch = im.chan[(size_t)c];
            ch.push(io, (size_t)n, 1);
            const size_t got = std::min((size_t)n, ch.available());
            if (got > 0) ch.pull(io, got, 1);
            // Cannot happen once warmed - available() >= n is the core's
            // contract after a prime - but a short pull would leave stale audio
            // in the tail, so fill it from the dry delay instead.
            for (int i = (int)got; i < n; ++i) {
                const uint64_t at = base + (uint64_t)i - (uint64_t)im.cfg.latency;
                io[i] = (base + (uint64_t)i >= (uint64_t)im.cfg.latency)
                      ? hist[(size_t)(at % (uint64_t)ring)] : 0.0f;
            }
        } else {
            // Bypassed, but still delayed by exactly what the core would hold,
            // so switching the filter on or off does not move the audio.
            for (int i = 0; i < n; ++i) {
                const uint64_t idx = base + (uint64_t)i;
                io[i] = (idx >= (uint64_t)im.cfg.latency)
                      ? hist[(size_t)((idx - (uint64_t)im.cfg.latency) % (uint64_t)ring)]
                      : 0.0f;
            }
        }
    }

    im.written += (uint64_t)n;
    im.engaged = wanted;

    if (wanted && !im.chan.empty()) {
        im.repaired.store(im.chan[0].repairedSamples(), std::memory_order_relaxed);
        im.seen.store(im.chan[0].seenSamples(), std::memory_order_relaxed);
    }
}

@end

#pragma mark - Dehum

namespace {

struct DehumImpl {
    std::vector<dehum::Channel> chan;

    dehum::Config cfg;
    dehum::Params active = dehum::Params::defaults();
    double rate      = 0.0;
    int    channels  = 0;
    int    maxFrames = 0;
    bool   ready     = false;
    bool   engaged   = false;   //!< audio thread only

    std::atomic<bool> bypass { true };

    // --- commands in, from any thread ---
    os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
    dehum::Params pending = dehum::Params::defaults();
    bool pendingDirty = false;
    bool pendingReset = false;
    dehum::LineReport adopted[dehum::kMaxLines];
    int  adoptedCount = 0;
    bool pendingAdopt = false;

    // --- diagnostics out, to the UI ---
    os_unfair_lock reportLock = OS_UNFAIR_LOCK_INIT;
    PTDehumLine reported[dehum::kMaxLines];
    int reportedCount = 0;
};

} // anonymous namespace

@implementation PTDehumProcessor {
    DehumImpl _im;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _im.pending = dehum::Params::defaults();
        _im.active  = _im.pending;
    }
    return self;
}

- (BOOL)bypassed { return _im.bypass.load(std::memory_order_relaxed); }
- (void)setBypassed:(BOOL)b { _im.bypass.store(b ? true : false, std::memory_order_relaxed); }

- (void)setParams:(PTDehumParams)params {
    const dehum::Params p = toCore(params);
    os_unfair_lock_lock(&_im.lock);
    _im.pending = p;
    _im.pendingDirty = true;
    os_unfair_lock_unlock(&_im.lock);
}

- (void)resetLines {
    os_unfair_lock_lock(&_im.lock);
    _im.pendingReset = true;
    _im.pendingAdopt = false;
    _im.adoptedCount = 0;
    os_unfair_lock_unlock(&_im.lock);
}

- (void)adoptLines:(const PTDehumLine *)lines count:(NSInteger)count {
    if (lines == NULL || count <= 0) return;
    const int n = (int)std::min<NSInteger>(count, (NSInteger)dehum::kMaxLines);
    os_unfair_lock_lock(&_im.lock);
    for (int i = 0; i < n; ++i) _im.adopted[i] = fromWire(lines[i]);
    _im.adoptedCount = n;
    _im.pendingAdopt = true;
    os_unfair_lock_unlock(&_im.lock);
}

- (BOOL)prepareWithSampleRate:(double)sampleRate
                 channelCount:(NSInteger)channelCount
                    maxFrames:(NSInteger)maxFrames {
    [self unprepare];

    const int nch = (int)std::min<NSInteger>(std::max<NSInteger>(channelCount, 1), kMaxChannels);

    os_unfair_lock_lock(&_im.lock);
    const dehum::Params p = _im.pending;
    _im.pendingDirty = false;
    os_unfair_lock_unlock(&_im.lock);

    dehum::Config cfg;
    cfg.compute(p, sampleRate);

    try {
        _im.chan.resize((size_t)nch);
        for (int c = 0; c < nch; ++c) _im.chan[(size_t)c].configure(cfg);
    } catch (const std::bad_alloc &) {
        [self unprepare];
        return NO;
    }

    _im.cfg       = cfg;
    _im.active    = p;
    _im.rate      = sampleRate;
    _im.channels  = nch;
    _im.maxFrames = (int)std::max<NSInteger>(maxFrames, 1);
    _im.engaged   = false;
    _im.ready     = true;
    return YES;
}

- (void)unprepare {
    _im.ready = false;
    _im.engaged = false;
    _im.chan.clear();
}

- (void)renderInPlace:(float * const *)data
         channelCount:(NSInteger)channelCount
           frameCount:(NSInteger)frameCount {
    DehumImpl & im = _im;
    if (!im.ready) return;

    const int n   = (int)frameCount;
    const int nch = (int)std::min<NSInteger>(channelCount, im.channels);
    if (n <= 0 || nch <= 0) return;

    const bool wanted = !im.bypass.load(std::memory_order_relaxed);

    dehum::scoped_flush_denormals ftz;

    bool doReset = false, doAdopt = false;
    dehum::LineReport adopted[dehum::kMaxLines];
    int adoptedCount = 0;

    dehum::Params moved = im.active;
    bool doMove = false;
    if (os_unfair_lock_trylock(&im.lock)) {
        if (im.pendingDirty) {
            im.pendingDirty = false;
            moved = im.pending;
            doMove = moved != im.active;
        }
        if (im.pendingReset) { im.pendingReset = false; doReset = true; }
        if (im.pendingAdopt) {
            im.pendingAdopt = false;
            adoptedCount = im.adoptedCount;
            for (int i = 0; i < adoptedCount; ++i) adopted[i] = im.adopted[i];
            doAdopt = adoptedCount > 0;
        }
        os_unfair_lock_unlock(&im.lock);
    }

    if (doMove) {
        dehum::Config next;
        next.compute(moved, im.rate);
        // Only the sample rate sizes anything here, so every parameter move
        // retunes live and the audio never breaks.
        bool ok = next.structurallyEquals(im.cfg);
        for (int c = 0; c < im.channels && ok; ++c) ok = im.chan[(size_t)c].retune(next);
        if (!ok) for (int c = 0; c < im.channels; ++c) im.chan[(size_t)c].configure(next);
        im.cfg    = next;
        im.active = moved;
    }

    if (doReset) for (int c = 0; c < im.channels; ++c) im.chan[(size_t)c].reset();

    if (!wanted) {
        // Nothing is spent on a detector the user has switched off; the analysis
        // window is therefore stale when it comes back, so drop it then - the
        // lines themselves are still true of the record and are kept.
        im.engaged = false;
        return;
    }

    if (!im.engaged) {
        for (int c = 0; c < im.channels; ++c) im.chan[(size_t)c].flush();
        im.engaged = true;
    }
    if (doAdopt) {
        for (int c = 0; c < im.channels; ++c) im.chan[(size_t)c].adopt(adopted, adoptedCount);
    }

    for (int c = 0; c < nch; ++c) im.chan[(size_t)c].process(data[c], (size_t)n, 1);

    // Publish what channel 0 believes, for the parameters overlay. The UI takes
    // this lock for real; the audio thread only ever tries it.
    if (os_unfair_lock_trylock(&im.reportLock)) {
        dehum::LineReport lines[dehum::kMaxLines];
        int count = 0;
        im.chan[0].report(lines, (int)dehum::kMaxLines, &count);
        for (int i = 0; i < count; ++i) im.reported[i] = toWire(lines[i]);
        im.reportedCount = count;
        os_unfair_lock_unlock(&im.reportLock);
    }
}

- (NSInteger)copyLines:(PTDehumLine *)out max:(NSInteger)max {
    if (out == NULL || max <= 0) return 0;
    os_unfair_lock_lock(&_im.reportLock);
    const int n = (int)std::min<NSInteger>(max, (NSInteger)_im.reportedCount);
    for (int i = 0; i < n; ++i) out[i] = _im.reported[i];
    os_unfair_lock_unlock(&_im.reportLock);
    return n;
}

@end

#pragma mark - Scout

@implementation PTDehumScout {
    dehum::Channel _chan;
    bool           _usable;
}

- (instancetype)initWithSampleRate:(double)sampleRate params:(PTDehumParams)params {
    self = [super init];
    if (self) {
        dehum::Params p = toCore(params);
        // A pinned frequency turns the search off, so there would be nothing to
        // find and adopt() would refuse the result anyway. Scouting is only ever
        // started on automatic, but belt and braces.
        p.frequency = 0.0f;
        p.sanitize();

        dehum::Config cfg;
        cfg.compute(p, sampleRate);
        try {
            _chan.configure(cfg);
            _usable = true;
        } catch (const std::bad_alloc &) {
            _usable = false;
        }
    }
    return self;
}

- (void)feedMono:(const float *)mono frames:(NSInteger)frames {
    if (!_usable || mono == NULL || frames <= 0) return;
    dehum::scoped_flush_denormals ftz;
    // The core processes in place, and the caller's buffer is the decoder's, so
    // copy through a slice rather than editing what we were handed.
    float slice[1024];
    NSInteger done = 0;
    while (done < frames) {
        const NSInteger n = std::min<NSInteger>(1024, frames - done);
        for (NSInteger i = 0; i < n; ++i) slice[i] = mono[done + i];
        _chan.process(slice, (size_t)n, 1);
        done += n;
    }
}

- (NSInteger)lineCount { return _usable ? (NSInteger)_chan.lineCount() : 0; }

- (NSInteger)report:(PTDehumLine *)out max:(NSInteger)max {
    if (!_usable || out == NULL || max <= 0) return 0;
    dehum::LineReport lines[dehum::kMaxLines];
    int count = 0;
    _chan.report(lines, (int)dehum::kMaxLines, &count);
    const int n = (int)std::min<NSInteger>(max, (NSInteger)count);
    for (int i = 0; i < n; ++i) out[i] = toWire(lines[i]);
    return n;
}

@end
