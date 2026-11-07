# 002 Tomcat 与应用交付

> **解决**：Java 应用怎么交付、怎么部署回滚——war/fat jar 两种形态与 Tomcat 配置运维。  
> **范围**：两种交付形态 · Tomcat 结构与配置 · 日志体系 · 部署与回滚。  
> **口径**：Tomcat 9/10.x；Spring Boot 3.x（内嵌容器）；部署流程对接「CICD」007 发布纪律。

## 目录

| 节 | 内容 |
|---|---|
| 1 | 两种交付形态：war vs fat jar |
| 2 | Tomcat 结构与关键配置 |
| 3 | Tomcat 日志体系 |
| 4 | 部署与回滚 |
| 5 | 排错速查 |
| 6 | 坑表 |
| 7 | 检查清单 |

---

## 1. 两种交付形态：war vs fat jar

| | war（外置 Tomcat） | fat jar（Spring Boot 内嵌） |
|---|---|---|
| 部署 | 拷进 `webapps/`，容器托管 | `java -jar app.jar`，应用自带容器 |
| 多应用共存 | 一个 Tomcat 跑多个 war | 一应用一进程 |
| 升级 Tomcat | 影响所有 war | 每应用独立升级依赖 |
| 回滚 | 换回旧 war 目录 | 换回旧 jar |
| 运维要点 | Tomcat 本身也是被管对象 | systemd 单元 + jar 管理 |

**形态决定运维对象**：war 运维"Tomcat + 应用"两层；fat jar 运维"一个 jar + systemd"——JVM 排障（001）两者通用。

## 2. Tomcat 结构与关键配置

```plain
tomcat/
├── bin/          # 启停脚本（startup.sh/shutdown.sh；catalina.sh 带 JVM 参数）
├── conf/
│   ├── server.xml      # 端口、连接器、线程池
│   ├── tomcat-users.xml  # 管理界面账号（默认注释掉——保持）
│   └── logging.properties
├── logs/         # catalina.out（主日志）、localhost.*、access log
├── webapps/      # 应用目录（war 自动解压）
└── work/         # JSP 编译缓存
```

server.xml 三个运维关键点：

| 项 | 配置 | 说明 |
|---|---|---|
| 端口 | `<Server port="8005" shutdown="SHUTDOWN">` | ⚠️ 默认 SHUTDOWN 指令可远程关停——改密码或禁用 |
| 线程池 | `<Connector maxThreads="500" minSpareThreads="50">` | 线程数 ≈ 并发处理能力；按压测定，不是越大越好 |
| 连接超时 | `connectionTimeout="20000"` | 与应用处理时长匹配 |

JVM 参数走 `bin/setenv.sh`（`CATALINA_OPTS`）——001 §2 的参数基线放这里。

## 3. Tomcat 日志体系

| 日志 | 内容 | 用途 |
|---|---|---|
| `catalina.out` | 启动信息 + stdout/stderr + 应用 System.out | 排障主入口（建议 logback 接管） |
| `localhost.*.log` | 应用初始化/卸载异常 | **启动失败先看这里** |
| access log | HTTP 访问（需显式配置 AccessLogValve） | 流量分析（格式对接「日志」板块） |
| GC 日志 | JVM 层（001 §2 配置） | 内存排障 |

排障顺序：启动失败 → localhost.log；运行慢 → GC 日志 + thread dump；请求异常 → 应用日志 + access log。

## 4. 部署与回滚

war 流程（对接「CICD」007 发布纪律）：

| 步 | 动作 | 纪律 |
|---|---|---|
| 1 | 新 war 上传到 deploy 目录（不直接覆盖） | 制品带版本号（不可变制品，CICD 006） |
| 2 | `mv webapps/app webapps/app.bak.$(date +%s)` 备份旧版 | 回滚=换回目录 |
| 3 | 放入新 war → Tomcat 自动解压；或用管理界面 | 生产建议停应用再部署（数据一致性） |
| 4 | 验证：localhost.log 无异常 + health 接口 200 | 验证不通过 → 步骤 5 |
| 5 | ⚠️ 回滚：换回备份目录，重启应用 | 回滚路径在部署前写好 |

fat jar 流程（systemd 管理）：`systemctl stop app` → 替换 jar → `systemctl start app` → 验证；回滚 = jar 按版本保留（`/opt/app/app-1.2.3.jar`）+ systemd 指向切换。**jar/jar.bak 的目录纪律与 war 相同**。

## 5. 排错速查

| 现象 | 先看 | 常见根因 |
|---|---|---|
| 启动失败 | localhost.log | 端口占用、配置错误、依赖缺失 |
| 部署后 404 | webapps 目录与 war 名 | context 路径与预期不符 |
| 503/502（SLB 后） | 应用线程池打满 / 应用假死 | 线程池耗尽、下游阻塞（001 §3 jstack） |
| 频繁 Full GC | GC 日志（001） | 内存泄漏或缓存过大 |
| 内存持续涨 | jmap 直方图 + dump | 001 §4 |

## 6. 坑表

| # | 坑 | 后果 | 正确做法 |
|---|---|---|---|
| 1 | 8005 SHUTDOWN 端口用默认值 | 任何人 telnet 即可关停 Tomcat | 改随机串或禁用 |
| 2 | war 直接覆盖部署 | 覆盖过程半解压状态被访问 | 部署目录+原子切换 |
| 3 | catalina.out 不轮转 | 单文件数十 GB 排障灾难 | logback/logrotate 接管 |
| 4 | 管理界面（manager）开着 | 弱口令 = war 后门 | 生产禁用或强 ACL |
| 5 | 线程池拍脑袋调大 | 内存与下游连接数被拖垮 | 按压测与下游容量定 |
| 6 | 多应用共享 Tomcat 无隔离 | 一个应用 OOM 拖死全部 | 关键应用独立 Tomcat/进程 |

## 7. 检查清单

| # | 问题 |
|---|---|
| 1 | 你的应用是 war 还是 fat jar？运维对象各是什么？ |
| 2 | 8005 端口与 manager 界面处理了吗？ |
| 3 | 部署五步与回滚路径写在文档里了吗？ |
| 4 | 线程池 maxThreads 与数据库连接池匹配吗？ |
| 5 | catalina.out 的轮转方案在跑吗？ |
| 6 | JVM 参数（001）在 setenv.sh 里统一管理吗？ |

---

**回到**：[Java 应用板块总览](README.md) —— 两册完结，回到板块导航。
