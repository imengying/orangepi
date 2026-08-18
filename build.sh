#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME=$(basename "$0")

IMAGE_SIZE="${IMAGE_SIZE:-3G}"
SUITE="${SUITE:-trixie}"
ARCH="${ARCH:-arm64}"
HOSTNAME="${HOSTNAME:-orangepi}"
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
UWE5622_REPO="${UWE5622_REPO:-https://github.com/armbian/uwe5622.git}"
UWE5622_REF="${UWE5622_REF:-d6bec7538a0b4b67e35715ad71eaa056555524cb}"
JOBS="${JOBS:-$(nproc)}"
BTRFS_ROOT_SUBVOL="${BTRFS_ROOT_SUBVOL:-@}"

ARMBIAN_BUILD_COMMIT="fd4ebfd1e107d5b89f7a672c7d609789565753b2"
ARMBIAN_FIRMWARE_COMMIT="f50a2a21bcdb77a562b3976930c5c6b521a1df08"

LOOP_OUTPUT=""
WORKDIR_CREATED=""
MNT_ROOT=""
MNT_BOOT=""
ASSETS_DIR=""
SRC_DIR=""
KERNEL_SRC_DIR=""
UBOOT_SRC_DIR=""
ATF_SRC_DIR=""
UWE5622_SRC_DIR=""
VENDOR_INPUTS_DIR=""
FIRMWARE_ASSETS_DIR=""
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
  UWE5622_SRC_DIR="${SRC_DIR}/uwe5622"
  VENDOR_INPUTS_DIR="${SRC_DIR}/vendor-inputs"
  FIRMWARE_ASSETS_DIR="${ASSETS_DIR}/firmware/uwe5622"
  MNT_ROOT="${WORKDIR_CREATED}/rootfs"
  MNT_BOOT="${WORKDIR_CREATED}/rootfs/boot"

  mkdir -p "${ASSETS_DIR}/dtb" "${SRC_DIR}" "${VENDOR_INPUTS_DIR}" \
    "${FIRMWARE_ASSETS_DIR}" "${MNT_ROOT}"
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
  local firmware_base="https://raw.githubusercontent.com/armbian/firmware/${ARMBIAN_FIRMWARE_COMMIT}/uwe5622"

  log "获取并校验 Armbian 7.1 板级补丁"
  fetch_verified_file "${patch_base}/arm64-dts-sun50i-h616-orangepi-zero2-enable-usb1-vbus.patch" \
    "6ed73c3d69c43e3c7d8fe9f4601f8a5418a0dfd17ad376bc72edb6428ed95eb9" \
    "${VENDOR_INPUTS_DIR}/01-enable-usb1-vbus.patch"
  fetch_verified_file "${patch_base}/arm64-dts-sun50i-h616-orangepi-zero2-fix-led-functions.patch" \
    "a40156ed2247b7a0ebc4410f6c749884da789e675121467fba1a044447a33bc5" \
    "${VENDOR_INPUTS_DIR}/02-fix-led-functions.patch"
  fetch_verified_file "${patch_base}/arm64-dts-sun50i-h616-orangepi-zero2-zero3-add-wifi.patch" \
    "cb868019ea15201922df7fd9869059a4f04f5aaf8d3fd61d267fe7939d0b6355" \
    "${VENDOR_INPUTS_DIR}/03-add-wifi.patch"
  fetch_verified_file "${patch_base}/arm64-dts-sun50i-h6-h616-add-sunxi-info-nodes.patch" \
    "5abc775c41de738382a6214d77ccb274d730f1611a43a3a99b033aff9f181422" \
    "${VENDOR_INPUTS_DIR}/04-add-sunxi-info-nodes.patch"
  fetch_verified_file "${patch_base}/drv-nvmem-sunxi-add-chipid-serial-helpers.patch" \
    "e7ad23a9b5331d0f132a152f49db008c6cb95da30c33990b13ee54b2c1e88c5b" \
    "${VENDOR_INPUTS_DIR}/05-add-sunxi-chipid-helpers.patch"
  fetch_verified_file "${patch_base}/drv-nvmem-sunxi-add-h616-support.patch" \
    "a2ae77146f78c43cc5727b2cdf428ab9703789abd11e2383e5f55ea290958ad4" \
    "${VENDOR_INPUTS_DIR}/06-add-h616-sid-support.patch"
  fetch_verified_file "${patch_base}/drv-misc-sunxi-add-addr-mgt-driver-uwe5622.patch" \
    "ee2cf5a3cb252600d4cef4d6554a08606765c334476622315b82ca4d13671d50" \
    "${VENDOR_INPUTS_DIR}/07-add-sunxi-addr-driver.patch"

  log "获取并校验 UWE5622 固件"
  fetch_verified_file "${firmware_base}/wcnmodem.bin" \
    "119b87ce30875734a67462f7293fb8fe85acf3270fe8b78c978ae24be7715a80" \
    "${FIRMWARE_ASSETS_DIR}/wcnmodem.bin"
  fetch_verified_file "${firmware_base}/wcnmodem-38222.bin" \
    "8a49a087bc26a95f89f3df9d9f5780ab3463fbdfc6b71d3892e7bae8f2999260" \
    "${FIRMWARE_ASSETS_DIR}/wcnmodem-38222.bin"
  fetch_verified_file "${firmware_base}/wifi_2355b001_1ant.ini" \
    "1f3c40ec245a8d0b99ad1c23706597d6dd5008ab80cefb7bcc1956efc4e938f7" \
    "${FIRMWARE_ASSETS_DIR}/wifi_2355b001_1ant.ini"
}

