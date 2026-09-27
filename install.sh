#!/bin/sh
#======================================================================
# BBR 一键脚本
#----------------------------------------------------------------------
# 在 VPS 上打开 Linux 内核自带的 BBR 加速。
# 公网 VPS 和 NAT 都能用。Debian / Ubuntu / CentOS / Alpine / Arch /
# openSUSE / OpenWrt 以及它们的同源系统会自动认出来。
# 独立内核（KVM 这类）缺了模块就从系统自己的软件源装。
# 切出来的机器（OpenVZ、LXC、Docker）跟母鸡共用内核，能开就开，
# 开不了会说明原因，不会在小鸡里面硬装一个新内核。
#
# 不重启，不更换别人改过的内核，不改防火墙。
# 再运行一次是安全的：已经开好的机器只会核对开机配置。
#
#   sh install.sh           打开 BBR
#   sh install.sh --status  只查看
#   sh install.sh --off     关掉本脚本打开的 BBR
#======================================================================

VERSION=1.0.0

if [ -t 1 ]; then
  C_RED=$(printf '\033[0;31m')
  C_GREEN=$(printf '\033[0;32m')
  C_YELLOW=$(printf '\033[1;33m')
  C_BLUE=$(printf '\033[0;34m')
  C_NC=$(printf '\033[0m')
else
  C_RED=''
  C_GREEN=''
  C_YELLOW=''
  C_BLUE=''
  C_NC=''
fi

say_ok()   { printf '%s\n' "${C_GREEN}✓ $*${C_NC}"; }
say_info() { printf '%s\n' "${C_BLUE}$*${C_NC}"; }
say_warn() { printf '%s\n' "${C_YELLOW}! $*${C_NC}"; }
say_err()  { printf '%s\n' "${C_RED}✗ $*${C_NC}" >&2; }
say_step() { printf '\n%s\n' "${C_YELLOW}>>> $*${C_NC}"; }

#----------------------------------------------------------------------
# 纯判断。测试会直接调用这些函数，不要在这里访问系统。
#----------------------------------------------------------------------

kernel_numeric() {
  printf '%s\n' "$1" | sed 's/[^0-9.].*$//' | sed 's/\.$//'
}

version_ge() {
  a=$(kernel_numeric "$1")
  b=$(kernel_numeric "$2")
  [ -n "$a" ] || return 1
  [ -n "$b" ] || return 1
  i=1
  while [ "$i" -le 3 ]; do
    pa=$(printf '%s\n' "$a" | cut -d. -f"$i")
    pb=$(printf '%s\n' "$b" | cut -d. -f"$i")
    pa=$(printf '%s' "$pa" | sed 's/[^0-9].*$//; s/^0*//')
    pb=$(printf '%s' "$pb" | sed 's/[^0-9].*$//; s/^0*//')
    [ -n "$pa" ] || pa=0
    [ -n "$pb" ] || pb=0
    if [ "$pa" -gt "$pb" ]; then return 0; fi
    if [ "$pa" -lt "$pb" ]; then return 1; fi
    i=$((i + 1))
  done
  return 0
}

is_ipv4() {
  ip=${1%%/*}
  oldifs=$IFS
  IFS=.
  # 仅按点拆开。调用方的参数在函数返回后会还原。
  set -- $ip
  IFS=$oldifs
  [ "$#" -eq 4 ] || return 1
  for n in "$1" "$2" "$3" "$4"; do
    case $n in
      ''|*[!0-9]*) return 1 ;;
    esac
    n=$(printf '%s' "$n" | sed 's/^0*//')
    [ -n "$n" ] || n=0
    [ "$n" -le 255 ] || return 1
  done
  return 0
}

is_private_ipv4() {
  is_ipv4 "$1" || return 1
  ip=${1%%/*}
  oldifs=$IFS
  IFS=.
  set -- $ip
  IFS=$oldifs
  a=$(printf '%s' "$1" | sed 's/^0*//')
  b=$(printf '%s' "$2" | sed 's/^0*//')
  [ -n "$a" ] || a=0
  [ -n "$b" ] || b=0
  [ "$a" -eq 0 ] && return 0
  [ "$a" -eq 10 ] && return 0
  [ "$a" -eq 127 ] && return 0
  [ "$a" -eq 169 ] && [ "$b" -eq 254 ] && return 0
  [ "$a" -eq 192 ] && [ "$b" -eq 168 ] && return 0
  if [ "$a" -eq 172 ] && [ "$b" -ge 16 ] && [ "$b" -le 31 ]; then
    return 0
  fi
  if [ "$a" -eq 100 ] && [ "$b" -ge 64 ] && [ "$b" -le 127 ]; then
    return 0
  fi
  return 1
}

# 打印 public / nat / ipv6 / unknown
network_kind() {
  locals=$1
  ipv6s=$2
  has_public=0
  has_private=0
  for ip in $locals; do
    if is_ipv4 "$ip"; then
      if is_private_ipv4 "$ip"; then
        has_private=1
      else
        has_public=1
      fi
    fi
  done
  if [ "$has_public" = 1 ]; then
    printf '%s\n' public
    return 0
  fi
  if [ "$has_private" = 1 ]; then
    printf '%s\n' nat
    return 0
  fi
  for ip in $ipv6s; do
    case $ip in
      ''|fe80:*|FE80:*|fc*|FC*|fd*|FD*|::1) continue ;;
      *:*) printf '%s\n' ipv6; return 0 ;;
    esac
  done
  printf '%s\n' unknown
}

# 参数：容器类型、虚拟机类型。打印「1 名称」或「0 名称」。
# 1 表示跟母鸡共用内核。
classify_virt() {
  container=$1
  vm=$2
  case $container in
    docker|podman|lxc|lxc-libvirt|openvz|systemd-nspawn|wsl|container|rkt|crio)
      printf '1 %s\n' "$container"
      return 0
      ;;
  esac
  case $vm in
    ''|none) printf '0 none\n' ;;
    *) printf '0 %s\n' "$vm" ;;
  esac
}

virt_phrase() {
  shared=$1
  name=$2
  case $name in
    openvz) printf '%s\n' "OpenVZ，切出来的，跟母鸡共用内核" ;;
    lxc|lxc-libvirt) printf '%s\n' "LXC，切出来的，跟母鸡共用内核" ;;
    docker|podman|rkt|crio) printf '%s\n' "容器，跟母鸡共用内核" ;;
    systemd-nspawn) printf '%s\n' "容器，跟母鸡共用内核" ;;
    wsl) printf '%s\n' "WSL，跟母鸡共用内核" ;;
    container) printf '%s\n' "切出来的机器，跟母鸡共用内核" ;;
    kvm|qemu) printf '%s\n' "KVM 虚拟机，自己的内核" ;;
    xen) printf '%s\n' "Xen 虚拟机，自己的内核" ;;
    vmware) printf '%s\n' "VMware 虚拟机，自己的内核" ;;
    microsoft) printf '%s\n' "Hyper-V 虚拟机，自己的内核" ;;
    amazon) printf '%s\n' "云主机，自己的内核" ;;
    google) printf '%s\n' "云主机，自己的内核" ;;
    oracle) printf '%s\n' "云主机，自己的内核" ;;
    none)
      if [ "$shared" = 1 ]; then
        printf '%s\n' "切出来的机器，跟母鸡共用内核"
      else
        printf '%s\n' "独立机器，自己的内核"
      fi
      ;;
    *)
      if [ "$shared" = 1 ]; then
        printf '%s\n' "$name，跟母鸡共用内核"
      else
        printf '%s\n' "$name，自己的内核"
      fi
      ;;
  esac
}

