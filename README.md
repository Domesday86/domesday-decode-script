# domesday-decode-script

Scripts for automatically decoding the BBC Domesday, Volcanoes and EcoDisc
AIV LaserDisc sets, and the GGV calibration discs, through
[ld-decode](https://github.com/happycube/ld-decode).

## Environment

The toolchain is provided by a Nix flake, so the exact `ld-decode` build used
for a decode is pinned and reproducible. It tracks the `8.0.0dev` (rev8)
branch of [ld-decode](https://github.com/happycube/ld-decode/tree/8.0.0dev).

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
| `ld-decode` | Decode a raw RF capture to `.cvbs` (or `.tbc` with `--tbc`) |
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

The decode is named after the capture, minus its `.ldf` and with spaces turned
into dashes, so nothing downstream has to quote it:

```
Pioneer GGV1069_CAV_NTSC_side1_dup1_2019-09-12_21-11-38.ldf   # capture
Pioneer-GGV1069_CAV_NTSC_side1_dup1_2019-09-12_21-11-38.cvbs  # decode
```

The captures in the library keep their own names; only the decode is renamed.

### Configuration

Both roots, the frame limit and everything else are configurable by flag or by
environment variable:

| Flag | Variable | Default | Meaning |
| --- | --- | --- | --- |
| `-l, --library` | `DD_LIBRARY` | `/Volumes/Domesday86_Library` | capture library root |
| `-o, --output` | `DD_OUTPUT` | `/Volumes/Domesday86_Decodes/domesday-decode-script` | decode output root |
| `--decoder` | `DD_DECODER` | from `flake.lock` | decoder directory name |
| `--no-verify-decoder` | `DD_VERIFY_DECODER=0` | check | skip the ld-decode/`flake.lock` check |
| `-f, --frames` | `DD_FRAMES` | `1000` | frames per disc, or `all` |
| `--lead-in` | `DD_LEAD_IN` | `1` | frames of lead-in to keep before CAV #1 |
| `--probe` | `DD_PROBE` | `800` | first frame the start search probes |
| `-j, --jobs` | `DD_JOBS` | `1` | discs decoded concurrently |
| `-t, --threads` | `DD_THREADS` | `0` (auto) | ld-decode worker threads per decode; auto aims for 4 each |
| `--tbc` | `DD_CVBS=0` | CVBS | write `.tbc` instead of CVBS |
| `--efm` | `DD_EFM=1` | off on CLV | decode EFM on CLV sides too |

Disc source paths in the table are relative to the library root, so pointing
`--library` at another copy of the library is all that is needed to decode from
somewhere else.

## Decoding the Domesday discs

`decode-domesday.sh` decodes the twelve PAL Domesday disc sets. Each set is two
double-sided discs — the Community disc carries **North** and **South**, the
National disc carries **A** and **B** — so 12 sets × 4 sides. Three sides of
every set are CAV; **National B is CLV**.

```sh
nix develop
./decode-domesday.sh --list                       # what is in the table
./decode-domesday.sh -f 2 DS1                     # quick smoke test of one set
./decode-domesday.sh DS1                          # set 1, first 1000 frames a side
./decode-domesday.sh --frames all DS1:NationalB   # one side in full
./decode-domesday.sh --frames all NB -j 3         # every National B, three at a time
./decode-domesday.sh --frames all -j 3            # the whole library
```

`--frames` is the switch to reach for while testing: it defaults to **1000
frames** a side, and `--frames all` decodes the whole side. Everything else —
the start search, the output layout, the decoder check — behaves identically
either way, so a 1000-frame run is a faithful rehearsal of a full one.

### Choosing what to decode

A selector picks sides, and selectors add together:

| Selector | Means |
| --- | --- |
| *(none)* | every side of every set — 49 decodes |
| `DS4` | every side of disc set 4 |
| `DS4:NationalA` | one side of one set |
| `NationalB` | that side of every set |
| `NB` | the same, by short name (`CN` `CS` `NA` `NB`) |

`--side` narrows whatever the selectors chose rather than adding to it, so
`--side NB DS4 DS7` and `DS4:NB DS7:NB` are the same request. Set and side names
are matched regardless of case, and naming a side twice still decodes it once.

The sides come out in table order — set by set, and within a set North, South,
A, B — however the selectors were written.

### Sides captured in more than one pass

A side the player could not read in one pass was captured in several, and each
part is a decode in its own right, so a set can have more than four decodes.
`DS1`'s National A is the one such side in the library: the player lost the disc
at picture 37480 and a second pass picks up at 39001.

Both parts are selected together — `DS1:NationalA` means the whole side — and
`--list` numbers them:

```
$ ./decode-domesday.sh --list DS1
DS1:CommunityNorth       CAV  picture #1      …_CommunityNorth_20191014_CAV_PAL_00001-54000.ldf
DS1:CommunitySouth       CAV  picture #1      …_CommunitySouth_20191014_CAV_PAL_00001-54000.ldf
DS1:NationalA part 1/2   CAV  picture #1      …_NationalA_PP_20191014_CAV_PAL_00001-37480.ldf
DS1:NationalA part 2/2   CAV  picture #39001  …_NationalA_PP_20191014_CAV_PAL_39000-54000.ldf
DS1:NationalB            CLV  picture #1      …_NationalB_PP_20191014_CLV_PAL_00-60.ldf
```

Part 2 begins at the very head of its capture, and the first frame ld-decode's
CVBS writer will accept there is three frames in (see [Keeping the lead-in in
the output](#keeping-the-lead-in-in-the-output)). A very short `--frames` never
reaches it, and ld-decode then exits cleanly having written an empty file — so
the scripts treat an empty video file as a failed decode and say so:

```
$ ./decode-domesday.sh -f 2 DS1:NationalA
ld-decode wrote an empty …_39000-54000.cvbs: its writer never reached a frame it
could open the file on. This side's output opens later than --frames 2 reaches;
decode more frames.
```

Anything from `-f 10` up is clear of it, and the 1000-frame default is well
clear.

The "picture #" column is what the start search converges on — the first frame
of that capture's content. It is 1 for a capture that begins at the head of the
side, and the part's own first picture for one that picks up mid-disc. That
number cannot be taken from the filename's frame range: the range on part 2
reads `39000-54000`, but its first picture is 39001, and a search told to find
39000 never lands on it. It is in the table instead.

### Output layout

Decodes go to `<output>/<set>/<decoder>/<capture basename>.*`:

```
/Volumes/Domesday86_Decodes/domesday-decode-script/
└── DS1/
    └── ld-decode-12be078/
        ├── Domesday_DD86-DS1_CommunityNorth_20191014_CAV_PAL_00001-54000.cvbs
        ├── Domesday_DD86-DS1_CommunityNorth_20191014_CAV_PAL_00001-54000.start
        ├── Domesday_DD86-DS1_NationalA_PP_20191014_CAV_PAL_00001-37480.cvbs
        ├── Domesday_DD86-DS1_NationalA_PP_20191014_CAV_PAL_39000-54000.cvbs
        └── decoder.txt
```

The capture basename already names the set and the side, and both parts of a
split side keep their own frame ranges, so nothing collides.

### Flags

`decode-domesday.sh` takes the same flags and environment variables as
`decode-ggv.sh` — see [Configuration](#configuration) — with `--side` added and
`--frames` defaulting to 1000. `--start N` still applies to a single capture, so
the selectors have to choose exactly one. It also passes
`--V4300D_coherent_subtract` on every side — see [Player spur
removal](#player-spur-removal) — and `--noEFM` on the CLV ones — see [EFM and the
National B sides](#efm-and-the-national-b-sides).

### EFM and the National B sides

**National B carries no EFM**, and it is the only CLV side in every set, so the
EFM front end is switched off on exactly the CLV sides:

```
ld-decode --pal --noEFM --cvbs --V4300D_coherent_subtract ...   # National B
ld-decode --pal --cvbs --V4300D_coherent_subtract ...           # the CAV sides
```

Run against a side that has none, the front end spends its time demodulating
noise and writes it out: the DS1 National B decode made before this was switched
off carries a 1.4GB `.efm` of nothing. The CAV sides do carry EFM and keep it.

This is the one place the table's CAV/CLV column reaches the decoder. It does
not steer the demodulator — ld-decode reads CAV or CLV out of the VBI itself —
but what is recorded on a side is a fact about that side, and within this
library CLV means National B means no EFM. `--efm` (`DD_EFM=1`) forces it back
on, for checking that claim on a side or for a CLV capture that does carry EFM.

Decodes made before this land under their own decoder directory and still have
their `.efm` files; nothing already decoded changes.

### Player spur removal

Every Domesday side is decoded with `--V4300D_coherent_subtract`. The whole
library was captured on an LD-V4300D, whose ~8.5MHz spur is therefore in the RF
of every side of every set, so the flag is passed unconditionally rather than
per set. Rather than notching the spur's FFT bin, it estimates the tone and
subtracts it in the time domain, which takes the spur's spectral-leakage skirts
and the clock's satellites with it instead of leaving a hole around them. It is
PAL-only, which the whole Domesday library is; `decode-ggv.sh` does not pass it,
since the calibration discs are NTSC.

Parallel demodulation stays available with it: on the pinned build the filter's
own no-video guard makes it safe from the first block, so it no longer defers
until sync acquisition and no longer forces serial demod. `--V4300D_no_defer`,
which used to control that, is obsolete on this build — accepted and ignored.
`--V4300D_notch_filter` is now a legacy alias for the same coherent subtract
rather than the older FFT-bin notch.

Nothing already in the output tree carries the spur subtraction: the decodes
under `ld-decode-12be078` and `ld-decode-8596be3` were made before the flag was
passed. Decodes made from here land under the newly pinned commit's own
directory, so they sit beside those rather than on top of them.

### Start points

Starts are resolved by `find-disc-start.sh`, the same helper the calibration
discs use, and cached beside the decode as `<basename>.start`. Nothing is taken
from the `--start` values in the library's `Domesday_AIV_DiscSet_Notes.txt`;
those are recorded by hand against a different ld-decode and are not what this
build wants.

The 49 starts are resolved before any decode begins, and at the same `--jobs`
concurrency as the decodes — unlike `decode-ggv.sh`, which resolves its two
serially. A start search is several short ld-decode probes that spend most of
their wall clock seeking into the `.ldf` rather than working, so run one at a
time the whole library takes well over an hour before the first frame is
decoded. Nothing is contended for: the resolve phase finishes before any decode
is launched.

## Decoding the Volcanoes disc

`decode-volcanoes.sh` decodes the PAL BBC AIV **Volcanoes** disc (BBC, 1988).

Volcanoes is **single-sided**: the second side carries no content, so a disc set
here is one capture rather than the four a Domesday set holds. The library has
three sets — three independent captures of the same disc, made between 2019 and
2022 — and each is decoded in its own right, so they can be compared against
each other or combined.

```sh
nix develop
./decode-volcanoes.sh                  # all three sets, first 1000 frames each
./decode-volcanoes.sh --frames 2       # quick smoke test
./decode-volcanoes.sh --frames all DS3 # one set in full
./decode-volcanoes.sh --frames all -j 2   # all three, two at a time
./decode-volcanoes.sh --list
```

Sets are named `DS1`, `DS2` and `DS3`, matched regardless of case. With none
named, all three are decoded. Output goes to
`<output root>/<set>/<decoder>/<capture basename>.*`, with the output root
defaulting to `/Volumes/Domesday86_Decodes/volcanoes-decode-script`.

### What the script asserts

Every capture is PAL CAV, was made on an LD-V4300D, and carries EFM digital
audio. Those are facts about the disc and the captures rather than choices, so
they are asserted in the script instead of offered as flags:

```sh
ld-decode --pal --cvbs --V4300D_coherent_subtract ...
```

EFM is therefore decoded on every set — Volcanoes is a CAV AIV disc and the
front end has something real to read. The Domesday **National B** sides are the
one place in this library where it is switched off, because they are CLV and
carry none; see [EFM and the National B
sides](#efm-and-the-national-b-sides). Player spur removal is the same coherent
subtraction the Domesday sides get, for the same reason — see [Player spur
removal](#player-spur-removal).

The table carries a "first picture" column that is `1` for all three captures,
each of which begins at the head of the side. It exists for a side the player
lost and had to be captured in more than one pass, whose later part picks up
mid-disc; the Domesday library has one such side, and this one has none.

Everything else — the two roots, the frame limit, lead-in, probe, jobs and
threads — works exactly as it does for the other two scripts, by the same flags
and the same `DD_*` environment variables, with `DD_OUTPUT` defaulting to the
Volcanoes output root. Starts are resolved by the shared `find-disc-start.sh`,
in parallel at the `--jobs` concurrency, and cached beside the decode as
`<basename>.start`. Nothing is taken from the `--start` values recorded by hand
in the library's `Volcanoes_Notes.txt`; those were made against a different
ld-decode and are not what this build wants.

## Decoding the EcoDisc disc

`decode-ecodisc.sh` decodes the PAL BBC AIV **EcoDisc** (BBC, 1987), an
interactive videodisc about Slapton Ley, a nature reserve in South Devon.

EcoDisc was first pressed **single-sided** and later reissued **double-sided**,
the new second side carrying a linear documentary about the reserve. The library
holds five sets: four are the double-sided pressing, and **DS2 is a copy of the
original single-sided one**, so it has a first side and nothing else. That makes
**nine captures across the five sets, not ten** — `Side2` selects four sides
rather than five, and `DS2:Side2` is an error rather than an omission.

```sh
nix develop
./decode-ecodisc.sh                       # all nine captures, first 1000 frames each
./decode-ecodisc.sh --frames 2            # quick smoke test
./decode-ecodisc.sh --frames all DS1:Side2  # one side in full
./decode-ecodisc.sh --frames all S1 -j 2  # every first side, two at a time
./decode-ecodisc.sh --frames all -j 2     # the whole disc, two at a time
./decode-ecodisc.sh --list
```

Selectors work as they do for Domesday: `DS4` is every side of a set,
`DS4:Side2` one side of one set, `Side2` (or `S2`) that side of every set that
has one, and they add together. `--side` narrows whatever the selectors chose.
Set and side names are matched regardless of case. Output goes to
`<output root>/<set>/<decoder>/<capture basename>.*`, with the output root
defaulting to `/Volumes/Domesday86_Decodes/ecodisc-decode-script`.

### Both sides are CAV

Both sides are **CAV**, including the second. The documentary runs about 35,500
frames, comfortably inside the 54,000 a CAV side holds, so it never needed CLV.
This is worth stating because two things suggest otherwise and both are wrong:

- Some second-side captures are **named** `...CAV_PAL_00001-54000.ldf`, after
  the *first* side's frame range. That is a copying slip in the library — the
  captures end where the side does, around frame 35,500. Nothing in the script
  reads a format or a length out of a filename.
- A short documentary side is the kind of thing that is often CLV.

What settles it is the VBI. `ld-decode` reads the format from the disc itself,
and probes right across a second-side capture return CAV picture numbers
counting up continuously at a constant file-frame offset — 327 on DS1, matching
the `--start 327` recorded by hand in `EcoDisc_Notes.txt`.

### EFM

The first sides carry EFM digital audio and the second sides do not, so the EFM
front end runs on the first sides only. On the Domesday sets the same question
is answered by the format column — EFM is absent exactly on the CLV National B
sides — but that shortcut does not work here: **both EcoDisc sides are CAV and
they still differ.** So the side table carries an explicit `efm` column, and it
is the only thing that decides whether the front end runs.

Each cell was measured rather than assumed. `ld-decode`'s own
`lddecode.efm_score` scores the T-value stream written to `.efm` for frame sync:
real EFM frames up at 588 channel bits between T11–T11 sync pairs, with the
demodulator reporting near-full confidence. Against known controls — a Volcanoes
first side that has EFM, and a Domesday National B that has none — the
separation is unambiguous:

| Capture | sync rate | frame-588 | demod confidence |
| --- | --- | --- | --- |
| Volcanoes DS1 Side1 (has EFM) | 1.000 | 1.000 | 249 / 255 |
| EcoDisc DS1 **Side1**, frames 6000–8000 | 1.000 | 1.000 | 243–245 |
| EcoDisc DS1 **Side1**, elsewhere | 0.000 | 0.000 | ~33 |
| EcoDisc DS1 **Side2**, 35 probes, frames 1000–35000 | 0.000 | 0.000 | ~35 |
| EcoDisc DS5 **Side2**, 13 probes, frames 1000–34000 | 0.000 | 0.000 | ~35 |
| Domesday DS1 National B (has none) | 0.000 | 0.000 | ~33 |

Two things are worth taking from that table. The first is that EFM on these
discs is **localised**: EcoDisc's first-side EFM occupies roughly frames
6,000–8,000 and nothing else, and on Volcanoes it sits in the last tenth of the
side. A sparse scan can miss it entirely — ten probes across the first side hit
it only once. The second is that a section that wide cannot hide from probes
spaced 1,000–2,000 frames apart, which is what the second-side scans used. Two
independent second-side captures, 48 probes between them, returned no syncs at
all.

Byte statistics do **not** settle this. The raw T-value stream from a side with
no EFM has much the same entropy and much the same distribution as one from a
side that has it, because the demodulator emits plausible run lengths either
way: the known-EFM-free National B control scores 3.79 bits/byte against
Volcanoes' 3.50. Only frame sync separates them.

`--efm` and `--no-efm` override the table for every selected side, which is how
its answer can be re-checked later — the same job `DD_EFM` does, which takes
`1`, `0`, or empty to leave the table alone.

### What the script asserts

Every capture is PAL, is CAV, and was made on an LD-V4300D. Those are facts
about the disc and the captures rather than choices, so they are asserted in the
script instead of offered as flags:

```sh
ld-decode --pal --cvbs --V4300D_coherent_subtract [--noEFM] ...
```

`--noEFM` appears for the second sides only, per the `efm` column above. Player
spur removal is the same coherent subtraction the Domesday and Volcanoes sides
get, for the same reason — all five sets came off an LD-V4300D; see [Player spur
removal](#player-spur-removal). The disc format is deliberately *not* passed:
`ld-decode` reads CAV or CLV from the VBI itself, and the table's format column
records what it will find rather than telling it.

The table also carries a "first picture" column that is `1` for all nine
captures, each of which begins at the head of its side. It exists for a side the
player lost and had to be captured in more than one pass, whose later part picks
up mid-disc; the Domesday library has one such side, and this one has none.

Everything else — the two roots, the frame limit, lead-in, probe, jobs and
threads — works exactly as it does for the other scripts, by the same flags and
the same `DD_*` environment variables, with `DD_OUTPUT` defaulting to the
EcoDisc output root. Starts are resolved by the shared `find-disc-start.sh`, in
parallel at the `--jobs` concurrency, and cached beside the decode as
`<basename>.start`. Nothing is taken from the `--start` values recorded by hand
in the library's `EcoDisc_Notes.txt`; those were made against a different
ld-decode and are not what this build wants, though they agree closely enough to
be a useful sanity check.

## How the decodes work

The rest of this applies to all four scripts: they share
`find-disc-start.sh`, the decoder check, the output format and the
concurrency machinery.

### Which ld-decode made a decode

These are pre-release branch builds, and two of them do not agree frame for
frame — so a decode is only meaningful alongside the ld-decode that produced it.
Decodes are therefore filed under the pinned commit:

```
/Volumes/Domesday86_Decodes/domesday-decode-script/
└── GGV1011/
    ├── ld-decode-634a128/          # 8.0.0dev
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
    flake.lock:    /nix/store/b4b6k8ps…-python3.12-ld-decode-7.2.0
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
decoder:  ld-decode-12be078 (from flake.lock)
binary:   /nix/store/b4b6k8ps…-python3.12-ld-decode-7.2.0/bin/ld-decode
version:  7.2.0+git.12be078
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
settled playback (`--probe`, default file frame 800), read the picture number
there, and compute where the target frame must be. A capture-relative file frame
is a nominal-length approximation, so the file-frame to picture-number offset
drifts slightly across the disc — on GGV1011 it is 229 at file frame 800 but 225
at file frame 226 — and the estimate is therefore re-probed until it lands on
picture #1 exactly. Both calibration discs converge in three probes, about 20
seconds:

```
$ ./find-disc-start.sh --pal -v GGV1011_….ldf
probe 1: start 800 (offset 0) -> 800 571;801 572
probe 2: start 228 (offset 0) -> 228 3;229 4 230 5
probe 3: start 224 (offset 0) -> 224 leadin;226 1
converged after 3 probe(s)
226
```

Each probe reports every reading it trusted, and the search takes the target
from anywhere in that window rather than only from its head — so a window that
straddles the answer converges there instead of going round again.

**CAV and CLV are both handled**, which is what National B needs. ld-decode
reports a picture number either way: on CAV it is the VBI address, and on CLV it
derives one from the timecode, printed after it.

```
File Frame 801: CAV Frame #39801
File Frame 205: CLV Timecode 0:00.02 Frame #2
File Frame 203: CAV Lead In
```

Both count up by one a frame, which is all the arithmetic needs. Lead-in carries
no format — nothing has been decoded yet to tell CAV from CLV — so it is
reported as `CAV Lead In` even at the head of a CLV capture, and is matched
under either label. A pre-1985 *early CLV* disc, whose timecode carries only the
minute, yields no picture number at all; none of these discs is one, and the
search reports that it found none rather than guessing.

Three guards keep it from repeating ld-find-start's mistake:

* A probe reading is only trusted when two successive frames advance together
  (file frame *n*→*n*+1 alongside picture *m*→*m*+1). A lone address in a
  spin-up region can be a misread, and it is that kind of misread that sends the
  arithmetic to the wrong part of the disc.
* An estimate landing before the head of the capture means the probe was itself
  inside spin-up, so the search moves deeper rather than clamping to zero and
  inventing an answer. It recovers from a badly chosen `--probe` this way, and
  gives up with a diagnostic rather than guessing if it cannot.
* **The seek offset is measured, not assumed.** The file frame a run reports
  first is not a fixed distance from the `--start` it was given: on the
  calibration discs `--start 800` reports file frame 800, and on the Domesday
  captures the same start reports 801. Aiming a start at a frame therefore reads
  that offset back out of the probe (the `offset` in the trace above) instead of
  taking it as a constant — otherwise the search re-probes the same spot until it
  gives up, or lands a frame short and keeps no lead-in.

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
lead-in trial: start 225 -> writer skipped ahead to file frame 227
lead-in trial: start 224 -> writer skipped ahead to file frame 227
lead-in trial: start 223 -> writer skipped ahead to file frame 227
lead-in trial: start 222 -> output opens at file frame 222 (accepted)
```

The output therefore opens with *at least* the requested lead-in, not exactly it:

| Disc | picture #1 at file frame | `--start` | output opens at | frames before picture #1 |
| --- | --- | --- | --- | --- |
| GGV1011 (PAL) | 226 | 222 | 222 | 4 |
| GGV1069 (NTSC) | 283 | 280 | 280 | 3 |
| DS1 National B (CLV) | 207 | 203 | 204 | 3 |

Where the output opens is measured, not inferred from the start: it is the start
that ld-decode is told, and the opening frame that says what the writer did with
it. `--report` prints both, as `opens=`.

**A capture that begins mid-disc may have no aligned frame at or before its
first picture at all.** `DS1`'s National A part 2 starts at picture 39001, and
the first frame its writer will accept is file frame 4 — picture 39004. No start
can write the three frames in front of it, from any `--start`, so the search
takes the earliest-opening start and says what that costs rather than failing:

```
start 0 opens the output at file frame 4, which is 3 frame(s) after picture
#39001: the frames before it are off the colour sequence and no start can
write them
```

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
extension sidecars. Pass `--tbc` for the older `.tbc` / `.tbc.db` output. ld-decode
writes the `.cvbs` name itself, so nothing here renames it. Earlier branch builds
called it `.composite`; a decode is recognised under either name, so an existing
decode is still found whichever build made it.

CVBS is ld-decode's own default on the pinned build, but the scripts pass
`--cvbs` or `--tbc` explicitly all the same. The default flipped once already —
`.tbc` was what a bare `ld-decode` wrote on earlier builds — and the extension
the script looks for afterwards follows the flag, so a decode made under a
flipped default would be reported as having written no video file after the
hours it took to make.

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

Ten is still too many. Sweeping the pool on a single PAL decode puts the peak at
**four** workers, and the curve turns down past it rather than levelling off:

| workers | FPS | CPU busy |
| --- | --- | --- |
| 2 | 4.07 | 20% |
| **4** | **5.42** | 32% |
| 6 | 5.32 | 34% |
| 8 | 5.16 | 36% |
| 10 (ld-decode's own choice) | 5.03 | 38% |

So ld-decode's ten is 7% slower than four while drawing 20% more CPU, and two is
genuinely starved. It is not I/O: decoding from the NFS library reads at about
4 MB/s over a 10Gb link, and system-wide iowait stays under 0.5%.

The spare cores are only reachable by running more than one decode. `--jobs`
does that:

```sh
./decode-ggv.sh --frames all -j 2       # both discs at once
```

A second decode pays; a third does not. Timed on three National A sides at
`-t 4`:

| arrangement | wall | CPU busy |
| --- | --- | --- |
| two sides, one after the other | 377.6 s | ~32% |
| **two sides, `-j 2`** | **347.8 s** | 66% |
| three sides, one after the other | 553.4 s | ~32% |
| three sides, `-j 3` | 555.3 s | 90% |

`-j 2` finishes **8.6% ahead**. `-j 3` finishes level, having spent 90% of the
host to do it — so the ceiling sits at about two decodes' worth of work, and it
is shared between the decodes rather than private to each. Memory bandwidth is
the leading suspect; it has not been measured directly.
[docs/performance.md](docs/performance.md) has the numbers.

So `-j 2` is worth reaching for on both counts: a little more throughput, and
every side advancing, so a side that crawls through damaged media does not hold
up the queue behind it. Past two it is only the second of those.

With `-j` above 1:

* **Starts are resolved for every disc first,** before any decode starts, so a
  missing source or an existing output is reported in seconds rather than after
  hours of decoding. `decode-ggv.sh` resolves its two serially;
  `decode-domesday.sh` resolves at the same `-j` concurrency, because with 49
  sides to get through the serial version costs over an hour before the first
  frame is decoded. Either way nothing is contended for: the resolve phase
  finishes before any decode is launched.
* **`--threads` auto aims for four workers per decode** and divides the host
  between the jobs rather than letting each claim it in full:
  `clamp(max(ncpu - 2, 1) / jobs, 1, 4)`, so 16 cores gives 4 workers each at
  `-j 1`, `-j 2` and `-j 3`, 3 at `-j 4`. Four is the peak of the measured curve
  above, and past it throughput falls, so a larger pool is not merely idle — it
  is slower. Unlike the earlier formula this applies at `-j 1` too, in place of
  ld-decode's own choice of ten. The target is `DD_THREADS_TARGET` if you want
  to move it. An explicit `-t N` is always used exactly as given. `-j` is first
  clamped to the number of discs selected, so the budget is never split more
  ways than there are decodes to run.
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
tail -f "/Volumes/Domesday86_Decodes/domesday-decode-script/GGV1011/ld-decode-634a128/GGV1011_….log"
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
