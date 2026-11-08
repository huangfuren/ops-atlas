# 009 HAProxy 四层负载均衡

> **解决**：TCP/端口级的四层转发用什么引擎、怎么配、怎么验证、怎么停——HAProxy 独立引擎的生产运维。  
> **范围**：四层七层分界 · frontend/backend 配置 · unit 纪律 · stats 监控口 · tcp-check 角色坑 · 端口冲突矩阵 · 迁移切流。  
> **口径**：HAProxy 2.8 LTS；与 003（Nginx upstream，七层视角）、008（Keepalived 双机高可用）分工——本册只讲四层转发引擎本身；示例 IP 均为文档段。  
> **更新**：2026-11-08

## 目录

| 节 | 内容 |
|---|---|
| 9.1 | 四层与七层：分界与验证方式差异 |
| 9.2 | 配置结构：frontend/backend 里没有域名 |
| 9.3 | 生产 unit 纪律：为什么只能 restart |
| 9.4 | stats 监控口：人看与机器看双通道 |
| 9.5 | 健康检查：tcp-check 的角色坑 |
| 9.6 | 端口冲突矩阵：bind 失败 = 整机不起 |
| 9.7 | 迁移与切流：五步与零业务基线 |
| 9.8 | 坑表 |
| 9.9 | 本章检查清单 |

---

## 9.1 四层与七层：分界与验证方式差异

| 维度 | 七层（003 册的 Nginx upstream） | **四层（本册 HAProxy）** |
|---|---|---|
| 引擎 | openresty / nginx / tengine | HAProxy |
| 配置块 | `http { server { location } }` | `frontend` / `backend`（**无域名概念**） |
| 识别依据 | 域名 + 路径 | **只有端口** |
| 验证方式 | `curl -H 'Host: …'` 看状态码 | `nc -zv` / stats 页 / 协议级探针（curl 不管用） |
| 端口占用 | 全站共享 80/443 | **每服务独占一个端口——主要难点** |
| TLS | `ssl_certificate` 终止 | 透传，不解密 |
| 变更 | reload 平滑 | `systemctl restart`（**连接会断**） |

两条推论：**其一**，四层验证 `curl` 没用——TCP 层没有 HTTP 语义，验证按"通断（`nc -zv`）→ 计数（stats 页）→ 协议级探针（如 MySQL 客户端握手看版本号）"分层做；**其二**，端口是稀缺资源——规划先于配置，先画端口矩阵再写 bind。

---

## 9.2 配置结构：frontend/backend 里没有域名

```haproxy
frontend db_mysql
        bind *:3306
        default_backend db_mysql_back
backend db_mysql_back
        server mysql1 10.0.1.50:3306
```

配置里从头到尾不出现域名——frontend 只认端口，backend 只认 `IP:端口`。**「域名：端口」能通 = 三件事齐**：

| # | 环节 | 谁负责 | 判据 |
|---|---|---|---|
| ① | DNS 解析 | DNS 服务商 / 内网 DNS | `dig +short <域名>` 返回目标机 IP |
| ② | 端口监听 | `bind` | 目标机 `ss -lntp \| grep haproxy` |
| ③ | 网络放行 | 防火墙 / 白名单 | 客户端 `nc -zv <域名> <端口>` |

「域名：端口不通」九成卡在 ①（域名没建、或还指着老机）。另记住：**一个端口只能对应一个后端组**，四层不能同端口按域名分流（TLS 场景借 SNI 例外）；多服务共用一台 HAProxy 只能"同域名不同端口"。

---

## 9.3 生产 unit 纪律：为什么只能 restart

验证过的标准写法（只改配置路径）：

```ini
[Unit]
Description=HAProxy Load Balancer
After=syslog.target network.target

[Service]
User=root
Type=forking
ExecStart=/opt/haproxy/sbin/haproxy -f /opt/config/haproxy/haproxy.cfg
PIDFile=/var/run/haproxy.pid
Restart=always
LimitNOFILE=100000

[Install]
WantedBy=multi-user.target
```

四条纪律，条条有事故背书：

