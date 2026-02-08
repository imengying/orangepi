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
ARMBIAN_URL="https://dl.armbian.com/orangepizero2/Bookworm_current_minimal"
ROOT_PASS="orangepi"

LOOP_OUTPUT=""
LOOP_ARMBIAN=""
WORKDIR_CREATED=""
MNT_ROOT=""
MNT_BOOT=""
ASSETS_DIR=""
ARMBIAN_CACHE_DIR=""
ARMBIAN_IMG_XZ=""
ARMBIAN_IMG=""
ARMBIAN_BOOT_MNT=""
ASSET_KERNEL_NAME="Image"
ASSET_INITRD_NAME="uInitrd"

log() {
  echo "[${SCRIPT_NAME}] $*"
}

cleanup() {
  set +e
  if [[ -n "${ARMBIAN_BOOT_MNT}" ]] && mountpoint -q "${ARMBIAN_BOOT_MNT}"; then
    umount -lf "${ARMBIAN_BOOT_MNT}"
  fi
  if [[ -n "${ARMBIAN_BOOT_MNT}" && -d "${ARMBIAN_BOOT_MNT}" ]]; then
    rmdir "${ARMBIAN_BOOT_MNT}" || true
  fi
  if [[ -n "${MNT_BOOT}" ]] && mountpoint -q "${MNT_BOOT}"; then
    umount -lf "${MNT_BOOT}"
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
  if [[ -n "${LOOP_ARMBIAN}" ]]; then
    losetup -d "${LOOP_ARMBIAN}" || true
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
    debootstrap qemu-aarch64-static parted losetup mkfs.vfat mkfs.btrfs mount rsync xz chroot lsblk
  )
  local missing=()

  for d in "${deps[@]}"; do
    if ! command -v "${d}" >/dev/null 2>&1; then
      missing+=("${d}")
    fi
  done
  if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    missing+=("wget/curl")
  fi
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
      --armbian-url)
        ARMBIAN_URL="$2"
        shift 2
        ;;
      --root-pass)
        ROOT_PASS="$2"
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
}

init_workdir() {
  if [[ -n "${WORKDIR}" ]]; then
    WORKDIR_CREATED="${WORKDIR}"
    mkdir -p "${WORKDIR_CREATED}"
  else
    WORKDIR_CREATED=$(mktemp -d /tmp/opi-build-XXXX)
  fi
  ASSETS_DIR="${WORKDIR_CREATED}/assets"
  ARMBIAN_CACHE_DIR="${WORKDIR_CREATED}/cache"
  MNT_ROOT="${WORKDIR_CREATED}/rootfs"
  MNT_BOOT="${WORKDIR_CREATED}/rootfs/boot"
  mkdir -p "${ASSETS_DIR}" "${ARMBIAN_CACHE_DIR}" "${MNT_ROOT}"
  log "工作目录: ${WORKDIR_CREATED}"
}

read_root_password() {
  if [[ -z "${ROOT_PASS}" ]]; then
    ROOT_PASS="orangepi"
  fi
}

require_tools_for_download() {
  if command -v curl >/dev/null 2>&1; then
    return
  fi
  if command -v wget >/dev/null 2>&1; then
    return
  fi
  echo "缺少下载工具: curl 或 wget"
  exit 1
}

