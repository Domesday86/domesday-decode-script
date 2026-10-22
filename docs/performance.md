# Decode performance

Measurements from `decode-ggv.sh` (since removed) and `decode-domesday.sh` on
the pinned `ld-decode-c02a4ec` build, taken 2026-09-05/06: the flag sweeps, and
then a six-side National A run of 321,954 frames that put the chosen flags to
work.
A few figures from the earlier `ld-decode-5a83836` build are kept for
comparison and are labelled where they appear.

They are here to answer two questions that come up before every long run: *how
long will this take*, and *what should `--jobs` and `--threads` be set to*.

The short answer to the second one is **`-t 4 -j 2`**, and unlike on the
previous build both halves of that are worth having: four workers per decode
beats ld-decode's own ten by 7.5%, and a second concurrent decode beats running
the two in turn by 8.6%. A third concurrent decode is worth nothing.

## Test machine

| | |
| --- | --- |
| CPU | 16 cores |
| RAM | 62 GB |
| Library | NFS, `10.0.1.4:/volume1/Domesday86_Library` |
| Decodes | NFS, `10.0.1.4:/volume1/Domesday86_Decodes` |
| ld-decode | `7.2.0+git.c02a4ec` (`prev8-parallel-dev`) |

Every Domesday decode below was made with `--V4300D_coherent_subtract`, which
the script passes unconditionally; the GGV decodes were not, being NTSC and PAL
calibration discs rather than LD-V4300D captures.

## Method for the flag sweeps

Both sweeps decode **1000 frames** from the head of a Domesday National A side,
with the start point already cached, except where noted, so that a run is pure
decode. Three sides stand in for the library: **DS3**, **DS5** and **DS9**
National A. They were chosen for being the same side, format and capture family
as the sides the flags would then be used on, while not being sides due to be
decoded in full — so no benchmark run had to be repeated later.

Two figures are recorded per run: wall clock around the whole script, and
ld-decode's own `Took … seconds to decode N frames (… FPS post-setup)`. There
are two layers of setup between them — about 4.7 s of script around `Took`, and
about 12 s inside it that the post-setup FPS excludes. The `--threads` table
below quotes the post-setup figure, since that is what the flag acts on; the
`--jobs` table quotes wall clock, since that is what a queue of sides costs.

