# 005 HTTPS 与 TLS 证书

> **解决**：加密怎么建立、证书为什么不认、换证怎么不断服、HTTPS 为什么慢。
> **范围**：TLS 原理与握手、证书与证书链、证书生命周期、常见故障、Nginx 配置、mTLS。
> **口径**：TLS 1.2 / 1.3。SSLv3 及以下已禁用，不再讨论。
> **更新**：2026-10-28

---

## 目录

| 节 | 内容 |
|---|---|
| 5.1 | TLS 要解决三件事 |
| 5.2 | 混合加密：非对称只在开头用一下 |
| 5.3 | 握手流程 |
| 5.4 | 证书与证书链 |
| 5.5 | 证书生命周期 |
| 5.6 | 常见故障与判据 |
| 5.7 | 终止点与 Nginx 配置 |
| 5.8 | mTLS 双向认证 |
| 5.9 | 合规基线 |
| 5.10 | 命令与坑 |
| 5.11 | 本章检查清单 |

---

## 5.1 TLS 要解决三件事

| 目标 | 靠什么 |
|---|---|
| **机密性** —— 别人看不懂 | 加密 |
| **完整性** —— 别人改不了 | 消息认证码（MAC） |
| **身份** —— 对面确实是它 | 证书 + 数字签名 |

三件事里最难的是第三件。加密本身不难，难的是**你加密用的那把公钥，确实属于 example.com**——否则中间人可以给你一把自己的公钥，你加密给他，他解密再转发。**证书解决的正是这个信任问题。**

一句话：**TLS = 加密 + 校验 + 证明身份**，三者缺一不可。

---

## 5.2 混合加密：非对称只在开头用一下

### 5.2.1 分工

「HTTPS 用非对称加密」这个说法是错的。准确讲是**混合加密**：

| 环节 | 用的密码学 | 具体算法（TLS 1.3） | 为什么是它 |
|---|---|---|---|
| 密钥协商 | 非对称（密钥交换） | ECDHE（X25519 / secp256r1） | 双方在不安全信道上算出同一把会话密钥，且具备前向保密 |
| 身份认证 | 非对称（数字签名） | RSA-PSS / ECDSA / Ed25519 | 证明「对面确实是 example.com」 |
| **数据加密** | **对称** | AES-128-GCM / AES-256-GCM / ChaCha20-Poly1305 | 快，且有 AES-NI 硬件加速 |
| 完整性校验 | 对称（AEAD 内置） | GCM / Poly1305 自带 MAC | 防篡改，不需要额外的 HMAC 步骤 |

**为什么不能全程非对称**：RSA-2048 做一次解密比 AES-128 慢 **2–3 个数量级**。一个 10MB 的页面如果用 RSA 逐块加密，握手 50ms，传数据要几十秒，CPU 直接打满。

**比喻**：去银行租保险箱。非对称像「银行核验你身份证、给你一把本次专用的钥匙」（慢，只在开头做一次）；对称像「用这把钥匙开门存取东西」（快，全程用）。而且钥匙每次来都换新的。

### 5.2.2 前向保密

「钥匙每次都换」这件事有个正式名字：**前向保密（Forward Secrecy）**。

意思是：即使哪天服务器私钥泄露了，攻击者拿到历史流量也解不开——因为每次会话的密钥是用 ECDHE 临时算出来的，从没在网络上传输过，也不存在服务器硬盘上。

判断有没有前向保密，看密钥交换算法：**ECDHE / DHE 有，纯 RSA 密钥交换没有。**

```bash
openssl s_client -connect www.example.com:443 </dev/null 2>/dev/null | grep "Server Temp Key"
# Server Temp Key: X25519, 253 bits     ← 有 ECDHE，具备前向保密
```

---

## 5.3 握手流程

### 5.3.1 TLS 1.2：两次往返

