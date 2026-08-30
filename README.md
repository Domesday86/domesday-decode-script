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
./decode-ggv.sh --list
```

Output goes to `<output root>/<disc id>/<capture basename>.*`, e.g.
`/home/sdi/raid/decodes/domesday-decode-script/GGV1069/Pioneer GGV1069_….cvbs`.

### Configuration

Both roots, the frame limit and everything else are configurable by flag or by
environment variable:

| Flag | Variable | Default | Meaning |
| --- | --- | --- | --- |
| `-l, --library` | `DD_LIBRARY` | `/home/sdi/raid/library` | capture library root |
| `-o, --output` | `DD_OUTPUT` | `/home/sdi/raid/decodes/domesday-decode-script` | decode output root |
| `-f, --frames` | `DD_FRAMES` | `1000` | frames per disc, or `all` |
| `--lead-in` | `DD_LEAD_IN` | `1` | frames of lead-in to keep before CAV #1 |
| `--probe` | `DD_PROBE` | `800` | first frame the start search probes |
| `-t, --threads` | `DD_THREADS` | `0` (auto) | ld-decode worker threads |
| `--tbc` | `DD_CVBS=0` | CVBS | write `.tbc` instead of CVBS |

Disc source paths in the table are relative to the library root, so pointing
`--library` at another copy of the library is all that is needed to decode from
somewhere else.

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

Decodes are CVBS (`--cvbs`): `<basename>.cvbs` (u16le, 4fsc) plus the `.meta`
SQLite sidecar, `_audio_0.wav`, and the `.dropouts.meta` / `.efm` / `.efm.meta`
extension sidecars. Pass `--tbc` for the older `.tbc` output.

ld-decode currently names the video output `<basename>.composite`, but the
required name is `<basename>.cvbs`, so `decode-ggv.sh` renames it after each
decode. Nothing refers to the file by name — the `.meta` sidecar records a
`signal_type`, not a filename — so the rename is all that is needed, with no
sidecar to keep in step. Drop this step once ld-decode writes `.cvbs` itself.

The sample encoding is `CVBS_U16_4FSC`: 10-bit codes clamped to 4–1019 and
stored `<< 6` in 16-bit containers. `CVBS_U10_4FSC` is permitted by the `.meta`
schema but ld-decode hardcodes the U16 preset and offers no switch for it.

### Following a long decode

ld-decode writes a timestamped, line-oriented log of its own beside each decode,
at `<basename>.log`. That is the thing to follow:

```sh
tail -f "/home/sdi/raid/decodes/domesday-decode-script/GGV1011/GGV1011_….log"
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
