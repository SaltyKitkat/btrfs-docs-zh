# Quota Tree

树 ID `QUOTA_TREE (8)`。

Quota Tree 存储子卷配额（qgroup）的配置、统计和限制信息，用于追踪和限制子卷/子卷组的磁盘空间占用。

Quota Tree 的根节点作为 `ROOT_ITEM` 存入 [Root Tree](root-tree.md)，key 为 `(QUOTA_TREE_OBJECTID, ROOT_ITEM_KEY, 0)`。

## Qgroup ID

Qgroup ID 为 64 位无符号整数，高 16 位为层级（level），低 48 位为编号：

```
qgroupid = (level << 48) | number
```

```c
/* include/uapi/linux/btrfs_tree.h */

#define BTRFS_QGROUP_LEVEL_SHIFT 48
static inline __u16 btrfs_qgroup_level(__u64 qgroupid)
{
    return (__u16)(qgroupid >> BTRFS_QGROUP_LEVEL_SHIFT);
}
```

- **level = 0**：qgroup 直接对应一个子卷，编号即为该子卷的 root objectid（例如 `FS_TREE (5)` 对应的 qgroup id 为 `5`）
- **level > 0**：由用户创建的高层 qgroup，用于将多个子卷/低层 qgroup 分组管理

## Key-Item 结构

除 `QGROUP_RELATION` 外，所有 item 的 objectid 均为 0。

| Object ID | Type | Offset | Item 结构 | 说明 |
|-----------|------|--------|-----------|------|
| `0` | `QGROUP_STATUS (240)` | `0` | `btrfs_qgroup_status_item` | 配额全局状态，整个树仅此一个 |
| `0` | `QGROUP_INFO (242)` | qgroup ID | `btrfs_qgroup_info_item` | qgroup 的空间统计（rfer / excl） |
| `0` | `QGROUP_LIMIT (244)` | qgroup ID | `btrfs_qgroup_limit_item` | qgroup 的空间限制 |
| 子 qgroup ID | `QGROUP_RELATION (246)` | 父 qgroup ID | （空 item） | 父子成员关系。每个关系存两条互为反向的 key |

## QGROUP_STATUS (240)

全局配额状态，整个 Quota Tree 中仅存在一个，key 固定为 `(0, 240, 0)`。

```c
/* include/uapi/linux/btrfs_tree.h */

#define BTRFS_QGROUP_STATUS_VERSION 1

struct btrfs_qgroup_status_item {
    __le64 version;
    __le64 generation;
    __le64 flags;
    __le64 rescan;
    __le64 enable_gen;
} __attribute__ ((__packed__));
```

| 字段名 | 偏移 | 大小 | 说明 |
|--------|------|------|------|
| `version` | 0x0 | 8 | 状态结构版本号，始终为 1 |
| `generation` | 0x8 | 8 | 每次事务提交时更新。挂载时若与 fs_info 记录的 generation 不符，表示配额数据可能不一致 |
| `flags` | 0x10 | 8 | 状态标志，见下表 |
| `rescan` | 0x18 | 8 | rescan 进度指针（逻辑地址），仅扫描期间非零 |
| `enable_gen` | 0x20 | 8 | 配额最后启用时的事务代次。仅简单配额模式使用，用于忽略启用前已分配的 extent |

### 状态标志

| 常量 | 值 | 说明 |
|------|-----|------|
| `BTRFS_QGROUP_STATUS_FLAG_ON` | `1 << 0` | 配额已启用 |
| `BTRFS_QGROUP_STATUS_FLAG_RESCAN` | `1 << 1` | rescan 进行中 |
| `BTRFS_QGROUP_STATUS_FLAG_INCONSISTENT` | `1 << 2` | 配额数据不一致，需 rescan 修复 |
| `BTRFS_QGROUP_STATUS_FLAG_SIMPLE_MODE` | `1 << 3` | 使用简单配额模式 |

## QGROUP_INFO (242)

每个 qgroup 的空间使用统计。创建 qgroup 时插入并初始化为零。

```c
struct btrfs_qgroup_info_item {
    __le64 generation;
    __le64 rfer;
    __le64 rfer_cmpr;
    __le64 excl;
    __le64 excl_cmpr;
} __attribute__ ((__packed__));
```

| 字段名 | 偏移 | 大小 | 说明 |
|--------|------|------|------|
| `generation` | 0x0 | 8 | 上次更新时的事务代次 |
| `rfer` | 0x8 | 8 | 引用空间（referenced space）。此 qgroup 引用的所有 extent 总字节数。共享 extent 在每个引用者处均重复计入 |
| `rfer_cmpr` | 0x10 | 8 | 压缩后引用空间。Btrfs 在 extent 级别压缩，因此通常与 `rfer` 相同 |
| `excl` | 0x18 | 8 | 独占空间（exclusive space）。仅被此 qgroup（及其子树）引用的 extent 字节数 |
| `excl_cmpr` | 0x20 | 8 | 压缩后独占空间 |

### rfer 与 excl 的计算

以上为完整配额模式下的语义。给定一个 extent：

