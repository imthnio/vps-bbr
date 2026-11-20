#!/bin/sh
# 只测判断和配置改写，不改本机网络，也不装软件。
cd "$(dirname "$0")" || exit 1
BBR_SOURCE_ONLY=1
. ./install.sh

ok=0
bad=0

expect() {
  name=$1
  got=$2
  want=$3
  if [ "$got" = "$want" ]; then
    ok=$((ok + 1))
  else
    bad=$((bad + 1))
    printf 'FAIL %s\n  got:  [%s]\n  want: [%s]\n' "$name" "$got" "$want" >&2
  fi
}

expect_ok() {
  name=$1
  shift
  if "$@"; then
    ok=$((ok + 1))
  else
    bad=$((bad + 1))
    printf 'FAIL %s (expected success)\n' "$name" >&2
  fi
}

expect_fail() {
  name=$1
  shift
  if "$@"; then
    bad=$((bad + 1))
    printf 'FAIL %s (expected failure)\n' "$name" >&2
  else
    ok=$((ok + 1))
  fi
}

expect_ok "4.9 >= 4.9" version_ge 4.9 4.9
expect_ok "4.9.0 >= 4.9" version_ge 4.9.0 4.9
expect_ok "4.9.1 >= 4.9" version_ge 4.9.1 4.9
expect_fail "4.9 < 4.9.1" version_ge 4.9 4.9.1
expect_fail "4.8 < 4.9" version_ge 4.8.0 4.9
expect_fail "5 < 5.1" version_ge 5 5.1
expect_ok "5 >= 5.0" version_ge 5 5.0
expect_fail "leading dot invalid" version_ge .4.9 4.9
expect_fail "el7 < 4.9" version_ge 3.10.0-1160.el7.x86_64 4.9
expect_ok "6.14 >= 4.9" version_ge 6.14.0-35-generic 4.9
expect_ok "10 >= 9" version_ge 10.0 9.9
expect_fail "empty kernel" version_ge linux 4.9
expect_ok "debian abi newer" kernel_version_newer 6.1.0-25-amd64 6.1.0-18-amd64
expect_ok "debian abi 25 > 9" kernel_version_newer 6.1.0-25-amd64 6.1.0-9-amd64
expect_fail "debian abi older" kernel_version_newer 6.1.0-9-amd64 6.1.0-25-amd64
expect_fail "debian abi equal" kernel_version_newer 6.1.0-25-amd64 6.1.0-25-amd64
expect_ok "rhel abi newer" kernel_version_newer 5.14.0-427.13.1.el9_4.x86_64 5.14.0-362.8.1.el9_3.x86_64
expect_fail "same version" version_newer 1.1.0 1.1.0
expect_ok "newer patch" version_newer 1.1.1 1.1.0
expect_fail "older version" version_newer 1.0.0 1.1.0
expect_ok "newer minor" version_newer 1.10.0 1.9.0
expect "keep same file" "$(installed_copy_action 1.1.0 1.1.0 1)" "keep"
expect "replace older" "$(installed_copy_action 1.1.0 1.0.0 0)" "replace"
expect "use newer installed" "$(installed_copy_action 1.0.0 1.1.0 0)" "use-installed"
expect "replace same version other file" "$(installed_copy_action 1.1.0 1.1.0 0)" "replace"
expect "replace unreadable version" "$(installed_copy_action 1.1.0 "" 0)" "replace"
expect "stay on same remote" "$(remote_update_action 1.1.0 1.1.0)" "stay"
expect "stay on older remote" "$(remote_update_action 1.1.0 1.0.0)" "stay"
expect "update from remote" "$(remote_update_action 1.0.0 1.1.0)" "update"
expect "stay without remote" "$(remote_update_action 1.1.0 "")" "stay"
expect "path has local sbin" "$(shortcut_link_dir "/usr/local/sbin:/usr/sbin:/usr/bin")" ""
expect "path has local sbin slash" "$(shortcut_link_dir "/usr/local/sbin/:/usr/sbin:/usr/bin")" ""
expect "openwrt path" "$(shortcut_link_dir "/usr/sbin:/usr/bin:/sbin:/bin")" "/usr/sbin"
expect "kernel numeric" "$(kernel_numeric 6.14.0-35-generic)" "6.14.0"
expect "kernel numeric trailing dots" "$(kernel_numeric 4.9..)" "4.9"
expect_ok "no local kernel files" kernel_ship_bbr 9.9.9-no-such-kernel-bbrtest