network_phrase() {
  kind=$1
  locals=$2
  egress=$3
  case $kind in
    public)
      printf '公网（%s）\n' "$locals"
      ;;
    nat)
      if [ -n "$egress" ]; then
        printf 'NAT（网卡 %s，出口 %s）\n' "$locals" "$egress"
      else
        printf 'NAT（网卡 %s）\n' "$locals"
      fi
      ;;
    ipv6)
      printf '有公网 IPv6（%s）\n' "$locals"
      ;;
    *)
      printf '%s\n' "没判断出是公网还是 NAT，不影响打开 BBR"
      ;;
  esac
}

# on：fq 保持，常见默认队列换成 fq，mq 换子队列，cake/htb 不动。
# off：只把 fq 改回 fq_codel。
qdisc_plan() {
  root=$1
  mode=$2
  if [ "$mode" = on ]; then
    case $root in
      fq) printf '%s\n' keep ;;
      fq_codel|pfifo_fast|pfifo|noqueue) printf '%s\n' replace ;;
      mq|mqprio) printf '%s\n' children ;;
      *) printf '%s\n' skip ;;
    esac
  else
    case $root in
      fq) printf '%s\n' replace ;;
      mq|mqprio) printf '%s\n' children ;;
      *) printf '%s\n' keep ;;
    esac
  fi
}

# dash 的 case 里 [[:space:]]* 不能表示「零个空格」，所以用 grep。
is_managed_sysctl_line() {
  printf '%s\n' "$1" | grep -q '^net\.core\.default_qdisc[[:space:]]*=' && return 0
  printf '%s\n' "$1" | grep -q '^net\.ipv4\.tcp_congestion_control[[:space:]]*=' && return 0
  printf '%s\n' "$1" | grep -q '^net\.ipv4\.tcp_allowed_congestion_control[[:space:]]*=' && return 0
  return 1
}

# 把已有的拥塞控制和队列设置注释掉，再在文件末尾写上本脚本的块。
# 再跑一次不会叠成两份。DESIRED_BLOCK 是要写入的正文，可为空。
apply_sysctl_text() {
  in_block=0
  while IFS= read -r line || [ -n "$line" ]; do
    case $line in
      "# bbr-onekey-begin")
        in_block=1
        continue
        ;;
    esac
    if [ "$in_block" = 1 ]; then
      case $line in
        "# bbr-onekey-end") in_block=0 ;;
      esac
      continue
    fi
    stripped=$(printf '%s' "$line" | sed 's/^[[:space:]]*//')
    if is_managed_sysctl_line "$stripped"; then
      printf '%s\n' "# bbr-onekey: 改由脚本末尾这块管理"
      printf '# %s\n' "$line"
    else
      printf '%s\n' "$line"
    fi
  done
  if [ -n "${DESIRED_BLOCK:-}" ]; then
    printf '%s\n' "# bbr-onekey-begin"
    printf '%s\n' "$DESIRED_BLOCK"
    printf '%s\n' "# bbr-onekey-end"
  fi
}

# 去掉本脚本的块，恢复被注释的原行，再把仍然写着 bbr / fq 的生效行注释掉。
disable_bbr_text() {
  tmp1=$(mktemp "${TMPDIR:-/tmp}/bbr-off1.XXXXXX") || return 1
  tmp2=$(mktemp "${TMPDIR:-/tmp}/bbr-off2.XXXXXX") || { rm -f "$tmp1"; return 1; }
  restore_bbr_text > "$tmp1"
  comment_live_bbr < "$tmp1" > "$tmp2"
  cat "$tmp2"
  rm -f "$tmp1" "$tmp2"
}

restore_bbr_text() {
  in_block=0
  skip_uncomment=0
  while IFS= read -r line || [ -n "$line" ]; do
    case $line in
      "# bbr-onekey-begin")
        in_block=1
        continue
        ;;
    esac
    if [ "$in_block" = 1 ]; then
      case $line in
        "# bbr-onekey-end") in_block=0 ;;
      esac
      continue
    fi
    if [ "$skip_uncomment" = 1 ]; then
      skip_uncomment=0
      case $line in
        "# "*)
          printf '%s\n' "$line" | sed 's/^# //'
          continue
          ;;
      esac
    fi
    case $line in
      "# bbr-onekey: "*)
        skip_uncomment=1
        ;;
      *)
        printf '%s\n' "$line"
        ;;
    esac
  done
}

comment_live_bbr() {
  while IFS= read -r line || [ -n "$line" ]; do
    stripped=$(printf '%s' "$line" | sed 's/^[[:space:]]*//')
    case $stripped in
      \#*)
        printf '%s\n' "$line"
        continue
        ;;
    esac
    if off_line_should_comment "$stripped"; then
      printf '%s\n' "# bbr-onekey: 已关闭"
      printf '# %s\n' "$line"
    else
      printf '%s\n' "$line"
    fi
  done
}

off_line_should_comment() {
  stripped=$1
  is_managed_sysctl_line "$stripped" || return 1
  case $stripped in
    net.ipv4.tcp_allowed_congestion_control*) return 1 ;;
  esac
  key=$(printf '%s' "$stripped" | sed 's/[[:space:]]*=.*//')
  val=$(printf '%s' "$stripped" | sed 's/^[^=]*=[[:space:]]*//; s/[[:space:]]*$//')
  case $key in
    net.ipv4.tcp_congestion_control) [ "$val" = bbr ] ;;
    net.core.default_qdisc) [ "$val" = fq ] ;;
    *) return 1 ;;
  esac
}

#----------------------------------------------------------------------
# 读取这台机器。只在真正运行时调用。
#----------------------------------------------------------------------

detect_os() {
  PM=none
  if command -v apt-get >/dev/null 2>&1; then
    PM=apt
  elif command -v dnf >/dev/null 2>&1; then
    PM=dnf
  elif command -v yum >/dev/null 2>&1; then
    PM=yum
  elif command -v apk >/dev/null 2>&1; then
    PM=apk
  elif command -v pacman >/dev/null 2>&1; then
    PM=pacman
  elif command -v zypper >/dev/null 2>&1; then
    PM=zypper
  elif command -v opkg >/dev/null 2>&1; then
    PM=opkg
  elif command -v xbps-install >/dev/null 2>&1; then
    PM=xbps
  fi
  OS_ID=unknown
  OS_VERSION=""
  OS_PRETTY=""
  if [ -r /etc/os-release ]; then
    OS_ID=$(sed -n 's/^ID=//p' /etc/os-release | head -n 1 | tr -d '"')
    OS_VERSION=$(sed -n 's/^VERSION_ID=//p' /etc/os-release | head -n 1 | tr -d '"')
    OS_PRETTY=$(sed -n 's/^PRETTY_NAME=//p' /etc/os-release | head -n 1 | tr -d '"')
  fi
  if [ -r /etc/openwrt_release ]; then
    PM=opkg
    OS_ID=openwrt
    [ -n "$OS_PRETTY" ] || OS_PRETTY=OpenWrt
  fi
  [ -n "$OS_PRETTY" ] || OS_PRETTY=$OS_ID
}