```text
客户端                                          服务端
  │  ① ClientHello                               │
  │     支持的版本、套件列表、随机数A、SNI          │
  │ ────────────────────────────────────────────> │
  │                                              │
  │  ② ServerHello                                │
  │     选定的版本与套件、随机数B、会话ID            │
  │  ③ Certificate（服务器证书链）                  │
  │  ④ ServerKeyExchange（ECDHE 参数 + 签名）      │
  │  ⑤ ServerHelloDone                            │
  │ <──────────────────────────────────────────── │
  │                                              │
  │  ⑥ ClientKeyExchange（客户端 ECDHE 参数）      │
  │  ⑦ ChangeCipherSpec + Finished                │
  │ ────────────────────────────────────────────> │
  │                                              │
  │  ⑧ ChangeCipherSpec + Finished                │
  │ <──────────────────────────────────────────── │
  │                                              │
  │ ══════════ 加密数据传输 ══════════════════════ │
```

**2-RTT**（两个往返）之后才有第一个字节的应用数据。

### 5.3.2 TLS 1.3：一次往返

```text
客户端                                          服务端
  │  ① ClientHello                                │
  │     版本、套件、随机数A、SNI、**key_share**      │
  │ ────────────────────────────────────────────> │
  │                                              │
  │  ② ServerHello + {EncryptedExtensions,        │
  │     Certificate, CertificateVerify, Finished} │
  │     选定的套件、随机数B、**key_share**          │
  │ <──────────────────────────────────────────── │
  │                                              │
  │  ③ Finished                                   │
  │ ────────────────────────────────────────────> │
  │                                              │
  │ ══════════ 加密数据传输 ══════════════════════ │
```

**1-RTT**。省下的关键是：客户端在第一个包里就把自己的 key_share 猜着发出去了（叫 "guess"），服务端选定后直接算密钥，不用再等一个来回。

TLS 1.3 还移除了这些东西：RSA 密钥交换（只剩 ECDHE，强制前向保密）、CBC 模式、RC4、3DES、压缩、重协商。**所以 TLS 1.3 的套件是固定的五套**，不是配置出来的。

这带来一个运维坑：

```nginx
ssl_ciphers 'ECDHE+AESGCM:...';
# 这行只控制 TLS 1.2 及以下的套件
# TLS 1.3 的套件不受它控制，要靠 ssl_conf_command Ciphersuites 改（OpenSSL 1.1.1+）
```

### 5.3.3 会话复用

完整握手贵在非对称运算。会话复用让客户端第二次连接时跳过密钥协商：

| 机制 | 原理 | 版本 |
|---|---|---|
| Session ID | 服务端在内存/共享缓存里存会话，客户端带 ID 来取 | TLS 1.2 |
| Session Ticket | 服务端把会话加密成 ticket 给客户端，客户端自己带着 | TLS 1.2 |
| PSK | 预共享密钥，1.3 里统一成这个机制 | TLS 1.3 |

**多台 LB 后面的复用有个坑**：Session ID 存在单机内存里，客户端第二次被调度到另一台就失效了，复用率上不去。要么用 Session Ticket（不依赖服务端存储），要么把 ticket key 在多台间共享。

```nginx
ssl_session_cache shared:SSL:10m;     # 共享内存，1MB 约 4000 个会话
ssl_session_timeout 1d;
ssl_session_tickets on;
```

### 5.3.4 SNI：一台服务器多个证书

TLS 握手时客户端还没发 HTTP 请求，服务端怎么知道该用哪张证书？靠 **SNI（Server Name Indication）**——客户端在 ClientHello 里明文带上想访问的域名。

```text
ClientHello
  └─ server_name: www.example.com    ← SNI
```

| 现象 | 原因 |
|---|---|
| 直接访问 IP 报证书错误 | 没带 SNI，服务端给了默认证书 |
| 老客户端不报 SNI | XP/老 Java 客户端不支持 SNI |
| 域名配了但证书不对 | 该域名不在证书的 SAN 列表里，落到了默认证书 |

