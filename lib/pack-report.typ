// The pack report: set by lib/pack-report.py, which passes the figures and
// tables it read as report.json (sys.inputs.data) and its graphs as SVG
// (sys.inputs.graphs). Compiled with --root /, so both are absolute paths.

#let data = json(sys.inputs.data)
#let graph(name) = image(sys.inputs.graphs + "/" + name, width: 100%)

#let ink = rgb("#0b0b0b")
#let ink2 = rgb("#52514e")
#let muted = rgb("#898781")
#let grid-c = rgb("#e1e0d9")
#let axis-c = rgb("#c3c2b7")
#let good-text = rgb("#006300")
#let critical = rgb("#d03b3b")
#let mono(s, size: 7pt) = text(font: "IBM Plex Mono", size: size, s)

#set document(title: data.title + " pack report", author: "build-pack.sh")
#set text(font: "IBM Plex Sans", size: 9pt, fill: ink, lang: "en", region: "gb")
#set par(justify: false, leading: 0.6em, spacing: 0.9em)
#set page(
  paper: "a4",
  margin: (x: 17mm, top: 20mm, bottom: 18mm),
  header: context {
    if counter(page).get().first() > 1 {
      set text(size: 7.5pt, fill: muted)
      grid(columns: (1fr, auto), [#data.title · #data.stem], [pack #data.id · #data.version])
      v(-4pt)
      line(length: 100%, stroke: 0.4pt + grid-c)
    }
  },
  footer: context {
    set text(size: 7.5pt, fill: muted)
    grid(columns: (1fr, auto), [built #data.built by build-pack.sh #data.script.describe],
      counter(page).display("1 of 1", both: true))
  },
)
#set heading(numbering: "1.1", supplement: [section])
#show heading.where(level: 1): it => {
  pagebreak(weak: true)
  set text(size: 15pt, weight: "semibold")
  block(below: 10pt, it)
}
#show heading.where(level: 2): it => {
  set text(size: 10.5pt, weight: "semibold")
  block(above: 14pt, below: 7pt, it)
}
#show raw: set text(font: "IBM Plex Mono")

// A table from report.json: header, rows (strings), align per column. Columns
// in mono are set in IBM Plex Mono; with wide, the last column takes the
// remaining width and wraps; cols, when given, sets every column's width.
#let tbl(t, mono-cols: (), wide: false, cols: none, size: 7.5pt) = {
  let n = t.header.len()
  let al = t.align.map(a => if a == "left" { left } else if a == "right" { right } else { center })
  set text(size: size)
  table(
    columns: if cols != none { cols } else if wide { (auto,) * (n - 1) + (1fr,) } else { n },
    align: (x, y) => al.at(x) + horizon,
    stroke: (x, y) => (
      top: if y == 0 { none } else if y == 1 { 0.6pt + axis-c } else { 0.4pt + grid-c },
    ),
    inset: (x: 4pt, y: 3.2pt),
    table.header(..t.header.map(h => text(weight: "semibold", fill: ink2, h))),
    ..t.rows.enumerate().map(((i, r)) => r.enumerate().map(((j, c)) => if j in mono-cols { mono(c, size: size - 0.5pt) } else { c })).flatten()
  )
}

#let kv(..pairs) = {
  set text(size: 8pt)
  grid(columns: (auto, 1fr), column-gutter: 10pt, row-gutter: 5pt,
    ..pairs.pos().map(((k, v)) => (text(fill: ink2, k), v)).flatten())
}

#let tile(label, value, detail) = block(
  width: 100%, inset: 8pt, radius: 4pt, stroke: 0.5pt + grid-c,
  {
    text(size: 7.5pt, fill: ink2, label)
    v(2pt)
    text(size: 13pt, weight: "semibold", value)
    v(1pt)
    text(size: 7.5pt, fill: ink2, detail)
  },
)

#let checks-list(checks) = {
  set text(size: 7pt)
  grid(columns: (auto, 1fr), column-gutter: 6pt, row-gutter: 3.2pt,
    ..checks.map(((level, t)) => {
      let (label, colour) = if level == "ok" { ("ok", good-text) } else if level == "fail" { ("FAIL", critical) } else if level == "result" { ("result", ink) } else { ("note", muted) }
      (text(font: "IBM Plex Mono", weight: "semibold", fill: colour, label), text(fill: if level == "note" { ink2 } else { ink }, t))
    }).flatten())
}

