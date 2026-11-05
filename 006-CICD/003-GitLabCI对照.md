# 003 GitLab CI 对照

> **解决**：不维护独立构建服务器时的另一条路，以及与 Jenkins 的取舍。  
> **范围**：.gitlab-ci.yml · Runner · cache 与 artifacts · 与 Jenkins 的对照。  
> **口径**：GitLab CE 16+，Runner 以 docker executor 为主。  
> **更新**：2026-10-31

## 目录

| 节 | 内容 |
|---|---|
| 3.1 | GitLab CI 与 Jenkins 的架构差异 |
| 3.2 | Runner 与 executor：shell / docker / kubernetes 怎么选 |
| 3.3 | 第一条 .gitlab-ci.yml：build → test → deploy |
| 3.4 | stages 与并行：同阶段并发、跨阶段串行 |
| 3.5 | rules：什么分支什么事件跑什么 |
| 3.6 | cache 与 artifacts：提速的与交付的，别混 |
| 3.7 | 变量与保护：CI/CD Variables、保护分支与受保护变量 |
| 3.8 | include 与模板：多项目统一门禁 |
| 3.9 | 与 Jenkins 的选型对照 |
| 3.10 | 八个坑 |
| 3.11 | 本章检查清单 |

---

## 3.1 GitLab CI 与 Jenkins 的架构差异

两者的功能高度重叠，架构差异才是选型的根：

```plain
Jenkins：  代码仓库(GitLab) ──webhook──▶ Jenkins controller ──▶ agents
           （两套系统、两份账号、两处配置）

GitLab CI：代码仓库(GitLab) ──内置CI──▶ Runner（执行进程）
           （CI 是 GitLab 的内置功能，只差执行器）
```

含义有三层：**配置就在仓库里**（`.gitlab-ci.yml` 与代码同评审同回滚，002 §2.4 的理想态天然达成）；**权限天然复用**（GitLab 的分支保护、成员角色直接约束 CI，无需另配）；**代价是绑定 GitLab 生态**——代码托管在别处时此路不通。Runner 仍需自己养，但它是无状态的执行进程，维护量远小于 Jenkins controller。

---

## 3.2 Runner 与 executor：shell / docker / kubernetes 怎么选

Runner 是注册到 GitLab 的执行进程（`gitlab-runner register`，填 GitLab 地址与注册 token），**executor 决定 job 在什么环境里跑**：

| executor | 行为 | 评价 |
|---|---|---|
| shell | 在 Runner 主机直接执行命令 | 快，但环境污染不可逆——**只给可信项目用** |
| docker | 每个-job 拉镜像在容器里跑 | 环境干净可复现，**生产默认** |
| kubernetes | 在 K8s 集群内起 Pod 跑 | 构建量大、弹性诉求高时用 |

生产口径一句话：**docker executor + 在镜像里声明构建环境**（与「容器」002 的容器内构建同一思想）。Runner 配置里最有用的两项：`concurrent`（单机并发 job 数，磁盘与 CPU 的阀门）与 tags（job 按 tag 派发——语义同 Jenkins 的 label）。

---

## 3.3 第一条 .gitlab-ci.yml

仓库根目录放一个文件，CI 即生效：

```yaml
stages: [build, test, deploy]

build:
  stage: build
  image: golang:1.22-alpine
  script:
    - CGO_ENABLED=0 go build -o app .
  artifacts:
    paths: [app]

test:
  stage: test
  image: golang:1.22-alpine
  script:
    - go test ./...

deploy-test:
  stage: deploy
  image: alpine:3.19
  script:
    - ./deploy.sh test
  environment: test
  rules:
    - if: '$CI_COMMIT_BRANCH == "main"'
```

读法与 Jenkinsfile 对应：`stages` 是阶段清单，每个 job 的 `stage` 定归属；`script` 是步骤；`image` 是容器内构建的环境；`artifacts` 把产物传给下一个 job（3.6 展开）；`rules` 代替 Jenkins 的 when/triggers。

