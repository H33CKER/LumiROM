#!/bin/bash
source scripts/utils/bash_colors.sh
export AVBTOOL_BIN="${AVBTOOL:-$PWD/bin/avb/avbtool}"
export APEX_WIFI_FIX_KEY="$PWD/scripts/keys/apex-wifi-fix.pem"
export APEX_WIFI_FIX_PUB="$PWD/scripts/keys/apex-wifi-fix.avbpubkey"

# =====================================================================
#  Hotspot teardown fix, baked into the com.android.wifi apex.
#
#  Root cause on MediaTek devices ported to an A34/A24 base:
#  WifiNative.onSoftApInterfaceDestroyed() ->
#  WifiNative.stopHalAndWificondIfNecessary() -> IWifi.stop() HIDL call
#  into the legacy 1.0 wifi HAL (android.hardware.wifi@1.0-service-lazy),
#  which never answers while the HAL is running wifi_cleanup. The
#  WifiHandlerThread blocks forever and SoftApManager never leaves
#  StartedState, so the WIFI_AP_STATE_DISABLED (11) broadcast is never
#  sent and the hotspot tile stays on "turning off".
#
#  Fix: patch WifiNative inside the service-wifi.jar that lives in the
#  com.android.wifi apex, then rewrite the apex *in the ROM itself*
#  (capex repack at build time). No bind-mounts, no SELinux service, no
#  Magisk, no post-fs-data hooks — the patch is baked into the apex
#  payload image itself. Because apexd compares the payload's embedded
#  AVB hashtree root digest with the one inside the capex's
#  apex_manifest.pb (originalApexDigest), we regenerate the dm-verity
#  hash tree with avbtool (LumiROM's own apex key) and update both the
#  apex digest and its apex_pubkey to keep apexd's verification happy.
# =====================================================================

HotspotFix_BUILD_PATCHED_JAR() {
    if [ "$#" -ne 3 ]; then
        echo "Usage: ${FUNCNAME[0]} <WORK_DIR_SOFTAP> <APKTOOL_JAR> <SRC_JAR>"
        return 1
    fi
    local SOFTAP_DIR="$1"
    local APKTOOL_JAR="$2"
    local SRC_JAR="$3"
    local SMALI_OUT="$SOFTAP_DIR/services"

    rm -rf "$SMALI_OUT"
    java -jar "$APKTOOL_JAR" d -f "$SRC_JAR" -o "$SMALI_OUT" >/dev/null 2>&1 || {
        echo "${RED} - apktool decompile failed for service-wifi.jar${RESET}"
        return 1
    }

    local SMALI
    SMALI="$(ls "$SMALI_OUT"/smali*/com/android/server/wifi/WifiNative.smali 2>/dev/null | grep -v '\$' | head -1)"
    if [ -z "$SMALI" ]; then
        echo "${RED} - WifiNative.smali not found inside apex${RESET}"
        return 1
    fi

    echo "${YELLOW} - Patching WifiNative in service-wifi.jar${RESET}"
    python3 scripts/utils/softap_fix.py "$SMALI" || {
        echo "${RED} - softap smali edit failed${RESET}"
        return 1
    }

    java -jar "$APKTOOL_JAR" b "$SMALI_OUT" -o "$SOFTAP_DIR/patched/service-wifi.jar" >/dev/null 2>&1 || {
        echo "${RED} - apktool build failed for service-wifi.jar${RESET}"
        return 1
    }
    return 0
}

# ---------------------------------------------------------------
# Extract the raw ext4 region from a payload with an existing AVB footer
# ---------------------------------------------------------------
HotspotFix_STRIP_AVB_FOOTER() {
    if [ "$#" -ne 2 ]; then
        echo "Usage: ${FUNCNAME[0]} <APEX_PAYLOAD_IMG> <OUTPUT_RAW_IMG>"
        return 1
    fi
    local SRC="$1"
    local OUT="$2"
    local FS_BYTES
    FS_BYTES=$("${AVBTOOL_BIN:-$PWD/bin/avb/avbtool}" info_image --image "$SRC" 2>/dev/null | awk '/Original image size:/ {print $4}')
    if [ -z "$FS_BYTES" ]; then
        echo "${RED} - failed to read the ext4 size from payload${RESET}"
        return 1
    fi
    dd if="$SRC" of="$OUT" bs="$FS_BYTES" count=1 status=none
    return 0
}

