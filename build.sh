#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME=$(basename "$0")

IMAGE_SIZE="${IMAGE_SIZE:-3G}"
SUITE="${SUITE:-trixie}"
ARCH="${ARCH:-arm64}"
# Do not inherit the runner/host HOSTNAME; CI runners commonly expose a random
# hostname which would otherwise be written into the target image.
HOSTNAME="${IMAGE_HOSTNAME:-orangepi}"
MIRROR="${MIRROR:-http://mirrors.ustc.edu.cn/debian}"
OUTPUT="${OUTPUT:-$(pwd)/orangepi-zero2-debian13-trixie-btrfs.img}"
COMPRESS="${COMPRESS:-xz}"
UPDATE_BUNDLE="${UPDATE_BUNDLE:-auto}"
DEBOOTSTRAP_KEYRING="${DEBOOTSTRAP_KEYRING:-/usr/share/keyrings/debian-archive-keyring.gpg}"
WORKDIR="${WORKDIR:-}"
ROOT_PASS="${ROOT_PASS:-orangepi}"

KERNEL_REPO="${KERNEL_REPO:-https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git}"
KERNEL_REF="${KERNEL_REF:-7.1}"
KERNEL_DEFCONFIG="${KERNEL_DEFCONFIG:-defconfig}"
UBOOT_REPO="${UBOOT_REPO:-https://github.com/u-boot/u-boot.git}"
UBOOT_REF="${UBOOT_REF:-v2026.07}"
ATF_REPO="${ATF_REPO:-https://github.com/ARM-software/arm-trusted-firmware.git}"
ATF_REF="${ATF_REF:-lts-v2.12.9}"
JOBS="${JOBS:-$(nproc)}"
BTRFS_ROOT_SUBVOL="${BTRFS_ROOT_SUBVOL:-@}"

ARMBIAN_BUILD_COMMIT="fd4ebfd1e107d5b89f7a672c7d609789565753b2"

LOOP_OUTPUT=""
WORKDIR_CREATED=""
MNT_ROOT=""
MNT_BOOT=""
ASSETS_DIR=""
SRC_DIR=""
KERNEL_SRC_DIR=""
UBOOT_SRC_DIR=""
ATF_SRC_DIR=""
VENDOR_INPUTS_DIR=""
ATF_BL31=""
KERNEL_RELEASE=""
ASSET_KERNEL_NAME="Image"
ASSET_INITRD_NAME=""
UPDATE_BUNDLE_OUTPUT=""

log() {
  echo "[${SCRIPT_NAME}] $*"
}

cleanup() {
  set +e
  if [[ -n "${MNT_BOOT}" ]] && mountpoint -q "${MNT_BOOT}"; then
    umount -lf "${MNT_BOOT}"
  fi
  if [[ -n "${MNT_ROOT}" ]] && mountpoint -q "${MNT_ROOT}/dev/pts"; then
    umount -lf "${MNT_ROOT}/dev/pts"
  fi
  if [[ -n "${MNT_ROOT}" ]] && mountpoint -q "${MNT_ROOT}/dev"; then
    umount -lf "${MNT_ROOT}/dev"
  fi
  if [[ -n "${MNT_ROOT}" ]] && mountpoint -q "${MNT_ROOT}/proc"; then
    umount -lf "${MNT_ROOT}/proc"
  fi
  if [[ -n "${MNT_ROOT}" ]] && mountpoint -q "${MNT_ROOT}/sys"; then
    umount -lf "${MNT_ROOT}/sys"
  fi
  if [[ -n "${MNT_ROOT}" ]] && mountpoint -q "${MNT_ROOT}"; then
    umount -lf "${MNT_ROOT}"
  fi
  if [[ -n "${LOOP_OUTPUT}" ]]; then
    losetup -d "${LOOP_OUTPUT}" || true
  fi
  if [[ -n "${WORKDIR_CREATED}" && -d "${WORKDIR_CREATED}" ]]; then
    rm -rf "${WORKDIR_CREATED}" || true
  fi
}

trap cleanup EXIT ERR

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "请使用 root 权限运行。"
    exit 1
  fi
}

check_deps() {
  local deps=(
    debootstrap qemu-aarch64-static parted losetup mkfs.vfat mkfs.btrfs btrfs mount mountpoint
    rsync tar xz chroot lsblk git make aarch64-linux-gnu-gcc bc bison flex openssl dtc swig python3
    curl sha256sum
  )
  local missing=()

  for d in "${deps[@]}"; do
    if ! command -v "${d}" >/dev/null 2>&1; then
      missing+=("${d}")
    fi
  done

  if [[ "${#missing[@]}" -ne 0 ]]; then
    echo "缺少依赖命令: ${missing[*]}"
    echo "请先安装依赖后重试（可参考 .github/workflows/build-release.yml 的 Install dependencies 步骤）"
    exit 1
  fi

  if [[ ! -f "${DEBOOTSTRAP_KEYRING}" ]]; then
    echo "缺少 Debian archive keyring: ${DEBOOTSTRAP_KEYRING}"
    echo "请安装 debian-archive-keyring 后重试。"
    exit 1
  fi
}

ensure_loop_support() {
  if losetup -f >/dev/null 2>&1; then
    return
  fi

  echo "未找到可用 loop 设备（losetup -f 失败）。"
  echo "请确认当前环境已启用 loop 设备（需要 /dev/loop-control 和可用 /dev/loopN）。"
  echo "若在容器/受限环境中运行，请开启 loop 设备权限或改用支持 loop 的 VM。"
  exit 1
}

parse_args() {
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --image-size)
        IMAGE_SIZE="$2"
        shift 2
        ;;
      --suite)
        SUITE="$2"
        shift 2
        ;;
      --arch)
        ARCH="$2"
        shift 2
        ;;
      --hostname)
        HOSTNAME="$2"
        shift 2
        ;;
      --mirror)
        MIRROR="$2"
        shift 2
        ;;
      --output)
        OUTPUT="$2"
        shift 2
        ;;
      --compress)
        COMPRESS="$2"
        shift 2
        ;;
      --update-bundle)
        UPDATE_BUNDLE="$2"
        shift 2
        ;;
      --debootstrap-keyring)
        DEBOOTSTRAP_KEYRING="$2"
        shift 2
        ;;
      --workdir)
        WORKDIR="$2"
        shift 2
        ;;
      --root-pass)
        ROOT_PASS="$2"
        shift 2
        ;;
      --kernel-repo)
        KERNEL_REPO="$2"
        shift 2
        ;;
      --kernel-ref)
        KERNEL_REF="$2"
        shift 2
        ;;
      --kernel-defconfig)
        KERNEL_DEFCONFIG="$2"
        shift 2
        ;;
      --uboot-repo)
        UBOOT_REPO="$2"
        shift 2
        ;;
      --uboot-ref)
        UBOOT_REF="$2"
        shift 2
        ;;
      --atf-repo)
        ATF_REPO="$2"
        shift 2
        ;;
      --atf-ref)
        ATF_REF="$2"
        shift 2
        ;;
      --jobs)
        JOBS="$2"
        shift 2
        ;;
      *)
        echo "未知参数: $1"
        echo "请查看 README.md 获取用法说明。"
        exit 1
        ;;
    esac
  done
}

validate_args() {
  case "${COMPRESS}" in
    xz|none)
      ;;
    *)
      echo "无效参数: --compress ${COMPRESS} (仅支持 xz|none)"
      exit 1
      ;;
  esac

  case "${UPDATE_BUNDLE}" in
    auto|yes|no)
      ;;
    *)
      echo "无效参数: --update-bundle ${UPDATE_BUNDLE} (仅支持 auto|yes|no)"
      exit 1
      ;;
  esac

  if [[ -z "${DEBOOTSTRAP_KEYRING}" ]]; then
    echo "无效参数: --debootstrap-keyring 不能为空"
    exit 1
  fi

  if [[ "${ARCH}" != "arm64" ]]; then
    echo "当前脚本仅支持 --arch arm64"
    exit 1
  fi

  if ! [[ "${JOBS}" =~ ^[1-9][0-9]*$ ]]; then
    echo "无效参数: --jobs ${JOBS} (必须为正整数)"
    exit 1
  fi

  if [[ -z "${KERNEL_DEFCONFIG}" ]]; then
    echo "无效参数: --kernel-defconfig 不能为空"
    exit 1
  fi
}

