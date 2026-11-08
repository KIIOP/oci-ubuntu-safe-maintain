#!/usr/bin/env bash
# OCI Ubuntu LTS safe-maintenance helper (2026-11)
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
  warn '分享输出前请遮盖公网 IP、域名、主机名、账号信息与敏感容器名称。'
}

setup_pro() {
  require_maintained_lts
  section '启用 Ubuntu Pro ESM（不会升级 Ubuntu 大版本）'
  warn '此操作会添加 Ubuntu Pro 软件源，可能触发额外软件包更新；建议先创建 OCI 启动盘备份。'
  warn '必须用你或家人自己符合使用条款的 Ubuntu Pro 订阅，并在网页上完成授权。不要把 token 复制到聊天。'
  confirm_word PRO
  if ! command -v pro >/dev/null 2>&1; then
    say '安装 ubuntu-pro-client（Ubuntu 18.04 的旧仓库可能使用 ubuntu-advantage-tools 包名）...'
    apt-get update
    if ! apt-get install ubuntu-pro-client; then
      apt-get install ubuntu-advantage-tools
    fi
  fi
  need_cmd pro
  say '当前状态：'
  LC_ALL=C pro status || true
  local status
  status="$(LC_ALL=C pro status 2>&1 || true)"
  if grep -Eqi 'not attached|not subscribed' <<<"$status"; then
    say '启动网页配对流程（不自动启用 Livepatch 等服务）...'
    pro attach --no-auto-enable
  else
    warn '状态未显示「not attached」，暂不重复绑定；尝试直接启用 ESM。'
  fi
  say '启用 esm-infra（若已启用则保持原状态）...'
  pro enable esm-infra
  say '启用 esm-apps（若已启用则保持原状态）...'
  pro enable esm-apps
  pro status || true
  say 'ESM 已处理。补丁并不会由此立即全部安装；检查后选择 patch。'
}

setup_auto_updates() {
  require_maintained_lts
  section '启用默认 Ubuntu/ESM 自动安全补丁，无人值守自动重启关闭'
  warn 'Ubuntu 默认 unattended-upgrades 会使用其原有的允许源配置，本脚本不改动 Allowed-Origins，也不纳入第三方 PPA。'
  warn '安装安全补丁依然可能重启某些服务；需要开机重启时必须由你手动进行。'
  confirm_word AUTO
  if ! dpkg-query -W -f='${Status}' unattended-upgrades 2>/dev/null | grep -q 'install ok installed'; then
    apt-get update
    apt-get install unattended-upgrades
  fi
  local target=/etc/apt/apt.conf.d/95-oci-safe-maintenance
  if [[ -e "$target" ]]; then
    cp -a -- "$target" "${target}.bak.$(date +%Y%m%d%H%M%S)"
  fi
  cat > "$target" <<'APTCONF'
// OCI old Ubuntu: keep existing Ubuntu/ESM origin rules.
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
Unattended-Upgrade::Automatic-Reboot "false";
APTCONF
  chmod 0644 "$target"
  say "已写入 $target"
  apt-config dump | grep -E '(Periodic::Unattended-Upgrade|Periodic::Update-Package-Lists|Unattended-Upgrade::Automatic-Reboot)' || true
  say '检查 apt-daily 与 apt-daily-upgrade timers；不强制 enable/now，以免覆盖已有运维策略。'
  for unit in apt-daily.timer apt-daily-upgrade.timer; do
    printf '%s: ' "$unit"; systemctl is-enabled "$unit" 2>/dev/null || true
  done
  warn '若上述 timers 显示 disabled/masked，需另行检查已有运维配置后决定是否启用。'
}

