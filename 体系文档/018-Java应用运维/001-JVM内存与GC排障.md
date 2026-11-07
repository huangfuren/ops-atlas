# 001 JVM 内存与 GC 排障

> **解决**：Java 进程的内存地图、GC 行为、排障命令族——OOM 四型各自的处理。  
> **范围**：内存分区 · GC 器与参数 · 命令族（jps/jstat/jmap/jstack/jcmd）· OOM 四型 · dump 分析 · 容器要点。  
> **口径**：JDK 17 主线（G1 默认），8.x 差异注记；示例命令直接可用。

## 目录

| 节 | 内容 |
|---|---|
| 1 | 内存分区：四区地图 |
| 2 | GC 器与关键参数 |
| 3 | 排障命令族 |
| 4 | OOM 四型：报错区域决定处理 |
| 5 | 容器里的 Java：退出码 137 |
| 6 | dump 分析 |
| 7 | 坑表 |
| 8 | 检查清单 |

---

## 1. 内存分区：四区地图

| 区 | 存什么 | 参数 | 谁管 |
|---|---|---|---|
| **堆** | 对象实例 | `-Xmx/-Xms` | GC 回收 |
| **元空间** | 类元数据（本地内存） | `-XX:MaxMetaspaceSize` | 类卸载时回收 |
| **线程栈** | 每线程调用帧 | `-Xss`（默认 1MB） | 线程结束回收 |
| **直接内存** | NIO 堆外缓冲 | `-XX:MaxDirectMemorySize` | 不归 GC 直接管 |

分区图见 [000 全貌](000-Java应用全貌.md)。**排障第一步：确定 OOM/泄漏发生在哪个区**——报错信息直接写明。

## 2. GC 器与关键参数

| GC 器 | 特点 | 场景 |
|---|---|---|
| **G1**（9+ 默认） | 分 Region 增量回收，可预期停顿目标（`-XX:MaxGCPauseMillis=200`） | 大堆通用首选 |
| Parallel | 吞吐优先，停顿长 | 批处理 |
| ZGC | 亚毫秒停顿，超大堆 | 低延迟大内存服务 |
| Serial | 单线程 | 小内存客户端 |

生产参数基线（8GB 堆示例）：

```bash
-Xms8g -Xmx8g                        # 初始=最大，避免动态扩堆抖动
-XX:+UseG1GC                         # 17 默认，显式写明
-Xlog:gc*:file=/var/log/app/gc.log:time,uptime,level,tags:filecount=5,filesize=20m
-XX:MaxMetaspaceSize=512m
-XX:+HeapDumpOnOutOfMemoryError -XX:HeapDumpPath=/var/dump/
```

**GC 日志生产必开**——它回答"慢是不是 GC 引起的"，开销极小。

## 3. 排障命令族

```bash
jps -l                                # ① 找 PID
jstat -gcutil <pid> 1000 10           # ② GC 实况：各代占用/FGC 次数/耗时——看趋势
jmap -histo <pid> | head -20          # ③ 对象直方图（轻量，先看这个）
jmap -dump:live,format=b,file=/tmp/h.hprof <pid>   # ④ ⚠️ 全量 dump（STW，低峰做）
jstack <pid> > /tmp/stack.txt         # ⑤ 线程栈（查卡顿/死锁）
jcmd <pid> VM.uptime                  # ⑥ 统一入口：jcmd <pid> help 看全部
```

**决策树**：

```plain
CPU 高 → jstat 看 GC 频率（Full GC 连发=内存问题）
       → jstack 抓栈（无 GC 则看线程在忙什么：业务死循环 or 下游等待）
内存涨 → jmap -histo 看对象直方图（谁最多）
       → dump + MAT 对比两个时点（泄漏=同类型对象持续增长）
接口卡 → jstack 抓栈（BLOCKED=锁；WAITING=等下游）
```

## 4. OOM 四型：报错区域决定处理

| 报错 | 区域 | 常见原因 | 处理 |
|---|---|---|---|
| `Java heap space` | 堆 | 泄漏或堆太小 | dump 对比找增长点；加 -Xmx 前先确认不是泄漏 |
| `Metaspace` | 元空间 | 动态类生成泛滥（脚本/代理/CGLib） | 加 MaxMetaspaceSize + 查类加载泄漏 |
| `unable to create new native thread` | 线程栈 | 线程数超限（OS 限制或泄漏） | `jstack` 数线程、查线程池配置 |
| `Direct buffer memory` | 直接内存 | NIO 堆外没配上限 | MaxDirectMemorySize + 排查直接内存使用 |

**泄漏 vs 不够**的判定：dump 两个时点（间隔 1h）对比同类型对象数——持续增长=泄漏，稳定=容量不足。

## 5. 容器里的 Java：退出码 137

**JVM 的内存账与容器 limit 不是一回事**：`-Xmx` 只管堆——元空间、线程栈、直接内存、JIT 代码缓存在堆外。容器 limit 必须 ≥ 堆 + 全部堆外 + 余量。

| 现象 | 原因 | 处理 |
|---|---|---|
| 容器退出码 **137**（OOMKilled） | 进程总占用（含堆外）超容器 limit，被内核杀 | -Xmx 设为 limit 的 50~70%，预留堆外 |
| 明明设了 -Xmx 还 OOM | 堆外部分没算 | NMT 开启核对（`-XX:NativeMemoryTracking=summary`） |

JDK 10+ 默认感知容器 limit（UseContainerSupport）——G1 会按容器 limit 的比例设堆，但**堆外部分仍要你自己留**。

## 6. dump 分析

| 工具 | 场景 |
|---|---|
| **Eclipse MAT** | heap dump 主力：泄漏报告（Leak Suspects）一键出 |
| VisualVM | 轻量可视化：堆/线程实时 |
| Arthas | 在线诊断不改重启：watch 方法入参、火焰图（运维利器） |
| fastthread.io | thread dump 在线分析 |

分析入口三问：**谁最多**（histogram 排序）、**谁引用它**（paths to GC roots）、**两个时点差在哪**（对比 dump）。

## 7. 坑表

| # | 坑 | 后果 | 正确做法 |
|---|---|---|---|
| 1 | 生产跑 `jmap -dump` 全量 | STW 停顿，大堆几十秒 | 低峰做；或先用 `-histo` 轻量看 |
| 2 | OOM 后先重启不 dump | 证据销毁，泄漏查不了 | `-XX:+HeapDumpOnOutOfMemoryError` 预配 |
| 3 | -Xmx 与 -Xms 不同值 | 堆动态扩缩引发抖动 | 生产两者同值 |
| 4 | GC 日志没开 | 判断不了慢是不是 GC | 必开（§2 参数） |
| 5 | -Xmx 抄别人配置 | 每个应用的堆外构成不同 | 按自己应用 NMT 实测 |
| 6 | 8.x 用 Metaspace 的参数思维处理 7.x 永久代 | 参数不生效 | 先确认 JDK 版本再调参 |

## 8. 检查清单

| # | 问题 |
|---|---|
| 1 | 内存四区的参数与报错能对上号吗？ |
| 2 | GC 日志开了吗？格式能读懂吗？ |
| 3 | 排障命令族的决策树能画出来吗？ |
| 4 | OOM 四型的处理方式各自是什么？ |
| 5 | 容器 137 的账算得清吗（堆+堆外+余量）？ |
| 6 | dump 的分析入口三问会吗？ |

---

**下一篇**：[002 Tomcat 与应用交付](002-Tomcat与应用交付.md) —— 应用怎么交付、怎么回滚。
