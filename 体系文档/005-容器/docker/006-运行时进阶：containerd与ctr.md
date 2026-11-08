# 006 运行时进阶：containerd 与 ctr

> **解决**：把 000 册的"运行时栈"从概念变成亲手操作——containerd 怎么部署、怎么与 Docker 集成、ctr 三层模型怎么用，以及它和 K8s 的 CRI 是什么关系。  
> **范围**：containerd 定位与部署 · config.toml 三要点 · Docker 集成 · ctr 三层模型（namespace → container → task）· 与 K8s CRI 的衔接。  
> **口径**：containerd 1.7.x（cri-containerd-cni 二进制包）；ctr 为调试与管理工具，生产常态用 docker/K8s 间接使用。  
> **更新**：2026-11-08

## 目录

| 节 | 内容 |
|---|---|
| 6.1 | containerd 的定位：从 Docker 拆出来的那一层 |
| 6.2 | 部署与 config.toml：三个必改要点 |
| 6.3 | Docker 集成 containerd：一个 sock 的事 |
| 6.4 | ctr 三层模型：namespace → container → task |
| 6.5 | 与 K8s 的关系：CRI、pause 镜像与 crictl |
| 6.6 | 五个坑 |
| 6.7 | 本章检查清单 |

---

## 6.1 containerd 的定位：从 Docker 拆出来的那一层

000 册 §0.3 的调用链在这里落地：**Docker 引擎（构建/API/网络）之下是 containerd（拉镜像、管生命周期、快照），之下才是 runc（真正 exec 出容器进程）**。containerd 2016 年从 Docker 捐给 CNCF，如今是 K8s 节点上的标配运行时——**K8s 1.24 移除 dockershim 之后，kubelet 直连的就是它**（000 §0.3）。

两个使用场景：**独立部署**（给 K8s 或裸 containerd 环境用，docker 不装）与**与 Docker 共存集成**（让 docker 用的就是外部 containerd）。本册两个都做。

部署走官方二进制包 `cri-containerd-cni-<版本>-linux-amd64.tar.gz`——解压即得 containerd 二进制、systemd 单元、runc、CNI 插件与默认配置，一次到位。

---

## 6.2 部署与 config.toml：三个必改要点

```bash
tar -xf cri-containerd-cni-1.7.13-linux-amd64.tar.gz -C /        # 按包内目录结构落位
containerd config default > /etc/containerd/config.toml          # 生成默认配置再改
```

默认配置有三处**必改**（K8s 场景），sed 可脚本化：

```bash
sed -i 's#SystemdCgroup = false#SystemdCgroup = true#' /etc/containerd/config.toml     # 与 kubelet 的 cgroupDriver=systemd 对齐
sed -i 's#sandbox_image = "registry.k8s.io/pause:3.8"#sandbox_image = "registry.cn-hangzhou.aliyuncs.com/google_containers/pause:3.8"#' /etc/containerd/config.toml   # pause 镜像换国内源
```

第三个要点在 `[plugins."io.containerd.grpc.v1.cri".registry.mirrors]` 配**私有仓库镜像源与地址**——不配的话 K8s 节点拉私有镜像永远 ImagePullBackOff。

改完 `systemctl restart containerd && systemctl enable containerd`，`ctr version` 能对上客户端/服务端版本即部署成功。

---

## 6.3 Docker 集成 containerd：一个 sock 的事

让 Docker 不再自己内嵌 containerd，而是接管外部的这个：

```bash
# ExecStart 追加：--containerd /run/containerd/containerd.sock
systemctl edit docker       # 写入 override 后重启 docker
```

验证两个"同一"：**Docker 起的容器出现在 `ctr -n moby containers list`**（moby 是 Docker 专用的 namespace）；**ctr 里的 task PID 与 `docker inspect --format '{{.State.Pid}}'` 一致**——同一个进程，两套视图。

这个实验的价值：把"运行时栈分层"从图变成可触摸的事实——docker 与 ctr 是同一个 containerd 的两个客户端。

---

## 6.4 ctr 三层模型：namespace → container → task

ctr 的对象模型三层，操作顺序也是三层：

