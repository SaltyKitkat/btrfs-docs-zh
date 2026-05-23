# Node and Leaf（内部节点与叶子节点）

Btrfs 的树由两种节点组成：**内部节点（internal node）**和**叶子节点（leaf node）**。所有节点都以 [Tree Header](tree-header.md) 开头。

## 内部节点（Internal Node）

内部节点包含指向下一层内部节点或叶子节点的引用。当 level 降为 0 时，引用指向叶子节点。

### Key Pointer 结构

```c
/* include/uapi/linux/btrfs_tree.h */

/*
 * All non-leaf blocks are nodes, they hold only keys and pointers to other
 * blocks.
 */
struct btrfs_key_ptr {
    struct btrfs_disk_key key;
    __le64 blockptr;
    __le64 generation;
} __attribute__ ((__packed__));

struct btrfs_node {
    struct btrfs_header header;
    struct btrfs_key_ptr ptrs[];
} __attribute__ ((__packed__));
```

### 字段详解

| 字段名 | 偏移 | 大小 | 类型 | 说明 |
|--------|------|------|------|------|
| `key` | 0x0 | 0x11 | KEY | 该指针指向的子节点中所有 key ≥ 此 key，且 < 下一个 key ptr 的 key |
| `blockptr` | 0x11 | 0x8 | UINT | 子节点的块号（逻辑地址） |
| `generation` | 0x19 | 0x8 | UINT | 子节点的事务代次 |

### 布局

内部节点的布局为：**header | key ptr | key ptr | key ptr | … | free space**

每个 key ptr 指向一个子节点。子节点中所有 key 都大于等于该 key ptr 的 key，且小于下一个 key ptr 的 key。

## 叶子节点（Leaf Node）

叶子节点中存储的是实际的 item 数据。节点头之后是一系列 item 描述符，数据存储在节点的末尾。

### Item 结构

```c
/* include/uapi/linux/btrfs_tree.h */

/*
 * A leaf is full of items. offset and size tell us where to find the item in
 * the leaf (relative to the start of the data area)
 */
struct btrfs_item {
    struct btrfs_disk_key key;
    __le32 offset;
    __le32 size;
} __attribute__ ((__packed__));

/*
 * Leaves have an item area and a data area:
 * [item0, item1....itemN] [free space] [dataN...data1, data0]
 *
 * The data is separate from the items to get the keys closer together during
 * searches.
 */
struct btrfs_leaf {
    struct btrfs_header header;
    struct btrfs_item items[];
} __attribute__ ((__packed__));
```

### 字段详解

| 字段名 | 偏移 | 大小 | 类型 | 说明 |
|--------|------|------|------|------|
| `key` | 0x0 | 0x11 | KEY | item 的 key |
| `offset` | 0x11 | 0x4 | UINT | 数据偏移量（相对于 header 末尾，即 0x65） |
| `size` | 0x15 | 0x4 | UINT | 数据大小 |

### 布局

叶子节点的布局为：**header | item 0 | item 1 | … | item N | free space | data N | … | data 1 | data 0**

数据从节点末尾向前生长，item 描述符从 header 之后向后生长。这种设计有两个好处：

1. **搜索时 key 紧邻**：item 描述符中的 key 集中在前部，遍历时缓存友好。
2. **便于寻址和管理变长数据**：item 描述符大小固定（`sizeof(struct btrfs_item)` = 25 字节），可以通过简单索引访问；而 data 区域存放的是长度不固定的实际数据（如 `INODE_ITEM` 为定长，但 `EXTENT_DATA` 可能是 inline 数据或 extent 引用，长度各异）。将变长数据与定长描述符分离，增删 data 时不会影响 item 数组的布局。

`offset` 字段是相对于 header 末尾（偏移 0x65）计算的。例如，如果一个 item 的 `offset` 为 100，`size` 为 50，则数据位于节点内偏移 `0x65 + 100` 处，长度为 50 字节。

## 节点大小

节点大小由超级块中的 `nodesize` 字段决定，现代 Btrfs 文件系统默认使用 16 KiB。所有节点（内部节点和叶子节点）的大小相同。