**重要**：SNI 是明文的。所以「同一 IP 上部署多个 HTTPS 站点」时，中间人能看到你在访问哪个域名（但看不到内容）。

---

## 5.4 证书与证书链

### 5.4.1 证书里有什么

| 字段 | 作用 | 运维关注 |
|---|---|---|
| Subject / CN | 证书属于谁 | 现在主要看 SAN |
| **SAN**（Subject Alternative Name） | **实际生效的域名列表** | 域名不在这里面就报错 |
| Issuer | 谁签发的 | 判断根/中间证书 |
| 有效期 | Not Before / Not After | **到期监控看的就是这个** |
| 公钥 | 服务端的公钥 | — |
| 签名 | 上一级 CA 对这张证书的签名 | 验签用 |
| AIA | 到哪去下载中间证书 | **浏览器靠它自动补链** |

**只看 CN 是不够的**：现代浏览器只看 SAN。CN 里写了 `example.com` 但 SAN 里没有，照样报错。

### 5.4.2 证书链

```text
根证书（Root CA）         ← 内置在操作系统/浏览器里，自签
    │ 签发
中间证书（Intermediate）  ← 服务器要下发
    │ 签发
叶证书（Leaf / 服务器证书） ← 服务器要下发
```

**验证是自下而上走的**：浏览器拿到叶证书 → 用中间证书的公钥验叶证书的签名 → 用根证书的公钥验中间证书 → 根证书在本地信任库里 → 通过。

所以服务端必须下发 **叶证书 + 中间证书**（合成 `fullchain.pem`），否则链断了。根证书不用下发，客户端本来就有。

### 5.4.3 为什么「浏览器正常，curl 报错」

这是证书问题里最经典、也最容易吵起来的一个。

**原因**：浏览器会读叶证书里的 AIA 字段，自动去下载缺失的中间证书补上；**curl 不会，Java 不会，微信小程序不会，很多移动端 SDK 也不会。**

所以「我这打开是正常的」永远不能证明证书链是完整的。

```bash
# 正确验证方式：模拟一个不会自动补链的客户端
openssl s_client -connect www.example.com:443 -servername www.example.com -showcerts </dev/null

# 看返回的链里有几张证书
# 只有一张（叶证书）→ 缺中间证书 → 必然会出问题
# 两张及以上 → 链完整

# 直接验证链是否可信
openssl s_client -connect www.example.com:443 -servername www.example.com </dev/null 2>&1 | grep -i "verify"
# Verify return code: 0 (ok)
```

更狠的验证（完全不用本地信任库，只信服务端下发的）：

```bash
openssl s_client -connect www.example.com:443 -servername www.example.com \
  -CAfile /path/to/root.pem </dev/null
```

---

## 5.5 证书生命周期

### 5.5.1 类型

| 维度 | 选项 | 说明 |
|---|---|---|
| 验证等级 | DV / OV / EV | DV 只验域名控制权，几分钟签发；OV/EV 需验企业资质 |
| 覆盖范围 | 单域名 / 多域名（SAN）/ 通配符（`*.example.com`） | 通配符**只覆盖一级**，`*.example.com` 不含 `a.b.example.com` |
| 有效期 | 通常 1 年（公网 CA） | Let's Encrypt 是 90 天 |

**通配符的坑**：`*.example.com` 匹配 `www.example.com`、`api.example.com`，但**不匹配** `example.com` 本身，也不匹配 `a.b.example.com`。要覆盖根域，证书里得单独加一条。

### 5.5.2 换证不断服的标准流程

这是运维最常做、也最容易出事的一次操作。目标是**全程没有请求因为证书问题失败**。

