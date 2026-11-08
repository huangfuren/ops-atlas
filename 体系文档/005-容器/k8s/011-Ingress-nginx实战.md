# 011 Ingress-nginx 实战

> **解决**：ingress-nginx 的十五个生产专题——从 HTTP/HTTPS 到灰度、限流、黑白名单与四层代理，全部给出可 `kubectl apply` 的最小配置。  
> **范围**：HTTP/HTTPS 代理 · 重写与重定向 · basicauth · 黑白名单 · 速率限制 · 金丝雀 · 四层 TCP/UDP · 错误后端 · snippet 风险。  
> **口径**：ingress-nginx controller（k8s 社区版），注解前缀 `nginx.ingress.kubernetes.io/`。  
> **更新**：2026-11-08

## 目录

| 节 | 专题 |
|---|---|
| 11.1 | HTTP 代理：标准三件套入门模板 |
| 11.2 | HTTPS 代理：证书链路与 ssl-redirect |
| 11.3 | 重写与重定向：rewrite-target 的正则捕获 |
| 11.4 | basicauth：最简单的入口认证 |
| 11.5 | 黑白名单：全局 cm 与注解的优先级 |
| 11.6 | 速率限制：limit-rps 家族与压测验证 |
| 11.7 | 金丝雀灰度：canary 权重与统计验证 |
| 11.8 | 四层 TCP/UDP 代理：改启动参数的非常规姿势 |
| 11.9 | 错误后端：default-backend 与 custom-http-errors |
| 11.10 | snippet：能力最强、风险最大的注解 |
| 11.11 | 五个坑 |
| 11.12 | 本章检查清单 |

---

## 11.1 HTTP 代理：标准三件套入门模板

每个专题都是同一个三件套的变体：**Deployment（应用）→ Service → Ingress**。入门模板：

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: demo
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
spec:
  ingressClassName: nginx
  rules:
    - host: demo.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: demo-svc
                port:
                  number: 80
```

---

## 11.2 HTTPS 代理：证书链路与 ssl-redirect

三步：**openssl 自签或申请证书 → 证书存成 Secret（type: kubernetes.io/tls）→ Ingress 加 tls 段**：

```bash
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout tls.key -out tls.crt -subj "/CN=demo.example.com"
kubectl create secret tls demo-tls --cert=tls.crt --key=tls.key
```

```yaml
spec:
  tls:
    - hosts: [demo.example.com]
      secretName: demo-tls
```

默认行为：配了 tls 段后，**80 端口的 HTTP 请求自动 301 到 HTTPS**（ssl-redirect 内置）——想关它才需要显式注解。

---

## 11.3 重写与重定向：rewrite-target 的正则捕获

**重写（rewrite）**是代理内部的路径变换，浏览器无感知。核心是 `rewrite-target` 配合 path 的正则捕获组：

```yaml
metadata:
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /$2
spec:
  rules:
    - http:
        paths:
          - path: /api(/|$)(.*)        # 捕获组 $1=/api 或 /，$2=剩余路径
            pathType: ImplementationSpecific
            backend: { service: { name: api-svc, port: { number: 80 } } }
```

效果：`/api/users` 送到后端时变成 `/users`——前缀剥离的标准写法。

**重定向（redirect）**是让浏览器换地址，两个注解：

```yaml
nginx.ingress.kubernetes.io/permanent-redirect: "https://new.example.com"
nginx.ingress.kubernetes.io/permanent-redirect-code: "308"
```

分界一句话：**rewrite 用户看不到（透明），redirect 用户看得到（地址栏变）**。

---

## 11.4 basicauth：最简单的入口认证

```bash
htpasswd -c auth admin          # 生成 htpasswd 文件
kubectl create secret generic demo-auth --from-file=auth
```

```yaml
metadata:
  annotations:
    nginx.ingress.kubernetes.io/auth-type: basic
    nginx.ingress.kubernetes.io/auth-secret: demo-auth
    nginx.ingress.kubernetes.io/auth-realm: "需要认证"
```

适合给内部测试页、监控面板加一道门。**它不是 SSO**——用户名密码明文走 TLS 之外的链路就是裸奔，配合 11.2 的 HTTPS 用。

---

## 11.5 黑白名单：全局 cm 与注解的优先级

两种姿势，作用域不同：

| 姿势 | 配置位置 | 作用域 |
|---|---|---|
| **黑名单** | Controller 的 ConfigMap（`block-cidrs: "10.0.0.0/8"`） | **全局**：整个 Controller 生效 |
| **白名单** | Ingress 注解（`whitelist-source-range: "办公网段"`） | **仅本 Ingress** 生效 |

结论要背：**黑名单用 ConfigMap（一处处打补丁来不及），白名单用注解（每个入口的允许面本来就该各管各的）**。注解版：

```yaml
nginx.ingress.kubernetes.io/whitelist-source-range: "10.1.0.0/16,192.168.1.0/24"
```

---

## 11.6 速率限制：limit-rps 家族与压测验证

```yaml
metadata:
  annotations:
    nginx.ingress.kubernetes.io/limit-rps: "10"          # 每秒 10 请求
    nginx.ingress.kubernetes.io/limit-rpm: "600"         # 或每分钟
    nginx.ingress.kubernetes.io/limit-connections: "20"  # 并发连接数
    nginx.ingress.kubernetes.io/limit-whitelist: "10.1.0.0/16"   # 白名单网段不限速
