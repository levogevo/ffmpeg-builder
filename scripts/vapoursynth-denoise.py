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

# Tunables
PEL = 4
SUPER_SHARP = 2
SUPER_RFILTER = 4

BLKSIZE = 8
OVERLAP = 4
SEARCH = 4

RECALC_BLKSIZE = 4
RECALC_SEARCH = 4
RECALC_THSAD = grain

DEGRAIN_THSAD = grain
DEGRAIN_THSADC = grain // 2

# source
src = core.bs.VideoSource(input)

# motion estimation
super = core.mv.Super(
    src,
    pel=PEL,
    sharp=SUPER_SHARP,
    rfilter=SUPER_RFILTER
)

# delta 1
bw1 = core.mv.Analyse(
    super,
    isb=True,
    delta=1,
    blksize=BLKSIZE,
    overlap=OVERLAP,
    search=SEARCH,
    truemotion=True
)

fw1 = core.mv.Analyse(
    super,
    isb=False,
    delta=1,
    blksize=BLKSIZE,
    overlap=OVERLAP,
    search=SEARCH,
    truemotion=True
)

# delta 2
bw2 = core.mv.Analyse(
    super,
    isb=True,
    delta=2,
    blksize=BLKSIZE,
    overlap=OVERLAP,
    search=SEARCH,
    truemotion=True
)

fw2 = core.mv.Analyse(
    super,
    isb=False,
    delta=2,
    blksize=BLKSIZE,
    overlap=OVERLAP,
    search=SEARCH,
    truemotion=True
)

# delta 3
bw3 = core.mv.Analyse(
    super,
    isb=True,
    delta=3,
    blksize=BLKSIZE,
    overlap=OVERLAP,
    search=SEARCH,
    truemotion=True
)

fw3 = core.mv.Analyse(
    super,
    isb=False,
    delta=3,
    blksize=BLKSIZE,
    overlap=OVERLAP,
    search=SEARCH,
    truemotion=True
)

# refine
bw1 = core.mv.Recalculate(
    super, bw1,
    blksize=RECALC_BLKSIZE,
    search=RECALC_SEARCH,
    thsad=RECALC_THSAD
)

fw1 = core.mv.Recalculate(
    super, fw1,
    blksize=RECALC_BLKSIZE,
    search=RECALC_SEARCH,
    thsad=RECALC_THSAD
)

bw2 = core.mv.Recalculate(
    super, bw2,
    blksize=RECALC_BLKSIZE,
    search=RECALC_SEARCH,
    thsad=RECALC_THSAD
)

fw2 = core.mv.Recalculate(
    super, fw2,
    blksize=RECALC_BLKSIZE,
    search=RECALC_SEARCH,
    thsad=RECALC_THSAD
)

bw3 = core.mv.Recalculate(
    super, bw3,
    blksize=RECALC_BLKSIZE,
    search=RECALC_SEARCH,
    thsad=RECALC_THSAD
)

fw3 = core.mv.Recalculate(
    super, fw3,
    blksize=RECALC_BLKSIZE,
    search=RECALC_SEARCH,
    thsad=RECALC_THSAD
)

# temporal denoise
de = core.mv.Degrain3(
    src,
    super,
    bw1, fw1,
    bw2, fw2,
    bw3, fw3,
    thsad=DEGRAIN_THSAD,
    thsadc=DEGRAIN_THSADC,
    plane=4
)

de.set_output()