expect_ok "ipv4" is_ipv4 8.8.8.8
expect_ok "ipv4 cidr" is_ipv4 10.0.0.1/24
expect_fail "ipv4 cidr overflow" is_ipv4 10.0.0.1/33
expect_fail "ipv4 cidr garbage" is_ipv4 1.2.3.4/garbage
expect_fail "ipv4 cidr empty" is_ipv4 1.2.3.4/
expect_fail "ipv4 trailing dot" is_ipv4 1.2.3.4.
expect_fail "ipv4 leading dot" is_ipv4 .1.2.3.4
expect_fail "ipv4 double dot" is_ipv4 1..2.3
expect_fail "ipv4 glob" is_ipv4 '1.2.3.*'
expect_fail "ipv4 huge int" is_ipv4 99999999999999999999999.1.1.1
expect_fail "ipv4 overflow" is_ipv4 1.2.3.256
expect_fail "ipv4 text" is_ipv4 abc
expect_ok "10 private" is_private_ipv4 10.1.2.3
expect_ok "172.16 private" is_private_ipv4 172.16.0.1
expect_ok "172.31 private" is_private_ipv4 172.31.255.255
expect_fail "172.15 public" is_private_ipv4 172.15.1.1
expect_fail "172.32 public" is_private_ipv4 172.32.0.1
expect_ok "192.168 private" is_private_ipv4 192.168.1.1
expect_fail "192.169 public" is_private_ipv4 192.169.1.1
expect_ok "cgnat" is_private_ipv4 100.64.0.1
expect_ok "cgnat end" is_private_ipv4 100.127.255.255
expect_fail "after cgnat" is_private_ipv4 100.128.0.1
expect_ok "link local" is_private_ipv4 169.254.1.1
expect_ok "multicast not public" is_private_ipv4 224.0.0.1
expect_fail "public dns" is_private_ipv4 8.8.8.8
expect_ok "leading zero still ipv4" is_ipv4 08.8.8.8

expect "nat" "$(network_kind "10.0.0.5 192.168.1.2" "")" "nat"
expect "public beside private" "$(network_kind "10.0.0.5 1.2.3.4" "")" "public"
expect "cgnat kind" "$(network_kind "100.64.1.1" "")" "nat"
expect "ipv6" "$(network_kind "" "2001:db8::1")" "ipv6"
expect "link local ipv6" "$(network_kind "" "fe80::1")" "unknown"
expect "mixed case link local ipv6" "$(network_kind "" "Fe80::1")" "unknown"
expect "ula ipv6" "$(network_kind "" "fd12:3456::1")" "unknown"
expect "empty" "$(network_kind "" "")" "unknown"
expect "public ipv6 filter" "$(public_ipv6s "fe80::1 fd00::1 2001:db8::1 2606:4700::1")" "2001:db8::1 2606:4700::1"
expect "ipv6 phrase with addr" "$(network_phrase ipv6 "2001:db8::1" "")" "有公网 IPv6（2001:db8::1）"
expect "ipv6 phrase empty" "$(network_phrase ipv6 "" "")" "有公网 IPv6"

expect "openvz shared" "$(classify_virt openvz kvm)" "1 openvz"
expect "kvm own" "$(classify_virt "" kvm)" "0 kvm"
expect "bare" "$(classify_virt "" "")" "0 none"
expect "docker" "$(classify_virt docker "")" "1 docker"
expect "lxc" "$(classify_virt lxc "")" "1 lxc"
expect "incus shared" "$(classify_virt incus "")" "1 incus"
expect "proot shared" "$(classify_virt proot kvm)" "1 proot"

phrase=$(virt_phrase 1 openvz)
printf '%s\n' "$phrase" | grep -q '共用内核' && ok=$((ok + 1)) || {
  bad=$((bad + 1))
  printf 'FAIL virt phrase [%s]\n' "$phrase" >&2
}
phrase=$(virt_phrase 0 kvm)
printf '%s\n' "$phrase" | grep -q '自己的内核' && ok=$((ok + 1)) || {
  bad=$((bad + 1))
  printf 'FAIL kvm phrase [%s]\n' "$phrase" >&2
}

