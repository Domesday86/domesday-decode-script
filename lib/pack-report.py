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
# palette (validated for adjacent pairs, light surface), and primary ink.
SET_COLOURS = ["#2a78d6", "#eb6834", "#1baf7a", "#eda100", "#e87ba4", "#008300", "#6250d6", "#e34948"]
OTHER_COLOUR = "#898781"
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


def stacker_blocks(log, sets):
    """The stacker's measurement of each block it logged: the noise and share
    of each input, and the pressings it split them into, if it did."""
    out = []
    pat = re.compile(r"StackerStage: frames (\d+)-(\d+): input noise σ in codes \(share of the weight\) ([^;\n]*)(?:; pressings ([^\n]*))?")
    for m in pat.finditer(log):
        vals = re.findall(r"([0-9.]+) \(([0-9.]+)%\)", m.group(3))
        if len(vals) != len(sets):
            continue
        out.append({"from": int(m.group(1)), "to": int(m.group(2)),
                    "sigma": [float(a) for a, _ in vals], "share": [float(b) for _, b in vals],
                    "pressings": (m.group(4) or "").strip()})
    return out


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
        ax.plot(s["x"], s["y"], color=s["colour"], lw=0.9, label=s["set"])
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


def distribution_graph(work, key, label, sets, stack):
    """Per-frame white SNR or black PSNR, as the share of frames at each 0.25 dB."""
    allv = np.concatenate([s["v"][np.isfinite(s["v"])] for s in sets + ([stack] if stack else [])])
    lo, hi = np.percentile(allv, 0.2), np.percentile(allv, 99.9)
    edges = np.arange(math.floor(lo * 4) / 4, hi + 0.25, 0.25)
    fig, ax = plt.subplots(figsize=(7.0, 2.4))
    for s in sets + ([stack] if stack else []):
        v = s["v"][np.isfinite(s["v"])]
        h, _ = np.histogram(v, bins=edges)
        ax.step(edges[:-1], 100 * h / max(1, len(v)), where="post", color=s["colour"],
                lw=1.8 if s is stack else 0.9, label=s["set"])
    ax.set_xlim(edges[0], edges[-1])
    ax.set_xlabel(f"{label} of a frame (dB)")
    ax.set_ylabel("% of frames")
    ax.set_title(f"Per-frame {label}, every frame of each set and of the stack")
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