| 层 | 是什么 | 常用命令 |
|---|---|---|
| **namespace** | 隔离边界（moby 专属 Docker） | `ctr ns list` / `ctr ns create oldboy` |
| **container** | 静态配置（镜像 + 挂载 + 资源声明），**没跑** | `ctr containers create` |
| **task** | container 跑起来的进程 | `ctr task start -d` / `task pause` / `task kill` |

全流程一把过：

```bash
ctr -n oldboy images pull docker.io/library/nginx:alpine     # 本地无镜像不自动 pull（与 docker 不同）
ctr -n oldboy images tag  docker.io/library/nginx:alpine myreg/nginx:v1
ctr -n oldboy images mount docker.io/library/nginx:alpine /mnt/   # 把镜像挂成目录直接看内容
ctr -n oldboy images check                                   # 校验 UNPACKED 状态
ctr -n oldboy containers create --mount type=bind,src=/data,dst=/usr/share/nginx/html,options=rbind:rw nginx:alpine c1
ctr -n oldboy task start -d c1
ctr -n oldboy task exec --exec-id $RANDOM -t c1 sh
ctr -n oldboy task pause c1                                  # pause 后 exec 报 cannot exec in a paused state
ctr -n oldboy task kill c1 && ctr -n oldboy task rm -f c1    # task rm 需先停，-f 强杀（exit 137）
```

与 Docker 的行为差异记三条：**本地无镜像不自动 pull**（要先 `images pull`）；**`--net-host` 对应 docker 的 `--network host`**；**镜像/容器按 namespace 隔离**——`ctr -n moby` 里看不到你自己 ns 的东西，反之亦然。namespace 删除的前置条件：里面镜像/blob/snapshot 全清空。

---

## 6.5 与 K8s 的关系：CRI、pause 镜像与 crictl

K8s 节点上 kubelet 不直接调 ctr，而是走 **CRI（容器运行时接口）**：kubelet → CRI → containerd 内置的 CRI 插件 → runc。三个衍生命令与概念：

- **crictl**：面向 Pod/容器沙箱的调试 CLI（与 ctr 平级但走 CRI 口径）——查 Pod 的容器、看沙箱状态用它；
- **pause 镜像**：每个 Pod 里第一个被拉起的"占位容器"，作用是持住 network/ipc 等 namespace 供业务容器共享（Pod 的骨架，002 概念在 K8s 的落地）；**国内环境必换国内源**（6.2 的 sandbox_image）；
- **镜像可见性**：`ctr -n k8s.io images ls` 能看到 K8s 拉的所有镜像（k8s.io 是 containerd 给 K8s 的专用 namespace）——排障 ImagePullBackOff 时先在这里确认镜像到底有没有拉下来。

---

## 6.6 五个坑

| # | 坑 | 后果 | 正确做法 |
|---|---|---|---|
| 1 | SystemdCgroup 忘改 true | K8s 节点 Pod 反复重启 / kubelet 报 cgroup driver 不匹配 | 6.2 的三处必改逐条核 |
| 2 | sandbox 镜像用默认 k8s 源 | 国内节点 ImagePullBackOff 卡在 pause | 换国内源 |
| 3 | 在 ctr 里找不到 Docker 的容器 | 不在同一个 namespace | `ctr -n moby`（Docker 专用 ns） |
| 4 | task 还在跑就 `containers delete` | 报错容器在使用 | 先 `task kill` + `task rm`，再删 container |
| 5 | 把 registry 镜像里的秘密当成"删了就没了" | 镜像层与 Docker 同理，删层不等于销毁 | 敏感信息轮换（002 §2.9 同款纪律） |

---

## 6.7 本章检查清单

| # | 问题 |
|---|---|
| 1 | containerd、runc、Docker 三者的职责边界，用一句话各自说清？ |
| 2 | config.toml 在 K8s 场景的三个必改点是什么？不改各出什么故障？ |
| 3 | Docker 集成外部 containerd 后，用什么命令能同时看到两套视图的同一容器？ |
| 4 | ctr 的 namespace / container / task 三层各自对应什么状态？task 与 container 的区别？ |
| 5 | K8s 节点上排障 ImagePullBackOff，在 containerd 层面先看什么？ |

---

> 下一篇：回到 [k8s/005 架构与核心对象](../k8s/005-K8s架构与核心对象.md)——单机容器之后，看一组机器怎么编排。也可以先回 [../README](../README.md) 看板块地图。
