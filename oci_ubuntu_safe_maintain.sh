#!/usr/bin/env bash
# OCI Ubuntu LTS safe-maintenance helper v0.2.0 (2026-11)
# Supported target: Ubuntu 18.04 / 20.04 / 22.04 / 24.04, amd64 or arm64.
# Usage:
#   sudo bash oci_ubuntu_safe_maintain.sh                 # interactive menu
#   sudo bash oci_ubuntu_safe_maintain.sh audit           # read-only inspection
#   sudo bash oci_ubuntu_safe_maintain.sh pro             # optional Ubuntu Pro ESM
#   sudo bash oci_ubuntu_safe_maintain.sh auto-security   # optional security-updates policy
#   sudo bash oci_ubuntu_safe_maintain.sh patch           # manually-approved apt upgrades
#   sudo bash oci_ubuntu_safe_maintain.sh backup-setup    # optional encrypted remote SFTP backups
#   sudo bash oci_ubuntu_safe_maintain.sh backup-now      # create Restic snapshot
#   sudo bash oci_ubuntu_safe_maintain.sh backup-check    # check and test restore
#   sudo bash oci_ubuntu_safe_maintain.sh backup-timer    # opt-in daily backups
#   sudo bash oci_ubuntu_safe_maintain.sh backup-list     # list snapshots
# No major OS upgrade, firewall/SSH edit, OCI API call, instance deletion, or reboot.
set -Eeuo pipefail
umask 077
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export DEBIAN_FRONTEND=readline

CONFIG_DIR=/etc/oci-ubuntu-maintain
REPO_FILE="$CONFIG_DIR/restic-repository"
PASS_FILE="$CONFIG_DIR/restic-password"
PATHS_FILE="$CONFIG_DIR/restic-paths"
INSTALLED_SCRIPT=/usr/local/sbin/oci-ubuntu-safe-maintain
TIMER_NAME=oci-restic-backup.timer
VERIFIED_FILE="$CONFIG_DIR/restic-verified"

say()  { printf '\n\033[1;34m[INFO]\033[0m %s\n' "$*"; }
warn() { printf '\n\033[1;33m[注意]\033[0m %s\n' "$*" >&2; }
die()  { printf '\n\033[1;31m[错误]\033[0m %s\n' "$*" >&2; exit 1; }
section() { printf '\n========== %s ==========\n' "$*"; }
require_tty() { [[ -t 0 ]] || die '该操作需要交互式终端（请不要通过无人值守管道执行）。'; }
confirm_word() {
  require_tty
  local expected="$1" reply
  printf '请准确输入 %s 以继续，其余输入均取消: ' "$expected"
  IFS= read -r reply
  [[ "$reply" == "$expected" ]] || die '用户已取消；未执行此项更改。'
}
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "缺少命令: $1"; }

check_os() {
  [[ -f /etc/os-release ]] || die '未找到 /etc/os-release。'
  # shellcheck disable=SC1091
  . /etc/os-release
  [[ "${ID:-}" == ubuntu ]] || die '本脚本只用于 Ubuntu，不用于 Debian / Oracle Linux。'
  case "${VERSION_ID:-}" in
    18.04|20.04|22.04|24.04) ;;
    *) warn "检测到 Ubuntu ${VERSION_ID:-未知}。安全体检可用；涉及更改的选项未针对该版本验证。" ;;
  esac
}
require_maintained_lts() {
  case "${VERSION_ID:-}" in
    18.04|20.04|22.04|24.04) ;;
    *) die "Ubuntu ${VERSION_ID:-未知} 不在本脚本的更改操作验证范围；仅使用 audit。" ;;
  esac
}

