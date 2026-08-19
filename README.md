# Orange Pi Zero 2 Debian 13 系统镜像

> 适用于 Orange Pi Zero 2 (Allwinner H616) 的 Debian 13 (Trixie) 自动化构建脚本

本仓库提供基于 **GitHub Actions** 的自动化构建流程，生成采用 **Btrfs 文件系统** 的 **Debian 13 (Trixie)** Arm64 启动镜像。

---

## ✨ 特性

- **自动化构建**：利用 GitHub Actions 全自动构建，流程透明可追溯
- **纯净系统**：基于 `debootstrap` 构建的原生 Debian 13 (Trixie) rootfs，无多余预装
- **Linux 内核**：自动解析并集成 Linux 7.1 系列最新补丁版本 + Armbian H616/Zero 2 板级补丁
- **U‑Boot 2026.07**：主线 U‑Boot 稳定版本，与 Armbian sunxi64 配置一致
- **TF‑A 2.12 LTS**：`lts-v2.12.9` 固件版本
- **Btrfs 根分区**：默认使用 Btrfs，支持 ZSTD 透明压缩和快照功能
- **首次启动自动扩容**：根分区自动扩展至整张 TF 卡可用空间
- **ZRAM 内存压缩**：默认启用 `lz4` 算法，优化小内存设备性能
- **有线网络**：NetworkManager 管理 `end0`，默认通过 DHCP 即插即用
- **精简硬件支持**：不集成 WiFi、蓝牙、GPU、音频及媒体驱动
- **LED 状态指示**：进入 Linux 后绿灯 heartbeat 闪烁、红灯熄灭，由内核设备树直接定义

---

## 📥 系统烧录 (dd)

构建完成后，会生成 `.img.xz` 压缩镜像文件。按以下步骤烧录至 TF 卡：

### 1. 解压镜像

```bash
xz -d orangepi-zero2-debian-*.img.xz
```

### 2. 确认目标设备

插入 TF 卡后，使用 `lsblk` 或 `fdisk -l` 确认设备路径（如 `/dev/sdb`，**务必核对，避免误写硬盘**）。

### 3. 使用 dd 烧录

```bash
sudo dd if=orangepi-zero2-debian-*.img of=/dev/sdX bs=4M status=progress conv=fsync
```

> 将 `/dev/sdX` 替换为实际 TF 卡设备路径。`bs=4M` 加快写入速度，`conv=fsync` 确保数据完整落盘。

### 4. 验证（可选）

烧录完成后，重新插拔 TF 卡，用 `lsblk` 检查分区是否正常识别。

---

## 💾 系统备份 (dd)

### 整卡备份（完整镜像）

将 TF 卡插入读卡器，确认设备路径后执行：

```bash
sudo dd if=/dev/sdX of=backup-$(date +%Y%m%d).img bs=4M status=progress
```

生成的 `.img` 文件可直接用 dd 恢复到另一张同容量或更大的 TF 卡。

### 单分区备份（如 root 分区）

例如备份 Btrfs root 分区 `/dev/sdX2`：

```bash
sudo dd if=/dev/sdX2 of=rootfs-backup.img bs=4M status=progress
```

### 压缩备份

通过管道直接压缩，节省存储空间：

```bash
sudo dd if=/dev/sdX bs=4M status=progress | gzip -c > backup-$(date +%Y%m%d).img.gz
```

恢复压缩镜像：

```bash
gunzip -c backup-20260819.img.gz | sudo dd of=/dev/sdX bs=4M status=progress
```

将 `backup-20260819.img.gz` 替换为实际要恢复的单个备份文件，避免通配符同时匹配多个备份。

> ⚠️ **注意**：使用 dd 恢复时，目标设备容量必须大于或等于源镜像大小。

---

## 🔄 一键更新内核

每次构建会额外生成 `orangepi-zero2-kernel-*-update.tar.xz` 更新包，便于已安装系统升级内核。

在 Orange Pi Zero 2 上下载并解压后执行：

```bash
tar -xf orangepi-zero2-kernel-*-update.tar.xz
cd orangepi-zero2-kernel-*-update
sudo ./install.sh
sudo reboot
```

更新包将替换 `/boot` 中的内核、initrd、设备树、内核配置及 `/lib/modules/<版本>`，**不会改写 U‑Boot 或分区表**。

安装脚本自动将旧版本备份至 `/root/orangepi-kernel-backup-*.tar.xz`。确认新内核正常后，可运行以下脚本清理：

```bash
# 清理旧内核及备份包
/root/cleanup-kernel-backups.sh

# 仅清理旧内核，保留备份包
/root/cleanup-kernel-backups.sh no
```

---

