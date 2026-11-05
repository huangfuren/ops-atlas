# A 命令速查

> **这一册回答**：这个命令叫什么、参数怎么写、在另一个发行版上叫什么名字。**只查不讲。**
> **怎么用**：按域翻（A.1–A.11），或者 `Ctrl+F` 搜你要的动作（「看端口」「查包」「扩容」）。这里每条只给「命令 + 关键参数」，为什么这么写、坑在哪，回正文对应册。
> **口径**：左列 **CentOS 7**、右列 **Ubuntu 22.04** 的差异都标出来了；完全相同的只写一行。装包这件事见 A.8，工具名与包名对不上时见 A.13。
> **不在这里**：为什么这么用、参数背后的行为、故障怎么判 → 回各册正文；文本处理的组合套路 → [007 §7.14](007-命令行与文本处理.md)；性能数据的判读 → [009 §9.14](009-性能分析与排障.md)。

> **关于结构**：其他册的「知识点地图 / 排错路径 / 自测」在这一册没有意义——它本身就是索引。所以本册只有三段：**用法说明 → 分域速查 → 双系对照与速记**。

**符号约定**

| 记号 | 含义 |
| --- | --- |
| `<x>` | 占位符，换成你的值（`<pid>` `<svc>` `<dir>` `<ip>`） |
| ⚠️ | 破坏性操作，执行前先想一秒，多数要先备份 |
| `#` 开头 | 需要 root（`sudo -i` 或 `sudo`） |
| `→` | 「换成」「对应」 |

---

## A.1 系统与硬件

| 我要 | 命令 | 备注 |
| --- | --- | --- |
| 看内核版本与架构 | `uname -a`；`uname -r`；`uname -m` | `-r` 只看内核版本 |
| 看发行版 | `cat /etc/os-release` | 两系通用，最可靠 |
| 看发行版（旧办法） | `cat /etc/redhat-release` | Ubuntu 无此文件 |
| 看发行版（旧办法，Ubuntu） | `lsb_release -a` | 需 `redhat-lsb-core` / `lsb-release` |
| 看主机名 | `hostnamectl`；`hostname` | `hostnamectl` 信息更全 |
| 改主机名 | `hostnamectl set-hostname <name>` | 两系通用，立即生效 |
| 看开机多久、负载 | `uptime` | 三个 load 数见 009 §9.3 |
| 看时间与时区 | `timedatectl` | 含 NTP 同步状态 |
| 改时区 | `timedatectl set-timezone Asia/Shanghai` | 两系通用 |
| 校时（一次性） | `chronyc makestep`；`ntpdate <ip>` | `ntpdate` 已淘汰，优先 `chronyc` |
| 看 CPU 型号与核数 | `lscpu`；`nproc` | `nproc` 只给可用核数 |
| 看 CPU 详细信息 | `cat /proc/cpuinfo` | 关注 `flags`、`cpu MHz` |
| 看内存 | `free -h`；`cat /proc/meminfo` | 看 `available` 而不是 `free`，见 002 §2.8 |
| 看块设备树 | `lsblk`；`lsblk -f` | `-f` 带文件系统与 UUID |
| 看 PCI 设备 | `lspci -nn` | `-nn` 显示厂商与设备 ID |
| 看 USB | `lsusb` | |
| 看硬件详情 | `dmidecode -t system`；`-t memory`；`-t bios` | 需 root；虚机上信息可能不全 |
| 看是否在虚拟机里 | `systemd-detect-virt` | 输出 `kvm`/`vmware`/`none` |
| 看内核日志 | `dmesg -T \| tail -50` | `-T` 转成可读时间 |
| 看本次启动的内核日志 | `journalctl -k -b` | 见 A.9 |
| 看已加载模块 | `lsmod`；`modinfo <mod>` | |
| 加载/卸载模块 | `modprobe <mod>`；`modprobe -r <mod>` | 开机加载写 `/etc/modules-load.d/` |
| 看内核参数 | `sysctl -a`；`sysctl <key>` | |
| 临时改内核参数 | `sysctl -w <key>=<val>` | 重启失效 |
| 永久改内核参数 | 写 `/etc/sysctl.d/99-x.conf` → `sysctl --system` | 别堆 `/etc/sysctl.conf` |
| 看开机各阶段耗时 | `systemd-analyze blame`；`systemd-analyze critical-chain` | |
| 看已装内核 | `rpm -qa kernel` | `dpkg -l 'linux-image*'` |

## A.2 进程与资源

| 我要 | 命令 | 备注 |
| --- | --- | --- |
| 看所有进程 | `ps aux`；`ps -ef` | `aux` 是 BSD 风格，`-ef` 是 System V 风格 |
| 按 CPU 排序前 10 | `ps -eo pid,ppid,stat,pcpu,pmem,comm --sort=-pcpu \| head` | 排内存改 `-rss` |
| 看进程树 | `pstree -p` | `-p` 显示 pid |
| 实时看 | `top`；`htop` | `top` 只看三处，见 009 §9.2 |
| 看某进程的所有线程 | `top -Hp <pid>`；`ps -T -p <pid>` | 找「哪个线程在跑满一核」 |
| 看某进程的线程 CPU 明细 | `pidstat -t -p <pid> 1` | |
| 按名字找进程 | `pgrep -a <name>`；`pgrep -af <pattern>` | `-a` 显示完整命令行 |
| 杀进程 | `kill <pid>`；`kill -9 <pid>` | 先 `-TERM`（15），实在不行再 `-9` |
| 按名字杀 | `pkill -f <pattern>`；`killall <name>` | `-f` 匹配完整命令行，危险 |
| 看 `D` 状态进程 | `ps -eo pid,stat,wchan:30,comm \| awk '$2 ~ /^D/'` | 见 009 §9.4 |
| 看进程在等什么系统调用 | `cat /proc/<pid>/syscall`；`cat /proc/<pid>/stack` | 需 root，比 `strace` 更快 |
| 跟踪系统调用 | `strace -p <pid> -f -T -e trace=openat,read` | `-T` 显示每次耗时 |
| 跟踪库调用 | `ltrace -p <pid>` | 需装 |
| 看进程打开的文件 | `lsof -p <pid>` | |
| 看谁占着这个端口 | `lsof -i :<port>`；`ss -lntp \| grep <port>` | `ss` 更快 |
| 看谁占着这个目录 | `lsof +D <dir>` | 很慢，目录大时慎用 |
| 找「删了但还开着」的文件 | `lsof +L1` | 见 004 §4.5、10.15 |
| 看谁在用这个挂载点 | `fuser -vm <dir>` | `-k` 直接杀掉 |
| 看进程资源限制 | `cat /proc/<pid>/limits`；`ulimit -a` | 前者是实际生效值 |
| 改优先级 | `nice -n 10 <cmd>`；`renice -n 10 -p <pid>` | 负值需 root |
| 改 IO 优先级 | `ionice -c2 -n7 -p <pid>` | 现代调度器下多半无效，见 002 §2.11 |
| 看 IO 占用 | `pidstat -d 1`；`iotop -o` | |
| 看上下文切换 | `pidstat -w 1` | 自愿/非自愿，见 009 §9.5 |
| 看 cgroup 树 | `systemd-cgls`；`systemd-cgtop` | |
| 看进程内存分布 | `pmap -x <pid>`；`cat /proc/<pid>/smaps_rollup` | 后者更快 |
| 后台跑且退出终端不死 | `nohup <cmd> &`；`setsid <cmd>`；`tmux` | 见 002 §2.12 |
| 把已跑的任务放后台 | `Ctrl+Z` → `bg` → `disown` | 关终端前必须 `disown` |
| 看某服务的所有进程 | `systemctl status <svc>`；`systemctl show -p MainPID <svc>` | |

