# BBR 一键脚本

在 Linux 上打开内核自带的 BBR。公网 VPS 和 NAT 都能用。脚本先认出系统、是不是切出来的机器、缺哪些命令和内核模块，缺的就从这台机器自己的软件源安装，然后打开 BBR。

已经开好的机器再运行一次也安全：会把已经装上的 `bbr` 命令更新到新版本，并核对开机配置。不会自动重启，不会更换别人改过的内核，也不会改防火墙。连不上发布地址时，仍用当前这份继续。

## 安装（root，一行）

```sh
sh -c 'c(){ command -v "$1" >/dev/null 2>&1; }; c curl || c wget || { for pm in "apk add --no-cache" "apt-get install -y" "dnf install -y" "yum install -y" "pacman -Sy --noconfirm" "zypper --non-interactive install" "opkg install"; do b=${pm%% *}; c $b || continue; [ "$b" = apt-get ] && { apt-get update -qq 2>/dev/null || sudo apt-get update -qq 2>/dev/null; }; $pm curl wget ca-certificates 2>/dev/null || sudo $pm curl wget ca-certificates 2>/dev/null; break; done; c curl || c wget || { echo "装不上 curl / wget，请手动装一个"; exit 1; }; }; ok=""; for u in https://raw.githubusercontent.com/imthnio/vps-bbr/main/install.sh https://cdn.jsdelivr.net/gh/imthnio/vps-bbr@main/install.sh; do (wget -qO /tmp/bbr-install.sh "$u" || curl -fsSL -o /tmp/bbr-install.sh "$u") 2>/dev/null && [ -s /tmp/bbr-install.sh ] && head -n 1 /tmp/bbr-install.sh | grep -q "^#!/bin/sh" && { ok=1; break; }; rm -f /tmp/bbr-install.sh; done; [ -n "$ok" ] || { echo "下载 install.sh 失败，请检查网络"; exit 1; }; sh /tmp/bbr-install.sh'
```

一行会先确认有 curl 或 wget，没有就用系统软件源装上，再从 GitHub 和 jsDelivr 里挑一个能用的地址下载。

## 它会自己看什么

- 系统：Debian、Ubuntu 及其衍生版、CentOS / RHEL / Rocky / Alma / Fedora、Alpine、Arch、openSUSE、OpenWrt、Void。认不出包管理器时，只要内核里已经有 BBR，也会直接打开。
- 机器：KVM、独立服务器用自己的内核。OpenVZ、LXC、Docker 这类跟母鸡共用内核，能开就开，开不了会说明原因，不会在里面硬装新内核。
- 网络：公网还是 NAT。两种都照常打开，BBR 改的是这台机器自己怎么发数据。
- 缺的命令：`sysctl`、`modprobe`、`ip`、`tc`。
- 缺的内核模块：`tcp_bbr` 和队列 `sch_fq`。当前内核能装就装。内核太旧或编译时没带 BBR，而且这台机器有自己的内核时，才安装系统仓库里的新内核。装完也不重启。

## 其它命令

```sh
bbr --status    # 只查看
bbr --off       # 关掉本脚本打开的 BBR
```

第一次成功之后，可以直接输入 `bbr`。已经装过的服务器，再执行一次上面的安装命令，或者直接输入 `bbr`，都会先更新脚本，再核对 BBR。

新连接马上走 BBR。已经连着的连接要断开重连才换。IPv4 和 IPv6 的 TCP 都生效。

## 赞赏支持

如果这个脚本帮到了你，欢迎请我喝杯咖啡。

![赞赏码](./appreciate.png)
