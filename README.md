# BBR 一键脚本

在 Linux 上打开内核自带的 BBR。公网 VPS 和 NAT 都能用。脚本先认出系统、是不是切出来的机器、缺哪些命令和内核模块，缺的就从这台机器自己的软件源安装，然后打开 BBR。

已经开好的机器再运行一次也安全：会把已经装上的 `bbr` 命令更新到新版本，并核对开机配置。不会自动重启，不会更换别人改过的内核，也不会改防火墙。连不上发布地址时，仍用当前这份继续。

## 安装（root，一行）

```sh
sh -c 'c(){ command -v "$1" >/dev/null 2>&1; }; run_pm(){ if [ "$(id -u)" -eq 0 ]; then env DEBIAN_FRONTEND=noninteractive "$@" 2>/dev/null; elif c sudo; then sudo env DEBIAN_FRONTEND=noninteractive "$@" 2>/dev/null; else return 1; fi; }; c curl || c wget || { for pm in "apk add --no-cache" "apt-get install -y" "dnf install -y" "yum install -y" "pacman -Sy --noconfirm" "zypper --non-interactive install" "opkg install" "xbps-install -Sy"; do b=${pm%% *}; c "$b" || continue; [ "$b" = apt-get ] && run_pm apt-get update -qq; [ "$b" = opkg ] && run_pm opkg update; run_pm $pm ca-certificates; run_pm $pm curl || run_pm $pm wget || run_pm $pm wget-ssl; break; done; c curl || c wget || { echo "装不上 curl / wget，请手动装一个"; exit 1; }; }; f=$(mktemp "${TMPDIR:-/tmp}/bbr-install.XXXXXX") || exit 1; trap "rm -f \"\$f\"" EXIT; trap "rm -f \"\$f\"; exit 130" INT; trap "rm -f \"\$f\"; exit 143" TERM; wt=""; c wget && wget --help 2>&1 | grep -q -- "--tries" && wt="-t 1"; ok=""; for u in https://raw.githubusercontent.com/imthnio/vps-bbr/main/install.sh https://cdn.jsdelivr.net/gh/imthnio/vps-bbr@main/install.sh; do ( (c curl && curl -fsSL --connect-timeout 8 --max-time 20 -o "$f" "$u") || (c wget && wget -qO "$f" -T 15 $wt "$u") ) 2>/dev/null && [ -s "$f" ] && head -n 1 "$f" | grep -q "^#!/bin/sh\$" && grep -q "bbr-onekey-begin" "$f" && { ok=1; break; }; : > "$f"; done; [ -n "$ok" ] || { echo "下载 install.sh 失败，请检查网络"; exit 1; }; sh "$f"'
```

## 赞赏支持

如果这个脚本帮到了你，欢迎请我喝杯咖啡。

![赞赏码](./appreciate.png)
