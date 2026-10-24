# Plan: from captures to a VP415e disc pack

Status: **phases 0–2 are built. Phases 3–8 are not.** Volcanoes is the pilot
disc; the other discs follow once the process is proven on it.

## Goal

Run one repeatable, scripted process that takes the raw RF captures of a disc
and produces what the [VP415e](https://github.com/Domesday86/vp415e) emulator
loads for one disc side:

| File | What it is |
| --- | --- |
| `<stem>.mkv` | Stacked, dropout-corrected video and audio, with decode-orc's disc metadata embedded |
| `<stem>.dat` | The stacked, verified VFS (ADFS) data image recovered from the EFM track |
| `<stem>.dat.bsm` | Bad sector map for the `.dat`: one sector index per line for anything not recovered (empty when the image is complete) |

There is **one emulation output per AIV title**: one Volcanoes pack, and one
stem for each side of a multi-side title such as Domesday. All of a title's
usable disc sets go into that single output. A set that turns out to be an
outlier (a different pressing, a soft or badly damaged capture) is
**dropped**. It never becomes a second, alternative output.

For Volcanoes the stem is `volcanoes_stack`, the name vp415e already uses.
vp415e has no manifest or config file (one was removed in its decision 0048).
A side is just these three files sharing a stem in the media directory. The
"pack" is those three files plus a provenance record kept beside them.

The process must be **incremental**. A re-run with nothing changed does no
work. A re-run after a change (a new capture, a newer pinned tool, a changed
parameter) redoes only the stages downstream of that change.

## The pipeline

```
.ldf captures ─(1) ld-decode rev8─▶ .cvbs + .meta + .efm (+ audio)     one per set
                                         │
                (2) per-set decode-orc project   (orc-cli, one per set)
                    ├─ EFM sink ─▶ <set>_efm.dat + .dat.bsm + .dat.txt
                    └─ SNR / dropout / burst analysis ─▶ JSON + CSV
                                         │
                (3) stack project: tools refresh --dry-run
                    Disc Mapper on every set, then Source Alignment
                    ─▶ frame maps, offsets, pressing groups, soft sources
                                         │
                (4) selection: pressing / outlier decision ─▶ selection.yaml
                                         │
            ┌────────────────────────────┴───────────────────────────┐
  (5) stack project (chosen sets)                    (6) vfs-stacker + vfs-verifier
      Disc Mapper → Source Align → Stacker               chosen sets' .dat/.bsm
      (Weighted) → Dropout Correct → Video Sink          ─▶ volcanoes_stack.dat/.bsm
      ─▶ volcanoes_stack.mkv
            └────────────────────────────┬───────────────────────────┘
                (7) pack assembly and acceptance checks
```

## The tools, as pinned

The facts below come from the current sources: decode-orc `main` at
`31d22e64` (2026-10-23), vfs-verifier `41ab10c`, vp415e `8dfcd3e`.
decode-orc and vfs-verifier are pinned as flake inputs alongside ld-decode.
vp415e is read only as the definition of what a side must look like.

### ld-decode rev8

It writes `<stem>.cvbs` plus a `<stem>.meta` SQLite sidecar, and with EFM on,
`<stem>.efm` and `<stem>.efm.meta`. The Volcanoes script already decodes with
EFM on. decode-orc's CVBS source finds the audio, EFM and AC3 sidecars beside
the capture by stem, so a CVBS source takes only `input_path`. Its sample
encoding must stay at **From metadata**. It accepts the signal states
`STANDARD_STABLE_LOCKED` and `STANDARD_STABLE_UNLOCKED` and refuses any other.

### decode-orc (`orc-cli`)

Everything this pipeline needs runs headlessly
(docs/cli-user-guide/overview.md and multi-disc-stacking.md):

- **Editing a project:**
  - `nodes list|get|set|reset` address stages by name ("Disc 1", "Disc 1
    map", "Align", "Video Out").
  - `nodes set` validates every value and can write to a new file with
    `--output`.
  - `nodes list --json` reports each CVBS source's `signal_state` and
    `sequence_continuous`, so captures can be checked before anything runs.
- **Disc Mapper:**
  - `tools run <prj> field_mapping --node "Disc N map" [--apply]` builds a
    Frame Map's `ranges` from CAV picture numbers or CLV timecodes, with
    `PAD_n` entries for player skips.
  - It drops split-field frames (a skip mid-frame), and among duplicate
    pictures it keeps the best copy, scored on burst, SNR and dropout share.
  - It exits `6` if a disc cannot be mapped.
- **Source Alignment:**
  - `tools run <prj> source_alignment --node Align [--apply]` places each
    source by its median (picture number − position) and writes
    `alignmentMap` and `alignmentMode`.
  - `pad_for_alignment` now also pads every output at the tail to the longest
    one.
  - Its report adds a **capture comparison**: each source's noise, the
    **pressing groups** (when there are 4 or more sources), and a warning for
    any source that is **soft** at 5–6 MHz (below 0.75 of typical).
- **Refresh:**
  - `tools refresh-config <prj> <node> <tool>` records which tool refreshes
    each stage.
  - `tools refresh <prj> [--dry-run] [--json] [--process]` maps every disc,
    aligns them, saves only if every tool succeeded, then optionally runs the
    project.
  - **A refresh always reruns its tools, even on unchanged captures.**
    Skipping work is this repo's job (phase 0).
- **Analysis sinks:**
  - `tools run <prj> snr_analysis|dropout_analysis|burst_level_analysis
    --node … --json [--csv f]` gives per-source summary statistics and
    per-frame figures, without `--process`.
- **Processing:**
  - `orc-cli <prj> --process` runs **every** sink in the project, so each
    pipeline stage gets its own project.
  - Any `*_path` parameter is resolved against the project file's directory.
  - Sinks do not create their output directories.
- **Exit codes:**

  | Code | Meaning |
  | --- | --- |
  | 0 | ok |
  | 1 | error |
  | 2 | not found or unknown key |
  | 5 | project or capture refused |
  | 6 | analysis failed |
  | 130 | cancelled |

  A script can branch on all of them.

The stages have changed in ways that matter here:

- **Stacker `mode: Weighted`** is the new default and the recommended mode.
  - It measures each source's noise for every 500 frames, and works out the
    pressing groups from the pairwise differences (with 4 or more sources).
  - It weights the sources so that each pressing counts about once, and a
    cleaner disc counts more within its pressing.
  - It marks samples the sources disagree on as low-confidence dropout
    (severity 25), which Dropout Correct then repairs.
  - Each field is checked against the median of all inputs, and an input that
    carries a different picture there is left out of that field.
  - `Auto` and `Smart Mean` are deprecated and `smart_threshold` is gone. The
    hand-built `Volcanoes.orcprj` (`mode: Auto`) now loads as `Weighted`, so
    its output can no longer be reproduced exactly.
- **Stacker `efm_stacking`:** keep it at `Disabled`. On the National A tests
  every combining mode recovered fewer sectors than the best single source.
  EFM is therefore not stacked in decode-orc at all here; it is stacked at
  the sector level by vfs-stacker.
- **Video sink:**
  - `mkv-ffv1-bt601` ("FFV1 for VP415e") is the player format: lossless FFV1
    on the BT.601 720-wide grid, 16 slices, 24-bit FLAC at 48 kHz.
  - `embed_disc_metadata` adds the `orc-disc-metadata.yaml` attachment.
  - `luma_nr`/`chroma_nr` have been replaced by `noise_reduction` (dB, default
    0). It stays 0 for an emulator pack, so the pack is the stacked signal
    with nothing added.
  - The `display_aspect_ratio` default moved from `auto` to `4:3`. **Packs are
    4:3**, and the project sets it explicitly rather than relying on the
    default.
  - **Chroma decoder:** chosen per side, by content.
    - `transform2d` for discs that are mostly still frames.
    - `transform3d` for discs that are mostly motion.

    A 3D decoder separates chroma using the frames on either side. On a disc
    of stills those neighbours are unrelated pictures, so it gains nothing
    there and risks bleeding between pictures. `pal2d` is not used.

I probed the hand-built `vp415e_projects/Volcanoes_output/volcanoes_stack.mkv`
(made with `auto` aspect and `transform3d`). It is FFV1 720×576, `yuv422p`
8-bit, 25/1 fps, with every packet a keyframe, 48 kHz 24-bit stereo FLAC, and
the metadata attachment. That is exactly what vp415e accepts, so no re-encode
is needed. Phase 5 also checks that the 4:3 flag is present and that the
coded size is still 720×576.

### vfs-stacker and vfs-verifier

- **vfs-stacker:** `vfs-stacker -o out.dat a.dat b.dat …`
  - It merges sector by sector, voting among the sources that do not list the
    sector in their `.bsm`, and writes `out.dat.bsm`.
  - On a split vote the first input wins, so inputs go in best-first order.
  - It checks pairwise alignment first, and aborts on wide disagreement unless
    given `--force`.
  - It groups conflicts by which sources dissent, and reports a recurring
    dissent pattern as **systematic: a version (pressing) difference**.
  - It ends with `RESULT: GOOD | INCOMPLETE | UNKNOWN`, but **exits 0 for all
    three**, so the result line has to be parsed.
- **vfs-verifier:** `vfs-verifier image.dat` (reads `image.dat.bsm`)
  - It checks the ADFS structure: the free space map checksums, the root
    directory, the image length against the map, object sectors against the
    `.bsm`, and fill-only sectors the `.bsm` does not account for.
  - It exits 0 whenever it completes, so the verdict comes from parsing its
    log.
  - It holds **no reference hashes**, does not descend below the root
    directory, and cannot check file contents (ADFS has no per-file
    checksum).

No tool compares the image with a known-good one, so the pipeline has to
define **bit-perfect** for itself. An image counts as bit-perfect when:

1. vfs-stacker reports `GOOD` and the stacked `.bsm` is empty;
2. vfs-verifier finds no bad or unaccounted-for sectors;
3. no sector was taken from a single capture, and none was left contested.

Once an image passes, its SHA-256 is recorded in the repo as the reference
for later runs.

### vp415e

At load time vp415e refuses a side unless:

- the mkv is Matroska/FFV1, with every packet a keyframe;
- the video is 720×576 `yuv422p` 8-bit at exactly 25/1;
- the audio is 48 kHz (otherwise the side plays silently);
- the metadata attachment's `video.frame_count` equals the container's frame
  count;
- any `.bsm` that is present parses.

For the disc metadata, vp415e follows decode-orc's
[Embedded Disc Metadata Format](https://decode-orc.github.io/decode-orc/technical/disc-metadata-format/)
(`docs/technical/disc-metadata-format.md`, `format_version` 1.0). That spec,
not vp415e's code, is the contract the pack is checked against. The parts
that matter here:

- **Finding the document.** It is an attachment named
  `orc-disc-metadata.yaml`, MIME type
  `application/vnd.decode-orc.disc-metadata+yaml`, in Matroska only.
- **Reader contract:**
  - `format` must be `orc-disc-metadata`;
  - `format_version` is a quoted `MAJOR.MINOR`, where an unknown MAJOR is
    refused and an unknown MINOR is read;
  - the `ORC_*` container tags mirror the summary, and
    `ORC_DISC_METADATA_VERSION` matches `format_version`.
- **Address map:**
  - `kind` is `cav_picture` or `clv_timecode`;
  - `runs` follow `address = address₀ + (f − file_frame) −
    |unnumbered ∩ [file_frame, f)|`;
  - the sets `unnumbered` (never numbered: no address), `undecoded` (numbered
    but not recovered) and `unmapped` (no run, typically lead-in) each come
    as `ranges` or `bitmap`;
  - **every address the file states resolves to exactly one file frame**, and
    nothing is interpolated.
- **File frames** are 0-based and contiguous. `source.first_frame` is
  provenance only.
- **Disc values** (`disc.*`) are voted across fields, with
  `confidence.agreement`. A value never recovered is omitted, not guessed.
- **Events:** `lead_in`, `lead_out`, `stop_codes`, and `chapters` (which
  lists transitions only).
- **Known limitation:** PAL picture numbers at or above 79 999 decode
  incorrectly. No Domesday or AIV side goes that high (Volcanoes ends at
  54000), but the check asserts it.

The `.dat` is optional for the player, but required for a complete pack. On
the player, the media must be owned by group `vp415d`, with directories
`2775` (setgid) and files `0644`.

## Phases

### Phase 0: Tooling and the incremental framework

**Flake.** Two inputs join `ld-decode`:

```nix
decode-orc.url   = "github:simoninns/decode-orc";
vfs-verifier.url = "github:Domesday86/vfs-verifier";
```

vp415e is not an input. No build step runs it, because the final check is
done by hand on the player. Its acceptance rules are re-implemented as the
phase 5 checks instead.

- The dev shell gains `orc-cli`, `vfs-stacker` and `vfs-verifier`, plus
  `sqlite` and `yq` for reading `.meta` files and the metadata YAML.
  `orc-cli` is decode-orc's `apps.orc-cli` / `${decode-orc}/bin/orc-cli`.
- `flake.lock` is the single record of every tool revision. Outputs are filed
  under the revision that made them, as decodes are now
  (`ld-decode-16dc70f`): `orc-<rev>` and `vfs-<rev>`.
- `nix eval` checks that the tool on `PATH` is the locked one, in the same
  way `decode-*.sh` already checks ld-decode.

**Shares.** Every stage reads from or writes to two network shares: the
capture library and the decodes area.

The library is **read-only and is never written to**. Every output of every
stage goes to the decodes share. That includes intermediate files, temporary
names, stamps, logs, reports and generated projects. Nothing is ever written
next to a capture, and nothing goes to local disk or `/tmp`: scratch space is
`$DD_DECODES/decode-script/.work/`. The only things that land in the repo
are the reviewed decisions committed by hand (frame maps, `selection.yaml`,
reference hashes). `lib/stage.sh` enforces this: before writing, it resolves
every output path and refuses any path that does not lie under the decodes
mount, including one that resolves into the library. A share that has silently not mounted
is worse than a missing tool. On macOS an unmounted `/Volumes/<share>` can
still exist as an ordinary empty directory, and a decode written there fills
the local disk while looking like progress. A stale mount can also make every
stamp look missing, and so trigger a full rebuild. So shares are checked
first, by every script, and mounted when they can be.

- **Configuration.** `shares.conf` (committed) names each share by role, with
  its expected mount point and how to mount it on each platform:

  | Role | Mount point (env override) | macOS (this host) | Linux (decode host) |
  | --- | --- | --- | --- |
  | `library` | `DD_LIBRARY`, default `/Volumes/Domesday86_Library` | SMB `//sdi@raid._smb._tcp.local/Domesday86_Library` | NFS `10.0.1.4:/volume1/Domesday86_Library` |
  | `decodes` | `DD_DECODES`, default `/Volumes/Domesday86_Decodes` | SMB `//sdi@raid._smb._tcp.local/Domesday86_Decodes` | NFS `10.0.1.4:/volume1/Domesday86_Decodes` |

  A git-ignored `shares.local.conf` overrides it for each host: another
  server, user, transport or mount point. No password is ever stored in the
  repo. SMB credentials come from the macOS Keychain, and NFS needs none.
  `DD_OUTPUT` keeps its meaning and defaults to `$DD_DECODES/decode-script/<disc>`.
- **Check** (`lib/shares.sh`, `ensure_shares <role>…`). A share passes only
  if all of the following hold:
  1. **It is a mount.** The path is the root of a mount, not a directory on
     the parent filesystem. On Linux that is `mountpoint -q`. On macOS,
     `stat -f %d` must differ from the parent's, confirmed by `mount`.
  2. **It is the right mount.** The source and filesystem type match the
     config (`smbfs` or `nfs`, server, share or export). This catches the
     macOS habit of mounting a second copy at `/Volumes/Domesday86_Library-1`
     when the expected path is taken. In that case the script reports where
     the share actually is, rather than using an empty directory.
  3. **It responds.** `stat` and `ls` on the root must finish within a
     timeout, run in a background subshell, so that a hung NFS mount fails in
     seconds instead of blocking the script.
  4. **It has the right content.** For the library, one capture from
     `sources.sha256` must be present with the right size (a size check, not a
     hash, so it stays instant). For decodes, a `.domesday86-decodes` marker
     file at the share root must exist.
  5. **It has the right access.**
     - The library must be readable. Nothing tests whether it is writable:
       a write test is itself a write. Where the platform reports mount
       flags, a library mounted read-write gets a warning, since the share is
       meant to be read-only on the server too.
     - Decodes must be writable. This is tested by creating and removing a
       file under `decode-script/.work/`.
- **Mount** (`mount-shares.sh`, also called by `ensure_shares` when a check
  fails because the share is absent):
  - **macOS SMB:** `osascript -e 'mount volume "smb://sdi@raid._smb._tcp.local/Domesday86_Library"'`.
    It uses the Keychain credentials, mounts under `/Volumes/<share>` and
    returns only once the mount is up. If a stale empty directory blocks the
    path, the script stops and says so; it does not mount at a `-1` path.
  - **Linux NFS:** the host's own mount setup is left as it is, and the repo
    ships no fstab or automount snippet. The script runs `mount <mount
    point>`, which works when the host already defines the mount. Otherwise
    it stops and prints the `sudo mount -t nfs -o ro …` (library) or
    `sudo mount -t nfs …` (decodes) command to run. It never calls `sudo`
    itself.
  - After mounting, the full check runs again. A share that mounts but then
    fails the content or access check is an error, never a retry loop.
- **Use.** `decode-*.sh`, `verify-sources.sh` and `build-pack.sh` call
  `ensure_shares` before any other work. `build-pack.sh` also re-checks the
  shares before each stage, because they can drop during a run lasting
  several hours. A stage that fails partway leaves no stamp (see below), so
  re-running after a remount resumes where the run stopped. `build-pack.sh
  status` reports the share state first. `--no-mount` checks without
  mounting.
- **Paths that survive mount points.** Generated decode-orc projects live on
  the decodes share and use paths relative to the project file. A project
  opened on this Mac (`/Volumes/…`) and on the Linux host (`/home/sdi/raid/…`)
  therefore resolves the same files. The hand-built projects use absolute
  Linux paths, and could not do this.

**Stamps.** A small shell library, `lib/stage.sh`, implements stamp-and-skip
for every stage:

1. **Key.** A stage's stamp key is a hash of its declared inputs:
   - the stamps of its upstream stages;
   - the `sources.sha256` lines of the captures it reads;
   - the locked rev of each tool it calls;
   - its parameters, including the generated project file, normalised so
     that only content counts.
2. **Skip.** If the key matches the `<output>.stamp` beside the outputs and
   the outputs exist, the stage prints `up to date` and does nothing.
3. **Run.** Otherwise it runs into temporary names. On success it moves them
   into place and writes the stamp last, so an interrupted run never looks
   complete.

**Two versions kept.** Each rev-named output (`ld-decode-<rev>`,
`orc-<rev>`, `vfs-<rev>`, and the pack) keeps **the current version and the
one before it**, and no more. When a stage finishes a new version, the
oldest is deleted, leaving the new one and its predecessor. Deletion happens
only after the new version has completed and been stamped. A failed or
interrupted run never removes anything. `status` lists the versions held for
each stage.

Stamps chain, so no stage rehashes a multi-gigabyte output: a downstream stage
sees a new key because an upstream stamp changed. `--force <stage>` reruns a
stage regardless. `status` lists each stage as up to date or stale, with the
reason, and runs nothing. The `tools refresh` caveat above is handled the
same way: the stamp gates the refresh, so unchanged captures are never
re-mapped.

**Driver.** `build-pack.sh <disc> [status] [--from S] [--until S] [--force S]`
reads the same set table as `decode-<disc>.sh` and `verify-sources.sh`, so
there is still one list of captures. Per-disc settings live in
`discs/<disc>/`: the stem, the template project, and any overrides.

**Project files.** The disc sets rarely change, so the scripts are not
dynamic. Each disc side gets **committed project files written for its own
selected sets**: `discs/volcanoes/stack.orcprj`, and the per-set projects
for phase 2. They are built once (in the GUI or by hand), with:

- stages named "Disc 1"…"Disc N", "Disc N map", "Align", "Stack", "DOC" and
  "Video Out";
- refresh tools recorded with `tools refresh-config`: `field_mapping` on
  every map, `source_alignment` on Align.

Each run copies the project to the decodes share and points its sources at
the current decodes with `orc-cli nodes set`. Nothing else in the project
changes. Adding or dropping a set means editing the committed project, which
is a rare and deliberate change that shows in review.

**Exit criteria:**
- `nix develop` provides every tool at its locked rev.
- `mount-shares.sh` brings up both shares from an unmounted state on macOS,
  and on Linux when the host defines the mounts.
- `ensure_shares` refuses each of these:
  - an empty stand-in directory;
  - a `-1` mount;
  - an unresponsive mount;
  - a read-only decodes share.
- `build-pack.sh volcanoes status` on an empty tree lists every stage as stale.

**As built.** All the exit criteria are met.
- `tests/shares-test.sh` (macOS) checks each refusal against a real
  read-only mount made from a scratch disk image.
- `tests/stage-test.sh` checks the write guard, the stamps and pruning.

Where the build settles something the text above left open:

- **Layout** under `decode-script/volcanoes/`:

  | Stage | Directory |
  | --- | --- |
  | `decode:<DS>` | `<DS>/ld-decode-<rev>/` |
  | `set:<DS>` | `orc-<rev>/sets/<DS>/` |
  | `map` | `orc-<rev>/map/` |
  | `video` | `orc-<rev>/video/` |
  | `vfs` | `vfs-<rev>/` |
  | `pack` | `pack-<key>/` |

  Each directory holds a `stage.stamp`. An `orc-<rev>` version counts as
  complete once `video/stage.stamp` exists; the other directories are
  complete once their own stamp exists.
- **`select`** has no stamp of its own. It is decided once
  `discs/<disc>/selection.yaml` exists. `video`, `vfs` and `pack` take that
  file's content as an input, and read their sets from `.video.sets[]` and
  `.vfs.sets[]`. Phase 4 can add to that format, but should keep those two
  lists.
- **Project files** are expected at `discs/<disc>/stack.orcprj`, at
  `discs/<disc>/set-efm.orcprj` and `set-quality.orcprj`, which every set
  shares (since phase 2), and at `discs/<disc>/map.orcprj` (since phase 3).
  Until `stack.orcprj` is written, the `video` stamp records it as missing.
- **Linux mount points** default to `/home/sdi/raid/Domesday86_{Library,Decodes}`
  in `shares.conf`. A host that differs sets them in `shares.local.conf`.
- **Scratch.** Once the decodes share passes its check, `ensure_shares`
  points `TMPDIR` at `decode-script/.work/`. That catches every `mktemp` in
  the decode scripts and in `find-disc-start.sh` without changing them.
- **macOS uses NFS, not SMB.** The table above has changed for the Mac,
  which now mounts the same NFS exports as the Linux host. Its own mount
  points are under `/Users/Shared/Domesday86/`, and the SMB mounts in
  `/Volumes` are ignored. An ordinary user cannot make an NFS mount on macOS,
  so the osascript route is gone. Instead `sudo ./mac-nfs-mount.sh` mounts
  the shares once after each boot. It mounts the library and the SFTP share
  read-only (`resvport`, `nfc`), so the never-written rule holds at the mount.
  A script that finds a share missing names that command rather than calling
  sudo.
- **The share tests on NFS.** `tests/shares-test.sh` keeps its disk image on
  the decodes share. Its mount point is an empty directory in `/tmp`, because
  macOS attaches an image only at a directory the user owns, and on NFS
  every directory belongs to the server's user.

### Phase 1: Decode every set with ld-decode rev8

`decode-volcanoes.sh` already decodes all five sets. It uses
`--V4300D_coherent_subtract`, keeps EFM on and resolves each start, and writes
to `decode-script/volcanoes/<DS>/ld-decode-16dc70f/`. It changes as follows:

- **Skip an up-to-date decode instead of dying.** A decode whose stamp matches
  is skipped. The stamp covers:
  - the capture fingerprint;
  - the ld-decode rev;
  - start, length and flags.

  A decode with no stamp, or a different one, is reported as stale and is never
  silently overwritten. Replacing it still takes `--force`. Today's five
  decodes can be given stamps after the fact, once checked, so they are not
  redone.
- **Verify first.** `verify-sources.sh Volcanoes` runs before any decode, so a
  changed or missing capture is caught before hours of decoding.
- **Check every result:**
  - `.cvbs`, `.meta`, `.efm` and `.efm.meta` are all present.
  - `orc-cli nodes list --json` reports an accepted `signal_state` for the
    source.
  - The frame count is about 54,000 plus the lead-in.
  - `.efm` is non-empty over the span where EFM is known to be (on DS4 and
    DS5, from about picture 47000 to the end of the side).
  - Record whether rev8 carries analogue audio inside `.cvbs`/`.meta` or in
    separate sidecars.
- Concurrency stays at the measured best of `-t 4 -j 2` (docs/performance.md).

**Exit criteria:** five decodes, and a re-run that does nothing and finishes in
seconds.

**As built.** Both exit criteria are met.
- **The five full decodes** were made on 2026-10-23 on this Mac, an M4, by
  `build-pack.sh volcanoes --until decode`. Two ran at a time with four
  workers each, at 12.5–13 FPS each (18.6 FPS for DS5, which ran alone). The
  whole run took 3 h 5 min.
- **Every set passed its checks:**
  - 54,003–54,005 frames;
  - `STANDARD_STABLE_UNLOCKED`, which decode-orc accepts;
  - EFM t-values on all of the roughly 7,000 frames from picture #47000.
- **Sizes:** each set is 76.6 GB of CVBS, 2.0 GB of EFM and 622 MB of WAV.
  The five come to 369 GB.
- **A re-run** finds all five up to date and finishes in about 5 s, most of it
  entering the dev shell.
- **VBI picture numbers.** The ld-decode log shows 25–45 frames per set whose
  picture does not follow the one before it. They are single-frame VBI
  misreads (DS3 reads #49821 as #69486) and small skips and repeats. The
  Disc Mapper deals with these in phase 3. `check.txt` counts them, and
  reports the first and last frames' pictures rather than the smallest and
  largest.

Where the build settles something the text above left open:

- **Shared description.** `lib/decode.sh` describes a decode stage for both
  `decode-volcanoes.sh`, which builds and stamps it, and `build-pack.sh`, which
  asks whether it is up to date. The flags come from one `DECODE_FLAGS=(…)`
  line in the decode script, which `build-pack.sh` reads as it reads `SETS`.
  The stamp's inputs are the source line, the ld-decode rev, `start`, `frames`
  and `flags`. Threads and jobs are left out, since they change only the
  speed.
- **The start.**
  - The stamp records the start ld-decode was given.
  - `build-pack.sh` reads that start from the `.start` cache beside the
    decode. The cache line now ends in `target=<first picture>` and is used
    only for the same lead-in and picture.
  - A cache from before this change is re-resolved once.
- **The decode stage in `build-pack.sh`.** It runs the decode script on the
  stale sets, using `discs/<disc>/disc.conf`'s `DECODE_JOBS=2` and
  `DECODE_THREADS=4`. A forced set (`--force decode:DS3`) is passed on with
  `--force`.
- **Unstamped outputs.** `stage_state` now reports outputs that have no stamp
  as `stale: not stamped (…)` rather than `never built`. The decode script
  refuses such a decode without `--force`, or checks and stamps it with
  `--adopt`. There were no decodes under `decode-script/volcanoes/` to adopt:
  the hand-built project's decodes are `ld-decode-2454ee6`, on a Linux path.
- **The checks** are written to `check.txt`, which is a stage output:
  - **Frame count.** A whole side must be 54,000 pictures plus the lead-in
    kept, within 1%. A `--frames N` decode may come out up to
    `(opens − start) + 1` short, because `--length` counts from the start
    ld-decode is given, not from where its writer opens.
  - **decode-orc's view** comes from a one-source project, built with
    `orc-cli -i PAL_CVBS_Source=… --export-project` in `.work` and listed with
    `nodes list --json`.
  - **Picture numbers** are taken from ld-decode's log, which names the CAV
    picture on every frame it writes.
- **EFM.**
  - The front end writes t-values on every frame, including the ones before
    picture #47000 that have no EFM data. A t-value check therefore proves
    little.
  - The share of t-values in T3–T11 doesn't separate them cleanly either: about
    63% before the data against 83% within it, on DS4.
  - So phase 1 checks only that the span has t-values, as written. Phase 2's
    EFM sink is the real test.
- **Audio.** rev8 writes analogue audio as a sidecar beside the decode,
  `<stem>_audio_0.wav` ("Analogue stereo" in `.meta`), and also writes
  `<stem>.dropouts.meta`. Neither is a stamped output. `check.txt` records the
  audio sidecar.

### Phase 2: Per-set EFM and quality

Each set gets a small generated project in `volcanoes/orc-<rev>/sets/<DS>/`. It
has a CVBS source with two consumers:

- an **EFM Sink** (`decode_mode: data`, `output_metadata`, `report`) writing
  `<ds>_efm.dat`, `.dat.bsm` and `.dat.txt`;
- the **SNR**, **Dropout** and **Burst Level** analysis sinks.

The EFM sink is run with `--process`. The analysis sinks are run with
`tools run … --json --csv`, which writes their statistics without having to
process the project again. The EFM sink reads the raw source and does not
depend on the frame map, as in the hand-built project.

Each set has its own project and stamp, so adding or re-decoding a set reruns
only that set.

**Exit criteria:** every set has an EFM image, a `.bsm`, the decode report and
quality JSON. A re-run does nothing.

**As built.** Both exit criteria are met.

- **The run.** It was made on 2026-10-24 on this Mac, by `build-pack.sh
  volcanoes --until set`, two sets at a time, from 07:02 to 09:05: 2 h 3 min.
  - Every set passed its checks and was stamped. The outputs come to 1.7 GB.
  - A re-run finds all five up to date, in about 7 s.
  - The EFM sink took 46–53 s per set, and the dropout analysis 1–2 s.
  - SNR and burst level each took about 1,350–1,430 s with two sets sharing
    the link, and 830–920 s for DS5, which ran alone.
  - The Mac's link to the NAS is gigabit, and it ran at its 120 MB/s
    throughout, so the share's read rate sets the stage's time.
- **The results**, from each set's `quality.json`:

  | Set | Sectors | Not recovered (`.bsm`) | Good | Uncorrectable | Data loss after C2 | White SNR | Black PSNR | Dropouts (count / samples) | Burst |
  | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
  | DS1 | 162,152 | 139,920 | 22,231 | 2 | 0.0080% | 33.84 dB | 31.91 dB | 306,910 / 5.70 M | 126.4 |
  | DS2 | 162,152 | 139,925 | 22,226 | 7 | 0.0244% | 33.45 dB | 31.68 dB | 235,780 / 8.42 M | 126.3 |
  | DS3 | 162,148 | 140,346 | 21,796 | 426 | 1.7395% | 33.09 dB | 32.90 dB | 201,712 / 6.69 M | 125.1 |
  | DS4 | 162,152 | 139,926 | 22,224 | 12 | 0.0322% | 32.33 dB | 30.53 dB | 976,165 / 9.09 M | 130.5 |
  | DS5 | 162,151 | 139,933 | 22,217 | 15 | 0.0558% | 32.31 dB | 30.74 dB | 621,260 / 16.80 M | 127.6 |

  - SNR and burst are means over the frames.
  - The EFM sink grades every set POOR, because each has some uncorrectable
    sectors.
  - The EFM figures agree with the hand-built project. DS1 loses 0.0080% after
    C2 in both. DS3 is again the outlier, at 1.74% against 1.84%, and its image
    is again a few sectors shorter than the others.
  - Phase 4 weighs all of this; nothing here selects or drops a set.

- **A decode-orc fix carried here.** At the pinned `31d22e6` (and on `main` at
  `706b5f3`), the EFM sink in data mode crashes on macOS (SIGTRAP) within a
  second of starting, on any input.
  - The cause is in `Data24ToRawSector::waitingForSync()`. Once it has dropped
    the bytes before a sync pattern, it counts the flags of a whole sector even
    when fewer than 2,352 bytes are left, reading past the end of two vectors.
    libstdc++ lets that read pass; macOS's hardened libc++ traps it.
  - `patches/decode-orc-efm-sync.patch` waits for the rest of the sector
    instead. `flake.nix` applies it to the pinned decode-orc until decode-orc
    has the fix.
  - `stage_input_tool` adds each `patches/<input>-*.patch` to the tool's stamp
    line, so changing a patch makes the stages that use the tool stale.
- **Two projects per set, not one.** `--process` triggers every sink in a
  project, and the SNR and burst-level sinks each read the whole decode. In one
  project, processing the EFM sink would also run both analyses, which
  `tools run` then repeats. So each disc commits:
  - `discs/<disc>/set-efm.orcprj` (source "Disc", sink "EFM"), run with
    `--process`;
  - `set-quality.orcprj` (source "Disc", sinks "SNR", "Dropouts" and "Burst"),
    each sink run with `tools run --json --quiet --csv`.

  Every set shares the two. Each run copies them into
  `orc-<rev>/sets/<DS>/` and sets the source's `input_path`, relative to the
  project file, and the EFM output with `nodes set`.
- **Outputs, all stamped:**
  - `<ds>_efm.dat`, `.dat.bsm` and `.dat.txt`;
  - `snr.csv`, `dropouts.csv` and `burst.csv`, one row per frame;
  - `quality.json`: the EFM report's figures (assessment, sectors good,
    corrected and uncorrectable, C1/C2, data loss, missing sections) and each
    analysis's summary statistics;
  - `check.txt`.

  Each tool's raw JSON and log, the two projects and `efm.log` stay beside
  them, unstamped.
- **The checks:**
  - The EFM sink exits 0, and its report says `Result : SUCCESS`.
  - The image is a whole number of 2048-byte sectors, and the `.bsm` exists.
  - Each analysis reports `success` over all the decode's frames, and all
    three see the same number.

  How much was recovered, and how clean the picture is, are evidence for
  phase 4, recorded but never failed.
- **The stamp:** the decode's stamp, decode-orc's rev and patches, and both
  project files.
- **The decode stage now also requires `.dropouts.meta`**, which the dropout
  analysis reads. The stamped decodes already have it, so they stay up to
  date.
- **`SET_JOBS=2`** in `disc.conf`. Sets run two at a time, and each set's
  console lines carry its id.
- **Timings on DS4, read over NFS on this Mac:**
  - The EFM sink took 49 s for the whole side. It recovered 22,226 sectors
    with 12 uncorrectable and 0.03% data loss after C2. The image is 162,150
    sectors, 139,926 of them in the `.bsm`, most of them the span before
    picture #47000 that carries no EFM data.
  - The dropout analysis reads only `.dropouts.meta` and takes about a second.
  - SNR and burst level each read the whole 76 GB CVBS, so the share's read
    rate sets their time. SNR over all 54,003 frames of DS4 took 841 s (about
    91 MB/s) at 14% CPU, so a set takes about half an hour.
- **Tested** on a throwaway disc: DS4 and DS5, 400 frames each from picture
  #47000, under `.work`.
  - Both sets passed and were stamped, and a re-run did nothing in 3 s.
  - `--force set:DS4` redid DS4 alone.
  - A broken template made both sets stale, built neither, and stamped
    neither.

### Phase 3: Map, align and compare every set

The stack template is filled in with **all** the sets, then run with
`orc-cli tools refresh <prj> --dry-run --json`:

- The **Disc Mapper** on each set gives:
  - `ranges`;
  - padding frames, split-field frames and duplicate choices;
  - a failure (exit 6) for a set that cannot be mapped, which names the set
    and excludes it.
- **Source Alignment** gives:
  - offsets;
  - each source's noise;
  - **pressing groups** (with all 5 sets, above the minimum of 4);
  - **soft-source warnings**.

The report is kept as `analysis.json`. The frame maps and offsets are also
committed, as `discs/volcanoes/framemaps/<DS>.ranges` and `alignment`, so a
change in mapping shows up in review. Nothing is processed in this phase.

**Exit criteria:** `analysis.json` covering every set, and committed maps.

### Phase 4: Pressing and outlier selection

Not every set necessarily shares a pressing. Two mechanisms deal with that.

**Stacker weighting.** The `Weighted` stacker already copes with mixed
pressings, by weighting each pressing about once. So a second pressing is not
automatically an outlier.

**Removing sets.** Removing a set is still sometimes the better result:

- a set that is alone in its pressing, which the stacker cannot tell from a
  noisy disc;
- a soft capture chain, which blurs the stack;
- a capture that is badly damaged.

On the EFM side the problem is sharper. A sector that differs between
pressings is a real difference in content, not damage, and mixing pressings
in one vote can produce an image that matches neither.

The evidence for each set, all produced by the earlier phases:

| Evidence | Source | Points to |
| --- | --- | --- |
| Pressing group, noise σ | Source Alignment capture comparison (phase 3) | Pressing; noisy disc |
| Soft at 5–6 MHz | Source Alignment warning | Exclude from the video stack |
| Mean white SNR, black PSNR, dropout totals, burst | Analysis sinks (phase 2) | Ranking; damaged capture |
| Padding, split-field frames, unmappable stretches | Disc Mapper (phase 3) | Player trouble; coverage |
| User code, Amendment 2, CX, first/last picture, lead-in/out | Disc metadata (VBI) | Hard pressing difference |
| Pairwise sector agreement, systematic dissent | `vfs-stacker --dry-run --show-conflicts` over all EFM images | Data version or pressing |
| C1/C2 and sector loss | EFM reports (phase 2) | EFM ranking |

`compare-sets.sh` gathers this evidence into one readable report on the
decodes share. It makes **no** selection. The sets rarely change, so the
selection is decided once, **by a person reading the results**, rather than
by rules in the scripts. The video and VFS selections are decided
**separately**, because a set can be good for one and bad for the other:

- **Video:** every set of the chosen pressing, minus any that is soft,
  unmappable, or clearly the worst on SNR and dropouts. They are ordered best first, since
  `sample_align` uses input 1 as its reference grid.
- **VFS:** every set of the chosen pressing, minus any whose EFM is too
  damaged to vote usefully. They are ordered best first, since
  vfs-stacker breaks split votes towards its first input.

Whatever is decided, the outcome is one set of inputs for the title's one
output. An outlier is dropped, with its reason recorded. It is not kept as
the start of a second output. If the sets split into more than one pressing,
**the pressing with the most available sources is used**, and every set from
the other pressings is dropped, from both the video and the VFS stack. That
is the only basis for choosing between pressings. Picture quality and EFM
loss decide which sets to drop *within* the chosen pressing, never which
pressing to use. The report shows the pressing groups and their sizes, taken
from:
- Source Alignment's capture comparison (needs 4 or more sources);
- the disc metadata;
- vfs-stacker's systematic dissent.

If two pressings have the same number of sources, the report says so and
the choice is made by hand.

The decision goes into `discs/volcanoes/selection.yaml`, with a short reason
for every exclusion, and is committed. The video selection is also built into
the committed stack project (above). Later phases read only the committed
files. The report is regenerated when its inputs change, but it never changes
the selection.

Volcanoes already gives reason to look closely:

- DS4 and DS5 are both captures dated 2026-05-17, while DS1–DS3 date from
  2019–2022.
- In the hand-built project, DS3's EFM lost 1.84% after C2 (DS1: 0.008%),
  and its image is 8 KiB shorter than DS1's or DS2's.

This phase is what tells capture damage from a different pressing.

**Exit criteria:** a committed `selection.yaml`, with the video sets, the VFS
sets, their orders, and the reason for every exclusion.

### Phase 5: Stack the video

The stack template is filled in with the selected video sets. Its stages are:

- one CVBS source per set, in order;
- a Frame Map per set (Disc Mapper refresh);
- Align (`pad_for_alignment`, Source Alignment refresh);
- Stack: `Weighted`, `reject_sigma` 5, `sample_align` on, audio `Mean`, EFM
  `Disabled`;
- DOC: `match_chroma_phase` on;
- Video Out: `mkv-ffv1-bt601`, `display_aspect_ratio` `4:3`, the disc's
  chroma decoder, audio, chapters, disc metadata at `map` detail,
  `noise_reduction` 0, output `volcanoes_stack.mkv`.

The decoder is set **per side** in `discs/<disc>/`, by content, because the
sides of one disc can differ: EcoDisc side 1 is stills, but side 2 is a TV
programme.

| Disc / side | Content | Decoder |
| --- | --- | --- |
| Volcanoes | Mostly stills (AIV still-frame sets), with some motion sequences | `transform2d` (for now) |
| Domesday National A, Community N/S | Mostly stills (photos, maps, surrogate walks) | `transform2d` (for now) |
| Domesday National B | Motion (the CLV side) | `transform3d` |
| EcoDisc side 1 | Mostly stills | `transform2d` |
| EcoDisc side 2 | A TV programme (motion) | `transform3d` |
| City (both sides) | Likely mostly stills | `transform2d` |
| North Polar | Mostly motion | `transform3d` |
| Countryside | Mostly stills | `transform2d` |

This is a content decision, not a measurement. It is confirmed by a person
when a disc is added, and recorded in its configuration.

The project has no EFM sinks, so stacking never repeats phase 2. It is run
with:

```bash
orc-cli tools refresh volcanoes.orcprj --json --process > stack.report.json
```

The refresh regenerates the maps and offsets from the captures. The script
then checks that they match the ones committed in phase 3, and stops if they
do not. The stamp covers:

- the selection;
- the decode stamps of the chosen sets;
- the committed maps;
- the decode-orc rev;
- the project parameters.

**Checks** (vp415e's load-time rules, plus coverage):
- **Container:**
  - FFV1, `yuv422p`, 8-bit, 720×576, exactly 25/1;
  - a 4:3 display aspect, with the coded size still 720×576;
  - every packet a keyframe, counted across the whole stream;
  - audio is 48 kHz FLAC.
- **Metadata attachment.** `check-disc-metadata.py` implements the spec's
  reader in the dev shell's Python, so it reads the document the way vp415e
  does, and fails the pack on any of the following:
  - **Locating and versioning.** The attachment must be found by filename
    and MIME type and extract cleanly (`ffmpeg -dump_attachment:t:0 …`).
    `format` must be `orc-disc-metadata`, `format_version` must be a quoted
    string with MAJOR 1, and `ORC_DISC_METADATA_VERSION` must equal it. A
    newer MINOR passes with a note.
  - **Video.** `video.system` must be `PAL`, `frame_rate_exact` `[25, 1]`,
    and `fields_per_frame` 2. `frame_count` must equal the stream's frame
    count.
  - **Disc.** `disc.format` must be `CAV` for Volcanoes (`CLV` for National
    B), with the expected `side`. `user_code`, `cx_enabled`, `amendment2` and
    `confidence.agreement` go in the provenance file. The user code and
    Amendment 2 flags must also match the chosen pressing's evidence from
    phase 4.
  - **Address map.** Both set encodings are decoded, and the run arithmetic
    is applied to every file frame.
    - The `kind` must match the disc format, and `source` must be `biphase`.
    - Every picture 1–54000 must resolve to exactly one file frame, with no
      address claimed by two frames and none missing.
    - Any addresses beyond the programme range, and every run break (an
      address discontinuity), are listed.
    - `unnumbered` should be empty on a PAL CAV video disc, since there is no
      pulldown; if it is not, the frames are listed.
    - `undecoded` is reported with frame ranges. It measures how well the
      stack's VBI read, and should be no worse than the best single set.
    - `unmapped` may cover only lead-in and lead-out frames.
  - **Events.** `lead_in` and `lead_out` must be present, and the
    `stop_codes` are listed. For a CLV side with chapters (National B),
    `chapters` must be present and in order.
  - **Raw VBI.** Detail stays at `map`, so there is no `raw_vbi` block in
    the pack.
- **Stacker log:**
  - each source's σ and its share of the weight are recorded in the
    provenance, so a set that ends up with almost no weight is visible.

**Baseline.** Compare the result with the hand-built three-set
`vp415e_projects` mkv on:
- frame count;
- address-map gaps;
- dropout totals.

A five-set `Weighted` stack should be no worse anywhere.

**Exit criteria:** `volcanoes_stack.mkv` passes every check, and a re-run does
nothing.

### Phase 6: Stack and verify the VFS image

1. Run `vfs-stacker -o volcanoes_stack.dat <selected EFM images, best first>`
   with the default majority consensus. Log in full and parse `RESULT`.
2. Run `vfs-verifier volcanoes_stack.dat` and parse its summary.
3. Apply the bit-perfect test above. If it passes, record the image's SHA-256
   and size in `discs/volcanoes/pack.sha256`, and check every later run
   against it.
4. If it fails, report:
   - which sectors are still bad;
   - which captures cover them;
   - whether each lies in an allocated ADFS object or in free space.

   Losses in free space do not matter to the emulator; losses in objects do.
   The options are to:
   - capture again;
   - decode the EFM span again with different settings (for example
     `doubt_erasure_threshold`);
   - try `efm_stacking: Confidence` as one more candidate image for
     vfs-stacker (experimental);
   - accept an `INCOMPLETE` pack, whose `.bsm` vp415e serves as MEDIUM ERROR.

   The chosen option is recorded in `selection.yaml`.

**Baseline.** Compare with the hand-built
`vp415e_projects/Volcanoes_output/volcanoes_stack.dat` and its `.bsm`:
- There should be no more bad sectors than in the hand-built image.
- Any sector recovered by both images should hold identical bytes. If not, the
  cause is either a pipeline bug or a pressing difference, and it must be
  explained before the pack ships.

**Exit criteria:** a `.dat`/`.bsm` pair with a recorded verdict and hash.

### Phase 7: Pack assembly

The pack goes in `decode-script/volcanoes/pack/`:

```
volcanoes_stack.mkv
volcanoes_stack.dat
volcanoes_stack.dat.bsm
volcanoes_stack.provenance.yaml
SHA256SUMS
```

- The provenance file records:
  - capture fingerprints;
  - tool revs;
  - the selection with its evidence;
  - per-source stacker weights;
  - the vfs verdicts;
  - the results of every check.

  vp415e ignores it.
- The pack files are hard links (or copies) of the phase 5 and phase 6
  outputs. Nothing is recomputed.
- **Acceptance:**
  - Rerun the phase 5 and 6 checks on the assembled files.
  - vp415e cannot open a side without the player hardware, so the **final
    check is done by hand on the player**. The pack is not marked complete
    until that check is recorded in the provenance file: date, vp415e
    version, result.
- **Installing** is separate and explicit: `install-pack.sh <host>`. It is
  never part of the build. It sets group `vp415d`, directories `2775`, files
  `0644`, and avoids the `rsync -a` group carry-over that `vp415-selftest`
  flags.

**Exit criteria:**
- The Volcanoes pack passes the hand check on the player.
- `build-pack.sh volcanoes` on an unchanged tree does no work.

### Phase 8: Roll out to the other discs

Next come the Domesday sides. Their stems already exist: `dd_natA_stack`,
`dd_natB_stack`, `dd_comS_stack` and `dd_comN_stack`. Then the other AIV
discs. The differences from Volcanoes:

- **National B is CLV and has chapters.** The Disc Mapper and Source Alignment
  work on timecodes, and the chapter metadata needs its own check.
- **Several captures can make up one side.** A side whose capture was taken in
  more than one pass (the `first picture` column) has passes that must be
  joined before the Disc Mapper runs, or mapped as separate sources.
- **Discs with no EFM** (North Polar) skip phases 2 (EFM part) and 6. Their
  pack is just the mkv, which vp415e plays with SCSI reporting NOT READY.
- **Two-pressing sides.** Community North and National B are known to come
  from two pressings each (decode-orc's stacker study). These are the real
  test of phase 4.

## Decisions

| Question | Decision |
| --- | --- |
| Display aspect | 4:3 |
| Chroma decoder | Per side: `transform3d` for Domesday National B, EcoDisc side 2 and North Polar; `transform2d` for every other side, Volcanoes and Domesday for now (phase 5 table) |
| Library access | Read-only, never written; all output and r/w goes to the decodes share |
| Choosing sets and removing outliers | Decided by a person from the phase 4 results, then committed; the scripts are not dynamic |
| Outputs per title | One emulation output per AIV title (one stem per side); outlier sets are dropped, never made into a second output |
| Choosing a pressing | The pressing with the most available sources; sets from other pressings are dropped |
| Project files | Committed per disc side, built for its selected sets |
| Final pack check | By hand on the player (vp415e cannot run without its hardware) |
| Old outputs | Keep the current version and the previous one only |
| Linux mounts | No fstab or automount snippet in the repo; the script prints the mount command if a share is missing |
