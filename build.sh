#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME=$(basename "$0")

IMAGE_SIZE="3G"
SUITE="trixie"
ARCH="arm64"
HOSTNAME="orangepi"
MIRROR="http://mirrors.ustc.edu.cn/debian"
OUTPUT="$(pwd)/orangepi-zero2-debian13-trixie-btrfs.img"
COMPRESS="xz"
WORKDIR=""
ROOT_PASS="orangepi"

KERNEL_REPO="https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git"
KERNEL_REF="6.12"
KERNEL_DEFCONFIG="defconfig"
UBOOT_REPO="https://github.com/u-boot/u-boot.git"
UBOOT_REF="v2025.01"
ATF_REPO="https://github.com/ARM-software/arm-trusted-firmware.git"
ATF_REF="v2.12.0"
JOBS="$(nproc)"

LOOP_OUTPUT=""
WORKDIR_CREATED=""
MNT_ROOT=""
MNT_BOOT=""
ASSETS_DIR=""
SRC_DIR=""
KERNEL_SRC_DIR=""
UBOOT_SRC_DIR=""
ATF_SRC_DIR=""
ATF_BL31=""
KERNEL_RELEASE=""
ASSET_KERNEL_NAME="Image"
ASSET_INITRD_NAME=""

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
    debootstrap qemu-aarch64-static parted losetup mkfs.vfat mkfs.btrfs mount mountpoint
    rsync xz chroot lsblk git make aarch64-linux-gnu-gcc bc bison flex openssl dtc swig python3
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
}

