"""Check a decode-orc disc metadata document the way a player reads it.

    pack-python lib/check-disc-metadata.py <orc-disc-metadata.yaml> \
        --frames N --format CAV|CLV --side N [--pictures FIRST-LAST] \
        [--system PAL|NTSC] [--tag-version V] [--user-code CODE] \
        [--amendment2 present|absent]

The document is the one decode-orc's video sink attaches to an mkv
(docs/technical/disc-metadata-format.md in decode-orc, format_version 1.0).
It is checked against that spec's reader contract, which is what vp415e
follows, and against what the pack expects of the side:

- format and version: format is orc-disc-metadata, format_version a quoted
  MAJOR.MINOR with MAJOR 1, and the container's ORC_DISC_METADATA_VERSION
  tag the same;
- video: the side's system (PAL, the default, at exactly 25/1; NTSC at
  30000/1001), two fields a frame, frame_count the frames the container
  holds;
- disc: the expected format and side, and the user code and Amendment 2
  the chosen pressing reads;
- the address map, with every run's arithmetic applied to every file frame:
  every picture of the programme resolves to exactly one file frame, none
  to two, none missing; unmapped frames are lead-in or lead-out only;
- events: lead-in and lead-out present, chapters in order;
- no raw VBI (the pack is written at map detail).

A frame in undecoded has a number the file cannot state, but it advances
the count, so the picture its run implies there is counted as present and
listed apart. A frame in unnumbered has no picture at all.

Prints one JSON object: "checks", each {"level": ok|fail|note, "text"}, and
"summary", the figures the pack's provenance keeps. Exits 1 if any check
failed, 2 if the document could not be read at all.
"""

import argparse
import json
import re
import sys

import yaml

KNOWN_MINOR = 0
PICTURE_LIMIT = 79999  # the biphase decoder masks to the NTSC maximum

# Each system's exact frame rate as the document gives it, and the nominal
# rate CLV timecode counts at.
SYSTEMS = {"PAL": ([25, 1], 25), "NTSC": ([30000, 1001], 30)}


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


def as_ranges(frames):
    """Sorted frames as [first, count] pairs."""
    out = []
    for f in sorted(frames):
        if out and out[-1][0] + out[-1][1] == f:
            out[-1][1] += 1
        else:
            out.append([f, 1])
    return out


def ranges_text(frames, limit=12):
    pairs = as_ranges(frames)
    text = ", ".join(f"{a}" if n == 1 else f"{a}-{a + n - 1}" for a, n in pairs[:limit])
    return text + (f" and {len(pairs) - limit} more" if len(pairs) > limit else "")