manual_patch() {
  require_maintained_lts
  section '手动安装可用软件包更新（非 Ubuntu 大版本升级）'
  warn '请先做 OCI 启动盘备份 + Restic 数据备份；apt 可能更新内核或重启应用服务。'
  say '先刷新 APT 索引并模拟升级；如有问题将停止。'
  apt-get update
  apt-get -s upgrade
  warn '确认以上计划无不兼容软件包、删除操作或关键业务风险后再继续。'
  confirm_word PATCH
  # Intentionally interactive: no -y, no release upgrade, no reboot.
  apt upgrade
  if [[ -e /var/run/reboot-required ]]; then
    warn '更新后需要重启。脚本不会重启；请在测试串口控制台后选维护窗口重启。'
  fi
}

restic_ready() {
  need_cmd restic
  [[ -s "$REPO_FILE" && -s "$PASS_FILE" && -s "$PATHS_FILE" ]] || \
    die '尚未完成备份初始化；先运行 backup-setup。'
  [[ "$(stat -c %a "$PASS_FILE")" == 600 ]] || warn 'Restic 密码文件权限不是 600，请立即修正。'
}
restic_run() {
  restic -r "$(cat "$REPO_FILE")" --password-file "$PASS_FILE" "$@"
}

setup_backup() {
  require_maintained_lts
  section '初始化 Restic 加密异地备份（SFTP）'
  warn '备份目的地应是 OCI 以外、独立控制的 SFTP 存储；请自行确认空间、费用和 SSH 主机指纹。'
  warn '不要将仓库存放到本机系统盘作为唯一备份；两台机器请使用不同的仓库目录；数据库需要额外的一致性导出。'
  [[ ! -e "$REPO_FILE" && ! -e "$PASS_FILE" ]] || \
    die '检测到已有备份配置。为避免覆盖密钥或备份仓库，本脚本拒绝再次初始化。'
  confirm_word BACKUP
  if ! command -v restic >/dev/null 2>&1; then
    apt-get update
    apt-get install restic
  fi
  require_tty
  local repo password confirm_password newpath reply
  printf '远端 Restic 仓库（示例 sftp:backup@backup.example:/srv/restic/server1）: '
  IFS= read -r repo
  [[ "$repo" == sftp:* && "$repo" != *$'\n'* ]] || die '此版本仅自动配置 sftp: 仓库，防止本机备份误认为异地备份。'
  read -r -s -p '设定新的 Restic 加密口令（>=16 字符）：' password; printf '\n'
  [[ ${#password} -ge 16 ]] || die '口令过短。'
  read -r -s -p '再次输入口令：' confirm_password; printf '\n'
  [[ "$password" == "$confirm_password" ]] || die '两次口令不一致。'
  install -d -m 0700 "$CONFIG_DIR"
  printf '%s\n' "$repo" > "$REPO_FILE"
  printf '%s\n' "$password" > "$PASS_FILE"
  unset password confirm_password
  chmod 0600 "$REPO_FILE" "$PASS_FILE"
  : > "$PATHS_FILE"
  for newpath in /etc /home /root /opt /srv /var/www; do
    [[ -d "$newpath" ]] && printf '%s\n' "$newpath" >> "$PATHS_FILE"
  done
  say '已预置存在的 /etc、/home、/root、/opt、/srv、/var/www。'
  warn '默认不包含正在运行的 Docker 卷或数据库，因为直接复制可能导致不一致。'
  printf '是否额外加入 /var/lib/docker/volumes（仅限已停写/已做数据库导出的情况）？输入 YES 添加: '
  IFS= read -r reply
  if [[ "$reply" == YES && -d /var/lib/docker/volumes ]]; then
    printf '%s\n' /var/lib/docker/volumes >> "$PATHS_FILE"
  fi
  while :; do
    printf '输入其他需要备份的绝对目录路径（回车结束）：'
    IFS= read -r newpath
    [[ -z "$newpath" ]] && break
    [[ "$newpath" == /* && -d "$newpath" ]] || { warn '必须是现存绝对目录。'; continue; }
    [[ "$newpath" != / && "$newpath" != "$CONFIG_DIR" ]] || { warn '为避免过度备份或存储密码文件，拒绝该路径。'; continue; }
    printf '%s\n' "$newpath" >> "$PATHS_FILE"
  done
  chmod 0600 "$PATHS_FILE"
  say '正在测试仓库连接。初次连接请核实服务器 SSH host key 指纹。'
  if restic_run snapshots >/dev/null 2>&1; then
    say '连接到已有仓库成功，未执行 init。'
  else
    warn '不能读取现有仓库：可能是一个新路径，也可能是 SSH/网络/密码错误。请先确认。'
    confirm_word INIT
    restic_run init
  fi
  say '备份配置完成；务必把 Restic 加密口令另存密码管理器，遗失口令无法恢复数据。'
  say '使用 backup-now 首次备份、backup-check 验证，之后才能启用 backup-timer。'
}

backup_now() {
  restic_ready
  local -a paths=() listed=()
  mapfile -t listed < "$PATHS_FILE"
  local item
  for item in "${listed[@]}"; do
    [[ -d "$item" || -f "$item" ]] && paths+=("$item") || warn "路径已不存在，跳过：$item"
  done
  [[ ${#paths[@]} -gt 0 ]] || die '没有可用的备份路径。'
  section '创建 Restic 加密备份快照'
  warn '运行中数据库和 Docker 卷不能仅靠文件复制保证一致性，请确保额外导出或停写。'
  # Never put the repository encryption password back into its own backups.
  restic_run backup --exclude "$CONFIG_DIR" --tag oci-safe-maintain "${paths[@]}"
  say '备份完成；下一步运行 backup-check。'
}

backup_list() {
  restic_ready
  restic_run snapshots
}

backup_check() {
  restic_ready
  section '检查 Restic 仓库结构（不代表读取验证了所有数据块）'
  restic_run check
  section '将 /etc/passwd 恢复到 root 专用临时目录，验证实际文件读取（不会显示内容）'
  local dir
  dir="$(mktemp -d /tmp/oci-restic-restore.XXXXXXXX)"
  if restic_run restore latest --host "$(hostname)" --target "$dir" --include /etc/passwd; then
    [[ -s "$dir/etc/passwd" && ! -L "$dir/etc/passwd" ]] || die "恢复测试未产生有效普通文件，请检查：$dir"
    say '恢复测试成功（不会打印账号清单或覆盖原系统）。'
    rm -f -- "$dir/etc/passwd"
    rmdir -- "$dir/etc" "$dir" 2>/dev/null || true
  else
    warn "恢复测试失败。检查临时目录：$dir"
    return 1
  fi
  say '建议定期另做数据库/应用的完整恢复演练。'
}

backup_timer() {
  restic_ready
  command -v systemctl >/dev/null 2>&1 || die '缺少 systemctl。'
  section '配置每日 systemd Restic 异地备份'
  warn '先确认 backup-now 和 backup-check 均通过；每日备份会产生远端存储占用/流量与潜在账单。'
  warn '仅安装定时备份，不执行自动 prune（避免误删旧快照）。'
  confirm_word TIMER
  local source_path
  source_path="$(readlink -f -- "$0")"
  [[ -r "$source_path" ]] || die "无法读取脚本本体：$source_path"
  if [[ "$source_path" != "$INSTALLED_SCRIPT" ]]; then
    install -m 0700 "$source_path" "$INSTALLED_SCRIPT"
  fi
  cat > /etc/systemd/system/oci-restic-backup.service <<'UNIT'
[Unit]
Description=OCI Ubuntu Restic data backup (no upgrade)
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
  systemctl daemon-reload
  systemctl enable --now "$TIMER_NAME"
  systemctl list-timers --all "$TIMER_NAME" --no-pager || true
  say '定时备份已启用：每天约 03:30（服务器本地时区）+ 最多 45 分钟随机延迟。'
  say '检查日志：sudo journalctl -u oci-restic-backup.service -n 100 --no-pager'
}

help_text() {
  cat <<'HELP'
OCI Ubuntu 老实例安全维护助手（Ubuntu 18.04/20.04/22.04/24.04）

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