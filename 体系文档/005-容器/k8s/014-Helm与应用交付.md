# 014 Helm 与应用交付

> **解决**：K8s 的包管理器——一套应用几十个 YAML 怎么打包、怎么参数化、怎么升级回滚，以及用 Helm 交付 Harbor/Loki/ingress-nginx 的真实闭环。  
> **范围**：Chart / Release / Repository 三概念 · v2 → v3 演进 · 全套命令 · `--set` 语法规则 · 资源安装顺序 · 自建 chart 四步。  
> **口径**：Helm v3（无 tiller 架构）；示例均可在真实集群复现。  
> **更新**：2026-11-08

## 目录

| 节 | 内容 |
|---|---|
| 14.1 | Helm 是什么：K8s 的 YUM 与三大概念 |
| 14.2 | v2 → v3：tiller 的消亡与架构简化 |
| 14.3 | 全套命令：安装、升级、回滚、卸载 |
| 14.4 | `--set` 语法规则与优先级 |
| 14.5 | 资源安装顺序表：模板渲染的依赖依据 |
| 14.6 | 自建 chart 四步与模板灵魂 |
| 14.7 | 实战三例：harbor / loki / ingress-nginx |
| 14.8 | 五个坑 |
| 14.9 | 本章检查清单 |

---

## 14.1 Helm 是什么：K8s 的 YUM 与三大概念

一套应用（Deployment + Service + ConfigMap + Ingress + PV…）动辄十几个 YAML，逐个 apply 既难维护也难回滚。**Helm 把它们打成一个 Chart（自包含的部署单元）**，用一套参数驱动安装。三个概念：

| 概念 | 是什么 | 类比 |
|---|---|---|
| **Chart** | 应用打包格式：模板 + 默认值 + 说明 | 软件包（rpm） |
| **Release** | Chart 在集群里的一次运行实例 | 一次安装（同名可多实例） |
| **Repository** | Chart 仓库，`repo add` 后可 search/install | yum 源 |

Helm cli **直连 apiserver**（kubeconfig 就是凭证）——helm 命令的权限 = 你 kubeconfig 的权限。

---

## 14.2 v2 → v3：tiller 的消亡与架构简化

v2 的架构是 C/S：**tiller** 作为服务端跑在集群里替你执行——RBAC 时代这个设计成了灾难（tiller 常常 cluster-admin，谁拿到 tiller 就拿到了整个集群）。**v3 移除 tiller**：helm 直接用本地 kubeconfig 调 apiserver，不再需要 `helm init`、不再需要 SA。

对使用者的实际意义：**权限就是你的 kubeconfig 权限，审计就是你自己的操作**——v3 的架构修正本身就是 RBAC 时代安全模型的教学案例（012 册的活样本）。

---

## 14.3 全套命令：安装、升级、回滚、卸载

```bash
helm repo add bitnami https://charts.bitnami.com/bitnami && helm repo update
helm search repo keyword                        # 搜包
helm install my-release bitnami/mysql -f values.yaml
helm upgrade my-release bitnami/mysql -f new-values.yaml
helm rollback my-release 1                      # 回到 revision 1
helm uninstall my-release --keep-history        # 卸载但留史
helm list -n <ns> / helm history my-release
```

每条 install/upgrade 都产生一个 **revision**（版本号），rollback 按 revision 号操作——这就是"应用级回滚"，与 Deployment 的 rollout undo（008）分层：**Deployment undo 管单对象的滚动，Helm rollback 管整包应用**。

---

## 14.4 `--set` 语法规则与优先级

`--set` 是命令行传值入口，语法规则完整版：

```bash
--set key=value                    # 标量
--set outer.inner=value            # 嵌套
--set servers={a,b,c}              # 列表
--set servers[0].port=80           # 列表下标
--set "key=value\,with-comma"      # 值里的逗号要转义
```

**优先级**：`--set` > `-f 自定义values` > chart 默认值；且 `--set` 的值**会存进 Release 的 ConfigMap**——密钥别走 --set（007 §7.3 的纪律）。