detect_virt() {
  container=""
  vm=""
  if command -v systemd-detect-virt >/dev/null 2>&1; then
    if systemd-detect-virt --container >/dev/null 2>&1; then
      container=$(systemd-detect-virt --container 2>/dev/null || true)
    fi
    vm=$(systemd-detect-virt --vm 2>/dev/null || true)
  fi
  if [ -z "$container" ] && [ -e /.dockerenv ]; then
    container=docker
  fi
  if [ -z "$container" ] && [ -e /run/.containerenv ]; then
    container=podman
  fi
  if [ -z "$container" ] && [ -d /proc/vz ] && [ ! -d /proc/bc ]; then
    container=openvz
  fi
  if [ -z "$container" ] && [ -r /proc/1/environ ]; then
    env_c=$(tr '\0' '\n' < /proc/1/environ | sed -n 's/^container=//p' | head -n 1)
    [ -n "$env_c" ] && container=$env_c
  fi
  if [ -z "$container" ] && [ -r /proc/1/cgroup ]; then
    if grep -E -q 'docker|lxc|kubepods|containerd' /proc/1/cgroup 2>/dev/null; then
      container=container
    fi
  fi
  classified=$(classify_virt "$container" "$vm")
  SHARED_KERNEL=${classified%% *}
  VIRT_NAME=${classified#* }
  VIRT_PHRASE=$(virt_phrase "$SHARED_KERNEL" "$VIRT_NAME")
}

detect_network() {
  locals=""
  ipv6s=""
  if command -v ip >/dev/null 2>&1; then
    locals=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | tr '\n' ' ')
    ipv6s=$(ip -6 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | tr '\n' ' ')
  fi
  NET_KIND=$(network_kind "$locals" "$ipv6s")
  NET_LOCAL=$(printf '%s' "$locals" | sed 's/[[:space:]]*$//')
  NET_EGRESS=""
  if [ "$NET_KIND" = nat ]; then
    NET_EGRESS=$(fetch_egress_v4 || true)
    if ! is_ipv4 "$NET_EGRESS"; then
      NET_EGRESS=""
    fi
  fi
  NET_PHRASE=$(network_phrase "$NET_KIND" "$NET_LOCAL" "$NET_EGRESS")
}

fetch_egress_v4() {
  url=https://api.ipify.org
  if command -v curl >/dev/null 2>&1; then
    curl -4 -fsS --max-time 4 "$url" 2>/dev/null && return 0
  fi
  if command -v wget >/dev/null 2>&1; then
    wget -4 -qO- -T 4 "$url" 2>/dev/null && return 0
  fi
  return 1
}

read_sysctl() {
  key=$1
  val=""
  if command -v sysctl >/dev/null 2>&1; then
    val=$(sysctl -n "$key" 2>/dev/null) || val=""
  fi
  if [ -z "$val" ]; then
    path=$(printf '%s' "$key" | sed 's/\./\//g')
    if [ -r "/proc/sys/$path" ]; then
      val=$(cat "/proc/sys/$path" 2>/dev/null) || val=""
    fi
  fi
  printf '%s' "$val" | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

word_in() {
  word=$1
  list=$2
  printf '%s\n' "$list" | tr ' ' '\n' | grep -x -q "$word"
}

cc_has_bbr() {
  word_in bbr "$(read_sysctl net.ipv4.tcp_available_congestion_control)"
}

kb_free_root() {
  df -Pk / 2>/dev/null | awk 'NR==2 {print $4}'
}

have_space() {
  need=$1
  free=$(kb_free_root)
  case $free in
    ''|*[!0-9]*) return 0 ;;
  esac
  [ "$free" -ge "$need" ]
}

kconfig_state() {
  key=$1
  krel=$(uname -r)
  file=""
  for c in "/boot/config-$krel" "/lib/modules/$krel/build/.config"; do
    if [ -f "$c" ]; then
      file=$c
      break
    fi
  done
  if [ -n "$file" ]; then
    line=$(grep "^$key=" "$file" 2>/dev/null | head -n 1)
    if [ -z "$line" ] && grep -q "^# $key is not set" "$file" 2>/dev/null; then
      printf '%s\n' n
      return 0
    fi
  elif [ -r /proc/config.gz ] && command -v gzip >/dev/null 2>&1; then
    line=$(gzip -dc /proc/config.gz 2>/dev/null | grep "^$key=" | head -n 1)
    if [ -z "$line" ] && gzip -dc /proc/config.gz 2>/dev/null | grep -q "^# $key is not set"; then
      printf '%s\n' n
      return 0
    fi
  else
    printf '%s\n' unknown
    return 0
  fi
  case $line in
    "$key=y") printf '%s\n' y ;;
    "$key=m") printf '%s\n' m ;;
    *) printf '%s\n' unknown ;;
  esac
}

#----------------------------------------------------------------------
# 安装缺少的软件。只用这台机器已经配置好的软件源。
#----------------------------------------------------------------------

apt_retry() {
  rounds=$1
  shift
  i=0
  while [ "$i" -lt "$rounds" ]; do
    if "$@" >"$WORKDIR/apt.log" 2>&1; then
      return 0
    fi
    if grep -q 'Could not get lock' "$WORKDIR/apt.log" || grep -q 'Unable to acquire' "$WORKDIR/apt.log"; then
      i=$((i + 1))
      say_warn "apt 正被系统更新占用，等待 20 秒后重试（$i/$rounds）"
      sleep 20
      continue
    fi
    return 1
  done
  return 1
}

apt_install_pkg() {
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    -o Dpkg::Options::=--force-confdef \
    -o Dpkg::Options::=--force-confold \
    "$1"
}

ubuntu_eol_hosts() {
  grep -E 'no longer has a Release file' "$WORKDIR/apt.log" 2>/dev/null \
    | grep -oE 'https?://[^[:space:]'\''"]+' \
    | sed -nE 's#^https?://([^/]+)/ubuntu(/.*)?$#\1#p' \
    | sort -u
}

ubuntu_try_old_releases() {
  hosts=$(ubuntu_eol_hosts || true)
  [ -n "$hosts" ] || return 1
  say_info "检测到 Ubuntu 源已停止维护，只把失效的 Ubuntu 归档换成 old-releases"
  printf '%s\n' "$hosts" > "$WORKDIR/eol-hosts"
  rewrite_ubuntu_file() {
    f=$1
    [ -f "$f" ] || return 0
    while IFS= read -r host; do
      [ -n "$host" ] || continue
      host_esc=$(printf '%s' "$host" | sed 's/[].[*^$()+?{|\\]/\\&/g')
      sed -i -E "s#https?://${host_esc}/ubuntu#http://old-releases.ubuntu.com/ubuntu#g" "$f"
    done < "$WORKDIR/eol-hosts"
  }
  rewrite_ubuntu_file /etc/apt/sources.list
  for f in /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
    [ -f "$f" ] || continue
    rewrite_ubuntu_file "$f"
  done
  return 0
}

pm_prepare() {
  [ "${PREPARED:-0}" = 1 ] && return 0
  case $PM in
    apt)
      if ! apt_retry 8 apt-get update; then
        if ubuntu_try_old_releases; then
          apt_retry 5 apt-get update || say_warn "软件源更新没完全成功，能用本地缓存就继续"
        else
          say_warn "软件源更新没完全成功，能用本地缓存就继续"
          tail -n 8 "$WORKDIR/apt.log" >&2 || true
        fi
      fi
      ;;
    apk)
      apk update >/dev/null 2>&1 || say_warn "apk 源更新失败，继续尝试安装"
      ;;
    dnf)
      dnf makecache -y >"$WORKDIR/rpm.log" 2>&1 || true
      ;;
    yum)
      yum makecache -y >"$WORKDIR/rpm.log" 2>&1 || true
      ;;
    pacman)
      pacman -Sy --noconfirm >"$WORKDIR/pacman.log" 2>&1 || true
      ;;
    zypper)
      zypper --non-interactive refresh >"$WORKDIR/zypper.log" 2>&1 || true
      ;;
    opkg)
      opkg update >"$WORKDIR/opkg.log" 2>&1 || say_warn "opkg 源更新失败，继续尝试安装"
      ;;
    xbps)
      xbps-install -S >"$WORKDIR/xbps.log" 2>&1 || true
      ;;
  esac
  PREPARED=1
}