clone_repo() {
  local repo="$1"
  local ref="$2"
  local dst="$3"
  local -a candidates=("${ref}")
  local cand
  local major=""
  local minor=""

  if [[ "${ref}" =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    major="${BASH_REMATCH[1]}"
    minor="${BASH_REMATCH[2]}"
    candidates+=("v${major}.${minor}.0" "v${major}.${minor}")
  elif [[ "${ref}" =~ ^v([0-9]+)\.([0-9]+)$ ]]; then
    major="${BASH_REMATCH[1]}"
    minor="${BASH_REMATCH[2]}"
    candidates+=("v${major}.${minor}.0")
  fi

  for cand in "${candidates[@]}"; do
    rm -rf "${dst}"
    if git clone --depth 1 --branch "${cand}" "${repo}" "${dst}" >/dev/null 2>&1; then
      log "源码版本: ${repo} @ ${cand}"
      return
    fi

    rm -rf "${dst}"
    if git clone --depth 1 "${repo}" "${dst}" >/dev/null 2>&1; then
      if git -C "${dst}" fetch --depth 1 origin "${cand}" >/dev/null 2>&1 && \
         git -C "${dst}" checkout --detach FETCH_HEAD >/dev/null 2>&1; then
        log "源码版本: ${repo} @ ${cand}"
        return
      fi
    fi
  done

  echo "无法检出源码版本: ${repo} @ ${ref}"
  echo "请通过 --kernel-ref / --uboot-ref / --atf-ref 指定存在的分支或标签。"
  exit 1
}

fetch_sources() {
  log "获取源码"
  resolve_kernel_ref
  clone_repo "${ATF_REPO}" "${ATF_REF}" "${ATF_SRC_DIR}"
  clone_repo "${UBOOT_REPO}" "${UBOOT_REF}" "${UBOOT_SRC_DIR}"
  clone_repo "${KERNEL_REPO}" "${KERNEL_REF}" "${KERNEL_SRC_DIR}"
  clone_repo "${UWE5622_REPO}" "${UWE5622_REF}" "${UWE5622_SRC_DIR}"
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
  if [[ -x "${UBOOT_SRC_DIR}/scripts/config" ]]; then
    "${UBOOT_SRC_DIR}/scripts/config" --file "${UBOOT_SRC_DIR}/.config" \
      --disable TOOLS_MKEFICAPSULE \
      --set-val BOOTDELAY 0 || true
  else
    if grep -q '^CONFIG_BOOTDELAY=' "${UBOOT_SRC_DIR}/.config"; then
      sed -i 's/^CONFIG_BOOTDELAY=.*/CONFIG_BOOTDELAY=0/' "${UBOOT_SRC_DIR}/.config"
    else
      echo "CONFIG_BOOTDELAY=0" >> "${UBOOT_SRC_DIR}/.config"
    fi
  fi
  make -C "${UBOOT_SRC_DIR}" CROSS_COMPILE=aarch64-linux-gnu- olddefconfig
  make -C "${UBOOT_SRC_DIR}" -j"${JOBS}" CROSS_COMPILE=aarch64-linux-gnu- BL31="${ATF_BL31}"

  local uboot_bin="${UBOOT_SRC_DIR}/u-boot-sunxi-with-spl.bin"
  if [[ ! -f "${uboot_bin}" ]]; then
    echo "编译 U-Boot 失败: ${uboot_bin} 不存在"
    exit 1
  fi
  cp "${uboot_bin}" "${ASSETS_DIR}/uboot.bin"
}

patch_vendor_warning_sources() {
  local addr_dir="${KERNEL_SRC_DIR}/drivers/misc/sunxi-addr"
  local sid_file="${KERNEL_SRC_DIR}/drivers/nvmem/sunxi_sid.c"
  local cmdevt_file="${KERNEL_SRC_DIR}/drivers/net/wireless/uwe5622/unisocwifi/cmdevt.c"

  # These exported helpers come from the vendor patches and need declarations
  # before their definitions for the kernel's missing-prototypes warning.
  if ! grep -Fq 'int hmac_sha256(const uint8_t *plaintext, ssize_t psize, uint8_t *output);' \
    "${addr_dir}/sha256.c"; then
    sed -i '/^int hmac_sha256(/i int hmac_sha256(const uint8_t *plaintext, ssize_t psize, uint8_t *output);' \
      "${addr_dir}/sha256.c"
  fi
  if ! grep -Fq 'int get_custom_mac_address(int fmt, char *name, char *addr);' \
    "${addr_dir}/sunxi-addr.c"; then
    sed -i '/^int get_custom_mac_address(/i int get_custom_mac_address(int fmt, char *name, char *addr);' \
      "${addr_dir}/sunxi-addr.c"
  fi
  if ! grep -Fq 'int sunxi_get_soc_chipid(unsigned char *chipid);' "${sid_file}"; then
    sed -i '/^int sunxi_get_soc_chipid(unsigned char \*chipid)$/i int sunxi_get_soc_chipid(unsigned char *chipid);' "${sid_file}"
  fi
  if ! grep -Fq 'int sunxi_get_serial(unsigned char *serial);' "${sid_file}"; then
    sed -i '/^int sunxi_get_soc_chipid(unsigned char \*chipid)$/i int sunxi_get_serial(unsigned char *serial);' "${sid_file}"
  fi

  # The response sizes are compile-time constants; fixed arrays avoid the
  # vendor driver's -Wvla-larger-than warnings without changing its protocol.
  sed -i \
    -e '/u16 r_len = sizeof(\*fw_api);/{n;s/u8 r_buf\[r_len\];/u8 r_buf[sizeof(*fw_api)];/;}' \
    -e '/u16 r_len = sizeof(\*p) + GET_INFO_TLV_RBUF_SIZE;/{n;n;s/u8 r_buf\[r_len\];/u8 r_buf[sizeof(*p) + GET_INFO_TLV_RBUF_SIZE];/;}' \
    -e '/u16 r_len = sizeof(\*packet);/{n;s/u8 r_buf\[r_len\];/u8 r_buf[sizeof(*packet)];/;}' \
    "${cmdevt_file}"

  if grep -Fq 'u8 r_buf[r_len];' "${cmdevt_file}"; then
    echo "UWE5622 cmdevt.c 可变长栈数组修补失败"
    exit 1
  fi
}

apply_kernel_patches() {
  local patch_file
  local wireless_dir="${KERNEL_SRC_DIR}/drivers/net/wireless/uwe5622"

  log "应用 Armbian Zero 2 7.1 板级补丁"
  for patch_file in \
    01-enable-usb1-vbus.patch \
    02-fix-led-functions.patch \
    03-add-wifi.patch \
    04-add-sunxi-info-nodes.patch \
    05-add-sunxi-chipid-helpers.patch \
    06-add-h616-sid-support.patch; do
    git -C "${KERNEL_SRC_DIR}" apply --check --whitespace=nowarn "${VENDOR_INPUTS_DIR}/${patch_file}"
    git -C "${KERNEL_SRC_DIR}" apply --whitespace=nowarn "${VENDOR_INPUTS_DIR}/${patch_file}"
  done

  # The upstream patch only conflicts with the moving parent Makefile hunk.
  git -C "${KERNEL_SRC_DIR}" apply --check --whitespace=nowarn \
    --exclude=drivers/misc/Makefile "${VENDOR_INPUTS_DIR}/07-add-sunxi-addr-driver.patch"
  git -C "${KERNEL_SRC_DIR}" apply --whitespace=nowarn \
    --exclude=drivers/misc/Makefile "${VENDOR_INPUTS_DIR}/07-add-sunxi-addr-driver.patch"
  if ! grep -Fq 'obj-$(CONFIG_SUNXI_ADDR_MGT) += sunxi-addr/' "${KERNEL_SRC_DIR}/drivers/misc/Makefile"; then
    printf '%s\n' 'obj-$(CONFIG_SUNXI_ADDR_MGT) += sunxi-addr/' >> "${KERNEL_SRC_DIR}/drivers/misc/Makefile"
  fi

  if [[ ! -d "${UWE5622_SRC_DIR}/unisocwcn" || ! -d "${UWE5622_SRC_DIR}/unisocwifi" ]]; then
    echo "UWE5622 源码不完整: ${UWE5622_SRC_DIR}"
    exit 1
  fi
  rm -rf "${wireless_dir}"
  mkdir -p "${wireless_dir}"
  cp -a "${UWE5622_SRC_DIR}/tty-sdio" "${UWE5622_SRC_DIR}/unisocwcn" \
    "${UWE5622_SRC_DIR}/unisocwifi" "${UWE5622_SRC_DIR}/Kconfig" \
    "${UWE5622_SRC_DIR}/Makefile" "${wireless_dir}/"

  if ! grep -Fq 'source "drivers/net/wireless/uwe5622/Kconfig"' \
    "${KERNEL_SRC_DIR}/drivers/net/wireless/Kconfig"; then
    sed -i '/source "drivers\/net\/wireless\/ti\/Kconfig"/a source "drivers/net/wireless/uwe5622/Kconfig"' \
      "${KERNEL_SRC_DIR}/drivers/net/wireless/Kconfig"
  fi
  if ! grep -Fq 'obj-$(CONFIG_SPARD_WLAN_SUPPORT) += uwe5622/' \
    "${KERNEL_SRC_DIR}/drivers/net/wireless/Makefile"; then
    printf '%s\n' 'obj-$(CONFIG_SPARD_WLAN_SUPPORT) += uwe5622/' >> \
      "${KERNEL_SRC_DIR}/drivers/net/wireless/Makefile"
  fi

  patch_vendor_warning_sources
}

assert_kernel_config() {
  local expected
  local missing=()

  for expected in \
    CONFIG_WLAN=y \
    CONFIG_CFG80211=m \
    CONFIG_MAC80211=m \
    CONFIG_RFKILL=y \
    CONFIG_NVMEM_SUNXI_SID=y \
    CONFIG_SPARD_WLAN_SUPPORT=y \
    CONFIG_AW_WIFI_DEVICE_UWE5622=y \
    CONFIG_AW_BIND_VERIFY=y \
    CONFIG_WLAN_UWE5622=m \
    CONFIG_SPRDWL_NG=m \
    CONFIG_UNISOC_WIFI_PS=y \
    CONFIG_TTY_OVERY_SDIO=m \
    CONFIG_SUNXI_ADDR_MGT=m; do
    if ! grep -qx "${expected}" "${KERNEL_SRC_DIR}/.config"; then
      missing+=("${expected}")
    fi
  done

  if [[ "${#missing[@]}" -ne 0 ]]; then
    echo "内核无线配置校验失败:"
    printf '  %s\n' "${missing[@]}"
    exit 1
  fi
}

build_kernel() {
  log "编译 Linux 内核"
  make -C "${KERNEL_SRC_DIR}" mrproper
  apply_kernel_patches
  # 内核补丁会让源码树变为 dirty；写入空 .scmversion 避免版本名追加 -dirty
  : > "${KERNEL_SRC_DIR}/.scmversion"
  if make -C "${KERNEL_SRC_DIR}" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- "${KERNEL_DEFCONFIG}" >/dev/null 2>&1; then
    log "使用内核配置: ${KERNEL_DEFCONFIG}"
  else
    log "内核不支持 ${KERNEL_DEFCONFIG}，回退到 defconfig"
    make -C "${KERNEL_SRC_DIR}" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- defconfig
  fi

  if [[ -x "${KERNEL_SRC_DIR}/scripts/config" ]]; then
    log "启用额外的内核功能"
    "${KERNEL_SRC_DIR}/scripts/config" --file "${KERNEL_SRC_DIR}/.config" \
      --enable BLK_DEV_INITRD \
      --enable RD_GZIP \
      --enable RD_BZIP2 \
      --enable RD_LZMA \
      --enable RD_XZ \
      --enable RD_LZO \
      --enable RD_LZ4 \
      --enable RD_ZSTD \
      --enable BTRFS_FS \
      --enable BTRFS_FS_POSIX_ACL \
      --module ZSMALLOC \
      --module ZRAM \
      --enable USB \
      --enable USB_SUPPORT \
      --enable USB_XHCI_HCD \
      --enable USB_EHCI_HCD \
      --enable USB_OHCI_HCD \
      --enable USB_STORAGE \
      --enable USB_MUSB_HDRC \
      --enable USB_MUSB_SUNXI \
      --enable PHY_SUN4I_USB \
      --disable MICROSEMI_PHY \
      --disable USB_XHCI_RCAR \
      --disable USB_XHCI_TEGRA \
      --enable EXTCON \
      --enable EXTCON_USB_GPIO \
      --enable WLAN \
      --module CFG80211 \
      --enable CFG80211_WEXT \
      --module MAC80211 \
      --enable RFKILL \
      --enable NVMEM \
      --enable NVMEM_SUNXI_SID \
      --enable SPARD_WLAN_SUPPORT \
      --module WLAN_UWE5622 \
      --module SPRDWL_NG \
      --enable UNISOC_WIFI_PS \
      --module TTY_OVERY_SDIO \
      --module SUNXI_ADDR_MGT \
      --disable RTL8XXXU \
      --disable RTW88 \
      --disable RTW88_8822B \
      --disable RTW88_8822BS \
      --disable RTW88_8822C \
      --disable RTW88_8822CS \
      --disable RTW89 \
      --disable RTW89_8852A \
      --disable RTW89_8852AE \
      --enable THERMAL \
      --enable CPU_THERMAL \
      --enable THERMAL_GOV_STEP_WISE \
      --enable THERMAL_GOV_USER_SPACE \
      --enable THERMAL_EMULATION \
      --enable SUN8I_THERMAL \
      --module REGULATOR_SY8106A \
      --module I2C_MV64XXX \
      --module SPI_SUN6I \
      --enable MMC \
      --enable MMC_SUNXI \
      --enable STMMAC_ETH \
      --enable DWMAC_SUN8I \
      --enable NETFILTER \
      --enable NETFILTER_ADVANCED \
      --enable NETFILTER_NETLINK \
      --module NETFILTER_NETLINK_LOG \
      --module NETFILTER_NETLINK_QUEUE \
      --module NF_CONNTRACK \
      --module NF_CT_NETLINK \
      --module NF_NAT \
      --enable NF_TABLES \
      --enable NF_TABLES_INET \
      --enable NF_TABLES_NETDEV \
      --enable NF_TABLES_ARP \
      --module NFT_NUMGEN \
      --module NFT_CT \
      --module NFT_LOG \
      --module NFT_LIMIT \
      --module NFT_MASQ \
      --module NFT_REDIR \
      --module NFT_NAT \
      --module NFT_QUEUE \
      --module NFT_QUOTA \
      --module NFT_REJECT \
      --module NFT_COMPAT \
      --module NFT_HASH \
      --module NFT_FIB_INET \
      --module NFT_DUP_IPV4 \
      --module NFT_FIB_IPV4 \
      --module NFT_DUP_IPV6 \
      --module NFT_FIB_IPV6 \
      --module NETFILTER_XTABLES \
      --module IP_NF_IPTABLES \
      --module IP_NF_NAT \
      --module IP_NF_TARGET_MASQUERADE \
      --module IP_NF_TARGET_REDIRECT \
      --module IP_NF_TARGET_REJECT \
      --module IP_NF_RAW \
      --module IP6_NF_IPTABLES \
      --module IP6_NF_NAT \
      --module IP6_NF_TARGET_MASQUERADE \
      --module IP6_NF_TARGET_REJECT \
      --module IP6_NF_RAW \
      --set-str LOCALVERSION "" \
      --disable LOCALVERSION_AUTO
  fi

  make -C "${KERNEL_SRC_DIR}" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig
  assert_kernel_config

  # 再次校验，确保不会带上 -dirty 后缀
  if grep -q '^CONFIG_LOCALVERSION_AUTO=y' "${KERNEL_SRC_DIR}/.config"; then
    log "强制关闭 CONFIG_LOCALVERSION_AUTO（避免 -dirty 后缀）"
    if [[ -x "${KERNEL_SRC_DIR}/scripts/config" ]]; then
      "${KERNEL_SRC_DIR}/scripts/config" --file "${KERNEL_SRC_DIR}/.config" \
        --set-str LOCALVERSION "" \
        --disable LOCALVERSION_AUTO
      make -C "${KERNEL_SRC_DIR}" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig
    fi
  fi

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

install_uwe5622_rootfs() {
  log "安装 UWE5622 WiFi 固件和模块加载配置"
  mkdir -p "${MNT_ROOT}/lib/firmware/uwe5622" "${MNT_ROOT}/etc/modules-load.d"
  cp -a "${FIRMWARE_ASSETS_DIR}/wcnmodem.bin" \
    "${FIRMWARE_ASSETS_DIR}/wcnmodem-38222.bin" \
    "${FIRMWARE_ASSETS_DIR}/wifi_2355b001_1ant.ini" \
    "${MNT_ROOT}/lib/firmware/uwe5622/"
  ln -sfn uwe5622/wcnmodem.bin "${MNT_ROOT}/lib/firmware/wcnmodem.bin"
  ln -sfn uwe5622/wifi_2355b001_1ant.ini "${MNT_ROOT}/lib/firmware/wifi_2355b001_1ant.ini"
  cat <<'EOF2' > "${MNT_ROOT}/etc/modules-load.d/uwe5622-wifi.conf"
sunxi_addr
sprdwl_ng
EOF2
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
deb ${MIRROR} ${SUITE} main contrib non-free non-free-firmware
deb ${MIRROR}-security ${SUITE}-security main contrib non-free non-free-firmware
deb ${MIRROR} ${SUITE}-updates main contrib non-free non-free-firmware
EOF2

  chroot "${MNT_ROOT}" /bin/bash -c "apt-get update"
  chroot "${MNT_ROOT}" /bin/bash -c "DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends debian-archive-keyring openssh-server network-manager wpasupplicant wireless-regdb rfkill ca-certificates systemd-timesyncd btrfs-progs initramfs-tools parted cloud-guest-utils zstd xz-utils locales"
  chroot "${MNT_ROOT}" /bin/bash -c "systemctl enable ssh NetworkManager systemd-timesyncd"
  install_uwe5622_rootfs
  
  # 确保 NetworkManager 管理所有网络接口
  cat <<'EOF2' > "${MNT_ROOT}/etc/NetworkManager/conf.d/10-globally-managed-devices.conf"
[keyfile]
unmanaged-devices=none
EOF2

  # 配置 end0 自动连接
  cat <<'EOF2' > "${MNT_ROOT}/etc/NetworkManager/system-connections/Wired-end0.nmconnection"
[connection]
id=Wired-end0
type=ethernet
interface-name=end0
autoconnect=true
autoconnect-priority=999

[ethernet]

[ipv4]
method=auto

[ipv6]
method=auto
EOF2
  chmod 600 "${MNT_ROOT}/etc/NetworkManager/system-connections/Wired-end0.nmconnection"
  
  # 禁用 systemd-networkd（避免冲突）
  chroot "${MNT_ROOT}" /bin/bash -c "systemctl disable systemd-networkd systemd-networkd.socket" || true
  chroot "${MNT_ROOT}" /bin/bash -c "systemctl mask systemd-networkd systemd-networkd.socket" || true
  
  # 禁用不必要的服务（保留串口和日志）
  log "禁用不必要的服务"
  chroot "${MNT_ROOT}" /bin/bash -c "systemctl mask getty@tty1.service" || true
  chroot "${MNT_ROOT}" /bin/bash -c "systemctl disable apt-daily.timer apt-daily-upgrade.timer" || true
  chroot "${MNT_ROOT}" /bin/bash -c "if systemctl cat man-db.timer >/dev/null 2>&1; then systemctl disable man-db.timer; fi" || true
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

  local required_module
  for required_module in sunxi_addr uwe5622_bsp_sdio sprdwl_ng; do
    if ! find "${MNT_ROOT}/lib/modules/${KERNEL_RELEASE}" -name "${required_module}.ko*" -print -quit | grep -q .; then
      echo "缺少 UWE5622 内核模块: ${required_module}"
      exit 1
    fi
  done

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
  
  # 精简内核模块（在安装后）
  log "精简内核模块"
  if [[ -d "${MNT_ROOT}/lib/modules/${KERNEL_RELEASE}" ]]; then
    chroot "${MNT_ROOT}" /bin/bash -c "find /lib/modules/${KERNEL_RELEASE} -name '*.ko' -path '*/kernel/sound/*' -delete" || true
    chroot "${MNT_ROOT}" /bin/bash -c "find /lib/modules/${KERNEL_RELEASE} -name '*.ko' -path '*/kernel/drivers/gpu/*' -delete" || true
    chroot "${MNT_ROOT}" /bin/bash -c "find /lib/modules/${KERNEL_RELEASE} -name '*.ko' -path '*/kernel/drivers/media/*' -delete" || true
    chroot "${MNT_ROOT}" /bin/bash -c "find /lib/modules/${KERNEL_RELEASE} -name '*.ko' -path '*/kernel/drivers/staging/*' -delete" || true
    
    # 重新生成模块依赖
    chroot "${MNT_ROOT}" /bin/bash -c "depmod -a '${KERNEL_RELEASE}'" || true
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
  mkdir -p "${payload_dir}/boot/dtb" "${payload_dir}/lib/modules" \
    "${payload_dir}/lib/firmware/uwe5622" "${payload_dir}/etc/modules-load.d"

  cp "${MNT_BOOT}/${ASSET_KERNEL_NAME}" "${payload_dir}/boot/${ASSET_KERNEL_NAME}"
  cp "${MNT_BOOT}/${ASSET_INITRD_NAME}" "${payload_dir}/boot/${ASSET_INITRD_NAME}"
  cp "${MNT_BOOT}/config-${KERNEL_RELEASE}" "${payload_dir}/boot/config-${KERNEL_RELEASE}"
  cp "${MNT_BOOT}/dtb/sun50i-h616-orangepi-zero2.dtb" "${payload_dir}/boot/dtb/"
  cp -a "${MNT_ROOT}/lib/modules/${KERNEL_RELEASE}" "${payload_dir}/lib/modules/"
  cp -a "${MNT_ROOT}/lib/firmware/uwe5622/." "${payload_dir}/lib/firmware/uwe5622/"
  cp "${MNT_ROOT}/etc/modules-load.d/uwe5622-wifi.conf" "${payload_dir}/etc/modules-load.d/"

  cat <<EOF2 > "${bundle_dir}/manifest.txt"
Orange Pi Zero 2 kernel update bundle

Kernel release: ${KERNEL_RELEASE}
Kernel image:   /boot/${ASSET_KERNEL_NAME}
Initrd image:   /boot/${ASSET_INITRD_NAME}
Device tree:    /boot/dtb/sun50i-h616-orangepi-zero2.dtb
Modules:        /lib/modules/${KERNEL_RELEASE}
Firmware:       /lib/firmware/uwe5622/
Module config:  /etc/modules-load.d/uwe5622-wifi.conf

The target system also needs the Debian packages wpasupplicant, wireless-regdb,
and rfkill. New images install them automatically; install them manually before
using this bundle on an older rootfs.

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
    "${PAYLOAD_DIR}/lib/firmware/uwe5622/wcnmodem.bin"
    "${PAYLOAD_DIR}/lib/firmware/uwe5622/wcnmodem-38222.bin"
    "${PAYLOAD_DIR}/lib/firmware/uwe5622/wifi_2355b001_1ant.ini"
    "${PAYLOAD_DIR}/etc/modules-load.d/uwe5622-wifi.conf"
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

warn_missing_wireless_userspace() {
  local missing=()

  if ! command -v wpa_supplicant >/dev/null 2>&1; then
    missing+=(wpasupplicant)
  fi
  if ! command -v rfkill >/dev/null 2>&1; then
    missing+=(rfkill)
  fi
  if command -v dpkg-query >/dev/null 2>&1 && \
     ! dpkg-query -W -f='${db:Status-Abbrev}' wireless-regdb 2>/dev/null | grep -q '^ii'; then
    missing+=(wireless-regdb)
  fi

  if [[ "${#missing[@]}" -ne 0 ]]; then
    log "警告: 系统缺少 WiFi 用户态组件: ${missing[*]}"
    log "联网后安装: apt-get update && apt-get install -y ${missing[*]}"
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
  backup_file /lib/firmware/uwe5622
  backup_file /lib/firmware/wcnmodem.bin
  backup_file /lib/firmware/wifi_2355b001_1ant.ini
  backup_file /etc/modules-load.d/uwe5622-wifi.conf
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

install_wireless_files() {
  log "安装 UWE5622 固件和模块加载配置"
  mkdir -p /lib/firmware/uwe5622 /etc/modules-load.d
  cp -a "${PAYLOAD_DIR}/lib/firmware/uwe5622/." /lib/firmware/uwe5622/
  ln -sfn uwe5622/wcnmodem.bin /lib/firmware/wcnmodem.bin
  ln -sfn uwe5622/wifi_2355b001_1ant.ini /lib/firmware/wifi_2355b001_1ant.ini
  install -m 0644 "${PAYLOAD_DIR}/etc/modules-load.d/uwe5622-wifi.conf" /etc/modules-load.d/uwe5622-wifi.conf
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
  warn_missing_wireless_userspace
  ensure_boot_mounted
  backup_current_boot
  install_modules
  install_boot_files
  install_wireless_files
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
