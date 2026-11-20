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
# 再运行一次是安全的：已经开好的机器会核对开机配置。
# 机器上如果已经装过，再运行会先把 bbr 命令更新到新版本。
#
#   sh install.sh           打开 BBR
#   sh install.sh --status  只查看
#   sh install.sh --off     关掉本脚本打开的 BBR
#======================================================================

VERSION=1.1.1
INSTALLED_BBR=/usr/local/sbin/bbr

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
  printf '%s\n' "$1" | sed 's/[^0-9.].*$//; s/\.*$//'
}

version_ge() {
  vg_a=$(kernel_numeric "$1")
  vg_b=$(kernel_numeric "$2")
  case $vg_a in
    [0-9]*) ;;
    *) return 1 ;;
  esac
  case $vg_b in
    [0-9]*) ;;
    *) return 1 ;;
  esac
  vg_ra="${vg_a}.0.0"
  vg_rb="${vg_b}.0.0"
  vg_i=1
  while [ "$vg_i" -le 3 ]; do
    vg_pa=${vg_ra%%.*}
    vg_ra=${vg_ra#*.}
    vg_pb=${vg_rb%%.*}
    vg_rb=${vg_rb#*.}
    [ -n "$vg_pa" ] || vg_pa=0
    [ -n "$vg_pb" ] || vg_pb=0
    while :; do
      case $vg_pa in
        0?*) vg_pa=${vg_pa#0} ;;
        *) break ;;
      esac
    done
    while :; do
      case $vg_pb in
        0?*) vg_pb=${vg_pb#0} ;;
        *) break ;;
      esac
    done
    if [ "${#vg_pa}" -gt "${#vg_pb}" ]; then return 0; fi
    if [ "${#vg_pa}" -lt "${#vg_pb}" ]; then return 1; fi
    if [ "$vg_pa" -gt "$vg_pb" ]; then return 0; fi
    if [ "$vg_pa" -lt "$vg_pb" ]; then return 1; fi
    vg_i=$((vg_i + 1))
  done
  return 0
}

# 比较两个完整内核版本串（含发行版修订号，如 6.1.0-25-amd64 与 6.1.0-18-amd64）。
# $1 比 $2 新时返回 0。
kernel_version_newer() {
  kv_a=$(printf '%s' "$1" | sed 's/[^0-9][^0-9]*/ /g; s/^ *//; s/ *$//')
  kv_b=$(printf '%s' "$2" | sed 's/[^0-9][^0-9]*/ /g; s/^ *//; s/ *$//')
  [ -n "$kv_a" ] || return 1
  [ -n "$kv_b" ] || return 0
  while [ -n "$kv_a" ] || [ -n "$kv_b" ]; do
    if [ -n "$kv_a" ]; then
      kv_pa=${kv_a%% *}
      if [ "$kv_pa" = "$kv_a" ]; then kv_a=""; else kv_a=${kv_a#* }; fi
    else
      kv_pa=0
    fi
    if [ -n "$kv_b" ]; then
      kv_pb=${kv_b%% *}
      if [ "$kv_pb" = "$kv_b" ]; then kv_b=""; else kv_b=${kv_b#* }; fi
    else
      kv_pb=0
    fi
    while :; do
      case $kv_pa in
        0?*) kv_pa=${kv_pa#0} ;;
        *) break ;;
      esac
    done
    while :; do
      case $kv_pb in
        0?*) kv_pb=${kv_pb#0} ;;
        *) break ;;
      esac
    done
    if [ "${#kv_pa}" -gt "${#kv_pb}" ]; then return 0; fi
    if [ "${#kv_pa}" -lt "${#kv_pb}" ]; then return 1; fi
    if [ "$kv_pa" -gt "$kv_pb" ]; then return 0; fi
    if [ "$kv_pa" -lt "$kv_pb" ]; then return 1; fi
  done
  return 1
}

# $1 比 $2 新时返回 0。相等或更旧返回 1。
version_newer() {
  version_ge "$1" "$2" || return 1
  version_ge "$2" "$1" && return 1
  return 0
}

version_from_file() {
  [ -f "$1" ] || return 1
  sed -n "s/^VERSION=['\"]*\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p" "$1" | head -n 1
}

# 下载到的文件必须是本脚本，避免把错误页写成 bbr 命令。
remote_script_ok() {
  file=$1
  [ -f "$file" ] && [ -s "$file" ] || return 1
  head -n 1 "$file" | grep -q '^#!/bin/sh$' || return 1
  ver=$(version_from_file "$file")
  [ -n "$ver" ] || return 1
  grep -q 'bbr-onekey-begin' "$file" || return 1
  sh -n "$file" >/dev/null 2>&1
}

is_this_script() {
  remote_script_ok "$1"
}

# keep：正在运行的就是已安装的那份。
# replace：用这次运行的脚本盖掉已安装的文件。
# use-installed：已安装的版本更新，不要用旧文件盖回去。
# 还没有 bbr 命令时由调用方处理，不进这里。
installed_copy_action() {
  running=$1
  installed=$2
  same_file=$3
  if [ "$same_file" = 1 ]; then
    printf '%s\n' keep
    return 0
  fi
  if [ -n "$installed" ] && version_newer "$installed" "$running"; then
    printf '%s\n' use-installed
    return 0
  fi
  printf '%s\n' replace
}

# $1 是当前版本，$2 是发布地址上的版本。
remote_update_action() {
  running=$1
  remote=$2
  if [ -n "$remote" ] && version_newer "$remote" "$running"; then
    printf '%s\n' update
    return 0
  fi
  printf '%s\n' stay
}

# /usr/local/sbin 不在 PATH 里时，返回一个在 PATH 里的目录，用来放 bbr 命令。
shortcut_link_dir() {
  path=$1
  case ":$path:" in
    *:/usr/local/sbin:*|*:/usr/local/sbin/:*)
      printf '\n'
      return 0
      ;;
  esac
  for dir in /usr/sbin /sbin /usr/bin /bin; do
    case ":$path:" in
      *:"$dir":*|*:"$dir"/:*)
        printf '%s\n' "$dir"
        return 0
        ;;
    esac
  done
  printf '\n'
}

is_ipv4() {
  iv_raw=$1
  case $iv_raw in
    */*)
      iv_ip=${iv_raw%%/*}
      iv_pfx=${iv_raw#*/}
      case $iv_pfx in
        ''|*[!0-9]*) return 1 ;;
      esac
      while :; do
        case $iv_pfx in
          0?*) iv_pfx=${iv_pfx#0} ;;
          *) break ;;
        esac
      done
      [ "${#iv_pfx}" -le 2 ] && [ "$iv_pfx" -le 32 ] || return 1
      ;;
    *)
      iv_ip=$iv_raw
      ;;
  esac
  case $iv_ip in
    ''|*[!0-9.]*|.*|*.|*..*) return 1 ;;
  esac
  iv_o1=${iv_ip%%.*}
  iv_r1=${iv_ip#*.}
  [ "$iv_r1" != "$iv_ip" ] || return 1
  iv_o2=${iv_r1%%.*}
  iv_r2=${iv_r1#*.}
  [ "$iv_r2" != "$iv_r1" ] || return 1
  iv_o3=${iv_r2%%.*}
  iv_o4=${iv_r2#*.}
  [ "$iv_o4" != "$iv_r2" ] || return 1
  case $iv_o4 in
    *.*) return 1 ;;
  esac
  for iv_n in "$iv_o1" "$iv_o2" "$iv_o3" "$iv_o4"; do
    case $iv_n in
      ''|*[!0-9]*) return 1 ;;
    esac
    while :; do
      case $iv_n in
        0?*) iv_n=${iv_n#0} ;;
        *) break ;;
      esac
    done
    [ "${#iv_n}" -le 3 ] && [ "$iv_n" -le 255 ] || return 1
  done
  return 0
}

