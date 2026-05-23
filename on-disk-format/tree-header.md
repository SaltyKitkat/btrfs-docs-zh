# Tree Header（树节点头）

每个树节点（无论是内部节点还是叶子节点）的开头都存储着相同的头部结构。这个头部用于校验、定位和标识节点所属的上下文。

## 结构定义

```c
/* include/uapi/linux/btrfs_tree.h */

/*
 * Every tree block (leaf or node) starts with this header.
 */
struct btrfs_header {
    /* These first four must match the super block */
    __u8 csum[BTRFS_CSUM_SIZE];
    /* FS specific uuid */
    __u8 fsid[BTRFS_FSID_SIZE];
    /* Which block this node is supposed to live in */
    __le64 bytenr;
    __le64 flags;

    /* Allowed to be different from the super from here on down */
    __u8 chunk_tree_uuid[BTRFS_UUID_SIZE];
    __le64 generation;
    __le64 owner;
    __le32 nritems;
    __u8 level;
} __attribute__ ((__packed__));
```

## 字段详解

| 字段名 | 偏移 | 大小 | 类型 | 说明 |
|--------|------|------|------|------|
| `csum` | 0x0 | 0x20 | CSUM | 本字段之后（从 0x20 到节点末尾）所有内容的校验和 |
| `fsid` | 0x20 | 0x10 | UUID | 文件系统 UUID |
| `bytenr` | 0x30 | 0x8 | UINT | 本节点的逻辑地址 |
| `flags` | 0x38 | 0x8 | flags | 标志位 |
| `chunk_tree_uuid` | 0x40 | 0x10 | UUID | Chunk Tree UUID |
| `generation` | 0x50 | 0x8 | UINT | 事务代次 |
| `owner` | 0x58 | 0x8 | UINT | 包含本节点的树的 ID |
| `nritems` | 0x60 | 0x4 | UINT | 节点中 item / key ptr 的数量 |
| `level` | 0x64 | 0x1 | UINT | 层级。叶子节点为 0，内部节点大于 0 |

## 注意

头部的前四个字段（`csum`、`fsid`、`bytenr`、`flags`）必须与超级块中的对应字段格式一致。这允许在读取节点时复用部分校验逻辑。

`owner` 字段标识了本节点属于哪一棵树。例如，一个属于 Root Tree 的节点，其 `owner` 值为 `BTRFS_ROOT_TREE_OBJECTID`（即 1）。

`level` 字段在叶子节点中为 0，在内部节点中为大于 0 的值，表示该节点在 B-tree 中的深度（离叶子越远，level 越大）。

> **笔者注**：每个 Btrfs 节点都以 `btrfs_header` 开头，这使得节点**自描述**——仅凭节点自身的内容，无需依赖其他元数据或上下文，就能完成以下验证：
>
> | 问题 | Btrfs 的实现 |
> |------|-------------|
> | 这个块完整吗？ | `csum` 对整个节点做校验和，检测数据损坏 |
> | 它属于哪个文件系统？ | `fsid` / `chunk_tree_uuid` 标识文件系统和 chunk tree 身份 |
> | 它应该在哪个位置？ | `bytenr` 记录预期的逻辑地址，检测误写入 |
> | 它属于谁？ | `owner` 记录所属树的 ID，界定损坏影响范围 |
> | 它最后一次修改是什么时候？ | `generation` 记录写入时的事务代次，辅助关联损坏事件的时间线 |
> | 它是节点还是叶子？ | `level` 描述其在树结构中的角色 |
>
> 自描述元数据的价值在于故障隔离和取证。例如：
>
> - 如果一个元数据块被误写入到错误的位置，`bytenr` 字段会暴露这个问题——读取时发现节点的 `bytenr` 与预期位置不符，立即判为损坏
> - 如果检测到损坏，`owner` 字段能直接告诉内核或修复工具"这个块属于 Extent Tree"，从而界定影响范围，无需遍历整个文件系统去追溯
>
> 这种设计理念并非 Btrfs 独有。XFS 在 v5 版中也引入了类似的自描述元数据格式，其头部包含 magic、CRC、uuid、owner、blkno、lsn 等字段，解决的是相同的规模化验证问题：当文件系统达到 PB 级时，手工取证分析的成本极高，必须让元数据块自身携带足够的信息以快速验证和定位故障。

