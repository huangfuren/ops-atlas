# 004 事务、锁与 MVCC

> 数据库"卡住"最常见的三个原因：锁等待、死锁、长事务。这一篇讲清它们的机制和排查方法。

## 目录

| 章 | 内容 |
|---|---|
| 4.1 | ACID：四个字母的实际含义 |
| 4.2 | 四种隔离级别 |
| 4.3 | MVCC：为什么读不加锁 |
| 4.4 | RR vs RC：生产该用哪个 |
| 4.5 | 锁的类型 |
| 4.6 | 锁的兼容性 |
| 4.7 | 死锁 |
| 4.8 | 元数据锁 MDL（DDL 被卡的元凶） |
| 4.9 | 长事务 |
| 4.10 | 排查命令速查 |
| 4.11 | 九个坑 |
| 4.12 | 本章检查清单 |

---

## 4.1 ACID：四个字母的实际含义

| 字母 | 含义 | 靠什么实现 | 运维关心什么 |
|---|---|---|---|
| **A** 原子性 | 要么全做，要么全不做 | undo log | 回滚是否彻底 |
| **C** 一致性 | 约束不被破坏 | 应用 + 数据库约束 | 唯一索引、外键、CHECK |
| **I** 隔离性 | 并发事务互不干扰 | 锁 + MVCC | **死锁、锁等待** |
| **D** 持久性 | 提交后不丢 | redo log + 刷盘参数 | **宕机会丢多少数据** |

**运维实际要管的是 I 和 D**：

- **I（隔离性）**出问题的表现是：死锁、锁等待超时、并发写入互相阻塞。
- **D（持久性）**出问题的表现是：宕机后丢了最后几秒的数据。这由 `innodb_flush_log_at_trx_commit` 和 `sync_binlog` 决定（001 的 1.6.2）。

## 4.2 四种隔离级别

```sql
SHOW VARIABLES LIKE 'transaction_isolation';
-- 默认 REPEATABLE-READ
```

| 级别 | 脏读 | 不可重复读 | 幻读 | 并发性能 |
|---|---|---|---|---|
| `READ UNCOMMITTED` | 会 | 会 | 会 | 最高 |
| `READ COMMITTED`（RC） | 不会 | 会 | 会 | 高 |
| **`REPEATABLE READ`（RR）** | 不会 | 不会 | **InnoDB 基本避免** | 中 |
| `SERIALIZABLE` | 不会 | 不会 | 不会 | 最低 |

### 4.2.1 三个"读"问题是什么

| 问题 | 定义 | 例子 |
|---|---|---|
| **脏读** | 读到了别人未提交的数据 | A 转账给 B，还没提交，B 就看到了钱 |
| **不可重复读** | 同一事务内两次读同一行，结果不同 | 事务内查了两次余额，中间别人改了一笔 |
| **幻读** | 同一事务内两次查同一范围，行数变了 | 查"id>100 的记录有 5 条"，再查变 6 条 |

### 4.2.2 InnoDB 的 RR 如何避免幻读

标准 SQL 的 RR 允许幻读，但 InnoDB 用**间隙锁（Gap Lock）** 在 RR 下把它基本解决了。

```sql
-- RR 级别下
BEGIN;
SELECT * FROM orders WHERE user_id = 100 FOR UPDATE;
-- 不仅锁住现有的行，还锁住 user_id=100 这个"间隙"
-- 其他事务不能插入 user_id=100 的新行 → 不会幻读
```

**代价是死锁概率上升**——间隙锁范围大，两个事务很容易交叉等待。

## 4.3 MVCC：为什么读不加锁

**MVCC（多版本并发控制）让普通 `SELECT` 不加锁也能读到一致的数据。**

### 4.3.1 两个隐藏字段

InnoDB 每行都有两个隐藏列：

| 列 | 含义 |
|---|---|
| `DB_TRX_ID` | 最后一次修改这行的事务 ID |
| `DB_ROLL_PTR` | 指向 undo log 里的旧版本（版本链） |

### 4.3.2 版本链

```
当前行：  [name=张三, trx_id=105] → undo: [name=李四, trx_id=102] → undo: [name=王五, trx_id=98]
                                      ↑ 沿 roll_ptr 往回找
```

### 4.3.3 ReadView：判断"我能看到哪个版本"

事务开始时（RR）或每条语句开始时（RC），生成一个 ReadView，包含：

| 字段 | 含义 |
|---|---|
| `m_ids` | 当前活跃（未提交）的事务 ID 列表 |
| `min_trx_id` | 活跃事务里最小的 ID |
| `max_trx_id` | 下一个要分配的事务 ID |
| `creator_trx_id` | 自己的事务 ID |

