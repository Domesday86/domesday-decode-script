"""Make a pack's report: a PDF of everything the pack was made from and how.

    pack-python lib/pack-report.py <manifest.json> <report.pdf> --work DIR

build-pack.sh's pack stage writes the manifest, which names the pack's
provenance and every stage directory the pack was built from, and the tools
on PATH that built it. This reads those stages' own outputs -- each set's
per-frame SNR, dropout and burst figures and EFM image, the quality stage's
figures for the stack, the frame maps that put the two on one axis, the
stacker's log, the vfs stage's reports, every stage's stamp and checks --
draws the graphs (Matplotlib, as SVG) and the tables into DIR, and has typst
set lib/pack-report.typ over them as the PDF.

The report is made fresh with every pack build. It describes what the
automation did, from the RF captures to the pack it sits beside; it is a
record, not instructions.

Exits 1 if the report could not be made.
"""

import argparse
import csv
import json
import math
import os
import re
import subprocess
import sys
import time
from pathlib import Path

import matplotlib
import numpy as np

matplotlib.use("svg")
import matplotlib.pyplot as plt  # noqa: E402
from matplotlib import font_manager  # noqa: E402

# Frames per point on the graphs along the disc: the stacker measures its
# weights over blocks of this size, so the two line up.
BIN = 500

# The sets' colours, in set order, and the stack's: the reference categorical
# palette (validated for adjacent pairs, light surface), and primary ink. A
# disc with more sets than colours goes round the palette again, and the
# sets of the second round are told apart by their marks: dashed lines and
# hatched bars (SECOND_DASH, SECOND_HATCH).
SET_COLOURS = ["#2a78d6", "#eb6834", "#1baf7a", "#eda100", "#e87ba4", "#008300", "#6250d6", "#e34948"]
SECOND_DASH = (0, (4, 1.6))
SECOND_HATCH = "////"
STACK_COLOUR = "#0b0b0b"
INK, INK2, MUTED, GRID, AXIS = "#0b0b0b", "#52514e", "#898781", "#e1e0d9", "#c3c2b7"
GAIN, LOSS, NEUTRAL = "#2a78d6", "#e34948", "#c3c2b7"


# --- reading ------------------------------------------------------------------

def read_text(path, tail=None):
    """A file's text, or "" if it is not there; with tail, only its last bytes."""
    try:
        with open(path, "rb") as f:
            if tail:
                f.seek(max(0, os.path.getsize(path) - tail))
            return f.read().decode("utf-8", "replace")
    except OSError:
        return ""


def read_json(path):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def read_yaml(path):
    """YAML as the scripts' yq reads it (YAML 1.2): PyYAML reads 1.1, in which
    4:3 is the number 243 and off is false."""
    try:
        r = subprocess.run(["yq", "-o=json", ".", str(path)], capture_output=True, text=True, check=True)
        return json.loads(r.stdout)
    except (OSError, subprocess.CalledProcessError, ValueError):
        return None


def read_csv(path, column):
    """One column of an analysis sink's CSV, indexed by frame_number - 1 (the
    sinks number frames from 1), as floats with NaN where a frame is absent."""
    rows = {}
    try:
        with open(path, newline="") as f:
            for r in csv.DictReader(f):
                try:
                    rows[int(r["frame_number"]) - 1] = float(r[column])
                except (KeyError, ValueError):
                    pass
    except OSError:
        return np.array([])
    out = np.full(max(rows) + 1 if rows else 0, np.nan)
    for k, v in rows.items():
        out[k] = v
    return out


def read_ranges(path):
    """A frame map: for each frame of the mapped output, the source frame it
    reads, or None for padding."""
    out = []
    for t in read_text(path).replace(",", "\n").split():
        if t.startswith("PAD_"):
            out += [None] * int(t[4:])
        elif "-" in t:
            a, b = map(int, t.split("-"))
            out += range(a, b + 1)
        else:
            out.append(int(t))
    return out


def read_stamp(path):
    """A stage stamp: its stage, key, time and inputs."""
    s = {"stage": None, "key": None, "stamped": None, "inputs": []}
    for line in read_text(path).splitlines():
        k, _, v = line.partition(": ")
        if k in ("stage", "key"):
            s[k] = v
        elif k == "stamped" and v.isdigit():
            s[k] = int(v)
        elif k == "input":
            s["inputs"].append(v)
    return s if s["key"] else None


def read_checks(path):
    """The check lines of a check.txt, as (level, text)."""
    out = []
    for line in read_text(path).splitlines():
        m = re.match(r"^(ok|note|FAIL)\s+(.*)$", line)
        if m:
            out.append((m.group(1).lower(), m.group(2)))
        elif line.startswith("result: "):
            out.append(("result", line[8:]))
    return out


def read_bsm(path):
    """A bad sector map: one sector number a line."""
    return np.array([int(t) for t in read_text(path).split() if t.isdigit()], dtype=np.int64)


def project_parameters(path):
    """Each stage of an orc project but its sources, with its parameters."""
    doc = read_yaml(path) or {}
    out = []
    for n in (doc.get("dag") or {}).get("nodes") or []:
        if n.get("node_type") == "SOURCE":
            continue
        params = {}
        for k, v in sorted((n.get("parameters") or {}).items()):
            value = v.get("value") if isinstance(v, dict) else v
            params[k] = value
        out.append({"label": n.get("user_label") or n.get("display_name"), "stage": n.get("stage"), "parameters": params})
    return out


RECORD = "StackerStage report: "


def stacker_blocks(log, sets, n):
    """The stacker's weights over the stack of n frames, from its report
    records of kind weights: the noise and share of each input (None for one
    not measured), the stamper group of each, whether its noise model was
    trusted or the frames fell back to equal weights, and the noise σ the
    model predicts for the stack as weighted, for the stack in equal weights
    and for the best single set. The stacker measures every block of frames
    but writes a record only when the weights or its trust in the model
    change, so each record holds from its block to the next record's: "to"
    is where it stops holding, "frames" how many it holds for. Frames count
    from 1, as the records do."""
    out = []
    for line in log.splitlines():
        at = line.find(RECORD)
        if at < 0:
            continue
        try:
            r = json.loads(line[at + len(RECORD):])
        except ValueError:
            continue
        if r.get("v") != 1 or r.get("kind") != "weights" or len(r.get("inputs") or []) != len(sets):
            continue
        inputs = r["inputs"]
        out.append({"from": r["frames"][0], "to": r["frames"][1],
                    "sigma": [i.get("sigma") for i in inputs],
                    "share": [i.get("share") if i.get("sigma") is not None else None for i in inputs],
                    "groups": [i.get("stamperGroup") for i in inputs],
                    "fit_trusted": r.get("fitTrusted"), "fell_back_to_mean": r.get("fellBackToMean"),
                    "weighted_sigma": r.get("weightedSigma"), "equal_sigma": r.get("equalSigma"),
                    "best_single_sigma": r.get("bestSingleSigma"),
                    "worst_pair": [sets[i - 1] for i in r["worstPair"]] if r.get("worstPair") else None,
                    "worst_misfit": r.get("worstMisfitPercent")})
    out.sort(key=lambda b: b["from"])
    for k, b in enumerate(out):
        b["to"] = out[k + 1]["from"] - 1 if k + 1 < len(out) else max(n, b["to"])
        b["frames"] = b["to"] - b["from"] + 1
    return out


# The stacker, and the keys of its tables, as the Markdown and the PDF give
# them.
STACKER_TEXT = ("The stacker measures each input's noise on the flat areas of the picture, in blocks of frames, and fits "
                "a model in which sets cut from one stamper share its noise (a stamper group) and stamper groups cut from "
                "one mother share theirs (a family). It weights each set by what it adds under that model, so a set "
                "alone in its stamper group, whose noise no other set carries, adds the most. Where the model does not "
                "explain the sets' differences, the block is stacked with equal weights. It stacks repeats too: a "
                "picture held over several frames is stacked across them as well as across the sets.")
UNTRUSTED_TEXT = ("A selection holds the sets of one content version of the disc, which may be cut from several stampers. "
                  "Over these frames the stacker's noise model did not explain how the sets differ, so its weights are not "
                  "the model's; frames that fell back were stacked with equal weights.")
GAIN_TEXT = ("Both predictions are of the noise σ left in the stack, in 10-bit codes, from the sets' noise measured on the "
             "flat areas of the picture: Source Alignment's over the whole disc, when the sets were compared (the map "
             "stage), and the stacker's in each block it stacked. Equal weights is the same sets in Mean; the best single "
             "set is the least noisy set alone. These predict the picture; section 8 measures the test lines.")
QUALITY_KEY = ("group: the set's stamper group, as Source Alignment found it. "
               "noise σ, adds, weight and 5–6 MHz response: Source Alignment's capture comparison (10-bit codes). noise σ is "
               "the set's own noise; adds is the predicted noise σ of the stack without the set, the higher the more it "
               "adds; weight is its share of the Weighted stack of every set compared; a response of 1 is typical.")


def sample_text(sample, n):
    """What the stack was measured on, when it was a sample; empty otherwise."""
    if not sample:
        return ""
    blocks = [f"{a}–{b}" for a, b in sample.get("blocks") or []]
    return (f"The stack is measured on a sample of {sample.get('frames'):,} of its {n:,} frames, at the beginning, the "
            f"middle and the end of the side: frames {', '.join(blocks[:-1])} and {blocks[-1]}. Wherever it is set against the "
            "sets, the figures at the top, the bars and the graphs, the sets are taken over the same frames; the sets' own "
            "rows of the table are over every frame, and the stack's rows over the sample.")


# --- figures ------------------------------------------------------------------

def fmt(v, digits=2, unit=""):
    if v is None or (isinstance(v, float) and math.isnan(v)):
        return "–"
    if isinstance(v, (int, np.integer)) and not isinstance(v, bool):
        return f"{v:,}{unit}".replace(",", " ")
    if isinstance(v, (float, np.floating)):
        return f"{v:.{digits}f}{unit}"
    return f"{v}{unit}"


def bins(values, n):
    """The mean of values over each BIN frames of n, and the bin centres."""
    v = np.full(n, np.nan)
    m = min(n, len(values))
    v[:m] = values[:m]
    edges = np.arange(0, n, BIN)
    means = np.array([np.nanmean(v[a:a + BIN]) if np.isfinite(v[a:a + BIN]).any() else np.nan for a in edges])
    sums = np.array([np.nansum(v[a:a + BIN]) if np.isfinite(v[a:a + BIN]).any() else np.nan for a in edges])
    return edges + min(BIN, n) / 2, means, sums


