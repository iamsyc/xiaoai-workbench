import Foundation

/// Root-owned device transaction. Arguments are supplied only after host-side validation.
enum OTADeviceAgent {
    static let source = #"""
#!/bin/sh
set -eu
BASE=/data/xiaoai-ota
LOCK=/tmp/xiaoai-ota.lock
ORIGINAL_PREBOOT='run storeargs;if test ${reboot_mode} = cold_boot; then run try_auto_burn; fi;'
TRIAL_PREBOOT='if test ${xw_ota_state} = armed; then if test ${boot_part} = ${xw_ota_target}; then setenv xw_ota_state trying; else setenv boot_part ${xw_ota_previous}; setenv xw_ota_state rolled_back; fi; setenv boot_failcnt 0; saveenv; else if test ${xw_ota_state} = trying; then setenv boot_part ${xw_ota_previous}; setenv boot_failcnt 0; setenv xw_ota_state rolled_back; saveenv; fi; fi; run xw_ota_preboot;'
fail() { echo "OTA_ERROR=$*" >&2; exit 1; }
get() { fw_env -g "$1"; }
put() { fw_env -s "$1" "$2" >/dev/null; [ "$(get "$1")" = "$2" ] || fail "environment readback: $1"; }
mounted() { awk '$2=="/" {print $1}' /proc/mounts; }
check_device() {
    [ "$(id -u)" = 0 ] || fail root_required
    [ "$(uci -c /usr/share/mico get version.version.HARDWARE)" = LX06 ] || fail model
    [ "$(uci -c /usr/share/mico get version.version.ROM)" = 1.94.13 ] || fail version
    [ "$(get board_id)" = 1 ] || fail board
    case "$(get boot_part):$(mounted)" in boot0:/dev/mtdblock4|boot1:/dev/mtdblock5) ;; *) fail mounted_slot_mismatch;; esac
}
load() { [ -f "$BASE/state" ] || fail no_transaction; . "$BASE/state"; }
save() {
    umask 077
    mkdir -p "$BASE"
    printf 'job=%s\nphase=%s\nprevious=%s\ntarget=%s\nroot_hash=%s\nroot_bytes=%s\nkernel_hash=%s\n' "$job" "$phase" "$previous" "$target" "$root_hash" "$root_bytes" "$kernel_hash" > "$BASE/state.new"
    mv "$BASE/state.new" "$BASE/state"
    sync
}
status() {
    check_device
    echo "XW_BOOT=$(get boot_part)"
    echo "XW_ROOT=$(mounted)"
    echo "XW_BOOT_ID=$(cat /proc/sys/kernel/random/boot_id)"
    echo "XW_VERSION=1.94.13"
    echo "XW_PHASE=idle"
    if [ -f "$BASE/state" ]; then
        load
        # /tmp locks disappear on reboot; a lost writer cannot leave the host permanently pending.
        if [ "$phase" = writing ] && [ ! -d "$LOCK" ]; then phase=failed; fi
        if [ "$(get xw_ota_job)" = "$job" ] && [ "$(get xw_ota_state)" = rolled_back ] && [ "$(get boot_part)" = "$previous" ]; then phase=rolled_back; fi
        echo "XW_JOB=$job"
        echo "XW_PHASE=$phase"
        echo "XW_PREVIOUS=$previous"
        echo "XW_TARGET=$target"
        echo "XW_ROOT_HASH=$root_hash"
    fi
}
restore_entry() { put preboot "$ORIGINAL_PREBOOT"; put boot_failcnt 0; }
reboot_later() { sync; trap '' HUP; (sleep 2; reboot) </dev/null >/tmp/xiaoai-ota-reboot.log 2>&1 & }
case "${1:-}" in
status) status ;;
apply)
    job=$2; root_hash=$3; root_bytes=$4; kernel_hash=$5
    case "$job" in *[!a-zA-Z0-9-]*|'') fail job_id;; esac
    case "$root_hash$kernel_hash" in *[!a-f0-9]*) fail hash;; esac
    [ ${#root_hash} = 64 ] && [ ${#kernel_hash} = 64 ] || fail hash_length
    case "$root_bytes" in *[!0-9]*|'') fail length;; esac
    [ "$root_bytes" -gt 96 ] && [ "$root_bytes" -le 41943040 ] && [ $((root_bytes % 4096)) = 0 ] || fail size
    mkdir "$LOCK" || fail busy
    trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT
    check_device
    [ "$(get preboot)" = "$ORIGINAL_PREBOOT" ] || fail unexpected_preboot
    if [ -f "$BASE/state" ]; then
        prior_phase=$(sed -n 's/^phase=//p' "$BASE/state")
        case "$prior_phase" in uploading|trial|arming) fail transaction_pending;; esac
    fi
    phase=writing
    previous=$(get boot_part)
    if [ "$previous" = boot0 ]; then target=boot1; kernel_dev=boot1; root_dev=system1; kernel_read=/dev/mtdblock3; root_read=/dev/mtdblock5; else target=boot0; kernel_dev=boot0; root_dev=system0; kernel_read=/dev/mtdblock2; root_read=/dev/mtdblock4; fi
    stage=/tmp/xiaoai-ota/$job
    cleanup() {
        result=$?
        if [ "$result" != 0 ]; then
            if [ "$phase" = arming ]; then
                put boot_part "$previous" && put xw_ota_state failed && restore_entry || true
            fi
            phase=failed; save
        fi
        rmdir "$LOCK" 2>/dev/null || true
    }
    trap cleanup EXIT
    trap '' HUP
    [ "$(wc -c < "$stage/root.squashfs")" -eq "$root_bytes" ] || fail root_size
    [ "$(wc -c < "$stage/boot.img")" -eq 6291456 ] || fail kernel_size
    [ "$(sha256sum "$stage/root.squashfs" | cut -d' ' -f1)" = "$root_hash" ] || fail root_hash
    [ "$(sha256sum "$stage/boot.img" | cut -d' ' -f1)" = "$kernel_hash" ] || fail kernel_hash
    save
    # Install the small persistent agent before arming a trial. It never stores the images in /data.
    cp "$stage/agent.sh" "$BASE/agent.sh.new"; chmod 700 "$BASE/agent.sh.new"; mv "$BASE/agent.sh.new" "$BASE/agent.sh"
    check_device; [ "$(get boot_part)" = "$previous" ] || fail slot_changed
    echo 'OTA_STAGE=writing_kernel'
    mtd write "$stage/boot.img" "$kernel_dev"
    [ "$(dd if="$kernel_read" bs=131072 count=48 2>/dev/null | sha256sum | cut -d' ' -f1)" = "$kernel_hash" ] || fail kernel_readback
    check_device; [ "$(get boot_part)" = "$previous" ] || fail slot_changed
    echo 'OTA_STAGE=writing_root'
    mtd write "$stage/root.squashfs" "$root_dev"
    [ "$(dd if="$root_read" bs=4096 count=$((root_bytes / 4096)) 2>/dev/null | sha256sum | cut -d' ' -f1)" = "$root_hash" ] || fail root_readback
    phase=trial; save
    phase=arming
    put xw_ota_target "$target"
    put xw_ota_previous "$previous"
    put xw_ota_preboot "$ORIGINAL_PREBOOT"
    put xw_ota_state armed
    put xw_ota_job "$job"
    put boot_failcnt 0
    put preboot "$TRIAL_PREBOOT"
    put boot_part "$target"
    phase=trial; save
    echo 'OTA_STAGE=trial_armed'
    reboot_later
    ;;
