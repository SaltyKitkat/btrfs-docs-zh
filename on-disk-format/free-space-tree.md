# Free Space Tree

树 ID `FREE_SPACE_TREE (10)`。

Free Space Tree 跟踪每个 block group 中的空闲空间分布。它替代了旧版基于 inode 的空闲空间缓存（space cache v1），需要 `FREE_SPACE_TREE` compat_ro 特性。

超级块中不直接存储 Free Space Tree 的根节点地址；其根节点作为 `ROOT_ITEM` 存入 [Root Tree](root-tree.md)，key 为 `(FREE_SPACE_TREE_OBJECTID, ROOT_ITEM_KEY, 0)`。

## 概述

每个 block group 在 free space tree 中都有对应条目，记录该 block group 内哪些区域空闲、哪些已分配。跟踪方式有两种：

1. **extent 模式**：以 `FREE_SPACE_EXTENT` item 显式记录每一段连续空闲区间
2. **bitmap 模式**：以 `FREE_SPACE_BITMAP` item 存储位图，每个 bit 代表 `sectorsize` 字节

当 block group 变得碎片化（空闲 extent 数量超过阈值）时，从 extent 模式切换到 bitmap 模式以减少元数据开销。

## Key-Item 结构

free space tree 中所有 item 的 objectid 均表示 block group 内的逻辑地址，按 objectid 升序排列。

| Object ID | Type | Offset | Item 结构 | 说明 |
|-----------|------|--------|-----------|------|
| block group 起始 bytenr | `FREE_SPACE_INFO (198)` | block group 长度 | `btrfs_free_space_info` | block group 空闲空间元信息，每个 block group 有且仅有一个 |
| 空闲区间起始 bytenr | `FREE_SPACE_EXTENT (199)` | 空闲区间长度 | （空 item） | 一段连续空闲空间（extent 模式） |
| bitmap 起始 bytenr | `FREE_SPACE_BITMAP (200)` | bitmap 覆盖的字节范围 | 位图（256 字节） | bitmap 模式，每 bit 代表 sectorsize 字节 |

### FREE_SPACE_INFO (198)

key 的三元组：

- objectid：block group 的起始逻辑地址（bytenr）
- type：198
- offset：block group 的长度（字节）

```c
/* include/uapi/linux/btrfs_tree.h */

struct btrfs_free_space_info {
    __le32 extent_count;
    __le32 flags;
} __attribute__ ((__packed__));
```

| 字段名 | 偏移 | 大小 | 说明 |
|--------|------|------|------|
| `extent_count` | 0x0 | 4 | extent 模式下的 `FREE_SPACE_EXTENT` 数量。bitmap 模式下不反映空闲 extent 数 |
| `flags` | 0x4 | 4 | 标志位，见下表 |

#### Flags

| 常量 | 值 | 说明 |
|------|-----|------|
| `BTRFS_FREE_SPACE_USING_BITMAPS` | `1 << 0` | block group 使用 bitmap 模式（而非 extent 模式） |

### FREE_SPACE_EXTENT (199)

记录一段连续的空闲区间。item body 为空（0 字节），空闲区间的起止信息全部在 key 中。

key 的三元组：

- objectid：空闲区间的起始逻辑地址（bytenr）
- type：199
- offset：空闲区间的长度（字节）

所有 `FREE_SPACE_EXTENT` item 互不重叠，且按 objectid 排序。

### FREE_SPACE_BITMAP (200)

以位图形式表示空闲空间。每个 bit 对应 `sectorsize` 字节的数据区域：bit = 1 表示空闲，bit = 0 表示已用。

key 的三元组：

- objectid：bitmap 覆盖范围的起始地址（bytenr）
- type：200
- offset：bitmap 覆盖的字节范围长度

item body 为固定 256 字节（`BTRFS_FREE_SPACE_BITMAP_SIZE`）的位图，每个 bitmap 最多覆盖 `BTRFS_FREE_SPACE_BITMAP_BITS = 256 × 8 = 2048` 个 sector。

```
bitmap 覆盖范围 = key.offset = sectorsize × 2048
```

例如，sectorsize = 4K 时，每个 bitmap item 覆盖 8 MiB。

> **笔者注**：上游 `BTRFS_FREE_SPACE_BITMAP_SIZE` 为 256。笔者本地有一个 patch 将其改为 1024，以提升 16K nodesize 下的 leaf 空间利用率。
>
> 每个 bitmap item 在 leaf 中占用 `sizeof(struct btrfs_item) + bitmap_size` 字节。`struct btrfs_item` 为 25 字节（key 17 + offset 4 + size 4），因此：
>
> | bitmap 大小 | 每 item 总开销 | 覆盖 sector 数 | 覆盖范围 (4K sector) | 每 leaf 最多 item 数 | 每 leaf 最大覆盖 |
> |------------|--------------|---------------|---------------------|---------------------|-----------------|
> | 256 | 281 字节 | 2048 | 8 MiB | `16283 / 281 ≈ 57` | 456 MiB |
> | **1024** | **1049 字节** | **8192** | **32 MiB** | `16283 / 1049 ≈ 15` | **480 MiB** |
>
> （`16283` = 16K leaf 去除 101 字节 header 后的数据区大小）
>
> 1024 字节 bitmap 每 leaf 可多覆盖约 24 MiB（5%），同时 item 数从 57 降至 15，tree 遍历开销更低。

## Extent 模式与 Bitmap 模式切换

当 `FREE_SPACE_EXTENT` 数量超过 `bitmap_high_thresh` 阈值时，内核将该 block group 的所有 `FREE_SPACE_EXTENT` 转换为一个或多个 `FREE_SPACE_BITMAP`，并设置 `BTRFS_FREE_SPACE_USING_BITMAPS` 标志。

类似地，当 `FREE_SPACE_EXTENT` 数量降至 `bitmap_low_thresh` 以下时，bitmap 被重新展开为 `FREE_SPACE_EXTENT`。

阈值由 bitmap 的磁盘开销决定：`bitmap_high_thresh` = bitmap 总字节数 / `sizeof(struct btrfs_item)`，`bitmap_low_thresh` = `bitmap_high_thresh - 100`（下限为 0）。

## 与 Block Group 的关系

- 每个 block group 在 free space tree 中恰好有一个 `FREE_SPACE_INFO` item
- block group 的空间分配和释放通过增删 `FREE_SPACE_EXTENT` 或修改 `FREE_SPACE_BITMAP` 反映
- block group 创建时，整段区间作为单个 `FREE_SPACE_EXTENT` 插入
- block group 删除时，对应的所有 free space 条目一并删除

> v1 空闲空间缓存（space cache v1）使用 `FREE_SPACE_OBJECTID (-11)` 对应的特殊 inode 存储，格式不同（`btrfs_free_space_header` + `btrfs_free_space_entry`）。free space tree（space cache v2）是完全独立的 B-tree，与 v1 不兼容。当 `FREE_SPACE_TREE` compat_ro 特性启用时，v1 空闲空间缓存不再使用。
