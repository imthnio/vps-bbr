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
expect_fail "el7 < 4.9" version_ge 3.10.0-1160.el7.x86_64 4.9
expect_ok "6.14 >= 4.9" version_ge 6.14.0-35-generic 4.9
expect_ok "10 >= 9" version_ge 10.0 9.9
expect_fail "empty kernel" version_ge linux 4.9
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
expect "openwrt path" "$(shortcut_link_dir "/usr/sbin:/usr/bin:/sbin:/bin")" "/usr/sbin"
expect "kernel numeric" "$(kernel_numeric 6.14.0-35-generic)" "6.14.0"
expect_ok "no local kernel files" kernel_ship_bbr 9.9.9-no-such-kernel-bbrtest

expect_ok "ipv4" is_ipv4 8.8.8.8
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
expect_fail "public dns" is_private_ipv4 8.8.8.8
expect_ok "leading zero still ipv4" is_ipv4 08.8.8.8

expect "nat" "$(network_kind "10.0.0.5 192.168.1.2" "")" "nat"
expect "public beside private" "$(network_kind "10.0.0.5 1.2.3.4" "")" "public"
expect "cgnat kind" "$(network_kind "100.64.1.1" "")" "nat"
expect "ipv6" "$(network_kind "" "2001:db8::1")" "ipv6"
expect "link local ipv6" "$(network_kind "" "fe80::1")" "unknown"
expect "empty" "$(network_kind "" "")" "unknown"

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
expect_fail "keep cubic" off_line_should_comment "net.ipv4.tcp_congestion_control = cubic"
expect_ok "comment fq" off_line_should_comment "net.core.default_qdisc=fq"
expect_fail "keep fq_codel" off_line_should_comment "net.core.default_qdisc=fq_codel"

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
expect_ok "this file is a script" remote_script_ok ./install.sh
expect "version of this file" "$(version_from_file ./install.sh)" "1.1.0"

printf '%s\n' '#!/bin/sh' 'VERSION=9.9.9' > "$tmp/placed-src.sh"
place_script "$tmp/placed-src.sh" "$tmp/placed-dest.sh"
expect "placed version" "$(version_from_file "$tmp/placed-dest.sh")" "9.9.9"
expect_ok "placed is executable" test -x "$tmp/placed-dest.sh"

help_out=$(sh ./install.sh --help 2>&1)
printf '%s\n' "$help_out" | grep -q '自动识别' && ok=$((ok + 1)) || {
  bad=$((bad + 1))
  printf 'FAIL help text\n%s\n' "$help_out" >&2
}
sh ./install.sh --status >/tmp/bbr-status.out 2>/tmp/bbr-status.err
status_rc=$?
if [ "$status_rc" -ne 0 ] && grep -q 'Linux' /tmp/bbr-status.err; then
  ok=$((ok + 1))
else
  bad=$((bad + 1))
  printf 'FAIL non-linux status rc=%s\n' "$status_rc" >&2
  cat /tmp/bbr-status.err >&2
fi
rm -f /tmp/bbr-status.out /tmp/bbr-status.err

printf 'passed %s, failed %s\n' "$ok" "$bad"
[ "$bad" -eq 0 ]