Absolute rates from a 1000-frame run do not carry over to a full side, in either
direction: per decode it reads *high*, because the head of a side is clean
material (see [Disc condition](#disc-condition)), while in aggregate it reads
*low*, because 17 s of per-decode setup is amortised over 1000 frames rather
than 54,000 (see [Full-side timings](#full-side-timings)). The flag
*comparisons* hold regardless — that is what the sweeps are for.

## Choosing `--threads`

One decode, DS3 National A, varying the worker pool. The sweep was run twice,
forward (2→10) and then reverse (10→2), to separate the curve from any drift:

| Workers | Pass 1 | Pass 2 | Mean | FPS (post-setup) | CPU busy |
| --- | --- | --- | --- | --- | --- |
| 2 | 259.96 s | 255.72 s | 257.84 s | 4.07 | 20.1% |
| **4** | **195.30 s** | **197.12 s** | **196.21 s** | **5.42** | 31.9% |
| 6 | 198.91 s | 200.63 s | 199.77 s | 5.32 | 33.8% |
| 8 | 205.91 s | 205.73 s | 205.82 s | 5.16 | 36.1% |
| 10 | 211.47 s | 210.28 s | 210.88 s | 5.03 | 38.4% |

The seconds are ld-decode's `Took`; the FPS is its own post-setup figure, which
divides by a window about 12 s shorter, so the two columns are not reciprocals.
Either ranks the pool sizes the same way.

The two passes agree to within 1% at every point, so this is a curve and not
noise. It has a peak at four workers and **turns down past it**: ld-decode's own
auto-selected ten comes out 7.5% slower than four while drawing 20% more CPU,
and each step up from four costs another 2-3%. Two workers is genuinely starved.

This is a change from the previous build, where the same sweep was flat from
four workers up and the 2.8% spread across 4–10 was inside the run-to-run noise.
The peak has not moved; what has changed is that the tail beyond it now costs
something measurable, which is why the default moved from six to four.

`iowait` stayed at or below 0.29% across all ten runs.

## Choosing `--jobs`

Three sides at `-t 4`, decoded singly and then together. Wall clock, start
points cached:

| Arrangement | Wall | CPU busy | vs. sequential |
| --- | --- | --- | --- |
| DS3 alone | 200.2 s | 31.9% | |
| DS5 alone | 177.5 s | 32.9% | |
| DS9 alone | 175.8 s † | — | |
| two sides in turn | 377.6 s | ~32% | — |
| **two sides, `-j 2`** | **347.8 s** | 66.0% | **1.086× — 8.6% faster** |
| three sides in turn | 553.4 s | ~32% | — |
| three sides, `-j 3` | 555.3 s | 90.0% | 0.997× — level |

† DS9's start was not yet cached when it was timed, so its measured 248.1 s
includes a 72 s start search. The figure above is its decode phase (171.1 s)
plus the 4.7 s of setup the other two showed, and it is used only in the
three-side sequential total.

The second decode is worth having: 30 seconds off a six-minute pair, for a host
that is still only two thirds busy. The third is not. It takes the machine to
90% CPU and finishes level with running the three in turn — the extra cores go
into the job and no extra frames come out.

So the ceiling is reached at roughly two decodes' worth of work, and whatever
imposes it is shared between the decodes rather than private to each. `iowait`
was 0.16% during the pair and 0.03% during the triple, so it is not I/O.
**Memory bandwidth is the leading suspect** — ld-decode streams multi-megabyte
blocks through FFT and filter passes — but no `perf` counters were taken, so
treat that as hypothesis rather than established cause. What is established is
the observable: past about eight busy workers, more of them does not mean more
frames, whether they are added inside one decode or across three.

This is also a change from the previous build, where `-j 2` returned about 1%.
The parallel work in `c02a4ec` has made the second job pay.

### What follows from it

- `--threads` past four costs CPU **and** returns negative throughput.
- `--jobs 2` is worth about 8.6%; `--jobs 3` and up are worth nothing on
  throughput. They are still worth reaching for to keep every side advancing, so
  a side that crawls through damaged media does not hold up the queue behind it.
- A faster library run needs more memory bandwidth, or more machines — not more
  of either flag.

Both scripts therefore default to **four workers per decode**, shared between
concurrent jobs (`DECODE_THREADS_TARGET`, overridable with `DD_THREADS_TARGET`
or `--threads`). On a 16-core host that gives four each at `--jobs` 1, 2 and 3,
and three at `--jobs 4`.

## Full-side timings

Six National A sides, `-j 2 -t 4`, decoded 2026-09-05/06. `Frames` is what the
CVBS writer emitted; `Drops` counts `Unable to determine start of field`.

| Side | Frames | Time | FPS | Drops | Burst max / rms |
| --- | --- | --- | --- | --- | --- |
| DS2 | 54,005 | 4 h 53 m | 3.07 | 2,864 | 8.10° / 1.42° |
| DS4 | 54,005 | 4 h 13 m | 3.55 | 48 | 7.27° / 1.42° |
| DS6 | 54,005 | 4 h 15 m | 3.53 | 20 | 7.58° / 1.05° |
| DS7 | 54,002 | 4 h 27 m | 3.36 | 22 | 23.02° / 1.34° |
| DS8 | 54,005 | 4 h 17 m | 3.49 | 19 | 6.88° / 1.35° |
| DS10 | 51,932 | 3 h 55 m | 3.69 | 73 | 37.18° / 1.33° |

A clean CAV side is **about four and a quarter hours**. The whole run —
321,954 frames, three pairs, including the badly damaged DS2 — spanned 13.27 h
wall clock for an **aggregate of 6.74 FPS**.

That aggregate is *higher* than the 5.75 FPS the `-j 2` pair benchmark
predicted, which is worth knowing before trusting a short run again: a
1000-frame decode carries about 17 s of per-decode setup (4.7 s of script, ~12 s
inside ld-decode) that a 54,000-frame decode amortises to nothing, so a short
benchmark understates sustained throughput by roughly 8%. It ranks the flag
settings correctly; it just reads low in absolute terms. The damaged-region
penalty that might have pulled the other way turned out to be confined to one
side of the six.

For comparison, the same DS2 National A side on the previous `5a83836` build at
`-j 2 -t 6` took **5 h 37 m at 2.67 FPS**, against 4 h 53 m at 3.07 FPS here —
the new pin is about **15% faster on the same capture**, and the two-side
aggregate on that build was 5.34 FPS against 6.74 here.

The calibration discs, from the `5a83836` build:

| Decode | Frames | Time | FPS |
| --- | --- | --- | --- |
| GGV1069 (NTSC, 1 job) | 2,000 | 209.92 s | 9.79 |
| GGV1011 (PAL, 1 job) | 2,000 | 305.78 s | 6.66 |

NTSC ran about 47% faster than PAL for the same frame count, which is just data
volume: 0.96 MB a frame against 1.42 MB.

### Frames decoded but not written

Three of the six sides wrote fewer frames than they decoded:

| Side | Decoded | Written | |
| --- | --- | --- | --- |
| DS2, DS4, DS6 | 54,005 | 54,005 | — |
| DS8 | 54,007 | 54,005 | −2 |
| DS7 | 54,008 | 54,002 | −6 |
| DS10 | 51,940 | 51,932 | −8 |

The outputs are internally consistent — every `.cvbs` is exactly
1,418,758 bytes per written frame — so nothing is truncated; some frames simply
reach the end of the decode without being emitted. It is a small variable tail
rather than a property of one side, and it has not been chased further.

## Start caching

Resolving a start is several short ld-decode probes — convergence probes plus
one to three lead-in trials — each seeking into a multi-gigabyte `.ldf` over
NFS. It cost **194 s** on DS3 National A and **72 s** on DS9; the spread is the
number of lead-in trials needed, which is ten on DS3 and few on DS9.

That is a fixed cost per side, so it is negligible on a full-length decode and
dominant on a short one: the 2000-frame calibration run spent 296 s of its
1,197 s wall clock (24.7%) resolving starts, while the six-side National A run
spent **7.5 minutes** resolving all six from cold — 0.9% of its 13.27 hours.

The cache lives inside the decoder directory, so it survives re-runs of the same
commit but not a new one. For a library run this matters mostly in that
resolving all 49 starts up front, at `--jobs` concurrency, gets the seek-bound
work out of the way before any decoding begins.

## Signal quality

All six National A sides came out `CVBS_U10_4FSC`,
`STANDARD_STABLE_UNLOCKED`, `sequence BROKEN`, with **0 samples clamped**. Burst
residual rms sat in a tight band of 1.05–1.42°, but two sides threw a much
larger maximum:

| Side | Burst residual max | rms |
| --- | --- | --- |
| DS8 | 6.88° | 1.35° |
| DS4 | 7.27° | 1.42° |
| DS6 | 7.58° | 1.05° |
| DS2 | 8.10° | 1.42° |
| **DS7** | **23.02°** | 1.34° |
| **DS10** | **37.18°** | 1.33° |

A normal rms behind a 23° or 37° maximum means a handful of bad frames rather
than anything systemic, and neither side is in poor condition otherwise (22 and
73 dropped fields). Both are worth an eyeball before the decodes are used for
anything that cares about chroma phase.

The following table is from the earlier `ld-decode-5a83836` full-side and
calibration decodes.

| | GGV1011 | GGV1069 | DS2 CommunitySouth | DS2 NationalA |
| --- | --- | --- | --- | --- |
| Format | `CVBS_U10_4FSC` | `CVBS_U16_4FSC` | `CVBS_U10_4FSC` | `CVBS_U10_4FSC` |
| Sync | UNLOCKED | LOCKED | UNLOCKED | UNLOCKED |
| Samples clamped | 0 | 4,019,418 | 0 | 0 |
| Burst residual max | 7.44° | 0.32° | 8.55° | 8.22° |
| Burst residual rms | 0.77° | 0.10° | 1.24° | 1.42° |
| Dropped fields | 8 | 6 | 80 | 2,451 |

`sequence BROKEN` appears on all four and is not a fault: it reflects the
field-sequence discontinuity in the lead-in that each start point deliberately
keeps.

Two things worth carrying forward:

**GGV1069 clamped 4.02 M samples**, about 0.42% of its output, and was the only
decode to come out `U16` rather than `U10`. Its burst residual is the tightest
of the four by an order of magnitude, but the clamping means its levels should
not be trusted for calibration work without a closer look.

**DS2 NationalA's chroma is genuinely weak.** Measured burst sat at 14.6–15.3
IRE against 21.4 expected, and the auto inverse-MTF correction ran to −1.8 and
was held there by the multiburst chroma band on nearly all of its 611
adjustments. The correction cannot reach the target; the signal is not there.

## Disc condition

Across the six National A sides decoded on `c02a4ec`, condition is bimodal:
DS4, DS6, DS7, DS8 and DS10 dropped between 19 and 73 fields over a whole side,
and **DS2 dropped 2,864** — forty times the worst of the others. Damage is the
exception in this library, not the rule, and one bad side is what drags a run's
aggregate down.

### A drop-rate regression on the new build

DS2 National A is the one side decoded on both builds, and the newer one loses
more of it:

| Pictures | `5a83836` | `c02a4ec` |
| --- | --- | --- |
| 46,000 – 47,999 | 454 | 586 |
| 48,000 – 49,999 | 1,123 | 1,279 |
| 50,000 – 51,999 | 306 | 310 |
| 52,000 – 53,999 | 537 | 651 |
| **whole side** | **2,451** | **2,864** |

17% more dropped fields on an identical capture, worse in every damaged band.
It is not a logging artifact: both builds emit one `Unable to determine start of
field - dropping field` per drop and the two logs are within 0.3% on total DEBUG
lines. The newer build also resyncs *less* — 332 three-consecutive-reject
resyncs against 382 — which suggests it abandons marginal fields sooner rather
than fighting for them longer, and that would also account for part of its 15%
speed advantage. Burst residual is unchanged (8.10°/1.42° against 8.22°/1.42°),
so recovered frames look the same; there are simply fewer of them.

This rests on a single side, and that side is the worst-damaged of the six.

### Dropped fields by region

From the `ld-decode-5a83836` full-side decodes. This is a property of the discs,
not the build.

**DS2 NationalA** — 2,451 dropped fields, 98.7% of them in the inner third:

| Pictures | Dropped fields |
| --- | --- |
| 1 – 45,999 | 29 |
| 46,000 – 47,999 | 454 |
| 48,000 – 49,999 | 1,123 |
| 50,000 – 51,999 | 306 |
| 52,000 – 53,999 | 537 |

**DS2 CommunitySouth** — 80 dropped fields, 69 of them in 52,000–53,999.

Both degrade toward the inner edge, which is the ordinary wear pattern. National
A is about 30× worse and its damage starts some 6,000 pictures earlier.

In the worst band the decoder's field-boundary speculation fails repeatedly —
`sync_conf 0`, three-consecutive-reject resyncs, 382 of them over the side —
and falls back to the committed chain, which forces the work onto the serial
path. NationalA's throughput fell from 2.8 FPS to **0.99 FPS** through that
region and recovered to 3.63 FPS once clear of it. Nothing aborts; bad fields
are dropped and recorded.

**The VBI picture numbers are themselves corrupt inside that band.** The log
carries reads like `#67389` and `#8057` interleaved with the correct ~47,800
sequence. Anything downstream that keys off CAV picture numbers in the
46,000–54,000 range on this side has to tolerate garbage.

## Planning a library run

The six-side run sustained **6.74 FPS aggregate** at `-j 2 -t 4`, including one
badly damaged side. At that rate the 49 sides of the library come to about
**4.5 days** of continuous decoding, against 5.7 days at the previous build's
5.34 FPS.

Treat 6.74 as the planning figure rather than the 5.75 the short `-j 2`
benchmark suggested — see [Full-side timings](#full-side-timings) for why a
1000-frame run reads about 8% low. Across the configurations tested here the
flags move the total by about 15% at most, `-j 1 -t 10` against `-j 2 -t 4`, so
the choice is worth making and is not worth agonising over.

Storage runs at **1,418,758 bytes per PAL frame**, measured identically on all
six sides, so a full CAV side is 74 GB of `.cvbs` and about 74 GB in total once
`.efm`, audio and metadata are counted. The 49 sides come to something over
3.5 TB.

## Reproducing these numbers

The per-decode figures come from ld-decode's own progress log, which every
decode writes beside its output:

```sh
grep -E 'Took |CVBS: wrote' <output basename>.log
```

Wall clock and host CPU around a whole run, which is what the `--jobs` table
quotes, have to be taken outside the script — `/proc/stat` sampled either side
of it, or `/usr/bin/time`.

Dropped fields by region, as tabulated above:

```sh
awk '
  /CAV Frame #/ { match($0,/CAV Frame #[0-9]+/)
                  f=substr($0,RSTART+11,RLENGTH-11)+0
                  if (f>0 && f<=54100) cur=f }
  /Unable to determine start of field/ { if (cur>0) b[int(cur/2000)]++ }
  END { for (i=0;i<=27;i++) if (b[i]>0)
          printf "%6d-%6d : %5d\n", i*2000, (i+1)*2000-1, b[i] }
' <output basename>.log
```

Note that this keys off the same VBI picture numbers that go corrupt in a
damaged region, so the bands are approximate exactly where the damage is
heaviest.
