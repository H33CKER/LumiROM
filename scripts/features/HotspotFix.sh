#!/bin/bash
source scripts/utils/bash_colors.sh

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
#  com.android.wifi apex and rewrite the apex *in the ROM itself*
#  (capex repack, done here at build time). No bind-mount, no SELinux
#  service, no Magisk, no post-fs-data hooks. The apexd digest inside
#  the capex (originalApexFileDigest) is recomputed so apexd
#  re-decompresses and activates our modified apex normally. This also
#  survives bootloader-unlocked (verifiedbootstate=orange) devices
#  where the apex payload is mounted without merkle enforcement.
# =====================================================================

# ---------------------------------------------------------------
# Build the patched service-wifi.jar (smali edit via softap_fix.py)
# ---------------------------------------------------------------
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
# Swap the service-wifi.jar inside a dm-verity payload image
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

    # Locate the wifi apex that shipped with the base firmware.
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

    # ------------------------------------------------------------
    # 1. unpack the capex (a plain zip container around original_apex)
    # ------------------------------------------------------------
    cp -f "$CAPEX" "$SOFTAP_DIR/original.capex"
    unzip -qq "$SOFTAP_DIR/original.capex" -d "$SOFTAP_DIR/pit" || {
        echo "${RED} - failed to unzip capex${RESET}"
        return 1
    }

    # ------------------------------------------------------------
    # 2. unpack original_apex (contains apex_payload.img) and build
    #    the patched service-wifi.jar
    # ------------------------------------------------------------
    unzip -qq "$SOFTAP_DIR/pit/original_apex" -d "$SOFTAP_DIR/apexzip" || {
        echo "${RED} - failed to unzip original apex${RESET}"
        return 1
    }

    if [ ! -f "$SOFTAP_DIR/apexzip/apex_payload.img" ]; then
        echo "${RED} - apex_payload.img missing${RESET}"
        return 1
    fi

    debugfs -R "dump /javalib/service-wifi.jar $SOFTAP_DIR/patched/service-wifi.jar" \
        "$SOFTAP_DIR/apexzip/apex_payload.img" >/dev/null 2>&1

    HotspotFix_BUILD_PATCHED_JAR "$SOFTAP_DIR" "$APKTOOL" "$SOFTAP_DIR/patched/service-wifi.jar" || {
        echo "${RED} - SoftAp teardown patch aborted${RESET}"
        return 1
    }

    # ------------------------------------------------------------
    # 3. inject the patched jar into the apex_payload.img
    # ------------------------------------------------------------
    HotspotFix_PATCH_PAYLOAD "$SOFTAP_DIR/apexzip/apex_payload.img" \
        "$SOFTAP_DIR/patched/service-wifi.jar" || return 1

    # ------------------------------------------------------------
    # 4. rezip original_apex with the modified payload
    # ------------------------------------------------------------
    ( cd "$SOFTAP_DIR/apexzip" && rm -f ../pit/original_apex ../pit/original_apex.zip && zip -q -r -0 -X ../pit/original_apex.zip . && mv ../pit/original_apex.zip ../pit/original_apex )
    [ -f "$SOFTAP_DIR/pit/original_apex" ] || {
        echo "${RED} - failed to repack original_apex${RESET}"
        return 1
    }

    # ------------------------------------------------------------
    # 5. update the capex apex-manifest digest so apexd re-decompresses
    #    our modified apex instead of dropping it
    # ------------------------------------------------------------
    python3 scripts/utils/softap_fix.py --digest \
        "$SOFTAP_DIR/pit/apex_manifest.pb" \
        "$SOFTAP_DIR/pit/original_apex" || {
        echo "${RED} - failed to update apx manifest digest${RESET}"
        return 1
    }

    # ------------------------------------------------------------
    # 6. rezip the capex and drop it back into the ROM
    # ------------------------------------------------------------
    ( cd "$SOFTAP_DIR/pit" && rm -f ../com.android.wifi.capex ../com.android.wifi.capex.zip \
        && zip -q -r -X ../com.android.wifi.capex.zip \
            AndroidManifest.xml apex_build_info.pb apex_manifest.pb apex_pubkey \
            original_apex META-INF \
        && mv ../com.android.wifi.capex.zip ../com.android.wifi.capex )

    local CAPEX_NEW="$SOFTAP_DIR/com.android.wifi.capex"
    if [ ! -f "$CAPEX_NEW" ]; then
        echo "${RED} - failed to repack capex${RESET}"
        return 1
    fi

    # clean up stale bind-mount remnants (previous fix versions)
    rm -rf "$EXTRACTED_FIRM_DIR/system/system/etc/lumisoftapfix" 2>/dev/null
    rm -f "$EXTRACTED_FIRM_DIR/system/system/etc/init/lumisoftapfix.rc" 2>/dev/null

    cp -f "$CAPEX_NEW" "$CAPEX"
    echo "${GREEN} - Hotspot fix baked into $CAPEX${RESET}"
    return 0
}
