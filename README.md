# Orange Pi Zero 2 Debian 13 Btrfs 镜像构建脚本

本仓库提供一个可重复运行、带清理机制的脚本，用于在 x86_64 Debian/Ubuntu 服务器上生成 Orange Pi Zero 2 (Allwinner H616) 的 Debian 13 (trixie) arm64 启动镜像，rootfs 使用 btrfs，并启用首次启动自动扩容。

## 功能概览

- 使用 Debian 官方 `debootstrap` 构建 Debian 13 (trixie) arm64 rootfs。
- root 分区为 btrfs，挂载选项：`compress=zstd:3,noatime`。
- 从 Armbian Orange Pi Zero 2 Minimal 镜像中提取 U-Boot、内核、DTB、initrd 资产。
- 启用 SSH（允许 root 密码登录）、NetworkManager、systemd-timesyncd。
- 首次启动自动扩容 `/dev/mmcblk0p2`，并扩展 btrfs 文件系统。

## 依赖

脚本会检查以下依赖：

- debootstrap
- qemu-user-static（需要 `qemu-aarch64-static`）
- parted
- losetup
- mkfs.vfat
- mkfs.btrfs
- mount
- rsync
- wget/curl
- xz
- chroot

## 使用方法

```bash
sudo ./build.sh
```

常用参数：

```bash
sudo ./build.sh \
  --image-size 6G \
  --suite trixie \
  --arch arm64 \
  --hostname orangepi-zero2 \
  --mirror http://mirrors.ustc.edu.cn/debian \
  --output ./orangepi-zero2-debian13-trixie-btrfs.img \
  --compress xz \
  --armbian-url https://dl.armbian.com/orangepizero2/Bookworm_current_minimal
```

脚本会提示输入 root 密码，或使用以下参数传入：

- `--root-pass`：明文密码（注意风险）
- `--root-pass-hash`：已加密 hash（优先）

## 输出与烧录

默认输出：

- `orangepi-zero2-debian13-trixie-btrfs.img`
- 可选压缩为 `.xz`

烧录示例（脚本不会直接写盘）：

```bash
xz -d orangepi-zero2-debian13-trixie-btrfs.img.xz
sudo dd if=orangepi-zero2-debian13-trixie-btrfs.img of=/dev/sdX bs=4M conv=fsync status=progress
```

> 注意：请将 `/dev/sdX` 替换为实际 SD 卡设备。