判断规则（沿版本链找第一个可见的版本）：

```
对于版本链上某版本的 trx_id：
1. trx_id == creator_trx_id → 自己改的，可见
2. trx_id < min_trx_id      → 事务已提交，可见
3. trx_id >= max_trx_id     → 在我之后才开始，不可见
4. min_trx_id <= trx_id < max_trx_id
   ├─ 在 m_ids 里 → 还没提交，不可见
   └─ 不在 m_ids 里 → 已提交，可见
```

**这就是"快照读"的实现**。普通 `SELECT` 走这条路，不加锁。

### 4.3.4 快照读 vs 当前读

| 类型 | 语句 | 读什么 |
|---|---|---|
| **快照读** | 普通 `SELECT` | MVCC 版本链，不加锁 |
| **当前读** | `SELECT ... FOR UPDATE`、`SELECT ... LOCK IN SHARE MODE`、`UPDATE`、`DELETE`、`INSERT` | **最新已提交版本，加锁** |

```sql
-- 快照读：读到的是事务开始时的数据，不加锁
SELECT * FROM accounts WHERE id = 1;

-- 当前读：读最新数据，加排他锁
SELECT * FROM accounts WHERE id = 1 FOR UPDATE;
```

**这是运维最容易混淆的地方**：看到"数据库里明明是 100，程序读到的是 90"，那就是快照读——程序在事务里，读到的是事务开始时的版本。

## 4.4 RR vs RC：生产该用哪个

| | RR（默认） | RC |
|---|---|---|
| 一致性读 | 事务内多次读结果相同 | 每次读最新已提交 |
| 锁范围 | **有间隙锁** | 只有行锁，无间隙锁 |
| 死锁概率 | **较高** | 低 |
| 主从复制要求 | `binlog_format=ROW` 才安全 | 安全 |
| 适用场景 | 需要事务内一致快照 | 高并发写入、短事务 |

**实践建议**：

| 场景 | 建议 |
|---|---|
| 互联网高并发业务（订单、支付） | **RC**。间隙锁导致的死锁是主要痛点，业务层通常不依赖"事务内重复读一致" |
| 传统企业应用、报表 | RR（默认） |
| 从 5.6 之前迁移的老系统 | RR（改 RC 可能暴露老代码的一致性假设） |

**改 RC 的方法**：

```sql
SET GLOBAL transaction_isolation = 'READ-COMMITTED';
-- 持久化：my.cnf 里 transaction_isolation = READ-COMMITTED
```

**改之前必须确认**：`binlog_format = ROW`。RC + `STATEMENT` 格式会导致主从不一致。

## 4.5 锁的类型

### 4.5.1 按粒度分

| 锁 | 粒度 | 说明 |
|---|---|---|
| **行锁**（Record Lock） | 单行 | InnoDB 默认，锁索引记录 |
| **间隙锁**（Gap Lock） | 索引区间 | 锁住"两个索引值之间的空隙"，防止插入 |
| **临键锁**（Next-Key Lock） | 行 + 前面的间隙 | **RR 下默认的行锁实现**，左开右闭区间 |
| **表锁**（Table Lock） | 整表 | `LOCK TABLES`、DDL、`ALTER TABLE` |
| **意向锁**（Intention Lock） | 表级标记 | 表示"表里有些行被锁了"，快速判断能否加表锁 |

**关键理解：InnoDB 的行锁是加在索引上的，不是加在行上的。**

```sql
-- id 有主键索引 → 只锁 id=100 这一行
UPDATE users SET name='x' WHERE id = 100;

-- name 没索引 → 全表扫描 → 锁住所有行（实际上锁了所有扫描到的记录）
UPDATE users SET name='x' WHERE name = '张三';
```

**第二条是运维事故的高发点**：一个没走索引的 `UPDATE`，会锁住全表，所有并发写全部阻塞。

### 4.5.2 按模式分

| 模式 | 语句 | 兼容性 |
|---|---|---|
| **共享锁（S）** | `SELECT ... LOCK IN SHARE MODE` | 多个 S 可共存 |
| **排他锁（X）** | `SELECT ... FOR UPDATE`、`UPDATE`、`DELETE` | 与任何锁都互斥 |

## 4.6 锁的兼容性

|  | S 锁 | X 锁 |
|---|---|---|
| **S 锁** | 兼容 | **冲突** |
| **X 锁** | **冲突** | **冲突** |

**意向锁的兼容性**（表级）：