ensure_loop_support() {
  if losetup -f >/dev/null 2>&1; then
    return
  fi

  if command -v modprobe >/dev/null 2>&1; then
    modprobe loop >/dev/null 2>&1 || true
  fi

  if [[ -e /dev/loop-control ]]; then
    local i
    for i in $(seq 0 7); do
      if [[ ! -e "/dev/loop${i}" ]]; then
        mknod -m 660 "/dev/loop${i}" b 7 "${i}" >/dev/null 2>&1 || true
      fi
    done
    chown root:disk /dev/loop[0-7] >/dev/null 2>&1 || true
  fi

  if losetup -f >/dev/null 2>&1; then
    return
  fi

  echo "未找到可用 loop 设备（losetup -f 失败）。"
  echo "请确认当前环境支持 loop 设备："
  echo "  1) 在宿主机执行: modprobe loop"
  echo "  2) 确认存在: /dev/loop-control 和 /dev/loop0"
  echo "  3) 若在容器/受限云主机，请开启 loop 设备权限或改用支持 loop 的 VM"
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

  # 支持 --kernel-ref 6.12.69（自动补 v 前缀）
  if [[ "${ref}" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    KERNEL_REF="v${ref}"
    log "内核版本: ${KERNEL_REF}"
    return
  fi

  # 支持 --kernel-ref 6.12 / v6.12（自动解析最新补丁版）
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
  MNT_ROOT="${WORKDIR_CREATED}/rootfs"
  MNT_BOOT="${WORKDIR_CREATED}/rootfs/boot"

  mkdir -p "${ASSETS_DIR}/dtb" "${SRC_DIR}" "${MNT_ROOT}"
  log "工作目录: ${WORKDIR_CREATED}"
}

read_root_password() {
  if [[ -z "${ROOT_PASS}" ]]; then
    ROOT_PASS="orangepi"
  fi
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

set_dtb_led_defaults() {
  local dts_file="${KERNEL_SRC_DIR}/arch/arm64/boot/dts/allwinner/sun50i-h616-orangepi-zero.dtsi"
  if [[ ! -f "${dts_file}" ]]; then
    echo "未找到内核 LED 设备树文件: ${dts_file}"
    exit 1
  fi

  log "修改内核设备树 LED 默认状态（红灯关闭，绿灯心跳）"
  python3 - "${dts_file}" <<'PY'
import re
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    lines = f.readlines()


def find_anchor(tokens):
    for i, line in enumerate(lines):
        for token in tokens:
            if token in line:
                return i
    return -1


def find_block_bounds(anchor_idx):
    start = -1
    for i in range(anchor_idx, -1, -1):
        if "{" in lines[i]:
            start = i
            break
    if start < 0:
        raise RuntimeError("无法定位 LED 节点开始位置")

    depth = 0
    for i in range(start, len(lines)):
        depth += lines[i].count("{")
        depth -= lines[i].count("}")
        if depth == 0:
            return start, i
    raise RuntimeError("无法定位 LED 节点结束位置")


def patch_node(tokens, trigger, state):
    anchor_idx = find_anchor(tokens)
    if anchor_idx < 0:
        return False

    start, end = find_block_bounds(anchor_idx)
    block = lines[start:end + 1]

    indent = None
    for line in block:
        if "label =" in line or "function =" in line:
            indent = re.match(r"^(\s*)", line).group(1)
            break
    if indent is None:
        indent = re.match(r"^(\s*)", block[0]).group(1) + "\t"

    new_block = []
    for line in block[:-1]:
        if re.search(r"\blinux,default-trigger\s*=", line):
            continue
        if re.search(r"\bdefault-state\s*=", line):
            continue
        new_block.append(line)

    new_block.append(f'{indent}linux,default-trigger = "{trigger}";\n')
    if state is not None:
        new_block.append(f'{indent}default-state = "{state}";\n')
    new_block.append(block[-1])

    lines[start:end + 1] = new_block
    return True


red_ok = patch_node([
    'label = "orangepi:red:power"',
    'label = "red:power"',
    "LED_FUNCTION_POWER",
    'function = "power"',
    "LED_COLOR_ID_RED",
], "none", "off")
green_ok = patch_node([
    'label = "orangepi:green:status"',
    'label = "green:status"',
    "LED_FUNCTION_STATUS",
    'function = "status"',
    "LED_COLOR_ID_GREEN",
], "heartbeat", None)

if not red_ok or not green_ok:
    missing = []
    if not red_ok:
        missing.append("red:power")
    if not green_ok:
        missing.append("green:status")
    print("WARN: 未在内核 DTS 中定位到 LED 节点: " + ", ".join(missing), file=sys.stderr)

with open(path, "w", encoding="utf-8") as f:
    f.writelines(lines)

print(f"Patched Kernel DTS: {path}")
PY
}

build_kernel() {
  log "编译 Linux 内核"
  make -C "${KERNEL_SRC_DIR}" mrproper
  set_dtb_led_defaults
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
      --enable EXTCON \
      --enable EXTCON_USB_GPIO \
      --disable WLAN \
      --disable CFG80211 \
      --disable MAC80211 \
      --disable WIRELESS \
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
      --set-str LOCALVERSION "" \
      --disable LOCALVERSION_AUTO
  fi

  make -C "${KERNEL_SRC_DIR}" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig

  make -C "${KERNEL_SRC_DIR}" -j"${JOBS}" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- Image modules dtbs

  KERNEL_RELEASE=$(make -s -C "${KERNEL_SRC_DIR}" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- kernelrelease)
  if [[ -z "${KERNEL_RELEASE}" ]]; then
    echo "无法确定内核版本 (kernelrelease)"
    exit 1
  fi

  cp "${KERNEL_SRC_DIR}/arch/arm64/boot/Image" "${ASSETS_DIR}/${ASSET_KERNEL_NAME}"

  local dtb_file="${KERNEL_SRC_DIR}/arch/arm64/boot/dts/allwinner/sun50i-h616-orangepi-zero2.dtb"
  if [[ ! -f "${dtb_file}" ]]; then
    dtb_file=$(find "${KERNEL_SRC_DIR}/arch/arm64/boot/dts" -type f -name "sun50i-h616-orangepi-zero2.dtb" | head -n1 || true)
  fi
  if [[ -z "${dtb_file}" || ! -f "${dtb_file}" ]]; then
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
  mkdir -p "${MNT_BOOT}"
  mount "${LOOP_OUTPUT}p1" "${MNT_BOOT}"
}

prepare_dns() {
  if [[ -f /etc/resolv.conf ]]; then
    cp /etc/resolv.conf "${MNT_ROOT}/etc/resolv.conf"
  else
    echo "nameserver 1.1.1.1" > "${MNT_ROOT}/etc/resolv.conf"
  fi
}

build_debian_rootfs() {
  log "debootstrap 构建 rootfs"
  debootstrap --arch="${ARCH}" "${SUITE}" "${MNT_ROOT}" "${MIRROR}"
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

if [[ -f "${DONE_FILE}" ]]; then
  log "已完成，退出。"
  exit 0
fi

log "开始扩容 /dev/mmcblk0p2"

# 使用 growpart 扩展分区（更可靠）
if command -v growpart >/dev/null 2>&1; then
  log "使用 growpart 扩展分区"
  growpart /dev/mmcblk0 2 || log "growpart 失败，尝试其他方法"
elif command -v sfdisk >/dev/null 2>&1; then
  log "使用 sfdisk 扩展分区"
  echo ", +" | sfdisk --no-reread -N 2 /dev/mmcblk0 || log "sfdisk 失败"
else
  log "使用 parted 扩展分区"
  parted -s /dev/mmcblk0 resizepart 2 100% || log "parted 失败"
fi

log "刷新分区表"
partprobe /dev/mmcblk0 2>/dev/null || blockdev --rereadpt /dev/mmcblk0 2>/dev/null || true

sleep 3

new_size=$(blockdev --getsize64 /dev/mmcblk0p2 2>/dev/null || echo 0)
log "分区大小: $((new_size / 1024 / 1024)) MB"

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
127.0.0.1\tlocalhost
127.0.1.1\t${HOSTNAME}
EOF2

  cat <<EOF2 > "${MNT_ROOT}/etc/apt/sources.list"
deb ${MIRROR} ${SUITE} main contrib non-free non-free-firmware
deb ${MIRROR}-security ${SUITE}-security main contrib non-free non-free-firmware
deb ${MIRROR} ${SUITE}-updates main contrib non-free non-free-firmware
EOF2

  chroot "${MNT_ROOT}" /bin/bash -c "apt-get update"
  chroot "${MNT_ROOT}" /bin/bash -c "DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends openssh-server network-manager ca-certificates systemd-timesyncd btrfs-progs initramfs-tools parted cloud-guest-utils zstd locales"
  chroot "${MNT_ROOT}" /bin/bash -c "systemctl enable ssh NetworkManager systemd-timesyncd"
  
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
  chroot "${MNT_ROOT}" /bin/bash -c "systemctl disable man-db.timer" || true
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

  # 禁用 btrfs fsck（btrfs 不需要传统的 fsck）
  mkdir -p "${MNT_ROOT}/etc/initramfs-tools/hooks"
  cat <<'EOF2' > "${MNT_ROOT}/etc/initramfs-tools/hooks/ignore-btrfs-fsck"
#!/bin/sh
# 禁用 btrfs 的 fsck 检查（btrfs 使用自己的检查机制）
exit 0
EOF2
  chmod +x "${MNT_ROOT}/etc/initramfs-tools/hooks/ignore-btrfs-fsck"

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

  cat <<'EOF2' > "${MNT_ROOT}/etc/fstab"
/dev/mmcblk0p2 / btrfs defaults,compress=zstd 0 1
/dev/mmcblk0p1 /boot vfat defaults 0 2
EOF2

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
  
  # 创建 LED 调试脚本（默认行为由 U-Boot/内核设备树决定）
  cat <<'EOF2' > "${MNT_ROOT}/usr/local/bin/led-control"
#!/bin/bash
# LED 控制脚本

set_trigger() {
  local led_dir="$1"
  local mode="$2"
  [ -d "$led_dir" ] || return 0
  echo "$mode" > "$led_dir/trigger" 2>/dev/null || true
}

set_brightness() {
  local led_dir="$1"
  local value="$2"
  [ -d "$led_dir" ] || return 0
  echo "$value" > "$led_dir/brightness" 2>/dev/null || true
}

green_heartbeat_red_off() {
  for led_dir in /sys/class/leds/*; do
    [ -d "$led_dir" ] || continue
    led_name=$(basename "$led_dir")

    if [[ "$led_name" == *"red"* ]] || [[ "$led_name" == *"power"* ]]; then
      set_trigger "$led_dir" none
      set_brightness "$led_dir" 0
      continue
    fi

    if [[ "$led_name" == *"green"* ]] || [[ "$led_name" == *"status"* ]]; then
      set_trigger "$led_dir" heartbeat
    fi
  done

  # 回退到常见固定路径
  set_trigger /sys/class/leds/orangepi:red:power none
  set_brightness /sys/class/leds/orangepi:red:power 0
  set_trigger /sys/class/leds/orangepi:green:status heartbeat
}

show_leds() {
  echo "可用的 LED："
  for led in /sys/class/leds/*; do
    if [ -d "$led" ]; then
      echo "  $(basename $led)"
      echo "    当前触发器: $(cat $led/trigger 2>/dev/null | grep -o '\[.*\]' | tr -d '[]')"
      echo "    可用触发器: $(cat $led/trigger 2>/dev/null)"
    fi
  done
}

set_mode() {
  local mode=$1
  case $mode in
    heartbeat)
      echo "设置为绿灯心跳，红灯关闭"
      green_heartbeat_red_off
      ;;
    all-heartbeat)
      echo "设置为全部心跳模式"
      for led in /sys/class/leds/*/trigger; do
        echo heartbeat > "$led" 2>/dev/null || true
      done
      ;;
    off)
      echo "关闭所有 LED"
      for led in /sys/class/leds/*/trigger; do
        echo none > "$led" 2>/dev/null || true
        echo 0 > "$(dirname $led)/brightness" 2>/dev/null || true
      done
      ;;
    on)
      echo "打开所有 LED"
      for led in /sys/class/leds/*/trigger; do
        echo none > "$led" 2>/dev/null || true
        echo 1 > "$(dirname $led)/brightness" 2>/dev/null || true
      done
      ;;
    *)
      echo "用法: led-control [show|heartbeat|all-heartbeat|off|on]"
      exit 1
      ;;
  esac
}

case ${1:-show} in
  show) show_leds ;;
  *) set_mode "$1" ;;