def on_stack(values, frame_map, offset, n):
    """A set's per-frame figures moved onto the stack's frames: frame
    offset + i of the stack is frame frame_map[i] of the set."""
    out = np.full(n, np.nan)
    for i, f in enumerate(frame_map):
        j = offset + i
        if f is not None and 0 <= j < n and f < len(values):
            out[j] = values[f]
    return out


# --- graphs -------------------------------------------------------------------

def style():
    fonts = os.environ.get("PACK_REPORT_FONTS")
    family = "DejaVu Sans"
    if fonts:
        for p in Path(fonts).rglob("IBMPlexSans-*.otf"):
            font_manager.fontManager.addfont(str(p))
        family = "IBM Plex Sans"
    plt.rcParams.update({
        "font.family": family, "font.size": 8, "svg.fonttype": "none", "svg.hashsalt": "pack-report",
        "axes.edgecolor": AXIS, "axes.linewidth": 0.6, "axes.labelcolor": INK2, "axes.titlesize": 9,
        "axes.titlecolor": INK, "axes.titleweight": "semibold", "axes.titlelocation": "left", "axes.titlepad": 22,
        "axes.spines.top": False, "axes.spines.right": False, "axes.grid": True, "axes.axisbelow": True,
        "grid.color": GRID, "grid.linewidth": 0.5, "xtick.color": MUTED, "ytick.color": MUTED,
        "xtick.labelcolor": INK2, "ytick.labelcolor": INK2, "xtick.major.size": 0, "ytick.major.size": 0,
        "legend.frameon": False, "legend.fontsize": 7.5, "figure.dpi": 100,
        "savefig.transparent": True, "savefig.bbox": "tight", "savefig.pad_inches": 0.04,
    })


def save(fig, work, name):
    path = work / f"{name}.svg"
    fig.savefig(path, metadata={"Date": None})
    plt.close(fig)
    return name + ".svg"


def legend_row(ax, ncol):
    ax.legend(loc="lower left", bbox_to_anchor=(0, 1.0), ncol=ncol, handlelength=1.6, columnspacing=1.2, borderaxespad=0.2)


def frame_axis(ax, n):
    ax.set_xlim(0, n)
    ax.set_xlabel("frame of the pack's mkv")
    ax.xaxis.set_major_formatter(matplotlib.ticker.FuncFormatter(lambda x, _: f"{int(x):,}".replace(",", " ")))


def line_graph(work, name, title, ylabel, n, series, stack, log=False, mean=None):
    """Sources as thin lines in their colours, the stack thicker in ink, along
    the disc; with mean, the same stack in Mean as a dashed ink line."""
    fig, ax = plt.subplots(figsize=(7.0, 2.5))
    for s in series:
        ax.plot(s["x"], s["y"], color=s["colour"], lw=0.9, ls=s.get("ls", "-"), label=s["set"])
    if mean is not None:
        ax.plot(mean["x"], mean["y"], color=STACK_COLOUR, lw=1.0, ls=(0, (3, 2)), label="Stack in Mean")
    if stack is not None:
        ax.plot(stack["x"], stack["y"], color=STACK_COLOUR, lw=1.8, label="Stack")
        # A point with no finite neighbour draws no line, so it is a dot.
        ok = np.isfinite(stack["y"])
        alone = ok & ~np.r_[False, ok[:-1]] & ~np.r_[ok[1:], False]
        ax.scatter(stack["x"][alone], stack["y"][alone], s=14, color=STACK_COLOUR, zorder=3)
        last = np.where(ok)[0]
        if len(last):
            ax.annotate("Stack", (stack["x"][last[-1]], stack["y"][last[-1]]), xytext=(4, 0), textcoords="offset points",
                        va="center", fontsize=7.5, color=INK, fontweight="semibold", annotation_clip=False)
    if log:
        ax.set_yscale("log")
    ax.set_ylabel(ylabel)
    frame_axis(ax, n)
    ax.set_title(title)
    legend_row(ax, len(series) + 1 + (mean is not None))
    return save(fig, work, name)


# The two picture measures: white SNR and black PSNR, as the SNR analysis
# writes them, each with how a graph names it.
MEASURES = (("white", "white SNR", "White SNR", "mean_white_snr"), ("black", "black PSNR", "Black PSNR", "mean_black_psnr"))


def gain_graph(work, key, label, x, gain, n):
    fig, ax = plt.subplots(figsize=(7.0, 2.0))
    colours = [GAIN if g >= 0 else LOSS for g in np.nan_to_num(gain)]
    ax.bar(x, np.nan_to_num(gain), width=BIN * 0.82, color=colours, linewidth=0)
    ax.axhline(0, color=AXIS, lw=0.8)
    ax.set_ylabel("dB")
    frame_axis(ax, n)
    ax.set_title(f"{label[0].upper()}{label[1:]} of the stack, less the best single set's, per 500 frames")
    ax.legend(handles=[matplotlib.patches.Patch(color=GAIN, label="stack better"),
                       matplotlib.patches.Patch(color=LOSS, label="stack worse")],
              loc="lower left", bbox_to_anchor=(0, 1.0), ncol=2, borderaxespad=0.2)
    return save(fig, work, f"{key}-gain")


def distribution_graph(work, key, label, sets, stack, over="every frame"):
    """Per-frame white SNR or black PSNR, as the share of frames at each 0.25 dB,
    over the frames named by over."""
    allv = np.concatenate([s["v"][np.isfinite(s["v"])] for s in sets + ([stack] if stack else [])])
    lo, hi = np.percentile(allv, 0.2), np.percentile(allv, 99.9)
    edges = np.arange(math.floor(lo * 4) / 4, hi + 0.25, 0.25)
    fig, ax = plt.subplots(figsize=(7.0, 2.4))
    for s in sets + ([stack] if stack else []):
        v = s["v"][np.isfinite(s["v"])]
        h, _ = np.histogram(v, bins=edges)
        ax.step(edges[:-1], 100 * h / max(1, len(v)), where="post", color=s["colour"],
                lw=1.8 if s is stack else 0.9, ls=s.get("ls", "-"), label=s["set"])
    ax.set_xlim(edges[0], edges[-1])
    ax.set_xlabel(f"{label} of a frame (dB)")
    ax.set_ylabel("% of frames")
    ax.set_title(f"Per-frame {label}, {over} of each set and of the stack")
    legend_row(ax, len(sets) + 1)
    return save(fig, work, f"{key}-distribution")


def summary_bars(work, name, title, unit, rows, digits=2, dots=False):
    """One mark per set and one for the stack, each labelled with its value:
    bars from zero for a count, dots for a level (dB), whose zero means
    nothing and would hide the differences."""
    fig, ax = plt.subplots(figsize=(3.4, 0.28 * len(rows) + 0.7))
    y = np.arange(len(rows))[::-1]
    vals = [r["value"] for r in rows]
    lo, hi = min(vals), max(vals)
    span = hi - lo if hi > lo else abs(hi) or 1
    if dots:
        ax.scatter(vals, y, s=42, color=[r["colour"] for r in rows], edgecolors="white", linewidths=1.2, zorder=3)
        ax.set_xlim(lo - span * 0.25, hi + span * 0.35)
    else:
        ax.barh(y, vals, height=0.62, color=[r["colour"] for r in rows], linewidth=0)
        ax.set_xlim(0, hi * 1.3)
        ax.xaxis.set_major_locator(matplotlib.ticker.MaxNLocator(4))
        ax.xaxis.set_major_formatter(matplotlib.ticker.FuncFormatter(lambda x, _: f"{int(x):,}".replace(",", "\u2009")))
    for yy, r in zip(y, rows):
        ax.annotate(fmt(r["value"], digits), (r["value"], yy), xytext=(7 if dots else 3, 0), textcoords="offset points",
                    va="center", fontsize=7.5, color=INK)
    ax.set_yticks(y, [r["set"] for r in rows])
    ax.grid(axis="y", visible=False)
    ax.set_xlabel(unit)
    ax.set_title(title)
    return save(fig, work, name)


def weights_graph(work, blocks, sets, colours, dashes, n):
    fig, ax = plt.subplots(figsize=(7.0, 2.6))
    # The records count frames from 1; the axis, as every graph's, from 0.
    x = np.array([b["from"] - 1 for b in blocks])
    width = np.array([b["frames"] for b in blocks])
    bottom = np.zeros(len(blocks))
    for i, s in enumerate(sets):
        share = np.array([b["share"][i] or 0 for b in blocks])
        ax.bar(x, share, bottom=bottom, width=width, align="edge", color=colours[s], edgecolor="white", linewidth=0.3,
               hatch=SECOND_HATCH if dashes[s] != "-" else None, label=s)
        bottom += share
    split = [b for b in blocks if b["fit_trusted"] is False]
    if split:
        ax.plot([(b["from"] - 1 + b["to"]) / 2 for b in split], [106] * len(split), "v", ms=4, color=INK2,
                label="model not trusted", clip_on=False)
    ax.set_ylim(0, 110)
    ax.set_yticks([0, 20, 40, 60, 80, 100])
    ax.set_ylabel("share of the weight (%)")
    frame_axis(ax, n)
    ax.grid(axis="x", visible=False)
    ax.set_title("The stacker's weight for each set along the disc, each record held until the next")
    legend_row(ax, len(sets) + (1 if split else 0))
    return save(fig, work, "weights")


def sigma_graph(work, blocks, n):
    """The noise σ the stacker predicts in each block: the best single set
    alone, the sets in equal weights, and the stack as weighted."""
    fig, ax = plt.subplots(figsize=(7.0, 2.4))
    edges = [b["from"] - 1 for b in blocks] + [blocks[-1]["to"]]

    def y(k):
        return np.array([b[k] if b[k] is not None else np.nan for b in blocks], dtype=float)

    ax.stairs(y("best_single_sigma"), edges, color=MUTED, lw=1.0, baseline=None, label="best single set")
    ax.stairs(y("equal_sigma"), edges, color=STACK_COLOUR, lw=1.0, ls=(0, (3, 2)), baseline=None, label="equal weights")
    ax.stairs(y("weighted_sigma"), edges, color=STACK_COLOUR, lw=1.8, baseline=None, label="Weighted, as stacked")
    split = [b for b in blocks if b["fit_trusted"] is False]
    if split:
        top = np.nanmax(y("best_single_sigma"))
        ax.plot([(b["from"] - 1 + b["to"]) / 2 for b in split], [top * 1.06] * len(split), "v", ms=4, color=INK2,
                label="model not trusted", clip_on=False)
    ax.set_ylim(bottom=0)
    ax.set_ylabel("predicted noise σ (10-bit)")
    frame_axis(ax, n)
    ax.set_title("The noise the stacker predicts for the stack along the disc, each record held until the next")
    legend_row(ax, 3 + (1 if split else 0))
    return save(fig, work, "sigma")