is_private_ipv4() {
  is_ipv4 "$1" || return 1
  pv_ip=${1%%/*}
  pv_a=${pv_ip%%.*}
  pv_r=${pv_ip#*.}
  pv_b=${pv_r%%.*}
  while :; do
    case $pv_a in
      0?*) pv_a=${pv_a#0} ;;
      *) break ;;
    esac
  done
  while :; do
    case $pv_b in
      0?*) pv_b=${pv_b#0} ;;
      *) break ;;
    esac
  done
  [ "$pv_a" -eq 0 ] && return 0
  [ "$pv_a" -eq 10 ] && return 0
  [ "$pv_a" -eq 127 ] && return 0
  [ "$pv_a" -ge 224 ] && return 0
  [ "$pv_a" -eq 169 ] && [ "$pv_b" -eq 254 ] && return 0
  [ "$pv_a" -eq 192 ] && [ "$pv_b" -eq 168 ] && return 0
  if [ "$pv_a" -eq 172 ] && [ "$pv_b" -ge 16 ] && [ "$pv_b" -le 31 ]; then
    return 0
  fi
  if [ "$pv_a" -eq 100 ] && [ "$pv_b" -ge 64 ] && [ "$pv_b" -le 127 ]; then
    return 0
  fi
  return 1
}

is_public_ipv6() {
  case $1 in
    ''|::|::1|[fF][eE][89aAbB]?:*|[fF][cCdD]*|[fF][fF]*) return 1 ;;
    *:*) return 0 ;;
    *) return 1 ;;
  esac
}

public_ipv6s() {
  p6_out=""
  for p6_ip in $1; do
    if is_public_ipv6 "$p6_ip"; then
      p6_out="$p6_out $p6_ip"
    fi
  done
  printf '%s' "$p6_out" | sed 's/^ *//'
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
    if is_public_ipv6 "$ip"; then
      printf '%s\n' ipv6
      return 0
    fi
  done
  printf '%s\n' unknown
}

# 参数：容器类型、虚拟机类型。打印「1 名称」或「0 名称」。
# 1 表示跟母鸡共用内核。只要认出是容器，就按共用内核处理。
classify_virt() {
  container=$1
  vm=$2
  if [ -n "$container" ]; then
    printf '1 %s\n' "$container"
    return 0
  fi
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
    docker|podman|rkt|crio|incus|proot|pouch|cri|container-other)
      printf '%s\n' "容器，跟母鸡共用内核"
      ;;
    systemd-nspawn) printf '%s\n' "容器，跟母鸡共用内核" ;;
    wsl) printf '%s\n' "WSL，跟母鸡共用内核" ;;
    container) printf '%s\n' "切出来的机器，跟母鸡共用内核" ;;
    kvm|qemu) printf '%s\n' "KVM 虚拟机，自己的内核" ;;
    xen) printf '%s\n' "Xen 虚拟机，自己的内核" ;;
    vmware) printf '%s\n' "VMware 虚拟机，自己的内核" ;;
    virtualbox) printf '%s\n' "VirtualBox 虚拟机，自己的内核" ;;
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
      if [ -n "$locals" ]; then
        printf '有公网 IPv6（%s）\n' "$locals"
      else
        printf '%s\n' "有公网 IPv6"
      fi
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
# 同时支持 systemd 的 - 前缀和 / 分隔写法。
is_managed_sysctl_line() {
  mq=${2:-${MANAGE_QDISC:-1}}
  if [ "$mq" = 1 ]; then
    printf '%s\n' "$1" | tr -d '\r' | grep -E -q '^-?net[./](core[./]default_qdisc|ipv4[./]tcp_(allowed_)?congestion_control)[[:space:]]*=' && return 0
  else
    printf '%s\n' "$1" | tr -d '\r' | grep -E -q '^-?net[./]ipv4[./]tcp_(allowed_)?congestion_control[[:space:]]*=' && return 0
  fi
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
      if [ -n "${DESIRED_BLOCK:-}" ]; then
        printf '%s\n' "# bbr-onekey: 改由脚本末尾这块管理"
      else
        printf '%s\n' "# bbr-onekey: 改由 zzz-bbr.conf 管理"
      fi
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
  restore_bbr_text | comment_live_bbr
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
  ol_stripped=$(printf '%s' "$1" | tr -d '\r')
  is_managed_sysctl_line "$ol_stripped" 1 || return 1
  ol_key=$(printf '%s' "$ol_stripped" | sed 's/^-//; s/[[:space:]]*=.*//' | tr '/' '.')
  case $ol_key in
    net.ipv4.tcp_allowed_congestion_control) return 1 ;;
  esac
  ol_val=$(printf '%s' "$ol_stripped" | sed 's/^[^=]*=[[:space:]]*//; s/[[:space:]]*[#;].*$//; s/[[:space:]]*$//')
  case $ol_key in
    net.ipv4.tcp_congestion_control) [ "$ol_val" = bbr ] ;;
    net.core.default_qdisc) [ "$ol_val" = fq ] ;;
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
  osrel=""
  if [ -r /etc/os-release ]; then
    osrel=/etc/os-release
  elif [ -r /usr/lib/os-release ]; then
    osrel=/usr/lib/os-release
  fi
  if [ -n "$osrel" ]; then
    OS_ID=$(sed -n 's/^ID=//p' "$osrel" | head -n 1 | tr -d "\"'")
    OS_VERSION=$(sed -n 's/^VERSION_ID=//p' "$osrel" | head -n 1 | tr -d "\"'")
    OS_PRETTY=$(sed -n 's/^PRETTY_NAME=//p' "$osrel" | head -n 1 | tr -d "\"'")
  fi
  if [ -r /etc/openwrt_release ]; then
    if [ "$PM" = none ] && command -v opkg >/dev/null 2>&1; then
      PM=opkg
    fi
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
      [ "$container" = none ] && container=""
    fi
    vm=$(systemd-detect-virt --vm 2>/dev/null || true)
    [ "$vm" = none ] && vm=""
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
    env_c=$(tr '\0' '\n' < /proc/1/environ 2>/dev/null | sed -n 's/^container=//p' | head -n 1 || true)
    [ -n "$env_c" ] && container=$env_c
  fi
  if [ -z "$container" ] && [ -r /proc/1/cgroup ]; then
    if grep -E -q 'docker|lxc|kubepods|containerd' /proc/1/cgroup 2>/dev/null; then
      container=container
    fi
  fi
  if [ -z "$container" ] && [ -z "$vm" ]; then
    dmi=""
    for df_f in /sys/class/dmi/id/product_name /sys/class/dmi/id/sys_vendor /sys/class/dmi/id/bios_vendor; do
      if [ -r "$df_f" ]; then
        dmi="$dmi $(cat "$df_f" 2>/dev/null || true)"
      fi
    done
    case $dmi in
      *KVM*|*QEMU*) vm=kvm ;;
      *VMware*) vm=vmware ;;
      *VirtualBox*) vm=virtualbox ;;
      *Xen*) vm=xen ;;
      *Hyper-V*) vm=microsoft ;;
      *"Amazon EC2"*) vm=amazon ;;
      *"Google Compute"*) vm=google ;;
    esac
    if [ -z "$vm" ] && [ -r /proc/xen/capabilities ]; then
      vm=xen
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
  if [ "$NET_KIND" = ipv6 ]; then
    NET_LOCAL=$(public_ipv6s "$ipv6s")
  else
    NET_LOCAL=$(printf '%s' "$locals" | sed 's/[[:space:]]*$//')
  fi
  NET_EGRESS=""
  if [ "$NET_KIND" = nat ]; then
    NET_EGRESS=$(fetch_egress_v4 2>/dev/null | tr -d '\r\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' || true)
    case $NET_EGRESS in
      */*) NET_EGRESS="" ;;
    esac
    if ! is_ipv4 "$NET_EGRESS"; then
      NET_EGRESS=""
    fi
  fi
  NET_PHRASE=$(network_phrase "$NET_KIND" "$NET_LOCAL" "$NET_EGRESS")
}

wget_supports_tries() {
  wget --help 2>&1 | grep -q -- '--tries'
}

wget_supports_ipv4() {
  wget --help 2>&1 | grep -q -- '-4'
}

fetch_egress_v4() {
  url=https://api.ipify.org
  if command -v curl >/dev/null 2>&1; then
    curl -4 -fsS --connect-timeout 3 --max-time 4 "$url" 2>/dev/null && return 0
  fi
  if command -v wget >/dev/null 2>&1; then
    if wget_supports_tries && wget_supports_ipv4; then
      wget -4 -qO- -T 4 -t 1 "$url" 2>/dev/null && return 0
    elif wget_supports_tries; then
      wget -qO- -T 4 -t 1 "$url" 2>/dev/null && return 0
    else
      wget -qO- -T 4 "$url" 2>/dev/null && return 0
    fi
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
  printf '%s\n' "$list" | tr ' \t' '\n' | grep -F -x -q -- "$word"
}

cc_has_bbr() {
  word_in bbr "$(read_sysctl net.ipv4.tcp_available_congestion_control)"
}

kb_free_dir() {
  dir=${1:-/}
  free=$(LC_ALL=C df -Pk "$dir" 2>/dev/null | awk 'NR==2 {print $4}')
  case $free in
    ''|*[!0-9]*)
      free=$(LC_ALL=C df -k "$dir" 2>/dev/null | awk 'NR>=2 {val=$(NF-2)} END {print val}')
      ;;
  esac
  printf '%s\n' "$free"
}

kb_free_root() {
  kb_free_dir /
}

have_space() {
  need=$1
  dir=${2:-/}
  free=$(kb_free_dir "$dir")
  case $free in
    ''|*[!0-9]*) return 0 ;;
  esac
  [ "$free" -ge "$need" ]
}

kconfig_state() {
  key=$1
  krel=$(uname -r)
  file=""
  for c in "/boot/config-$krel" "/lib/modules/$krel/config" "/lib/modules/$krel/build/.config"; do
    if [ -f "$c" ] && [ -r "$c" ]; then
      file=$c
      break
    fi
  done
  if [ -n "$file" ]; then
    line=$(grep "^$key=" "$file" 2>/dev/null | head -n 1)
    if [ -z "$line" ]; then
      if grep -q -e "^# $key is not set" -e '^CONFIG_' "$file" 2>/dev/null; then
        printf '%s\n' n
        return 0
      fi
    fi
  elif [ -r /proc/config.gz ] && command -v gzip >/dev/null 2>&1; then
    line=$(gzip -dc /proc/config.gz 2>/dev/null | grep "^$key=" | head -n 1)
    if [ -z "$line" ]; then
      if gzip -dc /proc/config.gz 2>/dev/null | grep -q -e "^# $key is not set" -e '^CONFIG_'; then
        printf '%s\n' n
        return 0
      fi
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

files_equal() {
  [ -f "$1" ] && [ -f "$2" ] || return 1
  if command -v cmp >/dev/null 2>&1; then
    cmp -s "$1" "$2"
    return $?
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    fe_a=$(sha256sum "$1" 2>/dev/null | awk '{print $1}')
    fe_b=$(sha256sum "$2" 2>/dev/null | awk '{print $1}')
    [ -n "$fe_a" ] && [ "$fe_a" = "$fe_b" ]
    return $?
  fi
  if command -v md5sum >/dev/null 2>&1; then
    fe_a=$(md5sum "$1" 2>/dev/null | awk '{print $1}')
    fe_b=$(md5sum "$2" 2>/dev/null | awk '{print $1}')
    [ -n "$fe_a" ] && [ "$fe_a" = "$fe_b" ]
    return $?
  fi
  if command -v cksum >/dev/null 2>&1; then
    fe_a=$(cksum "$1" 2>/dev/null | awk '{print $1, $2}')
    fe_b=$(cksum "$2" 2>/dev/null | awk '{print $1, $2}')
    [ -n "$fe_a" ] && [ "$fe_a" = "$fe_b" ]
    return $?
  fi
  return 1
}

apt_retry() {
  rounds=$1
  shift
  i=0
  while [ "$i" -lt "$rounds" ]; do
    if (export LC_ALL=C LANGUAGE=C; "$@") >"$WORKDIR/apt.log" 2>&1; then
      return 0
    fi
    if grep -q -e 'Could not get lock' -e 'Unable to acquire' -e 'Unable to lock' "$WORKDIR/apt.log"; then
      i=$((i + 1))
      if [ "$i" -lt "$rounds" ]; then
        say_warn "apt 正被系统更新占用，等待 20 秒后重试（$i/$rounds）"
        sleep 20
        continue
      fi
      return 1
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
    | sed -nE 's#^https?://([^/]+)/ubuntu(-ports)?(/.*)?$#\1#p' \
    | grep -v '^old-releases\.ubuntu\.com$' \
    | sort -u
}

rewrite_ubuntu_sources_file() {
  ru_file=$1
  ru_hosts=$2
  [ -f "$ru_file" ] && [ -w "$ru_file" ] || return 0
  cp "$ru_file" "$WORKDIR/sources.tmp" 2>/dev/null || return 0
  while IFS= read -r ru_host; do
    [ -n "$ru_host" ] || continue
    ru_esc=$(printf '%s' "$ru_host" | sed 's/[].[*^$()+?{|\\]/\\&/g')
    sed -E "s#https?://${ru_esc}/ubuntu(-ports)?#http://old-releases.ubuntu.com/ubuntu#g" "$WORKDIR/sources.tmp" > "$WORKDIR/sources.next" \
      && mv "$WORKDIR/sources.next" "$WORKDIR/sources.tmp"
  done < "$ru_hosts"
  if ! files_equal "$WORKDIR/sources.tmp" "$ru_file"; then
    cat "$WORKDIR/sources.tmp" > "$ru_file"
  fi
  rm -f "$WORKDIR/sources.tmp" "$WORKDIR/sources.next"
}

ubuntu_try_old_releases() {
  [ "$OS_ID" = ubuntu ] || return 1
  hosts=$(ubuntu_eol_hosts || true)
  [ -n "$hosts" ] || return 1
  say_info "检测到 Ubuntu 源已停止维护，只把失效的 Ubuntu 归档换成 old-releases"
  printf '%s\n' "$hosts" > "$WORKDIR/eol-hosts"
  rewrite_ubuntu_sources_file /etc/apt/sources.list "$WORKDIR/eol-hosts"
  for ru_f in /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
    [ -f "$ru_f" ] || continue
    rewrite_ubuntu_sources_file "$ru_f" "$WORKDIR/eol-hosts"
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
      LC_ALL=C LANGUAGE=C apk update >/dev/null 2>&1 || say_warn "apk 源更新失败，继续尝试安装"
      ;;
    dnf)
      LC_ALL=C LANGUAGE=C dnf makecache -y >"$WORKDIR/rpm.log" 2>&1 || true
      ;;
    yum)
      LC_ALL=C LANGUAGE=C yum makecache fast -y >"$WORKDIR/rpm.log" 2>&1 \
        || LC_ALL=C LANGUAGE=C yum makecache -y >"$WORKDIR/rpm.log" 2>&1 || true
      ;;
    pacman)
      LC_ALL=C LANGUAGE=C pacman -Sy --noconfirm >"$WORKDIR/pacman.log" 2>&1 || true
      ;;
    zypper)
      LC_ALL=C LANGUAGE=C zypper --non-interactive refresh >"$WORKDIR/zypper.log" 2>&1 || true
      ;;
    opkg)
      LC_ALL=C LANGUAGE=C opkg update >"$WORKDIR/opkg.log" 2>&1 || say_warn "opkg 源更新失败，继续尝试安装"
      ;;
    xbps)
      LC_ALL=C LANGUAGE=C xbps-install -S >"$WORKDIR/xbps.log" 2>&1 || true
      ;;
  esac
  PREPARED=1
}

show_log_tail() {
  log=$1
  [ -f "$log" ] || return 0
  tail -n 15 "$log" >&2 || true
}

# 打印 ok / missing / failed。rc 为 0 时是 ok。
# 「No package」优先于「Nothing to do」，避免把找不到的包当成装好了。
rpm_log_kind() {
  log=$1
  rc=$2
  if [ "$rc" -eq 0 ]; then
    printf '%s\n' ok
    return 0
  fi
  if [ -f "$log" ] && grep -q -e 'No match for argument' -e 'No matching Packages' -e 'No package' -e 'Error: Unable to find a match' "$log"; then
    printf '%s\n' missing
    return 0
  fi
  if [ -f "$log" ] && grep -q 'Nothing to do' "$log"; then
    printf '%s\n' ok
    return 0
  fi
  printf '%s\n' failed
}

# 0 装好了，1 源里没有这个包，2 装的过程失败。
pm_install_one() {
  pm_pkg=$1
  if [ "$PM" = none ]; then
    return 1
  fi
  pm_min_kb=20480
  pm_min_label=20MB
  if [ "$OS_ID" = openwrt ] || [ "$PM" = opkg ]; then
    pm_min_kb=2048
    pm_min_label=2MB
  fi
  if ! have_space "$pm_min_kb"; then
    say_err "磁盘剩余空间不足 ${pm_min_label}，停止安装，避免把系统写满"
    return 2
  fi
  pm_prepare
  case $PM in
    apt)
      if ! LC_ALL=C LANGUAGE=C apt-cache show "$pm_pkg" >/dev/null 2>&1; then
        return 1
      fi
      say_info "正在安装 $pm_pkg"
      if apt_retry 4 apt_install_pkg "$pm_pkg"; then
        return 0
      fi
      if grep -q -e 'Unable to locate package' -e 'has no installation candidate' "$WORKDIR/apt.log"; then
        return 1
      fi
      say_err "安装 $pm_pkg 失败，系统原话："
      show_log_tail "$WORKDIR/apt.log"
      return 2
      ;;
    dnf|yum)
      say_info "正在安装 $pm_pkg"
      if [ "$PM" = dnf ]; then
        LC_ALL=C LANGUAGE=C dnf install -y "$pm_pkg" >"$WORKDIR/rpm.log" 2>&1
      else
        LC_ALL=C LANGUAGE=C yum install -y "$pm_pkg" >"$WORKDIR/rpm.log" 2>&1
      fi
      pm_rc=$?
      pm_kind=$(rpm_log_kind "$WORKDIR/rpm.log" "$pm_rc")
      case $pm_kind in
        ok) return 0 ;;
        missing) return 1 ;;
      esac
      say_err "安装 $pm_pkg 失败，系统原话："
      show_log_tail "$WORKDIR/rpm.log"
      return 2
      ;;
    apk)
      say_info "正在安装 $pm_pkg"
      if LC_ALL=C LANGUAGE=C apk add --no-cache "$pm_pkg" >"$WORKDIR/apk.log" 2>&1; then
        return 0
      fi
      if grep -q -e 'no such package' -e 'unsatisfiable' -e 'could not satisfy' "$WORKDIR/apk.log"; then
        return 1
      fi
      say_err "安装 $pm_pkg 失败，系统原话："
      show_log_tail "$WORKDIR/apk.log"
      return 2
      ;;
    pacman)
      say_info "正在安装 $pm_pkg"
      if LC_ALL=C LANGUAGE=C pacman -S --noconfirm --needed "$pm_pkg" >"$WORKDIR/pacman.log" 2>&1; then
        return 0
      fi
      if grep -q -e 'target not found' -e '未找到目标' "$WORKDIR/pacman.log"; then
        return 1
      fi
      say_err "安装 $pm_pkg 失败，系统原话："
      show_log_tail "$WORKDIR/pacman.log"
      return 2
      ;;
    zypper)
      say_info "正在安装 $pm_pkg"
      if LC_ALL=C LANGUAGE=C zypper --non-interactive install --no-recommends "$pm_pkg" >"$WORKDIR/zypper.log" 2>&1; then
        return 0
      fi
      if grep -q -e 'not found' -e 'No provider' "$WORKDIR/zypper.log"; then
        return 1
      fi
      say_err "安装 $pm_pkg 失败，系统原话："
      show_log_tail "$WORKDIR/zypper.log"
      return 2
      ;;
    opkg)
      say_info "正在安装 $pm_pkg"
      LC_ALL=C LANGUAGE=C opkg install "$pm_pkg" >"$WORKDIR/opkg.log" 2>&1 || true
      if LC_ALL=C LANGUAGE=C opkg status "$pm_pkg" 2>/dev/null | grep -q 'Status: install'; then
        return 0
      fi
      if grep -q 'Unknown package' "$WORKDIR/opkg.log"; then
        return 1
      fi
      say_err "安装 $pm_pkg 失败，系统原话："
      show_log_tail "$WORKDIR/opkg.log"
      return 2
      ;;
    xbps)
      say_info "正在安装 $pm_pkg"
      if LC_ALL=C LANGUAGE=C xbps-install -y "$pm_pkg" >"$WORKDIR/xbps.log" 2>&1; then
        return 0
      fi
      if grep -q 'not found' "$WORKDIR/xbps.log"; then
        return 1
      fi
      say_err "安装 $pm_pkg 失败，系统原话："
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
  ensure_cmd ip iproute2 iproute ip-full ip-tiny || true
  ensure_cmd tc iproute2 iproute-tc iproute tc-tiny tc-full tc || true
}

module_file_exists() {
  mf_name=$1
  mf_krel=$(uname -r)
  mf_dir="/lib/modules/$mf_krel"
  [ -d "$mf_dir" ] || return 1
  find "$mf_dir" \( -type f -o -type l \) \( \
    -name "${mf_name}.ko" -o -name "${mf_name}.ko.xz" -o -name "${mf_name}.ko.gz" \
    -o -name "${mf_name}.ko.zst" -o -name "${mf_name}.ko.bz2" \
  \) 2>/dev/null | grep -q .
}

module_sysfs() {
  [ -e "/sys/module/$1" ]
}

load_module() {
  lm_name=$1
  if module_sysfs "$lm_name"; then
    return 0
  fi
  if ! command -v modprobe >/dev/null 2>&1; then
    return 1
  fi
  if LC_ALL=C LANGUAGE=C modprobe "$lm_name" >"$WORKDIR/modprobe.err" 2>&1; then
    return 0
  fi
  if module_file_exists "$lm_name" && command -v depmod >/dev/null 2>&1; then
    depmod -a >/dev/null 2>&1 || true
    if LC_ALL=C LANGUAGE=C modprobe "$lm_name" >"$WORKDIR/modprobe.err" 2>&1; then
      return 0
    fi
  fi
  module_sysfs "$lm_name"
}

fq_available_hint() {
  sysctl_accepts_fq && return 0
  module_sysfs sch_fq && return 0
  module_file_exists sch_fq && return 0
  fa_krel=$(uname -r)
  if [ -f "/lib/modules/$fa_krel/modules.builtin" ] && grep -q 'sch_fq\.ko' "/lib/modules/$fa_krel/modules.builtin" 2>/dev/null; then
    return 0
  fi
  [ "$(kconfig_state CONFIG_NET_SCH_FQ)" = y ] && return 0
  return 1
}

try_install_fq_module() {
  [ "$SHARED_KERNEL" = 1 ] && return 1
  fq_available_hint && return 0
  fq_krel=$(uname -r)
  if [ "$OS_ID" = openwrt ]; then
    pm_install_one kmod-sched || true
    load_module sch_fq || true
    return 0
  fi
  [ "$(kconfig_state CONFIG_NET_SCH_FQ)" = m ] || return 1
  if ! have_space 81920; then
    return 1
  fi
  case $PM in
    apt)
      pm_install_one "linux-modules-extra-$fq_krel" || true
      ;;
    dnf|yum)
      pm_install_one "kernel-modules-extra-$fq_krel" || pm_install_one "kernel-modules-$fq_krel" || true
      ;;
    *)
      return 1
      ;;
  esac
  if command -v depmod >/dev/null 2>&1; then
    depmod -a >/dev/null 2>&1 || true
  fi
  load_module sch_fq || true
}

try_install_current_modules() {
  krel=$(uname -r)
  if [ "$OS_ID" = openwrt ] || [ "$PM" = opkg ]; then
    if ! have_space 2048; then
      say_warn "剩余磁盘空间不足 2MB，跳过安装内核模块，避免把磁盘写满"
      return 1
    fi
    pm_install_one kmod-tcp-bbr || true
    load_module sch_fq || true
    if ! fq_available_hint; then
      pm_install_one kmod-sched || true
    fi
    load_module tcp_bbr || true
    load_module sch_fq || true
    cc_has_bbr
    return $?
  fi
  if ! have_space 81920; then
    say_warn "剩余磁盘空间不足 80MB，跳过安装内核模块，避免把磁盘写满"
    return 1
  fi
  case $PM in
    apt)
      for pkg in "linux-modules-$krel" "linux-modules-extra-$krel" "linux-image-$krel"; do
        pm_install_one "$pkg" || true
        load_module tcp_bbr || true
        load_module sch_fq || true
        if cc_has_bbr; then
          try_install_fq_module || true
          return 0
        fi
      done
      ;;
    dnf|yum)
      for pkg in "kernel-modules-$krel" "kernel-modules-core-$krel" "kernel-modules-extra-$krel" "kernel-uek-modules-$krel"; do
        pm_install_one "$pkg" || true
        load_module tcp_bbr || true
        load_module sch_fq || true
        if cc_has_bbr; then
          try_install_fq_module || true
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
    xbps)
      pm_install_one linux || true
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
  ks_ver=$1
  ks_dir="/lib/modules/$ks_ver"
  if [ -d "$ks_dir" ]; then
    if find "$ks_dir" \( -type f -o -type l \) \( \
      -name 'tcp_bbr.ko' -o -name 'tcp_bbr.ko.xz' -o -name 'tcp_bbr.ko.gz' \
      -o -name 'tcp_bbr.ko.zst' -o -name 'tcp_bbr.ko.bz2' \
    \) 2>/dev/null | grep -q .; then
      return 0
    fi
    if [ -f "$ks_dir/modules.builtin" ] && grep -q 'tcp_bbr\.ko' "$ks_dir/modules.builtin" 2>/dev/null; then
      return 0
    fi
  fi
  if [ -f "/boot/config-$ks_ver" ] && grep -q '^CONFIG_TCP_CONG_BBR=y' "/boot/config-$ks_ver"; then
    return 0
  fi
  if [ -d "$ks_dir" ] || [ -f "/boot/config-$ks_ver" ]; then
    return 1
  fi
  return 0
}

boot_images() {
  ls -1 /boot/vmlinuz-* 2>/dev/null || true
}

boot_snapshot() {
  ls -1 /boot/vmlinuz-* 2>/dev/null || true
  printf '%s\n' "---"
  ls -1 /lib/modules 2>/dev/null || true
}

prefer_boot_kernel() {
  ver=$1
  if command -v grubby >/dev/null 2>&1 && [ -f "/boot/vmlinuz-$ver" ]; then
    grubby --set-default "/boot/vmlinuz-$ver" >/dev/null 2>&1 || true
  fi
}

has_fixed_boot_image() {
  for fi_img in /boot/vmlinuz-lts /boot/vmlinuz-virt /boot/vmlinuz-edge /boot/vmlinuz-vanilla /boot/vmlinuz-linux /boot/vmlinuz-linux-*; do
    [ -f "$fi_img" ] && return 0
  done
  return 1
}

find_bootable_kernel() {
  current=$(uname -r)
  best=""
  for img in /boot/vmlinuz-*; do
    [ -f "$img" ] || continue
    ver=${img#/boot/vmlinuz-}
    case $ver in
      ''|'*'|*-rescue-*|*.old|*.bak|*.dpkg-*|*.rpmsave|*.rpmnew) continue ;;
    esac
    [ "$ver" = "$current" ] && continue
    version_ge "$ver" 4.9 || continue
    kernel_ship_bbr "$ver" || continue
    if [ -z "$best" ]; then
      best=$ver
      continue
    fi
    if kernel_version_newer "$ver" "$best"; then
      best=$ver
    fi
  done
  if [ -z "$best" ] && has_fixed_boot_image && [ -d /lib/modules ]; then
    for mdir in /lib/modules/*; do
      [ -d "$mdir" ] || continue
      ver=${mdir#/lib/modules/}
      case $ver in
        ''|'*') continue ;;
      esac
      [ "$ver" = "$current" ] && continue
      version_ge "$ver" 4.9 || continue
      kernel_ship_bbr "$ver" || continue
      if [ -z "$best" ]; then
        best=$ver
        continue
      fi
      if kernel_version_newer "$ver" "$best"; then
        best=$ver
      fi
    done
  fi
  if [ -n "$best" ] && [ "$best" != "$current" ]; then
    printf '%s\n' "$best"
  fi
}

install_distro_kernel() {
  if ! have_space 512000 /; then
    say_warn "剩余磁盘空间不足 500MB，不安装新内核，避免把磁盘写满"
    return 1
  fi
  if [ -d /boot ] && ! have_space 61440 /boot; then
    say_warn "/boot 分区剩余空间不足 60MB，不安装新内核，避免把 /boot 写满"
    return 1
  fi
  case $PM in
    apt)
      pm_prepare
      krel=$(uname -r)
      pkg=""
      case $krel in
        *rpi*|*raspi*)
          if LC_ALL=C LANGUAGE=C apt-cache show linux-image-raspi >/dev/null 2>&1; then
            pkg=linux-image-raspi
          elif LC_ALL=C LANGUAGE=C apt-cache show raspberrypi-kernel >/dev/null 2>&1; then
            pkg=raspberrypi-kernel
          fi
          ;;
      esac
      if [ -z "$pkg" ]; then
        case $OS_ID in
          ubuntu|linuxmint|pop|neon|elementary|zorin)
            case $OS_VERSION in
              16.04)
                if LC_ALL=C LANGUAGE=C apt-cache show linux-generic-hwe-16.04 >/dev/null 2>&1; then
                  pkg=linux-generic-hwe-16.04
                fi
                ;;
              18.04)
                if LC_ALL=C LANGUAGE=C apt-cache show linux-generic-hwe-18.04 >/dev/null 2>&1; then
                  pkg=linux-generic-hwe-18.04
                fi
                ;;
            esac
            if [ -z "$pkg" ] && LC_ALL=C LANGUAGE=C apt-cache show linux-generic >/dev/null 2>&1; then
              pkg=linux-generic
            fi
            ;;
          *)
            arch=$(dpkg --print-architecture 2>/dev/null || true)
            if [ -n "$arch" ] && LC_ALL=C LANGUAGE=C apt-cache show "linux-image-$arch" >/dev/null 2>&1; then
              pkg="linux-image-$arch"
            elif LC_ALL=C LANGUAGE=C apt-cache show linux-image-generic >/dev/null 2>&1; then
              pkg=linux-image-generic
            elif LC_ALL=C LANGUAGE=C apt-cache show linux-generic >/dev/null 2>&1; then
              pkg=linux-generic
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
        if ! rpm -q elrepo-release >/dev/null 2>&1; then
          if ! LC_ALL=C LANGUAGE=C rpm --import https://www.elrepo.org/RPM-GPG-KEY-elrepo.org >"$WORKDIR/elrepo.log" 2>&1; then
            say_err "没能导入 ELRepo 签名，不安装新内核"
            show_log_tail "$WORKDIR/elrepo.log"
            return 1
          fi
          say_info "正在安装 ELRepo 源"
          if [ "$PM" = dnf ]; then
            LC_ALL=C LANGUAGE=C dnf install -y https://www.elrepo.org/elrepo-release-7.el7.elrepo.noarch.rpm >"$WORKDIR/elrepo.log" 2>&1
          else
            LC_ALL=C LANGUAGE=C yum install -y https://www.elrepo.org/elrepo-release-7.el7.elrepo.noarch.rpm >"$WORKDIR/elrepo.log" 2>&1
          fi
          el_rc=$?
          if [ "$(rpm_log_kind "$WORKDIR/elrepo.log" "$el_rc")" != ok ]; then
            say_err "ELRepo 源安装失败，系统原话："
            show_log_tail "$WORKDIR/elrepo.log"
            return 1
          fi
        fi
        say_info "正在安装 kernel-ml"
        if [ "$PM" = dnf ]; then
          LC_ALL=C LANGUAGE=C dnf --enablerepo=elrepo-kernel install -y kernel-ml >"$WORKDIR/elrepo.log" 2>&1
        else
          LC_ALL=C LANGUAGE=C yum --enablerepo=elrepo-kernel install -y kernel-ml >"$WORKDIR/elrepo.log" 2>&1
        fi
        el_rc=$?
        if [ "$(rpm_log_kind "$WORKDIR/elrepo.log" "$el_rc")" != ok ]; then
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
      if [ "$OS_ID" = openwrt ]; then
        return 1
      fi
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
    xbps)
      pm_install_one linux
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
    try_install_fq_module || true
    return 0
  fi
  if [ "$SHARED_KERNEL" = 1 ]; then
    explain_shared_kernel_blocked
    return 2
  fi
  before_boot=$(boot_snapshot)
  cfg=$(kconfig_state CONFIG_TCP_CONG_BBR)
  if [ "$cfg" = m ] || { version_ge "$(uname -r)" 4.9 && [ "$cfg" != n ]; }; then
    say_info "内核里还没有 tcp_bbr，准备从系统软件源安装对应模块"
    try_install_current_modules || true
    load_module tcp_bbr || true
    load_module sch_fq || true
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
  after_try=$(boot_snapshot)
  if [ "$before_boot" != "$after_try" ]; then
    NEED_REBOOT=1
    REBOOT_KERNEL=""
    return 3
  fi
  if install_distro_kernel; then
    after_boot=$(boot_snapshot)
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
    LC_ALL=C LANGUAGE=C sysctl -w "$key=$val" >"$WORKDIR/sysctl.err" 2>&1
    return $?
  fi
  path=$(printf '%s' "$key" | sed 's/\./\//g')
  if [ -e "/proc/sys/$path" ]; then
    (export LC_ALL=C LANGUAGE=C; printf '%s\n' "$val" > "/proc/sys/$path") 2>"$WORKDIR/sysctl.err"
    return $?
  fi
  printf '%s\n' "No such file or directory: /proc/sys/$path" > "$WORKDIR/sysctl.err"
  return 1
}

sysctl_error_kind() {
  if [ ! -f "$WORKDIR/sysctl.err" ]; then
    printf '%s\n' other
    return 0
  fi
  if grep -q -i \
    -e 'permission denied' -e 'operation not permitted' -e 'read-only' -e 'read only' \
    -e '权限不够' -e '不允许的操作' -e '只读' \
    "$WORKDIR/sysctl.err"; then
    printf '%s\n' denied
    return 0
  fi
  if grep -q -i -e 'invalid argument' -e 'invalid' -e '无效的参数' "$WORKDIR/sysctl.err"; then
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
  SYSCTL_READONLY=0
  load_module tcp_bbr || true
  load_module sch_fq || true
  allow_bbr || true
  write_sysctl_key net.core.default_qdisc fq || true
  if [ "$(read_sysctl net.core.default_qdisc)" = fq ]; then
    LIVE_FQ=1
  fi
  if ! cc_has_bbr; then
    load_module tcp_bbr || true
  fi
  if write_sysctl_key net.ipv4.tcp_congestion_control bbr; then
    if [ "$(read_sysctl net.ipv4.tcp_congestion_control)" = bbr ]; then
      LIVE_BBR=1
    fi
  else
    kind=$(sysctl_error_kind)
    if [ "$(read_sysctl net.ipv4.tcp_congestion_control)" = bbr ]; then
      LIVE_BBR=1
      if [ "$kind" = denied ]; then
        SYSCTL_READONLY=1
      fi
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

sysctl_file_has_managed() {
  sf_file=$1
  [ -f "$sf_file" ] || return 1
  if grep -q '^# bbr-onekey-begin$' "$sf_file" 2>/dev/null; then
    return 0
  fi
  if [ "${MANAGE_QDISC:-1}" = 1 ]; then
    tr -d '\r' < "$sf_file" 2>/dev/null \
      | grep -E -q '^[[:space:]]*-?net[./](core[./]default_qdisc|ipv4[./]tcp_(allowed_)?congestion_control)[[:space:]]*='
    return $?
  else
    tr -d '\r' < "$sf_file" 2>/dev/null \
      | grep -E -q '^[[:space:]]*-?net[./]ipv4[./]tcp_(allowed_)?congestion_control[[:space:]]*='
    return $?
  fi
}

sysctl_file_has_bbr_or_marker() {
  sb_file=$1
  [ -f "$sb_file" ] || return 1
  if grep -q '^# bbr-onekey' "$sb_file" 2>/dev/null; then
    return 0
  fi
  tr -d '\r' < "$sb_file" 2>/dev/null \
    | grep -E -q '^[[:space:]]*-?net[./](core[./]default_qdisc|ipv4[./]tcp_congestion_control)[[:space:]]*='
}

rewrite_sysctl_file() {
  file=$1
  block=$2
  [ -f "$file" ] || return 0
  [ -w "$file" ] || { say_warn "写不了 $file"; return 1; }
  DESIRED_BLOCK=$block
  apply_sysctl_text < "$file" > "$WORKDIR/sysctl-out" || return 1
  if ! files_equal "$WORKDIR/sysctl-out" "$file"; then
    cat "$WORKDIR/sysctl-out" > "$file" || { say_warn "写不了 $file"; return 1; }
  fi
}

disable_sysctl_file() {
  file=$1
  [ -f "$file" ] || return 0
  [ -w "$file" ] || return 0
  sysctl_file_has_bbr_or_marker "$file" || return 0
  disable_bbr_text < "$file" > "$WORKDIR/sysctl-out" || return 1
  if ! files_equal "$WORKDIR/sysctl-out" "$file"; then
    cat "$WORKDIR/sysctl-out" > "$file"
  fi
}

each_sysctl_d_file() {
  if [ -d /etc/sysctl.d ]; then
    for f in /etc/sysctl.d/*.conf; do
      [ -f "$f" ] || continue
      base=${f##*/}
      [ "$base" = zzz-bbr.conf ] && continue
      if [ -f /etc/sysctl.conf ] && [ "$f" -ef /etc/sysctl.conf ]; then
        continue
      fi
      printf '%s\n' "$f"
    done
  fi
}