## A.3 文件与目录

| 我要 | 命令 | 备注 |
| --- | --- | --- |
| 列目录 | `ls -lh`；`ls -ltr`；`ls -ld <dir>` | `-t` 按时间、`-r` 反序、`-d` 只看目录本身 |
| 看 inode 与 SELinux 标签 | `ls -li`；`ls -lZ` | |
| 复制（保留属性） | `cp -a <src> <dst>`；`cp -r` | `-a` 保留时间、权限、链接 |
| 复制并显示进度 | `cp -av`；`rsync -avP` | 大文件优先 `rsync` |
| 移动/改名 | `mv <src> <dst>` | ⚠️ 覆盖不提示 |
| 删除 | `rm -f <file>`；`rm -rf <dir>` | ⚠️ 见 A.12 危险清单 |
| 建目录 | `mkdir -p <a>/<b>` | |
| 建空文件/改时间 | `touch <file>`；`touch -d '2026-10-01' <file>` | |
| 建软链接 | `ln -s <target> <link>` | ⚠️ target 用绝对路径更稳 |
| 建硬链接 | `ln <target> <link>` | 不能跨文件系统、不能链目录 |
| 查文件真实路径 | `readlink -f <path>`；`realpath <path>` | 解开所有软链接 |
| 看文件详情 | `stat <file>` | inode、三个时间、权限一目了然 |
| 看文件类型 | `file <file>` | 判断「为什么执行不了」第一步 |
| 找文件（按名） | `find <dir> -name '*.log' -type f` | `-iname` 忽略大小写 |
| 找 7 天内改过的 | `find <dir> -mtime -7`；`-mmin -60` | `-` 是「之内」，`+` 是「之前」 |
| 找大于 100M 的 | `find <dir> -type f -size +100M` | |
| 找空文件/空目录 | `find <dir> -empty` | |
| 找某用户的文件 | `find <dir> -user <u>` | |
| 找某权限的文件 | `find <dir> -perm -4000` | SUID 排查 |
| 找比某文件新的 | `find <dir> -newer <ref>` | |
| 限制深度、不跨文件系统 | `find <dir> -maxdepth 2 -xdev` | 备 `/` 时必加 `-xdev` |
| 找到就删 | `find <dir> -name '*.tmp' -delete` | ⚠️ 先 `-print` 看一遍 |
| 找到就执行 | `find <dir> -name '*.log' -exec gzip {} +` | `+` 比 `\;` 快得多 |
| 按大小排序输出 | `find <dir> -type f -printf '%s %p\n' \| sort -rn \| head` | `-printf` 只有 GNU find 有 |
| 快速定位文件 | `locate <name>`；`updatedb` | 依赖数据库，新文件找不到 |
| 命令在哪 | `which <cmd>`；`command -v <cmd>`；`type -a <cmd>` | `type -a` 能看到别名与函数 |
| 文件属于哪个包 | 见 A.8 | |
| 临时目录 | `mktemp -d` | 比手拼 `/tmp/xxx` 安全 |
| 清空文件但保留 | `: > <file>`；`truncate -s 0 <file>` | 比 `rm` 好，fd 不断 |
| 把缓存刷到磁盘 | `sync` | `dd` 之后、拔盘之前 |
| 看目录占用 | `du -sh <dir>`；`du -h --max-depth=1 <dir>` | 硬链接统计陷阱见 10.4 |
| 看磁盘剩余 | `df -h`；`df -i` | `-i` 看 inode |
| 看目录树 | `tree -L 2 <dir>` | 需装 |

## A.4 文本处理