expect "fq keep" "$(qdisc_plan fq on)" "keep"
expect "fq_codel replace" "$(qdisc_plan fq_codel on)" "replace"
expect "pfifo replace" "$(qdisc_plan pfifo_fast on)" "replace"
expect "noqueue replace" "$(qdisc_plan noqueue on)" "replace"
expect "mq children" "$(qdisc_plan mq on)" "children"
expect "cake skip" "$(qdisc_plan cake on)" "skip"
expect "htb skip" "$(qdisc_plan htb on)" "skip"
expect "off fq replace" "$(qdisc_plan fq off)" "replace"
expect "off fq_codel keep" "$(qdisc_plan fq_codel off)" "keep"
expect "off mq children" "$(qdisc_plan mqprio off)" "children"
expect "off cake keep" "$(qdisc_plan cake off)" "keep"

expect_ok "comment bbr" off_line_should_comment "net.ipv4.tcp_congestion_control=bbr"
expect_ok "comment spaced bbr" off_line_should_comment "net.ipv4.tcp_congestion_control = bbr"
expect_ok "comment inline comment bbr" off_line_should_comment "net.ipv4.tcp_congestion_control = bbr # enable"
expect_ok "comment slash bbr" off_line_should_comment "net/ipv4/tcp_congestion_control = bbr"
expect_ok "comment dash fq" off_line_should_comment "-net.core.default_qdisc = fq ; pacing"
expect_fail "keep cubic" off_line_should_comment "net.ipv4.tcp_congestion_control = cubic"
expect_ok "comment fq" off_line_should_comment "net.core.default_qdisc=fq"
expect_fail "keep fq_codel" off_line_should_comment "net.core.default_qdisc=fq_codel"

expect "root qdisc normal" "$(root_qdisc_from_show "qdisc fq_codel 0: root refcnt 2")" "fq_codel"
expect "root qdisc after clsact" "$(root_qdisc_from_show "qdisc clsact ffff: parent ffff:fff1
qdisc mq 0: root")" "mq"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/bbr-test.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

cat > "$tmp/in.txt" <<'EOF'
# keep
net.ipv4.tcp_congestion_control = cubic
net.core.default_qdisc=fq_codel
vm.swappiness=10
net.ipv4.tcp_congestion_control=bbr
EOF

cat > "$tmp/want-on.txt" <<'EOF'
# keep
# bbr-onekey: 改由脚本末尾这块管理
# net.ipv4.tcp_congestion_control = cubic
# bbr-onekey: 改由脚本末尾这块管理
# net.core.default_qdisc=fq_codel
vm.swappiness=10
# bbr-onekey: 改由脚本末尾这块管理
# net.ipv4.tcp_congestion_control=bbr
# bbr-onekey-begin
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
# bbr-onekey-end
EOF

cat > "$tmp/want-off.txt" <<'EOF'
# keep
net.ipv4.tcp_congestion_control = cubic
net.core.default_qdisc=fq_codel
vm.swappiness=10
# bbr-onekey: 已关闭
# net.ipv4.tcp_congestion_control=bbr
EOF

DESIRED_BLOCK='net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr'
apply_sysctl_text < "$tmp/in.txt" > "$tmp/on.txt"
apply_sysctl_text < "$tmp/on.txt" > "$tmp/on2.txt"
disable_bbr_text < "$tmp/on.txt" > "$tmp/off.txt"

if cmp -s "$tmp/on.txt" "$tmp/want-on.txt"; then
  ok=$((ok + 1))
else
  bad=$((bad + 1))
  printf 'FAIL apply_sysctl_text\n' >&2
  diff -u "$tmp/want-on.txt" "$tmp/on.txt" >&2 || true
fi
if cmp -s "$tmp/on.txt" "$tmp/on2.txt"; then
  ok=$((ok + 1))
else
  bad=$((bad + 1))
  printf 'FAIL apply is not idempotent\n' >&2
  diff -u "$tmp/on.txt" "$tmp/on2.txt" >&2 || true
fi
if cmp -s "$tmp/off.txt" "$tmp/want-off.txt"; then
  ok=$((ok + 1))
else
  bad=$((bad + 1))
  printf 'FAIL disable_bbr_text\n' >&2
  diff -u "$tmp/want-off.txt" "$tmp/off.txt" >&2 || true
fi

block=$(persist_lines 1 1 "")
expect "persist both" "$block" "net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr"
block=$(persist_lines 0 1 "")
expect "persist bbr only" "$block" "net.ipv4.tcp_congestion_control=bbr"

