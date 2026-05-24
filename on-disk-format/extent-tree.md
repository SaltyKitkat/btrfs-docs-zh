# Extent Tree

树 ID `EXTENT_TREE (2)`。

Extent Tree 是 Btrfs 空间管理的核心。它追踪磁盘上每一段已分配空间（extent）的引用计数、类型以及反向引用（backref）信息。

超级块中的 `extent_root` 字段保存 Extent Tree 根节点的逻辑地址。

## Key-Item 结构

extent tree 中 key 以 `objectid` 为 extent 的 bytenr 聚合：同一 bytenr 的所有 item 在 tree 中相邻排列，按 type 升序。

| Object ID | Type | Offset | Item 结构 | 说明 |
|-----------|------|--------|-----------|------|
| extent 起始逻辑地址（bytenr） | `EXTENT_ITEM (168)` | extent 大小（字节） | `btrfs_extent_item` + [tree_block_info] + inline refs | 主 extent 描述项，始终存在 |
| extent 的 bytenr | `METADATA_ITEM (169)` | tree level（0 = 叶子节点） | `btrfs_extent_item` + inline refs | skinny metadata 格式的元数据块 |
| extent 的 bytenr | `TREE_BLOCK_REF (176)` | 引用者树的 root_id | （空 item） | 独立隐式树块 backref |
| extent 的 bytenr | `EXTENT_DATA_REF (178)` | `hash(root, inode, offset)` | `btrfs_extent_data_ref` | 独立隐式数据 backref |
| extent 的 bytenr | `SHARED_BLOCK_REF (182)` | 父树块的 bytenr | （空 item） | 独立显式树块 backref |
| extent 的 bytenr | `SHARED_DATA_REF (184)` | 父文件 extent 的 bytenr | `btrfs_shared_data_ref` | 独立显式数据 backref |
| block group 逻辑起始地址 | `BLOCK_GROUP_ITEM (192)` | block group 长度 | 见 [Block Group Tree](block-group-tree.md) | block group 分配信息，仅当 `BLOCK_GROUP_TREE` 特性未启用时存于此 |

### EXTENT_ITEM (168)

key 的三元组：

- objectid：extent 的起始逻辑地址（bytenr）
- type：168
- offset：extent 的大小（字节）。对于数据 extent，此值来自文件 extent 项的 `num_bytes` 字段；对于元数据树块，此值等于 `nodesize`

```c
/* include/uapi/linux/btrfs_tree.h */

struct btrfs_extent_item {
    __le64 refs;
    __le64 generation;
    __le64 flags;
} __attribute__ ((__packed__));
```

| 字段名 | 偏移 | 大小 | 说明 |
|--------|------|------|------|
| `refs` | 0x0 | 8 | 引用计数。本 extent 被引用的总次数。refs = 0 时 extent 可被释放 |
| `generation` | 0x8 | 8 | 创建本 extent 时的事务代次 |
| `flags` | 0x10 | 8 | extent 类型标志，见下方标志表 |

#### Flags

| 常量 | 值 | 说明 |
|------|-----|------|
| `BTRFS_EXTENT_FLAG_DATA` | `1 << 0` | 数据 extent |
| `BTRFS_EXTENT_FLAG_TREE_BLOCK` | `1 << 1` | 元数据树块 |
| `BTRFS_BLOCK_FLAG_FULL_BACKREF` | `1 << 8` | 使用完整 backref（仅树块，见下文 backref 章节） |

`flags` 的高 8 位（bit 56–63）存储 backref 版本号 `BTRFS_BACKREF_REV`：

| 值 | 常量 | 说明 |
|----|------|------|
| 0 | `BTRFS_OLD_BACKREF_REV` | 旧版 backref 格式 |
| 1 | `BTRFS_MIXED_BACKREF_REV` | 混合 backref 格式（当前标准） |

### METADATA_ITEM (169)

key 的三元组：

- objectid：树块起始逻辑地址（bytenr）
- type：169
- offset：该树块在 B-tree 中的层级（0 = 叶子节点，1 = 第一层内部节点，以此类推）

`METADATA_ITEM` 与 `EXTENT_ITEM` 的区别：

- 元数据树块的大小可从 `superblock.nodesize` 确定，无需在 key.offset 中存储
- key.offset 改为存储树块的 level，方便遍历时快速过滤
- 仅在 `SKINNY_METADATA` 不兼容特性启用后使用（见 [superblock](superblock.md)）