---

## 14.5 资源安装顺序表：模板渲染的依赖依据

Helm 安装一个 chart 时，资源按**固定的 kind 顺序**创建——这是模板渲染依赖排序的权威依据：

```plain
Namespace → NetworkPolicy → ResourceQuota → LimitRange → PodSecurityPolicy
→ ServiceAccount → Secret → ConfigMap → StorageClass → PV/PVC
→ Service → DaemonSet → Deployment / StatefulSet / Job …
→ Ingress → APIService
```

两个用途：**自己写 chart 时，被依赖的资源（ns/配置/凭据）天然排在依赖方之前**；排查"装一半失败"时，对照顺序表看卡在哪一层——前面没起，后面全 Pending。这份顺序表也是 005 册"对象作用域三类"的实操映射。

---

## 14.6 自建 chart 四步与模板灵魂

```bash
helm create mychart          # ① 脚手架（templates/ + values.yaml + Chart.yaml）
# ② 改 templates/ 里的模板与 values.yaml 默认值
helm lint mychart            # ③ 静态检查（模板语法 + 值校验）
helm install test mychart --dry-run   # dry-run 渲染检查再真装
```

模板的灵魂是**Values 注入 + 内置对象 + 控制结构**三件套：

```yaml
nameOverride: {{ .Values.nameOverride | default "app" }}
generatedAt: {{ now | date "20060102030405" }}
{{- if eq .Values.service.type "NodePort" }}
type: NodePort
{{- end }}
```

`NOTES.txt` 是安装完成后的提示页（怎么访问/怎么取密码）——写好它，交付体验翻倍。

---

## 14.7 实战三例：harbor / loki / ingress-nginx

本板块三条工具线都用 Helm 交付过，三条真实链路：

| 应用 | 要点 |
|---|---|
| **Harbor** | `helm repo add harbor → pull → 改 values → install`；取 ingress-nginx 的证书 Secret、`/etc/docker/certs.d/` 信任链 |
| **Loki** | `helm install loki -n loki -f values-pre.yaml .`；验证 `/loki/api/v1/labels`；组件 Distributor/Ingester 的 quorum 写入 |
| **ingress-nginx** | Controller 本体 Helm 装；`defaultBackend.enabled` 控制全局错误后端；四层代理要挂 tcp-services ConfigMap（011 §11.8） |

三条链路的共同点：**values 文件进 Git（012 的配置纪律），安装命令进文档（016 的变动日志）**——Helm 的可复现性才成立。

---

## 14.8 五个坑

| # | 坑 | 后果 | 正确做法 |
|---|---|---|---|
| 1 | 密钥走 `--set` | 明文进 Release ConfigMap 与 shell 历史 | 密钥用 Secret 对象 + 外部注入 |
| 2 | `--set` 列表语法写错 | 静默覆盖成错误结构 | 复杂值写 values 文件，别硬 --set |
| 3 | 装一半失败就删 chart 重装 | 部分资源残留，二次安装冲突 | `helm uninstall` 或查 `get all -l app.kubernetes.io/instance=` |
| 4 | 升级不带 -f | 前次自定义值全部回退默认 | upgrade 仍要带同一份 -f（或用 `--reuse-values`） |
| 5 | 忽视资源安装顺序 | 依赖对象未建，Pod 全 Pending | 按 14.5 顺序表自查 chart |

---

## 14.9 本章检查清单

| # | 问题 |
|---|---|
| 1 | Chart / Release / Repository 三概念各对应什么？ |
| 2 | v3 为什么删 tiller？这体现了什么安全模型的变化？ |
| 3 | `--set` 的嵌套/列表/转义语法？它与 `-f` 的优先级？ |
| 4 | 资源安装顺序表对自建 chart 的两个用途？ |
| 5 | `helm rollback` 与 `rollout undo` 各管哪一层？ |

---

> 下一篇：回到 [板块 README](../README.md) —— Docker 与 K8s 两条工具线的全部地图。也可进入「CICD」册看交付闭环的另一半。