#let set-swatch(s) = box(width: 7pt, height: 7pt, radius: 1.5pt, fill: rgb(data.colours.at(s, default: "#898781")), baseline: 0.5pt)


// --- the first page ---------------------------------------------------------

#block(below: 4pt, text(size: 8pt, fill: ink2, tracking: 0.4pt, upper[VP415e pack report]))
#block(below: 4pt, text(size: 24pt, weight: "semibold", data.title))
#block(below: 3pt, text(size: 9.5pt, fill: ink2)[#data.side · #mono(data.stem, size: 9pt) · pack #mono(data.id, size: 9pt)])
#block(below: 12pt, text(size: 9.5pt, fill: ink2)[Directory #mono(data.place + "/" + data.version + "/", size: 9pt) on the decodes share])

#block(below: 10pt, text(size: 8.5pt)[Made by build-pack.sh from #data.captures.rows.len() RF captures of the side: decoded by ld-decode, mapped, stacked and measured by decode-orc, and the data area stacked and verified by vfs-verifier, each at the exact revision in @tools. Every step is automatic except the selection of the sets, which is a person's (@selection); @pipeline lists the steps.])

// The best single video set for a measure, for a tile's detail line.
#let best(k) = { let b = data.key.at("best_" + k, default: none); if b == none [–] else [best single set #b.set: #b.value dB] }

