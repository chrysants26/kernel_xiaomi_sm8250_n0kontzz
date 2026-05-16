#!/bin/bash
# Build performance kernel for Poco F4 (munch) on GCP VM
# Run this INSIDE the GCP VM after SSH-ing in

set -e

# ===== CONFIGURATION =====
KERNEL_TREE_URL="${KERNEL_TREE_URL:-https://github.com/bimoalfarrabi/kernel_xiaomi_sm8250_n0kontzz}"
KERNEL_TREE_BRANCH="${KERNEL_TREE_BRANCH:-base}"
KERNELSU_SETUP_URL="${KERNELSU_SETUP_URL:-https://raw.githubusercontent.com/KernelSU-Next/KernelSU-Next/refs/heads/dev/kernel/setup.sh}"
KERNELSU_SETUP_BRANCH="${KERNELSU_SETUP_BRANCH:-legacy}"
KERNELSU_PATCHES="${KERNELSU_PATCHES:-}"

# SuSFS (root hiding for KernelSU)
SUSFS_ENABLED="${SUSFS_ENABLED:-false}"
SUSFS_REPO_URL="${SUSFS_REPO_URL:-https://gitlab.com/simonpunk/susfs4ksu.git}"
SUSFS_BRANCH="${SUSFS_BRANCH:-kernel-4.19}"

ANYKERNEL_URL="${ANYKERNEL_URL:-https://github.com/bimoalfarrabi/AKmunch}"
ANYKERNEL_BRANCH="${ANYKERNEL_BRANCH:-main}"
ANYKERNEL_ZIP_NAME="${ANYKERNEL_ZIP_NAME:-N0Kontzzz-Perf-munch}"

# Clang toolchain
CLANG_TOOLCHAIN="${CLANG_TOOLCHAIN:-neutron}"
# Options: neutron, aosp-20, aosp-21

# Performance options
ENABLE_THINLTO="${ENABLE_THINLTO:-true}"
ENABLE_POLLY="${ENABLE_POLLY:-true}"
TIMER_HZ="${TIMER_HZ:-300}"
CPU_GOVERNOR="${CPU_GOVERNOR:-performance}"

# Build options
USE_CCACHE="${USE_CCACHE:-true}"
CCACHE_SIZE="${CCACHE_SIZE:-5G}"
NUM_JOBS="${NUM_JOBS:-$(nproc --all)}"

# ===== COLOR OUTPUT =====
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()  { echo -e "${CYAN}[STEP]${NC} $1"; }

# ===== DISPLAY CONFIG =====
echo "=============================================="
echo " Performance Kernel Build - Poco F4 (munch)"
echo "=============================================="
echo " Kernel Tree : ${KERNEL_TREE_URL}"
echo " Branch      : ${KERNEL_TREE_BRANCH}"
echo " Clang       : ${CLANG_TOOLCHAIN}"
echo " ThinLTO     : ${ENABLE_THINLTO}"
echo " Polly       : ${ENABLE_POLLY}"
echo " Timer       : ${TIMER_HZ}Hz"
echo " Governor    : ${CPU_GOVERNOR}"
echo " Jobs        : ${NUM_JOBS}"
echo " CCACHE      : ${USE_CCACHE}"
echo "=============================================="
echo ""

# ===== INSTALL DEPENDENCIES =====
log_step "Installing dependencies..."
sudo apt-get update -qq
sudo apt-get install -y -qq \
    build-essential git gcc-aarch64-linux-gnu bison flex \
    libelf-dev libssl-dev bc python3 python-is-python3 zstd curl wget zip unzip \
    ccache > /dev/null 2>&1

# ===== SETUP WORKSPACE =====
WORKDIR="$HOME/kernel_build"
mkdir -p "${WORKDIR}"
cd "${WORKDIR}"

# ===== SETUP CCACHE =====
if [[ "${USE_CCACHE}" == "true" ]]; then
    log_step "Setting up ccache..."
    export USE_CCACHE=1
    export CCACHE_EXEC=$(which ccache)
    ccache -M "${CCACHE_SIZE}"
    ccache -z
    log_info "Ccache size: ${CCACHE_SIZE}"
fi

# ===== DOWNLOAD CLANG =====
log_step "Downloading Clang toolchain (${CLANG_TOOLCHAIN})..."
CLANG_DIR="${WORKDIR}/clang"