| 我要 | 命令 | 备注 |
| --- | --- | --- |
| 看文件 | `cat <file>`；`less <file>`；`less +F <file>` | `+F` 等于 `tail -f` |
| 看不可见字符 | `cat -A <file>` | 排查 `\r\n`、Tab |
| 看头/尾 N 行 | `head -n 20`；`tail -n 20` | |
| 持续跟踪日志 | `tail -f <file>`；`tail -F <file>` | `-F` 能扛日志轮转 |
| 搜索 | `grep -rn <pat> <dir>` | `-r` 递归、`-n` 行号 |
| 反向匹配 | `grep -v <pat>` | |
| 扩展正则 | `grep -E '<pat>'`；`grep -P '<pat>'` | `-P` 支持 `\d` 等 PCRE 语法 |
| 只看匹配部分 | `grep -o '<pat>'` | 配合 `sort \| uniq -c` 统计 |
| 带上下文 | `grep -A3 -B3 -C3 <pat>` | 前/后/前后 |
| 只列文件名 | `grep -rl <pat> <dir>` | `-L` 反过来：不含的行 |
| 限定文件类型 | `grep -rn --include='*.conf' <pat> <dir>` | `--exclude-dir=.git` 排目录 |
| 统计匹配行数 | `grep -c <pat> <file>` | |
| 替换并写回 | `sed -i 's/old/new/g' <file>` | ⚠️ 先不加 `-i` 看结果；`-i.bak` 留备份 |
| 只打印某几行 | `sed -n '10,20p' <file>` | |
| 删除匹配行 | `sed -i '/<pat>/d' <file>` | |
| 按列取 | `awk '{print $1, $3}' <file>`；`awk -F: '{print $1}'` | `-F` 指定分隔符 |
| 条件过滤 | `awk '$3 > 100 {print $1}' <file>` | |
| 带行号/合计 | `awk '{print NR": "$0}'`；`awk '{s+=$1} END{print s}'` | |
| 取字段（简单分隔符） | `cut -d: -f1,3 <file>` | 多空格分隔用 `awk` 更可靠 |
| 排序 | `sort <file>`；`sort -n`；`sort -rn`；`sort -k2,2` | `-n` 按数值、`-k` 按列 |
| 去重 | `sort <file> \| uniq`；`uniq -c`；`uniq -d` | `uniq` 只去相邻重复，必须先 `sort` |
| 统计行数/字节 | `wc -l`；`wc -c` | |
| 换行与去空白 | `tr -d '\r'`；`tr -s ' '` | |
| 字符替换 | `tr 'a-z' 'A-Z'` | |
| 同时看又存 | `<cmd> \| tee -a <file>` | |
| 批量执行 | `xargs -n1 <cmd>`；`xargs -0 <cmd>`；`xargs -P4 -I{} <cmd> {}` | `-0` 配 `find -print0`，处理带空格文件名 |
| 对比两个文件 | `diff -u <a> <b>`；`vimdiff <a> <b>` | `-u` 是补丁格式 |
| 对比两个有序文件 | `comm -12 <(sort a) <(sort b)>` | `-12` 取交集 |
| 编码转换 | `iconv -f GBK -t UTF-8 <file> > <out>` | `-f` 源编码 |
| 去掉 Windows 换行 | `dos2unix <file>`；`sed -i 's/\r$//' <file>` | 前者更安全（会备份） |
| 算校验和 | `sha256sum <file>`；`md5sum <file>` | |
| 校验清单 | `sha256sum -c MANIFEST` | 见 10.8 |
| 编码/解码 base64 | `base64 <file>`；`base64 -d` | |
| 对齐成表格 | `<cmd> \| column -t` | |
| 解析 JSON | `jq '.' <file>`；`jq -r '.items[].name'` | 需装 |
| 格式化输出 | `printf '%s\t%s\n' <a> <b>` | 比 `echo` 可控 |
| 统计出现次数 Top10 | `<cmd> \| sort \| uniq -c \| sort -rn \| head` | 最高频的一条组合 |

## A.5 网络

| 我要 | 命令 | 备注 |
| --- | --- | --- |
| 看地址（简洁） | `ip -br a` | 推荐，比 `ifconfig` 信息准 |
| 看地址（详细） | `ip a` | |
| 加/删地址 | `ip a add <ip>/24 dev <nic>`；`ip a del <ip>/24 dev <nic>` | 临时，重启失效 |
| 启停网卡 | `ip l set <nic> up`；`ip l set <nic> down` | |
| 看路由 | `ip r`；`ip route get <ip>` | 后者直接告诉你走哪条路 |
| 加默认路由 | `ip r add default via <gw>` | 临时 |
| 看邻居表（ARP） | `ip n`；`arp -n` | |
| 清 ARP 缓存 | `ip n flush all` | |
| 看端口监听 | `ss -lntp` | `-l` 监听、`-n` 数字、`-t` TCP、`-p` 进程 |
| 看 UDP 监听 | `ss -lnup` | |
| 看已建立连接 | `ss -tnp`；`ss -tn state established` | |
| 看连接汇总 | `ss -s` | 各类连接数 |
| 看 socket 队列 | `ss -lnt` | `Recv-Q` 含义见 005 §5.6 |
| 看某端口谁在用 | `ss -lntp \| grep :<port>` | |
| 连通性 | `ping -c 4 <ip>` | `-i 0.2` 加快、`-s 1472` 测 MTU |
| 测 MTU/不分片 | `ping -M do -s 1472 <ip>` | 见 005 §5.11 |
| 路由追踪 | `traceroute <ip>`；`tracepath <ip>`；`mtr <ip>` | `mtr` 最好用 |
| 查 DNS | `dig <name>`；`dig +short <name>`；`dig @<dns> <name>` | 指定 DNS 服务器排「是不是解析错了」 |
| 查 DNS（简单） | `nslookup <name>`；`host <name>` | |
| 查本机解析 | `getent hosts <name>` | 走 `/etc/nsswitch.conf`，比 `dig` 更接近应用行为 |
| 看 DNS 配置 | `cat /etc/resolv.conf` | |
| HTTP 探测 | `curl -I <url>`；`curl -v <url>` | `-I` 只看头，`-v` 看握手 |
| 只看状态码与耗时 | `curl -s -o /dev/null -w '%{http_code} %{time_total}\n' <url>` | |
| 指定 Host 头 | `curl -H 'Host: <domain>' http://<ip>/` | 测虚拟主机、测负载均衡 |
| 忽略证书 | `curl -k <https://...>` | 只用于排查 |
| 下载 | `curl -O <url>`；`wget <url>`；`wget -c <url>` | `-c` 断点续传 |
| 端口探测 | `nc -zv <ip> <port>`；`nc -zvu <ip> <port>` | `-u` 是 UDP |
| 临时监听 | `nc -l <port>` | 两机互测端口通不通 |
| 抓包 | `tcpdump -i any -nn port <port>` | `-A` 看内容、`-w x.pcap` 存盘 |
| 读包 | `tcpdump -r x.pcap -nn` | |
| 抓某主机某端口 | `tcpdump -i any -nn host <ip> and port <port> -c 50` | |
| 网卡信息与统计 | `ethtool <nic>`；`ethtool -i <nic>`；`ethtool -S <nic>` | `-S` 看丢包与错误计数 |
| 网卡速率/双工 | `ethtool <nic> \| grep -i speed` | |
| 看网卡驱动 | `ethtool -i <nic>` | |
| 网络配置（CentOS） | `nmcli d`；`nmcli c show`；`nmcli c up <name>` | |
| 网络配置（Ubuntu） | `netplan apply`；`cat /etc/netplan/*.yaml` | |
| 看防火墙（firewalld） | `firewall-cmd --list-all`；`--list-ports` | |
| 开放端口（firewalld） | `firewall-cmd --permanent --add-port=<port>/tcp` → `--reload` | `--add-service=http` 按服务 |
| 看防火墙（ufw） | `ufw status verbose` | |
| 开放端口（ufw） | `ufw allow <port>/tcp`；`ufw allow from <cidr> to any port <port>` | |
| 看 iptables 规则 | `iptables -L -n -v --line-numbers` | `-t nat` 看 NAT |
| 看 nftables | `nft list ruleset` | |
| 看 conntrack | `cat /proc/sys/net/netfilter/nf_conntrack_count` | 上限在同目录 `nf_conntrack_max` |
| 看重传/丢包统计 | `nstat -az \| grep -iE 'Retrans\|Drop'` | 见 009 §9.9 |
| 扫描端口（慎用） | `nmap -p 1-1000 <ip>` | 需装；生产上扫之前先报备 |