```

验证用 `ab -n 100 -c 20` 压一轮，看返回里 503 的占比——限流生效的标志。限的是"每个客户端 IP"的速率，不是全局总量（全局容量靠后端扩缩）。

---

## 11.7 金丝雀灰度：canary 权重与统计验证

同一个 host 的两条 Ingress，**主 Ingress + 带 canary 注解的灰度 Ingress**：

```yaml
# 灰度 Ingress 的 annotations：
nginx.ingress.kubernetes.io/canary: "true"
nginx.ingress.kubernetes.io/canary-weight: "10"     # 10% 流量进灰度
```

验证方式接地气：`curl` 打 100 次，统计新旧后端命中分布是否 ≈ 10:90。除权重外还有按 header / 按 cookie 的定向灰度（`canary-by-header`）——内部测试走 header，公网走 weight。

---

## 11.8 四层 TCP/UDP 代理：改启动参数的非常规姿势

Ingress 只管七层——**四层（TCP/UDP）代理不走 Ingress 对象**，而是改 Controller 的启动参数 + ConfigMap：

```yaml
# Controller 的 args 追加：
- --tcp-services-configmap=ingress-nginx/tcp-services
- --udp-services-configmap=ingress-nginx/udp-services
```

```yaml
# tcp-services ConfigMap：外部端口 → 命名空间/服务:端口
"9000": "default/proxyhttps-svc:443"
# udp-services：
"53": "kube-system/kube-dns:53"
```

场景：数据库端口、自建 DNS 的暴露。注意这**绕过了七层的所有能力**（域名、TLS、限流全无），纯粹是端口转发。

---

## 11.9 错误后端：default-backend 与 custom-http-errors

应用 404/503 时给用户看什么，两级控制：

| 级别 | 配置 | 作用域 |
|---|---|---|
| Ingress 级 | `default-backend: 'errcode-svc'` + `custom-http-errors: "404,415"` | 本 Ingress 的指定错误码走自定义后端 |
| Controller 级 | Helm values `defaultBackend.enabled` | 全局兜底后端 |

自定义错误后端自己也是一个 Service（返回友好错误页），`custom-http-errors` 列出的状态码会被代理到它。品牌一致性与运维信息（返回运维联系方式/状态页）就在这里做。

---

## 11.10 snippet：能力最强、风险最大的注解

`server-snippet` / `configuration-snippet` 可以**直接注入 Nginx 原生配置段**——能力无边界（按 User-Agent 跳转、自定义 location 都能写）：

```yaml
nginx.ingress.kubernetes.io/server-snippet: |
  location ~* ^/internal/ {
    return 302 https://internal.example.com$request_uri;
  }
```

**风险与开关**：snippet 是"往 Nginx 配置里注入任意文本"，v1.9 起默认关闭，需在 Controller 配置里显式开启 `allow-snippet-annotations: "true"`。开启前想清楚：**能写 snippet 的人 = 能改整个 Nginx 配置的人**。团队约定：snippet 只走评审，不散用。

---

## 11.11 五个坑

| # | 坑 | 后果 | 正确做法 |
|---|---|---|---|
| 1 | pathType 写成 Prefix 却想用正则捕获组 | rewrite 不生效 | 正则场景用 ImplementationSpecific |
| 2 | snippet 没开开关就写 | 注解被静默忽略，以为写对了 | 先确认 Controller 的 allow-snippet-annotations |
| 3 | 黑白名单用反了位置 | 全局拉黑/单点放行，口径混乱 | 黑名单 cm 全局、白名单注解局部 |
| 4 | 四层代理忘了改 Controller 启动参数 | ConfigMap 写了不生效 | args 里的 configmap 挂载是前置条件 |
| 5 | canary 两条 Ingress 的 host/path 不完全一致 | 灰度流量全进主 Ingress | canary 与主规则仅注解不同，路径一字不差 |

---

## 11.12 本章检查清单

| # | 问题 |
|---|---|
| 1 | rewrite 与 redirect 的分界？rewrite-target 的正则捕获怎么写？ |
| 2 | 黑名单与白名单分别应该放在哪一层，为什么？ |
| 3 | 金丝雀的权重注解怎么写？怎么统计验证？ |
| 4 | 四层 TCP 代理需要动哪两处？它放弃了什么能力？ |
| 5 | snippet 的能力与风险各是什么？默认开关状态？ |
| 6 | custom-http-errors 与 default-backend 的关系？ |

---

> 下一篇：[012 安全与准入](012-安全与准入.md)——认证、鉴权、准入三道门与安全上下文。