if [ ! -d "${CLANG_DIR}/bin" ]; then
    mkdir -p "${CLANG_DIR}"
    if [[ "${CLANG_TOOLCHAIN}" == "aosp-20" ]]; then
        wget -q https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/refs/heads/main/clang-r547379.tar.gz -O clang.tar.gz
        tar -xf clang.tar.gz -C "${CLANG_DIR}"
    elif [[ "${CLANG_TOOLCHAIN}" == "aosp-21" ]]; then
        wget -q https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/508ea7dd0d8f681904d0422e98af9613aaabf180/clang-r574158.tar.gz -O clang.tar.gz
        tar -xf clang.tar.gz -C "${CLANG_DIR}"
    else
        wget -q https://github.com/Neutron-Toolchains/clang-build-catalogue/releases/download/10032024/neutron-clang-10032024.tar.zst -O clang.tar.zst
        unzstd -d clang.tar.zst -o clang.tar
        tar -xf clang.tar -C "${CLANG_DIR}"
        rm -f clang.tar
    fi
    rm -f clang.tar.gz clang.tar.zst
    log_info "Clang downloaded to ${CLANG_DIR}"
else
    log_info "Clang already cached at ${CLANG_DIR}"
fi

export PATH="${CLANG_DIR}/bin:${PATH}"

# Verify clang
CLANG_VERSION=$(clang --version 2>/dev/null | head -1 || echo "NOT FOUND")
log_info "Clang: ${CLANG_VERSION}"

# ===== CLONE KERNEL SOURCE =====
log_step "Cloning kernel source..."
KERNEL_DIR="${WORKDIR}/kernel_tree"

if [ ! -d "${KERNEL_DIR}/.git" ]; then
    git clone --depth=1 "${KERNEL_TREE_URL}" -b "${KERNEL_TREE_BRANCH}" "${KERNEL_DIR}"
    log_info "Kernel cloned"
else
    log_info "Kernel source already exists, pulling latest..."
    cd "${KERNEL_DIR}"
    git pull --ff-only
fi

cd "${KERNEL_DIR}"

# ===== APPLY PERFORMANCE OPTIMIZATIONS =====
log_step "Applying performance optimizations..."
DEFCONFIG="arch/arm64/configs/vendor/munch_defconfig"

# Backup original
cp "${DEFCONFIG}" "${DEFCONFIG}.orig"

# CPU Governor
if [[ "${CPU_GOVERNOR}" == "performance" ]]; then
    sed -i 's/CONFIG_CPU_FREQ_DEFAULT_GOV_SCHEDUTIL=y/# CONFIG_CPU_FREQ_DEFAULT_GOV_SCHEDUTIL is not set/' "$DEFCONFIG"
    echo "CONFIG_CPU_FREQ_DEFAULT_GOV_PERFORMANCE=y" >> "$DEFCONFIG"
    log_info "CPU governor set to: performance"
fi

# Timer Frequency
HZ="${TIMER_HZ}"
sed -i 's/CONFIG_HZ_[0-9]*=y/# CONFIG_HZ_OLD is not set/' "$DEFCONFIG"
sed -i "s/CONFIG_HZ=.*/CONFIG_HZ=${HZ}/" "$DEFCONFIG"
echo "CONFIG_HZ_${HZ}=y" >> "$DEFCONFIG"
log_info "Timer frequency: ${HZ}Hz"

# Full Preemption
sed -i 's/CONFIG_PREEMPT_NONE=y/# CONFIG_PREEMPT_NONE is not set/' "$DEFCONFIG"
sed -i 's/CONFIG_PREEMPT_VOLUNTARY=y/# CONFIG_PREEMPT_VOLUNTARY is not set/' "$DEFCONFIG"
echo "CONFIG_PREEMPT=y" >> "$DEFCONFIG"
log_info "Full preemption enabled"