## A.6 磁盘与文件系统

| 我要 | 命令 | 备注 |
| --- | --- | --- |
| 看空间 | `df -h`；`df -hT`；`df -i` | `-T` 看文件系统类型，`-i` 看 inode |
| 看目录占用 | `du -sh <dir>`；`du -h --max-depth=1 <dir> \| sort -h` | |
| 看块设备 | `lsblk -f` | UUID、挂载点、文件系统一起看 |
| 看分区表 | `parted -l`；`fdisk -l` | |
| 看 UUID | `blkid` | 写 `fstab` 用它比设备名稳 |
| 分区（MBR） | `fdisk /dev/sdb` | ⚠️ 交互式，见 004 §4.2 |
| 分区（GPT） | `gdisk /dev/sdb`；`parted /dev/sdb` | |
| 建文件系统 | `mkfs.ext4 -L <label> /dev/sdb1`；`mkfs.xfs -L <label> /dev/sdb1` | ⚠️ 会清空分区 |
| 挂载 | `mount /dev/sdb1 <dir>`；`mount -t nfs <srv>:/p <dir>` | |
| 按 fstab 全挂 | `mount -a` | 改完 `fstab` **必须**跑 |
| 卸载 | `umount <dir>`；`umount -l <dir>`；`umount -f <dir>` | `-l` 懒惰、`-f` 强制（NFS 卡死时用） |
| 看挂载参数 | `findmnt <dir>`；`mount \| grep <dir>` | `findmnt` 输出更清楚 |
| 判断是否挂载 | `mountpoint -q <dir> && echo yes` | 脚本里必用，见 10.3 |
| 重挂为只读 | `mount -o remount,ro <dir>` | 误删抢救第一步，见 10.15 |
| 看某个进程的挂载命名空间 | `ls -l /proc/<pid>/ns/mnt` | 容器排查 |
| LVM 查看 | `pvs`；`vgs`；`lvs`；`lvs -a -o name,attr,lv_size,snap_percent` | |
| 扩逻辑卷（含扩文件系统） | `lvextend -r -L +10G /dev/<vg>/<lv>` | `-r` 自动扩 fs，见 004 §4.7 |
| 扩 xfs | `xfs_growfs <mountpoint>` | **只能扩不能缩** |
| 扩 ext4 | `resize2fs /dev/<vg>/<lv>` | 先 `lvextend` 再 `resize2fs` |
| 建快照 | `lvcreate -s -L 5G -n <snap> /dev/<vg>/<lv>` | 快照区写满即失效 |
| 合并快照（回滚） | `lvconvert --merge /dev/<vg>/<snap>` | ⚠️ 需卸载后生效 |
| RAID 状态 | `cat /proc/mdstat`；`mdadm --detail /dev/md0` | |
| 软 RAID 重建 | `mdadm /dev/md0 --add /dev/sdc1` | |
| 看 IO 统计 | `iostat -xz 1 3` | 字段与 `%util` 陷阱见 004 §4.11 |
| 看某进程 IO | `iotop -o`；`pidstat -d 1` | |
| 测顺序写 | `dd if=/dev/zero of=<dir>/test bs=1M count=1024 oflag=direct` | ⚠️ 会写 1G 文件，测完删 |
| 测随机读 | `fio --name=t --rw=randread --bs=4k --size=1G --numjobs=4 --runtime=30 --time_based` | 需装 `fio` |
| 看磁盘健康 | `smartctl -H /dev/sda`；`smartctl -a /dev/sda` | 需装 `smartmontools`，见 004 §4.12 |
| 看 ext4 参数 | `tune2fs -l /dev/sda1` | |
| 看 xfs 参数 | `xfs_info <mountpoint>` | |
| 检查 ext4 | `e2fsck -f /dev/sda1` | ⚠️ 必须卸载；`-n` 只检查 |
| 检查 xfs | `xfs_repair -n /dev/sda1` | `-n` 只检查；修复需卸载 |
| SSD TRIM | `fstrim -av` | |
| 看 swap | `swapon --show`；`free -h` | |
| 配额 | `repquota -a`；`quota -u <user>` | 见 004 §4.10 |

## A.7 权限与用户