push 之后到 GitLab 的 CI/CD → Pipelines 页面看第一次运行。**job 红了点进去看完整日志**——GitLab 的日志与仓库同权限，这是它比 Jenkins 更顺手的地方。

---

## 3.4 stages 与并行：同阶段并发、跨阶段串行

执行模型两句话：**同 stage 的多个 job 并行跑；跨 stage 严格串行（上一 stage 全绿才进下一个）**。这决定了划分阶段的设计：并行加速放同一 stage，门禁关系放不同 stage：

```yaml
stages: [build, test, scan, deploy]

build: { stage: build, script: [make build] }
unit-test:  { stage: test,  script: [make test-unit] }
lint:       { stage: test,  script: [make lint] }     # 与单测并行
sec-scan:   { stage: scan,  script: [trivy .] }
deploy:     { stage: deploy, script: [./deploy.sh] }
```

`test` 里的两个 job 并行，`scan` 必须等 `test` 全绿——"测试并行省时间、扫描做门禁"的标准布局。

---

## 3.5 rules：什么分支什么事件跑什么

`rules` 决定每个 job 在什么时候被触发，四种常用写法：

```yaml
deploy-prod:
  rules:
    - if: '$CI_COMMIT_BRANCH == "main"'          # 只在 main 跑
      when: manual                               # 且人工点确认（生产审批）
deploy-tag:
  rules:
    - if: '$CI_COMMIT_TAG'                       # 打 tag 时触发（发布版）
mr-only:
  rules:
    - if: '$CI_PIPELINE_SOURCE == "merge_request_event"'   # 只在 MR 里跑
skip-docs:
  rules:
    - if: '$CI_PIPELINE_SOURCE == "push"'
      changes: { paths: ['docs/**'], compare_to: 'main' }  # 仅文档改动不跑全套
      when: never
    - when: always                               # 其余情况照常
```

`when: manual` 是 GitLab 版的生产审批（对应 002 §2.5 的 parameters 思路），且**手工触发时才进入该 job**。规则从上到下匹配，`when: never` 可短路——复杂团队在此沉淀"什么情况跑什么"的全部策略。

---

## 3.6 cache 与 artifacts：提速的与交付的，别混

两个概念都对"文件"下手，语义相反，混用是本册第一大坑：

| | cache | artifacts |
|---|---|---|
| 目的 | **加速**：依赖包、编译缓存的跨构建复用 | **交付**：把产物传回 GitLab、传给下游 job |
| 保证 | **不保证存在**（被清理后要能重建） | 有过期时间但可靠交付 |
| 位置 | Runner 本地或对象存储 | GitLab 统一存储 |

```yaml
build:
  cache:
    key:
      files: [go.sum]        # 依赖清单变则换新缓存
    paths: [.gocache/]
  artifacts:
    paths: [app]
    expire_in: 7 days
```

判据一句话：**丢了这个文件，构建要重做 = cache；下游要用、丢了是事故 = artifacts**。`key: files` 让缓存按依赖清单换档——清单没变就命中，与「容器」002 §2.4 的构建缓存同一思想。

---

## 3.7 变量与保护：CI/CD Variables、保护分支与受保护变量

GitLab 的流水线变量三个来源：**内置变量**（`$CI_COMMIT_SHA`、`$CI_COMMIT_TAG`、`$CI_PIPELINE_SOURCE`——可追溯性的素材）、**项目/组级 Variables**（Settings → CI/CD → Variables）、**job 级 variables**。两个关键开关：

- **Protected**：变量只在受保护分支/tag 的流水线里可见——生产凭据必须勾选，feature 分支的任意代码碰不到它；
- **Masked**：日志里自动打码——同 Jenkins 的掩码，且掩码有格式要求（值里不能有不可预测字符），不适合的值用 file 类型挂文件。

这条纪律与 002 §2.7 完全同构：**凭据进变量系统，不进 yml，不进日志**。

