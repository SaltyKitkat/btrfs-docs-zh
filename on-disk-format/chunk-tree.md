# Chunk Tree

树 ID `CHUNK_TREE (3)`。

Chunk Tree 负责将**逻辑地址（logical address）映射到物理地址（physical address）**。文件系统所有 B-tree 节点地址均为逻辑地址，必须通过 Chunk Tree 才能找到对应的物理磁盘位置。

超级块中的 `chunk_root` 字段保存 Chunk Tree 根节点的逻辑地址。

## Key-Item 结构

| Object ID | Type | Offset | Item 结构 | 说明 |
|-----------|------|--------|-----------|------|
| `FIRST_CHUNK_TREE (256)` | `CHUNK_ITEM (228)` | chunk 的逻辑起始地址 | `btrfs_chunk` | 一段逻辑地址范围到物理设备的映射。objectid 固定为 256 |
| `DEV_ITEMS (1)` | `DEV_ITEM (216)` | 设备 ID | `btrfs_dev_item` | 文件系统中每块设备的描述信息 |

### CHUNK_ITEM (228)

key 的三元组：

- objectid：固定为 `FIRST_CHUNK_TREE (256)`
- type：228
- offset：chunk 的逻辑起始地址。该 chunk 覆盖 [offset, offset + chunk.length) 的逻辑地址范围

```c
/* include/uapi/linux/btrfs_tree.h */

struct btrfs_stripe {
    __le64 devid;
    __le64 offset;
    __u8 dev_uuid[BTRFS_UUID_SIZE];
} __attribute__ ((__packed__));

struct btrfs_chunk {
    __le64 length;
    __le64 owner;
    __le64 stripe_len;
    __le64 type;
    __le32 io_align;
    __le32 io_width;
    __le32 sector_size;
    __le16 num_stripes;
    __le16 sub_stripes;
    struct btrfs_stripe stripe;
    /* 额外 stripe 紧随其后 */
} __attribute__ ((__packed__));
```

| 字段名 | 偏移 | 大小 | 说明 |
|--------|------|------|------|
| `length` | 0x0 | 8 | chunk 的总逻辑长度（字节）。chunk 覆盖 [key.offset, key.offset + length) |
| `owner` | 0x8 | 8 | 引用此 chunk 的树的 objectid |
| `stripe_len` | 0x10 | 8 | 单个 stripe 的长度 |
| `type` | 0x18 | 8 | block group 类型和 RAID profile 的组合标志 |
| `io_align` | 0x20 | 4 | 最优 IO 对齐 |
| `io_width` | 0x24 | 4 | 最优 IO 宽度 |
| `sector_size` | 0x28 | 4 | 最小 IO 大小 |
| `num_stripes` | 0x2c | 2 | stripe 的数量。SINGLE 为 1，RAID1 为 2，RAID10 通常 ≥ 4 |
| `sub_stripes` | 0x2e | 2 | RAID10 的子 stripe 数，非 RAID10 为 1 |
| `stripe` | 0x30 | 32 | 第一个 stripe。`sizeof(btrfs_stripe)` = 32 字节，后续 stripe 紧接其后 |

#### Stripe

```c
struct btrfs_stripe {
    __le64 devid;        /* 此 stripe 所在的设备 ID */
    __le64 offset;       /* 此 stripe 在设备上的物理字节偏移 */
    __u8 dev_uuid[BTRFS_UUID_SIZE];  /* 设备 UUID */
} __attribute__ ((__packed__));
```

#### Chunk Type 标志

`type` 字段是一个位域组合，包含存储类型和 RAID profile：