persist_sysctl() {
  PERSIST_OK=1
  if ! mkdir -p /etc/sysctl.d 2>/dev/null; then
    say_warn "创建 /etc/sysctl.d 失败，开机配置可能没写进去"
    PERSIST_OK=0
  else
    # 先写上本脚本的配置，再改掉其它文件里的旧设置。中途失败时也不会把原来的设置删光。
    if ! {
      printf '%s\n' "# 由 BBR 一键脚本 $VERSION 写入。再运行一次会覆盖本文件。"
      printf '%s\n' "# bbr-onekey-begin"
      printf '%s\n' "$PERSIST_BLOCK"
      printf '%s\n' "# bbr-onekey-end"
    } > /etc/sysctl.d/zzz-bbr.conf 2>/dev/null; then
      say_warn "写不了 /etc/sysctl.d/zzz-bbr.conf，开机配置可能没写进去"
      PERSIST_OK=0
    fi
  fi
  if [ -f /etc/sysctl.conf ]; then
    if ! rewrite_sysctl_file /etc/sysctl.conf "$PERSIST_BLOCK"; then
      PERSIST_OK=0
    fi
  fi
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if sysctl_file_has_managed "$f"; then
      rewrite_sysctl_file "$f" "" || true
    fi
  done <<EOF
$(each_sysctl_d_file)
EOF
  [ "$PERSIST_OK" = 1 ]
}

