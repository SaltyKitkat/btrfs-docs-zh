# Dev Tree

树 ID `DEV_TREE (4)`。

Dev Tree 管理**物理设备空间**的使用情况，提供从物理地址到逻辑地址的反向映射——即给定一个物理设备偏移，查询它属于哪个逻辑 chunk。这与 [Chunk Tree](chunk-tree.md) 的映射方向相反（Chunk Tree 负责逻辑→物理）。

此外，Dev Tree 还存储设备的错误统计（`DEV_STATS`）以及设备替换操作的进度状态（`DEV_REPLACE`）。

## Key-Item 结构

| Object ID | Type | Offset | Item 结构 | 说明 |
|-----------|------|--------|-----------|------|
| 设备 ID | `DEV_EXTENT (204)` | 该 extent 在设备上的物理起始偏移 | `btrfs_dev_extent` | 物理地址→逻辑 chunk 的反向映射。每段已分配给 chunk 的物理空间对应一个条目 |
| `0` | `DEV_STATS (249)` | `0` | `btrfs_dev_stats_item` | 设备的 I/O 错误统计 |
| `0` | `DEV_REPLACE (250)` | `0` | `btrfs_dev_replace_item` | 设备替换操作的进度状态 |

> **注意**：`DEV_ITEM (216)` 存储在 [Chunk Tree](chunk-tree.md#dev_item-216) 中，而非 Dev Tree。

### DEV_EXTENT (204)

key 的三元组：

- objectid：设备 ID
- type：204
- offset：该 extent 在设备上的物理起始偏移。该 range 覆盖 [offset, offset + length) 的物理地址范围

```c
/* include/uapi/linux/btrfs_tree.h */

struct btrfs_dev_extent {
    __le64 chunk_tree;
    __le64 chunk_objectid;
    __le64 chunk_offset;
    __le64 length;
    __u8 chunk_tree_uuid[BTRFS_UUID_SIZE];
} __attribute__ ((__packed__));
```

| 字段名 | 偏移 | 大小 | 说明 |
|--------|------|------|------|
| `chunk_tree` | 0x0 | 8 | 引用此 extent 的 chunk 所在树的 objectid（通常为 `CHUNK_TREE (3)`） |
| `chunk_objectid` | 0x8 | 8 | chunk 条目中的 objectid（固定为 `FIRST_CHUNK_TREE (256)`） |
| `chunk_offset` | 0x10 | 8 | chunk 的逻辑起始地址，对应 chunk 条目 key 的 offset 字段 |
| `length` | 0x18 | 8 | 该物理 extent 的长度（字节） |
| `chunk_tree_uuid` | 0x20 | 16 | chunk tree 的 UUID |

`chunk_tree`、`chunk_objectid`、`chunk_offset` 三者共同定位 Chunk Tree 中对应的 `CHUNK_ITEM` 条目。即，给定物理设备上的 [offset, offset + length) 范围，它属于逻辑地址 `chunk_offset` 处的 chunk，该 chunk 定义在 `chunk_tree` 树的 `(chunk_objectid, CHUNK_ITEM, chunk_offset)` 条目中。

#### Chunk 与 DEV_EXTENT 的对应关系

一个 chunk（由 `btrfs_chunk` 描述）包含若干 stripe，每个 stripe 位于不同（或相同）设备上。每个 stripe 在其所在设备上对应一个 `DEV_EXTENT`：

- chunk 中 `num_stripes` 个 stripe 对应 `num_stripes` 个 `DEV_EXTENT` 条目
- 每个 `DEV_EXTENT` 的 `length` 与 chunk 的 `length` 相同（SINGLE/DUP 模式下），或为 `length / num_stripes`（RAID0/RAID10 条带化模式下）
- stripe 的 `devid` 匹配 `DEV_EXTENT` 的 objectid，stripe 的 `offset` 匹配 `DEV_EXTENT` 的 key.offset

### DEV_STATS (249)

key 的三元组：

- objectid：`BTRFS_DEV_STATS_OBJECTID (0)`
- type：249
- offset：0

```c
/* include/uapi/linux/btrfs_tree.h */

struct btrfs_dev_stats_item {
    __le64 values[BTRFS_DEV_STAT_VALUES_MAX];
} __attribute__ ((__packed__));
```

| 字段名 | 偏移 | 大小 | 说明 |
|--------|------|------|------|
| `values` | 0x0 | 可变 | 设备统计计数器数组 |

各计数值的索引定义如下：

| 索引常量 | 值 | 说明 |
|----------|-----|------|
| `BTRFS_DEV_STAT_WRITE_ERRS` | 0 | 写入错误计数 |
| `BTRFS_DEV_STAT_READ_ERRS` | 1 | 读取错误计数 |
| `BTRFS_DEV_STAT_FLUSH_ERRS` | 2 | 刷写错误计数 |
| `BTRFS_DEV_STAT_CORRUPTION_ERRS` | 3 | 数据损坏错误计数 |
| `BTRFS_DEV_STAT_GENERATION_ERRS` | 4 | 代次不匹配错误计数 |

### DEV_REPLACE (250)

key 的三元组：

- objectid：`BTRFS_DEV_REPLACE_DEVID (0)`
- type：250
- offset：0

```c
/* include/uapi/linux/btrfs_tree.h */

struct btrfs_dev_replace_item {
    __le64 src_devid;
    __le64 cursor_left;
    __le64 cursor_right;
    __le64 cont_reading_from_srcdev_mode;

    __le64 replace_state;
    __le64 time_started;
    __le64 time_stopped;
    __le64 num_write_errors;
    __le64 num_uncorrectable_read_errors;
} __attribute__ ((__packed__));
```

| 字段名 | 偏移 | 大小 | 说明 |
|--------|------|------|------|
| `src_devid` | 0x0 | 8 | 被替换的源设备 ID |
| `cursor_left` | 0x8 | 8 | 替换进度左边界（已完成的字节偏移） |
| `cursor_right` | 0x10 | 8 | 替换进度右边界（已同步的字节偏移） |
| `cont_reading_from_srcdev_mode` | 0x18 | 8 | 替换期间是否从源设备继续读取。0 = 始终读取，1 = 尽量避免 |
| `replace_state` | 0x20 | 8 | 替换状态 |
| `time_started` | 0x28 | 8 | 替换开始时间戳 |
| `time_stopped` | 0x30 | 8 | 替换停止/完成时间戳 |
| `num_write_errors` | 0x38 | 8 | 替换过程中写入目标设备的错误计数 |
| `num_uncorrectable_read_errors` | 0x40 | 8 | 替换过程中从源设备读取的不可纠正错误计数 |

#### replace_state 状态值

| 常量 | 值 | 说明 |
|------|-----|------|
| `BTRFS_IOCTL_DEV_REPLACE_STATE_NEVER_STARTED` | 0 | 从未启动 |
| `BTRFS_IOCTL_DEV_REPLACE_STATE_STARTED` | 1 | 正在运行 |
| `BTRFS_IOCTL_DEV_REPLACE_STATE_FINISHED` | 2 | 已完成 |
| `BTRFS_IOCTL_DEV_REPLACE_STATE_CANCELED` | 3 | 已取消 |
| `BTRFS_IOCTL_DEV_REPLACE_STATE_SUSPENDED` | 4 | 已暂停 |
