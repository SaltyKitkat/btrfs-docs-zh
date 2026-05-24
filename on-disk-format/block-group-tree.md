# Block Group Tree

树 ID `BLOCK_GROUP_TREE (11)`。

Block Group Tree 存储所有 block group 的分配状态。此树仅在 `BLOCK_GROUP_TREE` compat_ro 特性启用时存在；未启用时，block group 信息存储在 [Extent Tree](extent-tree.md) 中。

Block Group Tree 的根节点作为 `ROOT_ITEM` 存入 [Root Tree](root-tree.md)，key 为 `(BLOCK_GROUP_TREE_OBJECTID, ROOT_ITEM_KEY, 0)`。

## Key-Item 结构

| Object ID | Type | Offset | Item 结构 | 说明 |
|-----------|------|--------|-----------|------|
| block group 逻辑起始地址 | `BLOCK_GROUP_ITEM (192)` | block group 长度（字节） | `btrfs_block_group_item` | block group 的分配和类型信息 |

### BLOCK_GROUP_ITEM (192)

key 的三元组：

- objectid：block group 的逻辑起始地址
- type：192
- offset：block group 的长度（字节）

```c
/* include/uapi/linux/btrfs_tree.h */

struct btrfs_block_group_item {
    __le64 used;
    __le64 chunk_objectid;
    __le64 flags;
} __attribute__ ((__packed__));
```

| 字段名 | 偏移 | 大小 | 说明 |
|--------|------|------|------|
| `used` | 0x0 | 8 | 此 block group 已使用的字节数 |
| `chunk_objectid` | 0x8 | 8 | 对应 chunk item 的 objectid（通常为 `FIRST_CHUNK_TREE (256)`） |
| `flags` | 0x10 | 8 | block group 类型和 profile 标志，值与 chunk type 相同（见 [Chunk Tree](chunk-tree.md#chunk-type-标志)） |

### 关联 chunk

每个 block group 对应一个 chunk，两者通过逻辑地址范围关联：chunk item 的 `(objectid, length)` 与 block group item 的 `(key.objectid, key.offset)` 一致。block group 的 `flags` 从对应 chunk 的 `type` 字段复制。

block group item 的 `chunk_objectid` 即为对应 chunk item key 的 `objectid`（即 `FIRST_CHUNK_TREE (256)`）。

## Item 大小变体

根据 `REMAP_TREE` incompat 特性启用与否，BLOCK_GROUP_ITEM 的 item body 大小不同：

| 特性 | item body 大小 | 结构 |
|------|---------------|------|
| 未启用（默认） | 24 字节 | `btrfs_block_group_item`（3 字段） |
| 启用 `REMAP_TREE` | 36 字节 | `btrfs_block_group_item_v2`（5 字段） |

### v2 结构

```c
struct btrfs_block_group_item_v2 {
    __le64 used;
    __le64 chunk_objectid;
    __le64 flags;
    __le64 remap_bytes;
    __le32 identity_remap_count;
} __attribute__ ((__packed__));
```

| 字段名 | 偏移 | 大小 | 说明 |
|--------|------|------|------|
| `used` | 0x0 | 8 | 同 v1 |
| `chunk_objectid` | 0x8 | 8 | 同 v1 |
| `flags` | 0x10 | 8 | 同 v1 |
| `remap_bytes` | 0x18 | 8 | 此 block group 中已重映射的字节数 |
| `identity_remap_count` | 0x20 | 4 | 原地重映射的次数 |
