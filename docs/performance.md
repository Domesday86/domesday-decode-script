# Decode performance

Measurements from `decode-ggv.sh` and `decode-domesday.sh` on the pinned
`ld-decode-5a83836` build, taken 2026-09-04/05. They are here to answer two
questions that come up before every long run: *how long will this take*, and
*what should `--jobs` and `--threads` be set to*.

The short answer to the second one is that neither flag moves the total much on
this machine, and the reasoning behind that is in [Throughput does not scale
with cores](#throughput-does-not-scale-with-cores).

## Test machine

| | |
| --- | --- |
| CPU | 16 cores |
| RAM | 62 GB |
| Library | NFS, `10.0.1.4:/volume1/Domesday86_Library` |
| Decodes | NFS, `10.0.1.4:/volume1/Domesday86_Decodes` |
| ld-decode | `7.2.0+git.5a83836` (`prev8-parallel-dev`) |

Every Domesday decode below was made with `--V4300D_coherent_subtract`, which
the script passes unconditionally; the GGV decodes were not, being NTSC and PAL
calibration discs rather than LD-V4300D captures.

## Headline numbers

| Decode | Frames | Time | FPS |
| --- | --- | --- | --- |
| GGV1069 (NTSC, 1 job) | 2,000 | 209.92 s | 9.79 |
| GGV1011 (PAL, 1 job) | 2,000 | 305.78 s | 6.66 |
| DS2 CommunitySouth (PAL, 2 jobs) | 54,005 | 5 h 11 m | 2.90 |
| DS2 NationalA (PAL, 2 jobs) | 54,005 | 5 h 37 m | 2.67 |

A full CAV side is **roughly five and a half hours**, and two of them decoded
together take about the same wall clock as one — see below.

NTSC runs about 47% faster than PAL for the same frame count, which is just
data volume: 0.96 MB a frame against 1.42 MB.

## Throughput does not scale with cores

### One decode, varying the worker pool

GGV1011, PAL, 1000 frames, start point pre-cached so every run is pure decode:

| Workers | Time | FPS |
| --- | --- | --- |
| 4 | 160.50 s | 6.46 |
| 6 | 157.41 s | 6.61 |
| 8 | 161.51 s | 6.43 |
| 10 | 160.67 s | 6.47 |

A 2.8% spread, and not monotonic — 8 workers came out below both 6 and 10. The
differences are run-to-run noise. Throughput is flat from four workers upward,
and ld-decode's own choice of ten buys nothing over six.

### Two decodes at once

Total throughput sat at ~5.3 FPS across every arrangement tried:

| Arrangement | Workers | CPU busy | Aggregate FPS |
| --- | --- | --- | --- |
| 1 decode, ld-decode auto | 10 | not sampled | 5.29 |
| 2 decodes, `-t 4` | 8 | 71% | ~5.20 |
| 2 decodes, `-t 6` | 12 | 93% | 5.34 |

Decoding DS2's two sides concurrently took 20,229 s. Decoding them one after
the other at the single-decode rate would have taken about 20,400 s. **The
second job bought roughly 1%.**

Going from 8 workers to 12 raised CPU use by 31% and throughput by 2.7%. The
cores are there and they are busy, but the frames do not come out any faster.

I/O is not the constraint: `iowait` was **0%** for the entire five-and-a-half
hour run, on both the read side (NFS `.ldf`) and the write side (NFS `.cvbs`).
Nor is it the serial decode loop in the way the script's comments assume — the
loop's own process topped out near 1.7 cores per decode and stayed there
whether it was fed 4 workers or 6.

The likeliest remaining explanation is **memory bandwidth**. ld-decode streams
multi-megabyte blocks through FFT and filter passes, and that saturates the
memory subsystem well before it saturates 16 cores. This has not been measured
directly — no `perf` counters were taken — so treat it as the leading
hypothesis rather than an established cause. What *is* established is the
observable: more workers, same frames per second.

### What follows from it

- Raising `--threads` past the plateau costs CPU and returns nothing.
- Raising `--jobs` does not multiply throughput on this machine. It is still
  worth using, because it keeps every side's decode advancing rather than
  finishing one and starting the next, and because a stalled side (see
  [Disc condition](#disc-condition)) no longer holds up the queue.
- A faster library run needs more memory bandwidth, or more machines — not
  more of either flag.

Both scripts therefore default to **six workers per decode**, shared between
concurrent jobs (`DECODE_THREADS_TARGET`, overridable with `DD_THREADS_TARGET`
or `--threads`). Six is the highest measured point in both regimes above,
though its margin is inside the noise; the substantive part is that it matches
ld-decode's own ten while spawning 40% fewer processes. On a 16-core host that
gives six each at `--jobs 1` and `--jobs 2`, four at `--jobs 3`, three at
`--jobs 4`.

## Start caching

The 2000-frame calibration run spent **296 s of its 1,197 s wall clock (24.7%)
resolving start points** — three convergence probes plus one to three lead-in
trials per disc, each seeking into a multi-gigabyte `.ldf` over NFS.

The full DS2 run spent **5 seconds**, because both `.start` files were already
cached from the earlier run.

Start resolution is a fixed cost per side, so it is negligible on a full-length
decode and dominant on a short one. The cache lives inside the decoder
directory, so it survives re-runs of the same commit but not a new one. For a
library run this matters mostly in that resolving all 49 starts up front, at
`--jobs` concurrency, gets the seek-bound work out of the way before any
decoding begins.

## Signal quality

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

Dropped fields by region, from the full-side decodes:

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

At a fixed ~5.3 FPS aggregate, the 49 sides of the library come to roughly
**5.7 days** of continuous decoding, and no combination of `--jobs` and
`--threads` tested here changes that materially.

Storage runs at about **1.42 MB per PAL frame**, so a full CAV side is ~74 GB
across `.cvbs`, `.efm`, audio and metadata. The 49 sides come to something over
3.5 TB.

## Reproducing these numbers

The per-decode figures come from ld-decode's own progress log, which every
decode writes beside its output:

```sh
grep -E 'Took |CVBS: wrote' <output basename>.log
```

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