def clv_address(time, fps):
    m = re.fullmatch(r"(\d+):(\d+):(\d+)\.(\d+)", str(time))
    if not m:
        raise ValueError(f"bad time code {time!r}")
    h, mi, s, fr = map(int, m.groups())
    return ((h * 60 + mi) * 60 + s) * fps + fr


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("document")
    ap.add_argument("--frames", type=int, required=True, help="frames the container holds")
    ap.add_argument("--format", choices=["CAV", "CLV"], required=True)
    ap.add_argument("--side", type=int, required=True)
    ap.add_argument("--pictures", help="the programme's addresses, FIRST-LAST (CAV pictures, or CLV timecodes in frames; "
                    "on CLV a FIRST of 0 is met by a programme that starts at .01)")
    ap.add_argument("--system", choices=sorted(SYSTEMS), default="PAL")
    ap.add_argument("--tag-version", help="the container's ORC_DISC_METADATA_VERSION")
    ap.add_argument("--user-code")
    ap.add_argument("--amendment2", choices=["present", "absent"])
    args = ap.parse_args()

    checks = []

    def ok(t): checks.append({"level": "ok", "text": t})
    def fail(t): checks.append({"level": "fail", "text": t})
    def note(t): checks.append({"level": "note", "text": t})

    try:
        with open(args.document, encoding="utf-8") as fh:
            text = fh.read()
        doc = yaml.safe_load(text)
    except (OSError, yaml.YAMLError) as e:
        print(json.dumps({"checks": [{"level": "fail", "text": f"cannot read the document: {e}"}],
                          "summary": None}))
        return 2
    if not isinstance(doc, dict):
        print(json.dumps({"checks": [{"level": "fail", "text": "the document is not a mapping"}],
                          "summary": None}))
        return 2
    summary = {}

    # --- format and version: the reader contract -------------------------
    if doc.get("format") == "orc-disc-metadata":
        ok("format is orc-disc-metadata")
    else:
        fail(f"format is {doc.get('format')!r}, not orc-disc-metadata: not a decode-orc disc metadata document")
    version = doc.get("format_version")
    quoted = re.search(r'^format_version:\s*"(\d+)\.(\d+)"\s*$', text, re.M)
    summary["format_version"] = version
    if not quoted or not isinstance(version, str):
        fail(f"format_version {version!r} is not a quoted MAJOR.MINOR string")
    else:
        major, minor = int(quoted.group(1)), int(quoted.group(2))
        if major != 1:
            fail(f"format_version {version}: MAJOR {major} is not 1, so a reader must refuse it")
        elif minor > KNOWN_MINOR:
            ok(f"format_version {version}")
            note(f"format_version {version} is newer than 1.{KNOWN_MINOR}: read, its new keys ignored")
        else:
            ok(f"format_version {version}")
    if args.tag_version is not None:
        if args.tag_version == version:
            ok(f"ORC_DISC_METADATA_VERSION is {args.tag_version}, as the document says")
        else:
            fail(f"ORC_DISC_METADATA_VERSION is {args.tag_version!r}, the document {version!r}")

    # --- video --------------------------------------------------------------
    video = doc.get("video") or {}
    rate, fps = SYSTEMS[args.system]
    if (video.get("system"), video.get("frame_rate_exact"), video.get("fields_per_frame")) == (args.system, rate, 2):
        ok(f"video is {args.system}, exactly {rate[0]}/{rate[1]}, two fields a frame")
    else:
        fail(f"video is {video.get('system')}, {video.get('frame_rate_exact')}, "
             f"{video.get('fields_per_frame')} fields a frame ({args.system}, {rate}, 2 expected)")
    count = video.get("frame_count")
    summary["frame_count"] = count
    if count == args.frames:
        ok(f"frame_count {count} is the container's frame count")
    else:
        fail(f"frame_count {count} is not the container's {args.frames} frames")
    frames = args.frames if isinstance(args.frames, int) else 0

    # --- disc -------------------------------------------------------------
    disc = doc.get("disc") or {}
    a2 = disc.get("amendment2") or {}
    conf = disc.get("confidence") or {}
    summary["disc"] = {k: disc.get(k) for k in ("format", "side", "size_inches", "user_code", "cx_enabled", "sound_mode")}
    summary["disc"]["amendment2"] = a2.get("present", False)
    summary["disc"]["agreement"] = conf.get("agreement")
    if disc.get("format") == args.format and disc.get("side") == args.side:
        ok(f"disc is {args.format} side {args.side}")
    else:
        fail(f"disc is {disc.get('format')} side {disc.get('side')}, not {args.format} side {args.side}")
    if args.user_code is not None:
        if str(disc.get("user_code")) == args.user_code:
            ok(f"user code {args.user_code}, as the chosen pressing reads")
        else:
            fail(f"user code {disc.get('user_code')!r}, the chosen pressing reads {args.user_code!r}")
    if args.amendment2 is not None:
        present = "present" if a2.get("present") else "absent"
        if present == args.amendment2:
            ok(f"Amendment 2 {present}, as the chosen pressing reads")
        else:
            fail(f"Amendment 2 {present}, the chosen pressing reads it {args.amendment2}")
    note(f"disc: user code {disc.get('user_code') or 'none'}, CX {'on' if disc.get('cx_enabled') else 'off'}, "
         f"sound {disc.get('sound_mode')}, status agreement {conf.get('agreement')}")

    # --- the address map --------------------------------------------------
    amap = doc.get("address_map") or {}
    kind, source = amap.get("kind"), amap.get("source")
    want = {"CAV": "cav_picture", "CLV": "clv_timecode"}[args.format]
    if kind == want and source == "biphase":
        ok(f"address map is {kind}, from {source}")
    else:
        fail(f"address map is {kind} from {source}, not {want} from biphase")
    unnumbered = frame_set(amap.get("unnumbered"))
    undecoded = frame_set(amap.get("undecoded"))
    unmapped = frame_set(amap.get("unmapped"))
    for name, s in (("unnumbered", unnumbered), ("undecoded", undecoded), ("unmapped", unmapped)):
        stated = (amap.get(name) or {}).get("count", 0)
        if stated != len(s):
            fail(f"{name} says count {stated} but lists {len(s)} frames")
        if any(f < 0 or f >= frames for f in s):
            fail(f"{name} lists frames outside the file's 0-{frames - 1}")

    runs = amap.get("runs") or []
    owner = {}       # address -> file frames stating it
    implied = {}     # address -> undecoded file frames implying it
    covered = set()
    breaks = []
    beyond = []
    try:
        for i, run in enumerate(runs):
            start, n = run["file_frame"], run["count"]
            base = run["picture"] if kind == "cav_picture" else clv_address(run["time"], fps)
            if i:
                breaks.append(start)
            held = 0
            for f in range(start, start + n):
                if f in covered:
                    fail(f"file frame {f} lies in two runs")
                covered.add(f)
                if f in unnumbered:
                    held += 1
                    continue
                address = base + (f - start) - held
                (implied if f in undecoded else owner).setdefault(address, []).append(f)
    except (KeyError, TypeError, ValueError) as e:
        fail(f"a run cannot be read: {e}")
    if any(f < 0 or f >= frames for f in covered):
        fail(f"the runs cover frames outside the file's 0-{frames - 1}")

    twice = {a: fs for a, fs in owner.items() if len(fs) > 1}
    twice.update({a: owner.get(a, []) + fs for a, fs in implied.items() if a in owner or len(fs) > 1})
    if twice:
        fail(f"{len(twice)} address(es) claimed by more than one file frame: "
             + ", ".join(f"{a} by {fs}" for a, fs in sorted(twice.items())[:10]))
    else:
        ok("no address is claimed by two file frames")

    addresses = set(owner) | set(implied)
    summary["address_map"] = {"kind": kind, "runs": len(runs), "run_breaks": breaks,
                              "unnumbered": len(unnumbered), "undecoded": len(undecoded),
                              "undecoded_ranges": as_ranges(undecoded),
                              "unmapped": len(unmapped), "unmapped_ranges": as_ranges(unmapped),
                              "first_address": min(addresses, default=None),
                              "last_address": max(addresses, default=None)}
    if kind == "cav_picture":
        if addresses and max(addresses) >= PICTURE_LIMIT:
            fail(f"pictures reach {max(addresses)}: at or above {PICTURE_LIMIT} the biphase decoder misreads them")
    # On CLV an address is the timecode counted in frames, so the programme is
    # checked the same way. The spec starts a CLV programme at 0:00:00.00, but
    # discs often start it at .01, as Domesday does, so either is a start:
    # address 0 missing is noted, and address 0 present where the programme
    # starts at 1 is noted below with the other addresses beyond it.
    if args.pictures:
        first, last = map(int, args.pictures.split("-"))
        programme = set(range(first, last + 1))
        missing = programme - addresses
        if kind == "clv_timecode" and first == 0 and 0 in missing and 1 in addresses:
            missing.discard(0)
            first = 1
            note("the programme starts at 0:00:00.01, not at .00 as the spec has it")
        beyond = sorted(addresses - programme)
        summary["address_map"]["pictures_missing"] = len(missing)
        summary["address_map"]["pictures_implied"] = len(set(implied) & programme)
        if missing:
            fail(f"{len(missing)} of pictures {first}-{last} resolve to no file frame: {ranges_text(missing)}")
        else:
            ok(f"every picture {first}-{last} resolves to one file frame"
               + (f" ({len(set(implied) & programme)} only by the arithmetic, at undecoded frames)" if implied else ""))
        if beyond:
            note(f"{len(beyond)} address(es) beyond the programme's {first}-{last}: {ranges_text(beyond)}")
    if breaks:
        note(f"{len(breaks)} run break(s) (address discontinuities), at file frames {', '.join(map(str, breaks[:20]))}")
    else:
        note("one run: no address discontinuity")
    if unnumbered and args.system == "PAL":
        note(f"{len(unnumbered)} unnumbered frame(s), unexpected on a PAL video disc: {ranges_text(unnumbered)}")
    elif unnumbered:
        # NTSC film in 3:2 pulldown: one frame in five carries no number.
        note(f"{len(unnumbered)} unnumbered frame(s), the pulldown frames of NTSC film "
             f"({len(unnumbered) / max(frames, 1):.1%} of the file, against 20% for 3:2 pulldown throughout)")
    if undecoded:
        note(f"{len(undecoded)} undecoded frame(s) (numbered on the disc, not recovered): {ranges_text(undecoded)}")
    else:
        note("no undecoded frames")
    uncovered = set(range(frames)) - covered - unmapped
    if uncovered:
        fail(f"{len(uncovered)} file frame(s) in no run and not listed as unmapped: {ranges_text(uncovered)}")

    # --- events -----------------------------------------------------------
    events = doc.get("events") or {}
    lead = frame_set({"ranges": events.get("lead_in") or []}) | frame_set({"ranges": events.get("lead_out") or []})
    summary["events"] = {"lead_in": events.get("lead_in"), "lead_out": events.get("lead_out"),
                         "stop_codes": events.get("stop_codes") or [],
                         "chapters": len(events.get("chapters") or [])}
    if events.get("lead_in") and events.get("lead_out"):
        ok(f"lead-in {events['lead_in']} and lead-out {events['lead_out']} are marked")
    else:
        fail(f"lead-in {events.get('lead_in') or 'not marked'} and lead-out {events.get('lead_out') or 'not marked'}: both must be marked")
    if unmapped - lead:
        fail(f"{len(unmapped - lead)} unmapped frame(s) outside the lead-in and lead-out: {ranges_text(unmapped - lead)}")
    elif unmapped:
        ok(f"the {len(unmapped)} unmapped frame(s) are all lead-in or lead-out")
    stops = events.get("stop_codes") or []
    note(f"{len(stops)} picture stop code(s)" + (f", at file frames {', '.join(map(str, stops[:20]))}" if stops else ""))
    chapters = events.get("chapters") or []
    if chapters:
        order = [c.get("file_frame", -1) for c in chapters]
        if order == sorted(order) and len(set(order)) == len(order):
            ok(f"{len(chapters)} chapter transition(s), in order")
        else:
            fail(f"the {len(chapters)} chapter transitions are not in file-frame order")

    # --- raw VBI ----------------------------------------------------------
    if "raw_vbi" in doc:
        fail("the document carries raw_vbi: the pack is written at map detail")
    else:
        ok("no raw VBI (map detail)")

    print(json.dumps({"checks": checks, "summary": summary}))
    return 1 if any(c["level"] == "fail" for c in checks) else 0


if __name__ == "__main__":
    sys.exit(main())