| 我要 | 命令 | 备注 |
| --- | --- | --- |
| 改权限（数字） | `chmod 755 <path>`；`chmod -R 750 <dir>` | ⚠️ `-R` 配错会把目录改成不可进入 |
| 改权限（符号） | `chmod u+x <f>`；`chmod g-w,o-rwx <f>` | 比数字更不容易手滑 |
| 改属主 | `chown <u>:<g> <path>`；`chown -R <u>:<g> <dir>` | ⚠️ `-R` 要确认符号链接行为 |
| 只改属组 | `chgrp <g> <path>` | |
| 看默认权限 | `umask` | 目录 777-umask，文件 666-umask |
| 看 ACL | `getfacl <path>`；`getfacl -R <dir>` | |
| 设 ACL | `setfacl -m u:<u>:rwx <path>`；`setfacl -m g:<g>:rx <path>` | |
| 设默认 ACL（目录继承） | `setfacl -d -m u:<u>:rwx <dir>` | |
| 删 ACL | `setfacl -b <path>` | |
| 看特殊属性 | `lsattr <path>` | |
| 加不可改/只追加 | `chattr +i <file>`；`chattr +a <file>` | ⚠️ 连 root 也改不动，先记住怎么 `-i` |
| 看 capabilities | `getcap -r / 2>/dev/null` | 提权排查，见 003 §3.15 |
| 加 capabilities | `setcap cap_net_bind_service=+ep <bin>` | |
| 我是谁 | `id`；`whoami`；`groups` | |
| 谁在线 | `who`；`w`；`last`；`lastb` | `lastb` 看失败登录 |
| 加用户 | `useradd -m -s /bin/bash <u>`；`useradd -r -s /sbin/nologin -M <u>` | `-r` 系统用户、`-M` 不建家目录 |
| 改用户 | `usermod -aG <g> <u>`；`usermod -s /sbin/nologin <u>`；`usermod -L <u>` | ⚠️ `-G` 不加 `-a` 会覆盖原有组 |
| 删用户 | `userdel -r <u>` | `-r` 连家目录一起删 |
| 改密码 | `passwd <u>`；`passwd -l <u>`；`passwd -e <u>` | `-l` 锁定、`-e` 强制下次改 |
| 密码有效期 | `chage -l <u>`；`chage -M 90 <u>` | |
| 加组 | `groupadd <g>`；`gpasswd -a <u> <g>` | |
| 切用户 | `su - <u>`；`sudo -i`；`sudo -u <u> <cmd>` | `su -` 带环境变量 |
| 编辑 sudo 规则 | `visudo`；`visudo -f /etc/sudoers.d/<file>` | 别直接编辑 `sudoers` |
| 看 SELinux 状态 | `getenforce`；`sestatus` | |
| 临时关 SELinux | `setenforce 0` | 重启恢复；永久改 `/etc/selinux/config` |
| 看 SELinux 拒绝记录 | `ausearch -m avc -ts recent`；`journalctl -t audit` | 见 003 §3.11 |
| 看布尔值 | `getsebool -a \| grep <kw>` | |
| 改布尔值 | `setsebool -P <bool> on` | `-P` 永久 |
| 改文件上下文 | `semanage fcontext -a -t <type> '<path>(/.*)?'` → `restorecon -Rv <path>` | `semanage` 需 `policycoreutils-python` |
| 临时改上下文 | `chcon -t <type> <path>` | `restorecon` 后会失效 |
| 看 AppArmor（Ubuntu） | `aa-status` | |
| 看审计规则 | `auditctl -l` | |
| 查审计日志 | `ausearch -m execve -ts today`；`aureport --auth` | |

## A.8 包管理（双系对照）

这一节是全册差异最集中的地方，值得单独记。

| 目的 | CentOS 7 | Ubuntu 22.04 |
| --- | --- | --- |
| 装包 | `yum install -y <pkg>` | `apt install -y <pkg>` |
| 删包（留配置） | `yum remove <pkg>` | `apt remove <pkg>` |
| 删包（含配置） | `yum remove <pkg>` + 手删 `/etc/<pkg>` | `apt purge <pkg>` |
| 升级单个包 | `yum update <pkg>` | `apt install --only-upgrade <pkg>` |
| 全量升级 | `yum update` | `apt update && apt upgrade` |
| 搜索 | `yum search <kw>` | `apt search <kw>` |
| 看包信息 | `yum info <pkg>` | `apt show <pkg>` |
| 列已装 | `yum list installed`；`rpm -qa` | `dpkg -l`；`apt list --installed` |
| 看某包版本 | `rpm -q <pkg>` | `dpkg -l <pkg>` |
| 包装了哪些文件 | `rpm -ql <pkg>` | `dpkg -L <pkg>` |
| 这个文件属于哪个包 | `rpm -qf <path>` | `dpkg -S <path>` |
| 谁提供这个命令 | `yum provides '*/bin/<cmd>'` | `apt-file search bin/<cmd>`（需装 `apt-file` 并 `apt-file update`） |
| 装本地包 | `yum localinstall x.rpm`；`rpm -ivh x.rpm` | `apt install ./x.deb`；`dpkg -i x.deb` |
| 解依赖装本地包 | `yum localinstall x.rpm` 自动补依赖 | `apt install -f` 补依赖 |
| 清缓存 | `yum clean all` | `apt clean`；`apt autoclean` |
| 刷新元数据 | `yum makecache` | `apt update` |
| 看依赖 | `yum deplist <pkg>`；`rpm -qR <pkg>` | `apt-cache depends <pkg>` |
| 看仓库 | `yum repolist`；`ls /etc/yum.repos.d/` | `apt policy`；`ls /etc/apt/sources.list.d/` |
| 加仓库 | 写 `/etc/yum.repos.d/x.repo` | 写 `/etc/apt/sources.list.d/x.list` 或 `.sources` |
| 导入 GPG key | `rpm --import <key>` | `gpg --dearmor` 后放 `/etc/apt/trusted.gpg.d/` |
| 装开发工具组 | `yum groupinstall "Development Tools"` | `apt install build-essential` |
| 操作历史 | `yum history` | `cat /var/log/apt/history.log` |
| 回滚一次操作 | `yum history undo <id>` | 无直接对应，只能手动 |
| 验证包完整性 | `rpm -Va`（全系统） | `debsums -c`（需装 `debsums`） |
| 看已装内核 | `rpm -qa kernel` | `dpkg -l 'linux-image*'` |
| 源码编译前 | `yum groupinstall "Development Tools"` + `yum install -y <devel>` | `apt install build-essential` + `apt install lib<name>-dev` |
| 额外仓库 | `yum install -y epel-release` | `add-apt-repository universe` |

> **文件名相同、包名不同**是跨发行版最费时间的事，见 A.13。

## A.9 服务、日志与定时任务