show_log_tail() {
  log=$1
  [ -f "$log" ] || return 0
  tail -n 15 "$log" >&2 || true
}

# 0 装好了，1 源里没有这个包，2 装的过程失败。
pm_install_one() {
  pkg=$1
  if [ "$PM" = none ]; then
    return 1
  fi
  if ! have_space 20480; then
    say_err "磁盘剩余空间不足 20MB，停止安装，避免把系统写满"
    return 2
  fi
  pm_prepare
  case $PM in
    apt)
      if ! apt-cache show "$pkg" >/dev/null 2>&1; then
        return 1
      fi
      say_info "正在安装 $pkg"
      if apt_retry 4 apt_install_pkg "$pkg"; then
        return 0
      fi
      say_err "安装 $pkg 失败，系统原话："
      show_log_tail "$WORKDIR/apt.log"
      return 2
      ;;
    dnf|yum)
      say_info "正在安装 $pkg"
      if [ "$PM" = dnf ]; then
        dnf install -y "$pkg" >"$WORKDIR/rpm.log" 2>&1
      else
        yum install -y "$pkg" >"$WORKDIR/rpm.log" 2>&1
      fi
      rc=$?
      if [ "$rc" -eq 0 ]; then
        return 0
      fi
      if grep -q 'Nothing to do' "$WORKDIR/rpm.log"; then
        return 0
      fi
      if grep -q -e 'No match for argument' -e 'No matching Packages' -e 'No package' -e 'Error: Unable to find a match' -e 'Nothing to do' "$WORKDIR/rpm.log"; then
        return 1
      fi
      say_err "安装 $pkg 失败，系统原话："
      show_log_tail "$WORKDIR/rpm.log"
      return 2
      ;;
    apk)
      say_info "正在安装 $pkg"
      if apk add --no-cache "$pkg" >"$WORKDIR/apk.log" 2>&1; then
        return 0
      fi
      if grep -q -e 'no such package' -e 'unsatisfiable' -e 'could not satisfy' "$WORKDIR/apk.log"; then
        return 1
      fi
      say_err "安装 $pkg 失败，系统原话："
      show_log_tail "$WORKDIR/apk.log"
      return 2
      ;;
    pacman)
      say_info "正在安装 $pkg"
      if pacman -S --noconfirm --needed "$pkg" >"$WORKDIR/pacman.log" 2>&1; then
        return 0
      fi
      if grep -q -e 'target not found' -e '未找到目标' "$WORKDIR/pacman.log"; then
        return 1
      fi
      say_err "安装 $pkg 失败，系统原话："
      show_log_tail "$WORKDIR/pacman.log"
      return 2
      ;;
    zypper)
      say_info "正在安装 $pkg"
      if zypper --non-interactive install --no-recommends "$pkg" >"$WORKDIR/zypper.log" 2>&1; then
        return 0
      fi
      if grep -q -e 'not found' -e 'No provider' "$WORKDIR/zypper.log"; then
        return 1
      fi
      say_err "安装 $pkg 失败，系统原话："
      show_log_tail "$WORKDIR/zypper.log"
      return 2
      ;;
    opkg)
      say_info "正在安装 $pkg"
      opkg install "$pkg" >"$WORKDIR/opkg.log" 2>&1 || true
      if opkg status "$pkg" 2>/dev/null | grep -q 'Status: install'; then
        return 0
      fi
      if grep -q -e 'Unknown package' -e 'Cannot install package' "$WORKDIR/opkg.log"; then
        return 1
      fi
      say_err "安装 $pkg 失败，系统原话："
      show_log_tail "$WORKDIR/opkg.log"
      return 2
      ;;
    xbps)
      say_info "正在安装 $pkg"
      if xbps-install -y "$pkg" >"$WORKDIR/xbps.log" 2>&1; then
        return 0
      fi
      if grep -q 'not found' "$WORKDIR/xbps.log"; then
        return 1
      fi
      say_err "安装 $pkg 失败，系统原话："
      show_log_tail "$WORKDIR/xbps.log"
      return 2
      ;;
    *)
      return 1
      ;;
  esac
}

ensure_cmd() {
  cmd=$1
  shift
  if command -v "$cmd" >/dev/null 2>&1; then
    return 0
  fi
  if [ "$PM" = none ]; then
    say_warn "缺少命令 $cmd，这台机器没有能用的包管理器"
    return 1
  fi
  say_info "缺少命令 $cmd，准备安装"
  for pkg in "$@"; do
    pm_install_one "$pkg"
    rc=$?
    if command -v "$cmd" >/dev/null 2>&1; then
      say_ok "已经有命令 $cmd"
      return 0
    fi
    if [ "$rc" -eq 2 ]; then
      return 1
    fi
  done
  say_warn "还是没有命令 $cmd，相关的步骤会跳过"
  return 1
}

ensure_tools() {
  ensure_cmd sysctl procps procps-ng procps-ng-sysctl || true
  ensure_cmd modprobe kmod || true
  ensure_cmd ip iproute2 iproute ip-full || true
  ensure_cmd tc iproute2 iproute tc || true
}

module_file_exists() {
  name=$1
  krel=$(uname -r)
  dir="/lib/modules/$krel"
  [ -d "$dir" ] || return 1
  find "$dir" -type f \( \
    -name "${name}.ko" -o -name "${name}.ko.xz" -o -name "${name}.ko.gz" \
    -o -name "${name}.ko.zst" -o -name "${name}.ko.bz2" \
  \) 2>/dev/null | grep -q .
}

module_sysfs() {
  [ -e "/sys/module/$1" ]
}

load_module() {
  name=$1
  if module_sysfs "$name"; then
    return 0
  fi
  if ! command -v modprobe >/dev/null 2>&1; then
    return 1
  fi
  if modprobe "$name" >"$WORKDIR/modprobe.err" 2>&1; then
    return 0
  fi
  if module_file_exists "$name" && command -v depmod >/dev/null 2>&1; then
    depmod -a >/dev/null 2>&1 || true
    if modprobe "$name" >"$WORKDIR/modprobe.err" 2>&1; then
      return 0
    fi
  fi
  module_sysfs "$name"
}

