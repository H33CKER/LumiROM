#!/bin/bash
source scripts/utils/bash_colors.sh

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
    mkdir -p "$SOFTAP_DIR/pit" "$SOFTAP_DIR/patched"

    if [[ "$CAPEX" == *.capex ]]; then
        unzip -oqq "$CAPEX" "original_apex" -d "$SOFTAP_DIR/pit" || {
            echo "${RED} - failed to read capex${RESET}"
            return 1
        }
        # original_apex is an apex zip carrying the dm-verity payload img
        unzip -oqq "$SOFTAP_DIR/pit/original_apex" "apex_payload.img" -d "$SOFTAP_DIR/pit" || {
            echo "${RED} - failed to unzip original apex payload${RESET}"
            return 1
        }
    fi

    local PAYLOAD_IMG="$SOFTAP_DIR/pit/apex_payload.img"
    if [ ! -f "$PAYLOAD_IMG" ]; then
        echo "${RED} - apex_payload.img missing${RESET}"
        return 1
    fi

    debugfs -R "dump /javalib/service-wifi.jar $SOFTAP_DIR/patched/service-wifi.jar" \
        "$PAYLOAD_IMG" >/dev/null 2>&1 || {
        echo "${RED} - could not extract service-wifi.jar from apex payload img${RESET}"
        return 1
    }
    HotspotFix_BUILD_PATCHED_JAR "$SOFTAP_DIR" "$APKTOOL" "$SOFTAP_DIR/patched/service-wifi.jar" || {
        echo "${RED} - SoftAp teardown patch aborted${RESET}"
        return 1
    }

    local FIX_DIR="$EXTRACTED_FIRM_DIR/system/system/etc/lumisoftapfix"
    local INIT_DIR="$EXTRACTED_FIRM_DIR/system/system/etc/init"
    mkdir -p "$FIX_DIR" "$INIT_DIR"

    cp -f "$SOFTAP_DIR/patched/service-wifi.jar" "$FIX_DIR/service-wifi.jar"

    cat > "$INIT_DIR/lumisoftapfix.rc" <<'LUMISOFTAPFIX_RC'
service lumisoftapfix /system/bin/sh /system/etc/lumisoftapfix/mount.sh
    user root
    group root
    oneshot
    disabled
    seclabel u:r:lumisoftapfix:s0

on post-fs-data
    start lumisoftapfix
LUMISOFTAPFIX_RC

    # Wait for apex activation to finish before mounting (com.android.wifi
    # activates during post-fs-data), then overlay the patched jar.
    cat > "$FIX_DIR/mount.sh" <<'LUMISOFTAPFIX_SH'
#!/system/bin/sh
DST=/apex/com.android.wifi/javalib/service-wifi.jar
SRC=/system/etc/lumisoftapfix/service-wifi.jar
i=0
while [ $i -lt 60 ]; do
    [ -e "$DST" ] && break
    sleep 1
    i=$((i+1))
done
[ -e "$DST" ] || exit 0
mount -o bind "$SRC" "$DST" 2>/dev/null
LUMISOFTAPFIX_SH
    chmod 755 "$FIX_DIR/mount.sh"


    # Baked SELinux rules for the lumisoftapfix service domain (Enforcing).
    # Mirrors the magisk-module flow so no Magisk module is required.
    local SELINUX_CIL="$EXTRACTED_FIRM_DIR/system/system_ext/etc/selinux/system_ext_sepolicy.cil"
    if [ -f "$SELINUX_CIL" ]; then
        if ! grep -q "(type lumisoftapfix)" "$SELINUX_CIL"; then
            cat >> "$SELINUX_CIL" <<'LUMISOFTAPFIX_CIL'

(type lumisoftapfix)
(allow init lumisoftapfix (process (transition)))
(allow lumisoftapfix system_file (dir (search)))
(allow lumisoftapfix system_file (file (execute open read getattr execute_no_trans mounton)))
(allow lumisoftapfix shell_exec (file (entrypoint execute open read getattr execute_no_trans)))
(allow lumisoftapfix fs_type (filesystem (mount unmount)))
(allow lumisoftapfix proc (dir (search)))
(allow lumisoftapfix proc (file (read open getattr)))
(allow lumisoftapfix self (process (setexec)))
LUMISOFTAPFIX_CIL
        fi
    fi

    echo "${GREEN} - Hotspot fix installed${RESET}"
    return 0
}