| 我要 | 命令 | 备注 |
| --- | --- | --- |
| 启/停/重启 | `systemctl start <svc>`；`stop`；`restart` | |
| 只重载配置 | `systemctl reload <svc>` | 比 `restart` 影响小，但要服务支持 |
| 开机自启 | `systemctl enable <svc>`；`disable <svc>` | |
| 看状态 | `systemctl status <svc> -l --no-pager` | `-l` 不省略行 |
| 是否在跑 | `systemctl is-active <svc>`；`is-enabled <svc>` | 返回值给脚本用 |
| 列所有服务 | `systemctl list-units --type=service` | 加 `--state=running` 或 `failed` |
| 列失败的 | `systemctl --failed` | |
| 列已启用 | `systemctl list-unit-files --state=enabled` | |
| 看 unit 文件内容 | `systemctl cat <svc>` | 含 drop-in |
| 看 unit 的所有属性 | `systemctl show <svc> -p ExecStart -p Restart` | |
| 改 unit（生成 drop-in） | `systemctl edit <svc>` | 推荐，不动原文件 |
| 改了 unit 后 | `systemctl daemon-reload` | 不跑不生效 |
| 屏蔽服务 | `systemctl mask <svc>` | 比 `disable` 彻底，防被依赖拉起 |
| 看依赖关系 | `systemctl list-dependencies <svc>` | |
| 看启动顺序耗时 | `systemd-analyze critical-chain <svc>` | |
| 看服务日志 | `journalctl -u <svc> -n 200 --no-pager` | |
| 实时跟 | `journalctl -u <svc> -f` | |
| 看本次启动 | `journalctl -b`；`-b -1` 上一次 | |
| 按时间 | `journalctl --since '1 hour ago'`；`--since 10:00 --until 11:00` | |
| 只看错误 | `journalctl -p err -b` | `-p` 支持 `emerg/alert/crit/err/warning` |
| 看内核日志 | `journalctl -k` | |
| 看磁盘占用 | `journalctl --disk-usage` | |
| 清理日志 | `journalctl --vacuum-size=500M`；`--vacuum-time=7d` | ⚠️ 会真删 |
| 传统日志位置（CentOS） | `/var/log/messages`；`/var/log/secure` | |
| 传统日志位置（Ubuntu） | `/var/log/syslog`；`/var/log/auth.log` | |
| 测试 logrotate | `logrotate -d /etc/logrotate.conf` | `-d` 只演练，不改文件 |
| 强制轮转一次 | `logrotate -f /etc/logrotate.d/<name>` | ⚠️ 会真的切 |
| 看 cron | `crontab -l`；`crontab -e` | `-u <user>` 操作别人的 |
| 看系统 cron | `cat /etc/crontab`；`ls /etc/cron.d/`；`ls /etc/cron.{hourly,daily}` | |
| 看 cron 执行记录 | `grep CRON /var/log/cron`（CentOS）；`/var/log/syslog`（Ubuntu） | |
| 看 timer | `systemctl list-timers --all` | |
| 手动触发 timer 对应的服务 | `systemctl start <name>.service` | |
| 一次性定时 | `echo '<cmd>' \| at now + 10 minutes`；`atq`；`atrm <n>` | 需 `atd` 在跑 |
| 写一条 syslog | `logger -t <tag> 'message'` | 脚本里记日志用 |

## A.10 压缩与归档

| 我要 | 命令 | 备注 |
| --- | --- | --- |
| 打包并 gzip | `tar -czf <out>.tar.gz -C <dir> <name>` | `-f` 后必须紧跟文件名，见 007 §7.13 |
| 解 gzip 包 | `tar -xzf <file> -C <dir>` | |
| 只列内容 | `tar -tzf <file> \| head` | |
| 解到标准输出单个文件 | `tar -xzf <file> -O <path/in/archive>` | 不用解整个包 |
| 排除 | `tar -czf out.tar.gz --exclude='*.log' --exclude='cache' <dir>` | |
| 不跨文件系统 | `tar -czf out.tar.gz --one-file-system -C / .` | 备 `/` 必加 |
| 保留属性 | `tar --acls --xattrs --selinux -czf out.tar.gz <dir>` | |
| 稀疏文件 | `tar -S -czf out.tar.gz <dir>` | |
| xz 压缩 | `tar -cJf out.tar.xz <dir>` | 慢，内存占用高 |
| zstd 压缩 | `tar -cf - <dir> \| zstd -T0 > out.tar.zst` | CentOS 7 的 tar 1.26 不认 `--zstd`，只能用管道 |
| 解 zstd | `zstd -dc out.tar.zst \| tar -xf - -C <dir>` | |
| 增量归档 | `tar -czf inc.tar.gz -g <snapfile> -C / <dir>` | 链断即全废，见 10.7 |
| 解增量 | `tar -xzf inc.tar.gz -g /dev/null -C <dir>` | 按顺序解 |
| 校验归档与现有文件 | `tar -dzf <file> -C /` | |
| gzip 压缩/解压 | `gzip <file>`；`gzip -d <file>.gz`；`gzip -k <file>` | `-k` 保留原文件 |
| 验 gzip 完整性 | `gzip -t <file>.gz` | |
| zip | `zip -r <out>.zip <dir>` | |
| unzip 列表/解压 | `unzip -l <f>.zip`；`unzip <f>.zip -d <dir>` | |
| 中文名乱码 | `unzip -O CP936 <f>.zip` | 部分版本不支持，改用 `7z x -mcp=936`，见 007 §7.13 |
| 7z | `7z a <out>.7z <dir>`；`7z x <f>.7z` | 需 `p7zip` / `p7zip-full` |
| 分卷 | `split -b 100M -d <file> <prefix>.` | |
| 合并分卷 | `cat <prefix>.* > <file>` | |
| 边压边传 | `tar -czf - <dir> \| ssh <host> 'tar -xzf - -C <dir>'` | 不落地中间文件 |

## A.11 备份与共享

