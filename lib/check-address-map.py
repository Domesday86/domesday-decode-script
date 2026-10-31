"""Check a stacked mkv's address map against the single captures it was
stacked from.

    pack-python lib/check-address-map.py <orc-disc-metadata.yaml> \
        <set>=<daphne .vbi>[@<offset>] ...

Each .vbi is decode-orc's Daphne VBI sink run on one set alone, through its
committed frame map: the biphase words of lines 16, 17 and 18, per field,
in the set's output-frame order. <offset> is the frames Align puts before
the set in the stack (0 by default), so the set's frame j is the stack's
frame j + offset.

For every stack frame, each set reads a CAV picture number from lines 17
and 18 of its two fields, or none. Where a majority of the sets that read a
number read the same one, P, and at least two read it, the mkv's address map
(the run arithmetic of check-disc-metadata.py) must put picture P on that
frame. A frame it leaves without a picture, or gives another picture, is a
picture the stack lost that its captures hold: the check that found Weighted
stacking and Dropout Correction corrupting the VBI (decode-orc 9afae69c).
Frames no majority reads are not compared: pulldown frames, padding, and
numbers the captures disagree on.

Only CAV picture numbers are compared; a CLV disc is noted and passed.

Prints one JSON object: "checks", each {"level": ok|fail|note, "text"},
and "summary". Exits 1 if any check failed, 2 if an input could not be
read.
"""

import argparse
import collections
import json
import sys

import yaml

UNREADABLE = 0x7FFFFF
RECORD = 10  # white flag, then three 24-bit big-endian words


def frame_set(block):
    """The file frames of an unnumbered/undecoded/unmapped block, either encoding."""
    if not block:
        return set()
    if block.get("encoding") == "bitmap":
        return {i * 8 + bit
                for i, byte in enumerate(bytes.fromhex(block.get("bitmap", "")))
                for bit in range(8)
                if byte >> bit & 1}
    return {f for start, count in block.get("ranges", []) for f in range(start, start + count)}


def picture(word):
    """The CAV picture number a biphase word carries, or None."""
    if word in (0, UNREADABLE) or word & 0xF00000 != 0xF00000:
        return None
    digits = word & 0x07FFFF
    n = 0
    for shift in (16, 12, 8, 4, 0):
        d = digits >> shift & 0xF
        if d > 9:
            return None
        n = n * 10 + d
    return n


def read_vbi(path):
    """Per frame, the one picture number its fields' lines 17 and 18 read, or None."""
    with open(path, "rb") as fh:
        data = fh.read()
    if data[:4] != b"1VBI":
        raise ValueError(f"{path} is not a Daphne VBI file")
    body = data[4:]
    fields = [body[i:i + RECORD] for i in range(0, len(body) - RECORD + 1, RECORD)]
    frames = []
    for k in range(0, len(fields) - 1, 2):
        read = set()
        for rec in fields[k:k + 2]:
            for line in (1, 2):  # lines 17 and 18
                p = picture(int.from_bytes(rec[1 + 3 * line:4 + 3 * line], "big"))
                if p is not None:
                    read.add(p)
        frames.append(read.pop() if len(read) == 1 else None)
    return frames


def addresses(doc):
    """file frame -> the picture the mkv's address map puts there (implied at undecoded frames)."""
    amap = doc.get("address_map") or {}
    if amap.get("kind") != "cav_picture":
        return None
    unnumbered = frame_set(amap.get("unnumbered"))
    out = {}
    for run in amap.get("runs") or []:
        held = 0
        for f in range(run["file_frame"], run["file_frame"] + run["count"]):
            if f in unnumbered:
                held += 1
                continue
            out[f] = run["picture"] + (f - run["file_frame"]) - held
    return out


def ranges_text(frames, limit=12):
    frames = sorted(frames)
    pairs = []
    for f in frames:
        if pairs and pairs[-1][1] == f - 1:
            pairs[-1][1] = f
        else:
            pairs.append([f, f])
    text = ", ".join(f"{a}" if a == b else f"{a}-{b}" for a, b in pairs[:limit])
    return text + (f" and {len(pairs) - limit} more" if len(pairs) > limit else "")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("document")
    ap.add_argument("sets", nargs="+", help="<set>=<vbi>[@<offset>]")
    args = ap.parse_args()

    checks = []

    def ok(t): checks.append({"level": "ok", "text": t})
    def fail(t): checks.append({"level": "fail", "text": t})
    def note(t): checks.append({"level": "note", "text": t})

    try:
        with open(args.document, encoding="utf-8") as fh:
            doc = yaml.safe_load(fh)
        captures = {}
        for spec in args.sets:
            name, _, rest = spec.partition("=")
            path, _, offset = rest.partition("@")
            captures[name] = (read_vbi(path), int(offset or 0))
    except (OSError, ValueError, yaml.YAMLError) as e:
        print(json.dumps({"checks": [{"level": "fail", "text": f"cannot read the inputs: {e}"}], "summary": None}))
        return 2

    mapped = addresses(doc)
    if mapped is None:
        note("the address map is not CAV pictures: not compared against the single captures")
        print(json.dumps({"checks": checks, "summary": None}))
        return 0

    frames = (doc.get("video") or {}).get("frame_count") or 0
    compared = 0
    lost, moved, differ = [], [], {}
    for f in range(frames):
        votes = collections.Counter()
        for read, offset in captures.values():
            j = f - offset
            if 0 <= j < len(read) and read[j] is not None:
                votes[read[j]] += 1
        if not votes:
            continue
        p, n = votes.most_common(1)[0]
        if n < 2 or n * 2 <= sum(votes.values()):
            continue
        compared += 1
        have = mapped.get(f)
        if have is None:
            lost.append(f)
        elif have != p:
            moved.append(f)
        for name, (read, offset) in captures.items():
            j = f - offset
            if 0 <= j < len(read) and read[j] is not None and read[j] != p:
                differ[name] = differ.get(name, 0) + 1

    summary = {"frames": frames, "compared": compared, "lost": len(lost), "moved": len(moved),
               "lost_frames": ranges_text(lost) if lost else "", "moved_frames": ranges_text(moved) if moved else "",
               "sets": {name: len(read) for name, (read, _) in captures.items()},
               "minority_reads": differ}
    note(f"{compared} of {frames} frames carry a picture number most of the {len(captures)} single captures agree on")
    if not lost and not moved:
        ok(f"the mkv puts the captures' picture on every one of those {compared} frames")
    if lost:
        fail(f"{len(lost)} frame(s) the captures number are left without a picture in the mkv: {ranges_text(lost)}")
    if moved:
        fail(f"{len(moved)} frame(s) carry another picture in the mkv than the captures read: {ranges_text(moved)}")
    if differ:
        note("reads that differ from the majority, by set: "
             + ", ".join(f"{k} {v}" for k, v in sorted(differ.items())))

    print(json.dumps({"checks": checks, "summary": summary}))
    return 1 if any(c["level"] == "fail" for c in checks) else 0


if __name__ == "__main__":
    sys.exit(main())