1. **ExecStart 不带 `-db`**（前台模式不写 pidfile，`Type=forking` 找不到 PID 起不来）、**不带 `-p`**（与 cfg 内 `pidfile` 指令重复会报 ALERT）、**不写 `ExecReload`**——于是 `systemctl reload haproxy` 报 `Job type reload is not applicable` 属预期：**改配置一律 `systemctl restart`，断连接，挑低峰**。
2. **配置路径"三处一致"**：unit 的 `ExecStart -f`、变更前检查脚本、重启脚本，三处必须指向同一个 cfg 路径——改任何一处都要同步另两处，否则检查/重启报 `Cannot open configuration file`。
3. **仓库即真相**：cfg 入 git 仓纳管，服务器是**只读拉取端**（remote 常为只读凭据，push 返回 403）——改配置 = 本地改仓 → push → 服务器拉取。若拉取脚本含 `git reset --hard`，**严禁在服务器上直接 vi 配置**（未提交的修改会被冲掉）。
4. **脚本对应关系**：四层用自己的 check/restart 脚本；七层那套 reload 脚本对 haproxy **不生效**——别拿错。

---

## 9.4 stats 监控口：人看与机器看双通道

单独起一个 stats frontend（端口选不冲突的，如 8404）：

```haproxy
frontend stats
        bind *:8404
        stats enable
        stats uri /stats
        stats auth admin:'S3cret!'
        stats admin if TRUE
```

三个用途一个口：**人看**——`/stats` 页（带口令）看 frontend/backend 会话与健康状态；**脚本读**——`/stats;csv` 输出全量计数器（`scur` 当前并发、`stot` 累计会话），排障判读的数据源；**机器抓**——`/metrics` 是 HAProxy **内置的 Prometheus exporter，免认证**，Prometheus 抓这里（Prometheus 侧 target 配置见「监控」prometheus 007）。

两个实战要点：**自证 target 真在抓**——每被 scrape 一次，stats frontend 的 `stot` 就 +1，看它是否按采集间隔节奏增长即可（不增长 = 根本没抓）；**迁移时监控口必须随迁**——它随 haproxy 进程消失，且建议给新机**新增** target 而非把老机 target 改指，老机曲线保留到停机、新机曲线从当天起积累，切换前后无断层。

---

## 9.5 健康检查：tcp-check 的角色坑

tcp-check 是四层健康检查的主力，坑在**期望字段与集群角色的语义错位**。以 MongoDB 副本集为例：

```haproxy
backend mongo
        option tcp-check
        tcp-check connect
        tcp-check send "…ismaster 探测…"   # 期望 ismaster=True
```

`ismaster=True` 只有**副本集 PRIMARY** 会应答——于是 SECONDARY 全部被判定 DOWN；如果配置又把从节点标成 `backup`（与真实角色相反），实际效果是"常规全 DOWN ⇒ 启用 backup 落到 PRIMARY"，**功能可用但口径全错**：监控面只有一台 UP、切换语义与预期不符。教训：**探针期望字段必须与集群角色语义核对**，配置注释里的角色标注与真实角色对齐；Redis 代理类（Predixy 等）同理——**业务端口常不是默认端口**（缓存代理转发口常见 6380/25900 这类），通知开发与配置监控时端口别按默认写。

---

## 9.6 端口冲突矩阵：bind 失败 = 整机不起

HAProxy 启动时**任一 bind 失败即整体退出**（不是那一条降级）——合并多台老机配置到一台新机前，端口必须算准：

```bash
# 目标机已占端口（冲突基线）
ss -lntp | awk 'NR>1{print $4}' | sed 's/.*://' | sort -n | uniq
# 本批要绑的端口（各老机配置汇总）
grep -hE '^[[:space:]]*bind' /opt/config/haproxy/*/haproxy.cfg | sed 's/.*://' | sort -n | uniq
```

高发雷区：**node_exporter 占 `[::]:9100`**——IPv6 通配在双栈下同时接管 IPv4，HAProxy 再 bind 9100 必失败；业务用非默认端口（上节的代理口）与"想暴露本机 exporter"的 frontend 都容易撞。

冲突处理四档，从优到劣：