| 我要 | 命令 | 备注 |
| --- | --- | --- |
| 本地同步 | `rsync -aAXH --numeric-ids <src>/ <dst>/` | 结尾斜杠见 10.3 |
| 远程同步（ssh） | `rsync -avP <src>/ <u>@<host>:<dst>/` | `-P` 进度 + 续传 |
| 远程拉取 | `rsync -avP <u>@<host>:<src>/ <dst>/` | |
| 干跑 | `rsync -avn --delete <src>/ <dst>/` | 上线前必跑 |
| 同步并删多余 | `rsync -av --delete <src>/ <dst>/` | ⚠️ 三条删库路径见 10.3 |
| 删除的文件留底 | `--backup --backup-dir=/backup/trash/$(date +%F)` | |
| 限制删除数量 | `--max-delete=100` | 触发时退出码 25 |
| 硬链接快照 | `--link-dest=../<上一份>` + `--delete` | 见 10.4 |
| 限速 | `--bwlimit=51200`（KB/s） | |
| 排除清单 | `--exclude-from=/etc/backup.exclude` | |
| 严格比对 | `--checksum` | 慢，两端全读 |
| 指定 ssh 端口 | `-e 'ssh -p 2222'` | |
| 走 daemon | `rsync -av --password-file=<f> <u>@<host>::<mod>/` | 873 端口，见 10.5 |
| 列 daemon 模块 | `rsync rsync://<host>/` | |
| scp 传文件 | `scp <file> <u>@<host>:<path>` | 小文件够用，大目录用 `rsync` |
| ssh 免密 | `ssh-keygen -t ed25519`；`ssh-copy-id <u>@<host>` | |
| NFS 导出 | 编辑 `/etc/exports` → `exportfs -rav` | 见 10.9 |
| 看导出生效值 | `exportfs -v` | 比看 `exports` 有用 |
| 看对方导出 | `showmount -e <host>` | v4-only 时可能失败，正常 |
| 挂 NFS | `mount -t nfs -o vers=4.2,rw,hard,noatime <host>:/p <dir>` | |
| 看挂载实际参数 | `nfsstat -m` | |
| 卸卡住的 NFS | `umount -f <dir>`；不行就 `umount -l <dir>` | 见 10.10 |
| NFS 性能 | `nfsiostat`；`nfsstat -c` | |
| 列 SMB 共享 | `smbclient -L //<host> -U <u>` | |
| 挂 CIFS | `mount -t cifs //<host>/<share> <dir> -o username=<u>,uid=1000,gid=1000,vers=3.0` | 见 10.11 |
| 看 SMB 连接与锁 | `smbstatus` | |
| 验 Samba 配置 | `testparm -s` | |
| 加 SMB 账号 | `smbpasswd -a <u>` | 系统用户必须先存在 |
| 列 SMB 账号 | `pdbedit -L` | |
| 建快照（LVM） | `lvcreate -s -L 5G -n <snap> /dev/<vg>/<lv>` | |
| 从快照捞文件 | `mount -o ro /dev/<vg>/<snap> <dir>` → `cp` | 不动原卷 |
| 冻住文件系统 | `fsfreeze -f <dir>`；`fsfreeze -u <dir>` | ⚠️ 必须配 `trap` 解冻 |
| 看是否冻住 | `fsfreeze <dir>`（不带参数） | 输出 Frozen / Unfrozen |
| 一键镜像目录 | `rsync -aAXH --numeric-ids <src>/ <dst>/` | 比 `cp -a` 可靠 |
| 整盘镜像 | `dd if=/dev/sdb of=<img> bs=4M conv=noerror,sync status=progress` | ⚠️ 目标空间要等大，见 10.15 |
| 文件签名恢复 | `photorec <img>` | 文件名会丢 |

## A.12 性能与排错

| 我要 | 命令 | 备注 |
| --- | --- | --- |
| 一屏看全景 | `vmstat 1 5` | 第一行是开机均值，必须丢，见 009 §9.2 |
| 看 CPU 每核 | `mpstat -P ALL 1 3` | |
| 看 IO | `iostat -xz 1 3` | |
| 看内存与 swap | `free -m`；`vmstat 1` 的 `si`/`so` | |
| 看负载与队列 | `uptime`；`vmstat 1` 的 `r`/`b`；`cat /proc/loadavg` | |
| 看历史（要预装） | `sar -u 1 5`；`sar -r`；`sar -b`；`sar -n DEV`；`sar -q` | `sysstat` 包，见 009 §9.2 |
| 看历史某天 | `sar -f /var/log/sa/sa28 -u` | CentOS；Ubuntu 用 `/var/log/sysstat/sa28` |
| 看进程 CPU 趋势 | `pidstat -u 1 5` | |
| 看进程内存趋势 | `pidstat -r 1 5` | |
| 看上下文切换 | `pidstat -w 1 5` | |
| 找 CPU 热点函数 | `perf top`；`perf record -g -p <pid>` → `perf report` | 需装 `perf`（`linux-tools-$(uname -r)`） |
| 看 CPU 压力（PSI） | `cat /proc/pressure/cpu`；`/proc/pressure/io`；`/proc/pressure/memory` | 内核 4.20+ |
| 看软中断分布 | `mpstat -P ALL 1 3` | 某核 `%soft` 独高 = 中断不均衡 |
| 看网络错误 | `ip -s link`；`ethtool -S <nic>`；`nstat -az` | |
| 看 fd 用量 | `cat /proc/sys/fs/file-nr`；`lsof \| wc -l` | 第一列 → 第三列 |
| 看某进程 fd 数 | `ls /proc/<pid>/fd \| wc -l` | |
| 看 inotify 用量 | `sysctl fs.inotify.max_user_watches` | |
| 30 秒留现场 | 见 009 §9.2 末尾的清单 | 故障时先跑它，再动手 |

## A.13 工具名与包名对照

**症状**：`command not found`，或者 `yum install ifconfig` 报「没有这个包」。这张表按「命令 → 要装的包」查。

| 命令 | CentOS 7 装什么 | Ubuntu 22.04 装什么 |
| --- | --- | --- |
| `ifconfig` `route` `netstat` `arp` | `net-tools` | `net-tools` |
| `ip` `ss` | `iproute`（已装） | `iproute2`（已装） |
| `dig` `nslookup` `host` | `bind-utils` | `dnsutils` |
| `nc` | `nmap-ncat` | `netcat-openbsd` |
| `traceroute` | `traceroute` | `traceroute` |
| `mtr` | `mtr` | `mtr-tiny` |
| `tcpdump` | `tcpdump` | `tcpdump` |
| `nmap` | `nmap` | `nmap` |
| `telnet` | `telnet` | `telnet` |
| `lsof` | `lsof` | `lsof` |
| `strace` | `strace` | `strace` |
| `pstree` `fuser` `killall` | `psmisc` | `psmisc` |
| `iostat` `sar` `mpstat` `pidstat` | `sysstat` | `sysstat` |
| `iotop` | `iotop` | `iotop` |
| `htop` | `htop`（EPEL） | `htop` |
| `iftop` `nethogs` | `iftop` `nethogs`（EPEL） | `iftop` `nethogs` |
| `tree` | `tree` | `tree` |
| `zip` `unzip` | `zip` `unzip` | `zip` `unzip` |
| `7z` | `p7zip` + `p7zip-plugins`（两个都装才有 `7z`） | `p7zip-full` |
| `vim` | `vim-enhanced` | `vim` |
| `screen` `tmux` | `screen` `tmux` | `screen` `tmux` |
| `jq` | `jq`（EPEL） | `jq` |
| `pv` | `pv`（EPEL） | `pv` |
| `fio` | `fio`（EPEL） | `fio` |
| `smartctl` | `smartmontools` | `smartmontools` |
| `testdisk` `photorec` | `testdisk`（EPEL） | `testdisk` |
| `inotifywait` | `inotify-tools`（EPEL） | `inotify-tools` |
| `lsyncd` | `lsyncd`（EPEL） | `lsyncd` |
| `rsync` | `rsync` | `rsync` |
| `showmount` `exportfs` | `nfs-utils` | `nfs-kernel-server`（服务端）/ `nfs-common`（客户端） |
| `smbclient` `smbstatus` | `samba-client` `samba` | `samba` `smbclient` |
| `chronyc` | `chrony`（已装） | `chrony`（默认用 `systemd-timesyncd`） |
| `semanage` `setsebool` | `policycoreutils-python` | 无对应（Ubuntu 用 AppArmor） |
| `aa-status` | 无 | `apparmor-utils` |
| `sshd` | `openssh-server` | `openssh-server` |
| `firewall-cmd` | `firewalld`（已装） | `firewalld`（默认用 `ufw`） |
| `ufw` | 无（需装 `firewalld` 或 `iptables-services`） | `ufw`（已装） |
| `lrzsz`（`rz`/`sz`） | `lrzsz` | `lrzsz` |
| `sshpass` | `sshpass`（EPEL） | `sshpass` |
| `expect` | `expect` | `expect` |
| `debsums` | 无 | `debsums` |
| EPEL 本身 | `yum install -y epel-release` | 无对应 |

