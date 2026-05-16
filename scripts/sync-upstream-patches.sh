#!/bin/bash
# Sync upstream Android 4.19 stable patches into kernel source
# Run this inside the kernel source directory (D:\KernelBuild or on GCP VM)

set -e

KERNEL_DIR="${1:-.}"
cd "${KERNEL_DIR}"

echo "=========================================="
echo " Sync Upstream Patches - Linux 4.19"
echo "=========================================="

# Current kernel version
CURRENT_VERSION=$(make kernelrelease 2>/dev/null | head -1 || echo "unknown")
echo "Current kernel: ${CURRENT_VERSION}"

# ===== Option 1: Sync from upstream n0kontzz repo =====
echo ""
echo "[1] Syncing from upstream n0kontzz repo..."

if git remote | grep -q "^upstream$"; then
    echo "Upstream remote already exists"
else
    git remote add upstream https://github.com/bimoalfarrabi/kernel_xiaomi_sm8250_n0kontzz.git
    echo "Added upstream remote"
fi

git fetch upstream

# Check for new commits
LOCAL=$(git rev-parse HEAD)
REMOTE=$(git rev-parse upstream/base)

if [ "$LOCAL" = "$REMOTE" ]; then
    echo "Already up to date with upstream n0kontzz"
else
    echo "New commits found!"
    echo "Local:  ${LOCAL}"
    echo "Remote: ${REMOTE}"
    echo ""
    echo "New commits:"
    git log --oneline HEAD..upstream/base | head -20
    echo ""
    read -p "Merge upstream changes? [Y/n] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        git merge upstream/base --no-edit
        echo "Merged upstream changes"
    fi
fi

# ===== Option 2: Cherry-pick from AOSP android-4.19-stable =====
echo ""
echo "[2] Checking AOSP android-4.19-stable for security patches..."

AOSP_REMOTE="aosp-4.19-stable"
if git remote | grep -q "^${AOSP_REMOTE}$"; then
    echo "AOSP remote already exists"
else
    git remote add "${AOSP_REMOTE}" https://android.googlesource.com/kernel/common.git
    echo "Added AOSP remote"
fi

# Fetch only the android-4.19-stable branch (shallow)
git fetch "${AOSP_REMOTE}" android-4.19-stable --depth=100 2>/dev/null || echo "Fetch failed (may need auth)"

# List recent security patches
echo ""
echo "Recent AOSP android-4.19-stable commits (last 20):"
git log --oneline "${AOSP_REMOTE}/android-4.19-stable" 2>/dev/null | head -20 || echo "Cannot read AOSP branch"

echo ""
echo "=========================================="
echo " Sync complete!"
echo "=========================================="
echo ""
echo "To cherry-pick specific patches:"
echo "  git cherry-pick <commit-hash>"
echo ""
echo "To check what's different:"
echo "  git diff HEAD..${AOSP_REMOTE}/android-4.19-stble --stat"