printf '%s\n' 'No package kernel available.' 'Error: Nothing to do' > "$tmp/rpm-missing.txt"
expect "rpm missing beats nothing" "$(rpm_log_kind "$tmp/rpm-missing.txt" 1)" "missing"
printf '%s\n' 'Nothing to do' > "$tmp/rpm-nothing.txt"
expect "rpm nothing is ok" "$(rpm_log_kind "$tmp/rpm-nothing.txt" 1)" "ok"
expect "rpm rc 0 is ok" "$(rpm_log_kind "$tmp/rpm-missing.txt" 0)" "ok"
printf '%s\n' 'Error: disk full' > "$tmp/rpm-fail.txt"
expect "rpm other failure" "$(rpm_log_kind "$tmp/rpm-fail.txt" 1)" "failed"

printf '%s\n' '#!/bin/sh' 'echo hi' > "$tmp/not-bbr.sh"
expect_fail "reject random script" remote_script_ok "$tmp/not-bbr.sh"
expect_fail "reject /bin/sh binary" is_this_script /bin/sh
printf '#!/bin/sh\r\nVERSION=1.1.1\r\n# bbr-onekey-begin\r\n' > "$tmp/crlf.sh"
expect_fail "reject crlf script" remote_script_ok "$tmp/crlf.sh"
expect_ok "this file is a script" remote_script_ok ./install.sh
expect "version of this file" "$(version_from_file ./install.sh)" "$VERSION"

# sysctl.d 清理（DESIRED_BLOCK 为空时不追加新块，同时清理旧版本遗留块）
cat > "$tmp/d-in.txt" <<'EOF'
kernel.yama.ptrace_scope = 1
net.ipv4.tcp_congestion_control = cubic
# bbr-onekey-begin
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
# bbr-onekey-end
EOF
cat > "$tmp/d-want.txt" <<'EOF'
kernel.yama.ptrace_scope = 1
# bbr-onekey: 改由 zzz-bbr.conf 管理
# net.ipv4.tcp_congestion_control = cubic
EOF
cat > "$tmp/d-want-off.txt" <<'EOF'
kernel.yama.ptrace_scope = 1
net.ipv4.tcp_congestion_control = cubic
EOF
DESIRED_BLOCK=""
apply_sysctl_text < "$tmp/d-in.txt" > "$tmp/d-out.txt"
disable_bbr_text < "$tmp/d-out.txt" > "$tmp/d-off.txt"
if cmp -s "$tmp/d-out.txt" "$tmp/d-want.txt"; then
  ok=$((ok + 1))
else
  bad=$((bad + 1))
  printf 'FAIL apply_sysctl_text empty block\n' >&2
  diff -u "$tmp/d-want.txt" "$tmp/d-out.txt" >&2 || true
fi
if cmp -s "$tmp/d-off.txt" "$tmp/d-want-off.txt"; then
  ok=$((ok + 1))
else
  bad=$((bad + 1))
  printf 'FAIL disable_bbr_text after empty block\n' >&2
  diff -u "$tmp/d-want-off.txt" "$tmp/d-off.txt" >&2 || true
fi

# MANAGE_QDISC=0 时不注释已有 default_qdisc
cat > "$tmp/cake-in.txt" <<'EOF'
net.core.default_qdisc = cake
net.ipv4.tcp_congestion_control = cubic
EOF
cat > "$tmp/cake-want.txt" <<'EOF'
net.core.default_qdisc = cake
# bbr-onekey: 改由脚本末尾这块管理
# net.ipv4.tcp_congestion_control = cubic
# bbr-onekey-begin
net.ipv4.tcp_congestion_control=bbr
# bbr-onekey-end
EOF
MANAGE_QDISC=0
DESIRED_BLOCK="net.ipv4.tcp_congestion_control=bbr"
apply_sysctl_text < "$tmp/cake-in.txt" > "$tmp/cake-out.txt"
MANAGE_QDISC=1
if cmp -s "$tmp/cake-out.txt" "$tmp/cake-want.txt"; then
  ok=$((ok + 1))
else
  bad=$((bad + 1))
  printf 'FAIL MANAGE_QDISC=0\n' >&2
  diff -u "$tmp/cake-want.txt" "$tmp/cake-out.txt" >&2 || true
fi

