# Key

Key 是 Btrfs B-tree 中的排序和查找单位。每个 item 都由一个 key 唯一标识。

## 结构定义

```c
/* include/uapi/linux/btrfs_tree.h */

struct btrfs_disk_key {
    __le64 objectid;
    __u8 type;
    __le64 offset;
} __attribute__ ((__packed__));

struct btrfs_key {
    __u64 objectid;
    __u8 type;
    __u64 offset;
} __attribute__ ((__packed__));
```

磁盘上存储的是 `btrfs_disk_key`（小端序），内存中处理时转换为 `btrfs_key`（CPU 本地序）。两者大小相同。

## 字段详解

| 字段名 | 偏移 | 大小 | 类型 | 说明 |
|--------|------|------|------|------|
| `objectid` | 0x0 | 0x8 | UINT | Object ID。每棵树有自己独立的 Object ID 空间 |
| `type` | 0x8 | 0x1 | UINT | Item Type。表示该 item 的数据类型 |
| `offset` | 0x9 | 0x8 | UINT | Offset。含义取决于 item type |

## 排序规则

Key 按 `(objectid, type, offset)` 三元组进行字典序排序。所有字段均为**无符号数**，因此 `-1` 会被视为 `0xffffffffffffffff` 并排在树的末尾。

由于 Btrfs 使用**小端序**，不能直接对 key 进行逐字节比较，而必须按字段解析后比较。

## Timespec 结构

部分 item 中包含时间戳，使用以下结构：

| 偏移 | 大小 | 类型 | 说明 |
|------|------|------|------|
| 0x0 | 0x8 | UINT | 自 1970-01-01T00:00:00Z 以来的秒数 |
| 0x8 | 0x4 | UINT | 本秒内的纳秒数 |

## 保留的 Object ID

```c
/* include/uapi/linux/btrfs_tree.h */

/* holds pointers to all of the tree roots */
#define BTRFS_ROOT_TREE_OBJECTID 1ULL

/* stores information about which extents are in use, and reference counts */
#define BTRFS_EXTENT_TREE_OBJECTID 2ULL

/* chunk tree stores translations from logical -> physical block numbering */
#define BTRFS_CHUNK_TREE_OBJECTID 3ULL

/* stores information about which areas of a given device are in use */
#define BTRFS_DEV_TREE_OBJECTID 4ULL

/* one per subvolume, storing files and directories */
#define BTRFS_FS_TREE_OBJECTID 5ULL

/* directory objectid inside the root tree */
#define BTRFS_ROOT_TREE_DIR_OBJECTID 6ULL

/* holds checksums of all the data extents */
#define BTRFS_CSUM_TREE_OBJECTID 7ULL

/* holds quota configuration and tracking */
#define BTRFS_QUOTA_TREE_OBJECTID 8ULL

/* for storing items that use the BTRFS_UUID_KEY* types */
#define BTRFS_UUID_TREE_OBJECTID 9ULL

/* tracks free space in block groups */
#define BTRFS_FREE_SPACE_TREE_OBJECTID 10ULL

/* Holds the block group items for extent tree v2 */
#define BTRFS_BLOCK_GROUP_TREE_OBJECTID 11ULL

/* Tracks RAID stripes in block groups */
#define BTRFS_RAID_STRIPE_TREE_OBJECTID 12ULL

/* Holds details of remapped addresses after relocation */
#define BTRFS_REMAP_TREE_OBJECTID 13ULL

/* orphan objectid for tracking unlinked/truncated files */
#define BTRFS_ORPHAN_OBJECTID -5ULL

/* for space balancing */
#define BTRFS_TREE_RELOC_OBJECTID -8ULL
#define BTRFS_DATA_RELOC_TREE_OBJECTID -9ULL

#define BTRFS_FIRST_FREE_OBJECTID 256ULL
#define BTRFS_LAST_FREE_OBJECTID -256ULL
```

| 常量 | 值 | 说明 |
|------|-----|------|
| ROOT_TREE | 1 | Root Tree 自身 |
| EXTENT_TREE | 2 | Extent Tree |
| CHUNK_TREE | 3 | Chunk Tree |
| DEV_TREE | 4 | Dev Tree |
| FS_TREE | 5 | 全局 FS Tree 根 |
| ROOT_TREE_DIR | 6 | **默认子卷的入口**。它包含一个名为 `"default"` 的 `DIR_ITEM`，指向当前默认子卷的 `ROOT_ITEM`。挂载时若未指定 subvolume，内核通过查找该条目决定挂载哪个子卷。`btrfs subvolume set-default` 修改的就是这个条目的指向目标 |
| CSUM_TREE | 7 | CSUM Tree |
| QUOTA_TREE | 8 | Quota Tree |
| UUID_TREE | 9 | UUID Tree |
| FREE_SPACE_TREE | 10 | Free Space Tree |
| BLOCK_GROUP_TREE | 11 | Block Group Tree |
| RAID_STRIPE_TREE | 12 | RAID Stripe Tree |
| REMAP_TREE | 13 | Remap Tree |
| ORPHAN | -5ULL | 孤儿根追踪 |
| TREE_LOG | -6ULL | 日志树（WAL） |
| TREE_LOG_FIXUP | -7ULL | 日志修复树 |
| TREE_RELOC | -8ULL | 树迁移用的临时树 |
| DATA_RELOC | -9ULL | 数据迁移用的临时树 |
| FIRST_FREE | 256ULL | 文件树中第一个可用的 objectid |
| LAST_FREE | -256ULL | 文件树中最后一个可用的 objectid |
| FIRST_CHUNK_TREE | 256 | Chunk Tree 中的第一个/唯一 objectid |

