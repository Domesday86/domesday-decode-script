# domesday-decode-script

Scripts for automatically decoding the BBC Domesday, Volcanoes, EcoDisc, City
and Countryside AIV LaserDisc sets, and the North Polar Expedition disc, through
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

`ffmpeg`, `flac` and `shellcheck` are in the shell too, along with the tools
that turn decodes into a VP415e pack (see [Building a VP415e
pack](#building-a-vp415e-pack)):

| Command | From | Purpose |
| --- | --- | --- |
| `orc-cli` | [decode-orc](https://github.com/simoninns/decode-orc) | Map, align and stack decodes; EFM images; the `.mkv` |
| `vfs-stacker`, `vfs-verifier` | [vfs-verifier](https://github.com/Domesday86/vfs-verifier) | Stack and check the VFS data images |
| `sqlite3`, `yq` | nixpkgs | Read `.meta` databases and the disc metadata YAML |

With [direnv](https://direnv.net/) installed, `direnv allow` enters the shell
automatically on `cd`.

### Run ld-decode without entering the shell

```sh
nix run . -- --pal --start 310 capture.ldf output-basename
```

### Updating the pinned tools

```sh
nix flake update ld-decode
nix flake update decode-orc vfs-verifier
```

decode-orc and vfs-verifier are pinned at whatever their `main` was when they
were last updated.

decode-orc is built with the fixes in `patches/decode-orc-*.patch` that its
pinned revision does not have yet. Each patch says what it fixes. Remove one
from `flake.nix` once an update brings its fix. Today there are none. The
last, `decode-orc-efm-sync.patch` (the EFM sink crashing in data mode on
macOS), went when decode-orc `4d54969` brought its fix. A patch is part of the stamp of every stage that runs decode-orc, so adding,
changing or removing one rebuilds those stages. A new patch file must be
`git add`ed before Nix can see it.

`flake.lock` is committed; commit it again after updating so decodes stay
reproducible.

## Configuration

Every script takes the same core flags and environment variables:

| Flag | Variable | Default | Meaning |
| --- | --- | --- | --- |
| `-l, --library` | `DD_LIBRARY` | from `shares.conf` | capture library root (a mount point) |
| | `DD_DECODES` | from `shares.conf` | decodes share root (a mount point) |
| | `DD_NO_MOUNT=1` | mount | check the shares but do not mount them |
| `-o, --output` | `DD_OUTPUT` | `$DD_DECODES/decode-script/<disc>` | decode output root; must be on the decodes share |
| `--decoder` | `DD_DECODER` | from `flake.lock` | decoder directory name |
| `--no-verify-decoder` | `DD_VERIFY_DECODER=0` | check | skip the ld-decode/`flake.lock` check |
| `-f, --frames` | `DD_FRAMES` | `1000` | frames per capture, or `all` |
| `--lead-in` | `DD_LEAD_IN` | `1` | frames of lead-in to keep before the first picture |
| `--probe` | `DD_PROBE` | `800` | first frame the start search probes |
| `--start` | | resolved | force the ld-decode `--start` frame (one capture only) |
| `--refresh-start` | | use cache | re-run the start search |
| `-j, --jobs` | `DD_JOBS` | `1` | captures decoded concurrently |
| `-t, --threads` | `DD_THREADS` | `0` (auto) | ld-decode worker threads per decode; auto aims for 4 each |
| `--tbc` | `DD_CVBS=0` | CVBS | write `.tbc` instead of CVBS |
| `--force` | | refuse | overwrite an existing decode |
| `--adopt` | | | the pack scripts only (Volcanoes, Community South, National A, Community North, EcoDisc, Countryside): check an existing decode and stamp it ([Checked and stamped decodes](#checked-and-stamped-decodes)) |
| `-n, --dry-run` | | | resolve starts and print the commands, decode nothing |
| `--list` | | | list what the selectors chose and exit |

The scripts for multi-sided discs add `--side`. The ones that switch the EFM
front end off anywhere add `--efm` (`DD_EFM=1`) to force it back on; each
disc's section below says which. `--help` on any script gives its full usage.

Source paths in the tables are relative to the library root, so decoding from
another copy of the library takes only pointing at it. Because the library is
checked as a share before anything reads it (see [The network
shares](#the-network-shares)), that copy is named in `shares.local.conf` rather
than with `--library` alone.

Every script's output root sits under one folder,
`/Users/Shared/Domesday86/Domesday86_Decodes/decode-script/`, in a subfolder named after the
script's disc or pack: `domesday`, `volcanoes`, `community-south`,
`national-a`, `community-north`, `ecodisc-side1`, `ecodisc-side2`, `city`, `countryside-side1`,
`countryside-side2`, `north-polar`, `dragons-lair`, `apple-almanac-side-a` and
`apple-almanac-side-b`.

Output goes to `<output root>/<set>/<decoder>/<capture basename>.*`, where
`<decoder>` names the ld-decode commit that produced the decode — see [Which
ld-decode made a decode](#which-ld-decode-made-a-decode). The decode is named
after the capture, minus its `.ldf` and with any spaces turned into dashes, so
nothing downstream has to quote it. The captures in the library keep their own
names; only the decode is renamed.

## The network shares

Every script reads from two shares and writes to one:

- **library**: the capture library. It is read-only, and nothing ever writes
  to it.
- **decodes**: everything the scripts produce, including their temporary and
  scratch files, which go in `decode-script/.work/` (the scripts point
  `TMPDIR` there).

Both platforms mount the shares over NFS from `10.0.1.4:/volume1/`. On macOS
they go under `/Users/Shared/Domesday86/`; on Linux, under `/home/sdi/raid/`.
`shares.conf` holds the mount points, sources and options, and a git-ignored
`shares.local.conf` overrides any of them for one host. Any SMB mounts of the
same shares under `/Volumes` are ignored, since a share is identified by its
mount source rather than by its path.

macOS lets only root make an NFS mount, so on a Mac the shares are mounted
once after each boot with:

```sh
sudo ./mac-nfs-mount.sh             # library and sftp read-only, decodes read-write
sudo ./mac-nfs-mount.sh --unmount
```

The library is mounted read-only, so the rule that it is never written holds
at the mount as well as in the scripts. The SFTP upload share is mounted
beside it; no script reads it.

Before doing anything else, every script checks that each share it uses:

1. is a mount;
2. is the right mount (the configured source and type, so the share mounted somewhere else, or another share at its path, is caught);
3. answers within a timeout (a hung NFS mount fails in seconds);
4. holds the right content (a capture from `sources.sha256` at its recorded
   size; a `.domesday86-decodes` marker at the root of the decodes share);
5. allows the access needed (the library readable, decodes writable).

A script that finds a share missing does not call sudo. On macOS it names
`mac-nfs-mount.sh`. On Linux it brings up a mount the host already defines, and
otherwise prints the `sudo mount` command. Every output path is checked too: one that is not on the
decodes share, or is in the library, is refused.

```sh
./mount-shares.sh                # check both (and, on Linux, mount what is missing)
./mount-shares.sh --check        # check only
./mount-shares.sh --mark-decodes # once, on a new decodes share: write its marker
tests/shares-test.sh             # (macOS) check the refusals, against a scratch disk image
```

## Verifying the source captures

`sources.sha256` fingerprints every capture the scripts decode — 84 of them —
by its exact size in bytes and the SHA-256 of its **first 16 MiB**. Each line is
keyed by the capture's path relative to the library root, spelled exactly as in
the scripts' tables, so a line says both what a capture is and where the scripts
expect it. `verify-sources.sh` checks against it:

```sh
./verify-sources.sh                  # every capture, in about a minute
./verify-sources.sh Countryside DS1_ # only paths containing one of these
```

```
OK       BBC_AIV/North_Polar_Expedition/NPE_DS1/North_Polar_Expedition_DD86-DS1_Side1_20210103_CAV_PAL_00001-51437.ldf
MISSING  BBC_AIV/Volcanoes/Volcanoes_DS2/Volcanoes_DD86-DS2_Side1_20200126_CAV_PAL_00001-54000.ldf
SIZE     BBC_AIV/City_Disc/… (1 bytes, expected 42148664852)

1 ok, 2 failed
```

If a capture has been renamed or moved, `--identify` fingerprints it wherever
it is and names the capture it is, which is the table entry to update:

```sh
$ ./verify-sources.sh --identify /somewhere/else/renamed.ldf
/somewhere/else/renamed.ldf: is BBC_AIV/North_Polar_Expedition/NPE_DS2/North_Polar_Expedition_DD86-DS2_Side1_20210103_CAV_PAL_00001-54348.ldf
```

A file whose head matches but whose size does not is reported as an incomplete
or altered copy, and one that matches nothing is not a capture these scripts
were written against, whatever it is called.

This is a verification, not a full checksum. Hashing the whole of every capture
means reading 4.67 TB back from the capture store, the best part of a day at the
~95 MB/s it serves; the heads are read in under a minute. The head hash tells
the captures apart — each is FLAC-compressed RF of a different disc or pass, and
`--generate` refuses to write a file in which any two share a fingerprint — and
the size catches a copy that stopped short. What it will not catch is damage
inside a file that leaves its size unchanged.

`./verify-sources.sh --generate` rewrites `sources.sha256` from the paths in the
decode scripts' tables, so a capture added to a table cannot be left out.

## Decoding the Domesday discs

`decode-domesday.sh` decodes the twelve PAL Domesday disc sets. Each set is two
double-sided discs — the Community disc carries **North** and **South**, the
National disc carries **A** and **B**. Three sides of every set are CAV;
**National B is CLV**.

Each VP415e pack has its own decode script, which stamps its decodes for
`build-pack.sh`. **Community South**, **National A** and **Community North**
have one each, `decode-community-south.sh`, `decode-national-a.sh` and
`decode-community-north.sh` (see [Building a VP415e
pack](#building-a-vp415e-pack)), so they are no longer in this script's table,
and naming any of them here says so. National B stays here, 12 sets, until it
gets a pack script of its own.

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
| *(none)* | every side of every set — 12 decodes |
| `DS4` | every side of disc set 4 |
| `DS4:NationalB` | one side of one set |
| `NationalB` | that side of every set |
| `NB` | the same, by short name |

`--side` narrows whatever the selectors chose rather than adding to it, so
`--side NB DS4 DS7` and `DS4:NB DS7:NB` are the same request. Set and side names
are matched regardless of case, and naming a side twice still decodes it once.

The sides come out in table order, set by set, however the selectors were
written.

### Sides captured in more than one pass

A side the player could not read in one pass was captured in several, and each
part is a decode in its own right. `DS1`'s National A is the one such side in
the library: the player lost the disc at picture 37480 and a second pass picks
up at 39001. It is decoded by `decode-national-a.sh`, which lists the two parts
as two sets, `DS1` and `DS1B`:

```
$ ./decode-national-a.sh --list
DS1   CAV PAL  picture #1      …_NationalA_PP_20191014_CAV_PAL_00001-37480.ldf
DS1B  CAV PAL  picture #39001  …_NationalA_PP_20191014_CAV_PAL_39000-54000.ldf
DS2   CAV PAL  picture #1      …_NationalA_PP_20191014_CAV_PAL_00001-54000.ldf
…
```

`decode-domesday.sh` still decodes a side in parts, in table order, and
numbers them in `--list` ("part 1/2"), though no side left in its table has
more than one.

`DS1B` begins at the very head of its capture, and the first frame ld-decode's
CVBS writer will accept there is three frames in (see [Keeping the lead-in in
the output](#keeping-the-lead-in-in-the-output)). A very short `--frames` never
reaches it, and ld-decode then exits cleanly having written an empty file — so
the scripts treat an empty video file as a failed decode and say so:

```
$ ./decode-national-a.sh -f 2 DS1B
ld-decode wrote an empty …_39000-54000.cvbs: its writer never reached a frame it
could open the file on. This side's output opens later than --frames 2 reaches;
decode more frames.
```

Anything from `-f 10` up is clear of it, and the 1000-frame default is well
clear.

The "picture #" column is what the start search converges on — the first frame
of that capture's content. It is 1 for a capture that begins at the head of the
side, and the part's own first picture for one that picks up mid-disc. That
number cannot be taken from the filename's frame range: the range on `DS1B`
reads `39000-54000`, but its first picture is 39001, and a search told to find
39000 never lands on it. It is in the table instead.

### Output layout

Decodes go to `<output>/<set>/<decoder>/<capture basename>.*`:

```
/Users/Shared/Domesday86/Domesday86_Decodes/decode-script/domesday/
└── DS1/
    └── ld-decode-12be078/
        ├── Domesday_DD86-DS1_CommunityNorth_20191014_CAV_PAL_00001-54000.cvbs
        ├── Domesday_DD86-DS1_CommunityNorth_20191014_CAV_PAL_00001-54000.start
        ├── Domesday_DD86-DS1_NationalB_PP_20191014_CLV_PAL_00-60.cvbs
        └── decoder.txt
```

The capture basename already names the set and the side, and the parts of a
split side keep their own frame ranges, so nothing collides.

### Flags

`decode-domesday.sh` takes the common flags and environment variables — see
[Configuration](#configuration) — with `--side` and `--efm` added. `--start N` still applies to a single capture, so
the selectors have to choose exactly one. It also passes
`--V4300D_coherent_subtract` on every side — see [Player spur
removal](#player-spur-removal) — and `--noEFM` on the CLV ones — see [EFM and the
National B sides](#efm-and-the-national-b-sides).

### EFM and the National B sides

**National B carries no EFM**, and it is the only CLV side in every set, so the
EFM front end is switched off on exactly the CLV sides:

```
ld-decode --pal --noEFM --cvbs --cvbs-spec-origin --V4300D_coherent_subtract ...   # National B
ld-decode --pal --V4300D_coherent_subtract --cvbs --cvbs-spec-origin ...           # the CAV sides
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
PAL-only, which the whole Domesday library is.

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

Starts are resolved by `find-disc-start.sh`, the same helper every script uses,
and cached beside the decode as `<basename>.start`. Nothing is taken
from the `--start` values in the library's `Domesday_AIV_DiscSet_Notes.txt`;
those are recorded by hand against a different ld-decode and are not what this
build wants.

The 49 starts are resolved before any decode begins, and at the same `--jobs`
concurrency as the decodes. A start search is several short ld-decode probes that spend most of
their wall clock seeking into the `.ldf` rather than working, so run one at a
time the whole library takes well over an hour before the first frame is
decoded. Nothing is contended for: the resolve phase finishes before any decode
is launched.

## Decoding the Volcanoes disc

`decode-volcanoes.sh` decodes the PAL BBC AIV **Volcanoes** disc (BBC, 1988).

Volcanoes is **single-sided**: the second side carries no content, so a disc set
here is one capture rather than the four a Domesday set holds. The library has
five sets — five independent captures of the same disc, made between 2019 and
2026 — and each is decoded in its own right, so they can be compared against
each other or combined.

```sh
nix develop
./decode-volcanoes.sh                  # all five sets, first 1000 frames each
./decode-volcanoes.sh --frames 2       # quick smoke test
./decode-volcanoes.sh --frames all DS3 # one set in full
./decode-volcanoes.sh --frames all -j 2   # all five, two at a time
./decode-volcanoes.sh --list
```

Sets are named `DS1` to `DS5`, matched regardless of case. With none named,
all five are decoded. Output goes to
`<output root>/<set>/<decoder>/<capture basename>.*`, with the output root
defaulting to `/Users/Shared/Domesday86/Domesday86_Decodes/decode-script/volcanoes`.

### What the script asserts

Every capture is PAL CAV, was made on an LD-V4300D, and carries EFM digital
audio. Those are facts about the disc and the captures rather than choices, so
they are asserted in the script instead of offered as flags:

```sh
ld-decode --pal --V4300D_coherent_subtract --cvbs --cvbs-spec-origin ...
```

EFM is therefore decoded on every set — Volcanoes is a CAV AIV disc and the
front end has something real to read. The Domesday **National B** sides are the
one place in this library where it is switched off, because they are CLV and
carry none; see [EFM and the National B
sides](#efm-and-the-national-b-sides). Player spur removal is the same coherent
subtraction the Domesday sides get, for the same reason — see [Player spur
removal](#player-spur-removal).

DS4 and DS5 were captured in 2026, four years after the rest, on an LD-V4300D
that may have been modified to quieten its EFM noise. They were checked rather
than taken on trust, and they behave exactly like the earlier sets:

- **The spur is still there.** At three points across the side the 8.4672MHz
  tone stands 38–48 dB above the local noise floor, with both ±88.2kHz
  satellites at 12–25 dB, against 6–10 dB at a neighbouring frequency. That is
  as strong as on DS1–DS3, typically 3–9 dB stronger, so the coherent
  subtraction has the same job to do on them.
- **EFM is where it is on the others.** Probes every 1,000 pictures, scored with
  `lddecode.efm_score`, find it from about picture #47000 to the end of the side
  — sync rate 1.000, confidence 238–248 — and nowhere before it.
- **CAV, end to end,** by the same probes, and both captures begin at picture #1,
  at file frames 342 (DS4) and 363 (DS5).

The table carries a "first picture" column that is `1` for all five captures,
each of which begins at the head of the side. It exists for a side the player
lost and had to be captured in more than one pass, whose later part picks up
mid-disc; the Domesday library has one such side, and this one has none.

Everything else — the two roots, the frame limit, lead-in, probe, jobs and
threads — works exactly as it does for the other scripts, by the same flags
and the same `DD_*` environment variables, with `DD_OUTPUT` defaulting to the
Volcanoes output root. Starts are resolved by the shared `find-disc-start.sh`,
in parallel at the `--jobs` concurrency, and cached beside the decode as
`<basename>.start`. Nothing is taken from the `--start` values recorded by hand
in the library's `Volcanoes_Notes.txt`; those were made against a different
ld-decode and are not what this build wants.

### Checked and stamped decodes

Volcanoes is the pilot for [building a VP415e pack](#building-a-vp415e-pack),
so its script also keeps each decode as a stage of that build. The other
scripts follow once the process is proven here.

- **The captures are verified first.** `verify-sources.sh` checks the selected
  captures against `sources.sha256` before any start search or decode, so a
  changed or missing capture is caught in seconds.
- **Each finished decode is checked**, and the results are written beside it as
  `check.txt`:
  - `.cvbs`, `.meta`, `.efm`, `.efm.meta` and `.dropouts.meta` are all there;
  - decode-orc accepts the source (`STANDARD_STABLE_LOCKED` or
    `STANDARD_STABLE_UNLOCKED`, from `orc-cli nodes list --json`);
  - the frame count is the side's 54,000 pictures plus the lead-in kept,
    within 1% (or the `--frames` asked for);
  - the frames from picture #47000 to the end, where the disc carries EFM
    data, all have EFM t-values. That is as far as this goes: the front end
    writes t-values from noise as well, so whether they decode is for the EFM
    sink in phase 2.
  - It also records where the analogue audio went. ld-decode rev8 writes it
    beside the decode as `<basename>_audio_0.wav`, not inside the `.cvbs`.
- **A decode that passes is stamped** (`stage.stamp`). The stamp records the
  capture's fingerprint, the ld-decode revision, the start, the frames and the
  flags. A failed check leaves no stamp, and the report is kept as
  `check.failed.txt`.
- **A re-run skips an up-to-date decode.** With nothing changed, the script
  verifies, finds every stamp matching and stops, in a second or two.
- **A stale decode is never overwritten silently.** If a decode has no stamp,
  or its stamp no longer matches (other frames, say), the script stops and
  says which input changed. `--force` decodes it again. `--adopt` instead checks
  the decode that is there and stamps it if it passes, which is the way to
  keep a decode made before stamps, or one whose check needed fixing.
- **Two versions are kept.** After a new ld-decode revision's decode is
  stamped, all but the newest two `ld-decode-<rev>` directories of that set
  are removed.
- **Each directory is dated.** A decode directory is named
  `ld-decode-<rev>-<date>`, where `<date>` (`YYYYMMDD-HHMMSS`) is when the
  run that first made it started. One run gives every directory it makes the
  same date, `build-pack.sh` included, and a directory a later run reuses
  keeps its date. The revision is what finds a directory again; the date is
  for reading the listing. Directories made before dates were added are
  still found and reused under their old names.

Only a decode made by the `flake.lock` build, checked as above, in CVBS, is
stamped. `--decoder`, `--no-verify-decoder` and `--tbc` decode as before,
without a stamp. The checks need `orc-cli`, `sqlite3` and `jq`, all in the dev
shell.

```
$ ./decode-volcanoes.sh --frames all DS4
...
   state: stale: changed frames
decode-volcanoes.sh: DS4: stale: changed frames
A decode is there (…/DS4/ld-decode-16dc70f/Volcanoes_DD86-DS4_….cvbs), and is not replaced without --force. Pass
--force to decode it again, or --adopt to check the decode that is there and
stamp it if it passes.
```

## Decoding the EcoDisc disc

The PAL BBC AIV **EcoDisc** (BBC, 1987) is an interactive videodisc about
Slapton Ley, a nature reserve in South Devon. Each side is a VP415e pack of its
own, so each has its own decode script, which checks and stamps its decodes
for `build-pack.sh` as [Volcanoes'](#checked-and-stamped-decodes) does:

| Side | Script | Pack | Captures |
| --- | --- | --- | --- |
| Side 1, the interactive side | `decode-ecodisc-side1.sh` | `ecodisc-side1`, stem `ecodisc_s1` | DS1–DS5 |
| Side 2, the documentary | `decode-ecodisc-side2.sh` | `ecodisc-side2`, stem `ecodisc_s2` | DS1, DS3, DS4, DS5 |

EcoDisc was first pressed **single-sided** and later reissued **double-sided**,
the new second side carrying a linear documentary about the reserve. The library
holds five sets: four are the double-sided pressing, and **DS2 is a copy of the
original single-sided one**, so it has a first side and nothing else. That makes
**nine captures across the five sets, not ten**: the second side's script lists
four sets, and has no DS2.

```sh
nix develop
./decode-ecodisc-side1.sh --list                # the first side's five captures
./decode-ecodisc-side1.sh --frames 2            # quick smoke test
./decode-ecodisc-side1.sh --frames all DS3      # one set in full
./decode-ecodisc-side2.sh --frames all -j 2     # the second side, two at a time
```

Sets are named `DS1` to `DS5`, matched regardless of case. With none named,
every set the script lists is decoded. Output goes to
`<output root>/<set>/<decoder>-<date>/<capture basename>.*`, with the output
roots `/Users/Shared/Domesday86/Domesday86_Decodes/decode-script/ecodisc-side1`
and `.../ecodisc-side2`.

### Both sides are CAV

Both sides are **CAV**, including the second. The documentary runs about 35,500
frames, comfortably inside the 54,000 a CAV side holds, so it never needed CLV.
This is worth stating because two things suggest otherwise and both are wrong:

- Some second-side captures are **named** `...CAV_PAL_00001-54000.ldf`, after
  the *first* side's frame range. That is a copying slip in the library — the
  captures end where the side does, around frame 35,500. Nothing in the scripts
  reads a format out of a filename, and the second side's does not read its
  length from one either.
- A short documentary side is the kind of thing that is often CLV.

What settles it is the VBI. `ld-decode` reads the format from the disc itself,
and probes right across a second-side capture return CAV picture numbers
counting up continuously at a constant file-frame offset — 327 on DS1, matching
the `--start 327` recorded by hand in `EcoDisc_Notes.txt`.

### EFM

The first sides carry EFM digital audio and the second sides do not, so the EFM
front end runs on the first sides only. On the Domesday sets the same question
is answered by the format — EFM is absent exactly on the CLV National B sides —
but that shortcut does not work here: **both EcoDisc sides are CAV and they
still differ.** Each side's script asserts its answer: `decode-ecodisc-side1.sh`
decodes EFM, and `decode-ecodisc-side2.sh` decodes with `--noEFM`.

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

The first side's check of a finished decode asks for EFM t-values on every
frame from picture #6000 to the end, as Volcanoes' does from #47000. The
front end writes t-values from noise past the data too, so that is as far as
the check goes; whether they decode is for the EFM sink in the `set` stage.

### What the scripts assert

Every capture is PAL, is CAV, and was made on an LD-V4300D, and each side
either carries EFM or does not. Those are facts about the disc and the captures
rather than choices, so they are asserted in the scripts instead of offered as
flags:

```sh
ld-decode --pal --V4300D_coherent_subtract --cvbs --cvbs-spec-origin ...           # Side 1
ld-decode --pal --noEFM --V4300D_coherent_subtract --cvbs --cvbs-spec-origin ...   # Side 2
```

Player spur removal is the same coherent subtraction the Domesday and Volcanoes
sides get, for the same reason — all five sets came off an LD-V4300D; see
[Player spur removal](#player-spur-removal). The disc format is deliberately
*not* passed: `ld-decode` reads CAV or CLV from the VBI itself.

A second-side decode with `--noEFM` has no `.efm` or `.efm.meta`, so its check
does not ask for them, and its stamp (`lib/decode.sh`) does not list them as
outputs. Its frame count is checked against the side's 35,501 pictures, from
DS5's file name, rather than against each capture's own name, since three of
those say 54000.

The tables carry a "first picture" column that is `1` for all nine captures,
each of which begins at the head of its side. It exists for a side the player
lost and had to be captured in more than one pass, whose later part picks up
mid-disc; the Domesday library has one such side, and EcoDisc has none.

Everything else — the two roots, the frame limit, lead-in, probe, jobs and
threads, `--adopt` — works exactly as it does for Volcanoes, by the same flags
and the same `DD_*` environment variables, with `DD_OUTPUT` defaulting to each
side's output root. Starts are resolved by the shared `find-disc-start.sh`, in
parallel at the `--jobs` concurrency, and cached beside the decode as
`<basename>.start`. Nothing is taken from the `--start` values recorded by hand
in the library's `EcoDisc_Notes.txt`; those were made against a different
ld-decode and are not what this build wants, though they agree closely enough to
be a useful sanity check.

## Decoding the City Disc set

`decode-city.sh` decodes the PAL BBC AIV **City Disc** set (BBC, 1990), an
interactive videodisc set about the City of London — the "square mile" —
covering its history, its customs and its role as a modern financial market
place.

Unlike the other AIV titles here, a City "set" is **four discs**: Culture 1,
Culture 2, Financial 1 and Financial 2. All four are single-sided except
**Culture 1, which carries the same content on both of its sides**. So a *side*
in this script names a disc *and* a side of it:

| Side | Short name |
| --- | --- |
| `Culture1-Side1` | `C1S1` |
| `Culture1-Side2` | `C1S2` |
| `Culture2-Side1` | `C2S1` |
| `Financial1-Side1` | `F1S1` |
| `Financial2-Side1` | `F2S1` |

The library holds two sets, and they are not equally complete: **DS2 has all
five captures, DS1 has no Financial 1** — that disc was missing when the set was
captured. That makes **nine captures across the two sets, not ten**, so
`Financial1-Side1` selects one capture rather than two and `DS1:F1S1` is an
error rather than an omission.

```sh
nix develop
./decode-city.sh                        # all nine captures, first 1000 frames each
./decode-city.sh --frames 30            # quick smoke test
./decode-city.sh --frames all DS2:F1S1  # one side in full
./decode-city.sh --frames all C1S1 -j 2 # both Culture 1 first sides
./decode-city.sh --frames all -j 2      # the whole set, two at a time
./decode-city.sh --list
```

Selectors work as they do for Domesday: `DS1` is every side of a
set, `DS2:Culture2-Side1` one side of one set, `Culture2-Side1` (or `C2S1`) that
side of every set that has one, and they add together. `--side` narrows whatever
the selectors chose. Set and side names are matched regardless of case. Output
goes to `<output root>/<set>/<decoder>/<capture basename>.*`, with the output
root defaulting to `/Users/Shared/Domesday86/Domesday86_Decodes/decode-script/city`.

### What the script asserts

Every capture is PAL, is CAV, was made on an LD-V4300D, and carries EFM digital
audio. Those are facts about the discs and the captures rather than choices, so
they are asserted in the script instead of offered as flags:

```sh
ld-decode --pal --V4300D_coherent_subtract --cvbs --cvbs-spec-origin ...
```

EFM is therefore decoded on **every** side, and the side table carries no `efm`
column and the script no `--efm` / `--no-efm` — there is nothing per-side to
decide. EcoDisc's second side carries no EFM, and has a script of its own that
says so; the Domesday **National B** sides are the other place in this library
where the front end is switched off, because they are CLV and carry none. See
[EFM and the National B sides](#efm-and-the-national-b-sides). Player spur removal is the same coherent
subtraction the other sides get, for the same reason — see [Player spur
removal](#player-spur-removal). The disc format is deliberately *not* passed:
`ld-decode` reads CAV or CLV from the VBI itself, and the table's format column
records what it will find rather than telling it.

### One capture that needs a different start target

The table's "first picture" column is `1` for eight of the nine captures. The
exception is **DS1's `Culture2-Side1`, which is `4`** — and that is a fact about
the *capture*, not about the disc.

Picture #1 is there, at file frame 332, directly behind the lead-in at 330–331.
But that capture reports a **duplicated file frame** just after it: pictures #2
and #3 both land on file frame 334. `find-disc-start.sh` only trusts a reading
its successor confirms by advancing one file frame and one picture together (see
[Finding the start of the disc](#finding-the-start-of-the-disc)), so picture #1
can never be confirmed there and the search runs out of probes:

```
probe 2: start 330 (offset 0) -> 330 leadin
probe 3: start 335 (offset 0) -> 335 4;336 5
start search kept estimating file frame 332 without reading picture #1 there
```

Picture #4, at file frame 335, *is* confirmed — by #5 at 336 — and converges on
the second probe.

**Nothing is lost by aiming at #4.** The start that keeps the lead-in has to
land on the colour-sequence lattice `ld-decode`'s CVBS writer opens on, and the
nearest one below 335 opens the output at file frame **332 — picture #1
itself**. The start report says so on every run:

```
content=335 leadin=1 start=332 opens=332
start: 332 (output opens at file frame 332, 3 frame(s) before picture #4; 1 requested)
```

The search has since learnt to trust a reading confirmed two file frames on
(for the Apple Visual Almanac), so it would now confirm picture #1 at 332 by
#2 at 334. The table keeps `4` all the same: the start is the same either way,
and the cached start is only reused for the target it was found for.

### Everything else

The two roots, the frame limit, lead-in, probe, jobs and threads work exactly as
they do for the other scripts, by the same flags and the same `DD_*` environment
variables, with `DD_OUTPUT` defaulting to the City output root. Starts are
resolved by the shared `find-disc-start.sh`, in parallel at the `--jobs`
concurrency, and cached beside the decode as `<basename>.start`. Nothing is
taken from the `--start` values recorded by hand in the library's
`City_Disc_Notes.txt`; those were made against a different ld-decode and are not
what this build wants, though they agree with it to within a few frames and are
a useful sanity check:

| Capture | notes | resolved |
| --- | --- | --- |
| DS1 `Culture1-Side1` | 384 | 382 |
| DS1 `Culture1-Side2` | 290 | 282 |
| DS1 `Culture2-Side1` | 331 | 332 |
| DS1 `Financial2-Side1` | 303 | 303 |
| DS2 `Culture1-Side1` | 298 | 296 |
| DS2 `Culture1-Side2` | 357 | 355 |
| DS2 `Culture2-Side1` | 380 | 381 |
| DS2 `Financial1-Side1` | 338 | 338 |
| DS2 `Financial2-Side1` | 368 | 368 |

Note that one quick smoke test differs from the other scripts: `--frames 2` is
too short here. DS1's `Culture1-Side2` has no colour-sequence-aligned start at
its content frame, so its output opens nine frames into the decode; `--frames
30` is the smallest round number that clears it on every capture.

## Decoding the Countryside disc

The PAL BBC AIV **Countryside** disc (BBC, 1988) is a double-sided interactive
videodisc about agriculture, the environment and the rural community. Each side
is a VP415e pack of its own, so each has its own decode script, which checks
and stamps its decodes for `build-pack.sh` as
[Volcanoes'](#checked-and-stamped-decodes) does:

| Side | Script | Pack | Captures |
| --- | --- | --- | --- |
| Side 1 | `decode-countryside-side1.sh` | `countryside-side1`, stem `countryside_s1` | DS1–DS5 |
| Side 2 | `decode-countryside-side2.sh` | `countryside-side2`, stem `countryside_s2` | DS1–DS5 |

The library holds five sets — five independent captures of the disc, made
between 2019 and 2021 — and every one has **both sides**, so there are **ten
captures**, five per script. Each is decoded in its own right, so they can be
compared against each other or combined.

```sh
nix develop
./decode-countryside-side1.sh --list              # the first side's five captures
./decode-countryside-side1.sh --frames 30 DS1     # quick smoke test
./decode-countryside-side1.sh --frames all DS3    # one set in full
./decode-countryside-side2.sh --frames all -j 2   # the second side, two at a time
```

Sets are named `DS1` to `DS5`, matched regardless of case. With none named,
every set the script lists is decoded. Output goes to
`<output root>/<set>/<decoder>-<date>/<capture basename>.*`, with the output
roots
`/Users/Shared/Domesday86/Domesday86_Decodes/decode-script/countryside-side1`
and `.../countryside-side2`.

### What the scripts assert

Every capture is PAL, is CAV on both sides, was made on an LD-V4300D, and
carries EFM digital audio. Those are facts about the disc and the captures, so
they are asserted in the scripts instead of offered as flags:

```sh
ld-decode --pal --V4300D_coherent_subtract --cvbs --cvbs-spec-origin ...
```

Each was checked rather than assumed:

- **CAV.** Probes every 1,000 pictures across both sides of DS1 and DS5 — 208
  in all — read back exactly the CAV picture number aimed at, end to end. The
  format is still not passed: `ld-decode` reads it from the VBI.
- **LD-V4300D.** All ten captures carry the player's 8.4672MHz clock spur,
  29–49 dB above the local noise floor against 7–11 dB at neighbouring
  frequencies, so the coherent subtraction has something to remove — see
  [Player spur removal](#player-spur-removal).
- **EFM on both sides.** Scored with `lddecode.efm_score` from those same
  probes, as for [EcoDisc](#efm). As on the other AIV discs the digital audio is
  localised: it spans roughly pictures **#9000–#11000 on the first side and
  #9000–#21000 on the second**, identically on both sets, with no syncs
  anywhere else. Within those spans the stream frames up perfectly — sync rate and frame-588 fraction 1.000,
  demodulator confidence 248–251 — and outside them it scores 0.000 at
  confidence 31–41, the signature of a section with none.

Since both sides carry some EFM, the front end runs on every set of both
scripts, and neither offers `--efm` / `--no-efm`; both packs have a VFS image.
That is EcoDisc's first side, not its second, which carries none. Each script's
check of a finished decode asks for EFM t-values on every frame from picture
#9000 to the end, as EcoDisc Side 1's does from #6000.

A decode's frame count is checked against its capture's last picture, from the
file name: 54,085 on every first side and 51,000 on every second.

### Everything else

The roots, the frame limit, lead-in, probe, jobs and threads, `--adopt`, work
exactly as they do for Volcanoes — see [Configuration](#configuration). Starts
are resolved by `find-disc-start.sh` and cached beside the decode as
`<basename>.start`. Every capture begins at the head of its side, so the "first
picture" column is `1` throughout. The `--start` values recorded by hand in the
library's `Countryside_Notes.txt` are not used, but they agree with what this
build resolves to within a few frames:

| Capture | notes | picture #1 at | `--start` | output opens at |
| --- | --- | --- | --- | --- |
| DS1 `Side1` | 334 | 335 | 326 | 334 |
| DS1 `Side2` | 337 | 338 | 335 | 335 |
| DS2 `Side1` | 295 | 296 | 292 | 292 |
| DS2 `Side2` | 373 | 376 | 371 | 372 |
| DS3 `Side1` | 330 | 331 | 330 | 330 |
| DS3 `Side2` | 295 | 297 | 290 | 291 |
| DS4 `Side1` | 379 | 380 | 376 | 376 |
| DS4 `Side2` | 350 | 351 | 348 | 348 |
| DS5 `Side1` | 301 | 303 | 293 | 302 |
| DS5 `Side2` | 363 | 365 | 358 | 359 |

As on the City Disc, `--frames 2` is too short a smoke test. On DS1 and DS5's
first sides the nearest colour-sequence-aligned start lies well before the
content, so the output opens eight and nine frames into the decode, and a
two-frame run writes an empty file — which the script reports as a failure
rather than a decode. `--frames 30` clears it on every capture.

## Decoding the North Polar Expedition disc

`decode-north-polar.sh` decodes the PAL **North Polar Expedition** disc (Virgin
Publishing, 1989), an interactive videodisc in which a group takes on the roles
of the members of an expedition to the North Pole. It is not a BBC title, but it
is an AIV-era disc captured the same way as the rest of the library.

North Polar Expedition is **single-sided**, so a disc set here is one capture.
The library has two sets — two different copies of the disc, both captured in
January 2021 — and each is decoded in its own right.

```sh
nix develop
./decode-north-polar.sh                   # both sets, first 1000 frames each
./decode-north-polar.sh --frames 30 DS1   # quick smoke test
./decode-north-polar.sh --frames all DS2  # one set in full
./decode-north-polar.sh --frames all -j 2 # both sets at once
./decode-north-polar.sh --list
```

Sets are named `DS1` and `DS2`, matched regardless of case. Output goes to
`<output root>/<set>/<decoder>/<capture basename>.*`, with the output root
defaulting to `/Users/Shared/Domesday86/Domesday86_Decodes/decode-script/north-polar`.

### What the script asserts

Every capture is PAL CAV, was made on an LD-V4300D, and carries **no EFM**:

```sh
ld-decode --pal --noEFM --cvbs --cvbs-spec-origin --V4300D_coherent_subtract ...
```

**No EFM** is the one that differs from the BBC AIV discs, and it was measured.
Probes every 500 pictures right across DS1 and every 1,000 across DS2 — 156 in
all — were scored with `lddecode.efm_score` as for [EcoDisc](#efm), and not one
found a single T11–T11 frame-sync pair: sync rate 0.000 throughout, demodulator
confidence 29–41, the signature of a section with no EFM. The BBC discs' EFM is
localised, but every block found on them spans a thousand pictures or more,
which probes 500 apart cannot step over. So the front end is switched off, as
it is on the Domesday National B sides, rather than left to write an `.efm` of
noise. `--efm` (`DD_EFM=1`) turns it back on, for checking that claim.

The other two were checked too. The same probes read back exactly the CAV
picture number aimed at, end to end on both captures. Both carry the
LD-V4300D's 8.4672MHz clock spur, 41 and 33 dB above the local noise floor, so
the coherent subtraction has something to remove — see [Player spur
removal](#player-spur-removal).

### Everything else

The roots, the frame limit, lead-in, probe, jobs and threads work exactly as
they do for the other scripts — see [Configuration](#configuration). Both
captures begin at the head of the side, so the "first picture" column is `1`.
The `--start` values in the library's `NPE_Notes.txt` are not used, but agree
with what this build resolves:

| Capture | notes | picture #1 at | `--start` | output opens at |
| --- | --- | --- | --- | --- |
| DS1 | 359 | 360 | 350 | 358 |
| DS2 | 303 | 304 | 300 | 300 |

DS1's output opens eight frames after its `--start`, so as with Countryside and
the City Disc, `--frames 2` is too short to smoke-test it; `--frames 30` clears
it.

## Decoding the Dragon's Lair disc

`decode-dragons-lair.sh` decodes the **NTSC** arcade disc of **Dragon's Lair**
(Cinematronics, 1983). It is not a Domesday or AIV title: it is decoded as
an **NTSC stacking reference for testing decode-orc**. The disc is
single-sided, and the library has five copies, `DS1` to `DS5`, each
captured once in December 2019 (`Arcade/Dragons_Lair`).

`build-pack.sh dragons-lair` builds it a **video-only pack**,
`dragons_lair.mkv`, the same way as EcoDisc side 2: the disc has no EFM,
so there is no VFS stack. `discs/dragons-lair/` has the following:
- `disc.conf`: `DISC_SYSTEM=NTSC`, `DISC_EFM=no`, CAV side 1, pictures
  1–31805, and the `ntsc3d` decoder on every frame;
- `map.orcprj`, `set-quality.orcprj` and `stack.orcprj`, all NTSC;
- `selection.yaml`, which is written once the compare report is in.

The stack uses decode-orc#354's chain with two exceptions:
- no FM Beat Cancel, which is PAL only;
- no `vbi_mono_average`, because the disc says mono but carries its sound on
  one carrier.

Its first video stage, on decode-orc 1e62354, failed the metadata check:
the Weighted stacker marked VBI lines 17 and 18 as dropouts, and Dropout
Correction pasted picture over them. That lost 25 picture numbers, each next
to a pulldown frame. decode-orc 9afae69c fixes it, and the address map check
against the single captures (see the video stage under [Building a VP415e
pack](#building-a-vp415e-pack)) now guards against it.

The 3:2 pulldown frames are kept unnumbered in the frame maps and the mkv.
The metadata check notes how many there are, and they fall near 20% of the
file.

```sh
nix develop
./decode-dragons-lair.sh --list
./decode-dragons-lair.sh --frames 30 DS1  # quick smoke test
./decode-dragons-lair.sh --frames all -j 2 # all five sets, two at a time
```

Output goes to `/Users/Shared/Domesday86/Domesday86_Decodes/decode-script/dragons-lair`.
The decodes are checked and stamped as the pack scripts' are.

### What the script asserts

```sh
ld-decode --ntsc --noEFM --cvbs --cvbs-spec-origin ...
```

- **NTSC.** `--ntsc` takes the place of `--pal`, and the PAL sides'
  `--V4300D_coherent_subtract` is not given: ld-decode documents it as PAL
  only. CVBS comes out in ld-decode's NTSC encoding, `CVBS_U16_4FSC`, and
  decode-orc reads it as an `NTSC_CVBS_Source`.
- **No EFM.** The disc's sound is analogue only. Eight probes of DS1, 30
  frames each at file frames 1000–40000, scored with `lddecode.efm_score` as
  for [EcoDisc](#efm), found no frame sync: sync rate 0.000, confidence 28–32.
- **3:2 pulldown.** The animation is film, so five frames carry four
  pictures, and ld-decode logs every fifth frame as "CAV Lead In", with no
  picture number; the picture check leaves those frames out. The side runs from picture #1 to #31805
  (DS1), which is 39,756 frames, and the frame count check uses that figure.
  The start search closes in on picture #1 more slowly for the same reason,
  so the script allows it 16 probes. DS5 needs nine.

| Capture | picture #1 at | `--start` | output opens at |
| --- | --- | --- | --- |
| DS1 | 520 | 516 | 517 |
| DS2 | 538 | 535 | 535 |
| DS3 | 532 | 528 | 529 |
| DS4 | 597 | 593 | 594 |
| DS5 | 603 | 599 | 600 |

All five pass their checks. DS1–DS4 write 39,761 frames each. DS5's
capture has a fault: the player sat on picture #25000 for 4,550 frames
(about 2½ minutes), then went on in skips of about 65 pictures to #25975.
That leaves 844 pictures missing, nearly all in #25001–#25975, for the Disc
Mapper to sort out. Its decode writes 43,565 frames, which the script's
`EXTRA_FRAMES` allows for, and ld-decode records it as
`STANDARD_STABLE_UNLOCKED`, where the other four are locked.

## Decoding the Apple Visual Almanac disc

`decode-apple-almanac-side-a.sh` and `decode-apple-almanac-side-b.sh` decode
the two sides of the **NTSC** **Apple Visual Almanac** (Apple, 1989), a CAV
disc of stills, video and sound that a Macintosh drives over a serial link to
the player. Like Dragon's Lair it has no VP415e pack, and is decoded as an
**NTSC stacking reference for testing decode-orc**. The library has three
copies, `DS1` to `DS3`, each side captured once
(`Interactive_Video/Apple_Visual_Almanac`).

```sh
nix develop
./decode-apple-almanac-side-a.sh --list
./decode-apple-almanac-side-a.sh --frames 30 DS1   # quick smoke test
./decode-apple-almanac-side-a.sh --frames all -j 2 # all three sets, two at a time
```

Output goes to `/Users/Shared/Domesday86/Domesday86_Decodes/decode-script/apple-almanac-side-a`
and `…/apple-almanac-side-b`. The decodes are checked and stamped as the pack
scripts' are.

### What the scripts assert

```sh
ld-decode --ntsc --noEFM --cvbs --cvbs-spec-origin ...
```

- **NTSC**, as for [Dragon's Lair](#decoding-the-dragons-lair-disc).
- **No EFM.** The sound is analogue only. Three probes of each side of DS1,
  30 frames each at file frames 1000, 20000 and 45000, found no frame sync:
  sync rate 0.000, confidence 30–37.
- **Pulldown in places.** Parts of each side are film with 3:2 pulldown, which
  ld-decode logs as "CAV Pulldown/Telecine Frame", with no picture number; the
  rest is video, one picture to a frame. So the side's length in frames is
  measured, not worked out from its pictures. In DS1:

| Side | pictures | #1 at | last picture at | frames | of them pulldown |
| --- | --- | --- | --- | --- | --- |
| A | #1–#50683 | 421 | 54420 | 54,000 | 3,317 |
| B | #1–#53361 | 416 | 54416 | 54,001 | 640 |

Side A's head is untidy. Before the real picture #1 there's a stray #1, then
two lead-in frames. DS2 then holds picture #3 for four frames, and DS3 reports
file frames that sometimes step by two. Each of those stopped the start search
until it was taught to cope (see
[Finding the start of the disc](#finding-the-start-of-the-disc)).

| Capture | picture #1 at | `--start` | output opens at |
| --- | --- | --- | --- |
| DS1 side A | 421 | 419 | 420 |
| DS2 side A | 425 | 423 | 424 |
| DS3 side A | 439 | 438 | 439 |
| DS1 side B | 416 | 413 | 414 |
| DS2 side B | 449 | 447 | 447 |
| DS3 side B | 392 | 390 | 390 |

The library's notes give DS2 side A's start as unknown. DS3 side A opens on
picture #1 itself, keeping no lead-in: the frames before it are off the
colour sequence the CVBS writer opens on.

All six pass their checks and are recorded `STANDARD_STABLE_LOCKED`. Each
runs over the whole side, #1–#50683 or #1–#53361, in 54,004–54,013 frames.
DS1 reads every picture in order on both sides. The other captures have a few
frames out of order (DS2: 8 on side A, 20 on side B; DS3: 6 and 4), for the
Disc Mapper to sort out. Decoding the six took two hours, both sides at once.

## Building a VP415e pack

`build-pack.sh <disc>` takes a disc from its captures to the `<stem>.mkv`,
`<stem>.dat` and `<stem>.dat.bsm` the [VP415e](https://github.com/Domesday86/vp415e)
emulator loads. It works stage by stage, and each stage keeps a stamp of its
inputs, so a re-run with nothing changed does nothing.
[docs/emulator-pack-plan.md](docs/emulator-pack-plan.md) has the plan.
- **Phase 0 is in place:** the pinned tools, the share checks, the stamps
  (`lib/stage.sh`, tested by `tests/stage-test.sh`) and the driver.
- **Phase 1 is in place:** the `decode` stage. It runs the disc's decode
  script on every stale set, two at a time with four workers each, so a
  decode made here and one made by hand are the same thing. See [Checked and
  stamped decodes](#checked-and-stamped-decodes).
- **Phase 2 is in place:** the `set` stage. For each set it writes, under
  `orc-<rev>/sets/<set>/`:
  - the EFM data image `<set>_efm.dat`, with its bad sector map (`.bsm`) and
    decode report (`.txt`), from decode-orc's EFM sink;
  - the SNR, dropout and burst-level figures per frame (`snr.csv`,
    `dropouts.csv`, `burst.csv`), from its analysis sinks;
  - `quality.json`, which gathers the EFM report's figures and each analysis's
    summary for the selection report in phase 4;
  - `check.txt`, the checks the set passed before it was stamped.

  The projects come from the disc's committed `set-efm.orcprj` and
  `set-quality.orcprj`, copied beside the outputs and pointed at the set's
  decode. They are two projects because `--process` runs every sink in a
  project, and the analyses each read the whole decode. Sets run
  `SET_JOBS` at a time.
- **Phase 3 is in place:** the `map` stage. It copies the disc's committed
  `map.orcprj` to `orc-<rev>/map/`, points each set's source at its decode,
  and runs `orc-cli tools refresh`. The Disc Mapper builds each set's frame
  map and reads the disc's identity over the whole side (user code, CX,
  Amendment 2, side, sound mode, first and last picture, lead-in and
  lead-out), then Source Alignment places the sets against each other and
  compares the captures. Nothing is processed. It writes:
  - `analysis.json`: by set, the Disc Mapper's figures (padding, split-field
    frames, duplicates), its disc identity and warnings, the alignment
    padding, and the capture comparison (noise, 5–6 MHz response, stamper
    group, what the set adds to the stack, its share of the weight, its
    coverage, softness), for the selection report in phase 4. It also gives
    the comparison's predicted stack σ, whether its noise model was trusted,
    and the suggested reference. All of it is read from the data decode-orc
    attaches to its report, not from its summary text;
  - `refresh.json`, decode-orc's own report, and `check.txt`;
  - `framemaps/<set>.ranges` (one entry per line, 0-based as a project
    stores them) and `framemaps/alignment` (each set's padding);
  - `framemaps/picture-band`: where the picture ends, Source Alignment's
    `lumaCutoffMHz`, which it measures only between captures of two or more
    stamper families (`none` otherwise);
  - `framemaps/<set>.carrier`, on a side whose `map.orcprj` puts a set
    through an FM Beat Cancel (`<set> beat`, a branch off its frame map that
    feeds nothing): the master's FM carrier at black, measured by the refresh's
    FM Beat Calibration. Community South has one on every set. The stage is
    PAL only.

  The stage fails if Source Alignment finds a set whose picture numbers sit
  off its content (`contentOffsetSources`). Stacking that set would blend in
  the neighbouring picture. Its warning gives the alignment map that would
  correct it: fix the set's alignment by hand, or leave the set out.

  The frame maps and alignment are also copied into `discs/<disc>/framemaps/`
  for committing, so a change in mapping shows up in `git diff`. A set that
  cannot be mapped stops the stage and is named; drop it by deleting its
  source and frame map from `map.orcprj`.
- **Phase 4 is in place:** the `compare` stage and the `select` check. The
  `compare` stage lays every mapped set's evidence side by side, in
  `orc-<rev>/compare/report.txt`, for a person to decide the selection from.
  It selects nothing. The disc identity each set reads comes from the `map`
  stage's Disc Mapper, over the whole side, so the stage runs no video sink
  and takes seconds. Besides what the `set` and `map` stages found, it
  measures one thing: whether the sets' EFM images agree sector for sector,
  from `vfs-stacker --dry-run --show-conflicts` over all of them
  (`vfs-stacker.txt`).

  The report orders the video sets by what each adds to the stack: the
  predicted stack σ without the set ("adds"), from Source Alignment, the
  higher the more it adds. A set's own noise σ is not the figure to choose
  by. A set alone in its stamper group (the discs whose noise one stamper
  recorded) reads as noisy as the rest or noisier, but adds the most,
  because no other set carries its noise, so it is not an outlier. A
  stamper group is shared noise, not a version of the disc: the disc
  identity and vfs-stacker's systematic dissent tell versions apart. The
  report ends the video section with a suggested order: the suggested
  reference first, which sets the stacker's sample grid, then the rest by
  what they add. Beside the suggested reference it gives Source Alignment's
  next choice, with what each adds and its padding, so a close call shows
  as one.

  It also writes `compare.json` (the same evidence, by set) and `check.txt`.
  The decision goes in `discs/<disc>/selection.yaml`, written and committed
  by hand. Its shape, with made-up choices:

  ```yaml
  pressing: A                # the content version chosen: the one with the most sets
  video:
    sets: [DS1, DS2, DS3]    # the suggested reference first (it sets the stacker's
                             # sample grid), then by what each adds
    dropped:
      - set: DS5
        reason: soft at 5-6 MHz
    noise_reduction: 6       # optional: the video sink's noise reduction, dB
  vfs:
    sets: [DS1, DS2, DS4]    # best first: vfs-stacker breaks split votes towards it
    dropped:
      - set: DS3
        reason: loses 1.7% of its EFM after C2
    accept: incomplete       # optional: ship even if the filesystem still lacks sectors,
                             # or single-source: let needed sectors rest on one set
  ```

  Every set `map.orcprj` maps is either used or dropped with a reason, in
  each stack. `select` is not stamped: it is waiting until the file exists,
  and stops the build if the file breaks those rules. When the first video
  set is not the compare report's suggested reference, `status` adds a
  warning to the `select` line, and the `video` stage prints it; it is not a
  failure, since the person may have a reason.

  `video.noise_reduction` is the selection owner's choice, and off unless
  given. It is applied in decode-orc's `still_only` mode: averaged only
  across the frames the stacker marks as one held picture, with no spatial
  fallback, so every single-frame still stays exactly as stacked. 6 dB is
  the setting measured on the Community South test card. It is a
  presentation choice, to check on vp415e before a pack ships with it.
- **Phase 5 is in place:** the `video` stage. It copies the disc's committed
  `stack.orcprj` to `orc-<rev>/video/`. That project's sources must be the
  selection's video sets, in its order. The stage then points each source at
  its decode, and sets each frame map and Align from the committed
  `discs/<disc>/framemaps/`, which must still match the `map` stage's. Then it
  processes the project: Source Align, the `Weighted` Stacker, Dropout
  Correction and the video sink (`mkv-ffv1-bt601`, 4:3, the disc's
  `VIDEO_DECODER` and `VIDEO_DECODER_SCHEDULE`, the selection's noise
  reduction, audio, chapters and disc metadata).

  A stack project rebuilt on decode-orc#354's advice (Community South and
  Dragon's Lair so far) adds to that chain. The video stage sets the
  measured values from the committed `framemaps/`, and `check.txt` notes
  them:
  - **`<set> beat`**: FM Beat Cancel between each frame map and Align, on
    PAL only. Its `carrier_black_mhz` comes from `framemaps/<set>.carrier`.
    The stack must have one on exactly the sets whose carrier `map.orcprj`
    measures.
  - **`pressing_repair`** on the Stacker, where the sets come from more than
    one stamper group.
  - No **`vbi_mono_average`** on any Domesday side: their sound is stereo.
    A PAL disc can't carry analogue sound and EFM at once, and the VBI's
    odd sound modes come from that, not from mono passages.
  - **Dropout Correction** with `method: interpolate`.
  - **`Band`**: Picture Band Limit after Dropout Correction. Its `cutoff_mhz`
    comes from `framemaps/picture-band`; when no band was measured, it takes
    the stage's default for the system (5.4 MHz PAL, 5.0 MHz NTSC).

  The Stacker stacks repeats (`still_frame_stacking`): a picture held over
  several frames is stacked across them as well as across the sets, which is
  most of what stacking gains on held pictures. It leaves `still_frame_search`
  (24), `luma_level_match` and `chroma_gain_match` (on) at decode-orc's
  defaults. The video sink decodes by picture range, from the side's
  `disc.conf`: `decoder_type` `multiple`, 3D on the motion sequences and 2D
  on the stills, the ranges given by a person from the side's known content
  (3D is about 1 dB better on held pictures and 2.7 dB worse on single-frame
  stills). The schedule counts frames 0-based, and on these sides picture p
  is frame p. A side that is motion throughout (National B, EcoDisc side 2,
  Dragon's Lair) takes one 3D decoder on every frame. It writes:
  - `<stem>.mkv`;
  - `metadata.yaml`, the disc metadata document taken from the mkv;
  - `video.json`: the container's figures, the metadata summary, each set's
    noise and share of the stacker's weight, read from the stacker's
    `StackerStage report:` records, whether its noise model was trusted in
    each block, and the hand-built baseline's figures (`VIDEO_BASELINE`);
  - `check.txt`.

  The mkv is checked as vp415e loads it:
  - Matroska and FFV1, `yuv422p` 8-bit and 4:3, at the size and rate of the
    disc's `DISC_SYSTEM`: 720×576 at exactly 25/1 for PAL (the default), or
    720×484 at 30000/1001 for NTSC (what decode-orc's video sink writes);
  - every packet a keyframe;
  - FLAC audio at 48 kHz.

  The disc metadata is checked by `lib/check-disc-metadata.py`, run with the
  dev shell's `pack-python`. It reads the document as decode-orc's format
  spec says a reader must, and checks:
  - the version;
  - the video system and its exact rate (`--system`);
  - the frame count;
  - the disc's format and side (`DISC_FORMAT`, `DISC_SIDE`);
  - the user code and Amendment 2 that the chosen sets read in the `compare`
    stage;
  - every picture in `DISC_PICTURES` resolving to exactly one frame;
  - unmapped frames only in the lead-in and lead-out.


  The **address map** is also checked against the single captures, by
  `lib/check-address-map.py`. While the stack is processed, each video set
  is run alone through its committed frame map into decode-orc's Daphne VBI
  sink, which decodes only the VBI. That takes minutes beside the stack, not
  hours. For every frame where most of the sets that read a picture number
  agree on one, P, the mkv's address map must put picture P on that frame.
  A frame left without a picture, or given another, fails the stage. Frames
  no majority reads aren't compared: pulldown frames, padding, and numbers
  the captures disagree on.

  This is the check that found decode-orc's Weighted stacker and Dropout
  Correction corrupting the VBI: they marked lines 17 and 18 as dropouts and
  pasted picture over them (fixed in 9afae69c). The metadata check sees that
  only where a picture is lost outright; this one sees it on every frame.
- **Phase 6 is in place:** the `vfs` stage. It stacks the selection's VFS
  sets' EFM images, best first, with `vfs-stacker` (majority consensus), and
  checks the result with `vfs-verifier`. It writes, under `vfs-<rev>/`:
  - `<stem>.dat` and `<stem>.dat.bsm`;
  - `vfs.sha256`, their hashes;
  - `vfs.json`: the verdict, each set's contribution, the bad sectors by
    role and the baseline comparison;
  - `check.txt`.

  The image must pass the bit-perfect test (the plan, phase 6):
  1. vfs-stacker's `RESULT` is `GOOD`;
  2. vfs-verifier passes;
  3. no sector the filesystem needs comes from one set alone, and no vote was
     split.

  Bad sectors in free space or before the filesystem don't count. A failing
  image stops the stage and lists each needed sector still bad, with its
  object, and which mapped sets' own images recover it. `accept: incomplete`
  under `vfs` in `selection.yaml` lets it through as `incomplete`.
  `accept: single-source` is narrower: it lets through only an image whose
  one failure is that some needed sectors were recovered by one set alone,
  every one of them recovered. Its verdict is `complete`, and `check.txt`,
  `vfs.json` and the pack report list the sectors each set alone recovered.

  The result is also checked against two things:
  - **the reference hashes** in `discs/<disc>/pack.sha256`. A person records
    them by copying `vfs.sha256` there after review;
  - **the hand-built image** (`VFS_BASELINE`). Every sector both recovered
    must hold the same bytes.
- **Phase 7 is in place:** the `pack` stage and `install-pack.sh`. The stage
  hard-links the video and vfs stages' outputs into `pack-<key>/`, so nothing
  is copied, and checks them again as they stand:
  - the mkv, with the video stage's checks;
  - the image and its map, against the vfs stage's hashes and the
    reference, and with `vfs-verifier`.

  Beside them it writes:
  - `SHA256SUMS`;
  - `<stem>.provenance.yaml`, which vp415e ignores. It records the captures'
    fingerprints, the tool revisions, the selection and the evidence behind
    it, the stacker's weights, the vfs verdict and every stage's checks;
  - `<stem>.report.pdf`, the pack's report, made afresh with every pack build
    (see below);
  - `pack.json` and `check.txt`.

  `pack` on the decodes share links to the current version.

  The last check is a person's, on the player. Until it is recorded, `status`
  says the pack is awaiting the hand check, and gives its id: the first 16 hex
  digits of the hash of its three files' `SHA256SUMS` lines. Record the check
  in `discs/<disc>/player-check.yaml`:

  ```yaml
  checks:
    - pack: "298eb83fe340638a"   # the pack's id, in quotes
      date: 2026-10-25
      vp415e: <the player's vp415e version>
      result: pass               # or fail
      notes: <what was checked>
  ```

  The next build restamps the same pack as complete. A recorded `fail` fails
  the stage.
- **The pack report.** Every pack build writes `<stem>.report.pdf` beside the
  pack, and the same report as Markdown in `<stem>.report.md`, for giving to
  an AI or anything else that reads text more easily than a PDF. The
  Markdown has the same sections, tables and appendices, from the same data,
  and links the PDF's own graphs, the SVGs in `report/`, whose text is kept
  as text. It is a record of what the automation did, from the RF captures to
  the pack, not instructions. It holds:
  - the pipeline: every step from RF to pack, its tool and revision, what it
    made for this pack, and how its checks came out;
  - the exact tools: each one's full revision, source and Nix hash from
    `flake.lock`, decode-orc's patches, and the store path and version of
    every command that ran;
  - the sources: each capture's date, size and fingerprint, its decode (the
    ld-decode version, flags and start), and its mapping;
  - each source's quality against the stack's: SNR, black PSNR, dropouts and
    burst level along the disc, the stack's SNR gain over the best single set,
    and the per-frame SNR distribution;
  - the selection, quoted with its reasons;
  - the stacker's weight for each set in each block it measured, and the
    blocks where its noise model was not trusted;
  - the mkv's container and disc metadata;
  - the EFM decode of each set, where each set's unrecovered sectors fall
    against the stack's, and the VFS stack and its verification;
  - every stage's checks and stamp, and the compare stage's report.

  The stack's figures come from the `quality` stage, which measures the
  stacker's output with the same SNR and dropout analyses the set stage runs
  on each set. It also measures the SNR of the same stack in Mean, every set
  weighted equally, as a check on the stacker's weights. Each analysis
  stacks again, so over the whole side it was the slowest stage: on
  Community South's eleven sets (decode-orc 2611e5b) each took about 95
  minutes, 4 h 48 m in all, against 2 h 58 m for the video stage. It now
  measures a sample instead: three blocks of 1,500 frames
  (`QUALITY_SAMPLE_BLOCK`, which a `disc.conf` may change) at the
  beginning, the middle and the end of the side, kept by a Frame Map after
  the stacker. A frame reads the same in the sample as over the whole side,
  so only the means become estimates. The report sets the stack against the
  sets over the same frames. The report is
  drawn by `lib/pack-report.py` (Matplotlib) and set by `typst` from
  `lib/pack-report.typ`, in IBM Plex from the dev shell rather than the host's
  fonts. Its working files (the graphs as SVG, and `report.json`) stay in
  `pack-<key>/report/`.
- **Phase 8 is under way:** the other discs, one at a time, each a directory
  under `discs/` and a decode script of its own that stamps its decodes: one
  script per pack. A disc's
  outputs go under its own `decode-script/<disc>/`, so two discs can be built
  at once. Each runs its decodes two at a time, and two discs' decodes
  together take the host past its measured best, so start the second when the
  first is past its decodes.
  - **Domesday Community South** (`community-south`, stem `dd_community_south`):
    the 12 Community South captures, decoded by `decode-community-south.sh`,
    which is `decode-volcanoes.sh` with this side's set table and checks. Its
    EFM data runs from about picture 1950 to 45040, not to the end of the
    side as on Volcanoes, and DS3's capture stops at picture 53040, which the
    frame count check takes from the file name. The baselines are the
    hand-built stack in `vp415e_projects/CommunityS_output`, which stacked
    DS4, DS6, DS8 and DS10. Its `selection.yaml` and `stack.orcprj` are
    written once the compare report is in.
  - **Domesday National A** (`national-a`, stem `dd_national_a`): the 13
    National A captures, decoded by `decode-national-a.sh`, which is
    `decode-community-south.sh` with this side's set table and checks. DS1's
    side is two passes, decoded as two sets: `DS1`, pictures 1–37480, and
    `DS1B`, from 39001. DS1B is left out of the map stage, and so of both
    stacks: Source Alignment compares captures only over frames every set
    holds, and its EFM image places data where its capture cannot reach.
    The side's EFM data runs from about picture 50 to 40900, so the decode
    check runs from picture 100. The baselines are the hand-built stack in
    `vp415e_projects/NationalA_output`, which stacked DS4, DS6, DS8 and DS10
    (its mkv is `dd_natA_stack_001.mkv`). Its `selection.yaml` and
    `stack.orcprj` are written once the compare report is in.
  - **Domesday Community North** (`community-north`, stem `dd_community_north`):
    the 12 Community North captures, decoded by `decode-community-north.sh`,
    which is `decode-national-a.sh` with this side's set table and checks.
    Its EFM data runs from about picture 1950 to 44410, as on Community
    South, the other side of the same disc, so the decode check runs from
    picture 2000. DS7 is left out, as on Community South: ld-decode hangs
    in its lead-out. The side's metadata reads CAV side 2. The baselines are the
    hand-built stack in `vp415e_projects/CommunityN_output`, which stacked
    DS2, DS4, DS6, DS8 and DS10. Its `selection.yaml` and `stack.orcprj` are
    written once the compare report is in.
  - **EcoDisc Side 1** (`ecodisc-side1`, stem `ecodisc_s1`): the five
    first-side captures, decoded by `decode-ecodisc-side1.sh`. Its EFM data
    is localised, to about pictures 6000–8000, so the decode check runs from
    picture 6000. There is no hand-built stack to compare with.
  - **EcoDisc Side 2** (`ecodisc-side2`, stem `ecodisc_s2`): the four
    second-side captures (DS2 has no second side), decoded by
    `decode-ecodisc-side2.sh` with `--noEFM`. It is the first side with no EFM,
    so its `disc.conf` says `DISC_EFM=no`. On such a side:
    - the set stage measures quality alone, with no EFM image;
    - the compare report has no VFS evidence;
    - `selection.yaml` has no `vfs` stack, and naming one is an error;
    - the `vfs` stage is "none", not stale;
    - the pack is `<stem>.mkv` alone, with SHA256SUMS, the provenance and the
      report, and the pack id is the hash of the mkv's line;
    - `install-pack.sh` copies the mkv alone.

    The side is a TV programme, motion throughout, so its video sink decodes
    every frame with `transform3d` rather than the held schedule.

```sh
./build-pack.sh volcanoes status                 # each stage: up to date, or stale and why
./build-pack.sh volcanoes                        # build what is stale
./build-pack.sh volcanoes --until decode         # just the decodes
./build-pack.sh volcanoes --until set            # the decodes, then each set's EFM image and quality
./build-pack.sh volcanoes --force decode:DS3     # decode one set again
./build-pack.sh volcanoes --force set:DS3        # redo one set's EFM image and quality
./build-pack.sh volcanoes --until map            # ...then map and align every set
./build-pack.sh volcanoes --until compare        # ...then the report to decide selection.yaml from
./build-pack.sh volcanoes --until video          # ...then, once selection.yaml is written, the stacked mkv
./build-pack.sh volcanoes --until vfs            # ...then the stacked, verified VFS image
./build-pack.sh volcanoes --until quality        # ...then the stack's SNR and dropouts, for the report
./build-pack.sh volcanoes --until pack           # ...then the pack, its provenance and report (the default)
```

### Installing a pack on the player

`install-pack.sh` copies the current pack's three files to the player's media
directory over ssh. It is never part of the build:

```sh
./install-pack.sh volcanoes development@vp415e-pi --dry-run   # check both ends, copy nothing
./install-pack.sh volcanoes development@vp415e-pi             # copy, then check on the player
./install-pack.sh volcanoes development@vp415e-pi --pack <decodes>/decode-script/volcanoes/pack-<key>
```

The last line installs another version, such as the previous one.

**Before copying,** it checks:
- the pack is stamped;
- the media directory (default `/srv/vp415e/media`) is group `vp415d` and
  mode `2775`;
- the ssh user can write to it and is in the group;
- there is room, and the player has `rsync` and `sha256sum`.

**The copy:**
- It sends the `.dat` and `.bsm` before the `.mkv`, since the player lists a
  side by its `.mkv`.
- It doesn't use `rsync -a`, which would carry the group over from here and
  defeat the directory's setgid bit (`vp415-selftest` reports that). It then
  sets group `vp415d` and mode `0644` on all three files explicitly.

**Afterwards,** it checks each file's group and mode, and checks every hash
on the player against `SHA256SUMS`. It never uses sudo, and it uses the
system's own `ssh`, with its keys; `rsync` comes from the dev shell.

Per-disc settings live in `discs/<disc>/disc.conf`. The disc's sets are read
from its decode script's `SETS` table, so there is one list of captures.

## How the decodes work

The rest of this applies to all six scripts: they share
`find-disc-start.sh`, the decoder check, the output format and the
concurrency machinery.

### Which ld-decode made a decode

These are pre-release branch builds, and two of them do not agree frame for
frame — so a decode is only meaningful alongside the ld-decode that produced it.
Decodes are therefore filed under the pinned commit:

```
/Users/Shared/Domesday86/Domesday86_Decodes/decode-script/volcanoes/
└── DS1/
    ├── ld-decode-16dc70f/          # 8.0.0dev
    │   ├── Volcanoes_DD86-DS1_….cvbs
    │   ├── Volcanoes_DD86-DS1_….start
    │   ├── decoder.txt
    │   ├── check.txt               # Volcanoes: what the decode was checked for
    │   └── stage.stamp             # Volcanoes: what it was made from
    └── ld-decode-<next rev>/       # after nix flake update
```

Decoding a disc again after updating ld-decode lands beside the earlier decode
rather than on top of it. Only a re-run of the *same* commit collides, and that
still stops with `already exists; pass --force to overwrite` (for Volcanoes, a
matching decode is skipped as up to date instead; see [Checked and stamped
decodes](#checked-and-stamped-decodes)). The `.start` cache
sits inside the decoder directory too, since which start keeps the lead-in is a
question about the writer's behaviour and so about the build.

The name is the short revision `flake.lock` pins, because that is the build `nix
develop` puts on `PATH`. That is a claim about the flake rather than about the
ld-decode that will actually run, so it is checked before anything is decoded —
`nix eval` on the flake (evaluation only, it never builds; about two seconds
with the store warm) against the ld-decode in the environment:

```
$ ./decode-volcanoes.sh --frames all
decode-volcanoes.sh: the ld-decode that would run is not the build flake.lock pins, so
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
test is wrong in both directions, as the library's two calibration-disc captures
— the ones `find-disc-start.sh` was developed against — show:

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
  (file frame *n*→*n*+1 or *n*+2 alongside picture *m*→*m*+1). A lone address
  in a spin-up region can be a misread, and it is that kind of misread that
  sends the arithmetic to the wrong part of the disc. A step of two file frames
  is allowed because on some captures the file frame ld-decode reports now and
  then steps by two and then holds: Apple Visual Almanac DS3 side A reads
  439 #1, 441 #2, 441 #3, so it never advances by one twice running.
* **An estimate made twice is probed wide once.** It means the four-frame
  window aimed at it missed the target, and would miss it again. On Apple
  Visual Almanac DS2 side A the player holds picture #3 for four frames, two
  after #1, so the window sees only #3. The search then probes 12 frames
  around the estimate, and gives up only if that misses too.
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
first picture at all.** National A's `DS1B`, `DS1`'s second pass, starts at
picture 39001, and the first frame its writer will accept is file frame 4 —
picture 39004. No start
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

With CVBS they also pass `--cvbs-spec-origin`, on the recommendation of
ld-decode's author: it 0H-aligns every frame as the CVBS specification
requires, with 0H of each frame's line 0 in the sample before sample 0. The
pinned 8.0.0dev build still defaults to `--cvbs-legacy-origin`, the decoder's
own line origin, which is not spec compliant. The flag is part of each
decode's stamp, so decodes made without it are stale.

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
./decode-volcanoes.sh --frames all -j 2   # two sets at once
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
  hours of decoding. The resolves run at the same `-j` concurrency as the
  decodes, because a start search spends most of its time seeking, and with
  `decode-domesday.sh`'s 49 sides to get through the serial version costs over
  an hour before the first frame is decoded. Nothing is contended for: the
  resolve phase finishes before any decode is launched.
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
decode-domesday.sh: decode failed for: DS3:NationalB (see each side's .log)
```

### Following a long decode

ld-decode writes a timestamped, line-oriented log of its own beside each decode,
at `<basename>.log`. That is the thing to follow:

```sh
tail -f "/Users/Shared/Domesday86/Domesday86_Decodes/decode-script/volcanoes/DS1/ld-decode-16dc70f/Volcanoes_DD86-DS1_….log"
```

ld-decode has no non-interactive output mode — it draws progress with carriage
returns and no newlines whatever it is writing to, so redirecting its console
output to a file gives one enormous line that `tail`, `grep` and `less` are all
useless on. The scripts therefore pass that stream through unchanged on a
terminal, where redrawing in place is what you want, and split it into lines
when stdout is not a terminal:

```sh
./decode-volcanoes.sh --frames 1000 > decode.log 2>&1   # decode.log is line-oriented
```

## Notes

`ld-decode` wraps its own `ffmpeg` and `flac` onto `PATH` at runtime, and this
flake takes `nixpkgs` from the ld-decode flake rather than pinning a second
copy, so the whole environment is built from a single nixpkgs revision.

The C++ `ld-decode-tools` (`ld-chroma-decoder`, `ld-dropout-correct`,
`ld-export-metadata`, …) are *not* built by the ld-decode flake and so are not
available here yet.