| 常量 | 值 | 说明 |
|------|-----|------|
| `BTRFS_BLOCK_GROUP_DATA` | `1 << 0` | 用户数据 |
| `BTRFS_BLOCK_GROUP_SYSTEM` | `1 << 1` | 系统元数据 |
| `BTRFS_BLOCK_GROUP_METADATA` | `1 << 2` | 元数据 |
| `BTRFS_BLOCK_GROUP_RAID0` | `1 << 3` | RAID0 |
| `BTRFS_BLOCK_GROUP_RAID1` | `1 << 4` | RAID1（2 副本） |
| `BTRFS_BLOCK_GROUP_DUP` | `1 << 5` | DUP（同设备两份） |
| `BTRFS_BLOCK_GROUP_RAID10` | `1 << 6` | RAID10 |
| `BTRFS_BLOCK_GROUP_RAID5` | `1 << 7` | RAID5 |
| `BTRFS_BLOCK_GROUP_RAID6` | `1 << 8` | RAID6 |
| `BTRFS_BLOCK_GROUP_RAID1C3` | `1 << 9` | RAID1（3 副本） |
| `BTRFS_BLOCK_GROUP_RAID1C4` | `1 << 10` | RAID1（4 副本） |
| `BTRFS_BLOCK_GROUP_REMAPPED` | `1 << 11` | 该 chunk 已被 relocation 重映射 |
| `BTRFS_BLOCK_GROUP_METADATA_REMAP` | `1 << 12` | 元数据 relocation 专用 |

类型掩码：

```c
#define BTRFS_BLOCK_GROUP_TYPE_MASK    (DATA | SYSTEM | METADATA | METADATA_REMAP)
#define BTRFS_BLOCK_GROUP_PROFILE_MASK (RAID0 | RAID1 | RAID1C3 | RAID1C4 | \
                                         RAID5 | RAID6 | DUP | RAID10)
```

### DEV_ITEM (216)

key 的三元组：

- objectid：`DEV_ITEMS_OBJECTID (1)`
- type：216
- offset：设备 ID

```c
/* include/uapi/linux/btrfs_tree.h */

struct btrfs_dev_item {
    __le64 devid;
    __le64 total_bytes;
    __le64 bytes_used;
    __le32 io_align;
    __le32 io_width;
    __le32 sector_size;
    __le64 type;
    __le64 generation;
    __le64 start_offset;
    __le32 dev_group;
    __u8 seek_speed;
    __u8 bandwidth;
    __u8 uuid[BTRFS_UUID_SIZE];
    __u8 fsid[BTRFS_FSID_SIZE];
} __attribute__ ((__packed__));
```

| 字段名 | 偏移 | 大小 | 说明 |
|--------|------|------|------|
| `devid` | 0x0 | 8 | 设备 ID |
| `total_bytes` | 0x8 | 8 | 设备总容量（字节） |
| `bytes_used` | 0x10 | 8 | 已分配使用的字节数 |
| `io_align` | 0x18 | 4 | 最优 IO 对齐 |
| `io_width` | 0x1c | 4 | 最优 IO 宽度 |
| `sector_size` | 0x20 | 4 | 最小可寻址 IO 大小 |
| `type` | 0x24 | 8 | 设备类型标志 |
| `generation` | 0x2c | 8 | 设备最后变更时的事务代次 |
| `start_offset` | 0x34 | 8 | 分区在物理设备上的起始偏移 |
| `dev_group` | 0x3c | 4 | 设备分组 ID（0 表示未分组） |
| `seek_speed` | 0x40 | 1 | 寻道速度评级（0-100） |
| `bandwidth` | 0x41 | 1 | 带宽评级（0-100） |
| `uuid` | 0x42 | 16 | 设备 UUID |
| `fsid` | 0x52 | 16 | 所属文件系统的 UUID |

## 自举

Chunk Tree 存储在 SYSTEM 类型的 block group 中。要读取 Chunk Tree，必须先知道 SYSTEM chunk 的物理位置——而这又需要 Chunk Tree 的映射。这是一个鸡和蛋的问题。

### sys_chunk_array

解决方法是超级块尾部内嵌的 `sys_chunk_array`，它包含所有 SYSTEM chunk 的 `(KEY, CHUNK_ITEM)` 对，格式与 Chunk Tree 中的条目一致：

```c
#define BTRFS_SYSTEM_CHUNK_ARRAY_SIZE 2048
```

挂载初期流程：

1. 读取超级块（位于 `0x10000`）
2. 从 `sys_chunk_array` 中解析出所有 SYSTEM chunk 的逻辑地址→物理地址映射
3. 利用这些映射读取 Chunk Tree 根节点
4. 此后可通过完整的 Chunk Tree 解析任何逻辑地址

`sys_chunk_array` 中不包含非 SYSTEM 的 chunk，因此只用于自举。挂载后 Chunk Tree 本身接管所有地址转换。

详见超级块中的 [sys_chunk_array 字段](superblock.md#字段详解)。
