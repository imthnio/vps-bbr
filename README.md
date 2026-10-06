# BBR 一键脚本

在 Linux 上打开内核自带的 BBR。公网 VPS 和 NAT 都能用。脚本先认出系统、是不是切出来的机器、缺哪些命令和内核模块，缺的就从这台机器自己的软件源安装，然后打开 BBR。

已经开好的机器再运行一次也安全：会把已经装上的 `bbr` 命令更新到新版本，并核对开机配置。不会自动重启，不会更换别人改过的内核，也不会改防火墙。连不上发布地址时，仍用当前这份继续。

## 安装（root，一行）

```sh
sh -c 'c(){ command -v "$1" >/dev/null 2>&1; }; c curl || c wget || { for pm in "apk add --no-cache" "apt-get install -y" "dnf install -y" "yum install -y" "pacman -Sy --noconfirm" "zypper --non-interactive install" "opkg install"; do b=${pm%% *}; c $b || continue; [ "$b" = apt-get ] && { apt-get update -qq 2>/dev/null || sudo apt-get update -qq 2>/dev/null; }; $pm curl wget ca-certificates 2>/dev/null || sudo $pm curl wget ca-certificates 2>/dev/null; break; done; c curl || c wget || { echo "装不上 curl / wget，请手动装一个"; exit 1; }; }; ok=""; for u in https://raw.githubusercontent.com/imthnio/vps-bbr/main/install.sh https://cdn.jsdelivr.net/gh/imthnio/vps-bbr@main/install.sh; do (wget -qO /tmp/bbr-install.sh "$u" || curl -fsSL -o /tmp/bbr-install.sh "$u") 2>/dev/null && [ -s /tmp/bbr-install.sh ] && head -n 1 /tmp/bbr-install.sh | grep -q "^#!/bin/sh" && { ok=1; break; }; rm -f /tmp/bbr-install.sh; done; [ -n "$ok" ] || { echo "下载 install.sh 失败，请检查网络"; exit 1; }; sh /tmp/bbr-install.sh'
```

## 赞赏支持

如果这个脚本帮到了你，欢迎请我喝杯咖啡。

![赞赏码](./appreciate.png)