---

## 3.8 include 与模板：多项目统一门禁

几十个仓库各自维护一份大而全的 yml，很快就会漂移（有的项目忘了扫描、有的超时配置不一致）。`include` 把公共部分抽成模板：

```yaml
include:
  - project: 'devops/ci-templates'     # 一个专门的模板仓库
    ref: main
    file: '/go-service.yaml'
```

`go-service.yaml` 里定义标准 stages/scan/deploy 模板，各项目只覆盖差异（`extends`）。收益是**门禁的统一演进**：模板仓库里给所有 Go 服务加一步漏洞扫描，几十个仓库一次生效。这是 000 §0.4"工具越少越好"之外的另一条治理原则——**配置越集中越好**。

---

## 3.9 与 Jenkins 的选型对照

把 000 §0.5 的判断展开成决策表：

| 维度 | Jenkins | GitLab CI |
|---|---|---|
| 初建成本 | 一台服务器 + 插件选型 | 已有 GitLab 即零起步 |
| 维护成本 | controller/agent/插件升级 | 养 Runner 即可 |
| 配置存放 | Jenkinsfile（也要进 Git） | 仓库内置 yml |
| 权限 | 独立体系（或 LDAP 对接） | 复用 GitLab 角色 |
| 灵活度 | 极高（Groovy + 插件） | yml 框架内，越界要写 Runner |
| 适合 | 流程复杂/异构环境/存量依赖 | GitLab 生态内/新项目/中小团队 |

务实结论（000 §0.5 的展开）：**新团队从 GitLab CI 起步**；两类信号出现时考虑 Jenkins——需要异构构建机集群与复杂编排、或组织里 Jenkins 存量深厚。迁移期的关键不是"选哪个"，是 000 §0.5 那句：**制品库与发布策略必须统一**（006/007），CI 引擎可以并存。

---

## 3.10 八个坑

| # | 坑 | 后果 | 正确做法 |
|---|---|---|---|
| 1 | cache 当 artifacts 用 | 产物丢失是事故 | 交付物走 artifacts（3.6） |
| 2 | job 卡在 pending | tag 不匹配 / 并发满 / Runner 掉线 | Runner 页面看勾选的 tags |
| 3 | shell executor 跑不可信代码 | 构建机永久污染 | docker executor |
| 4 | 生产凭据没勾 Protected | feature 分支可读取 | 变量全员 Protected + Masked |
| 5 | artifacts 不设 expire_in | 存储被构建历史吃满 | 统一过期策略 |
| 6 | 同 job 未限并发 | 同一部署目标互踩 | `resource_group: prod` |
| 7 | 忘记 GitLab 默认 job 超时 | 长构建被 1h 默认值截断 | 项目级设 timeout |
| 8 | yml 改动只在 main 验证 | feature 分支上 CI 坏了才发现 | rules 里 MR 事件也跑 lint |

第 6 条展开：`resource_group` 是 GitLab 版的"互斥锁"——同名资源组的 job 自动排队串行执行。部署类 job 必配，否则上一轮部署还没完成、这一轮的 `kubectl apply` 已经开打，502 与半新半旧状态就是这么来的。Jenkins 的对应物是 002 §2.5 的 `disableConcurrentBuilds`，两边的本质都是：**部署目标一次只能被一个发布动作占有**。

---

## 3.11 本章检查清单

读完能回答这六个问题，这一章就过了：

| # | 问题 |
|---|---|
| 1 | GitLab CI 与 Jenkins 的架构差异一句话？各自代价？ |
| 2 | 三个 executor 怎么选？生产的默认是什么？ |
| 3 | cache 与 artifacts 的判据一句话？ |
| 4 | Protected 变量防的是什么？ |
| 5 | 生产部署 job 的两个标配：什么 + 什么？（manual + resource_group） |
| 6 | include 模板解决什么治理问题？ |

---

> 下一篇：《004 Ansible 批量配置》——一百台机器怎么一条命令改完。
