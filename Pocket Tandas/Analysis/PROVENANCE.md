# Vendored analysis sources

`bpmcore/` and `pffft/` are **verbatim copies** and carry no local edits. Nothing
algorithmic is written here: `PTBPMAnalyzer.mm` is host glue, exactly as
`DSP/PTRestorationDSP.mm` is glue over the two restoration cores.

## bpmcore

    /Users/user/hacking/foo_rubato — bpmcore/
    the tempo + rhythm analysis behind foo_rubato (the "Rubato BPM Analyzer"
    foobar2000 component), which is itself only a shell around these files.

Copied 2026-09-16 from `550f387` (`bpmcore/{analyse,odf,real_fft,resample,rhythm,tempo}.cpp`
and `bpmcore/{bpmcore,internal,parallel,real_fft,rhythm_model}.h`).

`kiss_fft/` is deliberately NOT carried over: bpmcore names its transform in one
place, and this port takes the pffft backend.

## pffft

    https://bitbucket.org/jpommier/pffft
    revision 0aec0327a6912e1a0ec5326eef737c2ce19bc836

Copied through foo_rubato, which vendored it on 2026-09-13. `COPYING` is the
licence block lifted out of the header; see `pffft/PROVENANCE.txt`.

pffft reaches its SIMD paths off the compiler's own macros — `__aarch64__` /
`__ARM_NEON` on every Apple ARM slice, `__x86_64__` on an Intel Mac — so no
build setting selects them.

## Build settings this needs

Both app targets define, in `GCC_PREPROCESSOR_DEFINITIONS`:

    BPMCORE_FFT_PFFFT              which transform real_fft.cpp compiles against
    BPMCORE_FFT_SCALAR_TYPE=float  the width the spectral stage computes at

The two are separate questions upstream (see `cmake/fft_backend.cmake`) and stay
separate here; pffft is single precision, so `float` is not optional beside it.
`HEADER_SEARCH_PATHS` carries this folder, which is what makes the
`<bpmcore/bpmcore.h>` and `<pffft/pffft.h>` includes resolve.

## Resyncing

Straight `cp` — there is no local divergence to preserve. Upstream's own harness
(`bpmcore_test`, with `reference_cases.tsv`) is the thing to run against a
resynced copy; it builds with CMake in the foo_rubato tree, against these same
sources.
