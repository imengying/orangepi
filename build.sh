#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME=$(basename "$0")

IMAGE_SIZE="4G"
SUITE="trixie"
ARCH="arm64"
HOSTNAME="orangepi-zero2"
MIRROR="http://mirrors.ustc.edu.cn/debian"
OUTPUT="$(pwd)/orangepi-zero2-debian13-trixie-btrfs.img"
COMPRESS="xz"
WORKDIR=""
ROOT_PASS="orangepi"

KERNEL_REPO="https://github.com/torvalds/linux.git"
KERNEL_REF="v6.12"
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
    echo "请先安装依赖后重试（见 README.md）"
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
      --disable TOOLS_MKEFICAPSULE || true
    make -C "${UBOOT_SRC_DIR}" CROSS_COMPILE=aarch64-linux-gnu- olddefconfig
  fi
  make -C "${UBOOT_SRC_DIR}" -j"${JOBS}" CROSS_COMPILE=aarch64-linux-gnu- BL31="${ATF_BL31}"

  local uboot_bin="${UBOOT_SRC_DIR}/u-boot-sunxi-with-spl.bin"
  if [[ ! -f "${uboot_bin}" ]]; then
    echo "编译 U-Boot 失败: ${uboot_bin} 不存在"
    exit 1
  fi
  cp "${uboot_bin}" "${ASSETS_DIR}/uboot.bin"
}

build_kernel() {
  log "编译 Linux 内核"
  make -C "${KERNEL_SRC_DIR}" mrproper
  if make -C "${KERNEL_SRC_DIR}" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- "${KERNEL_DEFCONFIG}" >/dev/null 2>&1; then
    log "使用内核配置: ${KERNEL_DEFCONFIG}"
  else
    log "内核不支持 ${KERNEL_DEFCONFIG}，回退到 defconfig"
    make -C "${KERNEL_SRC_DIR}" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- defconfig
  fi

  if [[ -x "${KERNEL_SRC_DIR}/scripts/config" ]]; then
    "${KERNEL_SRC_DIR}/scripts/config" --file "${KERNEL_SRC_DIR}/.config" \
      --enable BLK_DEV_INITRD \
      --enable BTRFS_FS \
      --enable BTRFS_FS_POSIX_ACL
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
  parted -s "${OUTPUT}" mkpart primary fat32 1MiB 513MiB
  parted -s "${OUTPUT}" set 1 boot on
  parted -s "${OUTPUT}" mkpart primary btrfs 513MiB 100%
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
  mount -o compress=zstd,noatime "${LOOP_OUTPUT}p2" "${MNT_ROOT}"
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
}

if [[ -f "${DONE_FILE}" ]]; then
  log "已完成，退出。"
  exit 0
fi

log "开始扩容 /dev/mmcblk0p2"
if command -v sfdisk >/dev/null 2>&1; then
  log "使用 sfdisk 扩展分区"
  start_sector=$(sfdisk -d /dev/mmcblk0 | awk '/^\/dev\/mmcblk0p2/ {print $4}' | tr -d ',')
  if [[ -n "${start_sector}" ]]; then
    printf ',,L,\n' | sfdisk -N2 /dev/mmcblk0
  fi
else
  log "使用 parted 扩展分区"
  parted -s /dev/mmcblk0 resizepart 2 100%
fi

log "刷新分区表"
if command -v partprobe >/dev/null 2>&1; then
  partprobe /dev/mmcblk0 || true
else
  blockdev --rereadpt /dev/mmcblk0 || true
fi

sleep 2

new_size=$(blockdev --getsz /dev/mmcblk0p2 || echo 0)
log "分区扇区数: ${new_size}"

log "尝试扩容 btrfs"
if btrfs filesystem resize max /; then
  log "btrfs 扩容成功"
  touch "${DONE_FILE}"
  systemctl disable --now opi-firstboot-resize.service || true
  exit 0
fi

log "btrfs 扩容未完成，尝试重启后继续"
if ! systemctl reboot; then
  log "重启失败，稍后手动处理"
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
  chroot "${MNT_ROOT}" /bin/bash -c "DEBIAN_FRONTEND=noninteractive apt-get install -y openssh-server network-manager ca-certificates systemd-timesyncd btrfs-progs initramfs-tools parted util-linux"
  chroot "${MNT_ROOT}" /bin/bash -c "systemctl enable ssh NetworkManager systemd-timesyncd"

  mkdir -p "${MNT_ROOT}/etc/ssh/sshd_config.d"
  cat <<'EOF2' > "${MNT_ROOT}/etc/ssh/sshd_config.d/99-root-login.conf"
PermitRootLogin yes
PasswordAuthentication yes
EOF2

  echo "root:${ROOT_PASS}" | chroot "${MNT_ROOT}" chpasswd

  cat <<'EOF2' > "${MNT_ROOT}/etc/fstab"
/dev/mmcblk0p2 / btrfs defaults,compress=zstd,noatime 0 1
/dev/mmcblk0p1 /boot vfat defaults 0 2
EOF2

  write_resize_script
  chroot "${MNT_ROOT}" /bin/bash -c "systemctl enable opi-firstboot-resize.service"
}

install_compiled_kernel() {
  log "安装自编译内核模块"
  make -C "${KERNEL_SRC_DIR}" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
    INSTALL_MOD_PATH="${MNT_ROOT}" DEPMOD=/bin/true modules_install

  cp "${ASSETS_DIR}/${ASSET_KERNEL_NAME}" "${MNT_BOOT}/${ASSET_KERNEL_NAME}"
  mkdir -p "${MNT_BOOT}/dtb"
  rsync -a "${ASSETS_DIR}/dtb/" "${MNT_BOOT}/dtb/"

  cp "${ASSETS_DIR}/${ASSET_KERNEL_NAME}" "${MNT_ROOT}/boot/vmlinuz-${KERNEL_RELEASE}"
  cp "${ASSETS_DIR}/System.map-${KERNEL_RELEASE}" "${MNT_ROOT}/boot/System.map-${KERNEL_RELEASE}"
  cp "${ASSETS_DIR}/config-${KERNEL_RELEASE}" "${MNT_ROOT}/boot/config-${KERNEL_RELEASE}"

  chroot "${MNT_ROOT}" /bin/bash -c "depmod -a '${KERNEL_RELEASE}'"
  chroot "${MNT_ROOT}" /bin/bash -c "update-initramfs -c -k '${KERNEL_RELEASE}'"

  ASSET_INITRD_NAME="initrd.img-${KERNEL_RELEASE}"
  if [[ ! -f "${MNT_BOOT}/${ASSET_INITRD_NAME}" ]]; then
    echo "未生成 initrd: /boot/${ASSET_INITRD_NAME}"
    exit 1
  fi
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
    log "压缩镜像"
    xz -T0 -z -9 "${OUTPUT}"
  fi
}

print_flash_hint() {
  local out_file="${OUTPUT}"
  if [[ "${COMPRESS}" == "xz" ]]; then
    out_file="${OUTPUT}.xz"
    cat <<EOF2
镜像生成完成: ${out_file}

烧录示例:
  xz -d ${out_file}
  sudo dd if=${OUTPUT} of=/dev/sdX bs=4M conv=fsync status=progress
EOF2
    return
  fi

  cat <<EOF2
镜像生成完成: ${out_file}

烧录示例:
  sudo dd if=${out_file} of=/dev/sdX bs=4M conv=fsync status=progress
EOF2
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