try_install_current_modules() {
  krel=$(uname -r)
  if ! have_space 81920; then
    say_warn "剩余磁盘空间不足 80MB，跳过安装内核模块，避免把磁盘写满"
    return 1
  fi
  case $PM in
    apt)
      for pkg in "linux-modules-$krel" "linux-modules-extra-$krel" "linux-image-$krel"; do
        pm_install_one "$pkg" || true
        load_module tcp_bbr || true
        if cc_has_bbr; then
          return 0
        fi
      done
      ;;
    dnf|yum)
      for pkg in "kernel-modules-$krel" "kernel-modules-core-$krel" "kernel-modules-extra-$krel"; do
        pm_install_one "$pkg" || true
        load_module tcp_bbr || true
        if cc_has_bbr; then
          return 0
        fi
      done
      ;;
    apk)
      case $krel in
        *-virt*) flavor=linux-virt ;;
        *-edge*) flavor=linux-edge ;;
        *) flavor=linux-lts ;;
      esac
      pm_install_one "$flavor" || true
      ;;
    pacman)
      case $krel in
        *-lts*) flavor=linux-lts ;;
        *-zen*) flavor=linux-zen ;;
        *-hardened*) flavor=linux-hardened ;;
        *) flavor=linux ;;
      esac
      pm_install_one "$flavor" || true
      ;;
    zypper)
      pm_install_one kernel-default || true
      ;;
    opkg)
      pm_install_one kmod-tcp-bbr || true
      load_module sch_fq || true
      if ! sysctl_accepts_fq; then
        pm_install_one kmod-sched || true
      fi
      ;;
    *)
      return 1
      ;;
  esac
  if command -v depmod >/dev/null 2>&1; then
    depmod -a >/dev/null 2>&1 || true
  fi
  load_module tcp_bbr || true
  load_module sch_fq || true
  cc_has_bbr
}

sysctl_accepts_fq() {
  # 不改真实默认值：只在已经是 fq 时算有。真正的切换放在开启步骤。
  cur=$(read_sysctl net.core.default_qdisc)
  [ "$cur" = fq ]
}

kernel_ship_bbr() {
  ver=$1
  dir="/lib/modules/$ver"
  if [ -d "$dir" ]; then
    if find "$dir" -type f \( \
      -name 'tcp_bbr.ko' -o -name 'tcp_bbr.ko.xz' -o -name 'tcp_bbr.ko.gz' \
      -o -name 'tcp_bbr.ko.zst' -o -name 'tcp_bbr.ko.bz2' \
    \) 2>/dev/null | grep -q .; then
      return 0
    fi
  fi
  if [ -f "/boot/config-$ver" ] && grep -q '^CONFIG_TCP_CONG_BBR=[ym]' "/boot/config-$ver"; then
    return 0
  fi
  if [ -d "$dir" ] || [ -f "/boot/config-$ver" ]; then
    return 1
  fi
  return 0
}

boot_images() {
  ls -1 /boot/vmlinuz-* 2>/dev/null || true
}

prefer_boot_kernel() {
  ver=$1
  if command -v grubby >/dev/null 2>&1 && [ -f "/boot/vmlinuz-$ver" ]; then
    grubby --set-default "/boot/vmlinuz-$ver" >/dev/null 2>&1 || true
  fi
}

find_bootable_kernel() {
  current=$(uname -r)
  best=""
  for img in /boot/vmlinuz-*; do
    [ -f "$img" ] || continue
    ver=${img#/boot/vmlinuz-}
    case $ver in
      ''|'*') continue ;;
    esac
    version_ge "$ver" 4.9 || continue
    kernel_ship_bbr "$ver" || continue
    if [ -z "$best" ]; then
      best=$ver
      continue
    fi
    if version_ge "$ver" "$best" && ! version_ge "$best" "$ver"; then
      best=$ver
    fi
  done
  if [ -n "$best" ] && [ "$best" != "$current" ]; then
    printf '%s\n' "$best"
  fi
}

install_distro_kernel() {
  if ! have_space 512000; then
    say_warn "剩余磁盘空间不足 500MB，不安装新内核，避免把磁盘写满"
    return 1
  fi
  case $PM in
    apt)
      krel=$(uname -r)
      pkg=""
      case $krel in
        *rpi*|*raspi*)
          if apt-cache show linux-image-raspi >/dev/null 2>&1; then
            pkg=linux-image-raspi
          elif apt-cache show raspberrypi-kernel >/dev/null 2>&1; then
            pkg=raspberrypi-kernel
          fi
          ;;
      esac
      if [ -z "$pkg" ]; then
        case $OS_ID in
          ubuntu|linuxmint|pop|neon|elementary|zorin)
            case $OS_VERSION in
              16.04) pkg=linux-generic-hwe-16.04 ;;
              18.04) pkg=linux-generic-hwe-18.04 ;;
            esac
            if [ -z "$pkg" ] && apt-cache show linux-generic >/dev/null 2>&1; then
              pkg=linux-generic
            fi
            ;;
          *)
            arch=$(dpkg --print-architecture 2>/dev/null || true)
            if [ -n "$arch" ] && apt-cache show "linux-image-$arch" >/dev/null 2>&1; then
              pkg="linux-image-$arch"
            elif apt-cache show linux-image-generic >/dev/null 2>&1; then
              pkg=linux-image-generic
            fi
            ;;
        esac
      fi
      [ -n "$pkg" ] || return 1
      say_info "当前内核开不了 BBR，准备安装系统自带内核：$pkg"
      pm_install_one "$pkg"
      return $?
      ;;
    dnf|yum)
      # 7 的官方内核停在 3.10，没有 BBR。只用 ELRepo 的官方主线内核，不装别人改过的版本。
      major=${OS_VERSION%%.*}
      if [ "$OS_ID" = ol ] && [ "$major" = 7 ]; then
        say_info "当前是 Oracle Linux 7，准备安装它自带的 UEK 内核"
        pm_install_one kernel-uek
        return $?
      fi
      if [ "$major" = 7 ]; then
        say_info "当前内核是 3.10，官方源里没有带 BBR 的版本，准备安装 ELRepo 的主线内核"
        if ! rpm --import https://www.elrepo.org/RPM-GPG-KEY-elrepo.org >"$WORKDIR/elrepo.log" 2>&1; then
          say_err "没能导入 ELRepo 签名，不安装新内核"
          show_log_tail "$WORKDIR/elrepo.log"
          return 1
        fi
        if ! pm_install_one https://www.elrepo.org/elrepo-release-7.el7.elrepo.noarch.rpm; then
          # pm_install_one 对 URL 可能匹配不到缓存。直接用 yum/dnf 装这个 rpm。
          say_info "正在安装 ELRepo 源"
          if [ "$PM" = dnf ]; then
            dnf install -y https://www.elrepo.org/elrepo-release-7.el7.elrepo.noarch.rpm >"$WORKDIR/elrepo.log" 2>&1
          else
            yum install -y https://www.elrepo.org/elrepo-release-7.el7.elrepo.noarch.rpm >"$WORKDIR/elrepo.log" 2>&1
          fi
          if [ "$?" -ne 0 ]; then
            say_err "ELRepo 源安装失败，系统原话："
            show_log_tail "$WORKDIR/elrepo.log"
            return 1
          fi
        fi
        say_info "正在安装 kernel-ml"
        if [ "$PM" = dnf ]; then
          dnf --enablerepo=elrepo-kernel install -y kernel-ml >"$WORKDIR/elrepo.log" 2>&1
        else
          yum --enablerepo=elrepo-kernel install -y kernel-ml >"$WORKDIR/elrepo.log" 2>&1
        fi
        if [ "$?" -ne 0 ]; then
          say_err "kernel-ml 安装失败，系统原话："
          show_log_tail "$WORKDIR/elrepo.log"
          return 1
        fi
        return 0
      fi
      say_info "准备安装系统仓库里的新内核"
      pm_install_one kernel || pm_install_one kernel-core
      return $?
      ;;
    apk)
      case $(uname -r) in
        *-virt*) pm_install_one linux-virt ;;
        *-edge*) pm_install_one linux-edge ;;
        *) pm_install_one linux-lts ;;
      esac
      return $?
      ;;
    pacman)
      case $(uname -r) in
        *-lts*) pm_install_one linux-lts ;;
        *-zen*) pm_install_one linux-zen ;;
        *-hardened*) pm_install_one linux-hardened ;;
        *) pm_install_one linux ;;
      esac
      return $?
      ;;
    zypper)
      pm_install_one kernel-default
      return $?
      ;;
    *)
      return 1
      ;;
  esac
}

