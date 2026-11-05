# 05 Grafana 与可视化

> **解决**：指标存进去了，怎么建仪表盘、让团队看懂、让异常一眼可见。  
> **范围**：Grafana 架构 · 数据源 · Dashboard 设计 · 变量与模板 · 告警界面 · 权限。  
> **口径**：Grafana 10+，数据源接 Prometheus。  
> **更新**：2026-11-01

## 目录

| 节 | 内容 |
|---|---|
| 5.1 | Grafana 定位与数据源配置 |
| 5.2 | Dashboard 设计原则：SLO 对齐 |
| 5.3 | 变量与模板：一份仪表盘服务多场景 |
| 5.4 | Panel 类型选型：什么数据用什么图 |
| 5.5 | 告警界面：Unified Alerting |
| 5.6 | 权限与多团队隔离 |
| 5.7 | 六个坑 |
| 5.8 | 本章检查清单 |

---

## 5.1 Grafana 定位与数据源配置

Grafana 是**可视化与告警界面**——自己不存指标（saved dashboard 除外），查询实时打到 Prometheus。运维 80% 的时间在这里：看趋势、确认影响面、定位异常时段。

```plain
Connection → Data sources → Add data source → Prometheus
  URL: http://prometheus.internal:9090
  ✓ Default 开关（让 Explore 默认走它）
```

数据源建好后 Explore 页面能查到数据即通——与「日志」册的 Loki 数据源、「链路」册的 Tempo 数据源可以在同一个 Grafana 实例中共存，实现三支柱同屏跳转。

---

## 5.2 Dashboard 设计原则：SLO 对齐

仪表盘不是图表堆积——**每个 Dashboard 回答一个具体问题**：

| Dashboard | 回答 | 必含面板 |
|---|---|---|
| 服务健康 | "这个服务现在正常吗" | RED 三面板（请求率/错误率/P99）+ 依赖状态 |
| 容量 | "资源还能撑多久" | 磁盘/内存/连接数 + 趋势线 |
| 发布观测 | "刚才那次发布有没有搞坏" | 错误率（按版本分桶）+ 延迟对比 + 发布标记线 |
| 基础设施 | "机器还撑得住吗" | CPU/内存/磁盘/网络 + 节点存活 |

设计纪律三条：

1. **顶部放最关键的**——打开 Dashboard 3 秒内判断"是否异常"；
2. **每个面板有标题写明"看什么"**——"CPU 使用率"不如"CPU 使用率（超 80% 告警）"；
3. **红黄绿底色**——`thresholds` 设色阶，一眼看到健康/警告/危险。

---

## 5.3 变量与模板：一份仪表盘服务多场景

变量（Variables）让一份 Dashboard 通过下拉切换服务/环境：

```plain
Dashboard Settings → Variables → New
  Name:     service
  Type:     Query
  Query:    label_values(http_requests_total, service)
  Multi:    ✓（允许多选）
  Include All: ✓（全选选项）
```

面板查询里引用：`rate(http_requests_total{service=~"$service"}[5m])`——**选哪个服务，图就切哪个**。

一个 Dashboard 常用的变量组合：

| 变量 | 查询来源 | 用途 |
|---|---|---|
| `$env` | `label_values(env)` | 切换 prod/staging |
| `$service` | `label_values(service)` | 切换服务 |
| `$instance` | `label_values(instance{service=~"$service"})` | 级联：选了服务再选实例 |

---

## 5.4 Panel 类型选型：什么数据用什么图

| 数据形态 | Panel 类型 | 典型场景 |
|---|---|---|
| 时间序列（多系列） | **Time series** | 请求率、延迟趋势、连接数 |
| 单值 + 阈值 | **Stat / Gauge** | 当前错误率、磁盘使用率 |
| 多维排名 | **Bar chart / Table** | TOP 10 慢接口、TOP IP |
| 占比 | **Pie chart** | 状态码分布 |
| 热力图 | **Heatmap** | 延迟分布随时间变化（P50/P99 分桶） |
| 日志流 | **Logs**（接 Loki） | 告警时段的日志上下文 |

选型口诀：**趋势用线图、当前值用 Stat、排名用条形、分布用热力图**——一张 Dashboard 混用不超过 4 种类型，否则视觉噪音。

---

## 5.5 告警界面：Unified Alerting

Grafana 10 的 Unified Alerting 把告警规则、通知策略、静默规则统一管理：

- **Alert rules**：可直接在 Grafana 里写 PromQL 并设阈值——适合轻量场景（不用 Prometheus 的 rule_files）；
- **Notification policies**：按标签路由到不同 IM（钉钉/企微/Slack）——与「SRE」002 的分级响应对齐；
- **Silences**：计划内维护的静音——与「SRE」002 的 runbook 配合。

但**生产级告警仍推荐 Prometheus rule_files + Alertmanager**（004 §4.4）——规则进 Git 可评审，Alertmanager 的路由/抑制/静默能力更强。Grafana 告警适合"快速起步"或"非 Prometheus 数据源"。

---

## 5.6 权限与多团队隔离

| 机制 | 用途 |
|---|---|
| **Organization** | 完全隔离：多套 Grafana 数据（适合多租户 SaaS） |
| **Folder** | Dashboard 分组与权限边界：团队只能看自己的 Folder |
| **Team + Role** | Viewer（只看）/ Editor（可改）/ Admin（可管理） |
| **Data source 权限** | 限制某些团队只能查某些索引/指标 |

最小权限纪律：**研发默认 Viewer，只能看自己服务的 Dashboard**——生产全量日志与指标对所有团队可见是数据泄漏隐患（与「日志」003 §3.7 的 RBAC 同源）。

---

## 5.7 六个坑

| # | 坑 | 后果 | 正确做法 |
|---|---|---|---|
| 1 | 时间范围默认 6h/12h | 打开就看到"平线"以为没事 | 关键面板设 `Now-15m` 或变量化 |
| 2 | 所有面板同一刷新率 | 高频面板拖慢 Grafana | 核心面板 30s，次要 5m |
| 3 | 变量没有 Include All | 多服务要逐个选 | 变量勾 Include All + custom all value `.*` |
| 4 | 阈值写死在 SQL 里 | 换环境要改面板 | 用变量引用（`$threshold`） |
| 5 | 告警在 Grafana 和 Prometheus 各配一份 | 告警风暴（同一问题两条通知） | 统一走一处（建议 Prometheus rule_files） |
| 6 | Dashboard 无 Owner | 人走了没人维护 | Folder + Team 管理归属 |

第 1 条展开：**时间范围是最常见的"假正常"来源**——把时间窗从 `Last 6 hours` 改为 `Last 15 minutes` 后，原本"平线"的图突然出现一个尖峰——不是监控坏了，是 6 小时内这个尖峰只占 0.3% 的像素宽度，肉眼看不到。**排障时永远先缩窗再加过滤**（与「日志」003 §3.2 的纪律同源）。

---

## 5.8 本章检查清单

读完能回答这六个问题，这一章就过了：

| # | 问题 |
|---|---|
| 1 | Dashboard 的设计纪律三条？ |
| 2 | 变量的级联怎么实现（先选服务再选实例）？ |
| 3 | 时间序列、Stat、热力图各适合什么数据？ |
| 5 | Grafana 告警 vs Prometheus rule_files 的取舍？ |
| 5 | 权限的最小配置（研发默认什么角色）？ |
| 6 | "假正常"的时间范围陷阱怎么破？ |

---

**下一篇**：[006-告警规则实战](006-告警规则实战.md) —— SRE 001 的 burn rate 怎么用 PromQL 写出来。
