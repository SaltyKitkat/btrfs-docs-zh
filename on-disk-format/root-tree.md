# Root Tree

树 ID `ROOT_TREE (1)`。

Root Tree 是文件系统的**顶层索引**。它存储指向所有其他树的根节点信息，每个条目（`ROOT_ITEM`）对应一个子卷（subvolume）、快照（snapshot）或系统树（Extent Tree、Chunk Tree 等）。

超级块中的 `root` 字段保存了 Root Tree 根节点的逻辑地址。

## Key-Item 结构

| Object ID | Type | Offset | Item 结构 | 说明 |
|-----------|------|--------|-----------|------|
| 子卷/系统树的 ID | `ROOT_ITEM (132)` | `0` | `btrfs_root_item` | 普通子卷或系统树的条目 |
| 快照的 ID | `ROOT_ITEM (132)` | 创建时的事务代次 | `btrfs_root_item` | 快照条目 |
| **子卷 ID** | `ROOT_BACKREF (144)` | **父目录所在树的 ID** | `btrfs_root_ref` + name | 从子卷反向链接到引用它的父目录 |
| **父目录所在树的 ID** | `ROOT_REF (156)` | **子卷 ID** | `btrfs_root_ref` + name | 从引用者到子卷的前向引用 |

以上两行的 `root_id` 和 `ref_id` 遵循内核函数 `btrfs_add_root_ref` 的命名：
- `root_id`：子卷（被引用者）的树 ID
- `ref_id`：引用者（父目录所在的 FS tree）的树 ID

### ROOT_ITEM (132)

key 的三元组：

- objectid：子卷、快照或系统树的 ID
- type：132
- offset：普通条目为 0，快照条目为创建时的事务代次

```c
/* include/uapi/linux/btrfs_tree.h */

struct btrfs_root_item {
    struct btrfs_inode_item inode;
    __le64 generation;
    __le64 root_dirid;
    __le64 bytenr;
    __le64 byte_limit;
    __le64 bytes_used;
    __le64 last_snapshot;
    __le64 flags;
    __le32 refs;
    struct btrfs_disk_key drop_progress;
    __u8 drop_level;
    __u8 level;

    /* 以下字段在 subvol_uuids+subvol_times 引入后出现 */

    __le64 generation_v2;
    __u8 uuid[BTRFS_UUID_SIZE];
    __u8 parent_uuid[BTRFS_UUID_SIZE];
    __u8 received_uuid[BTRFS_UUID_SIZE];
    __le64 ctransid;
    __le64 otransid;
    __le64 stransid;
    __le64 rtransid;
    struct btrfs_timespec ctime;
    struct btrfs_timespec otime;
    struct btrfs_timespec stime;
    struct btrfs_timespec rtime;
    __le64 reserved[8];
} __attribute__ ((__packed__));
```