explain_shared_kernel_blocked() {
  say_err "这台是切出来的机器（$VIRT_PHRASE）。"
  say_err "现在的内核是 $(uname -r)。它里面没有 BBR，小鸡也换不了母鸡的内核。"
  say_err "请让服务商在母鸡上打开 BBR，或者换成 KVM 这种自己带内核的机器，然后再运行本脚本。"
}

# 0 现在就能用，3 需要重启后才会生效，2 这台机器开不了。
prepare_bbr_module() {
  load_module tcp_bbr || true
  load_module sch_fq || true
  if cc_has_bbr; then
    return 0
  fi
  if [ "$SHARED_KERNEL" = 1 ]; then
    explain_shared_kernel_blocked
    return 2
  fi
  cfg=$(kconfig_state CONFIG_TCP_CONG_BBR)
  if [ "$cfg" != n ]; then
    say_info "内核里还没有 tcp_bbr，准备从系统软件源安装对应模块"
    try_install_current_modules || true
    load_module tcp_bbr || true
    if cc_has_bbr; then
      say_ok "tcp_bbr 模块已经装好"
      return 0
    fi
  fi
  newer=$(find_bootable_kernel || true)
  if [ -n "$newer" ]; then
    say_info "磁盘上已经有内核 $newer，它的版本可以跑 BBR"
    prefer_boot_kernel "$newer"
    NEED_REBOOT=1
    REBOOT_KERNEL=$newer
    return 3
  fi
  before_boot=$(boot_images)
  if install_distro_kernel; then
    after_boot=$(boot_images)
    newer=$(find_bootable_kernel || true)
    if [ "$before_boot" != "$after_boot" ] || [ -n "$newer" ]; then
      [ -n "$newer" ] && prefer_boot_kernel "$newer"
      NEED_REBOOT=1
      REBOOT_KERNEL=$newer
      return 3
    fi
    say_warn "软件源里的内核包装过了，但没有出现比当前更新、并且能启动的内核"
  fi
  say_err "这个内核没有 BBR，系统软件源里也没能装上带 BBR 的内核。"
  say_err "内核版本：$(uname -r)。BBR 需要 4.9 或更新的内核。"
  return 2
}

#----------------------------------------------------------------------
# 写入开机配置，并立刻生效。
#----------------------------------------------------------------------

write_sysctl_key() {
  key=$1
  val=$2
  if command -v sysctl >/dev/null 2>&1; then
    sysctl -w "$key=$val" >"$WORKDIR/sysctl.err" 2>&1
    return $?
  fi
  path=$(printf '%s' "$key" | sed 's/\./\//g')
  if [ -w "/proc/sys/$path" ]; then
    printf '%s\n' "$val" > "/proc/sys/$path" 2>"$WORKDIR/sysctl.err"
    return $?
  fi
  printf '%s\n' "cannot write $key" > "$WORKDIR/sysctl.err"
  return 1
}

sysctl_error_kind() {
  if [ ! -f "$WORKDIR/sysctl.err" ]; then
    printf '%s\n' other
    return 0
  fi
  if grep -q -i -e 'permission denied' -e 'operation not permitted' -e 'read-only' -e 'read only' "$WORKDIR/sysctl.err"; then
    printf '%s\n' denied
    return 0
  fi
  if grep -q -i -e 'invalid argument' -e 'invalid' "$WORKDIR/sysctl.err"; then
    printf '%s\n' invalid
    return 0
  fi
  printf '%s\n' other
}

allow_bbr() {
  ALLOW_VALUE=""
  if [ ! -r /proc/sys/net/ipv4/tcp_allowed_congestion_control ]; then
    return 0
  fi
  cur=$(read_sysctl net.ipv4.tcp_allowed_congestion_control)
  if word_in bbr "$cur"; then
    return 0
  fi
  new=$(printf '%s bbr' "$cur" | sed 's/^[[:space:]]*//; s/[[:space:]][[:space:]]*/ /g')
  if write_sysctl_key net.ipv4.tcp_allowed_congestion_control "$new"; then
    ALLOW_VALUE=$new
    return 0
  fi
  return 1
}

apply_live() {
  LIVE_BBR=0
  LIVE_FQ=0
  load_module tcp_bbr || true
  load_module sch_fq || true
  allow_bbr || true
  if write_sysctl_key net.core.default_qdisc fq; then
    if [ "$(read_sysctl net.core.default_qdisc)" = fq ]; then
      LIVE_FQ=1
    fi
  fi
  if ! cc_has_bbr; then
    load_module tcp_bbr || true
  fi
  if write_sysctl_key net.ipv4.tcp_congestion_control bbr; then
    if [ "$(read_sysctl net.ipv4.tcp_congestion_control)" = bbr ]; then
      LIVE_BBR=1
    fi
  fi
  if [ "$LIVE_BBR" = 1 ]; then
    return 0
  fi
  kind=$(sysctl_error_kind)
  if [ "$kind" = denied ]; then
    say_err "系统不允许在这台机器上修改拥塞控制。"
    if [ "$SHARED_KERNEL" = 1 ]; then
      say_err "这是切出来的机器，母鸡把这项设置锁住了。需要在母鸡上打开 BBR，或者换一台可以自己改内核设置的机器。"
    fi
    return 2
  fi
  return 1
}

persist_lines() {
  block=""
  if [ "$1" = 1 ]; then
    block="net.core.default_qdisc=fq"
  fi
  if [ "$2" = 1 ]; then
    if [ -n "$block" ]; then
      block="$block
net.ipv4.tcp_congestion_control=bbr"
    else
      block="net.ipv4.tcp_congestion_control=bbr"
    fi
  fi
  if [ -n "${3:-}" ]; then
    if [ -n "$block" ]; then
      block="$block
net.ipv4.tcp_allowed_congestion_control=$3"
    else
      block="net.ipv4.tcp_allowed_congestion_control=$3"
    fi
  fi
  printf '%s' "$block"
}

write_text_file() {
  dest=$1
  tmp="$WORKDIR/write-text"
  cat > "$tmp"
  mkdir -p "$(dirname "$dest")" 2>/dev/null || true
  if [ -f "$dest" ]; then
    cat "$tmp" > "$dest"
  else
    cat "$tmp" > "$dest"
  fi
}

rewrite_sysctl_file() {
  file=$1
  [ -f "$file" ] || return 0
  [ -w "$file" ] || { say_warn "写不了 $file"; return 1; }
  DESIRED_BLOCK=$PERSIST_BLOCK
  apply_sysctl_text < "$file" > "$WORKDIR/sysctl-out" || return 1
  cat "$WORKDIR/sysctl-out" > "$file"
}

disable_sysctl_file() {
  file=$1
  [ -f "$file" ] || return 0
  [ -w "$file" ] || return 0
  disable_bbr_text < "$file" > "$WORKDIR/sysctl-out" || return 1
  cat "$WORKDIR/sysctl-out" > "$file"
}

each_sysctl_file() {
  if [ -f /etc/sysctl.conf ]; then
    printf '%s\n' /etc/sysctl.conf
  fi
  if [ -d /etc/sysctl.d ]; then
    for f in /etc/sysctl.d/*.conf; do
      [ -f "$f" ] || continue
      base=${f##*/}
      [ "$base" = zzz-bbr.conf ] && continue
      printf '%s\n' "$f"
    done
  fi
}

