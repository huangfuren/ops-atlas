# 001 VMware vSphere 运维

> **解决**：ESXi/vCenter 体系怎么管——虚拟机生命周期、快照纪律、资源与高可用。  
> **范围**：架构 · 虚拟机生命周期 · 快照 · 资源管理（DRS/HA）· 存储与网络 · 命令行工具。  
> **口径**：vSphere 8.x / vCenter 8.x；命令以 esxcli/PowerCLI/govc 为准。

## 目录

| 节 | 内容 |
|---|---|
| 1 | 架构：ESXi 与 vCenter |
| 2 | 虚拟机生命周期与快照纪律 |
| 3 | 模板与克隆 |
| 4 | 资源管理：DRS/HA/资源池 |
| 5 | 存储与网络 |
| 6 | 命令行工具 |
| 7 | 坑表 |
| 8 | 检查清单 |

---

## 1. 架构：ESXi 与 vCenter

| 组件 | 角色 |
|---|---|
| **ESXi** | 裸金属 hypervisor——单台宿主机，VM 直接跑在上面 |
| **vCenter** | 集中管理平台——管多台 ESXi：集群、DRS/HA、模板、迁移都依赖它 |
| 集群（Cluster） | 一组 ESXi 的资源池，DRS/HA 生效范围 |
| 数据中心/Datastore | 管理层级与存储容器（VMFS/NFS/vSAN） |

**vCenter 挂了 VM 照跑**（它只是管理层）——但迁移/HA/模板全失效。vCenter 自身要高可用（vCenter HA 或备份恢复方案）。

## 2. 虚拟机生命周期与快照纪律

创建 → 配置 → 运行 → 快照/变更 → 归档，每步的纪律：

| 动作 | 纪律 |
|---|---|
| 创建 | 从模板克隆（别从裸镜像逐台装）；CPU/内存按需分配并留超分余量 |
| 变更前 | **先打快照**（变更保险）——改完验证成功再删快照 |
| 快照 | ⚠️ **快照不是备份**：链式差分、依赖母盘、链过长性能劣化——快照保留 ≤72h，用完即删 |
| 删除快照 | "删除"是**合并**进母盘——需要等量临时空间，大快照合并期间 IO 高 |
| 磁盘置备 | Thick（一次占满，性能稳）vs Thin（按需增长，省空间但可能超卖存储）——生产库类 VM 用 Thick Eager Zeroed |
| 归档 | OVA/OVF 导出或镜像级备份（Veeam 等） |

**备份的正解**：镜像级备份工具（Veeam/Networker）按"变更块+保留策略"独立存副本——快照只是变更前的临时保险。

## 3. 模板与克隆

| 方式 | 机制 | 场景 |
|---|---|---|
| **全量克隆（Full Clone）** | 独立完整副本 | 长期运行的 VM |
| **链接克隆（Linked Clone）** | 依赖母盘的差分盘——省空间 | 桌面池/短命实验机——**母盘升级影响所有链接克隆** |
| **模板（Template）** | 只读母版，可转 VM 再转回 | 标准化交付：模板 + 客制化规范（主机名/IP 注入） |

模板更新流程：模板转 VM → 打补丁升级 → 清理 → 转回模板 → 新克隆全部受益——**每次变更只做一遍**。

## 4. 资源管理：DRS/HA/资源池

| 机制 | 做什么 | 运维要点 |
|---|---|---|
| **DRS** | 按负载自动在主机间迁移 VM（vMotion）——负载均衡 | 自动化等级按需（全自动/手动确认）；亲和/反亲和规则控制"谁和谁不在一起"（如双节点应用分主机） |
| **HA** | 主机故障 → VM 在其他主机**重启** | 准入控制（Admission Control）预留容量——预留不足时 HA 拒绝保障，**告警别关闭** |
| **资源池** | 集群内划分 CPU/内存配额 | 限制与共享——多团队共集群时防互相挤占 |
| **vMotion** | 在线迁移（内存状态搬运） | 硬件维护不停机；跨 CPU 代际需 EVC（Enhanced vMotion Compatibility）统一指令集 |

## 5. 存储与网络

存储：Datastore 承载 VM 磁盘（VMFS 本地/共享、NFS、vSAN 分布式存储）；**生产 VM 的磁盘必须在共享存储上**——否则 vMotion/HA 无法工作。

网络：标准交换机（单机）vs **分布式交换机（vDS，vCenter 集中配置跨主机一致）**——生产用 vDS；端口组划分 VLAN；VMkernel 网卡承载管理/vMotion/存储三类流量并**分离**（迁移流量打满不能影响管理）。

## 6. 命令行工具

```bash
# esxcli（ESXi 本机或 SSH）
esxcli vm process list                    # 运行中 VM
esxcli storage vmfs extent list           # 存储挂载
esxcli hardware memory get                # 主机内存

# PowerCLI（vCenter，批量管理首选）
Get-VM | Where-Object {$_.PowerState -eq "PoweredOn"}
Get-VM -Name web01 | New-Snapshot -Name "变更前"
Get-Snapshot -VM (Get-VM web*) | Remove-Snapshot -Confirm:$false
Get-VMHost | Select Name, MemoryUsageGB, CpuUsageMhz

# govc（跨平台 CLI，适合脚本/CI）
govc ls / DC/vm
govc vm.info web01
govc snapshot.tree -vm web01
```

运维纪律：**变更走 vCenter 界面或 PowerCLI 留痕**，直接 SSH 改 ESXi 属于应急手段——vCenter 数据库里没有的变更，DRS/HA 管不到。

## 7. 坑表

| # | 坑 | 后果 | 正确做法 |
|---|---|---|---|
| 1 | 快照当备份长期保留 | 链式差分膨胀，存储爆 + 性能劣化 | 快照 ≤72h，备份用镜像级工具 |
| 2 | Thin 置备存储超卖 | 底层存储瞬间打满，全集群 VM 暂停 | 存储告警 + 定期核对实际用量 |
| 3 | VM 磁盘在本地盘上 | 无法 vMotion/HA，主机故障数据随盘 | 生产 VM 一律共享存储 |
| 4 | HA 准入控制被关闭 | 故障时资源不够重启 VM | 预留容量 + 告警 |
| 5 | 一台主机塞满高 IOPS VM | 存储争抢互相拖累 | DRS + 反亲和规则分散 |
| 6 | vCenter 单点无备份 | 管理层失效只能逐台 ESXi 操作 | vCenter 备份（文件级+DB） |

## 8. 检查清单

| # | 问题 |
|---|---|
| 1 | 快照与备份的差别说得清吗？现网有没有超 72 小时的快照？ |
| 2 | 生产 VM 的磁盘都在共享存储上吗？ |
| 3 | HA 准入控制开了吗？预留够一次主机故障吗？ |
| 4 | 磁盘置备方式逐台核对过吗？ |
| 5 | 变更流程是"快照→改→验证→删快照"吗？ |
| 6 | vCenter 有备份吗？ |

---

**下一篇**：[002 KVM 运维](002-KVM运维.md) —— 开源世界的对应解法。