download_armbian_minimal() {
  require_tools_for_download
  log "下载 Armbian 资产: ${ARMBIAN_URL}"

  local resolved_url="${ARMBIAN_URL}"
  local final_url=""

  if [[ ! "${resolved_url}" =~ \.img\.xz($|[?#]) ]]; then
    if command -v curl >/dev/null 2>&1; then
      final_url=$(curl -fsSL -o /dev/null -w '%{url_effective}' "${ARMBIAN_URL}" 2>/dev/null || true)
    else
      final_url=$(wget --max-redirect=20 --server-response --spider "${ARMBIAN_URL}" 2>&1 | awk '/^  Location: / {print $2}' | tail -n1 | tr -d '\r' || true)
    fi
    if [[ "${final_url}" =~ \.img\.xz($|[?#]) ]]; then
      resolved_url="${final_url}"
    fi
  fi

  if [[ ! "${resolved_url}" =~ \.img\.xz($|[?#]) ]]; then
    log "解析 Armbian 下载页面，查找 .img.xz"
    local page_file
    page_file=$(mktemp "${WORKDIR_CREATED}/armbian-page-XXXXXX")
    if command -v curl >/dev/null 2>&1; then
      curl -fsSL "${ARMBIAN_URL}" -o "${page_file}"
    else
      wget -qO "${page_file}" "${ARMBIAN_URL}"
    fi
    resolved_url=$(grep -aoE 'https?://[^"[:space:]]+\.img\.xz' "${page_file}" | head -n1 || true)
    if [[ -z "${resolved_url}" ]]; then
      local href
      href=$(grep -aoE 'href=\"[^\"]+\.img\.xz\"' "${page_file}" | head -n1 | cut -d'"' -f2 || true)
      if [[ -n "${href}" ]]; then
        if [[ "${href}" =~ ^https?:// ]]; then
          resolved_url="${href}"
        else
          resolved_url="${ARMBIAN_URL%/}/${href}"
        fi
      fi
    fi
    rm -f "${page_file}"
  fi

  if [[ -z "${resolved_url}" || ! "${resolved_url}" =~ \.img\.xz($|[?#]) ]]; then
    echo "无法解析 Armbian 镜像下载地址，请检查 --armbian-url"
    exit 1
  fi

  local file_name
  file_name=$(basename "${resolved_url%%\?*}")
  if [[ -z "${file_name}" || ! "${file_name}" =~ \.img\.xz$ ]]; then
    file_name="armbian.img.xz"
  fi
  ARMBIAN_IMG_XZ="${ARMBIAN_CACHE_DIR}/${file_name}"
  if [[ -f "${ARMBIAN_IMG_XZ}" ]]; then
    log "使用缓存: ${ARMBIAN_IMG_XZ}"
    return
  fi
  if command -v curl >/dev/null 2>&1; then
    curl -fL "${resolved_url}" -o "${ARMBIAN_IMG_XZ}"
  else
    wget -O "${ARMBIAN_IMG_XZ}" "${resolved_url}"
  fi
}

extract_armbian_assets() {
  log "解压 Armbian 镜像"
  ARMBIAN_IMG="${ARMBIAN_CACHE_DIR}/armbian.img"
  if [[ ! -f "${ARMBIAN_IMG}" ]]; then
    xz -dkc "${ARMBIAN_IMG_XZ}" > "${ARMBIAN_IMG}"
  fi
  LOOP_ARMBIAN=$(losetup -Pf --show "${ARMBIAN_IMG}")
  log "Armbian loop: ${LOOP_ARMBIAN}"

  local armbian_parts=()
  local p
  for p in "${LOOP_ARMBIAN}"p*; do
    if [[ -e "${p}" ]]; then
      armbian_parts+=("${p}")
    fi
  done
  if [[ "${#armbian_parts[@]}" -eq 0 ]]; then
    echo "未找到 Armbian 镜像分区: ${LOOP_ARMBIAN}p*"
    exit 1
  fi

  ARMBIAN_BOOT_MNT="${WORKDIR_CREATED}/armbian-boot"
  mkdir -p "${ARMBIAN_BOOT_MNT}"

  local selected_part=""
  local dtb_found=""
  for p in "${armbian_parts[@]}"; do
    if ! mount -o ro "${p}" "${ARMBIAN_BOOT_MNT}" 2>/dev/null; then
      continue
    fi
    dtb_found=$(find -L "${ARMBIAN_BOOT_MNT}" -maxdepth 12 -type f -name "sun50i-h616-orangepi-zero2.dtb" | head -n1 || true)
    if [[ -n "${dtb_found}" ]]; then
      selected_part="${p}"
      break
    fi
    umount "${ARMBIAN_BOOT_MNT}" || true
  done

  if [[ -z "${selected_part}" ]]; then
    echo "未在 Armbian 各分区中找到 DTB: sun50i-h616-orangepi-zero2.dtb"
    exit 1
  fi
  log "使用分区提取启动资产: ${selected_part}"

  local kernel_path
  kernel_path=$(find -L "${ARMBIAN_BOOT_MNT}" -maxdepth 12 -type f -name "Image" | head -n1 || true)
  if [[ -z "${kernel_path}" ]]; then
    kernel_path=$(find -L "${ARMBIAN_BOOT_MNT}" -maxdepth 12 -type f -name "Image-*" | head -n1 || true)
  fi
  if [[ -z "${kernel_path}" ]]; then
    kernel_path=$(find -L "${ARMBIAN_BOOT_MNT}" -maxdepth 12 -type f -name "vmlinuz*" | head -n1 || true)
  fi
  if [[ -z "${kernel_path}" ]]; then
    kernel_path=$(find -L "${ARMBIAN_BOOT_MNT}" -maxdepth 12 -type f -name "zImage*" | head -n1 || true)
  fi
  if [[ -z "${kernel_path}" ]]; then
    echo "未找到内核文件（Image/Image-*/vmlinuz*/zImage*），启动分区结构可能已变化。"
    exit 1
  fi
  ASSET_KERNEL_NAME=$(basename "${kernel_path}")
  cp "${kernel_path}" "${ASSETS_DIR}/${ASSET_KERNEL_NAME}"

  local initrd_path
  initrd_path=$(find -L "${ARMBIAN_BOOT_MNT}" -maxdepth 12 -type f -name "uInitrd" | head -n1 || true)
  if [[ -z "${initrd_path}" ]]; then
    initrd_path=$(find -L "${ARMBIAN_BOOT_MNT}" -maxdepth 12 -type f -name "initrd.img*" | head -n1 || true)
  fi
  if [[ -z "${initrd_path}" ]]; then
    echo "未找到 initrd（uInitrd 或 initrd.img*）"
    exit 1
  fi
  ASSET_INITRD_NAME=$(basename "${initrd_path}")
  cp "${initrd_path}" "${ASSETS_DIR}/${ASSET_INITRD_NAME}"

  local dtb_src_dir
  dtb_src_dir=$(dirname "${dtb_found}")
  while [[ "${dtb_src_dir}" != "/" && "$(basename "${dtb_src_dir}")" != "dtb" ]]; do
    dtb_src_dir=$(dirname "${dtb_src_dir}")
  done
  if [[ "${dtb_src_dir}" == "/" ]]; then
    dtb_src_dir=$(dirname "${dtb_found}")
  fi
  mkdir -p "${ASSETS_DIR}/dtb"
  rsync -a "${dtb_src_dir}/" "${ASSETS_DIR}/dtb/"

  dd if="${ARMBIAN_IMG}" of="${ASSETS_DIR}/uboot.bin" bs=1M count=16
  umount "${ARMBIAN_BOOT_MNT}"
  rmdir "${ARMBIAN_BOOT_MNT}"
  ARMBIAN_BOOT_MNT=""
  losetup -d "${LOOP_ARMBIAN}"
  LOOP_ARMBIAN=""
}

create_blank_image() {
  log "创建镜像: ${OUTPUT}"
  truncate -s "${IMAGE_SIZE}" "${OUTPUT}"
  parted -s "${OUTPUT}" mklabel msdos
  parted -s "${OUTPUT}" mkpart primary fat32 1MiB 513MiB
  parted -s "${OUTPUT}" set 1 boot on
  parted -s "${OUTPUT}" mkpart primary btrfs 513MiB 100%
  log "分区信息:"
  lsblk -o NAME,SIZE,TYPE "${OUTPUT}" || true
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
  cat <<EOF > "${MNT_ROOT}/etc/hostname"
${HOSTNAME}
EOF
  cat <<EOF > "${MNT_ROOT}/etc/hosts"
127.0.0.1\tlocalhost
127.0.1.1\t${HOSTNAME}
EOF

  cat <<EOF > "${MNT_ROOT}/etc/apt/sources.list"
deb ${MIRROR} ${SUITE} main contrib non-free non-free-firmware
deb ${MIRROR}-security ${SUITE}-security main contrib non-free non-free-firmware
deb ${MIRROR} ${SUITE}-updates main contrib non-free non-free-firmware
EOF

  chroot "${MNT_ROOT}" /bin/bash -c "apt-get update"
  chroot "${MNT_ROOT}" /bin/bash -c "DEBIAN_FRONTEND=noninteractive apt-get install -y openssh-server network-manager ca-certificates systemd-timesyncd btrfs-progs initramfs-tools parted util-linux"
  chroot "${MNT_ROOT}" /bin/bash -c "systemctl enable ssh NetworkManager systemd-timesyncd"

  mkdir -p "${MNT_ROOT}/etc/ssh/sshd_config.d"
  cat <<'EOF' > "${MNT_ROOT}/etc/ssh/sshd_config.d/99-root-login.conf"
PermitRootLogin yes
PasswordAuthentication yes
EOF

  echo "root:${ROOT_PASS}" | chroot "${MNT_ROOT}" chpasswd

  cat <<'EOF' > "${MNT_ROOT}/etc/fstab"
/dev/mmcblk0p2 / btrfs defaults,compress=zstd,noatime 0 1
/dev/mmcblk0p1 /boot vfat defaults 0 2
EOF

  write_resize_script
  chroot "${MNT_ROOT}" /bin/bash -c "systemctl enable opi-firstboot-resize.service"
}

install_boot_assets() {
  log "安装 boot 资产"
  cp "${ASSETS_DIR}/${ASSET_KERNEL_NAME}" "${MNT_BOOT}/${ASSET_KERNEL_NAME}"
  mkdir -p "${MNT_BOOT}/dtb"
  rsync -a "${ASSETS_DIR}/dtb/" "${MNT_BOOT}/dtb/"
  cp "${ASSETS_DIR}/${ASSET_INITRD_NAME}" "${MNT_BOOT}/${ASSET_INITRD_NAME}"
  mkdir -p "${MNT_BOOT}/extlinux"
  local dtb_rel
  dtb_rel=$(find "${ASSETS_DIR}/dtb" -name "sun50i-h616-orangepi-zero2.dtb" | head -n1)
  dtb_rel=${dtb_rel#"${ASSETS_DIR}/dtb/"}
  cat <<EOF > "${MNT_BOOT}/extlinux/extlinux.conf"
LABEL DebianTrixie
  LINUX /${ASSET_KERNEL_NAME}
  INITRD /${ASSET_INITRD_NAME}
  FDT /dtb/${dtb_rel}
  APPEND root=/dev/mmcblk0p2 rootfstype=btrfs rootwait rw console=ttyS0,115200 console=tty1
EOF
}

install_uboot_to_output_image() {
  log "写入 U-Boot"
  dd if="${ASSETS_DIR}/uboot.bin" of="${LOOP_OUTPUT}" bs=1M conv=fsync
}

finalize_image() {
  sync
  log "检查生成结果"
  if [[ ! -f "${MNT_ROOT}/boot/${ASSET_KERNEL_NAME}" ]]; then
    echo "校验失败: /boot/${ASSET_KERNEL_NAME} 不存在"
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
    cat <<EOF
镜像生成完成: ${out_file}

烧录示例:
  xz -d ${out_file}
  sudo dd if=${OUTPUT} of=/dev/sdX bs=4M conv=fsync status=progress
EOF
    return
  fi

  cat <<EOF
镜像生成完成: ${out_file}

烧录示例:
  sudo dd if=${out_file} of=/dev/sdX bs=4M conv=fsync status=progress
EOF
}

main() {
  parse_args "$@"
  validate_args
  require_root
  check_deps
  ensure_loop_support
  init_workdir
  read_root_password
  download_armbian_minimal
  extract_armbian_assets
  create_blank_image
  setup_loop_for_output_image
  format_partitions
  mount_partitions
  build_debian_rootfs
  configure_rootfs_in_chroot
  install_boot_assets
  install_uboot_to_output_image
  finalize_image
  compress_output
  print_flash_hint
}

main "$@"