inspect() {
  section '系统 / 架构 / 内核'
  grep -E '^(PRETTY_NAME|VERSION_ID)=' /etc/os-release || true
  uname -m; uname -r
  section '内存与磁盘'
  free -h || true
  df -h / /boot 2>/dev/null || df -h /
  lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT 2>/dev/null || true
  section 'Ubuntu Pro / ESM'
  if command -v pro >/dev/null 2>&1; then pro status || true
  elif command -v ua >/dev/null 2>&1; then ua status || true
  else warn '未检测到 Ubuntu Pro 客户端。'; fi
  section '自动安全更新'
  dpkg-query -W -f='${Status}\n' unattended-upgrades 2>/dev/null || true
  for unit in apt-daily.timer apt-daily-upgrade.timer; do
    printf '%s: ' "$unit"; systemctl is-enabled "$unit" 2>/dev/null || true
  done
  if [[ -e /var/run/reboot-required ]]; then
    warn '系统已标记需要重启。请安排维护窗口、确保 OCI 串口控制台可用后手动重启。'
  else say '未发现 Ubuntu 的 reboot-required 标记。'; fi
  section 'APT 暂停/异常软件包'
  apt-mark showhold 2>/dev/null || true
  dpkg --audit || true
  section '监听端口（仅本机，不能反映 OCI NSG/Security List）'
  ss -lntup 2>/dev/null || ss -lnt 2>/dev/null || true
  section 'SSH 有效配置（不会修改）'
  if command -v sshd >/dev/null 2>&1; then
    sshd -T 2>/dev/null | grep -Ei '^(port|permitrootlogin|passwordauthentication|pubkeyauthentication) ' || true
  else warn 'sshd 命令不可用，跳过 SSH 配置检查。'; fi
  section 'UFW 状态（不会启用/关闭）'
  if command -v ufw >/dev/null 2>&1; then ufw status 2>/dev/null || true; else echo '未安装 ufw'; fi
  warn 'OCI Ubuntu 镜像请勿直接执行 ufw enable；网络放行规则应优先在 OCI NSG / Security List 管理。'
  section 'Docker 容器（只读）'
  if command -v docker >/dev/null 2>&1; then
    docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}' 2>/dev/null || true
  else echo '未检测到 docker'; fi
  section '失败的 systemd 服务'
  systemctl --failed --no-pager --plain 2>/dev/null || true
  section '备份设置'
  if [[ -f "$REPO_FILE" && -f "$PASS_FILE" ]]; then
    echo 'Restic 已配置（为安全起见不显示仓库位置或密钥）。'
    [[ -f "$PATHS_FILE" ]] && { echo '备份目录:'; sed -n '1,60p' "$PATHS_FILE"; }
  else echo 'Restic 未配置；使用 backup-setup 单独初始化。'; fi
  section 'OCI 侧需人工核对'
  printf '%s\n' \
    '1. OCI 控制台：创建符合配额的启动盘备份（本脚本不会自动创建）。' \
    '2. 检查 NSG/Security List：SSH 仅允许可信来源；数据库/面板不要裸露公网。' \
    '3. 提前测试 OCI 串口控制台；确认实例的 ARM 免费配额状态。' \
    '4. 如使用第三方 Docker / Node / PHP / 数据库，需单独核对其安全支持周期。'
  section 'OCI 专项检查（只读）'
  if command -v iptables-save >/dev/null 2>&1; then
    if iptables-save 2>/dev/null | grep -Eq '169[.]254[.](0[.]2|2[.])'; then
      say 'iptables 中发现 OCI iSCSI 相关地址；仍需人工确认规则完整。'
    else
      warn '未在 iptables-save 中发现常见 iSCSI 地址；使用半虚拟化启动盘或 nftables 的机器可能正常，请人工核查，勿自动修复。'
    fi
  else
    warn '未找到 iptables-save，无法检查 OCI iSCSI 规则。'
  fi
  if command -v snap >/dev/null 2>&1; then
    snap list oracle-cloud-agent 2>/dev/null || warn '未发现 snap 版 Oracle Cloud Agent（不代表所有 OCI 镜像异常）。'
    snap services oracle-cloud-agent 2>/dev/null || true
  fi
  for unit in iscsid.service open-iscsi.service; do
    printf '%s: ' "$unit"; systemctl is-active "$unit" 2>/dev/null || true
  done
  warn '以上检查不会修改 iptables、网络、OCI Agent 或 iSCSI；也不能自动识别 OCI 免费配额及控制台配置。'
  warn '分享输出前请遮盖公网 IP、域名、主机名、账号信息与敏感容器名称。'
}