def sector_graph(work, union, rows):
    """Where each set fails, among the sectors any set recovered, with the
    image's sector numbers on the axis."""
    fig, ax = plt.subplots(figsize=(7.0, 0.32 * len(rows) + 0.9))
    for k, r in enumerate(rows[::-1]):
        pos = np.searchsorted(union, r["bad"])
        if len(pos):
            ax.vlines(pos, k - 0.34, k + 0.34, color=r["colour"], lw=0.6)
        ax.annotate(f"{len(r['bad']):,}".replace(",", " "), (len(union), k), xytext=(4, 0),
                    textcoords="offset points", va="center", fontsize=7.5, color=INK, annotation_clip=False)
    ax.set_yticks(range(len(rows)), [r["set"] for r in rows[::-1]])
    ax.set_ylim(-0.6, len(rows) - 0.4)
    ax.set_xlim(0, len(union))
    ticks = np.linspace(0, len(union) - 1, 6).astype(int)
    ax.set_xticks(ticks, [f"{int(union[t]):,}".replace(",", " ") for t in ticks])
    ax.grid(axis="y", visible=False)
    ax.set_xlabel(f"sector of the image, over the {len(union):,} sectors some set recovered (the rest are not recorded on any capture)".replace(",", " "))
    ax.set_title("Sectors each set could not recover, and the stack (count at the right)")
    return save(fig, work, "sectors")


# --- the report ---------------------------------------------------------------

def table(header, rows, align=None, widths=None):
    return {"header": header, "rows": [[fmt(c) if not isinstance(c, str) else c for c in r] for r in rows],
            "align": align or ["left"] + ["right"] * (len(header) - 1), "widths": widths}


# --- the Markdown report ------------------------------------------------------
#
# The PDF's content, section for section, from the same data, for reading
# where a PDF is awkward (by an AI, say). The graphs are the PDF's own SVGs,
# linked from the report's working directory; their text is kept as text.

def single_source(vfs):
    """The needed sectors that rest on one set, as one line, or None when there are none."""
    n = (vfs.get("stack") or {}).get("vital_only") or 0
    if not n:
        return None
    lines = vfs.get("single_source") or []
    return (f"{n} sector(s) the filesystem needs were recovered by one set alone"
            + (f" (vfs.accept: {vfs['accept']})" if vfs.get("accept") == "single-source" else "")
            + ("; " + "; ".join(lines) if lines else ""))


def vfs_baseline(b):
    """The vfs stage's comparison with the hand-built image, as one line, or None without one."""
    if not b or b.get("compared") is None:
        return None
    diff, known = b.get("differing") or [], b.get("known") or []
    if not diff:
        same = f"the same bytes in all {fmt(b['compared'])} sectors both recovered"
    elif sorted(diff) == sorted(known):
        same = (f"the same bytes in all {fmt(b['compared'])} sectors both recovered but {len(diff)}, the ones selection.yaml "
                "records as known and explains (vfs.baseline_differs)")
    else:
        same = f"{len(diff)} of the {fmt(b['compared'])} sectors both recovered differ"
    ours, theirs = b.get("ours") or {}, b.get("theirs") or {}
    return f"{same}; {fmt(ours.get('bad'))} bad sectors here, {fmt(theirs.get('bad'))} there"