clear_sysctl() {
  if [ -f /etc/sysctl.conf ]; then
    disable_sysctl_file /etc/sysctl.conf || true
  fi
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    disable_sysctl_file "$f" || true
  done <<EOF
$(each_sysctl_d_file)
EOF
  rm -f /etc/sysctl.d/zzz-bbr.conf
}

module_loaded_dyn() {
  name=$1
  if [ -r /proc/modules ]; then
    awk '{print $1}' /proc/modules | grep -F -x -q -- "$name"
    return $?
  fi
  return 1
}

persist_modules() {
  if [ "$1" != 1 ] && [ "$2" != 1 ]; then
    rm -f /etc/modules-load.d/bbr.conf /etc/modules.d/bbr
    return 0
  fi
  if mkdir -p /etc/modules-load.d 2>/dev/null; then
    {
      printf '%s\n' "# 由 BBR 一键脚本写入"
      if [ "$1" = 1 ]; then
        printf '%s\n' tcp_bbr
      fi
      if [ "$2" = 1 ]; then
        printf '%s\n' sch_fq
      fi
    } > /etc/modules-load.d/bbr.conf 2>/dev/null || true
  fi
  if [ -d /etc/modules.d ]; then
    {
      printf '%s\n' "# bbr-onekey"
      [ "$1" = 1 ] && printf '%s\n' tcp_bbr
      [ "$2" = 1 ] && printf '%s\n' sch_fq
    } > /etc/modules.d/bbr 2>/dev/null || true
  fi
  # systemd 读 modules-load.d，OpenRC / 传统启动读 /etc/modules。只在已有 /etc/modules 或 OpenRC 上写入。
  if [ ! -f /etc/modules ] && { [ -x /etc/init.d/modules ] || [ "$PM" = apk ]; }; then
    touch /etc/modules 2>/dev/null || true
  fi
  if [ -f /etc/modules ] && [ -w /etc/modules ]; then
    if [ "$1" = 1 ] && ! grep -F -x -q -- tcp_bbr /etc/modules; then
      printf '%s\n' tcp_bbr >> /etc/modules
    fi
    if [ "$2" = 1 ] && ! grep -F -x -q -- sch_fq /etc/modules; then
      printf '%s\n' sch_fq >> /etc/modules
    fi
  fi
}