| 场景 | rfer | excl |
|------|------|------|
| extent 仅被一个 qgroup 引用 | 该 qgroup +`num_bytes` | 该 qgroup +`num_bytes` |
| extent 被 N 个 qgroup 共享 | 每个 qgroup 各 +`num_bytes` | 无变化 |
| 唯一引用者删除，extent 仅剩一个引用者 | 删除者 -`num_bytes` | 剩余者 +`num_bytes` |

> 例如，subvol A 写入 1 MiB extent，subvol B 对 A 做快照。此时 A 和 B 的 `rfer` 均含这 1 MiB，`excl` 均不含。删除 A 后，该 extent 仅被 B 引用，B 的 `excl` 增加 1 MiB。

简单配额模式不区分 rfer 与 excl，`rfer` 字段直接反映该 qgroup 的净空间占用。

## QGROUP_LIMIT (244)

每个 qgroup 的空间限制和预留额度。创建 qgroup 时插入并初始化为零（无限制）。

```c
struct btrfs_qgroup_limit_item {
    __le64 flags;
    __le64 max_rfer;
    __le64 max_excl;
    __le64 rsv_rfer;
    __le64 rsv_excl;
} __attribute__ ((__packed__));
```

| 字段名 | 偏移 | 大小 | 说明 |
|--------|------|------|------|
| `flags` | 0x0 | 8 | 限制生效标志，见下表 |
| `max_rfer` | 0x8 | 8 | 引用空间上限（字节） |
| `max_excl` | 0x10 | 8 | 独占空间上限（字节） |
| `rsv_rfer` | 0x18 | 8 | 引用空间预留额度 |
| `rsv_excl` | 0x20 | 8 | 独占空间预留额度 |

### 限制标志

仅设置对应位的限制项才会被检查：

| 常量 | 值 | 说明 |
|------|-----|------|
| `BTRFS_QGROUP_LIMIT_MAX_RFER` | `1 << 0` | `max_rfer` 生效 |
| `BTRFS_QGROUP_LIMIT_MAX_EXCL` | `1 << 1` | `max_excl` 生效 |
| `BTRFS_QGROUP_LIMIT_RSV_RFER` | `1 << 2` | `rsv_rfer` 生效 |
| `BTRFS_QGROUP_LIMIT_RSV_EXCL` | `1 << 3` | `rsv_excl` 生效 |
| `BTRFS_QGROUP_LIMIT_RFER_CMPR` | `1 << 4` | 压缩引用空间限制生效 |
| `BTRFS_QGROUP_LIMIT_EXCL_CMPR` | `1 << 5` | 压缩独占空间限制生效 |

限制项与配额模式无关——完整模式和简单模式均可使用。

## QGROUP_RELATION (246)

qgroup 之间的父子成员关系。item body 为空（0 字节），所有信息在 key 中。

每个关系以**两条** item 表示，互为反向：

```
(child_qgroupid, 246, parent_qgroupid)
(parent_qgroupid, 246, child_qgroupid)
```

子 qgroup 的空间使用向上汇总到父 qgroup，形成树状层级结构。level = 0 的 qgroup（对应子卷）为叶子节点，level > 0 的 qgroup（用户创建的组）为内部节点。一个子 qgroup 可被多个父 qgroup 包含。

## 配额模式

Btrfs 支持两种配额运行模式，由 `QGROUP_STATUS.flags` 中的 `SIMPLE_MODE` 标志区分。

### 完整配额模式

完整配额模式（`ON` 置位，`SIMPLE_MODE` 未置位）通过 extent backref 解析实现精确的共享/独占统计。无需额外的不兼容特性标记。

每次事务提交时的统计流程：

1. **收集脏 extent**：`btrfs_qgroup_account_extents()` 遍历事务中所有变更过的 extent
2. **解析引用**：对每个 extent 执行 backref 查找（`btrfs_find_all_roots()`），确定新旧两个时间点的引用者集合
3. **计算差异**：对比新旧引用者集合，按 rfer/excl 规则更新各 qgroup 的计数
4. **向上传播**：每个 qgroup 的变化沿 QGROUP_RELATION 树向上传播到所有父 qgroup
5. **写入磁盘**：脏 qgroup 的 `QGROUP_INFO` 和 `QGROUP_STATUS` 写回磁盘

当以下情况发生时，`INCONSISTENT` 标志被设置，配额数据需要 `btrfs quota rescan` 修复：

- qgroup 配置变更（创建、删除、关系变化）
- 被非 qgroup-aware 的旧版内核挂载过
- 配额关闭后重新启用

完整模式依赖 [Extent Tree](extent-tree.md) 的 backref 信息来确定 extent 引用者，backref 的准确性直接影响配额数据。

### 简单配额模式

简单配额模式（`SIMPLE_MODE` 置位）是轻量级替代方案，需要 `SIMPLE_QUOTA` 不兼容特性。

与完整模式的关键区别：

- **不解析 backref**：改为在每次空间分配/释放时记录增量（delta），无需遍历 Extent Tree
- **enable_gen**：记录启用时的 transid。释放 extent 时，若 extent 的 generation 小于 `enable_gen`，说明该 extent 在启用配额前已分配，其空间不从此 qgroup 扣除
- **不区分 rfer/excl**：仅追踪净空间占用，不支持 extent 级别的共享/独占细分统计