persist_sysctl() {
  mkdir -p /etc/sysctl.d
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    rewrite_sysctl_file "$f" || true
  done <<EOF
$(each_sysctl_file)
EOF
  DESIRED_BLOCK=$PERSIST_BLOCK
  {
    printf '%s\n' "# 由 BBR 一键脚本写入。再运行一次会覆盖本文件。"
    printf '%s\n' "# bbr-onekey-begin"
    printf '%s\n' "$PERSIST_BLOCK"
    printf '%s\n' "# bbr-onekey-end"
  } > /etc/sysctl.d/zzz-bbr.conf
}

clear_sysctl() {
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    disable_sysctl_file "$f" || true
  done <<EOF
$(each_sysctl_file)
EOF
  rm -f /etc/sysctl.d/zzz-bbr.conf
}

module_loaded_dyn() {
  name=$1
  if [ -r /proc/modules ]; then
    awk '{print $1}' /proc/modules | grep -x -q "$name"
    return $?
  fi
  return 1
}

persist_modules() {
  mkdir -p /etc/modules-load.d 2>/dev/null || true
  {
    printf '%s\n' "# 由 BBR 一键脚本写入"
    if [ "$1" = 1 ]; then
      printf '%s\n' tcp_bbr
    fi
    if [ "$2" = 1 ]; then
      printf '%s\n' sch_fq
    fi
  } > /etc/modules-load.d/bbr.conf
  if [ -d /etc/modules.d ]; then
    {
      printf '%s\n' "# bbr-onekey"
      [ "$1" = 1 ] && printf '%s\n' tcp_bbr
      [ "$2" = 1 ] && printf '%s\n' sch_fq
    } > /etc/modules.d/bbr
  fi
  # systemd 读 modules-load.d，OpenRC / 传统启动读 /etc/modules。两边都写，重复加载没有副作用。
  if [ "$1" = 1 ] || [ "$2" = 1 ]; then
    if [ ! -f /etc/modules ]; then
      touch /etc/modules 2>/dev/null || true
    fi
  fi
  if [ -f /etc/modules ]; then
    if [ "$1" = 1 ] && ! grep -x -q tcp_bbr /etc/modules; then
      printf '%s\n' tcp_bbr >> /etc/modules
    fi
    if [ "$2" = 1 ] && ! grep -x -q sch_fq /etc/modules; then
      printf '%s\n' sch_fq >> /etc/modules
    fi
  fi
}

clear_modules() {
  rm -f /etc/modules-load.d/bbr.conf
  if [ -f /etc/modules.d/bbr ]; then
    rm -f /etc/modules.d/bbr
  fi
  if [ -f /etc/modules ]; then
    grep -x -v -e tcp_bbr -e sch_fq /etc/modules > "$WORKDIR/modules" || true
    cat "$WORKDIR/modules" > /etc/modules
  fi
}

list_ifs() {
  if ! command -v ip >/dev/null 2>&1; then
    return 0
  fi
  ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | cut -d@ -f1 | while IFS= read -r dev; do
    case $dev in
      ''|lo|sit0) continue ;;
    esac
    printf '%s\n' "$dev"
  done
}

child_should_replace() {
  typ=$1
  mode=$2
  if [ "$mode" = on ]; then
    case $typ in
      fq_codel|pfifo_fast|pfifo|noqueue) return 0 ;;
    esac
  else
    case $typ in
      fq) return 0 ;;
    esac
  fi
  return 1
}

apply_qdiscs() {
  mode=$1
  if ! command -v tc >/dev/null 2>&1; then
    say_warn "没有 tc 命令，这次不改已经存在的网卡。重启之后，新起来的网卡会用当时的默认队列。"
    return 0
  fi
  if [ "$mode" = on ]; then
    target=fq
  else
    target=fq_codel
  fi
  ifs=$(list_ifs)
  for dev in $ifs; do
    show=$(tc qdisc show dev "$dev" 2>/dev/null) || continue
    [ -n "$show" ] || continue
    root=$(printf '%s\n' "$show" | awk 'NR==1 {print $2}')
    plan=$(qdisc_plan "$root" "$mode")
    case $plan in
      keep) ;;
      skip)
        say_warn "网卡 $dev 用的是 $root 队列，不是系统默认队列，保持不动"
        ;;
      replace)
        if tc qdisc replace dev "$dev" root "$target" >"$WORKDIR/tc.err" 2>&1; then
          CHANGED_DEVS="$CHANGED_DEVS $dev"
        else
          say_warn "网卡 $dev 没能改成 $target"
        fi
        ;;
      children)
        changed=0
        printf '%s\n' "$show" > "$WORKDIR/qdisc.txt"
        while IFS= read -r qline; do
          typ=$(printf '%s\n' "$qline" | awk '{print $2}')
          parent=$(printf '%s\n' "$qline" | sed -n 's/.* parent \([^ ]*\).*/\1/p')
          [ -n "$parent" ] || continue
          if child_should_replace "$typ" "$mode"; then
            if tc qdisc replace dev "$dev" parent "$parent" "$target" >"$WORKDIR/tc.err" 2>&1; then
              changed=1
            fi
          fi
        done < "$WORKDIR/qdisc.txt"
        if [ "$changed" = 1 ]; then
          CHANGED_DEVS="$CHANGED_DEVS $dev"
        fi
        ;;
    esac
  done
  CHANGED_DEVS=$(printf '%s' "$CHANGED_DEVS" | sed 's/^[[:space:]]*//; s/[[:space:]][[:space:]]*/ /g')
}

install_shortcut() {
  dest=/usr/local/sbin/bbr
  src=$0
  [ -f "$src" ] || return 0
  mkdir -p /usr/local/sbin 2>/dev/null || return 0
  if [ "$src" = "$dest" ]; then
    return 0
  fi
  if cp "$src" "$dest" 2>/dev/null; then
    chmod 755 "$dest" 2>/dev/null || true
    say_ok "以后可以直接输入 bbr，查看状态用 bbr --status"
  fi
}

print_identity() {
  say_info "系统：$OS_PRETTY（软件源：$PM）"
  say_info "内核：$(uname -r)（$(uname -m)）"
  say_info "机器：$VIRT_PHRASE"
  say_info "网络：$NET_PHRASE"
}

cmd_status() {
  detect_os
  detect_virt
  detect_network
  printf '%s\n' "BBR 一键脚本 $VERSION"
  print_identity
  cc=$(read_sysctl net.ipv4.tcp_congestion_control)
  qd=$(read_sysctl net.core.default_qdisc)
  [ -n "$cc" ] || cc="读不到"
  [ -n "$qd" ] || qd="读不到"
  say_info "当前拥塞控制：$cc"
  say_info "当前默认队列：$qd"
  if cc_has_bbr; then
    if module_loaded_dyn tcp_bbr; then
      say_info "tcp_bbr：已加载"
    elif module_sysfs tcp_bbr; then
      say_info "tcp_bbr：内核自带"
    else
      say_info "tcp_bbr：可用"
    fi
  else
    say_info "tcp_bbr：现在不可用"
  fi
  if [ -f /etc/sysctl.d/zzz-bbr.conf ]; then
    say_info "开机配置：有 /etc/sysctl.d/zzz-bbr.conf"
  else
    say_info "开机配置：还没有本脚本写的文件"
  fi
}