|  | IS | IX | S | X |
|---|---|---|---|---|
| **IS** | 兼容 | 兼容 | 兼容 | 冲突 |
| **IX** | 兼容 | 兼容 | 冲突 | 冲突 |
| **S** | 兼容 | 冲突 | 兼容 | 冲突 |
| **X** | 冲突 | 冲突 | 冲突 | 冲突 |

**为什么需要意向锁**：如果我要给整张表加锁，不需要逐行检查有没有行锁，只要看表上有没有意向锁。

## 4.7 死锁

### 4.7.1 死锁是怎么产生的

```
事务 A：                     事务 B：
BEGIN;                       BEGIN;
UPDATE t SET x=1 WHERE id=1;      -- 拿到 id=1 的 X 锁
                             UPDATE t SET x=2 WHERE id=2;   -- 拿到 id=2 的 X 锁
UPDATE t SET x=3 WHERE id=2;      -- 等 id=2
                             UPDATE t SET x=4 WHERE id=1;   -- 等 id=1
                             ↑ 互相等待，死锁
```

MySQL 会自动检测（`innodb_deadlock_detect`），**杀掉其中一个事务**，报错：

```
ERROR 1213 (40001): Deadlock found when trying to get lock; try restarting transaction
```

**所以死锁不是"数据库挂了"，是正常保护机制。** 应用要能捕获 1213 并重试。

### 4.7.2 怎么查死锁

```sql
SHOW ENGINE INNODB STATUS\G
```

找 `LATEST DETECTED DEADLOCK` 段：

```
------------------------
LATEST DETECTED DEADLOCK
------------------------
2026-10-28 14:23:11 0x7f8a2c0b7700
*** (1) TRANSACTION:
TRANSACTION 4832, ACTIVE 3 sec starting index read
mysql tables in use 1, locked 1
LOCK WAIT 3 lock struct(s), heap size 1136, 2 row lock(s)
MySQL thread id 128, OS thread handle 1402..., query id 8842 localhost app updating
UPDATE t SET x=3 WHERE id=2
*** (1) HOLDS THE LOCK(S):
RECORD LOCKS space id 2 page no 4 n bits 72 index PRIMARY of table `app`.`t`
trx id 4832 lock_mode X locks rec but not gap
Record lock, heap no 2 PHYSICAL RECORD: n_fields 4; ...
*** (1) WAITING FOR THIS LOCK TO BE GRANTED:
RECORD LOCKS ... index PRIMARY ... trx id 4832 lock_mode X locks rec but not gap waiting
...
*** WE ROLL BACK TRANSACTION (2)
```

**读法**：

| 部分 | 看什么 |
|---|---|
| `(1) TRANSACTION` / `(2) TRANSACTION` | 两个互相等待的事务 |
| `HOLDS THE LOCK(S)` | 它已经持有什么锁 |
| `WAITING FOR THIS LOCK` | 它在等什么锁 |
| `WE ROLL BACK TRANSACTION (2)` | **MySQL 选择了回滚哪个**（通常是修改行数少的） |

**排查重点**：两条 SQL 的 `WHERE` 条件是不是锁了不同的索引、加锁顺序是否相反。

### 4.7.3 死锁的四个常见原因

| 原因 | 例子 | 解法 |
|---|---|---|
| **加锁顺序相反** | A 先锁 id=1 再锁 id=2，B 反过来 | **统一加锁顺序**（按主键升序处理） |
| **缺索引导致锁全表** | `UPDATE t SET x=1 WHERE name='x'`（name 无索引） | 补索引 |
| **间隙锁冲突（RR）** | 两个事务插入相邻区间的值 | 改 RC，或调整业务逻辑 |
| **唯一索引冲突 + 事务回滚** | 并发 `INSERT ... ON DUPLICATE KEY UPDATE` | 加 `SELECT ... FOR UPDATE` 提前拿锁 |

### 4.7.4 减少死锁的五个做法

```sql
-- 1. 保持事务短小：不要在事务里做 RPC、发消息、等用户输入
-- 2. 按固定顺序访问数据
-- 3. 一次锁定所需的所有行（SELECT ... FOR UPDATE 提前拿）
-- 4. 用主键或唯一索引访问，避免锁范围
-- 5. 降低隔离级别到 RC，减少间隙锁
```

**应用侧必须做的**：

```go
// 捕获 1213 并重试（大部分 ORM 不会自动做）
if isDeadlock(err) {
    time.Sleep(time.Duration(rand.Intn(50)) * time.Millisecond)
    return retry()
}
```

## 4.8 元数据锁 MDL

**这是"DDL 被卡住"和"整个库突然全部超时"的最常见原因。**

