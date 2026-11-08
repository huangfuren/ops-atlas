# 010 GitOps 与 ArgoCD

> **解决**：应用交付从"推"变"拉"——GitOps 原则、ArgoCD 架构、同步策略与渐进发布。  
> **范围**：GitOps 三原则 · push/pull 模型 · ArgoCD 架构与 Application · 同步与渐进发布 · 密钥管理 · 与流水线的分工。  
> **口径**：ArgoCD 2.x；交付对象以 K8s 为准（与「容器」005~009 衔接）。

## 目录

| 节 | 内容 |
|---|---|
| 1 | GitOps 三原则 |
| 2 | push vs pull：凭据边界的反转 |
| 3 | ArgoCD 架构与 Application |
| 4 | 同步策略与漂移纠正 |
| 5 | 渐进发布：Argo Rollouts |
| 6 | 密钥管理 |
| 7 | 与流水线的分工 |
| 8 | 坑表 |
| 9 | 检查清单 |

---

## 1. GitOps 三原则

| 原则 | 含义 |
|---|---|
| **Git 是唯一事实源** | 期望的集群状态全部声明在 git 里（manifests/Helm/Kustomize） |
| **声明式** | 描述"我要什么"，不写"怎么达到"——与「云平台」004 Terraform 同思想（IaC 管资源，GitOps 管应用） |
| **持续自动同步** | controller 持续比对"实际 vs 期望"，自动拉齐或告警 |

收益：变更可评审可回滚（revert 一个 commit）、环境状态永远可重建、漂移自动纠正——004 §3 的漂移问题在这里有了结构性解法。

## 2. push vs pull：凭据边界的反转

| | push（传统流水线，007/008） | pull（GitOps，010） |
|---|---|---|
| 部署发起方 | CI 系统**推**到集群 | 集群内 controller **拉** git |
| 集群凭据 | CI 必须持有生产集群凭据 | **凭据不出集群**——ArgoCD 在集群内拉 git |
| 安全边界 | CI 被攻破 = 生产失守 | git 只读即可部署 |

**这是 GitOps 的核心安全收益**：生产集群对 CI 不再需要写凭据——CI 只负责"构建镜像 + 更新 manifest 仓库里的镜像 tag"（详见 §7 分工）。

## 3. ArgoCD 架构与 Application

| 组件 | 角色 |
|---|---|
| API Server | UI/CLI/gRPC 接口 |
| Repo Server | 拉取 git 仓库、渲染 manifests（Helm/Kustomize） |
| Application Controller | 比对"git 期望"与"集群实际"，执行同步 |

核心模型是 **Application CR**（一个 K8s 自定义资源）：

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: order-service
  namespace: argocd
spec:
  source:
    repoURL: https://git.example.com/ops/manifests.git
    path: apps/order/prod          # 该应用的 manifest 目录
    targetRevision: main
  destination:
    server: https://kubernetes.default.svc
    namespace: prod
  syncPolicy:
    automated: { prune: true, selfHeal: true }
```

多应用治理用 **App of Apps**（一个根 Application 管理一批 Application CR）——新环境接入就是加一个 Application 文件。

## 4. 同步策略与漂移纠正

| 策略 | 含义 | 取舍 |
|---|---|---|
| `automated.sync` | 自动同步 git 变更 | 手动同步适合敏感环境 |
| `prune: true` | git 里删了资源，集群里**同步删除** | ⚠️ 删错文件=删生产资源——仓库权限要严 |
| `selfHeal: true` | 有人手动改了集群，**自动纠正回 git 状态** | 漂移的结构性解法（004 §3 同思想）；应急绕行要先禁 selfHeal |

健康状态：Healthy / Progressing / Degraded / Missing / OutOfSync——**Degraded 接告警**（与「监控」体系同址）。资源健康判断可自定义（Lua）——如以 Deployment available 为准。

## 5. 渐进发布：Argo Rollouts

原生 Deployment 的滚动更新粒度粗；**Argo Rollouts** CR 提供声明式渐进发布：

```yaml
strategy: canary
steps:
  - setWeight: 10            # 10% 流量到新版
  - analysis: {templates: [{templateName: success-rate}]}   # 自动分析指标
  - pause: {duration: 5m}    # 暂停或自动判断
  - setWeight: 50
```

指标分析对接 Prometheus（成功率/延迟自动判断）——不达标自动回滚。**与「CICD」007 的发布策略对照**：007 是"流水线里做灰度"，Rollouts 是"声明式灰度+自动分析"——思想进阶，工具不同。

## 6. 密钥管理

⚠️ **明文 secret 进 git 是 GitOps 第一禁忌**——密钥与代码同库就等于公开：

| 方案 | 机制 |
|---|---|
| **Sealed Secrets** | 集群公钥加密的 secret 入 git，集群内 controller 解密——密文可安全提交 |
| External Secrets | 密钥存外部（Vault/云 KMS），ESO 同步成 K8s Secret——git 里只有引用 |

选型：小团队 Sealed Secrets 简单直接；有 Vault 体系用 External Secrets。

## 7. 与流水线的分工

GitOps 时代 CI 的职责收窄为两步：**① 构建镜像并推送仓库；② 更新 manifest 仓库里的镜像 tag（一个 commit）**——部署动作完全交给 ArgoCD：

```plain
代码 commit → CI：构建+测试+推镜像 → CI：改 manifest 仓库的 tag（commit）
→ ArgoCD 检测 manifest 变更 → 同步集群 → Rollouts 渐进发布 → 指标达标自动放量
```

Jenkins（002/008）与 ArgoCD **分工而非替代**：CI 管构建与测试，ArgoCD 管部署与漂移——007 的"部署"段在新体系下移交 GitOps。

## 8. 坑表

| # | 坑 | 后果 | 正确做法 |
|---|---|---|---|
| 1 | 明文 secret 入 git | 凭据公开（删了历史也在） | Sealed Secrets / External Secrets |
| 2 | auto-prune 删错资源 | 生产资源被静默删除 | 仓库变更走 PR 评审；敏感环境关 prune |
| 3 | 应急 kubectl 手改集群 | 被 selfHeal 立即改回，应急失败 | 应急先禁 selfHeal，事后把变更补回 git |
| 4 | manifest 仓库与源码仓库不分 | 镜像 tag 提交污染应用源码历史 | 分仓：源码仓 + manifest 仓（或同仓分目录+分支策略） |
| 5 | Application 全放一个命名空间无 RBAC | 任何人可改任何环境 | 项目（AppProject）+ RBAC 按环境隔离 |
| 6 | 健康判断用默认 | Deployment "可用"不代表业务可用 | 关键服务自定义健康判断对接业务指标 |

## 9. 检查清单

| # | 问题 |
|---|---|
| 1 | GitOps 三原则说得清吗？与 Terraform 的同构关系呢？ |
| 2 | pull 模型的安全收益（凭据不出集群）能讲吗？ |
| 3 | prune/selfHeal 两个开关的风险理解吗？ |
| 4 | 密钥方案选型定了吗（Sealed vs External）？ |
| 5 | CI 与 ArgoCD 的职责边界写进文档了吗？ |
| 6 | 渐进发布要不要上 Rollouts（有 SLI 数据源吗，衔接「监控」）？ |

---

> 下一篇：《011 Harbor 平台运维》——镜像仓库本体的命根数据、主备复制与反代接入五坑。