clear_modules() {
  rm -f /etc/modules-load.d/bbr.conf
  if [ -f /etc/modules.d/bbr ]; then
    rm -f /etc/modules.d/bbr
  fi
  if [ -f /etc/modules ] && [ -w /etc/modules ]; then
    grep -F -x -v -e tcp_bbr -e sch_fq /etc/modules > "$WORKDIR/modules" || true
    if ! files_equal "$WORKDIR/modules" /etc/modules; then
      cat "$WORKDIR/modules" > /etc/modules
    fi
  fi
}

list_ifs() {
  if ! command -v ip >/dev/null 2>&1; then
    return 0
  fi
  LC_ALL=C ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | cut -d@ -f1 | while IFS= read -r dev; do
    case $dev in
      ''|lo|sit0|tunl0|gre0|gretap0|erspan0|ip6tnl0|ip6gre0|teql0) continue ;;
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

root_qdisc_from_show() {
  rq_root=$(printf '%s\n' "$1" | awk '$0 ~ / root( |$)/ {print $2; exit}')
  if [ -z "$rq_root" ]; then
    rq_root=$(printf '%s\n' "$1" | awk 'NR==1 {print $2}')
  fi
  printf '%s\n' "$rq_root"
}

apply_qdiscs() {
  mode=$1
  target=${2:-}
  if ! command -v tc >/dev/null 2>&1; then
    say_warn "没有 tc 命令，这次不改已经存在的网卡。重启之后，新起来的网卡会用当时的默认队列。"
    return 0
  fi
  if [ -z "$target" ]; then
    if [ "$mode" = on ]; then
      target=fq
    else
      target=fq_codel
    fi
  fi
  ifs=$(list_ifs)
  for dev in $ifs; do
    show=$(LC_ALL=C tc qdisc show dev "$dev" 2>/dev/null) || continue
    [ -n "$show" ] || continue
    root=$(root_qdisc_from_show "$show")
    plan=$(qdisc_plan "$root" "$mode")
    case $plan in
      keep) ;;
      skip)
        say_warn "网卡 $dev 用的是 $root 队列，不是系统默认队列，保持不动"
        ;;
      replace)
        if LC_ALL=C tc qdisc replace dev "$dev" root "$target" >"$WORKDIR/tc.err" 2>&1; then
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
          parent=$(printf '%s\n' "$qline" | sed -n 's/.* parent \([^[:space:]]*\).*/\1/p')
          [ -n "$parent" ] || continue
          if child_should_replace "$typ" "$mode"; then
            if LC_ALL=C tc qdisc replace dev "$dev" parent "$parent" "$target" >"$WORKDIR/tc.err" 2>&1; then
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

