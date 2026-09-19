#!/usr/bin/env python3
"""SoftAp teardown fix (two modes).

Mode 1 (default): patch decompiled smali
    softap_fix.py <WifiNative.smali>

Removes the WifiNative.stopHalAndWificondIfNecessary() invoke from
WifiNative.onSoftApInterfaceDestroyed().

Why: on MediaTek devices ported to a newer base (A34/A24), when the
SoftAp interface is destroyed the framework stops the legacy wifi HAL
synchronously from inside the interface-destroyed listener. The
android.hardware.wifi@1.0-service-lazy HAL is in the middle of
wifi_cleanup at that point and never answers IWifi.stop(), blocking
the WifiHandlerThread forever. SoftApManager then never reaches
StartedState.exit()'s updateApState(11) and the hotspot tile stays on
"turning off" until reboot.

Mode 2: patch the capex digest
    softap_fix.py --digest <apex_manifest.pb> <original_apex>

Recomputes the SHA-256 of the (post-patch) original_apex and rewrites
the originalApexFileDigest field of the capex-level apex_manifest.pb so
apexd re-decompresses and activates the modified apex instead of
dropping the /data/apex/decompressed cache.
"""

import hashlib
import os
import re
import shutil
import sys
import tempfile


# ------------------------------------------------------------------
# mode 1: smali edit
# ------------------------------------------------------------------
def patch_smali(path: str) -> int:
    with open(path, "r", encoding="utf-8") as f:
        lines = f.readlines()

    start = end = None
    for i, line in enumerate(lines):
        if start is None:
            if line.startswith(".method") and "onSoftApInterfaceDestroyed" in line:
                start = i
        elif line.startswith(".end method"):
            end = i
            break

    if start is None or end is None:
        print("softap_fix: onSoftApInterfaceDestroyed method not found")
        return 1

    body = lines[start + 1:end]
    invoke = [j for j, line in enumerate(body)
              if "stopHalAndWificondIfNecessary" in line and "invoke-direct" in line]
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


# ------------------------------------------------------------------
# mode 2: bump the capex-level apex_manifest originalApexFileDigest
# ------------------------------------------------------------------
# The capex apex_manifest.pb stores the digest nested inside field 12:
#   tag 0x62 (field 12, wiretype 2), varint len, then field 1 sub-bytes
#   (0x0a 0x40 + 64 hex chars).
def patch_apex_manifest_digest(manifest_path: str, original_apex_path: str) -> int:
    data = open(manifest_path, "rb").read()

    old = re.search(b"\x0a\x40([0-9a-f]{64})", data)
    if not old:
        old = re.search(b"\x0a\x38([0-9a-f]{56})", data)
    if not old:
        print("softap_fix: originalApexFileDigest not found in apex_manifest.pb")
        return 1

    new_hex = hashlib.sha256(open(original_apex_path, "rb").read()).hexdigest().encode()
    patched = data.replace(old.group(1), new_hex)
    if patched == data:
        print("softap_fix: apex digest already up to date")
        return 0

    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(manifest_path) or ".")
    with os.fdopen(fd, "wb") as f:
        f.write(patched)
    shutil.move(tmp, manifest_path)
    print("softap_fix: originalApexFileDigest updated")
    return 0


def main() -> int:
    if len(sys.argv) == 4 and sys.argv[1] == "--digest":
        return patch_apex_manifest_digest(sys.argv[2], sys.argv[3])
    if len(sys.argv) != 2:
        print(__doc__)
        return 1
    return patch_smali(sys.argv[1])


if __name__ == "__main__":
    sys.exit(main())