resolve_kernel_ref() {
  local ref="${KERNEL_REF}"
  local major=""
  local minor=""

  # 支持 --kernel-ref 7.1.8（自动补 v 前缀）
  if [[ "${ref}" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    KERNEL_REF="v${ref}"
    log "内核版本: ${KERNEL_REF}"
    return
  fi

  # 支持 --kernel-ref 7.1 / v7.1（自动解析最新补丁版）
  if [[ "${ref}" =~ ^v?([0-9]+)\.([0-9]+)$ ]]; then
    major="${BASH_REMATCH[1]}"
    minor="${BASH_REMATCH[2]}"

    local latest_patch=-1
    local patch=""
    local remote_tag=""
    local latest_tag=""

    log "解析内核系列 v${major}.${minor} 的最新补丁版本"
    while read -r _ remote_tag; do
      remote_tag="${remote_tag#refs/tags/}"
      if [[ "${remote_tag}" =~ ^v${major}\.${minor}\.([0-9]+)$ ]]; then
        patch="${BASH_REMATCH[1]}"
        if (( 10#${patch} > latest_patch )); then
          latest_patch=$((10#${patch}))
          latest_tag="${remote_tag}"
        fi
      fi
    done < <(git ls-remote --tags --refs "${KERNEL_REPO}" "v${major}.${minor}.*")

    if [[ -z "${latest_tag}" ]]; then
      echo "无法在 ${KERNEL_REPO} 中找到 v${major}.${minor}.x 标签。"
      echo "请检查 --kernel-repo 是否为 stable 树，或直接指定 --kernel-ref v${major}.${minor}.Z"
      exit 1
    fi

    KERNEL_REF="${latest_tag}"
    log "内核版本: ${KERNEL_REF}（自动解析）"
    return
  fi

  # 其他引用（分支/标签/commit）保持原样
  KERNEL_REF="${ref}"
  log "内核版本: ${KERNEL_REF}"
}

init_workdir() {
  if [[ -n "${WORKDIR}" ]]; then
    WORKDIR_CREATED="${WORKDIR}"
    mkdir -p "${WORKDIR_CREATED}"
  else
    WORKDIR_CREATED=$(mktemp -d /tmp/opi-build-XXXX)
  fi

  ASSETS_DIR="${WORKDIR_CREATED}/assets"
  SRC_DIR="${WORKDIR_CREATED}/src"
  KERNEL_SRC_DIR="${SRC_DIR}/linux"
  UBOOT_SRC_DIR="${SRC_DIR}/u-boot"
  ATF_SRC_DIR="${SRC_DIR}/arm-trusted-firmware"
  VENDOR_INPUTS_DIR="${SRC_DIR}/vendor-inputs"
  MNT_ROOT="${WORKDIR_CREATED}/rootfs"
  MNT_BOOT="${WORKDIR_CREATED}/rootfs/boot"

  mkdir -p "${ASSETS_DIR}/dtb" "${SRC_DIR}" "${VENDOR_INPUTS_DIR}" "${MNT_ROOT}"
  log "工作目录: ${WORKDIR_CREATED}"
}

fetch_verified_file() {
  local url="$1"
  local expected_sha256="$2"
  local destination="$3"
  local actual_sha256

  curl -fL --retry 3 --retry-delay 2 "${url}" -o "${destination}"
  actual_sha256=$(sha256sum "${destination}")
  actual_sha256="${actual_sha256%% *}"
  if [[ "${actual_sha256}" != "${expected_sha256}" ]]; then
    echo "下载文件校验失败: ${url}"
    echo "期望 SHA256: ${expected_sha256}"
    echo "实际 SHA256: ${actual_sha256}"
    exit 1
  fi
}

fetch_armbian_inputs() {
  local patch_base="https://raw.githubusercontent.com/armbian/build/${ARMBIAN_BUILD_COMMIT}/patch/kernel/archive/sunxi-7.1/patches.armbian"

  log "获取并校验 Armbian 7.1 板级补丁"
  fetch_verified_file "${patch_base}/arm64-dts-sun50i-h616-orangepi-zero2-enable-usb1-vbus.patch" \
    "6ed73c3d69c43e3c7d8fe9f4601f8a5418a0dfd17ad376bc72edb6428ed95eb9" \
    "${VENDOR_INPUTS_DIR}/01-enable-usb1-vbus.patch"
  fetch_verified_file "${patch_base}/drv-nvmem-sunxi-add-h616-support.patch" \
    "a2ae77146f78c43cc5727b2cdf428ab9703789abd11e2383e5f55ea290958ad4" \
    "${VENDOR_INPUTS_DIR}/06-add-h616-sid-support.patch"
}

clone_repo() {
  local repo="$1"
  local ref="$2"
  local dst="$3"
  rm -rf "${dst}"
  if ! git clone --depth 1 --branch "${ref}" "${repo}" "${dst}" >/dev/null 2>&1; then
    echo "无法检出源码版本: ${repo} @ ${ref}"
    echo "请通过 --kernel-ref / --uboot-ref / --atf-ref 指定存在的分支或标签。"
    exit 1
  fi
  log "源码版本: ${repo} @ ${ref}"
}

fetch_sources() {
  log "获取源码"
  resolve_kernel_ref
  clone_repo "${ATF_REPO}" "${ATF_REF}" "${ATF_SRC_DIR}"
  clone_repo "${UBOOT_REPO}" "${UBOOT_REF}" "${UBOOT_SRC_DIR}"
  clone_repo "${KERNEL_REPO}" "${KERNEL_REF}" "${KERNEL_SRC_DIR}"
  fetch_armbian_inputs
}

build_atf() {
  log "编译 ARM Trusted Firmware"
  make -C "${ATF_SRC_DIR}" -j"${JOBS}" CROSS_COMPILE=aarch64-linux-gnu- PLAT=sun50i_h616 DEBUG=0 bl31
  ATF_BL31="${ATF_SRC_DIR}/build/sun50i_h616/release/bl31.bin"
  if [[ ! -f "${ATF_BL31}" ]]; then
    echo "编译 ATF 失败: ${ATF_BL31} 不存在"
    exit 1
  fi
}

build_uboot() {
  log "编译 U-Boot"
  make -C "${UBOOT_SRC_DIR}" distclean >/dev/null 2>&1 || true
  make -C "${UBOOT_SRC_DIR}" CROSS_COMPILE=aarch64-linux-gnu- orangepi_zero2_defconfig
  "${UBOOT_SRC_DIR}/scripts/config" --file "${UBOOT_SRC_DIR}/.config" \
    --disable TOOLS_MKEFICAPSULE \
    --set-val BOOTDELAY 0
  make -C "${UBOOT_SRC_DIR}" CROSS_COMPILE=aarch64-linux-gnu- olddefconfig
  make -C "${UBOOT_SRC_DIR}" -j"${JOBS}" CROSS_COMPILE=aarch64-linux-gnu- BL31="${ATF_BL31}"

  local uboot_bin="${UBOOT_SRC_DIR}/u-boot-sunxi-with-spl.bin"
  if [[ ! -f "${uboot_bin}" ]]; then
    echo "编译 U-Boot 失败: ${uboot_bin} 不存在"
    exit 1
  fi
  cp "${uboot_bin}" "${ASSETS_DIR}/uboot.bin"
}

apply_green_heartbeat_led_scheme() {
  local led_file="${KERNEL_SRC_DIR}/arch/arm64/boot/dts/allwinner/sun50i-h616-orangepi-zero.dtsi"

  if [[ ! -f "${led_file}" ]]; then
    echo "缺少 Orange Pi Zero 2/3 LED 设备树: ${led_file}"
    exit 1
  fi

  # Linux running state: PC12 red off, PC13 green heartbeat.
  perl -0pi -e 's{(gpios = <&pio 2 12 GPIO_ACTIVE_HIGH>; /\* PC12 \*/\n\s*)default-state = "on";}{${1}default-state = "off";}s' "${led_file}"
  perl -0pi -e 's{(gpios = <&pio 2 13 GPIO_ACTIVE_HIGH>; /\* PC13 \*/\n)}{${1}\t\t\tlinux,default-trigger = "heartbeat";\n}s' "${led_file}"

  if ! grep -A1 -F 'gpios = <&pio 2 12 GPIO_ACTIVE_HIGH>; /* PC12 */' "${led_file}" | grep -Fq 'default-state = "off"'; then
    echo "LED 方案修补失败: 红灯 PC12 未设置为 off"
    exit 1
  fi
  if ! grep -A1 -F 'gpios = <&pio 2 13 GPIO_ACTIVE_HIGH>; /* PC13 */' "${led_file}" | grep -Fq 'linux,default-trigger = "heartbeat"'; then
    echo "LED 方案修补失败: 绿灯 PC13 未设置为 heartbeat"
    exit 1
  fi
}

apply_kernel_patches() {
  local patch_file

  log "应用 Orange Pi Zero 2 7.1 板级补丁"
  for patch_file in \
    01-enable-usb1-vbus.patch \
    06-add-h616-sid-support.patch; do
    git -C "${KERNEL_SRC_DIR}" apply --check --whitespace=nowarn "${VENDOR_INPUTS_DIR}/${patch_file}"
    git -C "${KERNEL_SRC_DIR}" apply --whitespace=nowarn "${VENDOR_INPUTS_DIR}/${patch_file}"
  done
  apply_green_heartbeat_led_scheme
}

assert_kernel_config() {
  local expected
  local symbol
  local missing=()
  local enabled=()

  for expected in \
    CONFIG_ARCH_SUNXI=y \
    CONFIG_RD_ZSTD=y \
    CONFIG_BTRFS_FS=y \
    CONFIG_ZSMALLOC=m \
    CONFIG_ZRAM=m \
    CONFIG_SCSI=y \
    CONFIG_BLK_DEV_SD=y \
    CONFIG_USB_EHCI_HCD=y \
    CONFIG_USB_OHCI_HCD=y \
    CONFIG_USB_STORAGE=y \
    CONFIG_USB_MUSB_SUNXI=y \
    CONFIG_PHY_SUN4I_USB=y \
    CONFIG_EXTCON=y \
    CONFIG_MMC=y \
    CONFIG_MMC_SUNXI=y \
    CONFIG_STMMAC_ETH=y \
    CONFIG_STMMAC_PLATFORM=y \
    CONFIG_DWMAC_SUN8I=y \
    CONFIG_NVMEM_SUNXI_SID=y \
    CONFIG_MFD_AXP20X_RSB=y \
    CONFIG_REGULATOR_FIXED_VOLTAGE=y \
    CONFIG_REGULATOR_AXP20X=y \
    CONFIG_CPUFREQ_DT=y \
    CONFIG_ARM_ALLWINNER_SUN50I_CPUFREQ_NVMEM=m \
    CONFIG_SUN8I_THERMAL=y \
    CONFIG_SERIAL_8250_DW=y \
    CONFIG_RTC_DRV_SUN6I=y \
    CONFIG_LEDS_GPIO=y \
    CONFIG_LEDS_TRIGGER_HEARTBEAT=y \
    CONFIG_DMA_SUN6I=m \
    CONFIG_SUNXI_WATCHDOG=m \
    '# CONFIG_LOCALVERSION_AUTO is not set' \
    '# CONFIG_WLAN is not set' \
    '# CONFIG_BT is not set' \
    '# CONFIG_RFKILL is not set' \
    '# CONFIG_CFG80211 is not set' \
    '# CONFIG_MAC80211 is not set'; do
    if ! grep -qx "${expected}" "${KERNEL_SRC_DIR}/.config"; then
      missing+=("${expected}")
    fi
  done

  if [[ "${#missing[@]}" -ne 0 ]]; then
    echo "内核配置校验失败:"
    printf '  %s\n' "${missing[@]}"
    exit 1
  fi

  for symbol in \
    ACPI PCI KVM XEN COMPAT EFI NUMA HIBERNATION KEXEC KEXEC_FILE CRASH_DUMP \
    MEMORY_HOTPLUG MEMORY_HOTREMOVE \
    ARCH_ACTIONS ARCH_AIROHA ARCH_ALPINE ARCH_APPLE ARCH_ARTPEC ARCH_AXIADO \
    ARCH_BCM ARCH_BERLIN ARCH_BLAIZE ARCH_BST ARCH_CIX ARCH_EXYNOS \
    ARCH_SPARX5 ARCH_K3 ARCH_LG1K ARCH_HISI ARCH_KEEMBAY ARCH_MEDIATEK \
    ARCH_MESON ARCH_MICROCHIP ARCH_MVEBU ARCH_NXP ARCH_MA35 ARCH_NPCM \
    ARCH_QCOM ARCH_REALTEK ARCH_RENESAS ARCH_ROCKCHIP ARCH_SEATTLE \
    ARCH_INTEL_SOCFPGA ARCH_SOPHGO ARCH_STM32 ARCH_SYNQUACER ARCH_TEGRA \
    ARCH_TESLA_FSD ARCH_SPRD ARCH_THUNDER ARCH_THUNDER2 ARCH_UNIPHIER \
    ARCH_VEXPRESS ARCH_VISCONTI ARCH_XGENE ARCH_ZYNQMP \
    WLAN BT RFKILL NETFILTER CAN NFC WWAN ATA RC_CORE MEDIA_SUPPORT DRM \
    SOUND STAGING I2C SPI MTD RD_GZIP RD_BZIP2 RD_LZMA RD_XZ RD_LZO RD_LZ4 \
    NET_9P VIRTIO_BLK VIRTIO_NET VIRTIO_CONSOLE HW_RANDOM_VIRTIO VIRTIO_MMIO \
    BLK_DEV_NBD MD BLK_DEV_DM GNSS IPMI_HANDLER TCG_TPM SPMI \
    CFG80211 MAC80211 CFG80211_WEXT WEXT_CORE WEXT_PROC WEXT_SPY WEXT_PRIV \
    BRIDGE NET_DSA VLAN_8021Q NET_SCHED NET_CLS_ACT HSR QRTR MACVLAN MACVTAP \
    TUN VETH USB_NET_DRIVERS USB_SERIAL TYPEC UCSI USB_CDNS3 \
    SCSI_UFSHCD POWER_SEQUENCING CHROME_PLATFORMS CROS_EC RPMSG SLIMBUS GREYBUS \
    CORESIGHT FPGA IIO PERF_EVENTS COUNTER MUX_CORE STM STM_PROTO_BASIC \
    STM_PROTO_SYS_T PWM HWMON \
    REGULATOR_PWM LEDS_PWM COMMON_CLK_PWM LEDS_TRIGGER_DEFAULT_ON \
    BACKLIGHT_CLASS_DEVICE FUSE_FS OVERLAY_FS PSTORE \
    MHI_BUS MHI_NET GPIO_AGGREGATOR GPIO_WCD934X GPIO_ALTERA GPIO_XILINX \
    LEDS_CLASS_FLASH LEDS_CLASS_MULTICOLOR LEDS_CROS_EC \
    COMMON_CLK_XLNX_CLKWZRD XILINX_VCU \
    BCM_SBA_RAID XILINX_DMA XILINX_ZYNQMP_DMA XILINX_ZYNQMP_DPDMA \
    REGULATOR_VCTRL REGMAP_SLIMBUS UACCE XILINX_SDFEC MFD_WCD934X RAID_ATTRS \
    USB_ONBOARD_DEV USB_ACM KEYBOARD_ADC KEYBOARD_GPIO_POLLED \
    INPUT_PWM_BEEPER INPUT_PWM_VIBRA INPUT_FF_MEMLESS INPUT_SPARSEKMAP \
    RTC_DRV_MT6397 RTC_DRV_ZYNQMP NVMEM_REBOOT_MODE GENERIC_ADC_THERMAL \
    XILINX_WATCHDOG XILINX_WINDOW_WATCHDOG CPU_FREQ_GOV_POWERSAVE \
    CPU_FREQ_GOV_CONSERVATIVE GOOGLE_FIRMWARE DEVFREQ_GOV_PASSIVE \
    NVMEM_LAYOUT_SL28_VPD NVMEM_RMEM \
    PHY_CADENCE_TORRENT PHY_CADENCE_DPHY PHY_CADENCE_DPHY_RX \
    PHY_CADENCE_SIERRA PHY_CADENCE_SALVO PHY_QCOM_USB_HS \
    PHY_CAN_TRANSCEIVER PHY_SUN6I_MIPI_DPHY \
    AX88796B_PHY AQUANTIA_PHY BCM54140_PHY BCM7XXX_PHY BROADCOM_PHY \
    DP83867_PHY DP83869_PHY DP83TG720_PHY DP83TD510_PHY MARVELL_PHY \
    MARVELL_10G_PHY MARVELL_88Q2XXX_PHY MICREL_PHY MICROSEMI_PHY \
    AT803X_PHY QCA808X_PHY ROCKCHIP_PHY SMSC_PHY VITESSE_PHY \
    XILINX_GMII2RGMII NET_VENDOR_BROADCOM NET_VENDOR_QUALCOMM NET_VENDOR_XILINX \
    DWMAC_SUNXI DWMAC_SUN55I DWMAC_GENERIC INPUT_TOUCHSCREEN INPUT_MISC \
    KEYBOARD_GPIO HID_MULTITOUCH; do
    if grep -Eq "^CONFIG_${symbol}=(y|m)$" "${KERNEL_SRC_DIR}/.config"; then
      enabled+=("CONFIG_${symbol}")
    fi
  done

  if [[ "${#enabled[@]}" -ne 0 ]]; then
    echo "发现未关闭的无用内核子系统:"
    printf '  %s\n' "${enabled[@]}"
    exit 1
  fi
}

build_kernel() {
  log "编译 Linux 内核"
  make -C "${KERNEL_SRC_DIR}" mrproper
  apply_kernel_patches
  # 内核补丁会让源码树变为 dirty；写入空 .scmversion 避免版本名追加 -dirty
  : > "${KERNEL_SRC_DIR}/.scmversion"
  make -C "${KERNEL_SRC_DIR}" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- "${KERNEL_DEFCONFIG}"
  log "使用内核配置: ${KERNEL_DEFCONFIG}"

  log "配置 H616 Zero 2 专用内核功能"
  "${KERNEL_SRC_DIR}/scripts/config" --file "${KERNEL_SRC_DIR}/.config" \
      --enable BLK_DEV_INITRD \
      --disable RD_GZIP \
      --disable RD_BZIP2 \
      --disable RD_LZMA \
      --disable RD_XZ \
      --disable RD_LZO \
      --disable RD_LZ4 \
      --enable RD_ZSTD \
      --enable BTRFS_FS \
      --enable BTRFS_FS_POSIX_ACL \
      --module ZSMALLOC \
      --module ZRAM \
      --enable USB \
      --enable USB_SUPPORT \
      --enable USB_EHCI_HCD \
      --enable USB_OHCI_HCD \
      --enable USB_STORAGE \
      --enable USB_MUSB_HDRC \
      --enable USB_MUSB_SUNXI \
      --enable PHY_SUN4I_USB \
      --enable EXTCON \
      --disable USB_XHCI_HCD \
      --disable ACPI \
      --disable PCI \
      --disable KVM \
      --disable XEN \
      --disable COMPAT \
      --disable EFI \
      --disable NUMA \
      --disable HIBERNATION \
      --disable KEXEC \
      --disable KEXEC_FILE \
      --disable CRASH_DUMP \
      --disable MEMORY_HOTPLUG \
      --disable MEMORY_HOTREMOVE \
      --disable ARCH_ACTIONS \
      --disable ARCH_AIROHA \
      --disable ARCH_ALPINE \
      --disable ARCH_APPLE \
      --disable ARCH_ARTPEC \
      --disable ARCH_AXIADO \
      --disable ARCH_BCM \
      --disable ARCH_BERLIN \
      --disable ARCH_BLAIZE \
      --disable ARCH_BST \
      --disable ARCH_CIX \
      --disable ARCH_EXYNOS \
      --disable ARCH_SPARX5 \
      --disable ARCH_K3 \
      --disable ARCH_LG1K \
      --disable ARCH_HISI \
      --disable ARCH_KEEMBAY \
      --disable ARCH_MEDIATEK \
      --disable ARCH_MESON \
      --disable ARCH_MICROCHIP \
      --disable ARCH_MVEBU \
      --disable ARCH_NXP \
      --disable ARCH_MA35 \
      --disable ARCH_NPCM \
      --disable ARCH_QCOM \
      --disable ARCH_REALTEK \
      --disable ARCH_RENESAS \
      --disable ARCH_ROCKCHIP \
      --disable ARCH_SEATTLE \
      --disable ARCH_INTEL_SOCFPGA \
      --disable ARCH_SOPHGO \
      --disable ARCH_STM32 \
      --disable ARCH_SYNQUACER \
      --disable ARCH_TEGRA \
      --disable ARCH_TESLA_FSD \
      --disable ARCH_SPRD \
      --disable ARCH_THUNDER \
      --disable ARCH_THUNDER2 \
      --disable ARCH_UNIPHIER \
      --disable ARCH_VEXPRESS \
      --disable ARCH_VISCONTI \
      --disable ARCH_XGENE \
      --disable ARCH_ZYNQMP \
      --disable WLAN \
      --disable BT \
      --disable RFKILL \
      --disable CFG80211 \
      --disable MAC80211 \
      --disable CFG80211_WEXT \
      --disable WEXT_CORE \
      --disable WEXT_PROC \
      --disable WEXT_SPY \
      --disable WEXT_PRIV \
      --disable NETFILTER \
      --disable BRIDGE \
      --disable NET_DSA \
      --disable VLAN_8021Q \
      --disable NET_SCHED \
      --disable NET_CLS_ACT \
      --disable HSR \
      --disable QRTR \
      --disable MACVLAN \
      --disable MACVTAP \
      --disable TUN \
      --disable VETH \
      --disable USB_NET_DRIVERS \
      --disable USB_SERIAL \
      --disable TYPEC \
      --disable UCSI \
      --disable USB_CDNS3 \
      --disable CAN \
      --disable NFC \
      --disable WWAN \
      --disable ATA \
      --disable RC_CORE \
      --disable MEDIA_SUPPORT \
      --disable DRM \
      --disable SOUND \
      --disable STAGING \
      --disable I2C \
      --disable SPI \
      --disable MTD \
      --disable NET_9P \
      --disable VIRTIO_BLK \
      --disable VIRTIO_NET \
      --disable VIRTIO_CONSOLE \
      --disable HW_RANDOM_VIRTIO \
      --disable VIRTIO_MMIO \
      --disable BLK_DEV_NBD \
      --disable MD \
      --disable BLK_DEV_DM \
      --disable GNSS \
      --disable IPMI_HANDLER \
      --disable TCG_TPM \
      --disable SPMI \
      --disable SCSI_UFSHCD \
      --disable POWER_SEQUENCING \
      --disable CHROME_PLATFORMS \
      --disable CROS_EC \
      --disable RPMSG \
      --disable SLIMBUS \
      --disable GREYBUS \
      --disable CORESIGHT \
      --disable FPGA \
      --disable IIO \
      --disable PERF_EVENTS \
      --disable COUNTER \
      --disable MUX_CORE \
      --disable STM \
      --disable STM_PROTO_BASIC \
      --disable STM_PROTO_SYS_T \
      --disable PWM \
      --disable HWMON \
      --disable REGULATOR_PWM \
      --disable LEDS_PWM \
      --disable COMMON_CLK_PWM \
      --disable MHI_BUS \
      --disable MHI_NET \
      --disable GPIO_AGGREGATOR \
      --disable GPIO_WCD934X \
      --disable GPIO_ALTERA \
      --disable GPIO_XILINX \
      --disable LEDS_CLASS_FLASH \
      --disable LEDS_CLASS_MULTICOLOR \
      --disable LEDS_CROS_EC \
      --disable LEDS_TRIGGER_DEFAULT_ON \
      --disable COMMON_CLK_XLNX_CLKWZRD \
      --disable XILINX_VCU \
      --disable BCM_SBA_RAID \
      --disable XILINX_DMA \
      --disable XILINX_ZYNQMP_DMA \
      --disable XILINX_ZYNQMP_DPDMA \
      --disable REGULATOR_VCTRL \
      --disable REGMAP_SLIMBUS \
      --disable UACCE \
      --disable XILINX_SDFEC \
      --disable MFD_WCD934X \
      --disable RAID_ATTRS \
      --disable USB_ONBOARD_DEV \
      --disable USB_ACM \
      --disable KEYBOARD_ADC \
      --disable KEYBOARD_GPIO_POLLED \
      --disable INPUT_PWM_BEEPER \
      --disable INPUT_PWM_VIBRA \
      --disable INPUT_FF_MEMLESS \
      --disable INPUT_SPARSEKMAP \
      --disable RTC_DRV_MT6397 \
      --disable RTC_DRV_ZYNQMP \
      --disable NVMEM_REBOOT_MODE \
      --disable GENERIC_ADC_THERMAL \
      --disable XILINX_WATCHDOG \
      --disable XILINX_WINDOW_WATCHDOG \
      --disable CPU_FREQ_GOV_POWERSAVE \
      --disable CPU_FREQ_GOV_CONSERVATIVE \
      --disable GOOGLE_FIRMWARE \
      --disable DEVFREQ_GOV_PASSIVE \
      --disable NVMEM_LAYOUT_SL28_VPD \
      --disable NVMEM_RMEM \
      --disable BACKLIGHT_CLASS_DEVICE \
      --disable FUSE_FS \
      --disable OVERLAY_FS \
      --disable PSTORE \
      --disable PHY_CADENCE_TORRENT \
      --disable PHY_CADENCE_DPHY \
      --disable PHY_CADENCE_DPHY_RX \
      --disable PHY_CADENCE_SIERRA \
      --disable PHY_CADENCE_SALVO \
      --disable PHY_QCOM_USB_HS \
      --disable PHY_CAN_TRANSCEIVER \
      --disable PHY_SUN6I_MIPI_DPHY \
      --disable AX88796B_PHY \
      --disable AQUANTIA_PHY \
      --disable BCM54140_PHY \
      --disable BCM7XXX_PHY \
      --disable BROADCOM_PHY \
      --disable DP83867_PHY \
      --disable DP83869_PHY \
      --disable DP83TG720_PHY \
      --disable DP83TD510_PHY \
      --disable MARVELL_PHY \
      --disable MARVELL_10G_PHY \
      --disable MARVELL_88Q2XXX_PHY \
      --disable MICREL_PHY \
      --disable MICROSEMI_PHY \
      --disable AT803X_PHY \
      --disable QCA808X_PHY \
      --disable ROCKCHIP_PHY \
      --disable SMSC_PHY \
      --disable VITESSE_PHY \
      --disable XILINX_GMII2RGMII \
      --disable NET_VENDOR_BROADCOM \
      --disable NET_VENDOR_QUALCOMM \
      --disable NET_VENDOR_XILINX \
      --disable DWMAC_SUNXI \
      --disable DWMAC_SUN55I \
      --disable DWMAC_GENERIC \
      --disable INPUT_TOUCHSCREEN \
      --disable INPUT_MISC \
      --disable KEYBOARD_GPIO \
      --disable HID_MULTITOUCH \
      --enable REALTEK_PHY \
      --enable NVMEM \
      --enable NVMEM_SUNXI_SID \
      --enable MFD_AXP20X_RSB \
      --enable REGULATOR_FIXED_VOLTAGE \
      --enable REGULATOR_AXP20X \
      --enable CPU_FREQ \
      --enable CPUFREQ_DT \
      --module ARM_ALLWINNER_SUN50I_CPUFREQ_NVMEM \
      --enable THERMAL \
      --enable CPU_THERMAL \
      --enable THERMAL_GOV_STEP_WISE \
      --enable SUN8I_THERMAL \
      --enable MMC \
      --enable MMC_SUNXI \
      --enable STMMAC_ETH \
      --enable STMMAC_PLATFORM \
      --enable DWMAC_SUN8I \
      --enable SERIAL_8250_DW \
      --enable RTC_DRV_SUN6I \
      --enable LEDS_GPIO \
      --enable LEDS_TRIGGER_HEARTBEAT \
      --module DMA_SUN6I \
      --module SUNXI_WATCHDOG \
      --set-str LOCALVERSION "" \
      --disable LOCALVERSION_AUTO

  make -C "${KERNEL_SRC_DIR}" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig
  assert_kernel_config

  make -C "${KERNEL_SRC_DIR}" -j"${JOBS}" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- LOCALVERSION= Image modules dtbs

  KERNEL_RELEASE=$(make -s -C "${KERNEL_SRC_DIR}" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- LOCALVERSION= kernelrelease)
  if [[ -z "${KERNEL_RELEASE}" ]]; then
    echo "无法确定内核版本 (kernelrelease)"
    exit 1
  fi

  cp "${KERNEL_SRC_DIR}/arch/arm64/boot/Image" "${ASSETS_DIR}/${ASSET_KERNEL_NAME}"

  local dtb_file="${KERNEL_SRC_DIR}/arch/arm64/boot/dts/allwinner/sun50i-h616-orangepi-zero2.dtb"
  if [[ ! -f "${dtb_file}" ]]; then
    echo "未找到 DTB: sun50i-h616-orangepi-zero2.dtb"
    exit 1
  fi

  cp "${dtb_file}" "${ASSETS_DIR}/dtb/"
  cp "${KERNEL_SRC_DIR}/System.map" "${ASSETS_DIR}/System.map-${KERNEL_RELEASE}"
  cp "${KERNEL_SRC_DIR}/.config" "${ASSETS_DIR}/config-${KERNEL_RELEASE}"
}

create_blank_image() {
  log "创建镜像: ${OUTPUT}"
  truncate -s "${IMAGE_SIZE}" "${OUTPUT}"
  parted -s "${OUTPUT}" mklabel msdos
  parted -s "${OUTPUT}" mkpart primary fat32 1MiB 129MiB
  parted -s "${OUTPUT}" set 1 boot on
  parted -s "${OUTPUT}" mkpart primary btrfs 129MiB 100%
  log "分区信息:"
  parted -s "${OUTPUT}" unit MiB print || true
}

setup_loop_for_output_image() {
  LOOP_OUTPUT=$(losetup -Pf --show "${OUTPUT}")
  log "输出 loop: ${LOOP_OUTPUT}"
  lsblk "${LOOP_OUTPUT}" || true
}

format_partitions() {
  mkfs.vfat -F32 -n BOOT "${LOOP_OUTPUT}p1"
  mkfs.btrfs -f -L ROOT "${LOOP_OUTPUT}p2"
}

mount_partitions() {
  mount -o compress=zstd "${LOOP_OUTPUT}p2" "${MNT_ROOT}"
  btrfs subvolume create "${MNT_ROOT}/${BTRFS_ROOT_SUBVOL}" >/dev/null
  umount "${MNT_ROOT}"
  mount -o "compress=zstd,subvol=${BTRFS_ROOT_SUBVOL}" "${LOOP_OUTPUT}p2" "${MNT_ROOT}"
  mkdir -p "${MNT_BOOT}"
  mount "${LOOP_OUTPUT}p1" "${MNT_BOOT}"
}

prepare_dns() {
  local target="${MNT_ROOT}/etc/resolv.conf"

  if [[ -f /run/systemd/resolve/resolv.conf ]]; then
    cp /run/systemd/resolve/resolv.conf "${target}"
    return
  fi

  if [[ -f /etc/resolv.conf ]]; then
    awk '
      $1 == "nameserver" && $2 !~ /^(127\.|::1$|0:0:0:0:0:0:0:1$)/ { print }
    ' /etc/resolv.conf > "${target}"
    if [[ -s "${target}" ]]; then
      return
    fi
  fi

  cat <<'EOF2' > "${target}"
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF2
}

build_debian_rootfs() {
  log "debootstrap 构建 rootfs"
  debootstrap --keyring="${DEBOOTSTRAP_KEYRING}" --arch="${ARCH}" "${SUITE}" "${MNT_ROOT}" "${MIRROR}"
  mkdir -p "${MNT_ROOT}/usr/share/keyrings"
  cp "${DEBOOTSTRAP_KEYRING}" "${MNT_ROOT}/usr/share/keyrings/debian-archive-keyring.gpg"
  cp "$(command -v qemu-aarch64-static)" "${MNT_ROOT}/usr/bin/"
  mount --bind /dev "${MNT_ROOT}/dev"
  mkdir -p "${MNT_ROOT}/dev/pts"
  mount --bind /dev/pts "${MNT_ROOT}/dev/pts"
  mount --bind /proc "${MNT_ROOT}/proc"
  mount --bind /sys "${MNT_ROOT}/sys"
  prepare_dns
}

write_resize_script() {
  cat <<'SCRIPT' > "${MNT_ROOT}/usr/local/sbin/opi-firstboot-resize.sh"
#!/usr/bin/env bash
set -euo pipefail

DONE_FILE="/var/lib/opi-firstboot-resize.done"
LOG_PREFIX="[opi-firstboot-resize]"

log() {
  echo "${LOG_PREFIX} $*"
  logger -t opi-firstboot-resize "$*"
}

bytes_to_mib() {
  echo "$(( $1 / 1024 / 1024 ))"
}

read_partition_size() {
  blockdev --getsize64 /dev/mmcblk0p2 2>/dev/null || echo 0
}

partition_resize_state() {
  local disk_size sector_size start_sectors part_size max_size margin

  disk_size=$(blockdev --getsize64 /dev/mmcblk0 2>/dev/null || echo 0)
  sector_size=$(cat /sys/class/block/mmcblk0/queue/logical_block_size 2>/dev/null || echo 512)
  start_sectors=$(cat /sys/class/block/mmcblk0p2/start 2>/dev/null || echo 0)
  part_size=$(read_partition_size)

  if (( disk_size <= 0 || sector_size <= 0 || start_sectors <= 0 || part_size <= 0 )); then
    echo "unknown"
    return
  fi

  max_size=$((disk_size - start_sectors * sector_size))
  margin=$((4 * 1024 * 1024))

  if (( part_size + margin < max_size )); then
    echo "can-grow"
  else
    echo "full"
  fi
}

run_partition_resize() {
  if command -v growpart >/dev/null 2>&1; then
    log "使用 growpart 扩展分区"
    if growpart /dev/mmcblk0 2; then
      return 0
    fi
    log "growpart 失败，回退到 sfdisk/parted"
  fi

  if command -v sfdisk >/dev/null 2>&1; then
    log "使用 sfdisk 扩展分区"
    if echo ", +" | sfdisk --no-reread -N 2 /dev/mmcblk0; then
      return 0
    fi
    log "sfdisk 失败，回退到 parted"
  fi

  log "使用 parted 扩展分区"
  parted -s /dev/mmcblk0 resizepart 2 100%
}

if [[ -f "${DONE_FILE}" ]]; then
  log "已完成，退出。"
  exit 0
fi

log "开始扩容 /dev/mmcblk0p2"

old_size=$(read_partition_size)
log "当前分区大小: $(bytes_to_mib "${old_size}") MB"

if run_partition_resize; then
  log "分区扩容命令执行完成"
else
  log "分区扩容命令返回失败，继续检查实际分区大小"
fi

log "刷新分区表"
partprobe /dev/mmcblk0 2>/dev/null || blockdev --rereadpt /dev/mmcblk0 2>/dev/null || true
udevadm settle 2>/dev/null || true

sleep 3

new_size=$(read_partition_size)
log "分区大小: $(bytes_to_mib "${new_size}") MB"

case "$(partition_resize_state)" in
  can-grow)
    log "分区尚未扩展到磁盘末尾，保留服务以便下次重试"
    exit 1
    ;;
  unknown)
    log "无法判断分区是否已扩展到磁盘末尾，保留服务以便下次重试"
    exit 1
    ;;
esac

log "扩容 btrfs 文件系统"
if btrfs filesystem resize max / 2>&1 | tee -a /var/log/opi-resize.log; then
  log "btrfs 扩容成功"
  touch "${DONE_FILE}"
  systemctl disable opi-firstboot-resize.service || true
  log "扩容完成，系统将在 5 秒后重启"
  sleep 5
  systemctl reboot || true
else
  log "btrfs 扩容失败，请手动执行: btrfs filesystem resize max /"
fi

exit 0
SCRIPT
  chmod +x "${MNT_ROOT}/usr/local/sbin/opi-firstboot-resize.sh"

  cat <<'SERVICE' > "${MNT_ROOT}/etc/systemd/system/opi-firstboot-resize.service"
[Unit]
Description=Orange Pi first boot resize
After=local-fs.target
Before=multi-user.target
ConditionPathExists=!/var/lib/opi-firstboot-resize.done

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/opi-firstboot-resize.sh

[Install]
WantedBy=multi-user.target
SERVICE
}

configure_rootfs_in_chroot() {
  log "配置 rootfs"
  cat <<EOF2 > "${MNT_ROOT}/etc/hostname"
${HOSTNAME}
EOF2
  cat <<EOF2 > "${MNT_ROOT}/etc/hosts"
127.0.0.1 localhost
127.0.1.1 ${HOSTNAME}
::1 localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
EOF2

  cat <<EOF2 > "${MNT_ROOT}/etc/apt/sources.list"
deb ${MIRROR} ${SUITE} main
deb ${MIRROR}-security ${SUITE}-security main
deb ${MIRROR} ${SUITE}-updates main
EOF2

  chroot "${MNT_ROOT}" /bin/bash -c "apt-get update"
  chroot "${MNT_ROOT}" /bin/bash -c "DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends debian-archive-keyring openssh-server network-manager ca-certificates systemd-timesyncd btrfs-progs initramfs-tools parted cloud-guest-utils zstd xz-utils locales"
  chroot "${MNT_ROOT}" /bin/bash -c "systemctl enable ssh NetworkManager systemd-timesyncd"
  
  # 确保 NetworkManager 管理所有网络接口
  cat <<'EOF2' > "${MNT_ROOT}/etc/NetworkManager/conf.d/10-globally-managed-devices.conf"
[keyfile]
unmanaged-devices=none
EOF2

  # 配置 end0 自动连接
  cat <<EOF2 > "${MNT_ROOT}/etc/NetworkManager/system-connections/Wired-end0.nmconnection"
[connection]
id=Wired-end0
type=ethernet
interface-name=end0
autoconnect=true
autoconnect-priority=999

[ethernet]

[ipv4]
method=auto
dhcp-send-hostname=true
dhcp-hostname=${HOSTNAME}
dhcp-client-id=mac

[ipv6]
method=auto
dhcp-send-hostname=true
EOF2
  chmod 600 "${MNT_ROOT}/etc/NetworkManager/system-connections/Wired-end0.nmconnection"
  
  # 禁用 systemd-networkd（避免冲突）
  chroot "${MNT_ROOT}" /bin/bash -c "systemctl disable systemd-networkd systemd-networkd.socket" || true
  chroot "${MNT_ROOT}" /bin/bash -c "systemctl mask systemd-networkd systemd-networkd.socket" || true
  
  # 禁用不必要的服务（保留串口和日志）
  log "禁用不必要的服务"
  chroot "${MNT_ROOT}" /bin/bash -c "systemctl mask getty@tty1.service" || true
  chroot "${MNT_ROOT}" /bin/bash -c "systemctl disable apt-daily.timer apt-daily-upgrade.timer" || true
  chroot "${MNT_ROOT}" /bin/bash -c "if systemctl is-enabled man-db.timer >/dev/null 2>&1; then systemctl disable man-db.timer >/dev/null 2>&1 || true; fi" || true
  chroot "${MNT_ROOT}" /bin/bash -c "systemctl disable e2scrub_all.timer" || true
  chroot "${MNT_ROOT}" /bin/bash -c "systemctl disable fstrim.timer" || true
  
  # 彻底禁用 systemd credentials（使用 systemd drop-in）
  log "禁用 systemd credentials"
  mkdir -p "${MNT_ROOT}/etc/systemd/system/systemd-journald.service.d"
  cat <<'EOF2' > "${MNT_ROOT}/etc/systemd/system/systemd-journald.service.d/override.conf"
[Service]
ImportCredential=
LoadCredential=
LoadCredentialEncrypted=
SetCredential=
SetCredentialEncrypted=
EOF2
  
  mkdir -p "${MNT_ROOT}/etc/systemd/system/serial-getty@.service.d"
  cat <<'EOF2' > "${MNT_ROOT}/etc/systemd/system/serial-getty@.service.d/override.conf"
[Service]
ImportCredential=
LoadCredential=
LoadCredentialEncrypted=
SetCredential=
SetCredentialEncrypted=
EOF2
  
  mkdir -p "${MNT_ROOT}/etc/systemd/system/getty@.service.d"
  cat <<'EOF2' > "${MNT_ROOT}/etc/systemd/system/getty@.service.d/override.conf"
[Service]
ImportCredential=
LoadCredential=
LoadCredentialEncrypted=
SetCredential=
SetCredentialEncrypted=
EOF2

  # 配置 initramfs 以支持 btrfs
  mkdir -p "${MNT_ROOT}/etc/initramfs-tools/conf.d"
  cat <<'EOF2' > "${MNT_ROOT}/etc/initramfs-tools/conf.d/btrfs"
# 添加 btrfs 模块到 initramfs
MODULES=most
# 使用 zstd 压缩
COMPRESS=zstd
# 避免 fsck hook 在 chroot 中探测 /dev/mmcblk0p2 触发告警
FSTYPE=btrfs
EOF2

  mkdir -p "${MNT_ROOT}/etc/ssh/sshd_config.d"
  cat <<'EOF2' > "${MNT_ROOT}/etc/ssh/sshd_config.d/99-root-login.conf"
PermitRootLogin yes
PasswordAuthentication yes
EOF2

  echo "root:${ROOT_PASS}" | chroot "${MNT_ROOT}" chpasswd

  # 设置时区为上海
  log "设置时区为 Asia/Shanghai"
  chroot "${MNT_ROOT}" /bin/bash -c "ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime"
  echo "Asia/Shanghai" > "${MNT_ROOT}/etc/timezone"

  # 设置默认语言环境
  log "设置默认语言环境为 en_US.UTF-8"
  echo "en_US.UTF-8 UTF-8" > "${MNT_ROOT}/etc/locale.gen"
  chroot "${MNT_ROOT}" /bin/bash -c "locale-gen en_US.UTF-8"
  cat <<'EOF2' > "${MNT_ROOT}/etc/default/locale"
LANG=en_US.UTF-8
EOF2

  cat <<EOF2 > "${MNT_ROOT}/etc/fstab"
/dev/mmcblk0p2 / btrfs defaults,compress=zstd,subvol=${BTRFS_ROOT_SUBVOL} 0 1
/dev/mmcblk0p1 /boot vfat defaults 0 2
EOF2

  cat <<'EOF2' > "${MNT_ROOT}/root/cleanup-kernel-backups.sh"
#!/usr/bin/env bash
set -euo pipefail

CURRENT_KERNEL=$(uname -r)
REMOVE_BACKUP_ARCHIVES="${1:-yes}"

case "${REMOVE_BACKUP_ARCHIVES}" in
  yes|no)
    ;;
  *)
    echo "用法: $0 [yes|no]"
    echo "默认 yes：同时清理 /root/orangepi-kernel-backup-*.tar.xz"
    echo "传 no：只清理旧内核模块和旧 /boot 版本文件"
    exit 1
    ;;
esac

echo "当前运行内核: ${CURRENT_KERNEL}"

for module_dir in /lib/modules/*; do
  [[ -d "${module_dir}" ]] || continue
  if [[ "$(basename "${module_dir}")" == "${CURRENT_KERNEL}" ]]; then
    continue
  fi

  echo "删除旧模块目录: ${module_dir}"
  rm -rf -- "${module_dir}"
done

for boot_file in /boot/initrd.img-* /boot/config-*; do
  [[ -e "${boot_file}" ]] || continue
  case "${boot_file}" in
    "/boot/initrd.img-${CURRENT_KERNEL}"|"/boot/config-${CURRENT_KERNEL}")
      continue
      ;;
  esac

  echo "删除旧启动文件: ${boot_file}"
  rm -f -- "${boot_file}"
done

if [[ "${REMOVE_BACKUP_ARCHIVES}" == "yes" ]]; then
  for backup in /root/orangepi-kernel-backup-*.tar.xz; do
    [[ -e "${backup}" ]] || continue
    echo "删除旧备份包: ${backup}"
    rm -f -- "${backup}"
  done
fi

depmod -a "${CURRENT_KERNEL}" 2>/dev/null || true
echo "清理完成"
EOF2
  chmod +x "${MNT_ROOT}/root/cleanup-kernel-backups.sh"

  write_resize_script
  chroot "${MNT_ROOT}" /bin/bash -c "systemctl enable opi-firstboot-resize.service"
  
  # 配置 zram（压缩内存交换）
  log "配置 zram"
  chroot "${MNT_ROOT}" /bin/bash -c "DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends zram-tools"
  
  # 配置 zram 参数
  cat <<'EOF2' > "${MNT_ROOT}/etc/default/zramswap"
# zram 配置
# 使用总内存百分比
PERCENT=40
# 压缩算法（lz4 速度快，zstd 压缩率高）
ALGO=lz4
# 优先级
PRIORITY=100
EOF2
  
  chroot "${MNT_ROOT}" /bin/bash -c "systemctl enable zramswap.service"
  
  log "清理系统以减小镜像大小"
  chroot "${MNT_ROOT}" /bin/bash -c "apt-get clean"
  chroot "${MNT_ROOT}" /bin/bash -c "rm -rf /var/lib/apt/lists/*"
  chroot "${MNT_ROOT}" /bin/bash -c "rm -rf /tmp/* /var/tmp/*"
  chroot "${MNT_ROOT}" /bin/bash -c "rm -rf /usr/share/doc/* /usr/share/man/* /usr/share/info/*"
  chroot "${MNT_ROOT}" /bin/bash -c "rm -rf /usr/share/locale/* /usr/share/i18n/locales/*"
  chroot "${MNT_ROOT}" /bin/bash -c "find /var/log -type f -exec truncate -s 0 {} \;"
  chroot "${MNT_ROOT}" /bin/bash -c "rm -rf /usr/share/pixmaps/* /usr/share/icons/*"
  chroot "${MNT_ROOT}" /bin/bash -c "rm -rf /usr/share/sounds/*"
}

install_compiled_kernel() {
  log "安装自编译内核模块"
  make -C "${KERNEL_SRC_DIR}" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
    INSTALL_MOD_PATH="${MNT_ROOT}" DEPMOD=/bin/true modules_install

  cp "${ASSETS_DIR}/${ASSET_KERNEL_NAME}" "${MNT_BOOT}/${ASSET_KERNEL_NAME}"
  mkdir -p "${MNT_BOOT}/dtb"
  rsync -a "${ASSETS_DIR}/dtb/" "${MNT_BOOT}/dtb/"
  cp "${ASSETS_DIR}/config-${KERNEL_RELEASE}" "${MNT_BOOT}/config-${KERNEL_RELEASE}"

  # 不复制 vmlinuz/System.map 到 /boot（节省空间）
  # 保留 config，板子上后续 update-initramfs 需要它检查 initrd 压缩支持。
  # cp "${ASSETS_DIR}/${ASSET_KERNEL_NAME}" "${MNT_ROOT}/boot/vmlinuz-${KERNEL_RELEASE}"
  # cp "${ASSETS_DIR}/System.map-${KERNEL_RELEASE}" "${MNT_ROOT}/boot/System.map-${KERNEL_RELEASE}"

  chroot "${MNT_ROOT}" /bin/bash -c "depmod -a '${KERNEL_RELEASE}'"
  chroot "${MNT_ROOT}" /bin/bash -c "update-initramfs -c -k '${KERNEL_RELEASE}'"

  ASSET_INITRD_NAME="initrd.img-${KERNEL_RELEASE}"
  if [[ ! -f "${MNT_BOOT}/${ASSET_INITRD_NAME}" ]]; then
    echo "未生成 initrd: /boot/${ASSET_INITRD_NAME}"
    exit 1
  fi
  
  # 配置已经在编译前关闭不需要的子系统，这里只重建模块依赖。
  log "重建模块依赖"
  if [[ -d "${MNT_ROOT}/lib/modules/${KERNEL_RELEASE}" ]]; then
    # 重新生成模块依赖
    chroot "${MNT_ROOT}" /bin/bash -c "depmod -a '${KERNEL_RELEASE}'"
  fi

  rm -f "${MNT_ROOT}/usr/bin/qemu-aarch64-static"
  
  # 清理 boot 分区不必要的文件
  log "清理 boot 分区"
  rm -f "${MNT_ROOT}/boot/vmlinuz-${KERNEL_RELEASE}" 2>/dev/null || true
  rm -f "${MNT_ROOT}/boot/System.map-${KERNEL_RELEASE}" 2>/dev/null || true
}

install_boot_assets() {
  log "写入 extlinux 配置"
  local dtb_rel
  dtb_rel="dtb/sun50i-h616-orangepi-zero2.dtb"
  if [[ ! -f "${MNT_BOOT}/${dtb_rel}" ]]; then
    echo "启动分区未找到 DTB: sun50i-h616-orangepi-zero2.dtb"
    exit 1
  fi

  mkdir -p "${MNT_BOOT}/extlinux"
  cat <<EOF2 > "${MNT_BOOT}/extlinux/extlinux.conf"
LABEL DebianTrixie
  LINUX /${ASSET_KERNEL_NAME}
  INITRD /${ASSET_INITRD_NAME}
  FDT /${dtb_rel}
  APPEND root=/dev/mmcblk0p2 rootfstype=btrfs rootflags=subvol=${BTRFS_ROOT_SUBVOL},compress=zstd rootwait rw console=ttyS0,115200 console=tty1
EOF2
}

create_update_bundle() {
  if [[ "${UPDATE_BUNDLE}" == "no" ]]; then
    return
  fi

  log "打包已安装系统内核更新包"

  local bundle_name="orangepi-zero2-kernel-${KERNEL_RELEASE}-update"
  local bundle_dir="${WORKDIR_CREATED}/${bundle_name}"
  local payload_dir="${bundle_dir}/payload"
  local output_dir
  output_dir=$(dirname "${OUTPUT}")
  UPDATE_BUNDLE_OUTPUT="${output_dir}/${bundle_name}.tar.xz"

  rm -rf "${bundle_dir}" "${UPDATE_BUNDLE_OUTPUT}"
  mkdir -p "${payload_dir}/boot/dtb" "${payload_dir}/lib/modules"

  cp "${MNT_BOOT}/${ASSET_KERNEL_NAME}" "${payload_dir}/boot/${ASSET_KERNEL_NAME}"
  cp "${MNT_BOOT}/${ASSET_INITRD_NAME}" "${payload_dir}/boot/${ASSET_INITRD_NAME}"
  cp "${MNT_BOOT}/config-${KERNEL_RELEASE}" "${payload_dir}/boot/config-${KERNEL_RELEASE}"
  cp "${MNT_BOOT}/dtb/sun50i-h616-orangepi-zero2.dtb" "${payload_dir}/boot/dtb/"
  cp -a "${MNT_ROOT}/lib/modules/${KERNEL_RELEASE}" "${payload_dir}/lib/modules/"

  cat <<EOF2 > "${bundle_dir}/manifest.txt"
Orange Pi Zero 2 kernel update bundle

Kernel release: ${KERNEL_RELEASE}
Kernel image:   /boot/${ASSET_KERNEL_NAME}
Initrd image:   /boot/${ASSET_INITRD_NAME}
Device tree:    /boot/dtb/sun50i-h616-orangepi-zero2.dtb
Modules:        /lib/modules/${KERNEL_RELEASE}

This build intentionally excludes WiFi, Bluetooth, GPU, sound and media
drivers. The update bundle only replaces the kernel, DTB, initrd and modules.

Install:
  sudo ./install.sh
  sudo reboot
EOF2

  {
    cat <<EOF2
#!/usr/bin/env bash
set -euo pipefail

KERNEL_RELEASE="${KERNEL_RELEASE}"
KERNEL_IMAGE="${ASSET_KERNEL_NAME}"
INITRD_IMAGE="${ASSET_INITRD_NAME}"
DTB_IMAGE="sun50i-h616-orangepi-zero2.dtb"
EOF2
    cat <<'SCRIPT'

SCRIPT_NAME=$(basename "$0")
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PAYLOAD_DIR="${SCRIPT_DIR}/payload"
BACKUP_ID=$(date +%Y%m%d-%H%M%S)
BACKUP_PARENT="/tmp/orangepi-kernel-backup"
BACKUP_DIR="${BACKUP_PARENT}/${BACKUP_ID}"
BACKUP_ARCHIVE="/root/orangepi-kernel-backup-${BACKUP_ID}.tar.xz"

log() {
  echo "[${SCRIPT_NAME}] $*"
}

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "请使用 root 权限运行: sudo ./install.sh"
    exit 1
  fi
}

ensure_payload() {
  local missing=()
  local paths=(
    "${PAYLOAD_DIR}/boot/${KERNEL_IMAGE}"
    "${PAYLOAD_DIR}/boot/${INITRD_IMAGE}"
    "${PAYLOAD_DIR}/boot/config-${KERNEL_RELEASE}"
    "${PAYLOAD_DIR}/boot/dtb/${DTB_IMAGE}"
    "${PAYLOAD_DIR}/lib/modules/${KERNEL_RELEASE}"
  )

  for path in "${paths[@]}"; do
    if [[ ! -e "${path}" ]]; then
      missing+=("${path}")
    fi
  done

  if [[ "${#missing[@]}" -ne 0 ]]; then
    echo "更新包不完整，缺少:"
    printf '  %s\n' "${missing[@]}"
    exit 1
  fi
}

ensure_boot_mounted() {
  if mountpoint -q /boot; then
    return
  fi

  log "/boot 未挂载，尝试挂载"
  mount /boot
}

backup_file() {
  local src="$1"
  local dst="${BACKUP_DIR}${src}"

  if [[ ! -e "${src}" ]]; then
    return
  fi

  mkdir -p "$(dirname "${dst}")"
  cp -a "${src}" "${dst}"
}

backup_current_boot() {
  log "备份当前启动文件到临时目录 ${BACKUP_DIR}"
  mkdir -p "${BACKUP_DIR}"

  backup_file /boot/Image
  backup_file "/boot/${INITRD_IMAGE}"
  backup_file "/boot/config-${KERNEL_RELEASE}"
  backup_file "/boot/dtb/${DTB_IMAGE}"
  backup_file /boot/extlinux/extlinux.conf
}

archive_file() {
  local src="$1"
  local dst="${BACKUP_DIR}${src}"

  if [[ ! -e "${src}" ]]; then
    return
  fi

  mkdir -p "$(dirname "${dst}")"
  mv "${src}" "${dst}"
}

archive_old_boot_versions() {
  local path

  for path in /boot/initrd.img-* /boot/config-*; do
    [[ -e "${path}" ]] || continue
    case "${path}" in
      "/boot/${INITRD_IMAGE}"|"/boot/config-${KERNEL_RELEASE}")
        continue
        ;;
    esac

    log "移动旧启动文件到备份: ${path}"
    archive_file "${path}"
  done
}

install_modules() {
  local src="${PAYLOAD_DIR}/lib/modules/${KERNEL_RELEASE}"
  local dst="/lib/modules/${KERNEL_RELEASE}"

  mkdir -p /lib/modules

  if [[ -e "${dst}" ]]; then
    log "备份同版本模块目录"
    mkdir -p "${BACKUP_DIR}/lib/modules"
    cp -a "${dst}" "${BACKUP_DIR}/lib/modules/${KERNEL_RELEASE}"
    rm -rf "${dst}"
  fi

  log "安装内核模块 ${KERNEL_RELEASE}"
  cp -a "${src}" /lib/modules/

  if command -v depmod >/dev/null 2>&1; then
    depmod -a "${KERNEL_RELEASE}"
  fi
}

install_boot_files() {
  log "安装启动文件"
  mkdir -p /boot/dtb

  install -m 0644 "${PAYLOAD_DIR}/boot/${KERNEL_IMAGE}" "/boot/${KERNEL_IMAGE}"
  install -m 0644 "${PAYLOAD_DIR}/boot/${INITRD_IMAGE}" "/boot/${INITRD_IMAGE}"
  install -m 0644 "${PAYLOAD_DIR}/boot/config-${KERNEL_RELEASE}" "/boot/config-${KERNEL_RELEASE}"
  install -m 0644 "${PAYLOAD_DIR}/boot/dtb/${DTB_IMAGE}" "/boot/dtb/${DTB_IMAGE}"
}

update_extlinux() {
  local conf="/boot/extlinux/extlinux.conf"
  local tmp="${conf}.tmp"
  local target_label=""

  mkdir -p /boot/extlinux
  if [[ ! -f "${conf}" ]]; then
    log "未找到 extlinux.conf，创建默认配置"
    cat > "${conf}" <<EOF2
LABEL DebianTrixie
  LINUX /${KERNEL_IMAGE}
  INITRD /${INITRD_IMAGE}
  FDT /dtb/${DTB_IMAGE}
  APPEND root=/dev/mmcblk0p2 rootfstype=btrfs rootflags=subvol=@,compress=zstd rootwait rw console=ttyS0,115200 console=tty1
EOF2
    return
  fi

  if grep -Eq "^LABEL[[:space:]]+DebianTrixie[[:space:]]*$" "${conf}"; then
    target_label="DebianTrixie"
  fi

  awk -v target_label="${target_label}" -v kernel="/${KERNEL_IMAGE}" -v initrd="/${INITRD_IMAGE}" -v dtb="/dtb/${DTB_IMAGE}" '
    function flush_target() {
      if (!in_target) {
        return
      }
      if (!saw_initrd) {
        print "  INITRD " initrd
      }
      if (!saw_fdt) {
        print "  FDT " dtb
      }
      in_target = 0
    }
    $1 == "LABEL" {
      flush_target()
      if (!updated && ((target_label != "" && $2 == target_label) || (target_label == "" && !seen_label))) {
        in_target = 1
        updated = 1
        saw_initrd = 0
        saw_fdt = 0
      }
      seen_label = 1
      print
      next
    }
    in_target && /^[[:space:]]*LINUX[[:space:]]/ {
      print "  LINUX " kernel
      next
    }
    in_target && /^[[:space:]]*INITRD[[:space:]]/ {
      print "  INITRD " initrd
      saw_initrd = 1
      next
    }
    in_target && /^[[:space:]]*FDT[[:space:]]/ {
      print "  FDT " dtb
      saw_fdt = 1
      next
    }
    in_target && /^[[:space:]]*APPEND[[:space:]]/ {
      if (!saw_initrd) {
        print "  INITRD " initrd
        saw_initrd = 1
      }
      if (!saw_fdt) {
        print "  FDT " dtb
        saw_fdt = 1
      }
      print
      next
    }
    { print }
    END {
      flush_target()
    }
  ' "${conf}" > "${tmp}"
  cat "${tmp}" > "${conf}"
  rm -f "${tmp}"
}

install_cleanup_script() {
  log "安装备份清理脚本"
  cat > /root/cleanup-kernel-backups.sh <<'EOF2'
#!/usr/bin/env bash
set -euo pipefail

CURRENT_KERNEL=$(uname -r)
REMOVE_BACKUP_ARCHIVES="${1:-yes}"

case "${REMOVE_BACKUP_ARCHIVES}" in
  yes|no)
    ;;
  *)
    echo "用法: $0 [yes|no]"
    echo "默认 yes：同时清理 /root/orangepi-kernel-backup-*.tar.xz"
    echo "传 no：只清理旧内核模块和旧 /boot 版本文件"
    exit 1
    ;;
esac

echo "当前运行内核: ${CURRENT_KERNEL}"

for module_dir in /lib/modules/*; do
  [[ -d "${module_dir}" ]] || continue
  if [[ "$(basename "${module_dir}")" == "${CURRENT_KERNEL}" ]]; then
    continue
  fi

  echo "删除旧模块目录: ${module_dir}"
  rm -rf -- "${module_dir}"
done

for boot_file in /boot/initrd.img-* /boot/config-*; do
  [[ -e "${boot_file}" ]] || continue
  case "${boot_file}" in
    "/boot/initrd.img-${CURRENT_KERNEL}"|"/boot/config-${CURRENT_KERNEL}")
      continue
      ;;
  esac

  echo "删除旧启动文件: ${boot_file}"
  rm -f -- "${boot_file}"
done

if [[ "${REMOVE_BACKUP_ARCHIVES}" == "yes" ]]; then
  for backup in /root/orangepi-kernel-backup-*.tar.xz; do
    [[ -e "${backup}" ]] || continue
    echo "删除旧备份包: ${backup}"
    rm -f -- "${backup}"
  done
fi

depmod -a "${CURRENT_KERNEL}" 2>/dev/null || true
echo "清理完成"
EOF2
  chmod +x /root/cleanup-kernel-backups.sh
}

pack_backup_archive() {
  if [[ ! -d "${BACKUP_DIR}" ]]; then
    return
  fi

  if [[ -z "$(find "${BACKUP_DIR}" -mindepth 1 -print -quit)" ]]; then
    rm -rf "${BACKUP_DIR}"
    return
  fi

  log "打包旧版本备份到 ${BACKUP_ARCHIVE}"
  tar -C "${BACKUP_PARENT}" -cJf "${BACKUP_ARCHIVE}" "${BACKUP_ID}"
  rm -rf "${BACKUP_DIR}"
  rmdir "${BACKUP_PARENT}" 2>/dev/null || true
}

main() {
  require_root
  ensure_payload
  ensure_boot_mounted
  backup_current_boot
  install_modules
  install_boot_files
  update_extlinux
  archive_old_boot_versions
  pack_backup_archive
  install_cleanup_script
  sync

  log "更新完成: ${KERNEL_RELEASE}"
  if [[ -f "${BACKUP_ARCHIVE}" ]]; then
    log "旧版本备份: ${BACKUP_ARCHIVE}"
  fi
  log "请重启系统: reboot"
}

main "$@"
SCRIPT
  } > "${bundle_dir}/install.sh"
  chmod +x "${bundle_dir}/install.sh"

  tar -C "${WORKDIR_CREATED}" -cJf "${UPDATE_BUNDLE_OUTPUT}" "${bundle_name}"
  log "内核更新包: ${UPDATE_BUNDLE_OUTPUT}"
}

install_uboot_to_output_image() {
  log "写入 U-Boot"
  dd if="${ASSETS_DIR}/uboot.bin" of="${LOOP_OUTPUT}" bs=1k seek=8 conv=fsync,notrunc
}

finalize_image() {
  sync
  log "检查生成结果"
  if [[ ! -f "${MNT_ROOT}/boot/${ASSET_KERNEL_NAME}" ]]; then
    echo "校验失败: /boot/${ASSET_KERNEL_NAME} 不存在"
    exit 1
  fi
  if [[ -z "${ASSET_INITRD_NAME}" || ! -f "${MNT_ROOT}/boot/${ASSET_INITRD_NAME}" ]]; then
    echo "校验失败: /boot/${ASSET_INITRD_NAME} 不存在"
    exit 1
  fi
  if [[ ! -f "${MNT_ROOT}/boot/extlinux/extlinux.conf" ]]; then
    echo "校验失败: extlinux.conf 不存在"
    exit 1
  fi
  if [[ ! -f "${MNT_ROOT}/etc/os-release" ]]; then
    echo "校验失败: /etc/os-release 不存在"
    exit 1
  fi
  log "校验通过"

  log "优化镜像压缩率（填充空白空间）"
  dd if=/dev/zero of="${MNT_ROOT}/zero.fill" bs=1M 2>/dev/null || true
  sync
  rm -f "${MNT_ROOT}/zero.fill"

  log "卸载并释放资源"
  umount -lf "${MNT_BOOT}"
  umount -lf "${MNT_ROOT}/dev/pts" || true
  umount -lf "${MNT_ROOT}/dev" || true
  umount -lf "${MNT_ROOT}/proc" || true
  umount -lf "${MNT_ROOT}/sys" || true
  umount -lf "${MNT_ROOT}"
  losetup -d "${LOOP_OUTPUT}"
  LOOP_OUTPUT=""
}

compress_output() {
  if [[ "${COMPRESS}" == "xz" ]]; then
    log "压缩镜像（使用极限压缩）"
    xz -T0 -z -9 --extreme "${OUTPUT}"
  fi
}

print_flash_hint() {
  local out_file="${OUTPUT}"
  if [[ "${COMPRESS}" == "xz" ]]; then
    out_file="${OUTPUT}.xz"
  fi

  echo "镜像生成完成: ${out_file}"
  if [[ -n "${UPDATE_BUNDLE_OUTPUT}" ]]; then
    echo "内核更新包生成完成: ${UPDATE_BUNDLE_OUTPUT}"
  fi
}

main() {
  parse_args "$@"
  validate_args
  require_root
  check_deps
  ensure_loop_support
  init_workdir
  fetch_sources
  build_atf
  build_uboot
  build_kernel
  create_blank_image
  setup_loop_for_output_image
  format_partitions
  mount_partitions
  build_debian_rootfs
  configure_rootfs_in_chroot
  install_compiled_kernel
  install_boot_assets
  create_update_bundle
  install_uboot_to_output_image
  finalize_image
  compress_output
  print_flash_hint
}

main "$@"