```text
① 提前拿到新证书（含中间证书，合成 fullchain）
    ↓
② 本地验证链完整、域名匹配、有效期正确
   openssl x509 -in fullchain.pem -noout -text | grep -A1 "Subject Alternative Name"
    ↓
③ 在非生产环境（或同一台机的另一个端口）用新证书起一个测试 server，
   用 openssl s_client 验证通过
    ↓
④ 生产替换：直接把 fullchain.pem 覆盖，然后 nginx -s reload
    ↓
⑤ reload 后立即验证
   openssl s_client -connect 域名:443 -servername 域名 </dev/null | grep "Verify return"
    ↓
⑥ 观察 5–10 分钟错误日志
```

**关键点**：`nginx -s reload` 是**平滑重载**——旧 worker 会处理完存量连接再退出，新连接用新证书。所以单纯换证书不需要重启，也不该有中断。

**但要注意**：reload 只对 Nginx 自己生效。如果证书同时配在 CDN、LB、四层设备上，每一处都要换，漏一处就有一批用户报错。

### 5.5.3 到期监控

证书过期是运维事故里最不该发生、却最常见的一类。**必须有监控，不能靠记性。**

```bash
# 单条命令查剩余天数
echo | openssl s_client -connect www.example.com:443 -servername www.example.com 2>/dev/null \
  | openssl x509 -noout -enddate
# notAfter=Mar  1 12:00:00 2027 GMT

# 更实用的写法：直接算剩余天数
echo | openssl s_client -connect www.example.com:443 -servername www.example.com 2>/dev/null \
  | openssl x509 -noout -checkend 2592000 && echo "30天内不过期" || echo "★★★ 30天内到期"
```

监控要覆盖**所有**装着证书的地方：CDN 边缘、LB、Nginx、后端服务间 mTLS、内部系统。**最容易漏的是不对外的那几个。**

---

## 5.6 常见故障与判据

| 报错 | 原因 | 判据 |
|---|---|---|
| `unable to get local issuer certificate` | **缺中间证书** | `-showcerts` 只返回一张 |
| `certificate has expired` | 证书过期 | `-enddate` 看日期 |
| `certificate is not yet valid` | 本机时间错了 | `date` 看系统时间 |
| `Hostname mismatch` / `certificate is valid for X` | 域名不在 SAN 里 | `-text` 看 SAN |
| `handshake failure` | 没有共同支持的协议版本或套件 | 双方版本差太大（如客户端只支持 TLS 1.0） |
| `sslv3 alert handshake failure` | SNI 缺失或套件不匹配 | 加 `-servername` 重试 |
| `Connection reset by peer`（握手阶段） | 中间设备拦截、证书配置错导致 worker 崩 | 看 Nginx error log |
| 只有部分用户报错 | 客户端版本差异 / 部分地区 DNS 指到旧节点 | 换网络、换客户端复现 |

### 5.6.1 时间不同步导致的诡异问题

TLS 校验依赖时间。**服务器时间比真实时间差了几分钟，就可能报「证书未生效」或「证书已过期」**，而证书本身完全正常。

```bash
date -u                                    # 看系统 UTC 时间
timedatectl status                         # 看 NTP 同步状态
chronyc tracking                           # chrony 的偏差
```

这类问题的特征是：**换一台机器测就正常，只有某几台报错**。看到这种分布，先怀疑时间。

---

## 5.7 终止点与 Nginx 配置

### 5.7.1 终止在哪，决定了什么

```text
用户 ──TLS──> CDN ──TLS──> LB ──TLS──> 后端
              │            │
           边缘证书      站点证书
```

| 终止位置 | 优点 | 代价 |
|---|---|---|
| CDN 边缘 | 握手离用户最近，最快 | 源站证书也要配，且 CDN 到源站这段要单独加密 |
| 四层 LB | 集中管理，后端无感 | LB 是 CPU 消耗点，要评估容量 |
| 七层 Nginx | 能读到 Host 做路由 | 内网这一段是明文，除非再起一层 TLS |
| 后端应用 | 端到端加密 | 每台都要配证书，运维成本高 |

**关键认知**：终止点之后就是明文。所谓「内网安全」在很多合规要求下是不成立的——**能抓到内网包的人就能看到全部内容**。