# ---------------------------------------------------------------
# Rebuild the dm-verity hashtree + vbmeta of the patched payload
# ---------------------------------------------------------------
HotspotFix_SIGN_PAYLOAD() {
    if [ "$#" -ne 2 ]; then
        echo "Usage: ${FUNCNAME[0]} <RAW_FS_IMG> <NEW_PAYLOAD_IMG>"
        return 1
    fi
    local RAW="$1"
    local OUT="$2"
    mkdir -p "$(dirname "$OUT")"

    local FS_BYTES
    FS_BYTES=$(stat -c%s "$RAW")

    local SALT
    SALT=$("${AVBTOOL_BIN:-$PWD/bin/avb/avbtool}" info_image --image "$APEX_WIFI_PREVIOUS_PAYLOAD" 2>/dev/null | awk '/Salt:/ {print $2}')
    if [ -z "$SALT" ]; then
        SALT="2be4f352b93bda691f7e4a725dd39e328148bd3ce46838ad5e0e81db16eb56fa"
    fi

    # avbtool appends the hashtree + vbmeta and pads up to partition_size; a
    # ~100 KiB hashtree needs a little headroom over the raw ext4 size.
    local PART_SIZE=$((FS_BYTES + FS_BYTES / 64 + 262144))
    PART_SIZE=$(((PART_SIZE + 4095) / 4096 * 4096))

    "${AVBTOOL_BIN:-$PWD/bin/avb/avbtool}" add_hashtree_footer \
        --image "$RAW" \
        --partition_size "$PART_SIZE" \
        --partition_name "" \
        --hash_algorithm sha256 \
        --salt "$SALT" \
        --key "$APEX_WIFI_FIX_KEY" \
        --algorithm SHA256_RSA4096 \
        --prop apex.key:com.android.wifi \
        --do_not_generate_fec || {
        echo "${RED} - avbtool add_hashtree_footer failed${RESET}"
        return 1
    }
    mv -f "$RAW" "$OUT"
    return 0
}

# ---------------------------------------------------------------
# Extract the new payload root digest
# ---------------------------------------------------------------
HotspotFix_GET_ROOT_DIGEST() {
    if [ "$#" -ne 1 ]; then
        echo "Usage: ${FUNCNAME[0]} <APEX_PAYLOAD_IMG>"
        return 1
    fi
    "${AVBTOOL_BIN:-$PWD/bin/avb/avbtool}" info_image --image "$1" 2>/dev/null | awk '/Root Digest:/ {print $3}'
}

