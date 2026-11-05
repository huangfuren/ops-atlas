# 007 Exporter 生态

> **解决**：该监控什么、怎么采——从主机到中间件到自定义业务指标。  
> **范围**：node_exporter 深入 · blackbox_exporter · 中间件 exporter · 自定义 exporter · 服务发现。  
> **口径**：Exporter 是 Prometheus 拉模型的"数据源适配器"——选对、配对、别重复。  
> **更新**：2026-11-01

## 目录

| 节 | 内容 |
|---|---|
| 7.1 | Exporter 的模型：暴露 /metrics 让 Prometheus 拉 |
| 7.2 | node_exporter 深入：关键指标与 collector 开关 |
| 7.3 | blackbox_exporter：黑盒探测 |
| 7.4 | 中间件 exporter：mysqld / redis / kafka |
| 7.5 | 自定义 exporter：Go / Python 写一个 |
| 7.6 | 服务发现：让 Prometheus 自动找到新目标 |
| 7.7 | 六个坑 |
| 7.8 | 本章检查清单 |

---

## 7.1 Exporter 的模型：暴露 /metrics 让 Prometheus 拉

Exporter 的唯一职责：**把系统/服务的内部状态翻译成 Prometheus 的文本格式**，暴露在 HTTP `/metrics` 端点上。

```plain
Prometheus ──HTTP GET /metrics──▶ Exporter ──▶ 系统内部状态
              ◀── 文本响应 ──────────┘
```

响应格式（纯文本）：

```plain
# HELP node_cpu_seconds_total Seconds the CPUs spent in each mode
# TYPE node_cpu_seconds_total counter
node_cpu_seconds_total{cpu="0",mode="idle"} 12345.67
node_cpu_seconds_total{cpu="0",mode="user"} 234.56
```

`# HELP` 和 `# TYPE` 是元数据行；数据行是 `指标名{标签=值} 数值`。**Prometheus 只拉不推**——Exporter 挂了 Prometheus 侧显示 target DOWN，不会自动换源。

---

## 7.2 node_exporter 深入：关键指标与 collector 开关

node_exporter 是主机监控的基础，默认启用约 40 个 collector：

```bash
# 安装（systemd 服务）
curl -LO https://github.com/prometheus/node_exporter/releases/download/v1.8.1/node_exporter-1.8.1.linux-amd64.tar.gz
tar xzf node_exporter-1.8.1.linux-amd64.tar.gz
mv node_exporter-1.8.1.linux-amd64/node_exporter /usr/local/bin/

# systemd 服务
cat > /etc/systemd/system/node_exporter.service << 'EOF'
[Unit]
Description=node_exporter
After=network.target

[Service]
ExecStart=/usr/local/bin/node_exporter \
  --collector.systemd \
  --collector.processes \
  --web.listen-address=:9100
Restart=always

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload && systemctl enable --now node_exporter
```

运维必看的 **20 个关键指标**（按「Linux」009 五维模型的映射）：

| 维度 | 指标 | 含义 |
|---|---|---|
| CPU | `node_cpu_seconds_total{mode="idle"}` | 空闲时间——用 `100 - rate(*idle)*100` 算使用率 |
| 内存 | `node_memory_MemAvailable_bytes` | 可用内存——直接看这个（不是 free） |
| 磁盘空间 | `node_filesystem_avail_bytes` | 可用空间——按 mountpoint 分 |
| 磁盘 IO | `node_disk_io_time_seconds_total` | IO 忙碌时间——`rate` 即利用率 |
| 网络 | `node_network_receive_bytes_total` | 收发字节数 |
| 负载 | `node_load1/5/15` | 与「Linux」009 的 load 口径一致 |
| 进程 | `node_procs_running` / `node_procs_blocked` | R 与 D 状态进程数 |

`--collector.systemd` 和 `--collector.processes` 是常用但默认关闭的 collector——按需启用。**禁用不用的**（如 `--no-collector.nfs`）减少指标量。

---

## 7.3 blackbox_exporter：黑盒探测

blackbox_exporter 从外部探测服务的可达性——**不依赖被监控方安装任何东西**：

```yaml
# Prometheus 抓取配置
scrape_configs:
  - job_name: blackbox-http
    metrics_path: /probe
    params:
      module: [http_2xx]              # 探测模块
    static_configs:
      - targets:
          - https://app.example.com/health
          - https://api.example.com/v1/status
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target   # 把目标传给探测参数
      - source_labels: [__param_target]
        target_label: instance         # 保留原地址作为标签
      - target_label: __address__
        replacement: blackbox.internal:9115   # blackbox 地址
```

三类探测模块：`http_2xx`（HTTP 状态码 200）、`tcp_connect`（端口通）、`icmp`（ping）。**探测失败时 `probe_success=0`**——告警表达式 `probe_success == 0`。

