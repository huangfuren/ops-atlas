# 004 分布式 Proxy

> **解决**：主机分布在多个网段、分支或弱网环境时，怎么让采集不被网络掐断，断网恢复后数据还能补回来。  
> **范围**：Proxy 的适用场景 · 主动/被动模式 · 部署与注册 · 主机分配 · 队列排错 · 容量与高可用。  
> **口径**：Zabbix 6.0 LTS；Proxy 数据库默认 SQLite3，规模化改用 MySQL/PostgreSQL；6.0 的 proxy group 单独说明。  
> **更新**：2026-11-06

## 目录

| 节 | 内容 |
|---|---|
| 1 | 什么时候需要 Proxy |
| 2 | 主动与被动模式 |
| 3 | 部署与注册 |
| 4 | 队列与排错 |
| 5 | 容量与高可用 |
| 6 | 坑表 |
| 7 | 检查清单 |

---

## 1. 什么时候需要 Proxy

上一册的告警依赖数据及时到达；本节解决「数据在路上就断了」的问题。

Proxy 不是「可选加速器」，它解决三类硬问题：

| 场景 | 不用 Proxy 的后果 |
|---|---|
| 多分支/多 IDC，server 与主机之间隔着专线或 NAT | 只能单向开放端口，跨域策略难批 |
| 被监控机数量大，server 的 poller 不够 | 队列积压，采集延迟越滚越大 |
| 网络不稳定，断几分钟就丢数据 | 历史出现空洞，事后无法复盘 |

**判断标准**：主机到 server 的链路是否需要「本地缓存 + 断点续传」。需要就上 Proxy；只是主机多，先加 poller 与调缓存。

---

## 2. 主动与被动模式

上一节确定了要 Proxy；本节决定它和 server 谁先发起连接——这是配置错得最多的一处。

### 2.1 两种模式的数据流

| | 主动模式（ProxyMode=0） | 被动模式（ProxyMode=1） |
|---|---|---|
| 谁发起 | Proxy → server:10051 | server → proxy:10051 |
| 配置怎么拿 | Proxy 周期拉取 | server 推送 |
| 防火墙 | Proxy 出站到 server 即可 | server 能连到 Proxy |
| 适合 | 分支、NAT 后、server 不可直达 | Proxy 有固定可路由地址 |
| 配置频率 | `ProxyConfigFrequency`（默认 3600s） | server 主动推 |

多数分支场景选**主动**：只需要一条出站规则，安全策略最容易批。

### 2.2 关键配置项

```ini
# /etc/zabbix/zabbix_proxy.conf
ProxyMode=0                     # 0 主动 / 1 被动
Server=10.0.0.10                # 主动：server 地址；被动：允许哪些 server 来连
Hostname=proxy-bj-01            # 必须与前端注册名逐字符一致
ProxyConfigFrequency=600        # 主动模式拉配置间隔，默认 3600 偏长
DataSenderFrequency=1           # 送数据间隔（秒）
ProxyOfflineBuffer=24           # 断网本地缓存小时数，按最长断网时间设
```

`ProxyOfflineBuffer` 是最容易被忽略的一项：默认 1 小时，专线断一下午，超出部分直接丢，恢复后补不回来。

---

## 3. 部署与注册

上一节选好模式；本节把它装起来并在前端登记。

### 3.1 安装与数据库

```bash
dnf install -y zabbix-proxy-mysql zabbix-sql-scripts

# 建库（与 server 分开的库名，避免混用）
mysql -uroot -p -e "CREATE DATABASE zabbix_proxy CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;"
mysql -uroot -p -e "CREATE USER 'zabbix'@'localhost' IDENTIFIED BY '强口令'; GRANT ALL ON zabbix_proxy.* TO 'zabbix'@'localhost';"

zcat /usr/share/doc/zabbix-sql-scripts/mysql/proxy.sql.gz | mysql -uzabbix -p zabbix_proxy
```

小规模（几百台以内）可用默认 SQLite，省掉数据库维护；规模再大或需要并发写入，换 MySQL/PostgreSQL。

### 3.2 启动与注册

```bash
vi /etc/zabbix/zabbix_proxy.conf     # 按上一节填四项
systemctl enable --now zabbix-proxy
ss -lntp | grep 10051
tail -f /var/log/zabbix/zabbix_proxy.log
```

前端：`Administration → Proxies → Create proxy`

| 字段 | 填什么 |
|---|---|
| Proxy name | 与 `Hostname` 完全一致，如 `proxy-bj-01` |
| Proxy mode | Active / Passive，与配置文件一致 |
| Proxy address | 被动模式必填，主动模式可留空 |
| Proxy group | 6.0 可加入组，做负载与故障切换 |

保存后看列表的 `Last seen`：主动模式应在 `ProxyConfigFrequency` 内变为「刚刚」；一直 `Never` 就是 Hostname 或 10051 方向有问题。

### 3.3 把主机分配给 Proxy

`Data collection → Hosts → 选中主机 → Monitored by proxy` 选对应 Proxy。**新主机不会自动落到 Proxy**，漏了这一步会表现为「Proxy 装好了但没数据」，主机仍由 server 直接采。

---

## 4. 队列与排错

上一节把链路建好；本节处理「数据在队列里排队」。

### 4.1 队列看哪里

`Administration → Queue`，三个视角：