### 5.7.2 生产配置

```nginx
server {
    listen 443 ssl;
    http2 on;
    server_name www.example.com;

    # 证书：必须是 fullchain（叶 + 中间），否则部分客户端报错
    ssl_certificate     /etc/nginx/ssl/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/privkey.pem;

    # 协议版本：只留 1.2 和 1.3
    ssl_protocols TLSv1.2 TLSv1.3;

    # 套件：只对 TLS 1.2 及以下生效，1.3 的套件是固定的
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;

    # 默认 on 会让服务端的偏好优先，通常更慢；off 让客户端偏好优先，更快
    ssl_prefer_server_ciphers off;

    # 会话复用：多台机器要共享 ticket key
    ssl_session_cache   shared:SSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets on;

    # OCSP stapling：把吊销状态查询结果缓存到服务端，省掉客户端的一次查询
    ssl_stapling on;
    ssl_stapling_verify on;
    ssl_trusted_certificate /etc/nginx/ssl/chain.pem;
    resolver 223.5.5.5 valid=300s;

    # HSTS：告诉浏览器以后只用 HTTPS 访问
    # 注意：一旦下发且带长 max-age，回退极难，先在测试环境验证
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
}
```

**逐项理由：**

| 配置 | 为什么这么写 |
|---|---|
| `fullchain.pem` | 只配叶证书 = 缺中间证书，curl / 小程序 / Java 全报错 |
| 只留 1.2/1.3 | TLS 1.0/1.1 已不被 PCI DSS 接受，且存在已知弱点 |
| `ssl_prefer_server_ciphers off` | 服务端强制偏好会增加握手开销；客户端偏好通常已经是最优的 |
| `ssl_session_cache shared` | 每 worker 独立缓存会导致复用率极低 |
| `ssl_stapling on` | 省客户端一次 OCSP 查询，握手更快；但 resolver 必须配，否则不生效 |
| HSTS `includeSubDomains` | **危险**：所有子域都被强制 HTTPS，有子域还用 HTTP 就会挂 |

### 5.7.3 HSTS 是最需要谨慎的一项

HSTS 一旦被浏览器记住，**在 `max-age` 期间内，浏览器会拒绝任何 HTTP 访问**，不管你怎么改服务端配置都无效——只能等浏览器缓存过期，或让用户手动清。

上线顺序应该是：

```text
① 先设 max-age=300（5 分钟），观察有没有 HTTP 子域被漏掉
② 确认没问题，逐步加到 86400 → 604800 → 31536000
③ 确认所有子域都支持 HTTPS 后，再加 includeSubDomains
④ 最后才考虑 preload（这个一旦进浏览器预置列表，撤回要几个月）
```

---

## 5.8 mTLS 双向认证

普通 TLS 只验服务端（客户端确认"你是真的"）。mTLS 加一层：**服务端也验客户端**。

| 场景 | 用途 |
|---|---|
| 服务间通信 | 防止内网任意服务调你的接口 |
| API 对接 | 合作方必须持有我们签发的客户端证书 |
| 零信任 | 设备证书作为身份凭证 |

```nginx
ssl_client_certificate /etc/nginx/ssl/ca.pem;   # 用来验证客户端证书的 CA
ssl_verify_client on;                            # on = 强制，optional = 有则验
ssl_verify_depth 2;
```

```bash
# 测试
curl --cert client.pem --key client-key.pem https://api.example.com/
```

**mTLS 的运维成本在于证书分发和轮换**：每个客户端都要一张证书，到期都要换，规模一大就必须有自动化。没有自动化就别上 mTLS，否则迟早会因为某张客户端证书过期导致对接中断。

---

## 5.9 合规基线

