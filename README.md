# 香橙派 Zero 2 (Orange Pi Zero 2) Debian 13 系统镜像构建脚本

本仓库为 **香橙派 Zero 2 (Orange Pi Zero 2 / Allwinner H616)** 设计，提供了一套基于 **GitHub Actions** 的自动化构建流程，用于生成采用 **Btrfs 文件系统** 的 **Debian 13 (Trixie)** Arm64 启动镜像。

## ✨ 项目特性

* **自动化构建**：利用 GitHub Actions 实现全自动构建，流程透明可追溯。
* **纯净系统**：基于 `debootstrap` 构建的原生 Debian 13 (`trixie`) rootfs，无多余预装。
* **Linux 7.1 内核**：构建时自动解析 Linux 7.1 系列的最新补丁版本，并集成 Armbian 的 H616/Zero 2 板级补丁。
* **U-Boot 2026.07**：使用与 Armbian sunxi64 当前配置一致的主线 U-Boot 稳定版本。
* **Btrfs 根分区**：默认使用 Btrfs 文件系统，支持透明压缩 (ZSTD) 和快照功能。
* **开箱即用**：
    * 首次启动自动扩容根分区。
    * 集成 `zram` 内存压缩 (lz4)，优化小内存设备性能。
    * 集成 UWE5622 2.4 GHz WiFi、固件和 NetworkManager 网络管理。
    * 红灯心跳、绿灯常亮由内核设备树直接定义。

## 🚀 快速开始 (GitHub Actions)

推荐使用 GitHub Actions 进行构建：

1.  **Fork 本仓库** 到你的 GitHub 账号。
2.  本地创建并推送一个 Tag（发布构建）：

```bash
git tag v2026.02.10
git push origin v2026.02.10
```

3.  打开仓库 **Actions**，查看 `Build And Release OrangePi Image` 工作流进度。
4.  构建完成后，在 **Releases** 或 **Artifacts** 下载 `.img.xz` 镜像。

如只想临时测试构建，可在 Actions 页面手动 `Run workflow`，该模式仅上传 Artifacts，不发布 Release。

## 🔄 已安装系统一键更新内核

每次构建除完整 `.img.xz` 镜像外，还会生成一个 `orangepi-zero2-kernel-*-update.tar.xz` 更新包，用于更新已经安装好的系统。

在 Orange Pi Zero 2 上下载并解压更新包后执行：

```bash
tar -xf orangepi-zero2-kernel-*-update.tar.xz
cd orangepi-zero2-kernel-*-update
sudo ./install.sh
sudo reboot
```

更新包会替换 `/boot` 中的内核、initrd、设备树、内核配置、`/lib/modules/<版本>` 和 UWE5622 固件，不会改写 U-Boot 或重新分区。安装脚本会把旧版本备份打包到 `/root/orangepi-kernel-backup-*.tar.xz`。

确认新内核正常启动后，可执行 `/root/cleanup-kernel-backups.sh` 清理旧版本。脚本只保留当前 `uname -r` 正在使用的内核模块和 `/boot` 版本文件，并默认删除 `/root/orangepi-kernel-backup-*.tar.xz` 备份包；如需保留备份包可执行 `/root/cleanup-kernel-backups.sh no`。

## 💻 本地构建 (可选)

如果你拥有 Linux (x86_64) 环境（如 Debian/Ubuntu），也可以手动运行脚本进行测试：

```bash
# 克隆仓库
git clone https://github.com/imengying/orangepi.git
cd orangepi

# 安装必要依赖 (仅供参考，具体视环境而定)
sudo apt update && sudo apt install -y \
  debootstrap debian-archive-keyring qemu-user-static parted util-linux dosfstools btrfs-progs \
  rsync tar xz-utils git make gcc-aarch64-linux-gnu bc bison flex openssl \
  libssl-dev device-tree-compiler swig python3 curl

# 开始构建
sudo ./build.sh

```

## ⚙️ 构建参数说明

脚本支持通过同名环境变量或命令行参数进行自定义，命令行参数优先：

| 参数 | 说明 | 默认值 |
| --- | --- | --- |
| `--image-size` | 镜像文件大小 | `3G` |
| `--suite` | Debian 发行版代号 | `trixie` |
| `--arch` | 目标架构 | `arm64` |
| `--hostname` | 系统主机名 | `orangepi` |
| `--mirror` | Apt 镜像源地址 | `http://mirrors.ustc.edu.cn/debian` |
| `--compress` | 压缩输出 (`xz` 或 `none`) | `xz` |
| `--update-bundle` | 是否生成已安装系统内核更新包 (`auto`/`yes`/`no`) | `auto` |
| `--debootstrap-keyring` | debootstrap 验签使用的 Debian archive keyring | `/usr/share/keyrings/debian-archive-keyring.gpg` |
| `--kernel-ref` | Linux 内核分支/标签；`7.1` 会自动解析最新的 `v7.1.x` | `7.1` |
| `--uboot-ref` | U-Boot 分支/标签 | `v2026.07` |
| `--root-pass` | Root 用户密码 | `orangepi` |

## 📝 镜像默认配置

### 账号与系统

* **用户**: `root`
* **密码**: `orangepi`
* **语言环境**: `en_US.UTF-8`
* **时区**: `Asia/Shanghai`
* **分区**: `/boot` (FAT32, 128MB), `/` (Btrfs 子卷 `@`, 剩余空间)

### 网络连接

默认通过 `end0` (有线网卡) 使用 DHCP 获取 IP。

UWE5622 WiFi 默认启用（2.4 GHz），可以使用 NetworkManager 连接无线网络：

```bash
nmcli device wifi list
nmcli device wifi connect "网络名称" password "无线密码"
```

**静态 IP 配置示例：**

```bash
nmcli connection modify Wired-end0 ipv4.method manual \
    ipv4.addresses 192.168.1.100/24 \
    ipv4.gateway 192.168.1.1 \
    ipv4.dns 8.8.8.8
nmcli connection up Wired-end0

```

### LED 状态灯

* **红灯**: 心跳模式
* **绿灯**: 电源常亮

### ZRAM 内存优化

默认启用 ZRAM，使用 `lz4` 算法压缩，占用内存上限为 40%。配置文件位于 `/etc/default/zramswap`。

## 无线支持

镜像集成 Armbian 当前的 UWE5622 驱动方案：内核使用固定版本的板外驱动，设备树包含 SDIO、电源和复位时序，固件在构建时按 SHA256 校验后安装到 `/lib/firmware/uwe5622/`。

该芯片提供 2.4 GHz 802.11b/g/n WiFi。驱动和固件属于社区维护的板外组件，不是 Linux 主线驱动；蓝牙驱动源码会随内核编译，但本项目暂未配置蓝牙串口附着服务。

## 📜 License

本项目基于 [MIT License](LICENSE) 开源。

```text
MIT License

Copyright (c) 2024 Mengying

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

```