# Disable Debug
sed -i 's/CONFIG_DEBUG_KERNEL=y/# CONFIG_DEBUG_KERNEL is not set/' "$DEFCONFIG"
sed -i 's/CONFIG_DEBUG_INFO=y/# CONFIG_DEBUG_INFO is not set/' "$DEFCONFIG"
sed -i 's/CONFIG_DEBUG_PREEMPT=y/# CONFIG_DEBUG_PREEMPT is not set/' "$DEFCONFIG"
sed -i 's/CONFIG_DEBUG_SPINLOCK=y/# CONFIG_DEBUG_SPINLOCK is not set/' "$DEFCONFIG"
sed -i 's/CONFIG_DEBUG_MUTEXES=y/# CONFIG_DEBUG_MUTEXES is not set/' "$DEFCONFIG"
sed -i 's/CONFIG_DEBUG_ATOMIC_SLEEP=y/# CONFIG_DEBUG_ATOMIC_SLEEP is not set/' "$DEFCONFIG"
sed -i 's/CONFIG_DEBUG_LIST=y/# CONFIG_DEBUG_LIST is not set/' "$DEFCONFIG"
sed -i 's/CONFIG_DEBUG_BUGVERBOSE=y/# CONFIG_DEBUG_BUGVERBOSE is not set/' "$DEFCONFIG"
sed -i 's/CONFIG_FTRACE=y/# CONFIG_FTRACE is not set/' "$DEFCONFIG"
sed -i 's/CONFIG_FUNCTION_TRACER=y/# CONFIG_FUNCTION_TRACER is not set/' "$DEFCONFIG"
sed -i 's/CONFIG_IRQSOFF_TRACER=y/# CONFIG_IRQSOFF_TRACER is not set/' "$DEFCONFIG"
sed -i 's/CONFIG_SCHED_TRACER=y/# CONFIG_SCHED_TRACER is not set/' "$DEFCONFIG"
sed -i 's/CONFIG_BLK_DEV_IO_TRACE=y/# CONFIG_BLK_DEV_IO_TRACE is not set/' "$DEFCONFIG"
sed -i 's/CONFIG_KPROBES=y/# CONFIG_KPROBES is not set/' "$DEFCONFIG"
sed -i 's/CONFIG_KASAN=y/# CONFIG_KASAN is not set/' "$DEFCONFIG"
sed -i 's/CONFIG_STACK_TRACER=y/# CONFIG_STACK_TRACER is not set/' "$DEFCONFIG"
sed -i 's/CONFIG_DEBUG_RODATA=y/# CONFIG_DEBUG_RODATA is not set/' "$DEFCONFIG"
sed -i 's/CONFIG_DEBUG_OBJECTS=y/# CONFIG_DEBUG_OBJECTS is not set/' "$DEFCONFIG"
sed -i 's/CONFIG_DEBUG_KMEMLEAK=y/# CONFIG_DEBUG_KMEMLEAK is not set/' "$DEFCONFIG"
sed -i 's/CONFIG_PROVE_LOCKING=y/# CONFIG_PROVE_LOCKING is not set/' "$DEFCONFIG"
sed -i 's/CONFIG_MAGIC_SYSRQ=y/# CONFIG_MAGIC_SYSRQ is not set/' "$DEFCONFIG"
log_info "Debug options disabled"

# TCP BBR
echo "CONFIG_TCP_CONG_BBR=y" >> "$DEFCONFIG"
sed -i 's/CONFIG_DEFAULT_TCP_CONG="cubic"/CONFIG_DEFAULT_TCP_CONG="bbr"/' "$DEFCONFIG"
sed -i 's/CONFIG_DEFAULT_TCP_CONG="reno"/CONFIG_DEFAULT_TCP_CONG="bbr"/' "$DEFCONFIG"
log_info "TCP BBR enabled"

# LZ4 Compression
sed -i 's/CONFIG_KERNEL_GZIP=y/# CONFIG_KERNEL_GZIP is not set/' "$DEFCONFIG"
sed -i 's/CONFIG_KERNEL_LZMA=y/# CONFIG_KERNEL_LZMA is not set/' "$DEFCONFIG"
sed -i 's/CONFIG_KERNEL_XZ=y/# CONFIG_KERNEL_XZ is not set/' "$DEFCONFIG"
sed -i 's/CONFIG_KERNEL_LZO=y/# CONFIG_KERNEL_LZO is not set/' "$DEFCONFIG"
echo "CONFIG_KERNEL_LZ4=y" >> "$DEFCONFIG"
log_info "LZ4 kernel compression enabled"

# I/O Schedulers
echo "CONFIG_IOSCHED_FIOPS=y" >> "$DEFCONFIG"
echo "CONFIG_IOSCHED_MAPLE=y" >> "$DEFCONFIG"
echo "CONFIG_IOSCHED_SIO=y" >> "$DEFCONFIG"
echo "CONFIG_IOSCHED_KYBER=y" >> "$DEFCONFIG"
log_info "Performance I/O schedulers enabled"

