# Orphan Item（孤儿条目）

Orphan item 是 Btrfs 用来追踪**未完成的 inode/子卷删除**的机制：某些删除操作无法在一个事务内原子完成（如文件仍被打开、子卷子树尚未 drop 完），Btrfs 先在树上留下一个 orphan item 作为"备忘"，待条件满足后真正删除，或崩溃后在下一次挂载时完成收尾。

## Key-Item 结构

所有 orphan item 共享固定的 key 前缀，item body **为空**（size = 0），全部信息编码在 key 中：

```c
/* include/uapi/linux/btrfs_tree.h */

/* orphan objectid for tracking unlinked/truncated files */
#define BTRFS_ORPHAN_OBJECTID -5ULL

#define BTRFS_ORPHAN_ITEM_KEY 48
```

| 字段 | 值 | 说明 |
|------|-----|------|
| objectid | `BTRFS_ORPHAN_OBJECTID (-5)` | 固定值，标识 orphan item 空间 |
| type | `BTRFS_ORPHAN_ITEM_KEY (48)` | 固定值 |
| offset | inode 号 或 子卷 root id | 指向需要收尾的对象 |
| item body | 0 字节 | 无附加数据 |

按照 key 排序规则，`-5` 在无符号比较中是一个巨大的数，因此所有 orphan item 集中排在树的末尾，便于挂载时线性扫描。

## 存放位置

Orphan item 出现在**两个位置**，含义不同：

| 位置 | offset 含义 | 追踪对象 |
|------|------------|---------|
| 子卷的 FS tree | inode 号 | 该子卷内未完成的 inode 删除 |
| Root Tree | 子卷的 root id | 删除未完成的子卷/快照 |

两种情形分别由挂载时的不同代码路径消费，见下文。

## 创建时机

### 1. unlink / rename 覆盖打开中的文件

unlink 或 rename 覆盖目标后，若 inode 的硬链接数归零（`i_nlink == 0`）但文件仍被打开（`struct file` 持有引用），inode 无法立即销毁，此时插入 orphan item（`fs/btrfs/inode.c` 的 `btrfs_unlink()` / rename 路径）。待最后一个 fd 关闭、发生 inode eviction 时，orphan item 被移除，数据才真正释放。

### 2. 删除子卷/快照

删除子卷时，其整棵子树（可能非常庞大）不能在一个事务内 drop 完，需要后台 `cleaner` 线程分多次事务完成。删除开始时即向 **Root Tree** 插入 orphan item（offset = 子卷 root id，`fs/btrfs/inode.c` 的 `btrfs_delete_subvolume()`），作为"子卷删除进行中"的持久化标记；子树 drop 完成后删除该 orphan item。

### 3. O_TMPFILE / tmpfile

以 `open(2) O_TMPFILE` 创建的文件从出生起 `i_nlink` 就为 0，创建时插入 orphan item；之后若被 `link` 绑定到目录（nlink 变为 1），则删除 orphan item（`fs/btrfs/inode.c` 的 `btrfs_link()`）。

### 4. fs-verity 启用途中

启用 fs-verity 需要写入较多元数据，中途失败会留下半成品。启用流程开始时插入 orphan item，成功后删除（`fs/btrfs/verity.c`）。挂载清理时若发现 orphan inode 仍带链接数，会调用 `btrfs_drop_verity_items()` 丢弃不完整的 verity 元数据。

### 5. 日志重放（tree log）

崩溃恢复重放 tree log 时，若遇到此前被 unlink 过（重放项中 `i_nlink == 0`）的 inode，会重新插入 orphan item，确保后续清理逻辑能完成其删除（`fs/btrfs/tree-log.c`）。

> **历史遗留**：v3.12 之前的旧内核在 truncate 时也会创建 orphan item；v4.18 起不再为 truncate 创建。清理逻辑遇到这类历史条目时（inode 仍带链接数）直接删除 orphan item 即可，无需执行 truncate。

## 挂载时的消费流程

挂载时按固定顺序执行两阶段：

### 阶段一：查找死子卷

`btrfs_find_orphan_roots()`（`fs/btrfs/root-tree.c`）扫描 **Root Tree** 中所有 orphan item：

- 对每个 offset（子卷 root id），若对应子卷的 `ROOT_ITEM.refs == 0`，标记为 `BTRFS_ROOT_DEAD_TREE` 并加入待删除队列；若 `drop_progress` 非零，表明子树只 drop 到一半，还会设置 `BTRFS_FS_UNFINISHED_DROPS` 标志阻止 balance
- 若该 root id 已不存在（`btrfs_get_fs_root` 返回 `-ENOENT`），直接删除这个孤儿条目

**此阶段必须先于阶段二执行**：否则清理阶段会误删死子卷的 orphan item，导致其子树残留、下一次挂载时无法继续删除（见 `fs/btrfs/disk-io.c` 挂载流程注释）。

### 阶段二：逐子卷清理 inode 孤儿

`btrfs_orphan_cleanup()`（`fs/btrfs/inode.c`）对默认子卷、以及每个子卷首次挂载时执行，逐个处理 FS tree 中的 orphan item，对每个 orphan inode 分两种情况：

| 情况 | 处理 |
|------|------|
| inode 已不存在 | 直接删除 orphan item |
| `i_nlink != 0`（历史遗留/verity 不完整） | 调用 `btrfs_drop_verity_items()` 丢弃不完整 verity 元数据后，删除 orphan item |
| `i_nlink == 0` | `iput()` 该 inode，触发 inode eviction，完成数据释放与真正的删除 |

清理完成后会按 `BTRFS_ROOT_ORPHAN_ITEM_INSERTED` 标志在事务中确认收尾。

## 与 inode eviction 的协作

正常运行期间，在最后一次引用关闭时（inode eviction），`btrfs_evict_inode()` 负责：若 `i_nlink == 0`，删除该 inode 的所有数据 extents 与元数据（`btrfs_truncate`），最后移除自己的 orphan item。若该过程中途失败（如 -ENOSPC），orphan item 会留在树上，待下一次挂载时由阶段二完成收尾——注释明确说明"失败时保留 orphan item 比立即中止更安全"。