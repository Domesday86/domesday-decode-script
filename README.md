# domesday-decode-script

Scripts for automatically decoding the Domesday LaserDisc sets through
[ld-decode](https://github.com/happycube/ld-decode).

## Environment

The toolchain is provided by a Nix flake, so the exact `ld-decode` build used
for a decode is pinned and reproducible. It tracks the
`chad-2026.07.04-prev8-parallel` branch of ld-decode.

Requires Nix with flakes enabled:

```
experimental-features = nix-command flakes
```

### Enter the dev shell

```sh
nix develop
```

This puts `ld-decode` and its sibling tools on `PATH`:

| Command | Purpose |
| --- | --- |
| `ld-decode` | Decode a raw RF capture to `.tbc` |
| `ld-find-start` | ld-decode’s own start finder (see below; `find-disc-start.sh` is used instead) |
| `ld-cut` | Cut a section out of a capture |
| `ld-compress` | Compress a capture to `.ldf` |
| `ld-ldf-reader-py` | Read `.ldf` files |
| `ld-lds-converter-py` | Convert `.lds` files |

`ffmpeg`, `flac` and `shellcheck` are in the shell too.

With [direnv](https://direnv.net/) installed, `direnv allow` enters the shell
automatically on `cd`.

### Run ld-decode without entering the shell

```sh
nix run . -- --pal --start 310 capture.ldf output-basename
```

### Updating the pinned ld-decode

```sh
nix flake update ld-decode
```

`flake.lock` is committed; commit it again after updating so decodes stay
reproducible.

## Decoding the calibration discs

`decode-ggv.sh` decodes the PAL (GGV1011) and NTSC (GGV1069) calibration discs.

```sh
nix develop
./decode-ggv.sh                 # both discs, first 1000 frames each
./decode-ggv.sh --frames 2      # quick smoke test
./decode-ggv.sh --frames all GGV1069
./decode-ggv.sh --frames all -j 2   # both discs at once
./decode-ggv.sh --list
```

Output goes to `<output root>/<disc id>/<decoder>/<capture basename>.*`, where
`<decoder>` names the ld-decode commit that produced the decode — see [Which
ld-decode made a decode](#which-ld-decode-made-a-decode).

### Configuration

Both roots, the frame limit and everything else are configurable by flag or by
environment variable:

| Flag | Variable | Default | Meaning |
| --- | --- | --- | --- |
| `-l, --library` | `DD_LIBRARY` | `/home/sdi/raid/library` | capture library root |
| `-o, --output` | `DD_OUTPUT` | `/home/sdi/raid/decodes/domesday-decode-script` | decode output root |
| `--decoder` | `DD_DECODER` | from `flake.lock` | decoder directory name |
| `--no-verify-decoder` | `DD_VERIFY_DECODER=0` | check | skip the ld-decode/`flake.lock` check |
| `-f, --frames` | `DD_FRAMES` | `1000` | frames per disc, or `all` |
| `--lead-in` | `DD_LEAD_IN` | `1` | frames of lead-in to keep before CAV #1 |
| `--probe` | `DD_PROBE` | `800` | first frame the start search probes |
| `-j, --jobs` | `DD_JOBS` | `1` | discs decoded concurrently |
| `-t, --threads` | `DD_THREADS` | `0` (auto) | ld-decode worker threads per decode |
| `--tbc` | `DD_CVBS=0` | CVBS | write `.tbc` instead of CVBS |

Disc source paths in the table are relative to the library root, so pointing
`--library` at another copy of the library is all that is needed to decode from
somewhere else.

### Which ld-decode made a decode

These are pre-release branch builds, and two of them do not agree frame for
frame — so a decode is only meaningful alongside the ld-decode that produced it.
Decodes are therefore filed under the pinned commit:

```
/home/sdi/raid/decodes/domesday-decode-script/
└── GGV1011/
    ├── ld-decode-3caccf0/          # chad-2026.07.04-prev8-parallel
    │   ├── GGV1011_….cvbs
    │   ├── GGV1011_….start
    │   └── decoder.txt
    └── ld-decode-<next rev>/       # after nix flake update
```

Decoding a disc again after updating ld-decode lands beside the earlier decode
rather than on top of it. Only a re-run of the *same* commit collides, and that
still stops with `already exists; pass --force to overwrite`. The `.start` cache
sits inside the decoder directory too, since which start keeps the lead-in is a
question about the writer's behaviour and so about the build.

The name is the short revision `flake.lock` pins, because that is the build `nix
develop` puts on `PATH`. That is a claim about the flake rather than about the
ld-decode that will actually run, so it is checked before anything is decoded —
`nix eval` on the flake (evaluation only, it never builds; about two seconds
with the store warm) against the ld-decode in the environment:

```
$ ./decode-ggv.sh --frames all
decode-ggv.sh: the ld-decode that would run is not the build flake.lock pins, so
the decode would be filed under a commit that did not produce it:
    on PATH:       /nix/store/1g064rx9…-python3.12-ld-decode-7.2.0/bin/ld-decode
    on PYTHONPATH: /nix/store/1g064rx9…/lib/python3.12/site-packages/lddecode
    flake.lock:    /nix/store/apx0civl…-python3.12-ld-decode-7.2.0
Leave and re-enter the dev shell (exit; nix develop) to pick up the pinned
build, or pass --no-verify-decoder to decode with the one you have.
```

A shell entered before `nix flake update` (or before pulling a new lock) still
holds the previous build, and would otherwise file hours of decoding under a
commit that did not produce it. Both halves of the environment are checked
because either can be stale on its own: ld-decode's launcher is a wrapper that
touches only `PATH`, so the `lddecode` package the interpreter imports is
whichever one `PYTHONPATH` names first — and it is the module, not the launcher,
that decodes.

`--decoder NAME` labels a decode by hand (for an ld-decode built outside the
flake, say), and skips the check. `--no-verify-decoder` keeps the name from
`flake.lock` but decodes with whatever is present.

Each decoder directory gets a `decoder.txt` recording what its name is short
for, for whoever finds the decode later:

```
decoder:  ld-decode-3caccf0 (from flake.lock)
binary:   /nix/store/apx0civl…-python3.12-ld-decode-7.2.0/bin/ld-decode
version:  7.2.0+git.3caccf0
recorded: 2026-08-31T07:30:58+02:00
```

### Finding the start of the disc

The captures begin with disc spin-up, which cannot be decoded, so ld-decode has
to be told where to start. `find-disc-start.sh` works that out.

It replaces ld-decode's own `ld-find-start`, which scans forward from the head
of the capture looking for the first run of 30 contiguous CAV addresses. That
test is wrong in both directions on these captures:

* On **GGV1069 (NTSC)** it answers confidently and wrongly. Spin-up yields
  addresses that advance for long enough to pass, so it reports file frame 145
  — but the addresses read there (#283, then #285, #283, #284…) are misreads,
  and the player is not yet at playback speed. CAV frame #1 is actually at file
  frame 283.
* On **GGV1011 (PAL)** it never passes at all, because the VBI reads through
  spin-up are intermittent. Given no bound it scans the entire 23GB image —
  nearly five minutes — and still fails.

`find-disc-start.sh` uses the arithmetic instead. Jump well past spin-up into
settled playback (`--probe`, default file frame 800), read the CAV picture
number there, and compute where the target frame must be. A capture-relative
file frame is a nominal-length approximation, so the file-frame to
picture-number offset drifts slightly across the disc — on GGV1011 it is 229 at
file frame 800 but 225 at file frame 226 — and the estimate is therefore
re-probed until it lands on CAV #1 exactly. Both discs converge in three probes,
about 20 seconds:

```
$ ./find-disc-start.sh --pal -v GGV1011_….ldf
probe 1: frame 800 -> file frame 800, CAV 571
probe 2: frame 230 -> file frame 230, CAV 5
probe 3: frame 226 -> file frame 226, CAV 1
226
```

Two guards keep it from repeating ld-find-start's mistake:

* A probe reading is only trusted when two successive frames advance together
  (file frame *n*→*n*+1 alongside CAV *m*→*m*+1). A lone address in a spin-up
  region can be a misread, and it is that kind of misread that sends the
  arithmetic to the wrong part of the disc.
* An estimate landing before the head of the capture means the probe was itself
  inside spin-up, so the search moves deeper rather than clamping to zero and
  inventing an answer. It recovers from a badly chosen `--probe` this way, and
  gives up with a diagnostic rather than guessing if it cannot.

### Keeping the lead-in in the output

`--start` alone does not decide what reaches the file. ld-decode's CVBS writer
opens the file on the first field it finds carrying `fieldPhaseID 1` — the
conventional colour-sequence position — and discards everything before it. A
start that lands on any other phase silently loses every frame up to the next
qualifying one. Starting at `CAV #1 - 1` did exactly that: the lead-in frame was
decoded and then thrown away, and on PAL, CAV #1 went with it.

Each file frame has one true phase ID (decodes started at different points agree
exactly where they overlap). What is awkward is the *sequence* through spin-up
and lead-in, where the player is still settling onto the disc and fields are
repeated and skipped — the same condition ld-decode reports as `Field phaseID
sequence mismatch (player may be paused)`. On GGV1011 the first fields run

```
219:1  220:5  221:1  222:1  223:7  224:5  225:5  226:7  227:1  228:3  229:5 ...
```

— no valid 8-field progression until 226, after which it is clean. So only
frames 219, 221 and 222 qualify to open the file, and then not again until 227.
The old start of 225 (phase 5) is why the writer skipped to 227.

Because the qualifying frames are scattered rather than on a fixed lattice,
`find-disc-start.sh` measures rather than predicts: it decodes a short CVBS run
at each candidate and reads back which frame the writer actually opened the file
on, walking back until the candidate itself is accepted.

```
lead-in trial: start 225 -> writer skipped ahead to 227
lead-in trial: start 224 -> writer skipped ahead to 227
lead-in trial: start 223 -> writer skipped ahead to 227
lead-in trial: start 222 -> output opens at 222 (accepted)
```

The output therefore opens with *at least* the requested lead-in, not exactly it:

| Disc | CAV #1 at file frame | `--start` | frames before CAV #1 in the output |
| --- | --- | --- | --- |
| GGV1011 (PAL) | 226 | 222 | 4 |
| GGV1069 (NTSC) | 283 | 280 | 3 |

The resolved values are cached next to the decode as `<basename>.start`, along
with the lead-in they were resolved for — change `--lead-in` and the search
re-runs. `--refresh-start` forces it, and `--start N` bypasses it entirely.

Note that burst is present and at full amplitude throughout the lead-in
(measured 21.1–21.6 IRE on PAL against a 21.4 nominal, 19.1–20.1 IRE on NTSC
against 20.0), so these frames carry real, displayable video. It is only the
field-phase *sequence* that is irregular there. That irregularity does raise the
PAL burst-phase residual across the opening frames, which contributes to the
`STANDARD_TBC_UNLOCKED` verdict discussed below; on this capture that verdict is
set anyway by a player stall much later in the disc.

### Output format

Decodes are CVBS (`--cvbs`): `<basename>.cvbs` (4fsc) plus the `.meta` SQLite
sidecar, `_audio_0.wav`, and the `.dropouts.meta` / `.efm` / `.efm.meta`
extension sidecars. Pass `--tbc` for the older `.tbc` output. ld-decode writes
the `.cvbs` name itself, so nothing here renames it. Earlier branch builds
called it `.composite`; a decode is recognised under either name, so an existing
decode is still found whichever build made it.

The sample encoding differs by standard, and ld-decode chooses it from whether
the signal can carry non-standard values:

| Standard | Preset | Container | Range |
| --- | --- | --- | --- |
| PAL | `CVBS_U10_4FSC` | s16le, 10-bit domain | full s16 headroom |
| NTSC | `CVBS_U16_4FSC` | u16le, 10-bit `<< 6` | 4–1019, shifted |

PAL gets the signed U10 preset because the Domesday pilot burst sits outside the
EBU 3280 protected range, and `CVBS_U16_4FSC` cannot hold values there — encoding
PAL as U16 would clamp the pilot burst away. Read the preset back from the
`.meta` sidecar rather than assuming one: it is recorded per decode, and a
reader that guesses u16le will misread every PAL decode. `--cvbs-encoding`
overrides the choice if you need to force a preset.

### Decoding several discs at once

One decode does not fill a modern machine, and no amount of `--threads` will
make it. On a 16-core host a single full decode keeps about **5.4 cores** busy:

```
$ ps -o pid,pcpu,args -C python3.12
  29278  180   ld-decode --ntsc --cvbs --start 280 --threads 0 ...   # main
  29394   33   ...multiprocessing-fork                               # worker 1
  29400   33   ...multiprocessing-fork                               # worker 2
  ...                                                                # 10 in all
```

The ten workers are running at a third of a core each — they are starved, not
saturated. `lddecode/parallel.py` explains why: block demodulation is farmed out
to the pool and prefetched, but *the decode loop that consumes those blocks is
strictly in-order on the main thread*. That serial loop is the 1.8 cores in the
first row, and it cannot ask for blocks fast enough to keep ten workers busy.
ld-decode's own auto-threads formula already knows this and caps the pool at
ten, "diminishing returns past that on the shared read path".

It is not I/O either. Decoding from the NFS library reads at about 4 MB/s over a
10Gb link, and system-wide iowait sits at 0.1%.

So the spare cores are only reachable by running more than one decode. `--jobs`
does that:

```sh
./decode-ggv.sh --frames all -j 2       # both discs at once
```

Two full decodes together take about as long as the longer one alone, instead of
the sum of the two. Roughly three concurrent decodes will use a 16-core host.

With `-j` above 1:

* **Starts are resolved for every disc first, serially,** before any decode
  starts. The start search runs short ld-decode probe decodes of its own, so
  running those concurrently would only make them contend for the cores the real
  decodes are about to want — and resolving up front means a missing source or
  an existing output is reported in seconds rather than after hours of decoding.
* **`--threads` auto is divided between the jobs** rather than claimed in full
  by each: `clamp(max(ncpu - 2, 1) / jobs, 1, 10)`, so `-j 2` on 16 cores gives 7
  workers per decode. Since a decode's workers are bounded by its serial loop
  rather than by their own number, a smaller pool per decode still keeps up. At
  `-j 1` the choice is left to ld-decode (`--threads 0`), so its own formula
  stays authoritative for the single-decode case. An explicit `-t N` is always
  used exactly as given. `-j` is first clamped to the number of discs selected,
  so the budget is never split more ways than there are decodes to run.
* **Console progress is prefixed with the disc id**, since the decodes
  interleave.

A failing decode does not take the others with it. Each disc's exit status is
recorded separately, the discs that succeed are still finished and renamed, and
the run ends by naming the ones that failed:

```
decode-ggv.sh: decode failed for: GGV1069 (see each disc's .log)
```

### Following a long decode

ld-decode writes a timestamped, line-oriented log of its own beside each decode,
at `<basename>.log`. That is the thing to follow:

```sh
tail -f "/home/sdi/raid/decodes/domesday-decode-script/GGV1011/ld-decode-3caccf0/GGV1011_….log"
```

ld-decode has no non-interactive output mode — it draws progress with carriage
returns and no newlines whatever it is writing to, so redirecting its console
output to a file gives one enormous line that `tail`, `grep` and `less` are all
useless on. `decode-ggv.sh` therefore passes that stream through unchanged on a
terminal, where redrawing in place is what you want, and splits it into lines
when stdout is not a terminal:

```sh
./decode-ggv.sh --frames 1000 > decode.log 2>&1   # decode.log is line-oriented
```

## Notes

`ld-decode` wraps its own `ffmpeg` and `flac` onto `PATH` at runtime, and this
flake takes `nixpkgs` from the ld-decode flake rather than pinning a second
copy, so the whole environment is built from a single nixpkgs revision.

The C++ `ld-decode-tools` (`ld-chroma-decoder`, `ld-dropout-correct`,
`ld-export-metadata`, …) are *not* built by the ld-decode flake and so are not
available here yet.