script_path() {
  script=$1
  case $script in
    /*)
      printf '%s\n' "$script"
      return 0
      ;;
  esac
  if [ -f "$script" ]; then
    printf '%s\n' "$(pwd)/$script"
    return 0
  fi
  found=$(command -v "$script" 2>/dev/null || true)
  case $found in
    /*) printf '%s\n' "$found" ;;
    *) printf '%s\n' "$script" ;;
  esac
}

place_script() {
  src=$1
  dest=$2
  dir=$(dirname "$dest")
  mkdir -p "$dir" 2>/dev/null || return 1
  stage=$(mktemp "$dir/.bbr-new.XXXXXX" 2>/dev/null) || return 1
  if ! cp "$src" "$stage" 2>/dev/null; then
    rm -f "$stage"
    return 1
  fi
  chmod 755 "$stage" 2>/dev/null || true
  if ! mv "$stage" "$dest" 2>/dev/null; then
    rm -f "$stage"
    return 1
  fi
  return 0
}

link_installed_shortcut() {
  link_dir=$(shortcut_link_dir "${ORIG_PATH:-$PATH}")
  [ -n "$link_dir" ] || return 0
  [ -f "$INSTALLED_BBR" ] || return 0
  [ -d "$link_dir" ] || return 0
  if [ -d "$link_dir/bbr" ] && [ ! -L "$link_dir/bbr" ]; then
    return 0
  fi
  if [ -e "$link_dir/bbr" ] && [ "$link_dir/bbr" -ef "$INSTALLED_BBR" ]; then
    return 0
  fi
  if ln -sfn "$INSTALLED_BBR" "$link_dir/bbr" 2>/dev/null; then
    return 0
  fi
  cp "$INSTALLED_BBR" "$link_dir/bbr" 2>/dev/null || true
  chmod 755 "$link_dir/bbr" 2>/dev/null || true
}

download_install_sh() {
  dest=$1
  if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    return 1
  fi
  use_wget_tries=0
  if ! command -v curl >/dev/null 2>&1 && wget_supports_tries; then
    use_wget_tries=1
  fi
  for url in \
    https://raw.githubusercontent.com/imthnio/vps-bbr/main/install.sh \
    https://cdn.jsdelivr.net/gh/imthnio/vps-bbr@main/install.sh
  do
    rm -f "$dest"
    if command -v curl >/dev/null 2>&1; then
      curl -fsSL --connect-timeout 5 --max-time 12 -o "$dest" "$url" 2>/dev/null || true
    elif [ "$use_wget_tries" = 1 ]; then
      wget -qO "$dest" -T 12 -t 1 "$url" 2>/dev/null || true
    else
      wget -qO "$dest" -T 12 "$url" 2>/dev/null || true
    fi
    if remote_script_ok "$dest"; then
      return 0
    fi
  done
  rm -f "$dest"
  return 1
}

# 发布地址上有更新的脚本时，换成那一版再继续。失败不打断打开 BBR。
maybe_take_newer_remote() {
  [ "${BBR_UPDATED:-0}" = 1 ] && return 0
  if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    return 0
  fi
  dest="$WORKDIR/remote-install.sh"
  if ! download_install_sh "$dest"; then
    say_warn "暂时连不上脚本发布地址，按当前这份 $VERSION 继续"
    return 0
  fi
  remote=$(version_from_file "$dest" || true)
  if [ "$(remote_update_action "$VERSION" "$remote")" != update ]; then
    return 0
  fi
  was_new=0
  [ -f "$INSTALLED_BBR" ] || was_new=1
  say_info "发现新版本 $remote（当前是 $VERSION），先换成新版本再继续"
  if ! place_script "$dest" "$INSTALLED_BBR"; then
    say_warn "新版本下载了，但没能写到 $INSTALLED_BBR，继续用当前这份"
    return 0
  fi
  link_installed_shortcut
  reexec_installed "$was_new" "$@"
}

reexec_installed() {
  new_flag=$1
  shift
  if [ -n "${WORKDIR:-}" ]; then
    rm -rf "$WORKDIR"
  fi
  trap - EXIT HUP INT TERM
  exec env BBR_UPDATED=1 BBR_SUDO_TRIED="${BBR_SUDO_TRIED:-0}" \
    BBR_ORIG_PATH="${ORIG_PATH:-$PATH}" SHORTCUT_NEW="$new_flag" \
    sh "$INSTALLED_BBR" "$@"
}

# 把这次运行的脚本写到 bbr 命令。已安装的版本更新时不回退。
sync_installed_script() {
  [ "${BBR_NO_UPDATE:-0}" = 1 ] && return 0
  maybe_take_newer_remote "$@"
  src=$(script_path "$0")
  if ! is_this_script "$src"; then
    # 例如通过管道执行 curl ... | sh 时，$0 是 sh，绝对不能把 /bin/sh 写成 bbr。
    if [ -f "$WORKDIR/remote-install.sh" ] && remote_script_ok "$WORKDIR/remote-install.sh"; then
      rem_ver=$(version_from_file "$WORKDIR/remote-install.sh" || true)
      if [ -n "$rem_ver" ] && version_ge "$rem_ver" "$VERSION"; then
        src="$WORKDIR/remote-install.sh"
      else
        return 0
      fi
    else
      return 0
    fi
  fi
  if [ ! -f "$INSTALLED_BBR" ]; then
    if place_script "$src" "$INSTALLED_BBR"; then
      SHORTCUT_NEW=1
      link_installed_shortcut
    else
      say_warn "没能把脚本写到 $INSTALLED_BBR，这次只对当前进程生效"
    fi
    return 0
  fi
  old=$(version_from_file "$INSTALLED_BBR" || true)
  same=0
  if [ "$src" -ef "$INSTALLED_BBR" ]; then
    same=1
  fi
  action=$(installed_copy_action "$VERSION" "$old" "$same")
  case $action in
    keep)
      link_installed_shortcut
      ;;
    use-installed)
      say_info "本机的 bbr 是 $old，比这次运行的 $VERSION 新，改用已安装的版本"
      link_installed_shortcut
      reexec_installed "${SHORTCUT_NEW:-0}" "$@"
      ;;
    replace)
      if files_equal "$src" "$INSTALLED_BBR"; then
        link_installed_shortcut
        return 0
      fi
      if ! place_script "$src" "$INSTALLED_BBR"; then
        say_warn "没能把脚本更新到 $INSTALLED_BBR，这次只按当前这份继续"
        return 0
      fi
      link_installed_shortcut
      if [ -n "$old" ] && [ "$old" != "$VERSION" ]; then
        say_ok "已安装的脚本已从 $old 更新到 $VERSION"
      else
        say_ok "已安装的脚本已更新到 $VERSION"
      fi
      ;;
  esac
}

finish_shortcut_hint() {
  link_installed_shortcut
  if [ "${SHORTCUT_NEW:-0}" = 1 ]; then
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
    elif module_sysfs tcp_bbr || [ "$(kconfig_state CONFIG_TCP_CONG_BBR)" = y ]; then
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
  if [ -f "$INSTALLED_BBR" ]; then
    inst=$(version_from_file "$INSTALLED_BBR" || true)
    if [ -n "$inst" ]; then
      say_info "已安装命令：$INSTALLED_BBR（$inst）"
      if version_newer "$VERSION" "$inst"; then
        say_info "这次运行的是 $VERSION。不带参数再运行一次，会把已安装的命令更新过去。"
      fi
    fi
  fi
}

cmd_off() {
  detect_os
  say_step "关闭本脚本打开的 BBR"
  clear_sysctl
  clear_modules
  if ! write_sysctl_key net.ipv4.tcp_congestion_control cubic >/dev/null 2>&1; then
    write_sysctl_key net.ipv4.tcp_congestion_control reno >/dev/null 2>&1 || true
  fi
  off_qd=fq_codel
  if ! write_sysctl_key net.core.default_qdisc fq_codel >/dev/null 2>&1; then
    if write_sysctl_key net.core.default_qdisc pfifo_fast >/dev/null 2>&1; then
      off_qd=pfifo_fast
    fi
  fi
  CHANGED_DEVS=""
  apply_qdiscs off "$off_qd"
  now=$(read_sysctl net.ipv4.tcp_congestion_control)
  if [ "$now" = bbr ]; then
    say_warn "配置文件已清理，但当前运行中的拥塞控制仍是 bbr（可能是容器限制或内核没有别的算法）"
  else
    say_ok "已关掉。当前拥塞控制：${now:-未知}"
  fi
  if [ -n "$CHANGED_DEVS" ]; then
    say_ok "这些网卡的队列已从 fq 改回 $off_qd：$CHANGED_DEVS"
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

  PERSIST_OK=1
  if [ "${SYSCTL_READONLY:-0}" = 1 ]; then
    say_info "母鸡已经打开了 BBR，这台容器里不需要也改不了内核参数，跳过开机配置写入。"
  else
    PERSIST_BLOCK=$(persist_lines "$persist_fq" "$persist_bbr" "$ALLOW_VALUE")
    MANAGE_QDISC=$persist_fq
    say_step "写入开机配置"
    persist_sysctl || true
    MANAGE_QDISC=1
    if [ "$SHARED_KERNEL" != 1 ]; then
      load_tcp=0
      load_fq=0
      if module_loaded_dyn tcp_bbr || [ "$NEED_REBOOT" = 1 ]; then
        load_tcp=1
      fi
      if module_loaded_dyn sch_fq || [ "$NEED_REBOOT" = 1 ]; then
        load_fq=1
      fi
      persist_modules "$load_tcp" "$load_fq"
    fi
  fi

  CHANGED_DEVS=""
  if [ "$LIVE_FQ" = 1 ] && [ "${SYSCTL_READONLY:-0}" != 1 ]; then
    apply_qdiscs on
  fi

  printf '\n'
  if [ "$NEED_REBOOT" = 1 ] && [ "$LIVE_BBR" != 1 ]; then
    if [ "$PERSIST_OK" = 1 ]; then
      say_ok "开机配置已经写好，但现在这个内核还不能用 BBR"
    else
      say_warn "新内核已准备好，但开机配置没有完全写入，请检查 /etc/sysctl.d 权限"
    fi
    if [ -n "$REBOOT_KERNEL" ]; then
      say_info "重启后会使用内核 $REBOOT_KERNEL。"
    else
      say_info "新内核已经安装。重启后如果 uname -r 变了，BBR 会自动打开。"
    fi
    say_info "这次没有自动重启，避免把正在用的服务打断。"
    say_info "确认可以重启时执行：reboot"
    say_info "重启后如果拥塞控制仍不是 bbr，再运行一次本脚本。"
    say_info "如果重启后内核版本完全没变，说明服务商在面板里指定了内核，需要先在面板里换成新内核。"
    finish_shortcut_hint
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
    if [ "${SYSCTL_READONLY:-0}" = 1 ]; then
      say_info "BBR 由母鸡提供并处于开启状态。"
    elif [ "$PERSIST_OK" = 1 ]; then
      say_info "开机后还会保持，不用再运行一次。"
    else
      say_warn "当前会话已打开 BBR，但开机配置没能完全写入，重启后可能不会自动保持。"
    fi
    say_info "没有重启。已经连着的连接要断开重连才走 BBR，新连接马上生效。"
    say_info "IPv4 和 IPv6 的 TCP 都会走 BBR。"
    if [ "$SHARED_KERNEL" = 1 ]; then
      say_info "这台是切出来的，用的是母鸡内核里已经有的 BBR。"
    fi
    finish_shortcut_hint
    return 0
  fi
  say_err "没能打开 BBR。"
  return 2
}

usage() {
  cat <<EOF
BBR 一键脚本 $VERSION

用法：
  sh install.sh             自动识别这台机器，缺什么装什么，然后打开 BBR
  sh install.sh --status    只查看，不修改
  sh install.sh --off       关掉本脚本打开的 BBR
  sh install.sh --version   查看脚本版本

再运行一次会把已经装上的 bbr 命令更新到新版本，并重新核对开机配置。
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
    script=$(script_path "$0")
    if ! is_this_script "$script"; then
      say_err "当前不是 root，且脚本不是从本地文件运行的。请用 root 或 sudo 运行。"
      exit 1
    fi
    say_info "当前不是 root，改用 sudo 继续"
    exec sudo env \
      BBR_SUDO_TRIED=1 \
      BBR_NO_UPDATE="${BBR_NO_UPDATE:-0}" \
      BBR_UPDATED="${BBR_UPDATED:-0}" \
      BBR_ORIG_PATH="${ORIG_PATH:-$PATH}" \
      SHORTCUT_NEW="${SHORTCUT_NEW:-0}" \
      sh "$script" "$@"
  fi
  say_err "请用 root 运行：sudo sh install.sh"
  exit 1
}

cleanup_workdir() {
  if [ -n "${WORKDIR:-}" ]; then
    rm -rf "$WORKDIR"
  fi
}

make_workdir() {
  tmp_base=${TMPDIR:-/tmp}
  tmp_base=${tmp_base%/}
  [ -n "$tmp_base" ] || tmp_base=/tmp
  WORKDIR=$(mktemp -d "$tmp_base/bbr.XXXXXX") || {
    say_err "创建临时目录失败"
    exit 1
  }
  trap 'cleanup_workdir' EXIT
  trap 'cleanup_workdir; exit 129' HUP
  trap 'cleanup_workdir; exit 130' INT
  trap 'cleanup_workdir; exit 143' TERM
}

main() {
  if [ "$#" -gt 1 ]; then
    usage >&2
    exit 1
  fi
  action=on
  case ${1:-} in
    "") action=on ;;
    --status|status) action=status ;;
    --off|off) action=off ;;
    --version|-v|-V|version) action=version ;;
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

  if [ "$action" = version ]; then
    printf '%s\n' "BBR 一键脚本 $VERSION"
    exit 0
  fi

  if [ "$(uname -s 2>/dev/null)" != Linux ]; then
    say_err "BBR 是 Linux 内核的功能。请把脚本放到 VPS 上运行。"
    exit 1
  fi

  umask 022
  ORIG_PATH=${BBR_ORIG_PATH:-$PATH}
  PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"
  export PATH
  : "${SHORTCUT_NEW:=0}"
  NEED_REBOOT=0
  REBOOT_KERNEL=""
  ALLOW_VALUE=""
  LIVE_BBR=0
  LIVE_FQ=0
  SYSCTL_READONLY=0
  PERSIST_OK=1
  MANAGE_QDISC=1
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
      sync_installed_script "$@"
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