### 4.8.1 MDL 是什么

当你执行 `SELECT` / `UPDATE` 时，MySQL 会自动给表加**元数据锁（Metadata Lock）**，保证表结构不被并发修改。

| 语句 | MDL 类型 | 说明 |
|---|---|---|
| `SELECT` | MDL 读锁 | 共享，可并发 |
| `UPDATE` / `DELETE` / `INSERT` | MDL 读锁 | 共享 |
| `ALTER TABLE` / `DROP` / `RENAME` | MDL 写锁 | **排他** |

**关键规则：MDL 读锁和写锁互斥。**

### 4.8.2 经典事故链

```
时刻 1：长事务 A 执行 SELECT（持有 MDL 读锁），但事务一直没提交
时刻 2：DDL 请求 MDL 写锁 → 被 A 阻塞，开始等待
时刻 3：新的普通 SELECT 也要 MDL 读锁
        但 MDL 有"写优先"规则 → 新请求排在 DDL 后面等待
时刻 4：所有后续查询全部阻塞 → 数据库"假死"
```

**这是最危险的一类故障**：一条 `ALTER TABLE` 加上一个长事务，可以让整张表的所有访问停摆。

### 4.8.3 怎么查

```sql
SELECT * FROM performance_schema.metadata_locks
WHERE OBJECT_SCHEMA = 'your_db' AND OBJECT_TYPE = 'TABLE'
ORDER BY OBJECT_NAME;
```

或者查等待：

```sql
SELECT
  waiting_pid, waiting_query,
  blocking_pid, blocking_query
FROM sys.innodb_lock_waits;
```

更直接的方式（8.0）：

```sql
SELECT
  t.PROCESSLIST_ID AS pid,
  t.PROCESSLIST_INFO AS info,
  t.PROCESSLIST_TIME AS secs,
  t.PROCESSLIST_STATE AS state
FROM performance_schema.threads t
WHERE t.PROCESSLIST_STATE LIKE '%metadata%'
   OR t.PROCESSLIST_INFO IS NOT NULL
ORDER BY t.PROCESSLIST_TIME DESC;
```

**看到大量 `Waiting for table metadata lock`，就去杀那个 `Sleep` 的长事务。**

### 4.8.4 预防

| 做法 | 说明 |
|---|---|
| 事务要短 | 别在事务里做耗时操作 |
| DDL 前检查长事务 | `SELECT * FROM information_schema.INNODB_TRX` |
| DDL 加超时 | `SET SESSION lock_wait_timeout = 10;` 避免无限等待 |
| 大表用 gh-ost | 不直接对原表做 DDL |
| 业务低峰执行 DDL | 减少影响面 |

**`lock_wait_timeout` 是保命的参数**：

```sql
SET SESSION lock_wait_timeout = 10;   -- 等 10 秒拿不到就放弃
ALTER TABLE orders ADD INDEX idx_x (x);
-- 报错 ERROR 1205: Lock wait timeout exceeded
-- 而不是把整个表卡死 30 分钟
```

## 4.9 长事务

### 4.9.1 怎么找

```sql
SELECT
  trx_id,
  trx_state,
  trx_started,
  TIMESTAMPDIFF(SECOND, trx_started, NOW()) AS seconds,
  trx_rows_locked,
  trx_rows_modified,
  trx_mysql_thread_id,
  LEFT(trx_query, 200) AS query
FROM information_schema.INNODB_TRX
ORDER BY trx_started
LIMIT 10;
```

**注意**：`trx_query` 可能为空，说明事务处于空闲状态（`Sleep`）但没提交——**这是最危险的**，因为它拿着锁却什么都没做。

### 4.9.2 三个危害

| 危害 | 机制 | 表现 |
|---|---|---|
| **undo 膨胀** | 旧版本不能清理 | 磁盘持续增长，`undo_001` 几百 GB |
| **阻塞 DDL** | 持有 MDL 读锁 | `ALTER TABLE` 一直等 |
| **主从延迟** | 大事务在从库重放慢 | `Seconds_Behind_Master` 飙升 |

### 4.9.3 什么样的算"长"

| 时长 | 处理 |
|---|---|
| < 10 秒 | 正常 |
| 10–60 秒 | 关注，看是什么业务 |
| **> 60 秒** | **告警** |
| > 10 分钟 | 立即处理（杀或联系开发） |

### 4.9.4 处理

```sql
-- 先看它在干什么
SELECT * FROM information_schema.INNODB_TRX WHERE trx_mysql_thread_id = 12345;

-- 杀会话（会回滚，大事务回滚可能很久）
KILL 12345;

-- 如果只是空闲事务，杀掉很快
```