cmd_off() {
  detect_os
  say_step "关闭本脚本打开的 BBR"
  clear_sysctl
  clear_modules
  write_sysctl_key net.ipv4.tcp_congestion_control cubic >/dev/null 2>&1 || true
  write_sysctl_key net.core.default_qdisc fq_codel >/dev/null 2>&1 || true
  CHANGED_DEVS=""
  apply_qdiscs off
  now=$(read_sysctl net.ipv4.tcp_congestion_control)
  say_ok "已关掉。当前拥塞控制：${now:-未知}"
  if [ -n "$CHANGED_DEVS" ]; then
    say_ok "这些网卡的队列已从 fq 改回 fq_codel：$CHANGED_DEVS"
  fi
  say_info "如果原来的配置文件里写过别的队列，已按原样放回去。"
  say_info "已经连着的连接要断开重连才会换回原来的算法。"
}

cmd_on() {
  say_step "正在识别这台机器"
  detect_os
  detect_virt
  say_step "检查缺少的命令"
  ensure_tools
  detect_network
  print_identity
  if [ "$NET_KIND" = nat ] || [ "$NET_KIND" = public ] || [ "$NET_KIND" = ipv6 ]; then
    say_info "公网还是 NAT 都不影响 BBR，它改的是这台机器自己的发送方式。"
  fi

  say_step "检查 BBR 模块"
  prepare_bbr_module
  prep=$?
  if [ "$prep" -eq 2 ]; then
    return 2
  fi

  persist_fq=0
  persist_bbr=0
  if [ "$prep" -eq 0 ]; then
    say_step "打开 BBR"
    apply_live
    live=$?
    if [ "$live" -eq 2 ]; then
      return 2
    fi
    if [ "$LIVE_BBR" != 1 ]; then
      say_err "没能打开 BBR。"
      if [ -f "$WORKDIR/sysctl.err" ]; then
        say_err "系统原话："
        show_log_tail "$WORKDIR/sysctl.err"
      fi
      return 2
    fi
    persist_bbr=1
    if [ "$LIVE_FQ" = 1 ]; then
      persist_fq=1
    fi
  else
    LIVE_BBR=0
    LIVE_FQ=0
    persist_fq=1
    persist_bbr=1
  fi

  PERSIST_BLOCK=$(persist_lines "$persist_fq" "$persist_bbr" "$ALLOW_VALUE")
  say_step "写入开机配置"
  persist_sysctl
  load_tcp=0
  load_fq=0
  if module_loaded_dyn tcp_bbr || [ "$NEED_REBOOT" = 1 ]; then
    load_tcp=1
  fi
  if module_loaded_dyn sch_fq || [ "$NEED_REBOOT" = 1 ]; then
    load_fq=1
  fi
  persist_modules "$load_tcp" "$load_fq"

  CHANGED_DEVS=""
  if [ "$LIVE_FQ" = 1 ]; then
    apply_qdiscs on
  fi

  printf '\n'
  if [ "$NEED_REBOOT" = 1 ] && [ "$LIVE_BBR" != 1 ]; then
    say_ok "开机配置已经写好，但现在这个内核还不能用 BBR"
    if [ -n "$REBOOT_KERNEL" ]; then
      say_info "重启后会使用内核 $REBOOT_KERNEL。"
    else
      say_info "新内核已经安装。重启后如果 uname -r 变了，BBR 会自动打开。"
    fi
    say_info "这次没有自动重启，避免把正在用的服务打断。"
    say_info "确认可以重启时执行：reboot"
    say_info "重启后如果拥塞控制仍不是 bbr，再运行一次本脚本。"
    say_info "如果重启后内核版本完全没变，说明服务商在面板里指定了内核，需要先在面板里换成新内核。"
    install_shortcut
    return 0
  fi
  if [ "$LIVE_BBR" = 1 ]; then
    say_ok "BBR 已经打开"
    say_info "拥塞控制：bbr"
    if [ "$LIVE_FQ" = 1 ]; then
      say_info "默认队列：fq"
    else
      say_warn "队列 fq 没打开。BBR 会用内核自己的 pacing，效果比配上 fq 差一点，但已经在用 BBR。"
      if ! version_ge "$(uname -r)" 4.13; then
        say_warn "这个内核比 4.13 旧，没有 fq 时效果会更差一些。"
      fi
    fi
    if [ -n "$CHANGED_DEVS" ]; then
      say_info "这些网卡已换成 fq：$CHANGED_DEVS"
    fi
    say_info "开机后还会保持，不用再运行一次。"
    say_info "没有重启。已经连着的连接要断开重连才走 BBR，新连接马上生效。"
    say_info "IPv4 和 IPv6 的 TCP 都会走 BBR。"
    if [ "$SHARED_KERNEL" = 1 ]; then
      say_info "这台是切出来的，用的是母鸡内核里已经有的 BBR。"
    fi
    install_shortcut
    return 0
  fi
  say_err "没能打开 BBR。"
  return 2
}

usage() {
  cat <<EOF
BBR 一键脚本 $VERSION

用法：
  sh install.sh           自动识别这台机器，缺什么装什么，然后打开 BBR
  sh install.sh --status  只查看，不修改
  sh install.sh --off     关掉本脚本打开的 BBR

公网 VPS 和 NAT 都能用。切出来的机器如果母鸡内核带 BBR，也可以直接打开。
EOF
}

need_root() {
  if [ "$(id -u)" -eq 0 ]; then
    return 0
  fi
  if [ "${BBR_SUDO_TRIED:-0}" = 1 ]; then
    say_err "sudo 之后仍然不是 root，请换 root 账号再运行"
    exit 1
  fi
  if command -v sudo >/dev/null 2>&1; then
    say_info "当前不是 root，改用 sudo 继续"
    script=$0
    case $script in
      /*) ;;
      *) script=$(pwd)/$script ;;
    esac
    exec sudo env BBR_SUDO_TRIED=1 sh "$script" "$@"
  fi
  say_err "请用 root 运行：sudo sh install.sh"
  exit 1
}

make_workdir() {
  WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/bbr.XXXXXX") || {
    say_err "创建临时目录失败"
    exit 1
  }
  trap 'rm -rf "$WORKDIR"' EXIT HUP INT TERM
}

main() {
  action=on
  case ${1:-} in
    "") action=on ;;
    --status|status) action=status ;;
    --off|off) action=off ;;
    --help|-h|help) action=help ;;
    *)
      usage >&2
      exit 1
      ;;
  esac

  if [ "$action" = help ]; then
    usage
    exit 0
  fi

  if [ "$(uname -s 2>/dev/null)" != Linux ]; then
    say_err "BBR 是 Linux 内核的功能。请把脚本放到 VPS 上运行。"
    exit 1
  fi

  umask 022
  PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"
  export PATH
  NEED_REBOOT=0
  REBOOT_KERNEL=""
  ALLOW_VALUE=""
  LIVE_BBR=0
  LIVE_FQ=0
  SHARED_KERNEL=0
  VIRT_NAME=none
  VIRT_PHRASE=""
  PREPARED=0
  CHANGED_DEVS=""

  case $action in
    status)
      cmd_status
      ;;
    off)
      need_root "$@"
      make_workdir
      cmd_off
      ;;
    on)
      need_root "$@"
      make_workdir
      printf '%s\n' "BBR 一键脚本 $VERSION"
      say_info "先认出这台机器是公网还是 NAT、是自己的内核还是切出来的，再补缺少的组件，然后打开 BBR。"
      cmd_on
      exit $?
      ;;
  esac
}

if [ "${BBR_SOURCE_ONLY:-0}" != 1 ]; then
  main "$@"
fi