def markdown(data, graphs):
    out = []
    w = out.append

    def cell(c):
        return str(c if c is not None else "–").replace("|", "\\|").replace("\n", " ")

    def tbl(t):
        if not t or not t.get("rows"):
            return
        al = {"left": ":---", "right": "---:", "center": ":---:"}
        w("| " + " | ".join(cell(h) for h in t["header"]) + " |")
        w("|" + "|".join(al.get(a, "---") for a in t["align"]) + "|")
        for r in t["rows"]:
            w("| " + " | ".join(cell(c) for c in r) + " |")
        w("")

    def kv(pairs):
        for k, v in pairs:
            w(f"- **{k}:** {v}")
        w("")

    def graph(key):
        name = (data.get("graphs") or {}).get(key)
        if name:
            w(f"![{key.replace('_', ' ')}]({graphs}/{name})")
            w("")

    def code(text, lang=""):
        w(f"```{lang}")
        w((text or "").rstrip("\n"))
        w("```")
        w("")

    k, md, v = data.get("key") or {}, data.get("metadata") or {}, data.get("vfs") or {}
    best = {m: (k.get(f"best_{m}") or {}) for m in ("white", "black")}
    stack = lambda key: f"{k.get(key)} dB" if data.get("have_stack") and k.get(key) else "–"
    tools = {t["name"]: t for t in data.get("tools") or []}

    w(f"# {data['title']}: VP415e pack report")
    w("")
    w(f"{data['side']} · `{data['stem']}` · pack `{data['id']}`  ")
    w(f"Directory `{data['place']}/{data['version']}/` on the decodes share")
    w("")
    efm = data.get("has_efm", True)
    w(f"Made by build-pack.sh from {len((data.get('captures') or {}).get('rows') or [])} RF captures of the side: decoded by "
      "ld-decode, mapped, stacked and measured by decode-orc"
      + (", and the data area stacked and verified by vfs-verifier, each" if efm else ", each")
      + " at the exact revision in section 2. Every step is automatic except the selection of the sets, which is a person's "
      "(section 5); section 1 lists the steps."
      + ("" if efm else " The side has no EFM, so it has no data area, and the pack is the mkv alone.")
      + " This is the PDF report's content as Markdown; the graphs are its SVGs.")
    w("")
    w("| Stacked white SNR | Stacked black PSNR | Dropouts after stacking |" + (" VFS image |" if efm else "") + " Frames |")
    w("|---|---|---|" + ("---|" if efm else "") + "---|")
    w(f"| {stack('stack_white')} | {stack('stack_black')} | {k.get('stack_dropouts', '–') if data.get('have_stack') else '–'} "
      + (f"| {v.get('verdict', '–')} " if efm else "") + f"| {md.get('frames', '–')} |")
    w(f"| best single set {best['white'].get('set', '–')}: {best['white'].get('value', '–')} dB "
      f"| best single set {best['black'].get('set', '–')}: {best['black'].get('value', '–')} dB "
      f"| best single set {k.get('best_dropouts_set', '–')}: {k.get('best_dropouts', '–')} "
      + (f"| {v.get('result', '–')}; {v.get('objects', '–')} objects, {v.get('objects_damaged', '–')} damaged " if efm else "")
      + f"| pictures {md.get('addresses', '–')}; {md.get('undecoded_n', '–')} undecoded |")
    w("")
    if data.get("sample_text"):
        w(data["sample_text"])
        w("")
    for g in ("bars_white", "bars_black", "bars_dropouts"):
        graph(g)
    w("## The pack")
    w("")
    sc = data.get("script") or {}
    kv([("Disc", f"{data['title']} ({data['disc']}), {data['side']}"),
        ("Pack id", f"`{data['id']}`: the first 16 hex digits of the sha256 of "
                    + ("the three files' lines" if efm else "the mkv's line") + " of SHA256SUMS. "
                    "It names the files the player loads, not the directory"),
        ("Directory", f"`{data['place']}/{data['version']}/` on the decodes share; `{data['place']}/pack` points at the current pack"),
        ("Built", f"{data.get('built', '–')}, by build-pack.sh at `{sc.get('commit', '–')}`" + (" (with uncommitted changes)" if sc.get("dirty") else "")),
        ("Video stack", ", ".join(data.get("video_sets") or []) + ", in stack order (the first sets the sample grid)"),
        ("VFS stack", ", ".join(data.get("vfs_sets") or []) + ", best first" if efm else "none: the side has no EFM")])

    w("## 1 From RF to pack")
    w("")
    w("build-pack.sh runs these steps in order. Each is a stage with its own directory on the decodes share, its outputs "
      "checked before it is stamped, and a key over everything it was made from, so a stage is built again only when one "
      "of its inputs changes. The checks column counts the checks over every stage of the step (one per set for decode "
      "and set); appendix A lists them all.")
    w("")
    tbl(data.get("pipeline"))

    w("## 2 Tools and their exact versions")
    w("")
    w("Every tool is pinned by this repository's flake.lock and built by Nix, so a revision below names the exact source "
      "of the build that ran. The store paths are the builds themselves. A stage's stamp records the revision it ran "
      "with, and a pack is only built when every stage before it is up to date, so these are the tools behind every "
      "stage of this pack.")
    w("")
    for i, t in enumerate(data.get("tools") or [], 1):
        w(f"### 2.{i} {t['name']}")
        w("")
        pairs = [("Revision", f"`{t['rev']}`"), ("Source", f"`{t['source']}`"), ("Nix hash", f"`{t['nar']}`")]
        if t.get("patches"):
            pairs.append(("Patches", "; ".join(f"`{pn}`: `{ph}`" for pn, ph in t["patches"])))
        kv(pairs)
    w(f"### 2.{len(tools) + 1} The commands that ran")
    w("")
    tbl(data.get("binaries"))
    w(("decode-orc's orc-cli and vfs-verifier's tools do not" if efm else "decode-orc's orc-cli does not")
      + " report a version of their own: their revision above, and the "
      "store path, identify them. The report itself is drawn by pack-python and set by typst, neither of which affects "
      "the pack's files.")
    w("")

    w("## 3 The RF captures")
    w("")
    w(f"Each set is one RF capture of the disc, read from the capture library, which is only ever read. Its fingerprint "
      f"is the sha256 of its first {data.get('head_bytes', '–')} bytes and its size, as sources.sha256 records them. The "
      + ("video and VFS columns give its place in each stack." if efm else "video column gives its place in the stack."))
    w("")
    tbl(data.get("captures"))
    tbl(data.get("fingerprints"))

    w("## 4 Decoding and mapping")
    w("")
    w("### 4.1 Decoding")
    w("")
    w(f"Every set is decoded by ld-decode with the same flags: {' '.join(f'`{f}`' for f in data.get('flags') or [])}. "
      f"Decoding starts at the start field shown (from the lead-in), and covers {data.get('frames', '–')} frames. fps is "
      "ld-decode's own rate, after its setup.")
    w("")
    tbl(data.get("decodes"))
    w("### 4.2 Mapping")
    w("")
    w("The Disc Mapper puts each capture's frames in disc order: it pads pictures a capture skipped, drops duplicates and "
      "mixed frames, and removes frames it cannot place.")
    w("")
    tbl(data.get("mapping"))

    w("## 5 The selection")
    w("")
    w(f"Which sets go into each stack is a person's decision, made from the compare stage's report (in the appendix) and "
      f"committed as discs/{data['disc']}/selection.yaml, quoted here in full with its reasons. Pressing {data.get('pressing')} (the content version).")
    w("")
    code(data.get("selection_text"), "yaml")

    w("## 6 The video stack")
    w("")
    w(f"The sets {', '.join(data.get('video_sets') or [])} are stacked by decode-orc's stacker, then dropout-corrected and "
      f"written by the video sink with the `{data.get('decoder')}` chroma decoder as FFV1 in Matroska. {STACKER_TEXT}"
      + (f" {data['noise_reduction']}" if data.get("noise_reduction") else ""))
    w("")
    graph("weights")
    tbl(data.get("weights"))
    grid = data.get("sample_grid") or []
    w(f"{data.get('records')} {data.get('trust')}"
      + (" Sample grid shifts: " + ", ".join(f"{g['set']} by {g['samples']} sample(s) from frame {g['from_frame']}" for g in grid) + "." if grid else ""))
    w("")
    n = 1
    if data.get("gain"):
        w(f"### 6.{n} What the stacking is predicted to gain")
        w("")
        w(data["gain_text"])
        w("")
        graph("sigma")
        kv(data["gain"])
        n += 1
    if (data.get("split_blocks") or {}).get("rows"):
        w(f"### 6.{n} Frames where the noise model was not trusted")
        w("")
        w(UNTRUSTED_TEXT)
        w("")
        tbl(data["split_blocks"])
        n += 1
    w(f"### 6.{n} The stack's settings")
    w("")
    w(f"As the video stage processed it (`{data.get('video_dir')}/stack.orcprj`), its sources aside.")
    w("")
    tbl(data.get("stack_params"))

    w("## 7 The video file")
    w("")
    w("### 7.1 Container")
    w("")
    w(f"{data.get('packets')} packets, {data.get('keyframes')} keyframes (vp415e seeks to any frame, so every packet must be one).")
    w("")
    tbl(data.get("streams"))
    tbl(data.get("tags"))
    w("### 7.2 Disc metadata")
    w("")
    w("The orc-disc-metadata document attached to the mkv, as vp415e reads it.")
    w("")
    pairs = [("Frames", md.get("frames")), ("Disc", md.get("disc")), ("Status agreement", md.get("agreement")),
             ("Address map", f"{md.get('kind')}, pictures {md.get('addresses')}, {md.get('runs')} run(s), {md.get('missing')} missing"),
             ("Undecoded", f"{md.get('undecoded_n')} frame(s), pictures {md.get('undecoded')}: numbered on the disc, not "
                           "recovered; the address map implies their pictures"),
             ("Unmapped", f"frames {md.get('unmapped')} (lead-in and lead-out)")]
    if md.get("baseline"):
        pairs.append(("Hand-built stack", f"{md['baseline']}: {md.get('baseline_undecoded_n')} undecoded, pictures {md.get('baseline_undecoded')}"))
    kv(pairs)

    w("## 8 The stack against its sources")
    w("")
    w("Every set is measured over every frame by decode-orc's SNR, dropout and burst level analyses (the set stage); the "
      "stack is measured by the same analyses, with the same settings, on the stacker's output before dropout correction "
      "(the quality stage). The frame maps put both on the frames of the pack's mkv, so each graph compares like with "
      f"like. The graphs along the disc show one point per {data.get('bin')} frames.")
    w("")
    if data.get("sample_text"):
        w(data["sample_text"])
        w("")
    tbl(data.get("quality"))
    w(f"{QUALITY_KEY} White SNR, its lowest frame, and black PSNR in dB; dropouts and their samples over the whole disc; burst level as a "
      "10-bit median, mean over frames.")
    w("")
    w("Both picture measures come from the test signals in the vertical interval (VITS), so they measure the same thing on "
      "every frame whatever the picture: white SNR on the white flag, against its mean, and black PSNR on the black level "
      "reference, against peak white. Together they cover the luminance range. "
      "White SNR is read on the flat top of the bar, from 2 µs after its nominal start (decode-orc's SNR measurement "
      "1.1.0, from decode-orc 1a152d6). Packs built on earlier decode-orc read the bar's rising edge as well, 4–6 dB "
      "lower and depending on the stack's first set, so their white SNR cannot be compared with this one's; black PSNR can.")
    w("")
    w("They measure the test lines, not the picture. The stacker weights each set by a different measure: how much it "
      "differs from the others across the active picture. So the two can disagree. When they do, a set that reads best "
      "here may carry something in its picture that the test lines do not show, or the stacker may be counting as noise "
      "a difference that is not noise. Where the stack falls below a single set here, the loss in the picture can be much "
      "smaller than these graphs show. Noise that every set of one stamper group shares, recorded into the stamper, shows here "
      "and cannot be stacked away."
      + (" The same stack in Mean, with every set weighted equally, is measured too (the dashed line). Where Mean reads "
         "better than the stack as built, the stacker's weights do not favour the sets these figures do." if data.get("have_mean") else ""))
    w("")
    for i, (m, name) in enumerate((("white", "White SNR"), ("black", "Black PSNR")), 1):
        w(f"### 8.{i} {name}")
        w("")
        graph(m)
        g = k.get(f"gain_{m}")
        if g and f"gain_{m}" in (data.get("graphs") or {}):
            graph(f"gain_{m}")
            w(f"The stack is better than the best single set in {g['better']} of {g['bins']} blocks, worse in {g['worse']} "
              f"(by more than 0.05 dB). Worst: {g['worst']}."
              + (f" Against the same stack in Mean, it is better in {g['weighted_better']} blocks and worse in "
                 f"{g['mean_better']}, and {g['vs_mean']} dB over the disc." if "vs_mean" in g else ""))
            w("")
        graph(f"distribution_{m}")
    w("### 8.3 Dropouts and burst level")
    w("")
    graph("dropouts")
    graph("burst")
    w("### 8.4 The analyses' settings")
    w("")
    w(f"The quality stage's project (`{data.get('quality_dir')}/quality.orcprj`), its sources aside: the stack as the video "
      "stage builds it, measured by the analyses the set stage runs on each set."
      + (" The stack in Mean (`quality-mean.orcprj`) differs from it only in the rows of the second table." if (data.get("quality_mean_diff") or {}).get("rows") else ""))
    w("")
    tbl(data.get("quality_params"))
    tbl(data.get("quality_mean_diff"))

    # Section 9, the data area, only on a side with EFM; the pack follows it.
    pack_n = 10 if efm else 9
    if efm:
        w("## 9 The data area: EFM and the VFS image")
        w("")
        w(f"Each set's EFM is decoded to an image of 2048-byte sectors and a map of the sectors it could not recover (the set "
          f"stage). vfs-stacker stacks the images of {', '.join(data.get('vfs_sets') or [])} by majority, and vfs-verifier "
          "reads the ADFS filesystem of the result.")
        w("")
        w("### 9.1 Each set's EFM decode")
        w("")
        tbl(data.get("efm"))
        w("good, corrected, uncorrectable: sectors, from the EFM decode report. C1 and C2: uncorrectable codewords. used: "
          "sectors the stack took from the set.")
        w("")
        graph("sectors")
        w("### 9.2 The stack")
        w("")
        kv([("Result", f"{v.get('result')}: {v.get('result_text')}"),
            ("Verdict", f"{v.get('verdict')} (accepts {v.get('accept')})"),
            ("Sectors", f"{v.get('output_sectors')} in the image; {v.get('unanimous')} recovered by agreement, {v.get('majority')} "
                        f"by majority, {v.get('consensus')} by consensus; {v.get('contested')} contested, {v.get('disagreements')} disagreements"),
            ("Not recovered", f"{v.get('bad')}: {v.get('unrecovered')} bad in every set, {v.get('padded')} padding; "
                              f"{v.get('union')} sectors were recovered by some set"),
            ("Over the best set", f"{v.get('recovered_over_best')} sector(s) recovered that the best single set ({v.get('best')}) lacks"),
            ("Filesystem", ("vfs-verifier passes the image" if v.get("verify_passed") else "vfs-verifier does not pass the image")
                           + f": free space map {v.get('fsm')}; directory {v.get('directory')}; {v.get('objects')} objects, "
                             f"{v.get('objects_damaged')} damaged"),
            *([("On one set", v["single_source"])] if v.get("single_source") else []),
            *([("Hand-built image", v["baseline"])] if v.get("baseline") else []),
            ("Image", f"`{v.get('image_sha256')}`"), ("Bad sector map", f"`{v.get('bsm_sha256')}`")])
        w("### 9.3 Where the bad sectors fall")
        w("")
        tbl(v.get("roles"))
        w("### 9.4 The sets agree")
        w("")
        w("Wherever two sets both recovered a sector, they must hold the same bytes.")
        w("")
        tbl(data.get("pairs"))
        if data.get("efm_params"):
            w("### 9.5 The EFM decoder's settings")
            w("")
            tbl(data["efm_params"])
    w(f"## {pack_n} The pack")
    w("")
    if efm:
        w(f"The pack stage makes a new pack version, `{data['version']}`, from the video and vfs stages' outputs: it links the "
          "three files the player loads rather than copying them, checks them again as vp415e reads them (the container, every "
          "stream, the disc metadata against the container, the image and its bad sector map against the vfs stage's), hashes "
          "them into SHA256SUMS, and writes the provenance and this report. A pack is only built when every stage before it is "
          "up to date, and only stamped when every check passes; `pack` then points at it, and the previous version is kept.")
    else:
        w(f"The pack stage makes a new pack version, `{data['version']}`, from the video stage's output: it links the mkv, "
          "the one file the player loads, since the side has no EFM, rather than copying it, checks it again as vp415e reads "
          "it (the container, every stream, the disc metadata against the container), hashes it into SHA256SUMS, and writes "
          "the provenance and this report. A pack is only built when every stage before it is up to date, and only stamped "
          "when every check passes; `pack` then points at it, and the previous version is kept.")
    w("")
    tbl(data.get("files"))

    w("## A Every stage's checks")
    w("")
    w("Each stage checks its own outputs before it is stamped; a stage with a failed check is not stamped, and nothing "
      "after it is built.")
    w("")
    for i, st in enumerate(data.get("stages") or [], 1):
        w(f"### A.{i} {st['name']}")
        w("")
        w(f"`{st['dir']}`")
        w("")
        code("\n".join(f"{('FAIL' if lv == 'fail' else lv):6} {t}" for lv, t in st.get("checks") or []))
    w("## B Every stage's stamp")
    w("")
    w("A stage's key is the sha256 of its inputs: the captures' fingerprints, the tool revisions, its parameters and "
      "project files, and the keys of the stages before it. A stage whose key still matches its inputs is not built again.")
    w("")
    for i, st in enumerate(data.get("stages") or [], 1):
        w(f"### B.{i} {st['name']}")
        w("")
        kv([("Key", f"`{st.get('key')}`"), ("Stamped", st.get("stamped"))])
        code("\n".join(st.get("inputs") or []))
    w("## C The compare report")
    w("")
    w("The evidence the selection was decided from, as the compare stage wrote it.")
    w("")
    code(data.get("compare_report"))
    if efm:
        w("## D vfs-stacker and vfs-verifier")
        w("")
        code(data.get("vfs_stacker"))
        code(data.get("vfs_verifier"))
    w(f"## {'E' if efm else 'D'} SHA256SUMS")
    w("")
    code(data.get("sums"))
    return "\n".join(out).rstrip("\n") + "\n"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("manifest")
    ap.add_argument("pdf")
    ap.add_argument("--work", required=True)
    ap.add_argument("--markdown", help="also write the report as Markdown here, linking the graphs in --work")
    args = ap.parse_args()
    man = read_json(args.manifest)
    if not man:
        print("pack-report: cannot read the manifest", file=sys.stderr)
        return 1
    work = Path(args.work)
    work.mkdir(parents=True, exist_ok=True)
    prov = read_yaml(man["provenance"]) or {}
    style()

    # A side with no EFM (DISC_EFM=no) has no data area: no EFM images, no
    # vfs stage, and a pack of the mkv alone. Manifests from before the
    # switch are of sides with EFM.
    has_efm = man.get("efm", True)
    sets = [s["set"] for s in man["sets"]]
    colours = {s: SET_COLOURS[i % len(SET_COLOURS)] for i, s in enumerate(sets)}
    dashes = {s: SECOND_DASH if i >= len(SET_COLOURS) else "-" for i, s in enumerate(sets)}
    video = prov.get("video") or {}
    vfs = prov.get("vfs") or {}
    sel = prov.get("selection") or {}
    video_sets = (sel.get("video") or {}).get("sets") or []
    vfs_sets = (sel.get("vfs") or {}).get("sets") or []
    evidence = {e["set"]: e for e in (prov.get("evidence") or {}).get("sets") or []}
    n = int((video.get("metadata") or {}).get("frame_count") or 0)

    # Alignment: frame (pad - least pad) + i of the stack is frame i of a
    # set's mapped output.
    pads = {}
    for line in read_text(Path(man["framemaps"]) / "alignment").splitlines():
        p = line.split()
        if len(p) == 2 and p[1].isdigit():
            pads[p[0]] = int(p[1])
    least = min([pads.get(s, 0) for s in video_sets] or [0])

    # --- each set ------------------------------------------------------------
    per = {}
    for s in man["sets"]:
        sid, sdir, ddir = s["set"], Path(s["set_dir"]), Path(s["decode_dir"])
        fmap = read_ranges(Path(man["framemaps"]) / f"{sid}.ranges")
        off = pads.get(sid, 0) - least
        figs = {}
        for key, csvname, col in (("white", "snr", "white_snr_db"), ("black", "snr", "black_psnr_db"),
                                  ("dropouts", "dropouts", "dropout_count"), ("burst", "burst", "median_burst_10bit")):
            raw = read_csv(sdir / f"{csvname}.csv", col)
            figs[key] = on_stack(raw, fmap, off, n) if fmap and n else np.array([])
        stamp = read_stamp(ddir / "stage.stamp") or {}
        inputs = dict(i.split(": ", 1) for i in stamp.get("inputs", []) if ": " in i)
        decoder = dict(l.split(":", 1) for l in read_text(ddir / "decoder.txt").splitlines() if ":" in l)
        log = read_text(ddir / f"{s['decode_base']}.log", tail=65536)
        took = re.search(r"Took ([0-9.]+) seconds to decode (\d+) frames(?: \(([0-9.]+) FPS)?", log)
        wrote = re.search(r"CVBS: wrote (\d+) frames (\S+), (\S+), sequence (\S+)", log)
        efm_bsm = read_bsm(sdir / f"{sid.lower()}_efm.dat.bsm") if has_efm else np.array([], dtype=np.int64)
        per[sid] = {"figs": figs, "inputs": inputs, "decoder": {k.strip(): v.strip() for k, v in decoder.items()},
                    "took": took, "wrote": wrote, "bsm": efm_bsm, "q": read_json(sdir / "quality.json") or {},
                    "map": fmap}

    # --- the stack -------------------------------------------------------------
    qdir = Path(man["quality_dir"])
    stackq = read_json(qdir / "quality.json") or {}
    stack = {"white": read_csv(qdir / "snr.csv", "white_snr_db"), "black": read_csv(qdir / "snr.csv", "black_psnr_db"),
             "dropouts": read_csv(qdir / "dropouts.csv", "dropout_count")}
    # The same stack in Mean, every input weighted equally: a check on the
    # stacker's weights.
    stack_mean = {"white": read_csv(qdir / "mean-snr.csv", "white_snr_db"), "black": read_csv(qdir / "mean-snr.csv", "black_psnr_db")}
    have_stack = len(stack["white"]) > 0
    have_mean = have_stack and len(stack_mean["white"]) > 0
    # The frames the stack was measured on, when the quality stage measured a
    # sample (blocks of the stack's frames, from 1) rather than all of them.
    # Wherever the stack is set against the sets, the sets are taken over the
    # same frames.
    sample = stackq.get("sample") or None
    sampled = np.zeros(n, dtype=bool)
    for a, b in (sample or {}).get("blocks") or []:
        sampled[max(0, a - 1):min(n, b)] = True

    def over_sample(v):
        if not sample or not len(v):
            return v
        return np.where(sampled[:len(v)], v[:n], np.nan)

    graphs = {}
    key_figures = {}
    if n:
        for key, title, ylabel, log in (
                ("white", "White SNR along the disc, mean per 500 frames", "white SNR (dB)", False),
                ("black", "Black PSNR along the disc, mean per 500 frames", "black PSNR (dB)", False),
                ("dropouts", "Dropouts along the disc, per 500 frames", "dropouts", True),
                ("burst", "Burst level of each capture along the disc, mean per 500 frames", "median burst (10-bit)", False)):
            series = []
            for sid in sets:
                v = per[sid]["figs"][key]
                if not len(v):
                    continue
                x, mean, total = bins(v, n)
                series.append({"set": sid, "colour": colours[sid], "ls": dashes[sid], "x": x, "y": total if key == "dropouts" else mean})
            st = sm = None
            if key in stack and len(stack[key]):
                x, mean, total = bins(stack[key], n)
                st = {"x": x, "y": total if key == "dropouts" else mean}
            if have_mean and key in stack_mean:
                x, mean, _ = bins(stack_mean[key], n)
                sm = {"x": x, "y": mean}
            if series:
                graphs[key] = line_graph(work, f"along-{key}", title, ylabel, n, series, st, log=log, mean=sm)

        # For each measure, the stack against the best video set in each
        # block, and the spread of its per-frame values against theirs.
        for key, label, _, _ in MEASURES if have_stack else ():
            vs = [sid for sid in video_sets if len(per[sid]["figs"][key])]
            if not vs or not len(stack[key]):
                continue
            per_bin = np.array([bins(per[sid]["figs"][key], n)[1] for sid in vs])
            x, smean, _ = bins(stack[key], n)
            best = np.nanmax(per_bin, axis=0)
            gain = smean - best
            graphs[f"gain_{key}"] = gain_graph(work, key, label, x, gain, n)
            finite = np.isfinite(gain)
            g = {"better": int((gain[finite] > 0.05).sum()), "worse": int((gain[finite] < -0.05).sum()),
                 "bins": int(finite.sum()), "worst": "–"}
            if finite.any():
                worst = int(np.nanargmin(gain))
                g["worst"] = f"frames {worst * BIN}–{min(n, worst * BIN + BIN) - 1}: {gain[worst]:+.2f} dB"
            if have_mean:
                # The stack as built against the same stack in Mean.
                _, mmean, _ = bins(stack_mean[key], n)
                vm = smean - mmean
                ok = np.isfinite(vm)
                g["mean_better"] = int((vm[ok] < -0.05).sum())
                g["weighted_better"] = int((vm[ok] > 0.05).sum())
                g["vs_mean"] = f"{np.nanmean(stack[key]) - np.nanmean(stack_mean[key]):+.2f}"
            key_figures[f"gain_{key}"] = g
            graphs[f"distribution_{key}"] = distribution_graph(
                work, key, label, [{"set": sid, "colour": colours[sid], "ls": dashes[sid], "v": over_sample(per[sid]["figs"][key])}
                                   for sid in vs],
                {"set": "Stack", "colour": STACK_COLOUR, "v": stack[key]},
                "the sampled frames" if sample else "every frame")

    def stat(sid, group, field):
        return ((evidence.get(sid) or {}).get(group) or {}).get(field)

    # A set's figure to set beside the stack's: its mean SNR or PSNR, or its
    # total dropouts, over the same frames as the stack.
    def against_stack(sid, key, group, field):
        if not sample:
            return stat(sid, group, field)
        v = over_sample(per[sid]["figs"][key])
        if not len(v) or not np.isfinite(v).any():
            return None
        return int(np.nansum(v)) if key == "dropouts" else float(np.nanmean(v))

    # The headline: the stack against the best of the video sets.
    for key, _, _, field in MEASURES:
        best = [(against_stack(sid, key, "snr", field), sid) for sid in video_sets]
        best = [b for b in best if b[0] is not None]
        if best:
            v, sid = max(best)
            key_figures[f"best_{key}"] = {"set": sid, "value": fmt(v)}
        if have_stack:
            key_figures[f"stack_{key}"] = fmt((stackq.get("snr") or {}).get(field))
    drops = [(against_stack(sid, "dropouts", "dropouts", "total_dropouts"), sid) for sid in video_sets]
    drops = [d for d in drops if d[0] is not None]
    if drops:
        v, sid = min(drops)
        key_figures.update(best_dropouts_set=sid, best_dropouts=fmt(v))
    if have_stack:
        key_figures.update(stack_dropouts=fmt((stackq.get("dropouts") or {}).get("total_dropouts")))

    for key, _, title, field in MEASURES:
        bar_rows = [{"set": sid, "colour": colours[sid], "value": against_stack(sid, key, "snr", field)} for sid in sets]
        bar_rows = [r for r in bar_rows if r["value"] is not None]
        if have_stack and (stackq.get("snr") or {}).get(field) is not None:
            bar_rows.append({"set": "Stack", "colour": STACK_COLOUR, "value": stackq["snr"][field]})
        if bar_rows:
            graphs[f"bars_{key}"] = summary_bars(work, f"bars-{key}", f"Mean {title[0].lower()}{title[1:]}"
                                                 + (", the sampled frames" if sample else ""), "dB", bar_rows, dots=True)
    bar_rows = [{"set": sid, "colour": colours[sid], "value": against_stack(sid, "dropouts", "dropouts", "total_dropouts")}
                for sid in sets]
    bar_rows = [r for r in bar_rows if r["value"] is not None]
    if have_stack and (stackq.get("dropouts") or {}).get("total_dropouts") is not None:
        bar_rows.append({"set": "Stack", "colour": STACK_COLOUR, "value": stackq["dropouts"]["total_dropouts"]})
    if bar_rows:
        graphs["bars_dropouts"] = summary_bars(work, "bars-dropouts", "Dropouts, the sampled frames" if sample else "Dropouts, whole disc",
                                               "dropouts", bar_rows, 0)

    # --- the stacker -------------------------------------------------------------
    vdir = Path(man["video_dir"])
    blocks = stacker_blocks(read_text(vdir / "stack.log"), video_sets, n)
    if blocks and n:
        graphs["weights"] = weights_graph(work, blocks, video_sets, colours, dashes, n)
        if any(b["weighted_sigma"] is not None for b in blocks):
            graphs["sigma"] = sigma_graph(work, blocks, n)

    # --- the EFM images -----------------------------------------------------------
    vfsdir = Path(man["vfs_dir"]) if has_efm else None
    stack_bsm = read_bsm(Path(man["pack_dir"]) / f"{man['stem']}.dat.bsm") if has_efm else np.array([], dtype=np.int64)
    sizes = {sid: ((evidence.get(sid) or {}).get("efm") or {}).get("sectors") or 0 for sid in sets}
    total = int((vfs.get("stack") or {}).get("output_sectors") or max(sizes.values() or [0])) if has_efm else 0
    good_any = np.zeros(total, dtype=bool)
    for sid in sets:
        g = np.zeros(total, dtype=bool)
        g[:min(total, sizes[sid])] = True
        b = per[sid]["bsm"]
        g[b[b < total]] = False
        good_any |= g
    union = np.nonzero(good_any)[0]
    sector_rows = []
    if len(union):
        for sid in sets:
            bad = np.zeros(total, dtype=bool)
            bad[min(total, sizes[sid]):] = True
            b = per[sid]["bsm"]
            bad[b[b < total]] = True
            sector_rows.append({"set": sid, "colour": colours[sid], "bad": np.nonzero(bad & good_any)[0]})
        sb = np.zeros(total, dtype=bool)
        sb[stack_bsm[stack_bsm < total]] = True
        sector_rows.append({"set": "Stack", "colour": STACK_COLOUR, "bad": np.nonzero(sb & good_any)[0]})
        graphs["sectors"] = sector_graph(work, union, sector_rows)

    # --- tables ---------------------------------------------------------------
    def role(stack_name, sid):
        lst = (sel.get(stack_name) or {}).get("sets") or []
        if sid in lst:
            return f"{lst.index(sid) + 1}"
        for d in (sel.get(stack_name) or {}).get("dropped") or []:
            if d.get("set") == sid:
                return "dropped"
        return "–"

    captures = []
    for c in prov.get("captures") or []:
        sid = c["set"]
        date = re.search(r"_(\d{4})(\d{2})(\d{2})_", c.get("library_path", ""))
        fp = c.get("fingerprint") or {}
        captures.append([sid, f"{date.group(1)}-{date.group(2)}-{date.group(3)}" if date else "–",
                         fmt(fp.get("bytes")), role("video", sid)] + ([role("vfs", sid)] if has_efm else [])
                        + [c.get("library_path", "")])

    fingerprints = [[c["set"], (c.get("fingerprint") or {}).get("sha256_of_head", "–")] for c in prov.get("captures") or []]
    head_bytes = next(((c.get("fingerprint") or {}).get("head_bytes") for c in prov.get("captures") or [] if c.get("fingerprint")), None)

    decodes = []
    for sid in sets:
        p = per[sid]
        took, wrote = p["took"], p["wrote"]
        decodes.append([sid, p["decoder"].get("version", "–"), p["inputs"].get("start", "–"),
                        wrote.group(1) if wrote else "–", wrote.group(3) if wrote else "–",
                        f"{float(took.group(1)) / 60:.0f} min" if took else "–",
                        # ld-decode's own rate (after its setup), or the frames over the time.
                        (f"{float(took.group(3)):.1f}" if took.group(3) else
                         f"{int(took.group(2)) / float(took.group(1)):.1f}" if float(took.group(1)) > 0 else "–") if took else "–"])
    flags = sorted({per[sid]["inputs"].get("flags", "") for sid in sets})

    quality_rows = []
    for sid in sets:
        e = evidence.get(sid) or {}
        cap, snr, dro, bur, mp = (e.get(k) or {} for k in ("capture", "snr", "dropouts", "burst", "map"))
        quality_rows.append([sid, cap.get("stamper_group"), fmt(cap.get("noise_sigma") and float(cap["noise_sigma"]), 1),
                             fmt(cap.get("stack_sigma_without") and float(cap["stack_sigma_without"]), 2),
                             f"{float(cap['weight_share']):.0f}%" if cap.get("weight_share") is not None else None,
                             fmt(cap.get("response_5_6mhz") and float(cap["response_5_6mhz"]), 2), snr.get("mean_white_snr"),
                             snr.get("min_white_snr"), snr.get("mean_black_psnr"), dro.get("total_dropouts"),
                             dro.get("total_dropout_samples"), bur.get("mean_median_burst_10bit")])
    if have_stack:
        snr, dro = stackq.get("snr") or {}, stackq.get("dropouts") or {}
        quality_rows.append(["Stack, sampled" if sample else "Stack", None, None, None, None, None,
                             snr.get("mean_white_snr"), snr.get("min_white_snr"),
                             snr.get("mean_black_psnr"), dro.get("total_dropouts"), dro.get("total_dropout_samples"), None])
    if have_mean:
        snr = stackq.get("mean_snr") or {}
        quality_rows.append(["Stack in Mean, sampled" if sample else "Stack in Mean", None, None, None, None, None,
                             snr.get("mean_white_snr"), snr.get("min_white_snr"),
                             snr.get("mean_black_psnr"), None, None, None])

    mapping = []
    for sid in sets:
        mp = (evidence.get(sid) or {}).get("map") or {}
        mapping.append([sid, mp.get("outputFrames"), mp.get("paddingFrames"), mp.get("gapsPadded"), mp.get("splitFieldFrames"),
                        mp.get("removedDuplicates"), mp.get("removedUnmappable"), mp.get("signal_state", "–")])

    weights = []
    for i, sid in enumerate(video_sets if blocks else []):
        m = [(b["frames"], b["sigma"][i], b["share"][i]) for b in blocks if b["sigma"][i] is not None]
        f = sum(x[0] for x in m)
        weights.append([sid, f, fmt(sum(x[0] * x[1] for x in m) / f if f else None, 2),
                        fmt(sum(x[0] * x[2] for x in m) / f if f else None, 1), fmt(min((x[2] for x in m), default=None), 1)])
    split_blocks = [[f"{b['from']}–{b['to']}",
                     " · ".join(f"{s} {v:.0f}%" for s, v in zip(video_sets, b["share"]) if v is not None),
                     ("equal weights: model not trusted" if b["fell_back_to_mean"] else "model not trusted")
                     + (f" ({' and '.join(b['worst_pair'])} misfit by {b['worst_misfit']:.0f}%)"
                        if b["worst_pair"] and b["worst_misfit"] is not None else "")]
                    for b in blocks if b["fit_trusted"] is False]
    untrusted = len(split_blocks)
    untrusted_frames = sum(b["frames"] for b in blocks if b["fit_trusted"] is False)
    trust = ("The noise model was trusted over the whole disc." if blocks and not untrusted else
             f"The noise model was not trusted over {fmt(untrusted_frames)} frames, in {untrusted} span(s) (below)." if untrusted else "")
    records = (f"The stacker measures its weights in every block of {BIN} frames, but writes a record only when they change "
               f"or its trust in the noise model does: each of its {len(blocks)} records holds until the next, and the "
               "table weights each by the frames it holds for." if blocks else "The stacker logged no weights.")
    schedule = video.get("decoder_schedule")
    nr = video.get("noise_reduction") or {}

    # What the stacking is predicted to gain: Source Alignment's comparison
    # of the sets (the map stage's digest of it) and the stacker's own
    # blocks, with the reference the comparison suggested and any block
    # whose reference another set stood in for.
    alignment = (read_json(Path(man["map_dir"]) / "analysis.json") or {}).get("alignment") or {}
    ast = alignment.get("statistics") or {}
    suggested = (prov.get("evidence") or {}).get("suggested_reference")
    gain = []
    if ast.get("stackSigma") is not None:
        gain.append(("Source Alignment", f"σ {fmt(ast['stackSigma'])} as weighted, {fmt(ast.get('equalSigma'))} in equal weights, "
                     f"{fmt(ast.get('bestSingleSigma'))} for the best single set, over {fmt(ast.get('sourceCount'))} sets"))
        gain.append(("Its noise model", f"{fmt(ast.get('pressingGroups'))} stamper group(s), {fmt(ast.get('families'))} "
                     f"famil{'y' if ast.get('families') == 1 else 'ies'}; "
                     + ("trusted" if ast.get("fitTrusted") else "not trusted")
                     + (f" (worst misfit {fmt(ast['worstMisfit'], 1)}%)" if ast.get("worstMisfit") is not None else "")))
    measured = [b for b in blocks if b["weighted_sigma"] is not None]
    if measured:
        mean = lambda k: fmt(sum(b["frames"] * b[k] for b in measured if b[k] is not None)
                             / sum(b["frames"] for b in measured if b[k] is not None))
        gain.append(("The stacker", f"σ {mean('weighted_sigma')} as weighted, {mean('equal_sigma')} in equal weights, "
                     f"{mean('best_single_sigma')} for the best single set, the mean over the disc's frames"))
    if video_sets:
        gain.append(("Reference", f"{video_sets[0]}, video input 1, sets the sample grid; "
                     + ("Source Alignment suggested no reference" if not suggested else
                        "the reference Source Alignment suggested" if suggested == video_sets[0] else
                        f"Source Alignment suggested {suggested}, and the selection overrides it")))
    subs = (video.get("stacker") or {}).get("reference_substitutions") or []
    if blocks:
        gain.append(("Stand-in references", "none: the reference covered every block" if not subs else "; ".join(
            f"frames {s.get('from_frame')}–{s.get('to_frame')}: "
            + (f"{s['stand_in']}, offset {s.get('offset')}" if s.get("stand_in") else "no set could stand in")
            for s in subs)))

    # The quality stage's projects: the stack as built, and in Mean, which
    # differs from it only where its rows below say.
    quality_rows_p = project_parameters(qdir / "quality.orcprj")
    mean_p = {(m["label"], k): v for m in project_parameters(qdir / "quality-mean.orcprj") for k, v in m["parameters"].items()}
    mean_diff = [[label, k, json.dumps(v) if not isinstance(v, str) else v]
                 for (label, k), v in mean_p.items()
                 if not any(p["label"] == label and p["parameters"].get(k) == v for p in quality_rows_p)]

    efm_rows = []
    for sid in sets if has_efm else ():
        e = (evidence.get(sid) or {}).get("efm") or {}
        u = (evidence.get(sid) or {}).get("vfs_stacker") or {}
        efm_rows.append([sid, e.get("assessment", "–"), e.get("sectors"), e.get("good"), e.get("corrected"), e.get("uncorrectable"),
                         fmt(e.get("c1_uncorrectable_pct"), 4, "%"), fmt(e.get("c2_uncorrectable_pct"), 4, "%"),
                         fmt(e.get("data_loss_pct"), 4, "%"), e.get("sections_missing"), role("vfs", sid), u.get("used")])
    pairs = [[f"{p['a']} – {p['b']}", p.get("compared"), p.get("disagreed")]
             for p in (((prov.get("evidence") or {}).get("pressings") or {}).get("efm") or {}).get("pairs") or []]

    st = vfs.get("stack") or {}
    vrf = vfs.get("verify") or {}
    roles = st.get("roles") or {}

    # The stages, in build order, with their checks and stamps.
    stage_dirs = []
    for s in man["sets"]:
        stage_dirs.append((f"decode:{s['set']}", s["decode_dir"]))
    for s in man["sets"]:
        stage_dirs.append((f"set:{s['set']}", s["set_dir"]))
    stage_dirs += [("map", man["map_dir"]), ("compare", man["compare_dir"]), ("video", man["video_dir"])]
    stage_dirs += [("vfs", man["vfs_dir"])] if has_efm else []
    stage_dirs += [("quality", man["quality_dir"])]
    stages = []
    for name, d in stage_dirs:
        stamp = read_stamp(Path(d) / "stage.stamp") or {}
        stages.append({"name": name, "dir": os.path.relpath(d, man["out"]), "key": stamp.get("key") or "–",
                       "stamped": time.strftime("%Y-%m-%d %H:%M:%S UTC", time.gmtime(stamp["stamped"])) if stamp.get("stamped") else "–", "inputs": stamp.get("inputs", []),
                       "checks": [list(c) for c in read_checks(Path(d) / "check.txt")]})
    stages.append({"name": "pack", "dir": man["pack_version"], "key": "(stamped when this build passes)", "stamped": "–",
                   "inputs": man["pack_inputs"],
                   # The hand check is the player's business, not the build's: its
                   # note says how to install the pack, which a record does not need.
                   "checks": [list(c) for c in read_checks(man["pack_check"]) if not (c[1].startswith(("awaiting the hand check", "checked by hand on the player")) or "player-check.yaml" in c[1])]})

    tools = prov.get("tools") or {}
    tool_rows = []
    for name in ("ld-decode", "decode-orc", "vfs-verifier", "nixpkgs"):
        if name == "vfs-verifier" and not has_efm:
            continue
        t = tools.get(name) or {}
        tool_rows.append({"name": name, "rev": t.get("rev", "–"), "source": t.get("source", "–"), "nar": t.get("narHash", "–"),
                          "patches": [[p.get("name"), p.get("sha256")] for p in t.get("patches") or []]})
    binaries = [[b["name"], b.get("version") or "–", b.get("path") or "–"] for b in man.get("tools") or []]
    binaries.append(["pack-python", f"Python {sys.version.split()[0]}, NumPy {np.__version__}, Matplotlib {matplotlib.__version__}", sys.executable])

    pack = prov.get("pack") or {}
    files = [[f["name"], fmt(f.get("bytes")), f.get("sha256", "–"), f.get("how", "–")] for f in prov.get("files") or []]

    # The pipeline from RF to pack, one row per step, with how each step's
    # checks came out over all its stages (a stage per set for decode and set).
    def outcome(prefix):
        got = [s for s in stages if s["name"] == prefix or s["name"].startswith(prefix + ":")]
        if not got:
            return "–"
        levels = [c[0] for s in got for c in s["checks"]]
        if "fail" in levels:
            return f"{levels.count('fail')} failed"
        return f"{levels.count('ok')} passed" + (f", {levels.count('note')} noted" if levels.count("note") else "")

    rev = {t["name"]: t["rev"][:7] for t in tool_rows if t["rev"] != "–"}
    ldd, orc, vfst = (f"{n} {rev.get(n, '–')}" for n in ("ld-decode", "decode-orc", "vfs-verifier"))
    sq = (stackq.get("snr") or {}) if have_stack else {}
    if has_efm:
        pipeline = [
            ["captures", "–", f"{len(sets)} RF captures of the side, read from the capture library (read only) and fingerprinted",
             f"{', '.join(sets)}", "–"],
            ["decode", ldd, "demodulates each RF capture into composite video (.cvbs), analogue audio and the EFM channel data",
             f"{len(sets)} decodes, from the lead-in on", outcome("decode")],
            ["set", orc, "decodes each set's EFM into a sector image and a map of the sectors it could not recover, and measures "
             "every frame's SNR, dropouts and burst level", f"{len(sets)} sector images and per-frame measurements", outcome("set")],
            ["map", orc, "puts each set's frames in disc order by their picture numbers: pads skips, drops duplicates, mixed and "
             "unplaceable frames", "a frame map per set (committed after review)", outcome("map")],
            ["compare", f"{orc}, {vfst}", "compares the sets: noise and what each adds, disc identity, video quality, EFM agreement",
             "the compare report", outcome("compare")],
            ["select", "–", "the one step that is a person's: which sets go into each stack, and in which order, decided from the "
             "compare report", f"video {', '.join(video_sets)}; VFS {', '.join(vfs_sets)}", "decided"],
            ["video", orc, f"stacks the video sets, corrects dropouts, decodes chroma ({video.get('decoder', '–')}) and writes FFV1 "
             "video, FLAC audio and the disc metadata into Matroska", f"{man["stem"]}.mkv, {fmt((video.get('metadata') or {}).get('frame_count'))} frames",
             outcome("video")],
            ["vfs", vfst, "stacks the VFS sets' sector images by majority and verifies the ADFS filesystem of the result",
             f"{man["stem"]}.dat and .dat.bsm, {vfs.get('verdict', '–')}", outcome("vfs")],
            ["quality", orc, "measures the stack with the set stage's analyses, on the stacker's output before dropout correction",
             f"white SNR {fmt(sq.get('mean_white_snr'))} dB" if sq else "–", outcome("quality")],
            ["pack", "build-pack.sh", "links the three files into a new pack version, checks them again as vp415e reads them, hashes "
             "them, and writes the provenance and this report", f"pack {pack.get('id', '–')}", outcome("pack")],
        ]
    else:
        # The same steps on a side with no EFM: no EFM channel, no sector
        # images, and no vfs step.
        pipeline = [
            ["captures", "–", f"{len(sets)} RF captures of the side, read from the capture library (read only) and fingerprinted",
             f"{', '.join(sets)}", "–"],
            ["decode", ldd, "demodulates each RF capture into composite video (.cvbs) and analogue audio; the side has no EFM",
             f"{len(sets)} decodes, from the lead-in on", outcome("decode")],
            ["set", orc, "measures every frame's SNR, dropouts and burst level", f"{len(sets)} sets of per-frame measurements",
             outcome("set")],
            ["map", orc, "puts each set's frames in disc order by their picture numbers: pads skips, drops duplicates, mixed and "
             "unplaceable frames", "a frame map per set (committed after review)", outcome("map")],
            ["compare", orc, "compares the sets: noise and what each adds, disc identity, video quality",
             "the compare report", outcome("compare")],
            ["select", "–", "the one step that is a person's: which sets go into the video stack, and in which order, decided "
             "from the compare report", f"video {', '.join(video_sets)}", "decided"],
            ["video", orc, f"stacks the video sets, corrects dropouts, decodes chroma ({video.get('decoder', '–')}) and writes FFV1 "
             "video, FLAC audio and the disc metadata into Matroska", f"{man["stem"]}.mkv, {fmt((video.get('metadata') or {}).get('frame_count'))} frames",
             outcome("video")],
            ["quality", orc, "measures the stack with the set stage's analyses, on the stacker's output before dropout correction",
             f"white SNR {fmt(sq.get('mean_white_snr'))} dB" if sq else "–", outcome("quality")],
            ["pack", "build-pack.sh", "links the mkv, the one file, into a new pack version, checks it again as vp415e reads it, "
             "hashes it, and writes the provenance and this report", f"pack {pack.get('id', '–')}", outcome("pack")],
        ]

    md = video.get("metadata") or {}
    disc = md.get("disc") or {}
    am = md.get("address_map") or {}
    streams = [[str(s.get("index")), s.get("codec_type", "–"),
                ", ".join(str(x) for x in [s.get("codec_name"), s.get("pix_fmt"),
                                           f"{s['width']}×{s['height']}" if s.get("width") else None,
                                           s.get("display_aspect_ratio") and f"DAR {s['display_aspect_ratio']}",
                                           s.get("r_frame_rate") if s.get("codec_type") == "video" else None,
                                           s.get("sample_rate") and f"{s['sample_rate']} Hz",
                                           s.get("channels") and f"{s['channels']} ch",
                                           s.get("bits_per_raw_sample") and f"{s['bits_per_raw_sample']}-bit",
                                           (s.get("tags") or {}).get("title")] if x)]
               for s in (video.get("container") or {}).get("streams") or []]
    tags = [[k, str(v)] for k, v in ((video.get("container") or {}).get("tags") or {}).items()]

    def undecoded(ranges):
        return ", ".join(f"{a}" if c == 1 else f"{a}–{a + c - 1}" for a, c in ranges or []) or "none"

    baseline = (video.get("baseline") or {}).get("metadata") or {}

    def params_table(path):
        rows = []
        for node in project_parameters(path):
            for k, v in node["parameters"].items():
                if k in ("ranges",) and isinstance(v, str) and len(v) > 60:
                    v = f"{v.count(',') + 1} entries (the committed frame map)"
                rows.append([node["label"], node["stage"], k, json.dumps(v) if not isinstance(v, str) else (v or "\"\"")])
        return table(["stage", "type", "parameter", "value"], rows, ["left"] * 4)

    first = man["sets"][0] if man["sets"] else None
    data = {
        "title": man["title"], "disc": man["disc"], "stem": man["stem"], "side": f"{man['format']} side {man['side']}, pictures {man['pictures']}",
        "has_efm": has_efm,
        "built": pack.get("built", "–"), "version": man["pack_version"],
        # Where the pack directory sits on the decodes share, whatever its mount point.
        "place": "/".join(Path(man["out"]).parts[-2:]), "id": pack.get("id", "–"),
        "status": pack.get("status", "–"), "complete": bool(pack.get("complete")),
        "script": man["script"], "pipeline": table(["step", "tool", "what it does", "what it made here", "checks"], pipeline, ["left"] * 5),
        "files": table(["file", "bytes", "sha256", "in the pack"], files, ["left", "right", "left", "left"]),
        "sums": read_text(man["sums"]),
        "tools": tool_rows, "binaries": table(["command", "version", "path"], binaries, ["left", "left", "left"]),
        "captures": (table(["set", "captured", "bytes", "video", "VFS", "library path"], captures,
                           ["left", "left", "right", "center", "center", "left"]) if has_efm else
                     table(["set", "captured", "bytes", "video", "library path"], captures,
                           ["left", "left", "right", "center", "left"])),
        "fingerprints": table(["set", "sha256 of the first bytes"], fingerprints, ["left", "left"]), "head_bytes": fmt(head_bytes),
        "decodes": table(["set", "ld-decode", "start", "frames", "signal", "time", "fps"], decodes,
                         ["left", "left", "right", "right", "left", "right", "right"]),
        "flags": flags, "lead_in": man.get("lead_in"), "frames": man.get("decode_frames"),
        "quality": table(["set", "group", "noise σ", "adds", "weight", "5–6 MHz", "white SNR", "lowest", "black PSNR", "dropouts", "samples", "burst"], quality_rows),
        "mapping": table(["set", "frames", "padded", "gaps", "split", "dups", "unmappable", "signal"], mapping,
                         ["left"] + ["right"] * 6 + ["left"]),
        "graphs": graphs, "key": key_figures, "bin": BIN, "have_stack": have_stack, "have_mean": have_mean,
        "stack_quality": stackq,
        "video_sets": video_sets, "vfs_sets": vfs_sets, "pressing": sel.get("pressing"),
        "selection_text": read_text(man["selection"]),
        "dropped": {k: (sel.get(k) or {}).get("dropped") or [] for k in (("video", "vfs") if has_efm else ("video",))},
        "weights": table(["set", "frames measured", "mean noise σ", "mean share %", "least share %"], weights),
        "split_blocks": table(["frames", "share of the weight", "stacked with"], split_blocks, ["left", "left", "left"]),
        "records": records, "trust": trust,
        "stacker_text": STACKER_TEXT, "untrusted_text": UNTRUSTED_TEXT, "quality_key": QUALITY_KEY,
        "sample_text": sample_text(sample, n),
        "noise_reduction": (f"Noise reduction: {fmt(nr['db'], 1)} dB, {nr.get('mode')}: averaged only across the frames the "
                            "stacker marks as one held picture, so every single-frame still is as stacked."
                            if nr.get("db") else None),
        "sample_grid": (video.get("stacker") or {}).get("sample_grid") or [],
        "stack_params": params_table(vdir / "stack.orcprj"),
        "efm_params": params_table(Path(first["set_dir"]) / "efm.orcprj") if first and has_efm else None,
        "quality_params": params_table(qdir / "quality.orcprj"),
        "quality_mean_diff": table(["stage", "parameter", "in Mean"], mean_diff, ["left"] * 3),
        "quality_dir": os.path.relpath(man["quality_dir"], man["out"]),
        "gain": [list(p) for p in gain], "gain_text": GAIN_TEXT,
        "decoder": f"{video.get('decoder', '–')}" + (f", {schedule}" if schedule else ""), "video_dir": os.path.relpath(man["video_dir"], man["out"]),
        "streams": table(["#", "type", "detail"], streams, ["left", "left", "left"]),
        "tags": table(["tag", "value"], tags, ["left", "left"]),
        "packets": fmt((video.get("container") or {}).get("packets")), "keyframes": fmt((video.get("container") or {}).get("keyframes")),
        "metadata": {"frames": fmt(md.get("frame_count")), "disc": f"{disc.get('format', '–')} side {disc.get('side', '–')}, "
                     f"{disc.get('size_inches', '–')} inch, user code {disc.get('user_code', 'none')}, CX {'on' if disc.get('cx_enabled') else 'off'}, "
                     f"sound {disc.get('sound_mode', '–')}, Amendment 2 {'present' if disc.get('amendment2') else 'absent'}",
                     "agreement": fmt(disc.get("agreement"), 4), "kind": am.get("kind", "–"),
                     "addresses": f"{am.get('first_address', '–')}–{am.get('last_address', '–')}", "runs": fmt(am.get("runs")),
                     "missing": fmt(am.get("pictures_missing")), "undecoded": undecoded(am.get("undecoded_ranges")),
                     "undecoded_n": fmt(am.get("undecoded")), "unmapped": undecoded(am.get("unmapped_ranges")),
                     "baseline": (video.get("baseline") or {}).get("path"),
                     "baseline_undecoded": undecoded((baseline.get("address_map") or {}).get("undecoded_ranges")) if baseline else None,
                     "baseline_undecoded_n": fmt((baseline.get("address_map") or {}).get("undecoded")) if baseline else None},
        "efm": table(["set", "assessment", "sectors", "good", "corrected", "uncorrectable", "C1 uncorr.", "C2 uncorr.",
                      "loss after C2", "sections missing", "VFS", "used"], efm_rows,
                     ["left", "left"] + ["right"] * 8 + ["center", "right"]),
        "pairs": table(["sets", "sectors compared", "disagreed"], pairs),
        "vfs": {"verdict": vfs.get("verdict", "–"), "accept": vfs.get("accept", "–"), "result": (st.get("result") or {}).get("verdict", "–"),
                "result_text": (st.get("result") or {}).get("text", "–"), "output_sectors": fmt(st.get("output_sectors")),
                "unanimous": fmt(st.get("unanimous")), "majority": fmt(st.get("majority")), "consensus": fmt(st.get("consensus")),
                "contested": fmt(st.get("contested")), "unrecovered": fmt(st.get("unrecovered")), "padded": fmt(st.get("padded")),
                "disagreements": fmt(st.get("disagreements")), "recovered_over_best": fmt(st.get("recovered_over_best")),
                "best": f"{(st.get('best_single') or {}).get('set', '–')}, {fmt((st.get('best_single') or {}).get('bad'))} bad",
                "bad": fmt(st.get("bad")), "union": fmt(len(union)),
                "roles": table(["role", "sectors"], [[k.replace("_", " "), fmt(v)] for k, v in roles.items()]),
                "verify_passed": bool(vrf.get("passed")), "fsm": vrf.get("fsm", "–"), "directory": vrf.get("directory", "–"),
                "objects": fmt(vrf.get("objects")), "objects_damaged": fmt(vrf.get("objects_damaged")),
                "image_sha256": (vfs.get("image") or {}).get("sha256", "–"), "bsm_sha256": (vfs.get("image") or {}).get("bsm_sha256", "–"),
                "baseline": vfs_baseline(vfs.get("baseline")), "bit_perfect": bool(vfs.get("bit_perfect")),
                "single_source": single_source(vfs)},
        "sector_counts": table(["set", "not recovered"], [[r["set"], fmt(len(r["bad"]))] for r in sector_rows]),
        "stages": stages,
        "compare_report": read_text(Path(man["compare_dir"]) / "report.txt"),
        "vfs_stacker": read_text(vfsdir / "vfs-stacker.txt") if has_efm else "",
        "vfs_verifier": read_text(Path(man["pack_dir"]) / "vfs-verifier.txt") if has_efm else "",
        "colours": {**colours, "Stack": STACK_COLOUR},
    }
    (work / "report.json").write_text(json.dumps(data, indent=1, default=str))

    typ = Path(__file__).with_name("pack-report.typ")
    # The format is given, since the pack stage writes to <name>.pdf.partial.
    cmd = ["typst", "compile", "--format", "pdf", "--root", "/", "--ignore-system-fonts", "--input", f"data={(work / 'report.json').resolve()}",
           "--input", f"graphs={work.resolve()}"]
    if os.environ.get("PACK_REPORT_FONTS"):
        cmd += ["--font-path", os.environ["PACK_REPORT_FONTS"]]
    if man.get("epoch"):
        cmd += ["--creation-timestamp", str(man["epoch"])]
    cmd += [str(typ.resolve()), args.pdf]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        print(f"pack-report: typst failed:\n{r.stderr}", file=sys.stderr)
        return 1
    if args.markdown:
        md = Path(args.markdown)
        md.write_text(markdown(data, os.path.relpath(work.resolve(), md.resolve().parent)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