**注意**：回滚一个跑了 1 小时的 100 万行 `DELETE`，可能要再花 1 小时。杀之前评估。

## 4.10 排查命令速查

### 4.10.1 锁相关

```sql
-- 当前锁等待（8.0，最直观）
SELECT * FROM sys.innodb_lock_waits\G

-- 当前事务
SELECT * FROM information_schema.INNODB_TRX\G

-- 当前锁（8.0 数据字典）
SELECT * FROM performance_schema.data_locks;
SELECT * FROM performance_schema.data_lock_waits;

-- 死锁历史
SHOW ENGINE INNODB STATUS\G    -- 找 LATEST DETECTED DEADLOCK

-- 锁等待超时时间
SHOW VARIABLES LIKE 'innodb_lock_wait_timeout';   -- 默认 50 秒
```

### 4.10.2 元数据锁

```sql
SELECT * FROM performance_schema.metadata_locks
WHERE OBJECT_SCHEMA = 'your_db';

SELECT * FROM sys.schema_table_lock_waits;
```

### 4.10.3 事务与状态

```sql
-- 事务列表
SELECT * FROM information_schema.INNODB_TRX;

-- 会话列表（找 Sleep 的）
SELECT id, user, host, db, command, time, state, LEFT(info,100)
FROM information_schema.PROCESSLIST
WHERE command = 'Sleep' AND time > 60
ORDER BY time DESC;

-- 各状态计数
SHOW GLOBAL STATUS LIKE 'Innodb_row_lock%';
-- Innodb_row_lock_current_waits: 当前等待的锁数
-- Innodb_row_lock_waits: 累计等待次数
-- Innodb_row_lock_time_avg: 平均等待毫秒
```

### 4.10.4 死锁监控

```sql
SHOW GLOBAL STATUS LIKE 'Innodb_deadlocks';   -- 8.0 有累计计数
```

**这个值持续增长，说明业务有系统性的死锁问题**，不是偶发。

## 4.11 九个坑

| # | 坑 | 后果 | 正确做法 |
|---|---|---|---|
| 1 | `UPDATE` 的 `WHERE` 列没索引 | **锁全表**，所有写阻塞 | 条件列必须有索引 |
| 2 | 事务里做 HTTP 调用 / 发消息 | 锁持有几秒到几十秒 | 事务只包数据库操作 |
| 3 | DDL 不设 `lock_wait_timeout` | 等 30 分钟，期间全表阻塞 | 会话级设 10 秒 |
| 4 | 长事务不监控 | undo 暴涨、DDL 被卡 | 监控 `INNODB_TRX`，超 60 秒告警 |
| 5 | 认为"死锁是数据库的 bug" | 不重试，业务失败 | 应用捕获 1213 重试 |
| 6 | 两个事务加锁顺序不一致 | 稳定复现死锁 | 统一按主键升序处理 |
| 7 | RR 下大量间隙锁冲突 | 死锁频发 | 考虑改 RC |
| 8 | `SELECT ... FOR UPDATE` 用在没索引的列 | 锁全表 | 先补索引 |
| 9 | 杀掉大事务以为立刻好 | 实际在回滚，还是卡 | 杀后观察 `INNODB_TRX` 直到消失 |

第 1 条和第 8 条是同一条：**InnoDB 的行锁是锁在索引上的**。没索引，就退化成锁所有扫描到的记录，等于锁全表。

第 9 条很实际：`KILL` 一个正在执行大 `DELETE` 的会话，MySQL 需要回滚已经做的修改，这个回滚过程和原来的执行一样慢。**杀之前先看 `trx_rows_modified`。**

## 4.12 本章检查清单

| # | 问题 |
|---|---|
| 1 | RR 和 RC 的核心差别是什么？生产该用哪个？ |
| 2 | 什么是快照读和当前读？哪条语句会加锁？ |
| 3 | 为什么 `UPDATE` 的条件列没索引会锁全表？ |
| 4 | 死锁日志里的 `HOLDS` 和 `WAITING FOR` 分别看什么？ |
| 5 | 什么是 MDL？为什么一条 DDL 能让全库超时？ |
| 6 | 怎么找出跑了超过 60 秒的事务？ |
| 7 | 长事务的三个危害？ |
| 8 | 间隙锁在什么隔离级别下生效？为什么它会导致死锁？ |
| 9 | 杀掉一个执行中的大 `DELETE`，为什么还是卡？ |

---

> 下一篇：《005 备份恢复与数据迁移》——备份能不能用，只有恢复演练能证明。
