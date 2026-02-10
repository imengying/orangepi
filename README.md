# Orange Pi Zero 2 Debian 13 Btrfs 镜像构建脚本

本仓库用于在 x86_64 Debian/Ubuntu 环境中，构建 Orange Pi Zero 2 (Allwinner H616) 的 Debian 13 (trixie) arm64 启动镜像。

## 快速开始

```bash
sudo ./build.sh
```

在线一键执行（root）：

```bash
sudo bash -c 'bash <(curl -fsSL "https://raw.githubusercontent.com/imengying/orangepi/refs/heads/main/build.sh")'
```

## 默认行为

- 使用 `debootstrap` 构建 Debian 13 (`trixie`) arm64 rootfs。
- 全自编译 ATF、U-Boot、Linux 内核。
- 内核默认跟踪 `6.12` 系列并自动解析最新 `v6.12.x` 补丁。
- 分区布局：`/boot` 为 FAT32（约 128MiB），`/` 为 btrfs（其余空间）。
- 首次启动自动扩容 `mmcblk0p2` 并扩展 btrfs。
- 网络使用 NetworkManager，默认仅有线网卡 `end0`。
- 默认不编译无线驱动，并移除 WiFi/蓝牙固件。
- LED 默认：绿灯 `heartbeat`，红灯关闭。
- zram 默认：`PERCENT=40`、`ALGO=lz4`。

## 常用参数

- `--image-size SIZE`：镜像大小，默认 `3G`
- `--suite SUITE`：Debian 发行版，默认 `trixie`
- `--arch ARCH`：目标架构，默认 `arm64`（当前仅支持 `arm64`）
- `--hostname HOSTNAME`：主机名，默认 `orangepi`
- `--mirror MIRROR`：Debian 镜像源，默认 `http://mirrors.ustc.edu.cn/debian`
- `--output PATH`：输出镜像路径，默认 `./orangepi-zero2-debian13-trixie-btrfs.img`
- `--compress xz|none`：是否压缩，默认 `xz`
- `--workdir DIR`：工作目录，默认 `/tmp/opi-build-XXXX`
- `--jobs N`：并行编译线程数，默认 `nproc`
- `--kernel-repo URL`：内核仓库，默认 `https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git`
- `--kernel-ref REF`：内核分支/标签，默认 `6.12`（自动解析到最新 `v6.12.x`）
- `--kernel-defconfig NAME`：内核配置目标，默认 `defconfig`
- `--uboot-repo URL`：U-Boot 仓库，默认 `https://github.com/u-boot/u-boot.git`
- `--uboot-ref REF`：U-Boot 版本，默认 `v2025.01`
- `--atf-repo URL`：ATF 仓库，默认 `https://github.com/ARM-software/arm-trusted-firmware.git`
- `--atf-ref REF`：ATF 版本，默认 `v2.12.0`
- `--root-pass PASSWORD`：root 密码，默认 `orangepi`

## 输出文件

- `--compress xz`（默认）：输出 `*.img.xz`
- `--compress none`：输出 `*.img`

## 系统默认账号

- 用户：`root`
- 密码：`orangepi`
- 时区：`Asia/Shanghai`

修改时区示例：

```bash
# 查看可用时区
timedatectl list-timezones

# 设置时区（示例）
timedatectl set-timezone UTC
```

## 网络配置

系统默认通过 `end0` 使用 DHCP。

手动配置静态 IP：

```bash
nmcli connection modify Wired-end0 ipv4.method manual ipv4.addresses 192.168.1.100/24 ipv4.gateway 192.168.1.1 ipv4.dns 8.8.8.8
nmcli connection up Wired-end0
```

## LED 控制

```bash
# 查看所有 LED
led-control show

# 绿灯心跳 + 红灯关闭（默认）
led-control heartbeat

# 全灯心跳（可选）
led-control all-heartbeat

# 全部关闭
led-control off

# 常亮
led-control on
```

## zram 配置

当前默认配置文件：`/etc/default/zramswap`

```bash
PERCENT=40
ALGO=lz4
PRIORITY=100
```

查看状态：

```bash
zramctl
swapon --show
free -h
```

重启服务：

```bash
systemctl restart zramswap
```
