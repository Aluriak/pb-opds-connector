#!/usr/bin/env python3
"""Recompute the checksum at the end of a PocketBook settings file.

PocketBook ends its settings files (like opds-connector.cfg) with a line "#<crc32>".
When that line does not match the content, for example after editing the file by
hand, the reader silently loads the backup "<file>.back" instead, and the app
writes that old content back on its next save. Run this after every hand edit.

    fix-config-checksum.py opds-connector.cfg          # fix the checksum
    fix-config-checksum.py --check opds-connector.cfg  # only tell whether it is valid
"""

import re
import sys
import zlib

# What InkView appends: a newline, "#", eight hex digits, a newline
TRAILER = re.compile(rb"\n#([0-9a-fA-F]{8})\n$")


def split(data):
    """The content and the checksum the file states, None if it has none"""
    match = TRAILER.search(data)
    if match is None:
        return data, None
    return data[: match.start()], int(match.group(1), 16)


def main(args):
    check_only = "--check" in args
    paths = [a for a in args if a != "--check"]
    if len(paths) != 1:
        print(__doc__.strip(), file=sys.stderr)
        return 2

    path = paths[0]
    with open(path, "rb") as f:
        data = f.read()

    content, stated = split(data)
    if not content.endswith(b"\n"):
        content += b"\n"
    actual = zlib.crc32(content)

    if check_only:
        if stated == actual:
            print(f"{path}: checksum is valid")
            return 0
        print(f"{path}: checksum is {'missing' if stated is None else 'wrong'}")
        return 1

    with open(path, "wb") as f:
        f.write(content + b"\n#%08x\n" % actual)
    print(f"{path}: checksum set to {actual:08x}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
