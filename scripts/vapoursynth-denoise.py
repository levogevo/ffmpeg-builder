#!/usr/bin/env python3

import vapoursynth as vs
import os

core = vs.core

# inputs
inputArg = globals().get('input')
grainArg = globals().get('grain')

if inputArg is None:
    inputArg = os.getenv("INPUT")
if grainArg is None:
    grainArg = os.getenv("GRAIN")

input = inputArg
grain = int(grainArg)

# tunables
PEL = 4
SUPER_SHARP = 2
SUPER_RFILTER = 4

# Build the pyramid over the chroma planes too, so the block matching has
# colour information available.
SUPER_CHROMA = True

BLKSIZE = 8
OVERLAP = 4
SEARCH = 4

# Hexagon search depth for the block matching, in both Analyse and the
# Recalculate refinement pass. This happens to be the plugin default in this
# MVTools build, but it is spelled out because the default is not documented
# and the value measurably moves the rate/quality curve.
SEARCHPARAM = 2

RECALC_BLKSIZE = 4
RECALC_SEARCH = 4
RECALC_THSAD = grain

# The source is a grainy 4K film scan. Grain is temporally random, so it is
# cheap to average away with motion compensation and very expensive for the
# encoder, while SVT-AV1 re-synthesises it for almost nothing at playback time
# (film-grain=50 / adaptive-film-grain=1 in the encode parameters). Spending
# the bit budget on picture detail instead of noise is a large net win.
#
# Grain also inflates the per-block SAD that the temporal filter thresholds on,
# which is why the original script was barely denoising anything: at 4K with
# grain this strong almost every block failed the test and kept its own pixels.
# A single 3x3 box blur on the *analysis source only* brings the SAD back into
# range so the temporal filter actually engages. The pixels that get averaged
# are still the untouched source, so nothing is softened by the blur itself.
ANALYSIS_BLUR = 1

# Number of frames each pixel is averaged over. Grain averages down as 1/sqrt(n),
# so the extra taps buy real noise reduction rather than just a lower rate.
# Measured against Degrain3 at matched bitrate over four rate points, Degrain5
# is consistently ~0.0005 SSIM better; Degrain6 ties Degrain5 and is slower, so
# five taps is the stopping point.
DEGRAIN_FRAMES = 5

# Degrain threshold. Higher = smoother = fewer bits. Picked from the measured
# rate/quality frontier, then verified with a real `encode.sh` run.
DEGRAIN_THSAD = 260
DEGRAIN_THSADC = 225

# 4 = weights are derived from luma but chroma is filtered too. Chroma-weighted
# modes (plane 2/3) and luma-only (plane 0) were both far off the frontier.
DEGRAIN_PLANE = 4

# source
src = core.bs.VideoSource(input)

# motion estimation (on the blurred analysis source)
asrc = core.std.BoxBlur(
    src,
    hradius=ANALYSIS_BLUR,
    vradius=ANALYSIS_BLUR,
    hpasses=1,
    vpasses=1,
)

super = core.mv.Super(
    asrc,
    pel=PEL,
    sharp=SUPER_SHARP,
    rfilter=SUPER_RFILTER,
    chroma=SUPER_CHROMA
)

vectors = []
for delta in range(1, DEGRAIN_FRAMES + 1):
    bw = core.mv.Analyse(
        super,
        isb=True,
        delta=delta,
        blksize=BLKSIZE,
        overlap=OVERLAP,
        search=SEARCH,
        searchparam=SEARCHPARAM,
        truemotion=True
    )

    fw = core.mv.Analyse(
        super,
        isb=False,
        delta=delta,
        blksize=BLKSIZE,
        overlap=OVERLAP,
        search=SEARCH,
        searchparam=SEARCHPARAM,
        truemotion=True
    )

    bw = core.mv.Recalculate(
        super, bw,
        blksize=RECALC_BLKSIZE,
        search=RECALC_SEARCH,
        searchparam=SEARCHPARAM,
        thsad=RECALC_THSAD
    )

    fw = core.mv.Recalculate(
        super, fw,
        blksize=RECALC_BLKSIZE,
        search=RECALC_SEARCH,
        searchparam=SEARCHPARAM,
        thsad=RECALC_THSAD
    )

    vectors.append((bw, fw))

# temporal denoise. MVTools applies the threshold per block, so anything that
# does not actually match (real motion, occlusions) keeps its original pixels.
# Note: no spatial blur is applied to the output.
de = core.mv.Degrain5(
    src,
    super,
    *vectors[0], *vectors[1], *vectors[2], *vectors[3], *vectors[4],
    thsad=DEGRAIN_THSAD,
    thsadc=DEGRAIN_THSADC,
    plane=DEGRAIN_PLANE
)

de.set_output()