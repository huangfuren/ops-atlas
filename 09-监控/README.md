# 监控手册

> **定位**：可观测性第一支柱——指标监控的体系文档。Prometheus 是主线工具，本板块覆盖从指标设计到告警响应的完整闭环。  
> **读者**：需要为自己的服务建立监控、响应告警的运维/SRE 人员。  
> **口径**：**Prometheus 2.x / 3.x**，Alertmanager 0.27+，Grafana 10+；指标模型遵循 OTel 语义约定（与「链路」册互通）。  
> **更新**：2026-11-01

## 体系结构

监控板块分两层：**本 README 是监控领域的全局视角**，`prometheus/` 子目录是 Prometheus 工具的深入。

```
09-监控/
├── README.md                ← 你在这里：监控全景与选型
└── prometheus/              ← Prometheus 工具深入
    ├── README.md
    ├── 00-术语表.md
    ├── 001~004                ← 原理 / 查询 / 部署 / 存储告警
    ├── 005~008                ← 可视化 / 告警实战 / Exporter / 规模化
    └── 配图/
```

## 监控的四层

| 层 | 做什么 | 工具 | 册 |
|---|---|---|---|
| **采集** | 从目标拉取或接收指标 | Prometheus（pull）· Exporter · Pushgateway | 001/003/007 |
| **存储** | 时序数据的存与查 | TSDB · Thanos/Mimir（长期） | 002/004/008 |
| **可视化** | 看到数据、发现异常 | Grafana 仪表盘 · 告警规则 | 005/006 |
| **响应** | 告警到人、到行动 | Alertmanager · IM webhook · runbook | 004/006 + 「SRE」002 |

## 三支柱中的位置

监控（指标）是可观测性的**第一支柱**——负责"发现问题"：

```plain
指标（本板块）──告警──▶ 人/自动化
                          │
                          ▼
日志（「日志」册）── 解释为什么出事
链路（「链路」册）── 定位哪一跳慢/错
```

指标是唯一适合做**告警源**的支柱（实时、低成本、可聚合）——日志与链路是取证工具，不是告警源。

## 与其它板块的衔接

- **「SRE」001**：SLO 的 SLI 数据源全部来自指标——burn rate 告警的 PromQL 实现在监控 006；
- **「日志」册**：告警响了来日志取证——日志 006 §6.1 的四段取证以监控告警为起点；
- **「容器」册**：容器指标（cgroup/容器运行时）通过 cAdvisor + kube-state-metrics 暴露；
- **「接入层」005**：接入层的 log_format 设计与指标互补（日志管上下文，指标管趋势）。

## Exporter 生态速览

| 监控目标 | Exporter | 说明 |
|---|---|---|
| Linux 主机 | node_exporter | CPU/内存/磁盘/网络——最基础 |
| HTTP/TCP/ICMP 可达性 | blackbox_exporter | 黑盒探测 |
| MySQL | mysqld_exporter | 「数据库」007 的指标来源 |
| Redis | redis_exporter | |
| Kafka | kafka_exporter | 「消息队列」002 的 lag |
| K8s | kube-state-metrics + cAdvisor | 「容器」009 |
| 自定义业务指标 | prometheus/client_golang（Go）/ client_python | 「Go」004 /「Python」003 |

---

**Prometheus 深入**：[prometheus/README.md](prometheus/README.md) — 从原理到告警排错的完整路线。