| 优先 | 方式 | 说明 |
|---|---|---|
| ① | **主备对合一** | 两台老机配置相同（同端口同后端）→ 只迁一份；先 `md5sum` 比对，别假设 |
| ② | **删非必要端口** | 目标机已有同功能组件（如自带 node_exporter）→ 直接删该 frontend |
| ③ | **改端口** | 真有业务需要 → 换不冲突端口，**通知里写清新端口** |
| ④ | **别名 IP** | 以上都不可行才用：`bind <别名IP>:<原端口>`，需网络侧配合 |

**优先保持原端口**——改端口 = 让所有客户端改配置，成本最高。

---

## 9.7 迁移与切流：五步与零业务基线

老机四层服务迁到新机的标准五步：

1. **拷二进制**：先 `haproxy -v` 记录版本，新机**版本必须一致**；跨 OS 注意 GLIBC 兼容（「Linux」A 册）。
2. **拷配置 + 端口冲突矩阵**：每个来源老机一个子目录落位，先跑 9.6 的矩阵再合并。
3. **建 unit**：9.3 标准写法，三处一致。
4. **并行验证——零业务基线判定**：新老两机 `/stats;csv` 逐行对照（配置等价）+ 协议探针实测（如 MySQL 握手返回版本一致）；然后看业务有没有在走：**新机 `scur` 为 0 且 60 秒增量为 0、老机同时满载** → 入口层就绪但业务 100% 还在老机——这不是故障，是切流还没开始；给开发的迁移通知按老机日志里的客户端来源 IP 定位改动方。
5. **切流与收尾**：四层切流改的是"**哪个 IP 监听该端口**"——客户端按 `IP:端口` 直连的，**改 DNS 无效**，只能改客户端指向或换新域名；按域名访问的逐条切 A（老域名反查齐，多 DNS 视图逐视图核，002-003 的纪律）；监控 target 随迁（9.4）；观察期后停老机 haproxy——**只停服务、配置不动**，回滚 = 再启动。

---

## 9.8 坑表

| # | 坑 | 后果 | 正确做法 |
|---|---|---|---|
| 1 | 拿 curl 验证四层转发 | TCP 层无 HTTP 语义，结论误导 | `nc -zv` / stats / 协议探针分层验证（9.1） |
| 2 | `systemctl reload haproxy` | 报 not applicable，配置没生效还以为生效了 | 无 ExecReload，只能 restart，挑低峰（9.3） |
| 3 | ExecStart 带 `-db` 或 `-p` | 前台不写 pidfile / 与 cfg 重复报 ALERT，unit 起不来 | 按 9.3 标准写法（9.3） |
| 4 | 改了 unit 忘同步检查/重启脚本 | `Cannot open configuration file` | 配置路径三处一致（9.3） |
| 5 | 合并多台老机前不算端口 | 任一 bind 失败 = 整个 haproxy 起不来 | 端口冲突矩阵先行（9.6） |
| 6 | 业务 frontend 撞 node_exporter 的 9100 | bind 失败整机不起 | 冲突四档：删或改端口（9.6） |
| 7 | tcp-check 期望与集群角色不符 | 只有 PRIMARY UP、角色标反、口径错乱 | 探针字段与角色语义核对（9.5） |
| 8 | 切流只改 DNS | IP:PORT 直连的客户端纹丝不动 | 改"哪个 IP 监听端口"或客户端指向（9.7） |

---

## 9.9 本章检查清单

读完能回答这六个问题，这一章就过了：

| # | 问题 |
|---|---|
| 1 | 四层七层分界表里，验证方式与端口占用各差在哪？curl 为什么不管用？ |
| 2 | 「域名：端口不通」的三件套排查顺序？为什么九成卡 DNS？ |
| 3 | unit 为什么只能 restart？三个写法禁忌（`-db`/`-p`/ExecReload）各错在哪？ |
| 4 | stats 口的三个用途？怎么自证 Prometheus target 真在抓？ |
| 5 | 端口冲突四档处理的优先级？为什么优先保持原端口？ |
| 6 | 「零业务基线」怎么判定？四层切流改的到底是什么？ |

---

> 下一篇：回到 [README](README.md) 总览——「接入层」十册完成，横向衔接「CICD」007（灰度）与「容器」006（Ingress）。