## ⚙️ 构建参数

脚本支持通过环境变量或命令行参数自定义构建，**命令行参数优先级更高**：

主机名可通过 `IMAGE_HOSTNAME` 环境变量或 `--hostname` 参数设置，例如
`IMAGE_HOSTNAME=orangepi ./build.sh`。脚本不会读取构建主机自身的 `HOSTNAME`，避免 CI Runner 名称写入镜像。

| 参数 | 说明 | 默认值 |
|---|---|---|
| `--image-size` | 镜像文件大小 | `3G` |
| `--suite` | Debian 发行版代号 | `trixie` |
| `--arch` | 目标架构（当前仅支持 `arm64`） | `arm64` |
| `--hostname` | 系统主机名 | `orangepi` |
| `--mirror` | Apt 镜像源地址 | `http://mirrors.ustc.edu.cn/debian` |
| `--output` | 未压缩镜像输出路径 | `./orangepi-zero2-debian13-trixie-btrfs.img` |
| `--compress` | 压缩输出 (`xz` / `none`) | `xz` |
| `--update-bundle` | 是否生成内核更新包 (`auto`/`yes`/`no`) | `auto` |
| `--debootstrap-keyring` | Debian archive keyring 路径 | `/usr/share/keyrings/debian-archive-keyring.gpg` |
| `--workdir` | 构建工作目录 | 自动创建临时目录 |
| `--kernel-repo` | Linux 内核仓库地址 | `https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git` |
| `--kernel-ref` | Linux 内核分支/标签；`7.1` 自动解析最新 `v7.1.x` | `7.1` |
| `--kernel-defconfig` | 内核默认配置名 | `defconfig` |
| `--uboot-repo` | U-Boot 仓库地址 | `https://github.com/u-boot/u-boot.git` |
| `--uboot-ref` | U‑Boot 分支/标签 | `v2026.07` |
| `--atf-repo` | TF-A 仓库地址 | `https://github.com/ARM-software/arm-trusted-firmware.git` |
| `--atf-ref` | TF‑A 分支/标签 | `lts-v2.12.9` |
| `--jobs` | 并行编译任务数 | `$(nproc)` |
| `--root-pass` | Root 用户密码 | `orangepi` |

---

## 📋 默认配置

### 账号与系统

- **用户**：`root`
- **密码**：`orangepi`
- **语言环境**：`en_US.UTF-8`
- **时区**：`Asia/Shanghai`
- **分区**：`/boot` (FAT32, 128MB) + `/` (Btrfs 子卷 `@`, 剩余空间)

> **安全提示**：镜像默认允许 root 通过 SSH 使用密码登录，默认密码为 `orangepi`。接入网络前，请使用 `--root-pass` 设置自定义密码，或登录后立即修改 root 密码。

### 网络

- 有线网卡 `end0` 默认 DHCP 获取 IP
- WiFi、蓝牙、GPU、音频和媒体驱动未编译，也不安装相关用户态组件

```bash
# 配置静态 IP（示例）
nmcli connection modify Wired-end0 ipv4.method manual \
    ipv4.addresses 192.168.1.100/24 \
    ipv4.gateway 192.168.1.1 \
    ipv4.dns 8.8.8.8
nmcli connection up Wired-end0
```

### 其他

- **LED 状态灯**：进入 Linux 后绿灯（PC13）按 heartbeat 闪烁、红灯（PC12）熄灭；U-Boot 启动阶段的灯态可能不同
- **ZRAM**：默认启用，`lz4` 算法，内存上限 40%，配置文件 `/etc/default/zramswap`

---

## 硬件支持范围

由于这些闭源适配比较麻烦，所以镜像排除以下组件：

- UWE5622 WiFi/蓝牙设备树节点及电源时序
- UWE5622、`sprdwl_ng`、`tty-sdio`、`sunxi-addr` 驱动
- UWE5622 固件、`wpasupplicant`、`wireless-regdb` 和 `rfkill`
- Mali GPU、DRM、ALSA、V4L2、红外、NFC、CAN、WWAN 及 staging 驱动
- 非 Allwinner ARM64 平台、PCI/ACPI/KVM/Xen、VirtIO、SPI-NOR 和普通 I²C
- 网络桥接、DSA/VLAN、USB 网卡、MHI、Type-C/UCSI 及非 RTL8211 PHY
- UFS、ChromeOS/Google 固件、RPMsg、Greybus、FPGA、IIO、性能追踪和其它 SoC 专用外设
- 32 位用户态兼容及非 ZSTD initramfs 解压格式

---

## 📄 License

本项目基于 [MIT License](https://github.com/imengying/orangepi/blob/main/LICENSE) 开源。