# Ubuntu EOL 源识别与改写（含 ARM64 ubuntu-ports，不重复改写 old-releases）
WORKDIR=$tmp
cat > "$tmp/apt.log" <<'EOF'
E: The repository 'http://archive.ubuntu.com/ubuntu lunar Release' no longer has a Release file.
E: The repository 'http://ports.ubuntu.com/ubuntu-ports lunar Release' no longer has a Release file.
E: The repository 'http://old-releases.ubuntu.com/ubuntu lunar Release' no longer has a Release file.
EOF
expect "ubuntu eol hosts" "$(ubuntu_eol_hosts)" "archive.ubuntu.com
ports.ubuntu.com"
printf '%s\n' "archive.ubuntu.com" "ports.ubuntu.com" > "$tmp/eol-hosts"
cat > "$tmp/sources.list" <<'EOF'
deb http://archive.ubuntu.com/ubuntu lunar main
deb https://ports.ubuntu.com/ubuntu-ports lunar main
EOF
rewrite_ubuntu_sources_file "$tmp/sources.list" "$tmp/eol-hosts"
cat > "$tmp/sources.want" <<'EOF'
deb http://old-releases.ubuntu.com/ubuntu lunar main
deb http://old-releases.ubuntu.com/ubuntu lunar main
EOF
if cmp -s "$tmp/sources.list" "$tmp/sources.want"; then
  ok=$((ok + 1))
else
  bad=$((bad + 1))
  printf 'FAIL rewrite_ubuntu_sources_file\n' >&2
  diff -u "$tmp/sources.want" "$tmp/sources.list" >&2 || true
fi

# sysctl_error_kind 中英文识别
printf '%s\n' 'sysctl: setting key "net.ipv4.tcp_congestion_control": Read-only file system' > "$tmp/sysctl.err"
expect "sysctl err en denied" "$(sysctl_error_kind)" "denied"
printf '%s\n' 'sysctl: setting key "net.ipv4.tcp_congestion_control": 只读文件系统' > "$tmp/sysctl.err"
expect "sysctl err zh denied" "$(sysctl_error_kind)" "denied"
printf '%s\n' 'sysctl: setting key "net.ipv4.tcp_congestion_control": Invalid argument' > "$tmp/sysctl.err"
expect "sysctl err invalid" "$(sysctl_error_kind)" "invalid"

expect_ok "files_equal same" files_equal "$tmp/sources.list" "$tmp/sources.want"
expect_fail "files_equal diff" files_equal "$tmp/sources.list" "$tmp/apt.log"

printf '%s\n' '#!/bin/sh' 'VERSION=9.9.9' > "$tmp/placed-src.sh"
place_script "$tmp/placed-src.sh" "$tmp/placed-dest.sh"
expect "placed version" "$(version_from_file "$tmp/placed-dest.sh")" "9.9.9"
expect_ok "placed is executable" test -x "$tmp/placed-dest.sh"

help_out=$(sh ./install.sh --help 2>&1)
printf '%s\n' "$help_out" | grep -q '自动识别' && ok=$((ok + 1)) || {
  bad=$((bad + 1))
  printf 'FAIL help text\n%s\n' "$help_out" >&2
}
ver_out=$(sh ./install.sh --version 2>&1)
expect "version flag" "$ver_out" "BBR 一键脚本 $VERSION"
expect_fail "reject extra args" sh ./install.sh --help extra >/dev/null 2>&1

sh ./install.sh --status >"$tmp/bbr-status.out" 2>"$tmp/bbr-status.err"
status_rc=$?
if [ "$(uname -s 2>/dev/null)" = Linux ]; then
  if [ "$status_rc" -eq 0 ] && grep -q 'BBR 一键脚本' "$tmp/bbr-status.out"; then
    ok=$((ok + 1))
  else
    bad=$((bad + 1))
    printf 'FAIL linux status rc=%s\n' "$status_rc" >&2
    cat "$tmp/bbr-status.err" >&2
  fi
else
  if [ "$status_rc" -ne 0 ] && grep -q 'Linux' "$tmp/bbr-status.err"; then
    ok=$((ok + 1))
  else
    bad=$((bad + 1))
    printf 'FAIL non-linux status rc=%s\n' "$status_rc" >&2
    cat "$tmp/bbr-status.err" >&2
  fi
fi

printf 'passed %s, failed %s\n' "$ok" "$bad"
[ "$bad" -eq 0 ]