> **`nc` 的两系行为不一样**：CentOS 的 `nmap-ncat` 支持 `-z`、`--send-only` 等扩展参数，Ubuntu 的 `netcat-openbsd` 语法略不同。写脚本时优先用 `nc -zv host port`，两边都认。

## A.14 最常用的 30 条

一行一条，都是「记不住但天天要用的」。左边是动作，右边是命令。

| 动作 | 命令 |
| --- | --- |
| 机器有多快 | `uptime`；`nproc`；`free -h` |
| 谁在吃 CPU | `ps -eo pid,pcpu,pmem,comm --sort=-pcpu \| head` |
| 谁在吃内存 | `ps -eo pid,rss,comm --sort=-rss \| head` |
| 谁在吃磁盘 | `du -h --max-depth=1 / \| sort -h \| tail` |
| 盘还剩多少 | `df -hT`；`df -i` |
| 负载为什么高 | `vmstat 1 3` → 看 `r` 和 `b` |
| 谁卡在 IO | `ps -eo stat,wchan:30,comm \| awk '$1 ~ /^D/'` |
| 端口通不通 | `ss -lntp \| grep :<port>`；`nc -zv <ip> <port>` |
| 为什么连不上 | `ping` → `ip r get` → `dig` → `nc -zv` → `curl -v` |
| 谁占着文件/端口 | `lsof -i :<port>`；`lsof +D <dir>` |
| 日志在哪 | `journalctl -u <svc> -n 200`；`/var/log/messages`（C）/`syslog`（U） |
| 跟日志 | `tail -F <log>`；`journalctl -u <svc> -f` |
| 服务起不来 | `systemctl status <svc> -l` → `journalctl -u <svc> -b` |
| 改了 unit 不生效 | `systemctl daemon-reload` |
| 查某个配置写在哪 | `grep -rn '<key>' /etc/` |
| 改配置前备份 | `cp -a <file>{,.bak-$(date +%F)}` |
| 大范围替换（先看） | `grep -rn '<old>' <dir>` → 再 `sed -i.bak` |
| 找大文件 | `find / -xdev -type f -size +500M -printf '%s %p\n' \| sort -rn \| head` |
| 找最近改的 | `find <dir> -mmin -30 -type f` |
| 统计访问 Top10 IP | `awk '{print $1}' <log> \| sort \| uniq -c \| sort -rn \| head` |
| 看清某进程在干嘛 | `strace -p <pid> -f -T -e trace=network,file` |
| 同步目录 | `rsync -avP <src>/ <dst>/` |
| 同步前先看 | `rsync -avn --delete <src>/ <dst>/` |
| 打包带走 | `tar -czf <out>.tar.gz -C <dir> <name>` |
| 校验包好不好 | `sha256sum -c MANIFEST`；`tar -tzf <f> >/dev/null` |
| 装包 | `yum install -y <p>`；`apt install -y <p>` |
| 这个命令属于哪个包 | `rpm -qf $(command -v <cmd>)`；`dpkg -S $(command -v <cmd>)` |
| 开端口 | `firewall-cmd --permanent --add-port=<p>/tcp && firewall-cmd --reload`；`ufw allow <p>/tcp` |
| 临时给个 HTTP 服务 | `python3 -m http.server 8000` |
| 看机器是不是虚机 | `systemd-detect-virt` |

## A.15 执行前先停一秒的八条命令

不是「不许用」，是**用之前必须知道自己会失去什么**。

| 命令 | 一旦执行会失去什么 | 先做什么 |
| --- | --- | --- |
| `rm -rf <path>` | 路径下一整片数据。**变量为空时等于 `/`** | `echo` 出最终路径；用 `${VAR:?}`；能进回收站就进 |
| `dd if=<x> of=/dev/sdX` | 目标盘上的一切，不可逆 | `lsblk` 确认盘符；先 `dd` 到文件验证 |
| `mkfs.* /dev/sdX` | 该分区全部数据 | 确认挂载点已卸；`blkid` 确认没挂错 |
| `chmod -R 777 /` 或 `-R` 配错 | 全系统权限体系，SSH 可能直接不能登 | 先在子目录试；`-R` 前 `ls -ld` 看目标 |
| `chown -R` 配错 | 同上，且 `sshd` 会拒绝 `authorized_keys` 权限不对 | 同上 |
| `> <file>` / `truncate -s 0` | 文件内容清空，且**不可恢复** | 确认不是正在写的日志或数据库文件 |
| `mv <a> <b>` 覆盖同名 | 目标文件被静默替换 | `mv -n`（不覆盖）或 `mv -i` |
| `rsync --delete` 方向写反 | 用旧数据覆盖新数据并删掉多出来的 | `-n` 干跑，看 `deleting` 列表 |

> 这八行里出现最多的词是「`-R`」和「变量为空」。**递归和变量是两个放大器**：本来只影响一个文件的操作，加上 `-R` 或碰上空变量，影响面就是整台机器。所以脚本里凡是有 `-R`、凡是有 `$VAR`，都要多看一眼。

---

**上一篇**：[010 数据备份与共享](010-数据备份与共享.md)　**下一篇**：[B 发行版差异](B-发行版差异.md)