## Item Body 布局

extent item 的 body 由三部分组成：

```
[struct btrfs_extent_item]  [struct btrfs_tree_block_info]?  [inline ref]*+
```

1. **`btrfs_extent_item`**：extent 头部，始终存在
2. **`btrfs_tree_block_info`**：仅当 `flags` 包含 `BTRFS_EXTENT_FLAG_TREE_BLOCK` 且未启用 skinny metadata 时存在。对 `METADATA_ITEM`，此字段始终省略
3. **inline ref 列表**：反向引用列表，见下方 inline ref 章节

### btrfs_tree_block_info

```c
struct btrfs_tree_block_info {
    struct btrfs_disk_key key;
    __u8 level;
} __attribute__ ((__packed__));
```

| 字段名 | 偏移 | 大小 | 说明 |
|--------|------|------|------|
| `key` | 0x0 | 17 | 该树块中第一个 item 的 key |
| `level` | 0x11 | 1 | 树块层级（0 = 叶子） |

## Inline Ref

每个 extent 可被多个位置引用（例如一个数据 extent 被多个快照中的文件共享）。每个引用以 inline ref 的形式编码在 extent item body 尾部的变长列表中。

**inlineref 排序规则**：列表中的 inline ref 按 type 非递减排列。`EXTENT_OWNER_REF_KEY (172)` 始终在最前。

### 通用头部

```c
struct btrfs_extent_inline_ref {
    __u8 type;
    __le64 offset;
} __attribute__ ((__packed__));
```

| 字段名 | 偏移 | 大小 | 说明 |
|--------|------|------|------|
| `type` | 0x0 | 1 | backref 类型（一个 key type 值，如 176、178 等） |
| `offset` | 0x1 | 8 | 语义由 type 决定 |

`type` 决定了 `offset` 的含义以及是否有附加数据紧随其后。各类型的大小由 `btrfs_extent_inline_ref_size(type)` 计算：

| ref 类型 | 总大小 | 附后结构 |
|----------|--------|----------|
| `EXTENT_OWNER_REF_KEY (172)` | 9（仅头部） | 无，offset = 拥有者 root_id |
| `TREE_BLOCK_REF_KEY (176)` | 9（仅头部） | 无，offset = 引用者树的 root_id |
| `EXTENT_DATA_REF_KEY (178)` | 29 | `btrfs_extent_data_ref`（头部 offset 字段被覆写为此结构） |
| `SHARED_BLOCK_REF_KEY (182)` | 9（仅头部） | 无，offset = 父节点 bytenr |
| `SHARED_DATA_REF_KEY (184)` | 13 | `btrfs_shared_data_ref`（offset = 父节点 bytenr） |

### EXTENT_OWNER_REF (172)

简单配额（simple quota）专用。记录最初创建此 extent 的子卷 ID，在 extent 被删除时用于确定从哪个子卷扣除配额。

```c
struct btrfs_extent_owner_ref {
    __le64 root_id;
} __attribute__ ((__packed__));
```

| 字段名 | 偏移 | 大小 | 说明 |
|--------|------|------|------|
| `root_id` | 0x0 | 8 | 拥有此 extent 的子卷 root_id |

每个 extent 最多有一个 owner ref，且必须位于 inline ref 列表最前面（因其 type 值 172 在所有 ref 类型中最小）。

仅在 `SIMPLE_QUOTA` 不兼容特性启用时存在。

### TREE_BLOCK_REF (176)

隐式（implicit）树块引用。当父树块属于某个可识别的树（owner < `BTRFS_FIRST_FREE_OBJECTID`）时使用。通过父树块的 owner tree 和 key 即可定位引用者，无需额外数据。

`offset` 存储引用者树的 root_id。

### EXTENT_DATA_REF (178)

数据 extent 的隐式引用。记录哪个文件的哪一段引用了这个 extent。

```c
struct btrfs_extent_data_ref {
    __le64 root;
    __le64 objectid;
    __le64 offset;
    __le32 count;
} __attribute__ ((__packed__));
```

| 字段名 | 偏移 | 大小 | 说明 |
|--------|------|------|------|
| `root` | 0x0 | 8 | 引用此 extent 的文件所在子卷的 root objectid |
| `objectid` | 0x8 | 8 | 文件的 inode 号 |
| `offset` | 0x10 | 8 | 文件内的逻辑起始偏移（字节） |
| `count` | 0x18 | 4 | 引用计数（同一文件同一偏移多次映射） |