setup_pro() {
  require_maintained_lts
  section '绑定 Ubuntu Pro 并开启 ESM（不升级 Ubuntu 大版本）'
  warn '先在 OCI 控制台做好启动盘备份；Ubuntu Pro 可能新增 APT 软件源。'
  warn '只使用本人有权使用的订阅。不要公开 Pro Token。'
  confirm_word PRO
  if ! command -v pro >/dev/null 2>&1; then
    apt-get update
    if ! apt-get install ubuntu-pro-client; then
      apt-get install ubuntu-advantage-tools
    fi
  fi
  need_cmd pro
  local status
  status="$(LC_ALL=C pro status 2>&1)" || die '无法读取 Ubuntu Pro 状态；请先排查 pro status。'
  printf '%s\n' "$status"
  if grep -Eqi 'not attached|not subscribed' <<<"$status"; then
    warn '将执行 pro attach --no-auto-enable，避免意外开启 Livepatch 等其他服务。'
    pro attach --no-auto-enable
  elif ! grep -Eqi '^[[:space:]]*(Account|Subscription):' <<<"$status"; then
    die '无法确认当前 Pro 已绑定；为避免重复绑定或误改订阅，请手动运行 pro status。'
  fi
  pro enable esm-infra
  pro enable esm-apps
  status="$(LC_ALL=C pro status 2>&1)" || die 'ESM 操作完成但无法验证状态。'
  printf '%s\n' "$status"
  for service in esm-infra esm-apps; do
    if ! grep -Eiq "^[[:space:]]*${service}[[:space:]]+.*enabled" <<<"$status"; then
      warn "未能从状态中确认 $service 已启用，请人工复核（不同 Pro 版本输出可能不同）。"
    fi
  done
  say '已尝试启用 ESM；请检查 pro status 和 apt list --upgradable。'
}

setup_auto_updates() {
  require_maintained_lts
  section '配置 Ubuntu/ESM 自动安全更新（禁止自动重启）'
  warn '不会扩充第三方软件源；自动安装补丁仍可能重启应用服务。'
  confirm_word AUTO
  if ! dpkg-query -W -f='${Status}' unattended-upgrades 2>/dev/null | grep -q 'install ok installed'; then
    apt-get update
    apt-get install unattended-upgrades
  fi
  need_cmd apt-config
  local target=/etc/apt/apt.conf.d/95-oci-safe-maintenance
  if [[ -e "$target" ]]; then
    cp -a -- "$target" "${target}.bak.$(date +%Y%m%d%H%M%S)"
  fi
  cat > "$target" <<'APTCONF'
// OCI old Ubuntu: retain existing Ubuntu and Pro ESM allowed origins.
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
Unattended-Upgrade::Automatic-Reboot "false";
APTCONF
  chmod 0644 "$target"
  local effective
  effective="$(apt-config dump)" || die 'apt-config 无法解析当前配置。'
  for expectation in 'APT::Periodic::Update-Package-Lists "1";' 'APT::Periodic::Unattended-Upgrade "1";' 'Unattended-Upgrade::Automatic-Reboot "false";'; do
    grep -Fxq "$expectation" <<<"$effective" || die "配置未生效或被其他文件覆盖：$expectation"
  done
  local ok=1 unit state
  for unit in apt-daily.timer apt-daily-upgrade.timer; do
    state="$(systemctl is-enabled "$unit" 2>/dev/null || true)"
    printf '%s: %s\n' "$unit" "${state:-unknown}"
    [[ "$state" == enabled ]] || ok=0
  done
  if (( ! ok )); then
    warn 'APT 定时器未全部启用，配置文件已写入，但无法保证自动安全更新执行。为避免干预现有策略，不会自行启用；请人工检查。'
    return 1
  fi
  say 'APT 有效配置与两个定时器已验证；可在维护窗口手动运行 unattended-upgrade --dry-run 检查。'
}

manual_patch() {
  require_maintained_lts
  section '人工确认后安装 APT 常规更新（非系统发行版升级）'
  warn '更新内核、SSH、iSCSI、网络或 Docker 相关包前必须先备份，并确认 OCI 串口控制台可用。'
  apt-get update
  # Important: use the same front-end/options for simulation and execution.
  apt-get -s upgrade --no-remove
  warn '请审阅模拟结果，不要在确认前更改软件源。此操作仍可能重启服务。'
  confirm_word PATCH
  apt-get upgrade --no-remove
  if [[ -e /var/run/reboot-required ]]; then
    warn '已提示需要重启；本脚本绝不自动重启。'
  fi
}