esac
EOF2
  chmod +x "${MNT_ROOT}/usr/local/bin/led-control"
  
  log "清理系统以减小镜像大小"
  chroot "${MNT_ROOT}" /bin/bash -c "apt-get clean"
  chroot "${MNT_ROOT}" /bin/bash -c "rm -rf /var/lib/apt/lists/*"
  chroot "${MNT_ROOT}" /bin/bash -c "rm -rf /tmp/* /var/tmp/*"
  chroot "${MNT_ROOT}" /bin/bash -c "rm -rf /usr/share/doc/* /usr/share/man/* /usr/share/info/*"
  chroot "${MNT_ROOT}" /bin/bash -c "rm -rf /usr/share/locale/* /usr/share/i18n/locales/*"
  chroot "${MNT_ROOT}" /bin/bash -c "rm -rf /var/cache/apt/archives/*.deb"
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
  # config 仅用于 update-initramfs 探测能力，后续会清理
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
  
  # 清理 boot 分区不必要的文件
  log "清理 boot 分区"
  rm -f "${MNT_ROOT}/boot/vmlinuz-${KERNEL_RELEASE}" 2>/dev/null || true
  rm -f "${MNT_ROOT}/boot/System.map-${KERNEL_RELEASE}" 2>/dev/null || true
  rm -f "${MNT_ROOT}/boot/config-${KERNEL_RELEASE}" 2>/dev/null || true
}