其中 `{root, objectid, offset}` 三元组唯一标识一个数据引用。

### SHARED_BLOCK_REF (182)

显式（full）树块引用。当父树块不属任何可识别的 tree（如共享节点）时使用。需要显式存储父节点地址。

`offset` 存储父树块的逻辑地址（bytenr）。用于 full backref 场景下的反向解析。

### SHARED_DATA_REF (184)

数据 extent 的显式引用。用于多个快照共享同一数据 extent 的场景。

```c
struct btrfs_shared_data_ref {
    __le32 count;
} __attribute__ ((__packed__));
```

| 字段名 | 偏移 | 大小 | 说明 |
|--------|------|------|------|
| `count` | 0x0 | 4 | 共享引用计数 |

`offset`（继承自头部）存储父文件 extent 的 bytenr。

## 独立 Backref Item

除了嵌入在 extent item body 内的 inline ref，backref 也可以作为独立的 item 存储在 extent tree 中。当 extent item body 超过 `BTRFS_MAX_EXTENT_ITEM_SIZE(r) = (BTRFS_LEAF_DATA_SIZE >> 4) - sizeof(struct btrfs_item)` 无法容纳更多 inline ref 时，新的 backref 将作为独立 item 写入 extent tree。

独立 backref item 的 `objectid` 与 EXTENT_ITEM 相同（均为 extent 的 bytenr），因此在 tree 中与对应的 EXTENT_ITEM 相邻。B-tree 遍历时会一并处理。

### TREE_BLOCK_REF (176)

独立隐式树块 backref。item body 为空（size = 0），所有信息在 key 中。

key 的三元组：

- objectid：extent 的起始逻辑地址（bytenr）
- type：176
- offset：引用此 extent 的 tree 的 root_id

### EXTENT_DATA_REF (178)

独立隐式数据 backref。item body 包含一个 `btrfs_extent_data_ref` 结构。

key 的三元组：

- objectid：extent 的起始逻辑地址（bytenr）
- type：178
- offset：`hash_extent_data_ref(root, objectid, offset)` 的哈希值

item body 即为上文 inline ref 中定义的 `btrfs_extent_data_ref`，字段语义相同。

### SHARED_BLOCK_REF (182)

独立显式树块 backref。item body 为空（size = 0）。

key 的三元组：

- objectid：extent 的起始逻辑地址（bytenr）
- type：182
- offset：父树块的逻辑地址（bytenr）

### SHARED_DATA_REF (184)

独立显式数据 backref。item body 包含一个 `btrfs_shared_data_ref` 结构。

key 的三元组：

- objectid：extent 的起始逻辑地址（bytenr）
- type：184
- offset：父文件 extent 的 bytenr

item body 即为上文 inline ref 中定义的 `btrfs_shared_data_ref`，字段语义相同。

## BLOCK_GROUP_ITEM (192)

block group 的分配信息。当文件系统未启用 `BLOCK_GROUP_TREE` compat_ro 特性时，此 item 存储在 extent tree 中；启用后则移至独立的 [Block Group Tree](block-group-tree.md)。结构体与字段详见该文档。

## 反向引用解析

Extent Tree 的核心功能是**反向引用**（backref）：给定一个 extent，找到所有引用它的位置。

Inline ref 分为两大类：

1. **隐式 backref**（implicit）：适用于父节点属于已知 owner tree 的情形。存储逻辑标识（root + key），解析时通过 B-tree 搜索定位引用者
   - `TREE_BLOCK_REF` — 父树块属于某 tree，通过 owner tree + key 定位
   - `EXTENT_DATA_REF` — 父文件 extent 属于某子卷，通过 `{root, inode, offset}` 定位

2. **完整 backref**（full）：适用于父节点不属于可识别 tree 的情形。直接存储父节点的物理/逻辑地址
   - `SHARED_BLOCK_REF` — 直接存储父树块的 bytenr
   - `SHARED_DATA_REF` — 直接存储父文件 extent 的 bytenr

对于树块指针，通过 `flags` 中的 `BTRFS_BLOCK_FLAG_FULL_BACKREF` 标志判断某个指针应使用显式还是隐式 backref。