| 项目 | 要求 | 说明 |
|---|---|---|
| 协议版本 | 只用 TLS 1.2 / 1.3 | 1.0/1.1 已被主流合规标准淘汰 |
| 密钥交换 | 必须 ECDHE | 保证前向保密 |
| 对称算法 | AES-GCM 或 ChaCha20 | 禁用 CBC（有 padding oracle 风险） |
| 证书密钥 | RSA ≥ 2048 或 ECDSA ≥ 256 | 1024 位已不安全 |
| 证书有效期 | 公网 ≤ 398 天 | CA/B 论坛规定，逐年缩短 |
| HSTS | 建议启用 | 需先验证所有子域 |

---

## 5.10 命令与坑

```bash
# 看完整证书链
openssl s_client -connect www.example.com:443 -servername www.example.com -showcerts </dev/null

# 只看叶证书信息
openssl s_client -connect www.example.com:443 -servername www.example.com </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -issuer -dates

# 看 SAN（实际生效的域名）
openssl s_client -connect www.example.com:443 -servername www.example.com </dev/null 2>/dev/null \
  | openssl x509 -noout -text | grep -A1 "Subject Alternative Name"

# 查证书剩余天数
echo | openssl s_client -connect www.example.com:443 -servername www.example.com 2>/dev/null \
  | openssl x509 -noout -checkend 2592000

# 测支持的协议版本
for v in tls1_2 tls1_3; do
  echo -n "$v: "
  echo | openssl s_client -connect www.example.com:443 -$v 2>&1 | grep -q "Cipher is" && echo OK || echo FAIL
done

# 测 TLS 1.0/1.1 是否还能连（连得上说明该关了）
echo | openssl s_client -connect www.example.com:443 -tls1 2>&1 | grep -q "Cipher is" && echo "★ 仍支持 TLS 1.0"

# 本地校验证书与私钥是否配对
openssl x509 -noout -modulus -in fullchain.pem | md5sum
openssl rsa -noout -modulus -in privkey.pem    | md5sum
# 两个值相同才是配对的
```

### 5.10.1 七个坑

| # | 坑 | 现象 | 处置 |
|---|---|---|---|
| 1 | 只配叶证书 | 浏览器正常，curl/小程序/Java 报 `unable to get local issuer` | 配 `fullchain.pem` |
| 2 | 用浏览器验证证书链 | 结论"没问题"，线上一直有零星报错 | 必须用 `openssl s_client -showcerts` |
| 3 | HSTS 一上线就设一年 | 某个 HTTP 子域直接访问不了，且回退不了 | 从 `max-age=300` 起步，逐级加 |
| 4 | `includeSubDomains` 贸然加 | 所有 HTTP 子域全部不可用 | 确认全部子域支持 HTTPS 再加 |
| 5 | 证书换了但 CDN/ LB 没换 | 部分用户报错，部分正常 | 层数越多越容易漏，逐层核对 |
| 6 | 服务器时间不同步 | 只有个别机器报证书过期 | 查 NTP，`date` 对比 |
| 7 | 以为 `ssl_ciphers` 能控 TLS 1.3 | 改了没效果 | 1.3 套件固定，要用 `ssl_conf_command` |

---

## 5.11 本章检查清单

读完能回答这六个问题，这一章就过了：

| # | 问题 |
|---|---|
| 1 | TLS 要解决的三件事是什么？为什么非对称加密只在握手开头用一下？ |
| 2 | 证书链校验到哪一级？只配叶证书为什么浏览器正常、curl/Java 却报 `unable to get local issuer`？ |
| 3 | 用浏览器验证证书链为什么不可靠？该用哪条 `openssl s_client` 命令？ |
| 4 | SNI 解决什么问题？一台 Nginx 承载多域名证书靠什么区分？ |
| 5 | TLS 终止点放在 Nginx 之后，后端收到的流量是什么形态？这改变了哪些排障判据？ |
| 6 | mTLS 比普通 TLS 多了哪一步？HSTS 为什么不能一上线就设一年？`x509 -noout -checkend` 判什么？ |

---

**下一篇**：[006-负载均衡与高可用](006-负载均衡与高可用.md) —— 单点配好了，流量怎么分摊。