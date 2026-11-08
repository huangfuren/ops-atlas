# 005 Docker 网络与隔离底层

> **解决**：容器网络"为什么通、为什么不通"的底层答案——五种网络模型、端口转发的 iptables 链路、namespace 与 cgroup 的手工实验。  
> **范围**：五种网络模型 · 端口转发底层 · 自定义网络与 DNS · macvlan 与 overlay · namespace 六类 · cgroup 资源限制。  
> **口径**：Docker CE 24+ / Linux 内核 5.x；实验在单机可复现，`ip -d link`、`iptables -vnL` 输出以实际内核为准。  
> **更新**：2026-11-08

## 目录

| 节 | 内容 |
|---|---|
| 5.1 | 五种网络模型：none / bridge / host / container / custom |
| 5.2 | 端口转发的底层：iptables DNAT 与 MASQUERADE 链路 |
| 5.3 | 自定义网络与内置 DNS：为什么服务名能互访 |
| 5.4 | 跨主机网络：macvlan 与 overlay 两条路 |
| 5.5 | namespace 六类：手工实验看隔离 |
| 5.6 | cgroup 与资源限制：quota 手工写法与热更新 |
| 5.7 | 六个坑 |
| 5.8 | 本章检查清单 |

---

## 5.1 五种网络模型

`docker network ls` 里的网络不止 bridge 一种，五种模型的取舍：

| 模型 | 网络栈 | 典型用途 | 关键特性 |
|---|---|---|---|
| `none` | 只有 lo | 安全隔离、自行配网 | 无外网能力 |
| `bridge`（默认） | docker0 网桥 + veth pair | 单机常规容器 | NAT 出网、端口映射可用 |
| `host` | 直接用宿主栈 | 性能敏感（省两次报文封装） | 无隔离，端口直接占用宿主 |
| `container:<名>` | 共享另一容器的 netns | sidecar 模式（日志/代理伴跑） | 两容器 localhost 互通 |
| `custom`（自建 bridge） | 同 bridge + **内置 DNS** | 多容器按名互访 | `--network` 指定后可用容器名当主机名 |

两个容易忽略的点：**默认 bridge 没有内置 DNS**——容器间按名互访要自定义网络；`host` 模式省掉 NAT 与 veth 的开销，但端口冲突和隔离代价自己扛。

---

## 5.2 端口转发的底层：iptables DNAT 与 MASQUERADE 链路

`-p 81:80` 在底层不是"端口映射"这么一句话，而是 iptables 里真实存在的规则链。验证：

```bash
iptables -t nat -vnL DOCKER
```

```plain
DNAT tcp -- 0.0.0.0/0  0.0.0.0/0  tcp dpt:81 to:172.17.0.2:80
```

三条链各司其职：**PREROUTING 的 DOCKER 链做 DNAT**（宿主 81 进来的包改写目的地址为容器 IP:80）、**FORWARD 链放行转发**、**POSTROUTING 的 MASQUERADE 做伪装**（容器出网时把源 IP 换成宿主 IP）。排障时按这个顺序逐条核对。

配套的两个底层事实：

1. **容器与宿主之间靠 veth pair 连接**：容器里是 `eth0@if17`，宿主上是 `veth86a4799@if16`，成对出现。`brctl show docker0`（需 bridge-utils）能看到 veth 挂在 docker0 网桥上；
2. **`net.ipv4.ip_forward=0` 时容器无法访问外网**，但同节点容器互通不受影响——"容器之间通、出网不通"先查这个内核参数：

```bash
sysctl net.ipv4.ip_forward      # 0 = 未开启
sysctl -w net.ipv4.ip_forward=1
```

---

## 5.3 自定义网络与内置 DNS：为什么服务名能互访

默认 bridge 里的容器只能靠 IP 互访；**自定义网络里 Docker 内置了 DNS**，容器名直接当主机名：

```bash
docker network create -d bridge --subnet 172.21.0.0/16 \
  --gateway 172.21.0.254 --ip-range 172.21.100.0/24 mynet

docker run -d --name web --network mynet nginx
docker run -d --name db  --network mynet mysql
docker exec web ping db        # 直接解析到 db 的容器 IP
```

三个进阶能力：**子网/网关/地址段都可自定义**（`--ip-range` 划出分配池）；**`--ip` 手动指定地址**（写死 IP 的场景）；**一个容器接入多个网络**（`docker network connect bridge c2` 给运行中的容器追加一块网卡）——跨网段互通就靠这一招补救。

---

## 5.4 跨主机网络：macvlan 与 overlay 两条路

单机网络到多机，两条代表性路线：

**macvlan——容器直接接入物理网络（二层）。** 内核模块 + 绑定物理网卡：

```bash
modprobe macvlan
docker network create -d macvlan --subnet 172.29.0.0/16 \
  --gateway 172.29.0.254 -o parent=ens33 mymacvlan
```

容器拿物理网段的独立 IP，跨主机二层互通。三个已知缺陷要背：**容器与宿主机不通**（macvlan 的设计限制）、**默认无法出外网**（需双网卡补救：`docker network connect bridge 容器` 追加一块出网网卡）、**IP 要自己规划**防冲突。