#grid(columns: (1fr,) * 5, column-gutter: 6pt,
  tile("Stacked white SNR",
    if data.have_stack [#data.key.stack_white dB] else [–], best("white")),
  tile("Stacked black PSNR",
    if data.have_stack [#data.key.stack_black dB] else [–], best("black")),
  tile("Dropouts after stacking",
    if data.have_stack [#data.key.stack_dropouts] else [–],
    [best single set #data.key.best_dropouts_set: #data.key.best_dropouts]),
  tile("VFS image", data.vfs.verdict,
    [#(data.vfs.result); #data.vfs.objects objects, #data.vfs.objects_damaged damaged]),
  tile("Frames", data.metadata.frames,
    [pictures #(data.metadata.addresses); #data.metadata.undecoded_n undecoded]),
)

#if data.sample_text != "" { block(above: 8pt, text(size: 8pt, fill: ink2, data.sample_text)) }

#v(8pt)
#grid(columns: (1fr, 1fr), column-gutter: 14pt, row-gutter: 10pt,
  if "bars_white" in data.graphs { graph(data.graphs.bars_white) },
  if "bars_black" in data.graphs { graph(data.graphs.bars_black) },
  if "bars_dropouts" in data.graphs { graph(data.graphs.bars_dropouts) },
  [#heading(level: 2, numbering: none)[The pack]
#kv(
  ("Disc", [#data.title (#data.disc), #data.side]),
  ("Pack id", [#mono(data.id) — the first 16 hex digits of the sha256 of the three files' lines of SHA256SUMS. It names the files the player loads, not the directory]),
  ("Directory", [#mono(data.place + "/" + data.version + "/") on the decodes share; #mono(data.place + "/pack") points at the current pack]),
  ("Built", [#data.built, by build-pack.sh at #mono(data.script.commit)#if data.script.dirty [ (with uncommitted changes)]]),
  ("Video stack", data.video_sets.join(", ") + [, in stack order (the first sets the sample grid)]),
  ("VFS stack", data.vfs_sets.join(", ") + [, best first]),
)],
)

// --- the pipeline -----------------------------------------------------------------

= From RF to pack <pipeline>

build-pack.sh runs these steps in order. Each is a stage with its own directory on the decodes share, its outputs checked before it is stamped, and a key over everything it was made from, so a stage is built again only when one of its inputs changes. The checks column counts the checks over every stage of the step (one per set for decode and set); appendix A lists them all.

#tbl(data.pipeline, cols: (auto, auto, 2fr, 1.2fr, auto), size: 7.5pt)

// --- tools ----------------------------------------------------------------------

= Tools and their exact versions <tools>

Every tool is pinned by this repository's flake.lock and built by Nix, so a revision below names the exact source of the build that ran. The store paths are the builds themselves. A stage's stamp records the revision it ran with, and a pack is only built when every stage before it is up to date, so these are the tools behind every stage of this pack.

#for t in data.tools [
  == #t.name
  #kv(
    ("Revision", mono(t.rev)),
    ("Source", mono(t.source)),
    ("Nix hash", mono(t.nar)),
    ..if t.patches.len() > 0 { (("Patches", t.patches.map(((p, h)) => [#mono(p): #mono(h, size: 6.5pt)]).join(linebreak())),) },
  )
]

== The commands that ran
#tbl(data.binaries, mono-cols: (2,), wide: true, size: 7pt)

#v(4pt)
#text(size: 8pt, fill: ink2)[decode-orc's orc-cli and vfs-verifier's tools do not report a version of their own: their revision above, and the store path, identify them. The report itself is drawn by pack-python and set by typst, neither of which affects the pack's files.]

// --- sources ----------------------------------------------------------------------

= The RF captures

Each set is one RF capture of the disc, read from the capture library, which is only ever read. Its fingerprint is the sha256 of its first #data.head_bytes bytes and its size, as sources.sha256 records them. The video and VFS columns give its place in each stack.

#tbl(data.captures, mono-cols: (5,), wide: true, size: 7pt)
#v(4pt)
#tbl(data.fingerprints, mono-cols: (1,), size: 7pt)

= Decoding and mapping

== Decoding
Every set is decoded by ld-decode with the same flags: #for f in data.flags [#mono(f)]. Decoding starts at the start field shown (from the lead-in), and covers #data.frames frames.

#tbl(data.decodes)

== Mapping
The Disc Mapper puts each capture's frames in disc order: it pads pictures a capture skipped, drops duplicates and mixed frames, and removes frames it cannot place.

#tbl(data.mapping)

// --- selection ---------------------------------------------------------------------

= The selection <selection>

Which sets go into each stack is a person's decision, made from the compare stage's report (in the appendix) and committed as discs/#data.disc/selection.yaml, quoted here in full with its reasons. Pressing #data.pressing (the content version).

#block(width: 100%, inset: 8pt, radius: 3pt, fill: rgb("#f6f6f3"), raw(data.selection_text, block: true, lang: "yaml"))

// --- the video stack -------------------------------------------------------------------

= The video stack

The sets #data.video_sets.join(", ") are stacked by decode-orc's stacker, then dropout-corrected and written by the video sink with the #mono(data.decoder) chroma decoder as FFV1 in Matroska. #data.stacker_text#if data.noise_reduction != none [ #data.noise_reduction]

#if "weights" in data.graphs { graph(data.graphs.weights) }
#tbl(data.weights)
#text(size: 7.5pt, fill: ink2)[#data.records #data.trust#if data.sample_grid.len() > 0 [ Sample grid shifts: #data.sample_grid.map(s => [#s.set by #s.samples sample(s) from frame #s.from_frame]).join(", ").]]

#if data.gain.len() > 0 [
  == What the stacking is predicted to gain
  #data.gain_text
  #if "sigma" in data.graphs { graph(data.graphs.sigma) }
  #kv(..data.gain)
]

#if data.split_blocks.rows.len() > 0 [
  == Frames where the noise model was not trusted
  #data.untrusted_text
  #tbl(data.split_blocks, wide: true, size: 7pt)
]

== The stack's settings
As the video stage processed it (#mono(data.video_dir + "/stack.orcprj")), its sources aside.
#tbl(data.stack_params, mono-cols: (3,), wide: true, size: 7pt)

// --- the mkv ---------------------------------------------------------------------

= The video file

== Container
#data.packets packets, #data.keyframes keyframes (vp415e seeks to any frame, so every packet must be one).
#tbl(data.streams, wide: true)
#v(4pt)
#tbl(data.tags, mono-cols: (0, 1), size: 7pt)

== Disc metadata
The orc-disc-metadata document attached to the mkv, as vp415e reads it.
#kv(
  ("Frames", data.metadata.frames),
  ("Disc", data.metadata.disc),
  ("Status agreement", data.metadata.agreement),
  ("Address map", [#data.metadata.kind, pictures #data.metadata.addresses, #data.metadata.runs run(s), #data.metadata.missing missing]),
  ("Undecoded", [#data.metadata.undecoded_n frame(s), pictures #data.metadata.undecoded — numbered on the disc, not recovered; the address map implies their pictures]),
  ("Unmapped", [frames #data.metadata.unmapped (lead-in and lead-out)]),
  ..if data.metadata.baseline != none { (("Hand-built stack", [#data.metadata.baseline: #data.metadata.baseline_undecoded_n undecoded, pictures #data.metadata.baseline_undecoded]),) },
)

// --- quality ----------------------------------------------------------------------

= The stack against its sources

Every set is measured over every frame by decode-orc's SNR, dropout and burst level analyses (the set stage); the stack is measured by the same analyses, with the same settings, on the stacker's output before dropout correction (the quality stage). The frame maps put both on the frames of the pack's mkv, so each graph compares like with like. The graphs along the disc show one point per #data.bin frames.

#if data.sample_text != "" [#data.sample_text]

#tbl(data.quality)
#text(size: 7.5pt, fill: ink2)[#data.quality_key White SNR, its lowest frame, and black PSNR in dB; dropouts and their samples over the whole disc; burst level as a 10-bit median, mean over frames.]

Both picture measures come from the test signals in the vertical interval (VITS), so they measure the same thing on every frame whatever the picture: white SNR on the white flag, against its mean, and black PSNR on the black level reference, against peak white. Together they cover the luminance range. White SNR is read on the flat top of the bar, from 2 µs after its nominal start (decode-orc's SNR measurement 1.1.0, from decode-orc 1a152d6). Packs built on earlier decode-orc read the bar's rising edge as well, 4–6 dB lower and depending on the stack's first set, so their white SNR cannot be compared with this one's; black PSNR can.

They measure the test lines, not the picture. The stacker weights each set by a different measure: how much it differs from the others across the active picture. So the two can disagree. When they do, a set that reads best here may carry something in its picture that the test lines do not show, or the stacker may be counting as noise a difference that is not noise. Where the stack falls below a single set here, the loss in the picture can be much smaller than these graphs show. Noise that every set of one stamper group shares, recorded into the stamper, shows here and cannot be stacked away.#if data.have_mean [ The same stack in Mean, with every set weighted equally, is measured too (the dashed line). Where Mean reads better than the stack as built, the stacker's weights do not favour the sets these figures do.]

#for (k, name) in (("white", "White SNR"), ("black", "Black PSNR")) [
  == #name
  #if k in data.graphs { graph(data.graphs.at(k)) }
  #if ("gain_" + k) in data.graphs [
    #let g = data.key.at("gain_" + k)
    #graph(data.graphs.at("gain_" + k))
    #text(size: 8pt)[The stack is better than the best single set in #g.better of #g.bins blocks, worse in #g.worse (by more than 0.05 dB). Worst: #(g.worst).#if "vs_mean" in g [ Against the same stack in Mean, it is better in #g.weighted_better blocks and worse in #g.mean_better, and #g.vs_mean dB over the disc.]]
  ]
  #if ("distribution_" + k) in data.graphs { graph(data.graphs.at("distribution_" + k)) }
]

== Dropouts and burst level
#for k in ("dropouts", "burst") { if k in data.graphs { graph(data.graphs.at(k)) } }

== The analyses' settings
The quality stage's project (#mono(data.quality_dir + "/quality.orcprj")), its sources aside: the stack as the video stage builds it, measured by the analyses the set stage runs on each set.#if data.quality_mean_diff.rows.len() > 0 [ The stack in Mean (#mono("quality-mean.orcprj")) differs from it only in the rows of the second table.]
#tbl(data.quality_params, mono-cols: (3,), wide: true, size: 7pt)
#if data.quality_mean_diff.rows.len() > 0 {
  v(4pt)
  tbl(data.quality_mean_diff, mono-cols: (2,), wide: true, size: 7pt)
}

// --- EFM and VFS -------------------------------------------------------------------

= The data area: EFM and the VFS image

Each set's EFM is decoded to an image of 2048-byte sectors and a map of the sectors it could not recover (the set stage). vfs-stacker stacks the images of #data.vfs_sets.join(", ") by majority, and vfs-verifier reads the ADFS filesystem of the result.

== Each set's EFM decode
#tbl(data.efm, size: 7pt)
#text(size: 7.5pt, fill: ink2)[good, corrected, uncorrectable: sectors, from the EFM decode report. C1 and C2: uncorrectable codewords. used: sectors the stack took from the set.]

#if "sectors" in data.graphs { graph(data.graphs.sectors) }

== The stack
#kv(
  ("Result", [#data.vfs.result: #data.vfs.result_text]),
  ("Verdict", [#data.vfs.verdict (accepts #data.vfs.accept)]),
  ("Sectors", [#data.vfs.output_sectors in the image; #data.vfs.unanimous recovered by agreement, #data.vfs.majority by majority, #data.vfs.consensus by consensus; #data.vfs.contested contested, #data.vfs.disagreements disagreements]),
  ("Not recovered", [#data.vfs.bad: #data.vfs.unrecovered bad in every set, #data.vfs.padded padding; #data.vfs.union sectors were recovered by some set]),
  ("Over the best set", [#data.vfs.recovered_over_best sector(s) recovered that the best single set (#data.vfs.best) lacks]),
  ("Filesystem", [#if data.vfs.verify_passed [vfs-verifier passes the image] else [vfs-verifier does not pass the image]: free space map #(data.vfs.fsm); directory #(data.vfs.directory); #data.vfs.objects objects, #data.vfs.objects_damaged damaged]),
  ..if data.vfs.baseline != none { (("Hand-built image", data.vfs.baseline),) },
  ("Image", mono(data.vfs.image_sha256)),
  ("Bad sector map", mono(data.vfs.bsm_sha256)),
)

#grid(columns: (1fr, 1fr), column-gutter: 14pt,
  [== Where the bad sectors fall
  #tbl(data.vfs.roles)],
  [== The sets agree
  Wherever two sets both recovered a sector, they must hold the same bytes.
  #tbl(data.pairs)],
)

#if data.efm_params != none [
  == The EFM decoder's settings
  #tbl(data.efm_params, mono-cols: (3,), wide: true, size: 7pt)
]

// --- the pack --------------------------------------------------------------------------

= The pack

The pack stage makes a new pack version, #mono(data.version), from the video and vfs stages' outputs: it links the three files the player loads rather than copying them, checks them again as vp415e reads them (the container, every stream, the disc metadata against the container, the image and its bad sector map against the vfs stage's), hashes them into SHA256SUMS, and writes the provenance and this report. A pack is only built when every stage before it is up to date, and only stamped when every check passes; `pack` then points at it, and the previous version is kept.

#tbl(data.files, mono-cols: (2,))

// --- appendices ------------------------------------------------------------------------

#set heading(numbering: "A.1")
#counter(heading).update(0)

= Every stage's checks

Each stage checks its own outputs before it is stamped; a stage with a failed check is not stamped, and nothing after it is built.

#for s in data.stages [
  == #s.name
  #text(size: 7pt, fill: ink2, mono(s.dir, size: 7pt))
  #v(-2pt)
  #checks-list(s.checks)
]

= Every stage's stamp

A stage's key is the sha256 of its inputs: the captures' fingerprints, the tool revisions, its parameters and project files, and the keys of the stages before it. A stage whose key still matches its inputs is not built again.

#for s in data.stages [
  == #s.name
  #kv(("Key", mono(s.key, size: 6.5pt)), ("Stamped", [#s.stamped]))
  #v(2pt)
  #block(inset: (left: 8pt), text(size: 6.5pt, font: "IBM Plex Mono", s.inputs.join("\n")))
]

= The compare report
The evidence the selection was decided from, as the compare stage wrote it.
#text(size: 6pt, raw(data.compare_report, block: true))

= vfs-stacker and vfs-verifier
#text(size: 6pt, raw(data.vfs_stacker, block: true))
#text(size: 6pt, raw(data.vfs_verifier, block: true))

= SHA256SUMS
#text(size: 7pt, raw(data.sums, block: true))
