# Btrfs 磁盘格式（On-disk Format）

Btrfs 完全由若干棵 B-tree 组成，所有树均采用写时复制（Copy-on-Write, COW）。

树存储在**节点（node）**中，每个节点属于 B-tree 结构中的某一层。内部节点包含指向其他内部节点或叶子节点的引用。叶子节点包含各种类型的数据结构，具体取决于所在的树。

## 逻辑地址与物理地址

Btrfs 区分**逻辑地址（logical address）**和**物理地址（physical address）**：

- **逻辑地址**：用于文件系统结构中的地址。
- **物理地址**：磁盘上的字节偏移。

**Chunk Tree** 负责将逻辑地址转换为物理地址；**Dev Tree** 则处理反向映射。

超级块包含了指向 Root Tree 和 Chunk Tree 根节点的逻辑地址。为了**自举**（bootstrapping）——即在 Chunk Tree 本身尚未可读时定位 SYSTEM chunk——超级块还内嵌了一个 `sys_chunk_array`，其中存放了自举所需的 SYSTEM chunk（受限于 2048 字节容量）的 `(KEY, CHUNK_ITEM)` 对。[详见 Chunk Tree 的自举章节](chunk-tree.md#自举)。

## 命名约定

宏名称可能省略 `BTRFS_` 前缀和 `_OBJECTID` / `_KEY` 后缀。例如 `BTRFS_DEV_ITEMS_OBJECTID` 可简写为 `DEV_ITEMS`，`BTRFS_INODE_ITEM_KEY` 可简写为 `INODE_ITEM`。

## 目录

- [Superblock（超级块）](superblock.md) — 文件系统的全局元数据，包含各树根节点位置
- [Tree Header（树节点头）](tree-header.md) — 每个节点/叶子共有的头部结构
- [Node and Leaf（内部节点与叶子节点）](node-and-leaf.md) — B-tree 节点的内部布局
- [Key](key.md) — 键结构、排序规则、保留的 Object ID 与 Item Type 索引
- [Root Tree](root-tree.md) — 保存所有其他树的根节点信息
- [Chunk Tree](chunk-tree.md) — 逻辑地址到物理地址的映射
- [Dev Tree](dev-tree.md) — 物理地址到逻辑地址的反向映射
- [Extent Tree](extent-tree.md) — 空间分配与引用计数
- [FS Tree](fs-tree.md) — 文件与目录数据
- [CSUM Tree](csum-tree.md) — 数据校验和
- [UUID Tree](uuid-tree.md) — UUID 条目
- [Free Space Tree](free-space-tree.md) — 空闲空间信息
- [Block Group Tree](block-group-tree.md) — 每个 block group 的分配信息
