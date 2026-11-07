# 004 Terraform IaC 基础

> **解决**：云资源从"点点点"变成"代码评审 + 预览 + 可重建"——IaC 的思想与 Terraform 最小集。  
> **范围**：IaC 思想 · HCL 最小语法 · state 与漂移 · plan/apply 纪律 · 与 Ansible 的对照。  
> **口径**：Terraform 1.x（HCL 语法）；阿里云 provider 为例；模块化与多环境工程化为候选 P5。

## 目录

| 节 | 内容 |
|---|---|
| 1 | IaC 思想：为什么点点点不可持续 |
| 2 | Terraform 最小集：HCL 与 provider |
| 3 | state 与漂移 |
| 4 | plan/apply 纪律 |
| 5 | 与 Ansible 的对照 |
| 6 | 坑表 |
| 7 | 检查清单 |

---

## 1. IaC 思想：为什么点点点不可持续

控制台点出来的资源有三个致命伤：**不可评审**（谁改的？改前什么样？）、**不可重建**（坏了只能照记忆再点一遍）、**会漂移**（代码与真实环境越走越远）。

IaC 三原则：

1. **声明式**：描述"我要什么状态"，不写"怎么达到"——引擎负责计算差异。
2. **幂等**：同一份代码反复 apply，结果一致——与「CICD」006 制品思维、「SRE」004 脚本幂等同源。
3. **可评审**：资源变更走 git——和代码一样有 review、有历史、可回滚。

## 2. Terraform 最小集：HCL 与 provider

```hcl
# main.tf —— 一个最小可用的例子
terraform {
  required_providers {
    alicloud = { source = "aliyun/alicloud", version = "~> 1.21" }
  }
}

provider "alicloud" {
  region = "cn-hangzhou"
}

resource "alicloud_instance" "web" {
  instance_name   = "web-01"
  instance_type   = "ecs.g7.large"
  image_id        = "aliyun_3_x64_20G_alibase_20240528.vhd"
  security_groups = [alicloud_security_group.app.id]
  vswitch_id      = "vsw-xxxx"
}

resource "alicloud_security_group" "app" {
  name = "app-sg"
}

resource "alicloud_security_group_rule" "allow_http" {
  type              = "ingress"
  ip_protocol       = "tcp"
  port_range        = "80/80"
  security_group_id = alicloud_security_group.app.id
  cidr_ip           = "0.0.0.0/0"
}

output "public_ip" {
  value = alicloud_instance.web.public_ip
}
```

四步生命周期：`terraform init`（下载 provider）→ `plan`（预览差异）→ `apply`（落地）→ `destroy`（销毁）。**变量**抽到 `variables.tf`（`variable "env" {}` + `var.env` 引用），**输出**放 `outputs.tf`。

## 3. state 与漂移

**state（terraform.tfstate）是 Terraform 的账本**——记录"这份代码创建了哪些真实资源"，plan/apply 都靠它算差异。

| 事项 | 纪律 |
|---|---|
| **绝不提交 git** | state 里可能有密码与敏感信息；放**远端存储**（OSS backend，支持锁） |
| **绝不手改** | 手改 state 与现实脱节，后续 plan 全错 |
| **漂移（drift）** | 有人在控制台手动改了资源 → 代码与 state 都对不上——用 `terraform plan` 定期检测，发现漂移要么回滚资源、要么把变更补进代码 |
| **锁** | 两人同时 apply 会互相破坏——远端 backend 自带锁（OSS+表格存储） |

## 4. plan/apply 纪律

| 纪律 | 内容 |
|---|---|
| **永远先 plan** | apply 前必须 plan 并**逐行看 diff**——一行 +资源可能意味着几十行删除 |
| **apply 走流水线** | plan 结果贴到 PR，评审通过后流水线 apply——个人项目也要形成"先 plan 后 apply"的肌肉记忆 |
| **破坏性变更警惕** | diff 里出现 `- resource`（删除）或 `force replacement`（重建，如实例规格变更导致销毁重建）时**停手确认**——重建 = 数据盘之外的一切重置 |
| **小步快跑** | 一次 apply 一类变更，不攒大 PR |

## 5. 与 Ansible 的对照

| | Ansible（「CICD」004） | Terraform |
|---|---|---|
| 管理对象 | **已存在的机器**：装软件、改配置 | **还不存在的资源**：创建/销毁基础设施 |
| 模型 | 过程式模块（step by step） | 声明式资源（期望状态） |
| 状态 | 无（幂等靠模块设计） | 有（state 文件） |
| 组合 | Terraform 建机器 → Ansible 配机器——**上下游，不是竞争** |

## 6. 坑表

| # | 坑 | 后果 | 正确做法 |
|---|---|---|---|
| 1 | state 提交进 git | 泄漏敏感信息 + 并发写坏 | 远端 backend + 锁 |
| 2 | 不看 plan 直接 apply | `force replacement` 把带数据的实例销毁重建 | 逐行看 diff，破坏性变更停手确认 |
| 3 | 控制台手动改资源 | 漂移，代码失真 | 改动必须走代码；plan 定期检测漂移 |
| 4 | state 丢了 | 资源台账消失，只能 import 重录 | 远端备份 state |
| 5 | provider 版本漂移 | 升级 provider 后 plan 出意外差异 | version 锁定在 required_providers |

## 7. 检查清单

| # | 问题 |
|---|---|
| 1 | IaC 三原则（声明式/幂等/可评审）与点点点的差别说得清吗？ |
| 2 | state 的四条纪律背得出来吗？ |
| 3 | plan 里的 `force replacement` 意味着什么？ |
| 4 | Terraform 与 Ansible 的分工边界在哪？ |
| 5 | 漂移怎么发现、怎么处理？ |
| 6 | 资源变更走 PR 评审的流程立起来了吗？ |

---

**下一篇**：[005 云监控云日志与衔接](005-云监控云日志与衔接.md) —— 云原生观测与自建体系的合流。