restic_ready() {
  need_cmd restic
  [[ -s "$REPO_FILE" && -s "$PASS_FILE" && -s "$PATHS_FILE" ]] || die '缺少完整的 Restic 配置。'
  [[ -d "$CONFIG_DIR" && ! -L "$CONFIG_DIR" ]] || die 'Restic 配置目录异常。'
  [[ "$(stat -c %a "$CONFIG_DIR")" == 700 ]] || die 'Restic 配置目录权限必须为 700。'
  [[ -f "$PASS_FILE" && ! -L "$PASS_FILE" ]] || die 'Restic 密码文件不是普通文件。'
  [[ "$(stat -c %a "$PASS_FILE")" == 600 ]] || die 'Restic 密码文件权限必须为 600。'
  [[ "$(stat -c %u "$PASS_FILE")" == 0 ]] || die 'Restic 密码文件必须属于 root。'
}
restic_run() {
  restic -r "$(cat "$REPO_FILE")" --password-file "$PASS_FILE" "$@"
}


setup_backup() {
  require_maintained_lts
  section '初始化 Restic 加密 SFTP 异地备份'
  warn '请先确认远程 SSH 主机指纹，以及 root 的密钥认证；不要在服务器保存 SFTP 登录密码。'
  warn '存储费用、流量和备份空间需要你自行确认；不能把 OCI 内部存储当作唯一备份。'
  [[ ! -e "$REPO_FILE" && ! -e "$PASS_FILE" && ! -e "$PATHS_FILE" ]] || die '已有 Restic 配置，拒绝覆盖。'
  confirm_word BACKUP
  if ! command -v restic >/dev/null 2>&1; then
    apt-get update
    apt-get install restic
  fi
  need_cmd timeout
  local repo password confirm_password newpath reply tempdir temp_pass
  printf '远端 Restic 仓库，例如 sftp:backup@backup.example:/srv/restic/server1: '
  IFS= read -r repo
  [[ "$repo" =~ ^sftp:[A-Za-z0-9._-]+@[A-Za-z0-9._-]+:/[A-Za-z0-9._/-]+$ ]] || die '请用 sftp:user@host:/absolute/path 格式。'
  read -r -s -p '设定 Restic 加密口令（至少 16 字符）：' password; printf '\n'
  [[ ${#password} -ge 16 ]] || die '加密口令长度不足。'
  read -r -s -p '再次输入口令：' confirm_password; printf '\n'
  [[ "$password" == "$confirm_password" ]] || die '两次口令不一致。'
  install -d -m 0700 "$CONFIG_DIR"
  tempdir="$(mktemp -d "$CONFIG_DIR/.staging.XXXXXXXX")" || die '创建临时配置目录失败。'
  # On abort/CTRL-C, remove staged secrets instead of leaving a half-configured state.
  trap 'if [[ -n "${tempdir:-}" && -d "$tempdir" ]]; then rm -rf -- "$tempdir"; fi' EXIT
  temp_pass="$tempdir/password"
  printf '%s\n' "$password" > "$temp_pass"
  unset password confirm_password
  chmod 0600 "$temp_pass"
  local -a paths=()
  for newpath in /etc /home /root /opt /srv /var/www; do
    [[ -d "$newpath" ]] && paths+=("$newpath")
  done
  warn '默认不包含 /var/lib/docker、数据库在线文件；请先制作应用一致性备份。'
  printf '如已停写并确认一致性，是否添加 Docker 卷目录？输入 YES: '
  IFS= read -r reply
  if [[ "$reply" == YES && -d /var/lib/docker/volumes ]]; then paths+=(/var/lib/docker/volumes); fi
  while :; do
    printf '额外备份目录（必须是现存绝对路径；回车结束）： '
    IFS= read -r newpath
    [[ -z "$newpath" ]] && break
    [[ "$newpath" == /* && -d "$newpath" ]] || { warn '请输入现有绝对目录。'; continue; }
    case "$newpath" in
      /|/proc|/proc/*|/sys|/sys/*|/dev|/dev/*|/run|/run/*|/tmp|/tmp/*|"$CONFIG_DIR"|"$CONFIG_DIR"/*) warn '该路径禁止作为备份根目录。'; continue;;
    esac
    paths+=("$newpath")
  done
  ((${#paths[@]}>0)) || { rm -rf -- "$tempdir"; die '没有有效备份目录。'; }
  printf '%s\n' "${paths[@]}" > "$tempdir/paths"
  printf '%s\n' "$repo" > "$tempdir/repository"
  chmod 0600 "$tempdir/paths" "$tempdir/repository"
  warn '开始非交互式连接测试（最多 90 秒）。连接失败可能意味着目录不存在、认证失败或已有仓库密码不匹配。'
  if timeout 90 restic -r "$repo" --password-file "$temp_pass" snapshots </dev/null >/dev/null 2>&1; then
    say '现有仓库连接成功。'
  else
    warn '无法读取现有仓库。仅当你确认这是一个全新的远端空目录、SSH 密钥正常且指纹可信时才输入 INIT。'
    confirm_word INIT
    if ! timeout 90 restic -r "$repo" --password-file "$temp_pass" init </dev/null; then
      rm -rf -- "$tempdir"
      die '远端初始化失败：正式配置未写入，检查 SSH 和仓库路径后重试。'
    fi
  fi
  # Publish configuration only after the repository was opened or initialized.
  mv -- "$tempdir/repository" "$REPO_FILE"
  mv -- "$temp_pass" "$PASS_FILE"
  mv -- "$tempdir/paths" "$PATHS_FILE"
  rmdir -- "$tempdir"
  tempdir=""
  trap - EXIT
  chmod 0600 "$REPO_FILE" "$PASS_FILE" "$PATHS_FILE"
  say '备份仓库已配置。首次执行 backup-now 后，还必须运行 backup-check 才能启用 timer。'
}

backup_now() {
  restic_ready
  local -a paths=()
  mapfile -t paths < "$PATHS_FILE"
  local item
  ((${#paths[@]}>0)) || die '备份路径列表为空。'
  for item in "${paths[@]}"; do
    [[ "$item" == /* && "$item" != / && ( -d "$item" || -f "$item" ) ]] || die "备份路径不存在或不安全：$item（已停止，避免生成不完整快照）。"
  done
  section '创建 Restic 加密备份快照'
  warn '对运行中的数据库和 Docker 数据卷必须单独进行一致性备份。'
  restic_run backup --exclude "$CONFIG_DIR" --tag oci-safe-maintain "${paths[@]}"
  say '备份完成；运行 backup-check 验证恢复。'
}

backup_list() {
  restic_ready
  restic_run snapshots
}

latest_snapshot_id() {
  need_cmd python3
  restic_run snapshots --json --host "$(hostname)" | python3 -c 'import json,sys; snaps=json.load(sys.stdin); matches=[s for s in snaps if "oci-safe-maintain" in s.get("tags",[])]; print(matches[-1].get("id", "") if matches else "")'
}
backup_check() {
  restic_ready
  section '验证仓库索引与结构（不自动读取全部数据块）'
  restic_run check
  local id dir
  id="$(latest_snapshot_id)" || die '获取最新快照失败。'
  [[ -n "$id" ]] || die '本机还没有带 oci-safe-maintain 标签的备份快照。'
  dir="$(mktemp -d /tmp/oci-restic-restore.XXXXXXXX)"
  if restic_run restore "$id" --target "$dir" --include /etc/passwd && [[ -s "$dir/etc/passwd" && ! -L "$dir/etc/passwd" ]]; then
    rm -rf -- "$dir"
    printf '%s %s\n' "$id" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$VERIFIED_FILE"
    chmod 0600 "$VERIFIED_FILE"
    say '仓库检查与测试文件恢复成功。标记已验证快照。'
  else
    rm -rf -- "$dir"
    die '文件恢复验证失败；定时备份不会据此解锁。'
  fi
  warn '这不是完整恢复演练。可在维护窗口使用 restic check --read-data-subset=1/20 做额外数据块抽检。'
}

backup_timer() {
  restic_ready
  need_cmd systemctl
  section '启用每天一次的 systemd Restic 备份'
  [[ -s "$VERIFIED_FILE" ]] || die '还没有验证记录；必须先运行 backup-now 和 backup-check。'
  [[ "$(stat -c %a "$VERIFIED_FILE")" == 600 ]] || die '验证记录权限错误。'
  local id verified_id checked_at source_path
  id="$(latest_snapshot_id)" || die '无法读取当前快照。'
  read -r verified_id checked_at < "$VERIFIED_FILE"
  [[ -n "$id" && "$id" == "$verified_id" ]] || die '验证记录与最新快照不一致；请重新执行 backup-check。'
  warn '启用后 Persistent=true 可能使定时任务立即补跑；请确认 SFTP 目的地、存储费用和资源余量。'
  confirm_word TIMER
  source_path="$(readlink -f -- "$0")"
  [[ -r "$source_path" ]] || die '无法读取脚本本体。'
  if [[ "$source_path" != "$INSTALLED_SCRIPT" ]]; then
    install -m 0700 "$source_path" "$INSTALLED_SCRIPT"
  fi
  cat > /etc/systemd/system/oci-restic-backup.service <<'UNIT'
[Unit]
Description=OCI Ubuntu Restic encrypted data backup
Wants=network-online.target
After=network-online.target
[Service]
Type=oneshot
User=root
ExecStart=/usr/local/sbin/oci-ubuntu-safe-maintain backup-now
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7
UNIT
  cat > /etc/systemd/system/oci-restic-backup.timer <<'UNIT'
[Unit]
Description=Daily OCI Ubuntu Restic backup
[Timer]
OnCalendar=*-*-* 03:30:00
RandomizedDelaySec=45m
Persistent=true
Unit=oci-restic-backup.service
[Install]
WantedBy=timers.target
UNIT
  chmod 0644 /etc/systemd/system/oci-restic-backup.{service,timer}
  if command -v systemd-analyze >/dev/null 2>&1; then
    systemd-analyze verify /etc/systemd/system/oci-restic-backup.{service,timer} || die 'systemd 单元验证失败；未启用定时器。'
  fi
  systemctl daemon-reload
  systemctl enable --now "$TIMER_NAME"
  systemctl list-timers --all "$TIMER_NAME" --no-pager || true
  say '定时备份已启用。请用 journalctl -u oci-restic-backup.service 检查后续运行结果。'
}

help_text() {
  cat <<'HELP'
OCI Ubuntu 老实例安全维护助手 v0.2.0（Ubuntu 18.04/20.04/22.04/24.04）

sudo bash oci_ubuntu_safe_maintain.sh [命令]

命令：
  audit          系统体检（默认、只读）
  pro            登录 Ubuntu Pro 并启用 ESM（需要确认）
  auto-security  配置 Ubuntu/ESM 自动安全更新，禁止自动重启（需要确认）
  patch          模拟并在确认后应用 apt 软件包更新（不升级 Ubuntu 大版本）
  backup-setup   安装/配置 Restic 加密 SFTP 异地仓库（需要确认）
  backup-now     执行一次备份
  backup-check   检查仓库并恢复测试文件
  backup-list    查看备份快照
  backup-timer   配置每日备份定时器（需要确认）
  menu           交互菜单

永不自动执行：do-release-upgrade、reboot、ufw、修改 SSH 配置、OCI 资源删除、清理备份快照。
提示：OCI 启动盘快照必须在 OCI 控制台单独做；脚本不会操作 OCI API。
HELP
}

menu() {
  require_tty
  cat <<'MENU'

==== OCI 老 Ubuntu 安全维护 ====
1) 只读体检（建议先做）
2) 绑定 Ubuntu Pro / 开启 ESM
3) 配置自动安全补丁（不自动重启）
4) 预览并手动安装 apt 更新
5) 配置 Restic 加密 SFTP 异地备份
6) 立即备份
7) 检查备份 + 测试恢复
8) 启用每日备份定时器
9) 列出 Restic 快照
0) 退出
MENU
  printf '选择: '
  local choice
  IFS= read -r choice
  case "$choice" in
    1) inspect;; 2) setup_pro;; 3) setup_auto_updates;; 4) manual_patch;;
    5) setup_backup;; 6) backup_now;; 7) backup_check;; 8) backup_timer;;
    9) backup_list;; 0) exit 0;; *) die '无效选项。';;
  esac
}

main() {
  local action="${1:-menu}"
  case "$action" in -h|--help|help) help_text; exit 0;; esac
  [[ $EUID -eq 0 ]] || die '需要 root：请使用 sudo bash /path/to/script [命令]。'
  check_os
  case "$action" in
    menu) menu;; audit) inspect;; pro) setup_pro;;
    auto-security) setup_auto_updates;; patch) manual_patch;;
    backup-setup) setup_backup;; backup-now) backup_now;;
    backup-check) backup_check;; backup-list) backup_list;;
    backup-timer) backup_timer;; *) help_text; exit 2;;
  esac
}
main "$@"