| 字段名 | 偏移 | 大小 | 说明 |
|--------|------|------|------|
| `inode` | 0x0 | 160 | 嵌入的 [inode item](fs-tree.md#inode_item-结构)，记录子卷自身的元数据。`size` 始终为 0。`flags` 可包含 `BTRFS_INODE_ROOT_ITEM_INIT (1U << 31)` |
| `generation` | 0xa0 | 8 | 本 root item 最后更新时的事务代次 |
| `root_dirid` | 0xa8 | 8 | 子卷根目录的 inode 号。系统树此字段为 0 |
| `bytenr` | 0xb0 | 8 | 该树根节点的逻辑地址。和 `level` 一起描述树的根节点位置 |
| `byte_limit` | 0xb8 | 8 | 子卷的字节限制。0 表示无限制 |
| `bytes_used` | 0xc0 | 8 | 子卷已使用的字节数 |
| `last_snapshot` | 0xc8 | 8 | 从此子卷创建的最新快照的事务代次 |
| `flags` | 0xd0 | 8 | 标志位。`BTRFS_ROOT_SUBVOL_RDONLY (1 << 0)` 表示只读 |
| `refs` | 0xd8 | 4 | 引用计数 |
| `drop_progress` | 0xdc | 17 | 删除进度位置（`btrfs_disk_key`） |
| `drop_level` | 0xed | 1 | 删除进度所在的树层级 |
| `level` | 0xee | 1 | 该树根节点的层级 |
| `generation_v2` | — | 8 | generation 的副本，用于检测新旧内核兼容性 |
| `uuid` | — | 16 | 子卷的 UUID |
| `parent_uuid` | — | 16 | 父子卷的 UUID（快照的源子卷）。原始子卷为全零 |
| `received_uuid` | — | 16 | 接收子卷的 UUID。非 received 子卷为全零 |
| `ctransid` | — | 8 | 子卷内 inode 变更时更新的事务代次 |
| `otransid` | — | 8 | 子卷创建时的事务代次 |
| `stransid` | — | 8 | 被 `btrfs send` 发送时的事务代次 |
| `rtransid` | — | 8 | 被 `btrfs receive` 接收时的事务代次 |
| `ctime` | — | 12 | 子卷的变更时间 |
| `otime` | — | 12 | 子卷的创建时间 |
| `stime` | — | 12 | 子卷被发送的时间 |
| `rtime` | — | 12 | 子卷被接收的时间 |
| `reserved[8]` | — | 64 | 保留 |

#### 旧格式兼容

```c
static inline __u32 btrfs_legacy_root_item_size(void)
{
    return offsetof(struct btrfs_root_item, generation_v2);
}
```

旧版内核的 `btrfs_root_item` 大小只到 `generation_v2` 之前。挂载时若 `generation != generation_v2`，表示曾被旧内核写入过，UUID/时间戳扩展字段被清空。

### ROOT_BACKREF (144) / ROOT_REF (156)

**ROOT_BACKREF** key 的三元组：

- objectid：子卷（被引用者）的树 ID
- type：144
- offset：引用者（父目录所在的 FS tree）的树 ID

**ROOT_REF** key 的三元组：

- objectid：引用者（父目录所在的 FS tree）的树 ID
- type：156
- offset：子卷（被引用者）的树 ID

两种引用共用同一个 item 结构体，其后紧跟子卷名称：

```c
/* include/uapi/linux/btrfs_tree.h */

struct btrfs_root_ref {
    __le64 dirid;
    __le64 sequence;
    __le16 name_len;
} __attribute__ ((__packed__));
```

| 字段名 | 偏移 | 大小 | 说明 |
|--------|------|------|------|
| `dirid` | 0x0 | 8 | 父目录的 inode 号 |
| `sequence` | 0x8 | 8 | 目录项序列号 |
| `name_len` | 0x10 | 2 | 子卷名称长度（字节）。名称紧随其后 |

## 子卷标志

`btrfs_root_item.flags` 可包含以下标志：

| 常量 | 值 | 说明 |
|------|-----|------|
| `BTRFS_ROOT_SUBVOL_RDONLY` | `1 << 0` | 只读子卷 |
| `BTRFS_ROOT_SUBVOL_DEAD` | `1 << 48` | 已标记删除（仅内核内存标志，不持久化） |

## 关键 Object ID 汇总

Root Tree 中存储的 `ROOT_ITEM` 的 objectid 即为对应树的 ID：

| Object ID | 树 | 说明 |
|-----------|-----|------|
| 2 | Extent Tree | extent 分配与引用计数 |
| 3 | Chunk Tree | 逻辑地址→物理地址映射 |
| 4 | Dev Tree | 设备使用情况 |
| 5 | FS Tree（默认子卷） | 默认的文件和目录树 |
| 7 | CSUM Tree | 数据校验和 |
| 8 | Quota Tree | 配额配置与追踪 |
| 9 | UUID Tree | 子卷 UUID→ID 查找 |
| 10 | Free Space Tree | 空闲空间管理（v2） |
| 11 | Block Group Tree | extent tree v2 的 block group 条目 |
| 12 | RAID Stripe Tree | RAID 条带追踪 |
| 13 | Remap Tree | relocation 后的地址重映射 |
| ≥256 | 普通子卷/快照 | 用户创建的子卷和快照 |