---

## 7.4 中间件 exporter：mysqld / redis / kafka

中间件的 exporter 需要凭据来连接目标系统——**凭据走环境变量或 Docker secrets**：

| 中间件 | Exporter | 端口 | 关键指标 |
|---|---|---|---|
| MySQL | mysqld_exporter | 9104 | `mysql_up`、`mysql_global_status_threads_connected`、慢查询数 |
| Redis | redis_exporter | 9121 | `redis_up`、`redis_memory_used_bytes`、`redis_keyspace_hits/misses` |
| Kafka | kafka_exporter | 9308 | `kafka_consumergroup_lag`（堆积）、`kafka_broker Brokers` |

运维验收点：**exporter 的 `*_up` 指标必须进告警**——它为 0 说明 exporter 或目标服务挂了。**lag 告警**对接「消息队列」002 §2.6 的最小集。

---

## 7.5 自定义 exporter：Go / Python 写一个

当没有现成 exporter 时，用 `prometheus/client_golang` 写一个：

```go
package main

import (
	"net/http"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

var queueDepth = promauto.NewGaugeVec(
	prometheus.GaugeOpts{
		Name: "myapp_queue_depth",
		Help: "当前队列深度",
	},
	[]string{"queue"},
)

func main() {
	go func() {
		for {
			depth := getQueueDepth()          // 你的业务逻辑
			queueDepth.WithLabelValues("order").Set(float64(depth))
			time.Sleep(15 * time.Second)
		}
	}()
	http.Handle("/metrics", promhttp.Handler())
	http.ListenAndServe(":9105", nil)
}
```

Python 版用 `prometheus_client` 包（`start_http_server(9105)`）。

**自定义指标命名规范**：`<namespace>_<子系统>_<名称>_<单位>`——如 `myapp_queue_depth_bytes`。**只用 counter/gauge/histogram/summary 四种类型**——类型选错（该用 counter 的用了 gauge）会导致 rate() 无法计算。

---

## 7.6 服务发现：让 Prometheus 自动找到新目标

手动维护 `static_configs` 在机器多时不可持续——服务发现自动同步目标列表：

```yaml
scrape_configs:
  - job_name: node
    file_sd_configs:                   # 文件服务发现：JSON/YAML 目标列表
      files: ["/etc/prometheus/targets/*.json"]
      refresh_interval: 30s

  - job_name: kubernetes-pods
    kubernetes_sd_configs: [{ role: pod }]
    relabel_configs:
      # 只抓带 prometheus.io/scrape=true 注解的 Pod
      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
        action: keep
        regex: "true"
      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_path]
        target_label: __metrics_path__
```

K8s 场景的纪律：**Pod 加注解自动被发现**——运维不需要手动加 target；file_sd 适合非 K8s 环境的半自动管理（目标列表文件由 Ansible/CI 生成）。

---

## 7.7 六个坑

| # | 坑 | 后果 | 正确做法 |
|---|---|---|---|
| 1 | 重复采集同一目标 | 数据翻倍，rate 翻倍 | 确认每个 target 只被一个 job 抓 |
| 2 | exporter 版本不匹配 | 指标名变化导致面板空 | 版本锁定 + 升级前核对指标名 |
| 3 | node_exporter 全开 collector | 指标量暴涨（nfs/rapl 等） | 只开需要的 |
| 4 | blackbox 探测频率过高 | 被探测方限流/DDoS | 探测间隔 ≥ 30s |
| 5 | 自定义指标无 HELP/TYPE | Grafana 无法识别类型 | 导出时必须包含 |
| 6 | 服务发现标签没 relabel | 标签名太长或无意义 | relabel 精简为有用的维度 |

第 1 条展开：**两个 Prometheus 同时抓同一个 target**（如 HA 双实例）是正常的高可用做法，但如果查询时没做 `sum` 去重，rate() 会翻倍。解法是 Grafana 里用 `sum by (instance)` 聚合，或用 Thanos Query 的去重功能（008 展开）。

---

## 7.8 本章检查清单

读完能回答这六个问题，这一章就过了：

| # | 问题 |
|---|---|
| 1 | Exporter 的唯一职责？拉模型的含义？ |
| 2 | node_exporter 的 20 个关键指标按五维模型怎么分组？ |
| 3 | blackbox_exporter 的探测模块与告警表达式？ |
| 4 | 中间件 exporter 的凭据怎么管？哪些 `*_up` 必须进告警？ |
| 5 | 自定义指标命名规范的格式？四种类型怎么选？ |
| 6 | K8s 场景的服务发现怎么配？Pod 注解的作用？ |

---

**下一篇**：[008-规模化与高可用](008-规模化与高可用.md) —— 当一台 Prometheus 不够用时。