# ---------------------------------------------------------------
# Locate the Android SDK's zipalign (preferred) for APEX page alignment
# ---------------------------------------------------------------
HotspotFix_FIND_ZIPALIGN() {
    if [ -n "$ZIPALIGN" ] && [ -x "$ZIPALIGN" ]; then
        echo "$ZIPALIGN"
        return 0
    fi
    if command -v zipalign >/dev/null 2>&1; then
        command -v zipalign
        return 0
    fi
    local root cand roots
    roots="$ANDROID_HOME $ANDROID_SDK_ROOT $HOME/Android/Sdk $HOME/android-sdk ${ANDROID_HOME:-/nonexistent}"
    for root in $roots; do
        [ -d "$root/build-tools" ] || continue
        cand=$(ls -1 "$root"/build-tools/*/zipalign 2>/dev/null | sort -V | tail -1)
        if [ -n "$cand" ]; then
            echo "$cand"
            return 0
        fi
    done
    return 1
}

# ---------------------------------------------------------------
# Replace the service-wifi.jar inside the ext4 payload
# ---------------------------------------------------------------
HotspotFix_PATCH_PAYLOAD() {
    if [ "$#" -ne 2 ]; then
        echo "Usage: ${FUNCNAME[0]} <PAYLOAD_IMG> <PATCHED_JAR>"
        return 1
    fi
    local PAYLOAD_IMG="$1"
    local PATCHED_JAR="$2"

    debugfs -w -R "rm /javalib/service-wifi.jar" "$PAYLOAD_IMG" >/dev/null 2>&1
    debugfs -w -R "write $PATCHED_JAR /javalib/service-wifi.jar" "$PAYLOAD_IMG" >/dev/null 2>&1

    local INODE
    INODE=$(debugfs -R "ls -l /javalib" "$PAYLOAD_IMG" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($NF=="service-wifi.jar") print $1}')
    if [ -n "$INODE" ] && [ "$INODE" != "service-wifi.jar" ]; then
        debugfs -w -R "sif <$INODE> uid 1000" "$PAYLOAD_IMG" >/dev/null 2>&1
        debugfs -w -R "sif <$INODE> gid 1000" "$PAYLOAD_IMG" >/dev/null 2>&1
    fi
    echo "${GREEN} - payload patched${RESET}"
    return 0
}

ADD_SOFTAP_FIX() {
    echo ""
    if [ "$#" -ne 1 ]; then
        echo "Usage: ${FUNCNAME[0]} <EXTRACTED_FIRM_DIR>"
        return 1
    fi

    local EXTRACTED_FIRM_DIR="$1"

    echo "${YELLOW}Patching Hotspot...${RESET}"

    local CAPEX=""
    local cand
    for cand in \
        "$EXTRACTED_FIRM_DIR/system/system/apex/com.android.wifi.capex" \
        "$EXTRACTED_FIRM_DIR/system/apex/com.android.wifi.capex" \
        "$EXTRACTED_FIRM_DIR/system/system/apex/com.android.wifi.apex" \
        "$EXTRACTED_FIRM_DIR/system/apex/com.android.wifi.apex"; do
        if [ -f "$cand" ]; then
            CAPEX="$cand"
            break
        fi
    done
    if [ -z "$CAPEX" ]; then
        echo "${RED}Warning: com.android.wifi apex not found, skipping SoftAp fix${RESET}"
        return 0
    fi

    local SOFTAP_DIR="$WORK_DIR/softapfix"
    rm -rf "$SOFTAP_DIR"
    mkdir -p "$SOFTAP_DIR/pit" "$SOFTAP_DIR/patched" "$SOFTAP_DIR/apexzip"

    {
        cp -f "$CAPEX" "$SOFTAP_DIR/pit/original.capex"
        unzip -qq "$SOFTAP_DIR/pit/original.capex" -d "$SOFTAP_DIR/pit" &&
        unzip -qq "$SOFTAP_DIR/pit/original_apex" -d "$SOFTAP_DIR/apexzip"
    } >/dev/null 2>&1 || {
        echo "${RED} - failed to unzip capex${RESET}"
        return 1
    }

    local PAYLOAD="$SOFTAP_DIR/apexzip/apex_payload.img"
    if [ ! -f "$PAYLOAD" ]; then
        echo "${RED} - apex_payload.img missing${RESET}"
        return 1
    fi

    export APEX_WIFI_PREVIOUS_PAYLOAD="$PAYLOAD"

    debugfs -R "dump /javalib/service-wifi.jar $SOFTAP_DIR/patched/service-wifi.jar" \
        "$PAYLOAD" >/dev/null 2>&1

    HotspotFix_BUILD_PATCHED_JAR "$SOFTAP_DIR" "$APKTOOL" "$SOFTAP_DIR/patched/service-wifi.jar" || {
        echo "${RED} - SoftAp teardown patch aborted${RESET}"
        return 1
    }

    HotspotFix_PATCH_PAYLOAD "$PAYLOAD" "$SOFTAP_DIR/patched/service-wifi.jar" || {
        echo "${RED} - patching service-wifi.jar into payload failed${RESET}"
        return 1
    }

    HotspotFix_STRIP_AVB_FOOTER "$PAYLOAD" "$SOFTAP_DIR/patched/payload_raw.img" || {
        echo "${RED} - failed to strip avb footer${RESET}"
        return 1
    }

    HotspotFix_SIGN_PAYLOAD "$SOFTAP_DIR/patched/payload_raw.img" "$SOFTAP_DIR/patched/payload_rebuilt.img" || {
        echo "${RED} - failed to re-sign payload${RESET}"
        return 1
    }

    cp -f "$SOFTAP_DIR/patched/payload_rebuilt.img" "$PAYLOAD"
    cp -f "$APEX_WIFI_FIX_PUB" "$SOFTAP_DIR/apexzip/apex_pubkey"
    cp -f "$APEX_WIFI_FIX_PUB"  "$SOFTAP_DIR/pit/apex_pubkey"

    local ROOT_DIGEST
    ROOT_DIGEST=$(HotspotFix_GET_ROOT_DIGEST "$PAYLOAD") || ROOT_DIGEST=""
    if [ -z "$ROOT_DIGEST" ]; then
        echo "${RED} - failed to compute the new root digest${RESET}"
        return 1
    fi

    python3 scripts/utils/softap_fix.py --digest \
        "$SOFTAP_DIR/pit/apex_manifest.pb" "$ROOT_DIGEST" || {
        echo "${RED} - failed to update the apex manifest digest${RESET}"
        return 1
    }

    ( cd "$SOFTAP_DIR/apexzip" && rm -f ../pit/original_apex ../pit/original_apex.zip \
        && zip -q -r -0 -X ../pit/original_apex.zip . \
        && mv ../pit/original_apex.zip ../pit/original_apex )

    # dm-verity needs apex_payload.img on a 4096-byte boundary inside the
    # APEX; plain zip loses that alignment and apexd fails the mount with
    # EINVAL. zipalign is the canonical fix (AOSP builds use it too); fall
    # back to the portable python implementation when it is unavailable.
    local ZIPALIGN_BIN
    if ZIPALIGN_BIN=$(HotspotFix_FIND_ZIPALIGN); then
        echo "${YELLOW} - Aligning apex with $ZIPALIGN_BIN${RESET}"
        "$ZIPALIGN_BIN" -f 4096 \
            "$SOFTAP_DIR/pit/original_apex" "$SOFTAP_DIR/pit/original_apex.aligned" || {
            echo "${RED} - zipalign failed${RESET}"
            return 1
        }
        mv -f "$SOFTAP_DIR/pit/original_apex.aligned" "$SOFTAP_DIR/pit/original_apex"
    else
        echo "${YELLOW} - zipalign not found, using python fallback${RESET}"
        python3 scripts/utils/softap_fix.py --align \
            "$SOFTAP_DIR/pit/original_apex" 4096 || {
            echo "${RED} - apex alignment failed${RESET}"
            return 1
        }
    fi

    ( cd "$SOFTAP_DIR/pit" && rm -f "$CAPEX" "$CAPEX.zip" \
        && zip -q -r -X "$CAPEX.zip" AndroidManifest.xml \
            apex_build_info.pb apex_manifest.pb apex_pubkey \
            original_apex META-INF \
        && mv "$CAPEX.zip" "$CAPEX" )

    echo "${GREEN} - Hotspot fix baked into $CAPEX${RESET}"
    return 0
}
