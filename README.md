# OCI Ubuntu 老实例安全维护助手

适用于 Oracle Cloud Infrastructure (OCI) 上的 Ubuntu LTS 18.04 / 20.04 / 22.04 / 24.04 (ARM64/AMD64)。目标是保留原实例、降低旧系统长期运行风险，**不执行 Ubuntu 大版本升级**。

> ⚠️ 重要：此脚本不是官方 Oracle/Canonical 工具，尚未在你的真实 OCI 实例上验证。请先检查代码，在维护窗口操作，提前备份并测试 OCI 串口控制台。Ubuntu Pro 和 ESM 是否适用取决于 Ubuntu 版本及订阅状态。版本支持范围以 Canonical 实际政策为准。

## 功能

- `audit`：只读检查操作系统、内核、磁盘、APT、Ubuntu Pro、SSH、UFW、Docker 和失败服务。
- `pro`：可选绑定 Ubuntu Pro，启用 ESM；需要人工确认。
- `auto-security`：设置定期安全补丁安装，禁止自动重启；沿用既有软件源策略。
- `patch`：先模拟 APT 升级，人工确认后执行普通软件包更新。
- `backup-setup`：交互式配置加密 Restic SFTP 异地备份仓库。
- `backup-now`：手动创建数据备份。
- `backup-check`：检查备份仓库并尝试恢复 `/etc/passwd` 到临时目录。
- `backup-timer`：经确认启用每日定时备份。
- `backup-list`：查看已有快照。

**不会自动执行：** `do-release-upgrade`、重启、修改 SSH、修改 OCI 防火墙、OCI API 操作、删除实例/启动盘、备份清理。

## 使用

将 `oci_ubuntu_safe_maintain.sh` 复制到服务器，并**先审阅源代码**：

```bash
less oci_ubuntu_safe_maintain.sh
bash -n oci_ubuntu_safe_maintain.sh
sudo bash oci_ubuntu_safe_maintain.sh audit
```

确认体检结果后使用交互菜单：

```bash
sudo bash oci_ubuntu_safe_maintain.sh
```

也可按需执行单项：

```bash
sudo bash oci_ubuntu_safe_maintain.sh pro
sudo bash oci_ubuntu_safe_maintain.sh auto-security
sudo bash oci_ubuntu_safe_maintain.sh patch
sudo bash oci_ubuntu_safe_maintain.sh backup-setup
sudo bash oci_ubuntu_safe_maintain.sh backup-now
sudo bash oci_ubuntu_safe_maintain.sh backup-check
sudo bash oci_ubuntu_safe_maintain.sh backup-timer
```

## 安全注意事项

1. 最先执行 `audit`，并在 OCI 控制台建立启动盘备份。**启动盘备份和 Restic 文件备份互不替代。**
2. 不要在 OCI Ubuntu 云镜像上未经验证地执行 `ufw enable`；网络访问优先通过 OCI NSG / Security List 限制。
3. 不要用 `curl ... | bash` 方式直接执行远程代码；下载、阅读、校验后手动执行。
4. Restic 密钥及配置文件会放在 `/etc/oci-ubuntu-maintain`（应只有 root 能读），不要提交到 GitHub。丢失 Restic 密码将无法解密备份。
5. Restic 不保证运行中数据库或 Docker 卷备份一致；需要额外数据库导出/停写、并测试业务级恢复。
6. 两台 VPS 建议使用**不同的备份仓库目录**，并把备份放在 OCI 之外。
7. 自动安全更新可能重启部分服务；脚本禁用的是**自动机器重启**，不等于补丁安装完全无风险。
8. 恢复 `latest` 快照的文件验证不等于整个仓库完整数据恢复演练；还应定期验证关键应用。
9. 切勿在 GitHub 仓库中提交 OCI API Key、SSH 私钥、Ubuntu Pro Token、Restic 密码或真实服务器 IP。

## 支持范围

脚本以 Bash 编写，主要针对 Ubuntu 18.04/20.04/22.04/24.04。发行版更改操作受版本检查限制。ARM64、AMD64 均可运行，但实际依赖于该 Ubuntu 版本仓库能否安装 Ubuntu Pro 客户端和 Restic。

## 相关文档

- [Ubuntu Pro](https://ubuntu.com/pro)
- [Oracle Cloud Free Tier](https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm)
- [Restic](https://restic.readthedocs.io/)

## 项目状态

v0.2.0 安全加固版：已通过 `bash -n` 静态语法检查及本地模拟测试（APT 预览、备份目录失效、未验证备份禁止启用定时器）。尚未在真实 OCI 实例上完成端到端测试；请先备份并在低风险实例验证。

## v0.2.0 安全修复说明

- **APT**：模拟与执行均使用 `apt-get upgrade --no-remove`；不自动确认、不自动重启、不升级发行版。
- **自动更新**：检查最终 `apt-config dump` 生效值以及两个 APT 定时器；若 timer 未启用则返回失败并提醒人工处理，不强行变更原策略。
- **OCI**：只读检查 `iptables-save` 内常见 iSCSI 地址、Oracle Cloud Agent 和 iSCSI 服务状态。缺少地址并不一定代表故障（启动盘可能是半虚拟化的）；不会自动调整防火墙。
- **Restic 初始化**：新配置先在 root-only 临时目录暂存，仓库连通或初始化成功才提交正式配置。连接测试上限 90 秒，用户取消时清理临时密码。需要 root SSH 密钥认证和正确的 known_hosts 指纹。
- **备份完整性**：配置的源路径不存在则中止，不再静默跳过；数据库和运行中的 Docker 数据卷仍须单独做应用一致性备份。
- **定时备份**：首次 `backup-now` 和 `backup-check` 必须成功；恢复校验后记录快照标识，才允许启用定时器。启用时 `Persistent=true` 可能立即补跑。
- **Restic 全量校验**：`backup-check` 包含 `restic check` 与 `/etc/passwd` 的文件恢复验证，但不保证所有数据库/文件完整可恢复；深度校验可独立运行 `restic check --read-data-subset=1/20`（会消耗流量）。

使用顺序：`audit` → 在 OCI 控制台制作启动盘备份 → `backup-setup` → `backup-now` → `backup-check` → `pro` → `auto-security` → （维护窗口）`patch` → `backup-timer`。

**重要限制**：修改 `auto-security`、`pro` 或 `patch` 仍可能安装软件包并重启服务；建议先在非关键实例试运行。旧 Ubuntu 镜像/仓库、第三方 PPA、OCI 网络/iSCSI 启动方式均有差异，脚本不能保证零风险。