## Item Type 索引

以下列出所有已定义的 item type。具体结构详见对应的功能树文档。

| 常量 | 值 | 所在树 | 文档 |
|------|-----|--------|------|
| `BTRFS_INODE_ITEM_KEY` | 1 | FS_TREE | [fs-tree](fs-tree.md) |
| `BTRFS_INODE_REF_KEY` | 12 | FS_TREE | [fs-tree](fs-tree.md) |
| `BTRFS_INODE_EXTREF_KEY` | 13 | FS_TREE | [fs-tree](fs-tree.md) |
| `BTRFS_XATTR_ITEM_KEY` | 24 | FS_TREE | [fs-tree](fs-tree.md) |
| `BTRFS_VERITY_DESC_ITEM_KEY` | 36 | FS_TREE | [fs-tree](fs-tree.md) |
| `BTRFS_VERITY_MERKLE_ITEM_KEY` | 37 | FS_TREE | [fs-tree](fs-tree.md) |
| `BTRFS_ORPHAN_ITEM_KEY` | 48 | ROOT_TREE | [orphan-and-log](orphan-and-log.md) |
| `BTRFS_DIR_LOG_ITEM_KEY` | 60 | LOG_TREE | [orphan-and-log](orphan-and-log.md) |
| `BTRFS_DIR_LOG_INDEX_KEY` | 72 | LOG_TREE | [orphan-and-log](orphan-and-log.md) |
| `BTRFS_DIR_ITEM_KEY` | 84 | FS_TREE | [fs-tree](fs-tree.md) |
| `BTRFS_DIR_INDEX_KEY` | 96 | FS_TREE | [fs-tree](fs-tree.md) |
| `BTRFS_EXTENT_DATA_KEY` | 108 | FS_TREE | [fs-tree](fs-tree.md) |
| `BTRFS_EXTENT_CSUM_KEY` | 128 | CSUM_TREE | [csum-tree](csum-tree.md) |
| `BTRFS_ROOT_ITEM_KEY` | 132 | ROOT_TREE | [root-tree](root-tree.md) |
| `BTRFS_ROOT_BACKREF_KEY` | 144 | ROOT_TREE | [root-tree](root-tree.md) |
| `BTRFS_ROOT_REF_KEY` | 156 | ROOT_TREE | [root-tree](root-tree.md) |
| `BTRFS_EXTENT_ITEM_KEY` | 168 | EXTENT_TREE | [extent-tree](extent-tree.md) |
| `BTRFS_METADATA_ITEM_KEY` | 169 | EXTENT_TREE | [extent-tree](extent-tree.md) |
| `BTRFS_EXTENT_OWNER_REF_KEY` | 172 | EXTENT_TREE | [extent-tree](extent-tree.md) |
| `BTRFS_TREE_BLOCK_REF_KEY` | 176 | EXTENT_TREE | [extent-tree](extent-tree.md) |
| `BTRFS_EXTENT_DATA_REF_KEY` | 178 | EXTENT_TREE | [extent-tree](extent-tree.md) |
| `BTRFS_SHARED_BLOCK_REF_KEY` | 182 | EXTENT_TREE | [extent-tree](extent-tree.md) |
| `BTRFS_SHARED_DATA_REF_KEY` | 184 | EXTENT_TREE | [extent-tree](extent-tree.md) |
| `BTRFS_BLOCK_GROUP_ITEM_KEY` | 192 | EXTENT_TREE | [extent-tree](extent-tree.md) |
| `BTRFS_FREE_SPACE_INFO_KEY` | 198 | FREE_SPACE_TREE | [free-space-tree](free-space-tree.md) |
| `BTRFS_FREE_SPACE_EXTENT_KEY` | 199 | FREE_SPACE_TREE | [free-space-tree](free-space-tree.md) |
| `BTRFS_FREE_SPACE_BITMAP_KEY` | 200 | FREE_SPACE_TREE | [free-space-tree](free-space-tree.md) |
| `BTRFS_DEV_EXTENT_KEY` | 204 | DEV_TREE | [dev-tree](dev-tree.md) |
| `BTRFS_DEV_ITEM_KEY` | 216 | CHUNK_TREE | [chunk-tree](chunk-tree.md) |
| `BTRFS_CHUNK_ITEM_KEY` | 228 | CHUNK_TREE | [chunk-tree](chunk-tree.md) |
| `BTRFS_QGROUP_STATUS_KEY` | 240 | QUOTA_TREE | [quota-tree](quota-tree.md) |
| `BTRFS_QGROUP_INFO_KEY` | 242 | QUOTA_TREE | [quota-tree](quota-tree.md) |
| `BTRFS_QGROUP_LIMIT_KEY` | 244 | QUOTA_TREE | [quota-tree](quota-tree.md) |
| `BTRFS_QGROUP_RELATION_KEY` | 246 | QUOTA_TREE | [quota-tree](quota-tree.md) |
| `BTRFS_UUID_KEY_SUBVOL` | 251 | UUID_TREE | [uuid-tree](uuid-tree.md) |
| `BTRFS_UUID_KEY_RECEIVED_SUBVOL` | 252 | UUID_TREE | [uuid-tree](uuid-tree.md) |
