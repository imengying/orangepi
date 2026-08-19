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
- **无线与网络**：集成 UWE5622 2.4GHz WiFi 固件与 NetworkManager，有线 DHCP 即插即用
- **LED 状态指示**：红灯心跳、绿灯常亮，由内核设备树直接定义

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
gunzip -c backup-*.img.gz | sudo dd of=/dev/sdX bs=4M status=progress
```

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

更新包将替换 `/boot` 中的内核、initrd、设备树、内核配置、`/lib/modules/<版本>` 及 UWE5622 固件，**不会改写 U‑Boot 或分区表**。

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

| 参数 | 说明 | 默认值 |
|---|---|---|
| `--image-size` | 镜像文件大小 | `3G` |
| `--suite` | Debian 发行版代号 | `trixie` |
| `--arch` | 目标架构 | `arm64` |
| `--hostname` | 系统主机名 | `orangepi` |
| `--mirror` | Apt 镜像源地址 | `http://mirrors.ustc.edu.cn/debian` |
| `--compress` | 压缩输出 (`xz` / `none`) | `xz` |
| `--update-bundle` | 是否生成内核更新包 (`auto`/`yes`/`no`) | `auto` |
| `--kernel-ref` | Linux 内核分支/标签 | `7.1` |
| `--uboot-ref` | U‑Boot 分支/标签 | `v2026.07` |
| `--atf-ref` | TF‑A 分支/标签 | `lts-v2.12.9` |
| `--root-pass` | Root 用户密码 | `orangepi` |

---

## 📋 默认配置

### 账号与系统

- **用户**：`root`
- **密码**：`orangepi`
- **语言环境**：`en_US.UTF-8`
- **时区**：`Asia/Shanghai`
- **分区**：`/boot` (FAT32, 128MB) + `/` (Btrfs 子卷 `@`, 剩余空间)

### 网络

- 有线网卡 `end0` 默认 DHCP 获取 IP
- UWE5622 WiFi (2.4GHz) 已启用，可通过 NetworkManager 连接

```bash
# 扫描 WiFi
nmcli device wifi list

# 连接 WiFi
nmcli device wifi connect "网络名称" password "无线密码"

# 配置静态 IP（示例）
nmcli connection modify Wired-end0 ipv4.method manual \
    ipv4.addresses 192.168.1.100/24 \
    ipv4.gateway 192.168.1.1 \
    ipv4.dns 8.8.8.8
nmcli connection up Wired-end0
```

### 其他

- **LED 状态灯**：红灯心跳，绿灯常亮
- **ZRAM**：默认启用，`lz4` 算法，内存上限 40%，配置文件 `/etc/default/zramswap`

---

## 📶 无线支持

镜像集成了 Armbian 针对 UWE5622 芯片的驱动方案：

- 内核使用固定版本的板外驱动
- 设备树包含 SDIO、电源及复位时序
- 固件在构建时按 SHA256 校验后安装至 `/lib/firmware/uwe5622/`

> 该芯片提供 2.4GHz 802.11b/g/n WiFi，驱动及固件属于社区维护的板外组件，非 Linux 主线驱动。蓝牙驱动源码虽已编译，但本镜像暂未配置蓝牙串口附着服务。

---

## 📄 License

本项目基于 [MIT License](https://github.com/imengying/orangepi/blob/main/LICENSE) 开源。

