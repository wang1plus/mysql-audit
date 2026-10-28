#!/usr/bin/env python3
"""Insert (or replace) a ThdOffsets row in src/audit_offsets.cc.

Usage:
    insert-offsets.py '"8.4.13","<md5>", 9512, 9552, ...'

The row is placed right after the section marker. A row for the same version
is replaced, so the script is safe to re-run.
"""
import argparse
import pathlib
import re
import sys

MARKERS = {
    "mysql": "/* +++ MYSQL 64 OFFSETS GO HERE +++ */",
    "percona": "/* +++ PERCONA 64 OFFSETS GO HERE +++ */",
    "mariadb": "/* +++ MARIADB 64 OFFSETS GO HERE +++ */",
}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("row", help='row body, e.g. \'"8.4.13","abc...", 9512, 9552, ...\'')
    ap.add_argument("--file", default="src/audit_offsets.cc")
    ap.add_argument("--section", default="mysql", choices=sorted(MARKERS))
    ap.add_argument("--comment", default=None)
    args = ap.parse_args()

    path = pathlib.Path(args.file)
    lines = path.read_text().splitlines(keepends=True)

    m = re.match(r'\s*"([^"]+)"', args.row)
    if not m:
        print("row must start with a quoted version", file=sys.stderr)
        return 2
    version = m.group(1)

    marker = MARKERS[args.section]
    try:
        marker_idx = next(i for i, line in enumerate(lines) if marker in line)
    except StopIteration:
        print(f"marker not found: {marker}", file=sys.stderr)
        return 3

    # drop stale rows for this version first (keeps re-runs idempotent)
    stale = [
        i for i, line in enumerate(lines)
        if re.match(r'\s*\{\s*"%s"\s*,' % re.escape(version), line)
    ]
    # also drop the comment line that documents a stale row
    for i in list(stale):
        if i > 0 and lines[i - 1].strip().startswith("//offsets for:"):
            stale.append(i - 1)
    for i in sorted(set(stale), reverse=True):
        del lines[i]
        if i < marker_idx:
            marker_idx -= 1

    comment = args.comment or f"//offsets for: official mysqld ({version})"
    new_lines = [
        f"\t{comment}\n",
        "\t{" + args.row + "},\n",
    ]
    lines[marker_idx + 1:marker_idx + 1] = new_lines

    path.write_text("".join(lines))
    print(f"inserted {version} after line {marker_idx + 1}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
