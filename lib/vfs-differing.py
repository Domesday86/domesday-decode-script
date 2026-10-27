"""List the EFM sectors two VFS images both recovered but hold different bytes in.

    pack-python lib/vfs-differing.py <a.dat> <b.dat>

Each image's bad sector map is the .bsm beside it, one sector number a line.
A sector counts when neither map lists it and both images reach it; past the
end of the shorter image nothing is compared.

vfs-stacker's dry run counts these sectors but names at most 20 of them, so
the vfs stage reads the full list from here to hold it against the ones the
selection records as known (vfs.baseline_differs).

Prints one JSON object: "compared", the sectors both recovered, and
"differing", the sorted sector numbers.
"""

import json
import sys

SECTOR = 2048


def bad_sectors(path):
    with open(path) as f:
        return {int(line) for line in f if line.strip().isdigit()}


def main():
    a, b = sys.argv[1:3]
    bad = bad_sectors(a + ".bsm") | bad_sectors(b + ".bsm")
    compared, differing = 0, []
    with open(a, "rb") as fa, open(b, "rb") as fb:
        n = 0
        while True:
            x, y = fa.read(SECTOR), fb.read(SECTOR)
            if len(x) < SECTOR or len(y) < SECTOR:
                break
            if n not in bad:
                compared += 1
                if x != y:
                    differing.append(n)
            n += 1
    json.dump({"compared": compared, "differing": differing}, sys.stdout)
    print()


if __name__ == "__main__":
    main()
