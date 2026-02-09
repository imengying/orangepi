# Orange Pi Zero 2 Debian 13 Btrfs 镜像构建脚本

本仓库提供一个可重复运行、带清理机制的脚本，用于在 x86_64 Debian/Ubuntu 服务器上生成 Orange Pi Zero 2 (Allwinner H616) 的 Debian 13 (trixie) arm64 启动镜像，rootfs 使用 btrfs，并启用首次启动自动扩容。

## 功能概览

- 使用 Debian 官方 `debootstrap` 构建 Debian 13 (trixie) arm64 rootfs。
- 全自编译 ARM Trusted Firmware、U-Boot、Linux 内核（不再依赖从 Armbian 镜像提取启动资产）。
- 构建流程参考 Orange Pi 官方 `orangepi-build`，默认源码使用上游仓库。
- root 分区为 btrfs，挂载选项：`compress=zstd`（移除 noatime 以延长 SD 卡寿命）。
- 启用 SSH（允许 root 密码登录）、NetworkManager、systemd-timesyncd。
- 首次启动自动扩容 `/dev/mmcblk0p2`，并扩展 btrfs 文件系统（使用 growpart 工具）。
- **镜像优化**：使用 `--no-install-recommends`、清理缓存文档、精简内核模块、极限压缩，大幅减小镜像体积。
- **LED 控制**：电源指示灯设置为心跳模式（可自定义）。
- **精简配置**：移除 WiFi/蓝牙固件（有线网络可用，减小镜像体积）。

## 依赖

需要以下软件包：

- debootstrap
- qemu-user-static
- parted
- util-linux
- dosfstools
- btrfs-progs
- rsync
- xz-utils
- coreutils
- git
- make
- gcc-aarch64-linux-gnu
- bc
- bison
- flex
- libssl-dev
- libelf-dev
- libgnutls28-dev
- device-tree-compiler
- swig
- python3

## 使用方法

```bash
sudo ./build.sh
```

一键运行示例（需要 root 权限）：

```bash
sudo bash -c 'bash <(curl -fsSL "https://raw.githubusercontent.com/imengying/orangepi/refs/heads/main/build.sh")'
```

常用参数：

- `--image-size SIZE`：镜像大小，默认 `4G`
- `--suite SUITE`：Debian 发行版代号，默认 `trixie`
- `--arch ARCH`：目标架构，默认 `arm64`（当前仅支持 `arm64`）
- `--hostname HOSTNAME`：主机名，默认 `Orangepi`
- `--mirror MIRROR`：Debian 镜像源，默认 `http://mirrors.ustc.edu.cn/debian`
- `--output PATH`：输出镜像路径，默认 `./orangepi-zero2-debian13-trixie-btrfs.img`
- `--compress xz|none`：是否压缩，默认 `xz`
- `--workdir DIR`：工作目录，默认 `/tmp/opi-build-XXXX`
- `--jobs N`：并行编译线程数，默认 `nproc`
- `--kernel-repo URL`：Linux 内核仓库，默认 `https://github.com/torvalds/linux.git`
- `--kernel-ref REF`：Linux 内核分支/标签，默认 `v6.12.69`
- `--kernel-defconfig NAME`：内核配置目标，默认 `defconfig`
- `--uboot-repo URL`：U-Boot 仓库，默认 `https://github.com/u-boot/u-boot.git`
- `--uboot-ref REF`：U-Boot 分支/标签，默认 `v2025.01`
- `--atf-repo URL`：ARM Trusted Firmware 仓库，默认 `https://github.com/ARM-software/arm-trusted-firmware.git`
- `--atf-ref REF`：ARM Trusted Firmware 分支/标签，默认 `v2.12.0`

## 账号与密码

- 默认账号：`root`
- 默认密码：`orangepi`
- 如需修改默认密码，可使用参数：`--root-pass <PASSWORD>`

## 输出与烧录

输出规则（`--output` 与 `--compress`）：

- 默认 `--compress xz`，最终输出为 `--output` 对应文件的 `.xz`（默认 `orangepi-zero2-debian13-trixie-btrfs.img.xz`）。
- 当 `--compress none` 时，最终输出为 `--output` 原文件（默认 `orangepi-zero2-debian13-trixie-btrfs.img`）。

烧录示例（脚本不会直接写盘）：

```bash
xz -d orangepi-zero2-debian13-trixie-btrfs.img.xz
sudo dd if=orangepi-zero2-debian13-trixie-btrfs.img of=/dev/sdX bs=4M conv=fsync status=progress
```

> 注意：请将 `/dev/sdX` 替换为实际 SD 卡设备。
