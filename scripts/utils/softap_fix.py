#!/usr/bin/env python3

import shutil
import sys
import tempfile
import os


def patch(path: str) -> int:
    with open(path, "r", encoding="utf-8") as f:
        lines = f.readlines()

    # find ".method private onSoftApInterfaceDestroyed(...)" then its
    # matching ".end method"
    start = None
    end = None
    for i, line in enumerate(lines):
        if start is None:
            if line.startswith(".method") and "onSoftApInterfaceDestroyed" in line:
                start = i
        else:
            if line.startswith(".end method"):
                end = i
                break

    if start is None or end is None:
        print("softap_fix: onSoftApInterfaceDestroyed method not found")
        return 1

    body = lines[start + 1:end]
    invoke = [
        j for j, line in enumerate(body)
        if "stopHalAndWificondIfNecessary" in line and "invoke-direct" in line
    ]
    if not invoke:
        print("softap_fix: call not present (already patched or newer base)")
        return 0
    if len(invoke) != 1:
        print(f"softap_fix: expected 1 invoke site, found {len(invoke)}; aborting")
        return 1

    del body[invoke[0]]

    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path) or ".")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.writelines(lines[:start + 1] + body + lines[end:])
    shutil.move(tmp, path)
    print("softap_fix: removed stopHalAndWificondIfNecessary from onSoftApInterfaceDestroyed")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(1)
    sys.exit(patch(sys.argv[1]))