install_boot_assets() {
  log "写入 extlinux 配置"
  local dtb_rel
  dtb_rel=$(find "${MNT_BOOT}/dtb" -type f -name "sun50i-h616-orangepi-zero2.dtb" | head -n1 || true)
  if [[ -z "${dtb_rel}" ]]; then
    echo "启动分区未找到 DTB: sun50i-h616-orangepi-zero2.dtb"
    exit 1
  fi
  dtb_rel=${dtb_rel#"${MNT_BOOT}/"}

  mkdir -p "${MNT_BOOT}/extlinux"
  cat <<EOF2 > "${MNT_BOOT}/extlinux/extlinux.conf"
LABEL DebianTrixie
  LINUX /${ASSET_KERNEL_NAME}
  INITRD /${ASSET_INITRD_NAME}
  FDT /${dtb_rel}
  APPEND root=/dev/mmcblk0p2 rootfstype=btrfs rootwait rw console=ttyS0,115200 console=tty1
EOF2
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
    echo "镜像生成完成: ${out_file}"
    return
  fi

  echo "镜像生成完成: ${out_file}"
}

main() {
  parse_args "$@"
  validate_args
  require_root
  check_deps
  ensure_loop_support
  init_workdir
  read_root_password
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
  install_uboot_to_output_image
  finalize_image
  compress_output
  print_flash_hint
}

main "$@"