# Jump Label + Block Layer
echo "CONFIG_JUMP_LABEL=y" >> "$DEFCONFIG"
echo "CONFIG_BLK_WBT=y" >> "$DEFCONFIG"
echo "CONFIG_BLK_WBT_MQ=y" >> "$DEFCONFIG"

# Deduplicate configs (keep last occurrence)
tac "$DEFCONFIG" | awk '!seen[$0]++' | tac > "${DEFCONFIG}.tmp"
mv "${DEFCONFIG}.tmp" "$DEFCONFIG"

log_info "Performance optimizations applied!"

# ===== SETUP KERNELSU =====
if [[ -n "${KERNELSU_SETUP_URL}" && -n "${KERNELSU_SETUP_BRANCH}" ]]; then
    log_step "Setting up KernelSU (${KERNELSU_SETUP_BRANCH})..."
    curl -LSs "${KERNELSU_SETUP_URL}" | bash -s "${KERNELSU_SETUP_BRANCH}"
    if [ -n "${KERNELSU_PATCHES}" ]; then
        cd Kernel*
        echo "${KERNELSU_PATCHES}" | tr ',' '\n' | while read -r PATCH; do
            TRIMMED=$(echo "$PATCH" | xargs)
            TEMP_PATCH_FILE="/tmp/downloaded_patch_$(date +%s%N).patch"
            curl -fsSL "$TRIMMED" -o "$TEMP_PATCH_FILE"
            patch -p1 < "$TEMP_PATCH_FILE"
        done
        cd ..
    fi
    log_info "KernelSU setup complete"
fi

# ===== SETUP SUSFS =====
if [[ "${SUSFS_ENABLED}" == "true" ]]; then
    log_step "Setting up SuSFS (root hiding)..."
    cd "${KERNEL_DIR}"

    # Clone susfs4ksu
    rm -rf susfs4ksu
    git clone --depth=1 "${SUSFS_REPO_URL}" -b "${SUSFS_BRANCH}" susfs4ksu

    # Apply KernelSU enable susfs patch
    if [ -f "susfs4ksu/kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch" ]; then
        cd Kernel*
        patch -p1 < ../susfs4ksu/kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch || true
        cd ..
        log_info "SuSFS KernelSU patch applied"
    fi

    # Apply kernel patches
    if [ -f "susfs4ksu/kernel_patches/50_add_susfs_in_kernel.patch" ]; then
        patch -p1 < susfs4ksu/kernel_patches/50_add_susfs_in_kernel.patch || true
        log_info "SuSFS kernel patch applied"
    fi

    # Add SuSFS config to defconfig
    echo "CONFIG_KSU_SUSFS=y" >> "${DEFCONFIG}"
    echo "CONFIG_KSU_SUSFS_SUS_MOUNT=y" >> "${DEFCONFIG}"
    echo "CONFIG_KSU_SUSFS_TRY_UMOUNT=y" >> "${DEFCONFIG}"
    echo "CONFIG_KSU_SUSFS_SPOOF_UNAME=y" >> "${DEFCONFIG}"
    echo "CONFIG_KSU_SUSFS_ENABLE_LOG=y" >> "${DEFCONFIG}"

    # Clean up
    rm -rf susfs4ksu
    log_info "SuSFS setup complete"
fi

# ===== BUILD KERNEL =====
log_step "Building kernel..."
BUILD_START=$(date +%s)

export ARCH=arm64
export SUBARCH=ARM64
export KBUILD_BUILD_USER="perf-gcp"
export KBUILD_BUILD_HOST="gcp-build"

# Performance compiler flags
export KCFLAGS="-O3 -march=armv8.2-a+crypto+fp16+dotprod -mtune=cortex-a77"

# ThinLTO
if [[ "${ENABLE_THINLTO}" == "true" ]]; then
    export KCFLAGS="${KCFLAGS} -flto=thin"
    log_info "ThinLTO enabled"
fi

# Polly optimizer
if [[ "${ENABLE_POLLY}" == "true" ]]; then
    export KCFLAGS="${KCFLAGS} -mllvm -polly -mllvm -polly-vectorizer=stripmine"
    log_info "Polly optimizer enabled"