**overlay——跨主机隧道（三层）。** 经典实验方案用 consul 做集群存储，任一节点建网全网自动同步：

```bash
# daemon.json：{"cluster-store":"consul://10.0.0.101:8500","cluster-advertise":"10.0.0.101:6666"}
docker network create -d overlay --subnet 172.30.0.0/16 myoverlay
```

overlay 网卡的 **MTU 是 1450**（比物理网卡小 50）——那是 VXLAN 封装头的开销，跨主机流量经 `docker_gwbridge` 封装出网。`tcpdump` 能直接抓到 VXLAN 报文验证。现代生产里 overlay 已内置进 swarm/K8s（CNI），但**理解 VXLAN 封装原理**对排障 K8s 网络问题仍然成立。

---

## 5.5 namespace 六类：手工实验看隔离

容器的隔离是六类 namespace 各管一面：**IPC（信号量）、MNT（挂载点）、NET（网络栈）、PID（进程号）、User（用户映射）、UTS（主机名）**。不用 Docker 也能手工做一遍实验：

```bash
# 创建一个网络命名空间，手工接 veth
ip netns add oldboyedu-linux
ip link add veth100 type veth peer name veth200
ip link set veth200 netns oldboyedu-linux
ip netns exec oldboyedu-linux ip link

# 验证两个进程是否共享网络栈：比对 net ns 的 inode
ll /proc/<pid>/ns/net          # inode 相同 = 共享同一网络栈
```

`--network container:另一容器` 的本质就是**两个进程共享同一个 netns**——`/proc/<pid>/ns/net` 的 inode 完全相同，而 MNT/PID ns 仍是各自的。这套"看 inode 判断共享"的方法，排障 sidecar 网络问题时是硬证据。

**chroot 是隔离的雏形**：`cp bash` 进目录、`ldd bash` 把依赖库一并拷入，两个目录互不可见——MNT namespace 把这个思路做成了内核级机制。手工搭一遍最小 rootfs，容器的文件系统隔离就不再神秘。

---

## 5.6 cgroup 与资源限制：quota 手工写法与热更新

cgroup 子系统管资源：**cpu / cpuacct / cpuset / memory / blkio / devices / freezer** 等。不用 Docker 也能手工限流：

```bash
mkdir /sys/fs/cgroup/cpu/oldboyedu-linux
echo 30000 > /sys/fs/cgroup/cpu/oldboyedu-linux/cpu.cfs_quota_us   # 限 0.3 核
echo <pid> >> /sys/fs/cgroup/cpu/oldboyedu-linux/tasks             # 把进程放进组
```

Docker 的 `--cpu-quota` / `-m` 做的就是这件事的封装；**运行中的容器还能热更新**：

```bash
docker run -id --cpu-quota 30000 -m 200m --name c1 nginx
docker container update --cpu-quota 20000 -m 200m --memory-swap 200m c1
```

两个排障常识：**容器里看 CPU/内存要用 `docker stats`**——容器内的 `free`/`top` 读的是宿主全量（001 §1.8 的坑）；**内存超限直接 OOMKill、CPU 超限只限流**，两者违约成本不同，limits 的宽紧策略 accordingly（004 §4.6 展开）。

---

## 5.7 六个坑

| # | 坑 | 后果 | 正确做法 |
|---|---|---|---|
| 1 | 默认 bridge 里按容器名互访 | 解析失败——默认 bridge 没有内置 DNS | 自定义网络 + `--network` |
| 2 | 容器之间通、出网不通 | 以为是 DNS 问题 | `sysctl net.ipv4.ip_forward` 先查 |
| 3 | macvlan 容器连不通宿主机 | 以为配置错了 | macvlan 设计限制，加一块 bridge 网卡补救 |
| 4 | overlay 网卡 MTU 1450 排查大包问题 | 抓包看到分片以为被攻击 | VXLAN 封装开销是设计使然 |
| 5 | 容器里 free/top 判断额度 | 读到宿主全量数据 | `docker stats` / cgroup 文件 |
| 6 | 手工 stop 后宿主重启容器又活 | always 策略的"困惑" | 调试用 unless-stopped（001 §1.5） |

---

## 5.8 本章检查清单

| # | 问题 |
|---|---|
| 1 | `-p 81:80` 在 iptables 里对应哪条链的哪个动作？ |
| 2 | 为什么默认 bridge 容器间不能按名互访？自定义网络加了什么？ |
| 3 | macvlan 与 overlay 各牺牲了什么、各解决了什么？ |
| 4 | 两个进程共享网络栈的硬证据是什么？在哪看？ |
| 5 | 手工把一个进程限到 0.3 核，要写哪两个文件？ |
| 6 | 内存超限和 CPU 超限的后果有什么本质区别？ |

---

> 下一篇：[006 运行时进阶：containerd 与 ctr](006-运行时进阶：containerd与ctr.md)——把运行时栈从"概念分层"变成"亲手操作"。