def weights_graph(work, blocks, sets, colours, n):
    fig, ax = plt.subplots(figsize=(7.0, 2.6))
    x = np.array([(b["from"] + b["to"] + 1) / 2 for b in blocks])
    bottom = np.zeros(len(blocks))
    for i, s in enumerate(sets):
        share = np.array([b["share"][i] for b in blocks])
        ax.bar(x, share, bottom=bottom, width=BIN * 0.9, color=colours[s], edgecolor="white", linewidth=0.3, label=s)
        bottom += share
    split = [b for b in blocks if b["pressings"]]
    if split:
        ax.plot([(b["from"] + b["to"] + 1) / 2 for b in split], [106] * len(split), "v", ms=4, color=INK2,
                label="pressings split", clip_on=False)
    ax.set_ylim(0, 110)
    ax.set_yticks([0, 20, 40, 60, 80, 100])
    ax.set_ylabel("share of the weight (%)")
    frame_axis(ax, n)
    ax.grid(axis="x", visible=False)
    ax.set_title("The stacker's weight for each set, in each block it measured")
    legend_row(ax, len(sets) + (1 if split else 0))
    return save(fig, work, "weights")


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


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("manifest")
    ap.add_argument("pdf")
    ap.add_argument("--work", required=True)
    args = ap.parse_args()
    man = read_json(args.manifest)
    if not man:
        print("pack-report: cannot read the manifest", file=sys.stderr)
        return 1
    work = Path(args.work)
    work.mkdir(parents=True, exist_ok=True)
    prov = read_yaml(man["provenance"]) or {}
    style()

    sets = [s["set"] for s in man["sets"]]
    colours = {s: (SET_COLOURS[i] if i < len(SET_COLOURS) else OTHER_COLOUR) for i, s in enumerate(sets)}
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
        efm_bsm = read_bsm(sdir / f"{sid.lower()}_efm.dat.bsm")
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
                series.append({"set": sid, "colour": colours[sid], "x": x, "y": total if key == "dropouts" else mean})
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
                work, key, label, [{"set": sid, "colour": colours[sid], "v": per[sid]["figs"][key]} for sid in vs],
                {"set": "Stack", "colour": STACK_COLOUR, "v": stack[key]})

    def stat(sid, group, field):
        return ((evidence.get(sid) or {}).get(group) or {}).get(field)

    # The headline: the stack against the best of the video sets.
    for key, _, _, field in MEASURES:
        best = [(stat(sid, "snr", field), sid) for sid in video_sets if stat(sid, "snr", field) is not None]
        if best:
            v, sid = max(best)
            key_figures[f"best_{key}"] = {"set": sid, "value": fmt(v)}
        if have_stack:
            key_figures[f"stack_{key}"] = fmt((stackq.get("snr") or {}).get(field))
    drops = [(stat(sid, "dropouts", "total_dropouts"), sid) for sid in video_sets if stat(sid, "dropouts", "total_dropouts") is not None]
    if drops:
        v, sid = min(drops)
        key_figures.update(best_dropouts_set=sid, best_dropouts=fmt(v))
    if have_stack:
        key_figures.update(stack_dropouts=fmt((stackq.get("dropouts") or {}).get("total_dropouts")))

    for key, _, title, field in MEASURES:
        bar_rows = [{"set": sid, "colour": colours[sid], "value": stat(sid, "snr", field)}
                    for sid in sets if stat(sid, "snr", field) is not None]
        if have_stack and (stackq.get("snr") or {}).get(field) is not None:
            bar_rows.append({"set": "Stack", "colour": STACK_COLOUR, "value": stackq["snr"][field]})
        if bar_rows:
            graphs[f"bars_{key}"] = summary_bars(work, f"bars-{key}", f"Mean {title[0].lower()}{title[1:]}", "dB", bar_rows, dots=True)
    bar_rows = [{"set": sid, "colour": colours[sid], "value": stat(sid, "dropouts", "total_dropouts")}
                for sid in sets if stat(sid, "dropouts", "total_dropouts") is not None]
    if have_stack and (stackq.get("dropouts") or {}).get("total_dropouts") is not None:
        bar_rows.append({"set": "Stack", "colour": STACK_COLOUR, "value": stackq["dropouts"]["total_dropouts"]})
    if bar_rows:
        graphs["bars_dropouts"] = summary_bars(work, "bars-dropouts", "Dropouts, whole disc", "dropouts", bar_rows, 0)

    # --- the stacker -------------------------------------------------------------
    vdir = Path(man["video_dir"])
    blocks = stacker_blocks(read_text(vdir / "stack.log"), video_sets)
    if blocks and n:
        graphs["weights"] = weights_graph(work, blocks, video_sets, colours, n)

    # --- the EFM images -----------------------------------------------------------
    vfsdir = Path(man["vfs_dir"])
    stack_bsm = read_bsm(Path(man["pack_dir"]) / f"{man['stem']}.dat.bsm")
    sizes = {sid: ((evidence.get(sid) or {}).get("efm") or {}).get("sectors") or 0 for sid in sets}
    total = int((vfs.get("stack") or {}).get("output_sectors") or max(sizes.values() or [0]))
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
                         fmt(fp.get("bytes")), role("video", sid), role("vfs", sid), c.get("library_path", "")])

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
        quality_rows.append([sid, fmt(cap.get("noise_sigma") and float(cap["noise_sigma"]), 1),
                             fmt(cap.get("response_5_6mhz") and float(cap["response_5_6mhz"]), 2), snr.get("mean_white_snr"),
                             snr.get("min_white_snr"), snr.get("mean_black_psnr"), dro.get("total_dropouts"),
                             dro.get("total_dropout_samples"), bur.get("mean_median_burst_10bit")])
    if have_stack:
        snr, dro = stackq.get("snr") or {}, stackq.get("dropouts") or {}
        quality_rows.append(["Stack", None, None, snr.get("mean_white_snr"), snr.get("min_white_snr"),
                             snr.get("mean_black_psnr"), dro.get("total_dropouts"), dro.get("total_dropout_samples"), None])
    if have_mean:
        snr = stackq.get("mean_snr") or {}
        quality_rows.append(["Stack in Mean", None, None, snr.get("mean_white_snr"), snr.get("min_white_snr"),
                             snr.get("mean_black_psnr"), None, None, None])

    mapping = []
    for sid in sets:
        mp = (evidence.get(sid) or {}).get("map") or {}
        mapping.append([sid, mp.get("outputFrames"), mp.get("paddingFrames"), mp.get("gapsPadded"), mp.get("splitFieldFrames"),
                        mp.get("removedDuplicates"), mp.get("removedUnmappable"), mp.get("signal_state", "–")])

    weights = [[w["set"], w.get("measurements"), fmt(w.get("mean_sigma"), 1), fmt(w.get("mean_share"), 1), w.get("least_share")]
               for w in (video.get("stacker") or {}).get("sets") or []]
    split_blocks = [[f"{b['from']}–{b['to']}", " · ".join(f"{s} {v:.0f}%" for s, v in zip(video_sets, b["share"])), b["pressings"]]
                    for b in blocks if b["pressings"]]

    efm_rows = []
    for sid in sets:
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
    stage_dirs += [("map", man["map_dir"]), ("compare", man["compare_dir"]), ("video", man["video_dir"]),
                   ("vfs", man["vfs_dir"]), ("quality", man["quality_dir"])]
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
    pipeline = [
        ["captures", "–", f"{len(sets)} RF captures of the side, read from the capture library (read only) and fingerprinted",
         f"{', '.join(sets)}", "–"],
        ["decode", ldd, "demodulates each RF capture into composite video fields (.tbc), analogue audio and the EFM channel data",
         f"{len(sets)} decodes, from the lead-in on", outcome("decode")],
        ["set", orc, "decodes each set's EFM into a sector image and a map of the sectors it could not recover, and measures "
         "every frame's SNR, dropouts and burst level", f"{len(sets)} sector images and per-frame measurements", outcome("set")],
        ["map", orc, "puts each set's frames in disc order by their picture numbers: pads skips, drops duplicates, mixed and "
         "unplaceable frames", "a frame map per set (committed after review)", outcome("map")],
        ["compare", f"{orc}, {vfst}", "compares the sets: noise, pressing, video quality, EFM agreement",
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
        "built": pack.get("built", "–"), "version": man["pack_version"],
        # Where the pack directory sits on the decodes share, whatever its mount point.
        "place": "/".join(Path(man["out"]).parts[-2:]), "id": pack.get("id", "–"),
        "status": pack.get("status", "–"), "complete": bool(pack.get("complete")),
        "script": man["script"], "pipeline": table(["step", "tool", "what it does", "what it made here", "checks"], pipeline, ["left"] * 5),
        "files": table(["file", "bytes", "sha256", "in the pack"], files, ["left", "right", "left", "left"]),
        "sums": read_text(man["sums"]),
        "tools": tool_rows, "binaries": table(["command", "version", "path"], binaries, ["left", "left", "left"]),
        "captures": table(["set", "captured", "bytes", "video", "VFS", "library path"], captures,
                          ["left", "left", "right", "center", "center", "left"]),
        "fingerprints": table(["set", "sha256 of the first bytes"], fingerprints, ["left", "left"]), "head_bytes": fmt(head_bytes),
        "decodes": table(["set", "ld-decode", "start", "frames", "signal", "time", "fps"], decodes,
                         ["left", "left", "right", "right", "left", "right", "right"]),
        "flags": flags, "lead_in": man.get("lead_in"), "frames": man.get("decode_frames"),
        "quality": table(["set", "noise σ", "5–6 MHz", "white SNR", "lowest", "black PSNR", "dropouts", "samples", "burst"], quality_rows),
        "mapping": table(["set", "frames", "padded", "gaps", "split", "dups", "unmappable", "signal"], mapping,
                         ["left"] + ["right"] * 6 + ["left"]),
        "graphs": graphs, "key": key_figures, "bin": BIN, "have_stack": have_stack, "have_mean": have_mean,
        "stack_quality": stackq,
        "video_sets": video_sets, "vfs_sets": vfs_sets, "pressing": sel.get("pressing"),
        "selection_text": read_text(man["selection"]),
        "dropped": {k: (sel.get(k) or {}).get("dropped") or [] for k in ("video", "vfs")},
        "weights": table(["set", "blocks", "mean noise σ", "mean share %", "least share %"], weights),
        "split_blocks": table(["frames", "share of the weight", "pressings"], split_blocks, ["left", "left", "left"]),
        "blocks_logged": len(blocks),
        "sample_grid": (video.get("stacker") or {}).get("sample_grid") or [],
        "stack_params": params_table(vdir / "stack.orcprj"),
        "efm_params": params_table(Path(first["set_dir"]) / "efm.orcprj") if first else None,
        "quality_params": params_table(qdir / "quality.orcprj"),
        "decoder": video.get("decoder", "–"), "video_dir": os.path.relpath(man["video_dir"], man["out"]),
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
                "baseline": vfs.get("baseline"), "bit_perfect": bool(vfs.get("bit_perfect"))},
        "sector_counts": table(["set", "not recovered"], [[r["set"], fmt(len(r["bad"]))] for r in sector_rows]),
        "stages": stages,
        "compare_report": read_text(Path(man["compare_dir"]) / "report.txt"),
        "vfs_stacker": read_text(vfsdir / "vfs-stacker.txt"),
        "vfs_verifier": read_text(Path(man["pack_dir"]) / "vfs-verifier.txt"),
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
    return 0


if __name__ == "__main__":
    sys.exit(main())