| 视角 | 看什么 | 含义 |
|---|---|---|
| Overview | 各 proxy/server 的排队项数 | 整体是否积压 |
| Queue details | 具体 item 与等待秒数 | 哪台主机、哪个 item 慢 |
| 5 分钟/1 小时趋势 | 积压变化 | 突增还是长期 |

前端 `Reports → System information` 还能看 server/proxy 的进程忙闲与缓存使用。

### 4.2 积压的四个根因

| 根因 | 判据 | 处理 |
|---|---|---|
| 数据库写不动 | MySQL 慢查询、磁盘 IO 高 | 加索引/换盘/清理历史 |
| housekeeper 抢占 | 清理任务长时间运行 | 调保留期，避开高峰 |
| poller/trapper 不足 | 进程利用率长期 100% | 调 `StartPollers`/`StartTrappers` |
| 网络或 Proxy 缓存满 | Proxy 日志报 buffer 满 | 扩 `ProxyOfflineBuffer`、查链路 |

**先分清是 server 队列还是 proxy 队列**：proxy 侧积压说明它连不上 server 或本地库慢；server 侧积压说明写库或进程不够。

### 4.3 常用排错命令

```bash
# 重载配置缓存（改宏/模板后不重启）
zabbix_server -R config_cache_reload
zabbix_proxy  -R config_cache_reload

# 看进程与队列
ps -ef | grep -E 'zabbix_(server|proxy)'
mysql -uzabbix -p zabbix -e "SELECT COUNT(*) FROM history_uint;"
```

---

## 5. 容量与高可用

上一节处理单点积压；本节看规模上来之后的设计。

### 5.1 容量估算的三个数

| 输入 | 怎么估 | 影响 |
|---|---|---|
| 监控项总数 | 主机数 × 每台 item 数（含 LLD 生成） | poller 数量、缓存 |
| 采集频率 | 核心 30s、普通 1~5m | 写入 QPS、库容量 |
| 保留期 | 历史 7~30 天、趋势 1 年 | 磁盘、housekeeper 压力 |

一个可用的粗算：**写入 QPS ≈ 监控项数 ÷ 平均采集间隔（秒）**。10 万 item、平均 60 秒，约 1600 写/秒，MySQL 单机需专门调优。

### 5.2 6.0 的 proxy group

6.0 引入 proxy group：多个 Proxy 组成一组，前端把主机分配给「组」而不是单个 Proxy，组内自动分摊与故障切换。

| 能力 | 说明 |
|---|---|
| 负载均衡 | 主机按组内 Proxy 分摊 |
| 故障切换 | 某台 Proxy 失联，其主机由组内其他 Proxy 接管 |
| 前提 | 组内 Proxy 版本一致、都能访问同一批主机 |

没有 proxy group 时，想做到同等效果只能手工分片，一台挂了要人工改分配。

### 5.3 server 自身的高可用

Zabbix server 6.0 支持原生 HA（多节点主备，共享数据库，靠数据库锁选主）。注意：

- 备节点不采集，只待命；
- 前端可指向任一节点；
- 数据库仍是单点，需要单独做 MySQL 主从或 MHA。

---

## 6. 坑表

| # | 现象 | 原因 | 解法 |
|---|---|---|---|
| 1 | 前端 Last seen 一直 Never | Hostname 与 Proxy name 不一致，或 10051 方向错 | 逐字符对齐；主动/被动模式与防火墙方向一起核 |
| 2 | Proxy 装好但主机没数据 | 主机未分配 `Monitored by proxy` | 批量选主机改分配 |
| 3 | 断网恢复后历史有空洞 | `ProxyOfflineBuffer` 太短，超时数据被丢 | 按最长断网时间调大，注意磁盘 |
| 4 | Proxy 本地库暴涨 | SQLite 单文件增长、未及时上传 | 查链路与 `DataSenderFrequency`，必要时换 MySQL |
| 5 | 队列长期积压 | 数据库写慢或 housekeeper 抢占 | 看慢查询、调保留期、加磁盘 |
| 6 | 改了模板 Proxy 端不生效 | 配置未到拉取周期 | 调小 `ProxyConfigFrequency` 或重载缓存 |
| 7 | 数据时间错乱 | Proxy 与 server 时间不同步 | 全部上 chrony，偏差秒级 |
| 8 | 升级后 Proxy 连不上 | proxy 版本高于 server | Proxy 版本不高于 server，按 server → proxy 顺序升级 |
| 9 | 跨公网明文传输 | 未启用 PSK 加密 | 配 TLS PSK，`TLSConnect=psk` |
| 10 | proxy group 里主机不切换 | 组内 Proxy 版本/网络不一致 | 统一版本，确认都能到被监控网段 |

## 7. 检查清单

| # | 问题 | 判据 |
|---|---|---|
| 1 | Proxy 的 Hostname 与前端名一致吗？ | `Last seen` 在周期内更新 |
| 2 | 主动/被动模式与防火墙方向对上了吗？ | 只开必要方向，能通 |
| 3 | 主机都分配到 Proxy 了吗？ | Queue 里能看到该 Proxy 的采集项 |
| 4 | 断网缓存时长够吗？ | `ProxyOfflineBuffer` ≥ 最长计划外断网 |
| 5 | 时间同步做了吗？ | 两端 `chronyc tracking` 偏差秒级 |
| 6 | 规模化前算过写入 QPS 吗？ | 监控项数 ÷ 平均间隔，与库容量匹配 |

---

**下一篇**：[005 API 自动化](005-API自动化.md) —— 把重复的纳管、导出、巡检交给脚本。
