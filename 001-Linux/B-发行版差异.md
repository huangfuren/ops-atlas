# 附录 B　发行版差异对照

> 正文以 **CentOS 7** 与 **Ubuntu 22.04** 为主写两套命令；这张表回答另一个问题：**同一件事，换到 CentOS 6 / Rocky / Debian 上，要改哪几个字。**  
> 以下按各版本**最小化安装后的默认值**，装过额外包或改过默认的不算。

## 一、九维矩阵

| 维度 | CentOS 6 | CentOS 7 | Rocky 9 | Ubuntu 22.04 | Debian 12 |
| --- | --- | --- | --- | --- | --- |
| **状态** | EOL 2020-11 | EOL 2024-06 | 维护中 | 维护中 | 维护中 |
| **init / 服务** | Upstart `service` `chkconfig` | systemd | systemd | systemd | systemd |
| **包管理** | `yum` + `rpm` | `yum` + `rpm` | `dnf` + `rpm` | `apt` + `dpkg` | `apt` + `dpkg` |
| **防火墙** | `iptables` | `firewalld`（iptables 后端） | `firewalld`（nftables 后端） | `ufw`（底层 iptables-nft） | `nftables`（需装，无前端） |
| **网络配置** | `ifcfg` + `network` | `ifcfg` + NetworkManager | NetworkManager keyfile | `netplan` | `ifupdown`（`/etc/network/interfaces`） |
| **默认文件系统** | ext4 | xfs | xfs | ext4 | ext4 |
| **强制访问控制** | SELinux | SELinux | SELinux | AppArmor | AppArmor（策略较少） |
| **日志** | rsyslog | journald + rsyslog | journald + rsyslog | journald + rsyslog | journald + rsyslog |
| **时间同步** | `ntpd` | `chrony` | `chrony` | `systemd-timesyncd` | `systemd-timesyncd` |
| **内核 / Python** | 2.6.32 / 2.6 | 3.10 / 2.7 | 5.14 / 3.9 | 5.15 / 3.10 | 6.1 / 3.11 |

## 二、五个最常踩的差异

**1. CentOS 6 没有 systemctl，也没有 firewalld。**
用 `service sshd start`、`chkconfig sshd on`、`iptables -L`。CentOS 6 已于 2020-11 EOL，正常只该出现在存量环境——排查要会用，新环境不要上。

**2. CentOS 7 的 journald 默认不落盘。**
`/var/log/journal` 目录不存在时，`journalctl` 读的是内存日志，**重启即全部丢失**，而 `systemctl status` 一切正常，很容易误判「日志没写」。

```bash
ls -d /var/log/journal || echo "未持久化，重启后日志会丢"
sudo mkdir -p /var/log/journal && sudo systemctl restart systemd-journald
```

Rocky 9、Ubuntu、Debian 默认已持久化。CentOS 7 上做故障复盘前，先确认这一步。

**3. CentOS 7 → Rocky 9，`iptables` 变成了兼容层。**
Rocky 9 的 `iptables` 命令仍可用，但底层是 nftables。后果是 **`iptables -L` 看到的规则和 `nft list ruleset` 不完全一致**，两处对不上时不要怀疑自己。

- 新写规则：用 `firewall-cmd`，或直接 `nft`；
- 清空规则：`iptables -F` 只清兼容层对应表，`nft flush ruleset` 才是全清。

**4. Ubuntu / Debian 没有 ifcfg。**
Ubuntu 改 `/etc/netplan/*.yaml` 后必须 `sudo netplan apply`；Debian 改 `/etc/network/interfaces` 后 `sudo systemctl restart networking`。另外 **Debian 默认不装 ufw**，`ufw status` 会提示命令不存在，别以为是权限问题。

**5. 日志文件名不同。**
RHEL 系是 `/var/log/messages` + `secure`，Debian 系是 `/var/log/syslog` + `auth.log`。写脚本或照着文档查日志时，先 `ls` 一下确认文件存在，比记住结论可靠。

## 三、怎么用这张表

- 正文命令写两套（CentOS 7 / Ubuntu）时，不重复上面这些差异。
- 遇到表里没有的维度，按「先确认发行版与版本，再查该版本 `--help`」处理，不硬套。
- 跨版本迁移前先跑一遍 `cat /etc/os-release`——`Rocky 9` 与 `CentOS 7` 同属 RHEL 系，但内核、包管理器、防火墙后端三者都换了，不能当成「只是换个名字」。

---

**上一篇**：[A 命令速查](A-命令速查.md)　**回到**：[Linux 板块总览](README.md)