fi

# Ccache
if [[ "${USE_CCACHE}" == "true" ]]; then
    export CC="ccache clang"
else
    export CC="clang"
fi

log_info "KCFLAGS: ${KCFLAGS}"
log_info "Starting build with ${NUM_JOBS} jobs..."

# Generate config
make O=out vendor/munch_defconfig

# Build
make O=out \
    CC="${CC}" \
    -j"${NUM_JOBS}" \
    CROSS_COMPILE=aarch64-linux-gnu- \
    LLVM=1 \
    LLVM_IAS=1 \
    2>&1 | tee build.log

BUILD_END=$(date +%s)
BUILD_DURATION=$((BUILD_END - BUILD_START))

# Check build result
if [ ! -f "out/arch/arm64/boot/Image.gz" ]; then
    log_error "Build failed! Image.gz not found."
    exit 1
fi

log_info "Build completed in $((BUILD_DURATION / 60)) min $((BUILD_DURATION % 60)) sec"

# Ccache stats
if [[ "${USE_CCACHE}" == "true" ]]; then
    log_info "Ccache hit rate:"
    ccache -s
fi

# ===== PACKAGE WITH ANYKERNEL3 =====
log_step "Packaging with AnyKernel3..."
cd out/arch/arm64/boot/

if [[ -n "${ANYKERNEL_URL}" && -n "${ANYKERNEL_BRANCH}" ]]; then
    git clone --recursive --depth=1 "${ANYKERNEL_URL}" -b "${ANYKERNEL_BRANCH}" AnyKernel3

    [ -e "Image.gz" ] && cp -f Image.gz AnyKernel3
    [ -e "dtb.img" ] && cp -f dtb.img AnyKernel3/dtb
    [ -e "dtbo.img" ] && cp -f dtbo.img AnyKernel3

    cd AnyKernel3

    # Customize info
    if [ -f "anykernel-info" ]; then
        sed -i "s/kernel.string=.*/kernel.string=N0Kontzzz-Perf (Performance Optimized)/" anykernel-info
    fi

    ZIP_NAME="${ANYKERNEL_ZIP_NAME}-HZ${TIMER_HZ}-${CPU_GOVERNOR}"
    if [[ -n "${KERNELSU_SETUP_URL}" ]]; then
        ZIP_NAME="${ZIP_NAME}-KSU"
    else
        ZIP_NAME="${ZIP_NAME}-NONKSU"
    fi
    if [[ "${SUSFS_ENABLED}" == "true" ]]; then
        ZIP_NAME="${ZIP_NAME}-SUSFS"
    fi

    zip -q -r "${ZIP_NAME}.zip" *
    mv "${ZIP_NAME}.zip" ../
    cd ..

    log_info "Package created: ${ZIP_NAME}.zip"

    # Copy to home dir for easy download
    cp "${ZIP_NAME}.zip" "${HOME}/"
    log_info "ZIP copied to ${HOME}/${ZIP_NAME}.zip"
fi

# ===== BUILD SUMMARY =====
echo ""
echo "=============================================="
echo " BUILD COMPLETE!"
echo "=============================================="
echo " Duration    : $((BUILD_DURATION / 60)) min $((BUILD_DURATION % 60)) sec"
echo " Device      : Poco F4 (munch)"
echo " SoC         : Snapdragon 870 (SM8250-AC)"
echo " Branch      : ${KERNEL_TREE_BRANCH}"
echo " Clang       : ${CLANG_VERSION}"
echo " ThinLTO     : ${ENABLE_THINLTO}"
echo " Polly       : ${ENABLE_POLLY}"
echo " Timer       : ${TIMER_HZ}Hz"
echo " Governor    : ${CPU_GOVERNOR}"
echo " KernelSU    : ${KERNELSU_SETUP_URL:+Enabled}${KERNELSU_SETUP_URL:-Disabled}"
echo " SuSFS       : ${SUSFS_ENABLED}"
echo " Flags       : -O3 -march=armv8.2-a+crypto+fp16+dotprod"
echo "=============================================="
echo ""
echo "Download ZIP from VM:"
echo "  gcloud compute scp ${INSTANCE_NAME:-kernel-build-munch}:~/${ZIP_NAME}.zip . --zone=${ZONE:-asia-southeast1-b}"
