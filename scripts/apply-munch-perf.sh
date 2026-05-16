#!/bin/bash
# Performance optimization script for Poco F4 (munch) kernel
# Based on kernel_xiaomi_sm8250_n0kontzz repo
# This script applies performance-focused config overrides to the defconfig

DEFCONFIG_PATH="arch/arm64/configs/vendor/munch_defconfig"
FRAGMENT_PATH="arch/arm64/configs/vendor/munch_perf.config"

if [ ! -f "$DEFCONFIG_PATH" ]; then
    echo "ERROR: $DEFCONFIG_PATH not found. Run this from kernel source root."
    exit 1
fi

echo "Applying performance optimizations for Poco F4 (munch)..."

# Backup original defconfig
cp "$DEFCONFIG_PATH" "${DEFCONFIG_PATH}.bak"

# Merge performance fragment into defconfig
if [ -f "$FRAGMENT_PATH" ]; then
    # Use scripts/merge_config.sh if available
    if [ -f "scripts/kconfig/merge_config.sh" ]; then
        scripts/kconfig/merge_config.sh -m "$DEFCONFIG_PATH" "$FRAGMENT_PATH"
    else
        # Manual merge: append fragment, then deduplicate
        cat "$FRAGMENT_PATH" >> "$DEFCONFIG_PATH"
        # Remove duplicate lines, keeping last occurrence
        tac "$DEFCONFIG_PATH" | awk '!seen[$0]++' | tac > "${DEFCONFIG_PATH}.tmp"
        mv "${DEFCONFIG_PATH}.tmp" "$DEFCONFIG_PATH"
    fi
    echo "Performance config fragment merged successfully."
else
    echo "ERROR: Performance fragment $FRAGMENT_PATH not found."
    exit 1
fi

echo "Done. Performance optimizations applied to $DEFCONFIG_PATH"