boot-watch)
    [ -f "$BASE/state" ] || exit 0
    load
    [ "$(get xw_ota_job)" = "$job" ] && [ "$phase" = trial ] && [ "$(get xw_ota_state)" = trying ] && [ "$(get boot_part)" = "$target" ] || exit 0
    echo $$ > /tmp/xiaoai-ota-watch-ready
    watched=$job
    # The device owns this deadline, including when both wireless links are unavailable.
    count=0
    while [ "$count" -lt 90 ]; do
        sleep 1; count=$((count + 1)); load
        [ "$job" = "$watched" ] && [ "$phase" = trial ] || exit 0
    done
    [ "$(get xw_ota_state)" = trying ] || exit 0
    echo 'OTA_STAGE=confirmation_timeout_rollback'
    sync; reboot
    ;;
confirm)
    check_device; load
    [ "$(get xw_ota_job)" = "$job" ] && [ "$job" = "$2" ] && [ "$phase" = trial ] && [ "$(get boot_part)" = "$target" ] && [ "$(get xw_ota_state)" = trying ] || fail trial_mismatch
    [ -f /tmp/xiaoai-ota-watch-ready ] && kill -0 "$(cat /tmp/xiaoai-ota-watch-ready)" || fail watcher_not_started
    [ "$(dd if="$(mounted)" bs=4096 count=$((root_bytes / 4096)) 2>/dev/null | sha256sum | cut -d' ' -f1)" = "$root_hash" ] || fail running_root_hash
    pidof rfcomm >/dev/null || fail bluetooth_listener_missing
    put xw_ota_state committed
    restore_entry
    phase=committed; save
    status
    ;;
finish-rollback)
    check_device; load
    [ "$(get xw_ota_job)" = "$job" ] && [ "$job" = "$2" ] && [ "$(get boot_part)" = "$previous" ] && [ "$(get xw_ota_state)" = rolled_back ] || fail rollback_mismatch
    restore_entry; phase=rolled_back; save; status
    ;;
rollback)
    check_device; load
    [ "$job" = "$2" ] || fail job_mismatch
    case "$phase" in trial|committed) ;; *) fail not_reversible;; esac
    # Both original partitions were left untouched throughout the update.
    put boot_part "$previous"; put xw_ota_state rolled_back; put xw_ota_job "$job"; restore_entry
    phase=rolled_back; save; reboot_later
    ;;
*) fail unknown_command;;
esac
"""#
}
