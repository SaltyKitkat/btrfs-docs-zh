# Csum Tree

树 ID `CSUM_TREE (7)`。

Csum Tree 存储数据 extent 的校验和（checksum），用于检测磁盘数据损坏。每个数据 extent 在写入时计算校验和，读取时验证。校验和以 `sectorsize` 为单位计算。

超级块中的 `csum_root` 字段保存 Csum Tree 根节点的逻辑地址，`csum_type` 字段指定校验和算法。

## Key-Item 结构

csum tree 中所有 item 共享同一个 objectid（`-10` = `BTRFS_EXTENT_CSUM_OBJECTID`）和 type（128 = `BTRFS_EXTENT_CSUM_KEY`），仅按 offset（extent 的起始逻辑地址，bytenr）排序。

| Object ID | Type | Offset | Item 结构 | 说明 |
|-----------|------|--------|-----------|------|
| `EXTENT_CSUM (-10)` | `EXTENT_CSUM_KEY (128)` | extent 起始 bytenr | `btrfs_csum_item[]` | 连续排列的校验和值 |

同一 bytenr 最多存在一个 csum item。每个 item 覆盖的字节范围由 item body 大小和 csum 算法决定。

## EXTENT_CSUM_KEY (128)

key 的三元组：

- objectid：`-10`（`BTRFS_EXTENT_CSUM_OBJECTID`）
- type：128
- offset：该 item 覆盖的第一个 sector 所在的 extent 的逻辑起始地址（bytenr）

```c
/* include/uapi/linux/btrfs_tree.h */

struct btrfs_csum_item {
    __u8 csum;
} __attribute__ ((__packed__));
```

`btrfs_csum_item` 的 `csum` 字段仅占 1 字节，实际 item body 为多个校验和值连续排列组成的字节数组。每个校验和值覆盖 `sectorsize` 字节的数据，占用 `csum_size` 字节。

一个 csum item 覆盖的字节范围：

```
[key.offset, key.offset + (item_size / csum_size) * sectorsize)
```

其中 `item_size` 为 item body 的字节长度，`csum_size` 为当前算法单个校验和的字节数。

### 校验和算法

校验和类型由超级块的 `csum_type` 字段指定。支持以下算法：

| 常量 | 值 | csum_size | 说明 |
|------|-----|-----------|------|
| `BTRFS_CSUM_TYPE_CRC32` | 0 | 4 | CRC32C（默认） |
| `BTRFS_CSUM_TYPE_XXHASH` | 1 | 8 | xxHash64 |
| `BTRFS_CSUM_TYPE_SHA256` | 2 | 32 | SHA-256 |
| `BTRFS_CSUM_TYPE_BLAKE2` | 3 | 32 | BLAKE2b-256 |

`BTRFS_CSUM_SIZE (32)` 是单个校验和值可能的最大字节数，用于 superblock 等结构中 csum 字段的维数。并非所有算法都填满这 32 字节。

### 校验和粒度

校验和以 `sectorsize` 为粒度计算。例如，sectorsize = 4K 时，每个 `csum_size` 字节的校验和对应 4096 字节的数据。一个 128K 的 extent 产生 `128K / 4K = 32` 个校验和值（CRC32C 下共 128 字节）。

数据量、校验和大小和覆盖字节范围的关系：

```
item_size = (data_bytes / sectorsize) * csum_size
covered_bytes = (item_size / csum_size) * sectorsize
```

## 与 Extent Tree 的关系

Extent tree 通过 `EXTENT_ITEM` / `METADATA_ITEM` 记录 extent 引用计数和反向引用，csum tree 记录这些 extent 的数据校验和。二者通过 bytenr 关联：

- 给定一个 extent 的 bytenr，在 extent tree 中可查出其引用信息（谁在用、引用计数）
- 在同一 bytenr 的 csum tree 中可查出其校验和（数据完整性）

注意 csum tree 仅为**数据** extent 存储校验和。元数据树块的校验和嵌入在树块头部（见 [Tree Header](tree-header.md)），不经过 csum tree。
