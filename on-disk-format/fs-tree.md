# FS Tree（Subvolume Tree）

FS Tree 是 Btrfs 中存储文件和目录数据的 B-tree。每个子卷（subvolume）拥有自己独立的 FS tree，tree ID 即为该子卷的 root objectid。

## 子卷

子卷是 Btrfs 中可独立快照的最小命名空间单元。每个子卷内部是一棵完整的文件系统树，包含该子卷下的所有文件、目录、扩展属性、以及文件数据 extent 的引用。

从 on-disk format 的角度看，子卷的关键特征如下：

- 每个子卷以一棵独立的 B-tree（FS tree）存储，tree ID = 子卷的 root objectid
- 子卷的 root objectid 和根节点地址存储在 [Root Tree](root-tree.md) 的 ROOT_ITEM 中
- 不同子卷的文件数据可以共享相同的磁盘 extent（通过 extent 引用计数和 backref 实现）
- 子卷之间完全隔离——一个子卷内的 inode 号、目录结构对其他子卷不可见

子卷按 root objectid 区分：

| root objectid | 说明 |
|--------------|------|
| `FS_TREE (5)` | 文件系统创建时自动生成的顶层子卷，挂载时默认可见。这是唯一有固定 objectid 的子卷 |
| `≥ 256`（`BTRFS_FIRST_FREE_OBJECTID`） | 用户创建的子卷或快照。快照默认可写，与源子卷共享数据 extent，写操作通过 COW 分离。通过 `-r` 选项可创建只读快照。快照在 on-disk 结构上与普通子卷完全相同 |

> 子卷概念的详细介绍（创建、删除、父子关系等）未来可能移至独立文档，此处只保留与 on-disk format 直接相关的内容。

## Key-Item 结构

FS tree 中所有 item 的 `objectid` 均为 inode 号：对于文件自身的 item（INODE_ITEM、EXTENT_DATA 等）为自身 inode 号；对于目录项（DIR_ITEM、DIR_INDEX）为所属目录的 inode 号。同一 inode 的 item 在 tree 中相邻排列，按 type 升序。

| Type | Offset | Item 结构 | 说明 |
|------|--------|-----------|------|
| `INODE_ITEM (1)` | 0 | `btrfs_inode_item` | inode 元数据（权限、大小、时间戳等） |
| `INODE_REF (12)` | 父目录的 inode 号 | `btrfs_inode_ref` + name | 从 inode 到父目录的反向链接 |
| `INODE_EXTREF (13)` | `crc32c(parent_objectid, name, name_len)` | `btrfs_inode_extref` + name | 扩展反向链接（当 index 值过大时使用） |
| `XATTR_ITEM (24)` | 0 | `btrfs_dir_item` + name + data | 扩展属性 |
| `VERITY_DESC_ITEM (36)` | 0 或 1 | fs-verity 描述符 | fs-verity 完整性保护元数据 |
| `VERITY_MERKLE_ITEM (37)` | Merkle 树偏移 | fs-verity Merkle 树块 | fs-verity 的 Merkle 哈希树 |
| `DIR_ITEM (84)` | `crc32c(name)` | `btrfs_dir_item` + name | 目录项，按文件名哈希查找 |
| `DIR_INDEX (96)` | 目录内顺序索引 | `btrfs_dir_item` + name | 目录项，按索引序号遍历 |
| `EXTENT_DATA (108)` | 文件内逻辑偏移 | `btrfs_file_extent_item` | 文件数据 extent |

## INODE_ITEM (1)

每个文件、目录、符号链接等对象都有一个 INODE_ITEM。它是每个 inode 的第一个 item（type 最小），充当 inode 的元数据头部。

key 的三元组：

- objectid：inode 号
- type：1
- offset：0

```c
/* include/uapi/linux/btrfs_tree.h */

struct btrfs_timespec {
    __le64 sec;
    __le32 nsec;
} __attribute__ ((__packed__));

struct btrfs_inode_item {
    __le64 generation;
    __le64 transid;
    __le64 size;
    __le64 nbytes;
    __le64 block_group;
    __le32 nlink;
    __le32 uid;
    __le32 gid;
    __le32 mode;
    __le64 rdev;
    __le64 flags;
    __le64 sequence;
    __le64 reserved[4];
    struct btrfs_timespec atime;
    struct btrfs_timespec ctime;
    struct btrfs_timespec mtime;
    struct btrfs_timespec otime;
} __attribute__ ((__packed__));
```

| 字段名 | 偏移 | 大小 | 说明 |
|--------|------|------|------|
| `generation` | 0x0 | 8 | 此 inode 最初创建时的 transid |
| `transid` | 0x8 | 8 | 最后修改此 inode 的 transid |
| `size` | 0x10 | 8 | 文件的逻辑大小（字节） |
| `nbytes` | 0x18 | 8 | 所有 `EXTENT_DATA` item 的 `num_bytes` 之和（不含 hole），即文件数据占用的逻辑字节总数。目录为 0 |
| `block_group` | 0x20 | 8 | 普通 inode 为 0；空闲空间缓存的 inode 存储对应 block group 起始地址 |
| `nlink` | 0x28 | 4 | 硬链接计数（在文件树外的 inode 中始终为 1） |
| `uid` | 0x2c | 4 | 所有者用户 ID |
| `gid` | 0x30 | 4 | 所有者组 ID |
| `mode` | 0x34 | 4 | 文件类型和权限（`st_mode`） |
| `rdev` | 0x38 | 8 | 设备号（字符/块设备） |
| `flags` | 0x40 | 8 | inode 标志位。低 32 位为读写标志，高 32 位为只读标志，见下表 |
| `sequence` | 0x48 | 8 | NFS 修改序列号 |
| `reserved` | 0x50 | 32 | 预留（4 × 8 字节） |
| `atime` | 0x70 | 12 | 访问时间 |
| `ctime` | 0x7c | 12 | 状态变更时间 |
| `mtime` | 0x88 | 12 | 数据修改时间 |
| `otime` | 0x94 | 12 | 创建时间（birth time） |

`btrfs_inode_item` 总大小为 160 字节（0xa0）。

### Inode Flags

| 常量 | 值 | 说明 |
|------|-----|------|
| `BTRFS_INODE_NODATASUM` | `1 << 0` | 不为此 inode 的数据做校验和 |
| `BTRFS_INODE_NODATACOW` | `1 << 1` | 不为数据做写时复制 |
| `BTRFS_INODE_READONLY` | `1 << 2` | 只读 |
| `BTRFS_INODE_NOCOMPRESS` | `1 << 3` | 不压缩 |
| `BTRFS_INODE_PREALLOC` | `1 << 4` | 有预分配空间 |
| `BTRFS_INODE_SYNC` | `1 << 5` | 同步写入 |
| `BTRFS_INODE_IMMUTABLE` | `1 << 6` | 不可变 |
| `BTRFS_INODE_APPEND` | `1 << 7` | 只追加 |
| `BTRFS_INODE_NODUMP` | `1 << 8` | dump 工具跳过 |
| `BTRFS_INODE_NOATIME` | `1 << 9` | 不更新 atime |
| `BTRFS_INODE_DIRSYNC` | `1 << 10` | 目录同步写入 |
| `BTRFS_INODE_COMPRESS` | `1 << 11` | 对此 inode 强制压缩 |

只读标志（存储在 `flags` 字段高 32 位，即 bit 32–63）：

| 常量 | 值（ro_flags 内） | 磁盘有效位 | 说明 |
|------|-------------------|------------|------|
| `BTRFS_INODE_RO_VERITY` | `1 << 0` | bit 32 | inode 启用了 fs-verity |

`BTRFS_INODE_ROOT_ITEM_INIT (1 << 31)` 标记 `ROOT_ITEM` 的 `flags` 和 `byte_limit` 字段已被正确初始化。旧版 btrfs 创建子卷时遗漏了这两个字段的初始化，内核借用 inode flags 的 bit 31 来区分是否需要补设默认值（置零）。此标志仅在 root tree 中的子卷 inode 上有意义。

## INODE_REF (12) / INODE_EXTREF (13)

从 inode 到父目录的反向链接（backref）。每个硬链接对应一个 `btrfs_inode_ref` entry，多个同父目录的 entry 存储在同一个 INODE_REF item 中。当该 item 所属 leaf 空间不足，无法追加更多 entry 时，溢出到 INODE_EXTREF（需 `EXTENDED_IREF` 不兼容特性）。

### INODE_REF (12)

key 的三元组：

- objectid：当前 inode 号
- type：12
- offset：父目录的 inode 号

```c
struct btrfs_inode_ref {
    __le64 index;
    __le16 name_len;
    /* name goes here */
} __attribute__ ((__packed__));
```

| 字段名 | 偏移 | 大小 | 说明 |
|--------|------|------|------|
| `index` | 0x0 | 8 | 此条目在父目录中的 DIR_INDEX 序号 |
| `name_len` | 0x8 | 2 | 文件名长度 |
| `name` | 0xa | `name_len` | 文件名（不含结尾 `\0`） |

### INODE_EXTREF (13)

key 的三元组：

- objectid：当前 inode 号
- type：13
- offset：`crc32c(parent_objectid, name, name_len)` 的哈希值

```c
struct btrfs_inode_extref {
    __le64 parent_objectid;
    __le64 index;
    __le16 name_len;
    __u8   name[];
} __attribute__ ((__packed__));
```

| 字段名 | 偏移 | 大小 | 说明 |
|--------|------|------|------|
| `parent_objectid` | 0x0 | 8 | 父目录的 inode 号 |
| `index` | 0x8 | 8 | 此 inode 在父目录 dir index 中的序号 |
| `name_len` | 0x10 | 2 | 文件名长度 |
| `name` | 0x12 | `name_len` | 文件名 |

## XATTR_ITEM (24)

扩展属性。item body 复用 `btrfs_dir_item` 结构：`name_len` 和随后的 `name` 字节存储属性名，`data_len` 和随后的 `data` 字节存储属性值，`location` 字段未使用。

key 的三元组：

- objectid：inode 号
- type：24
- offset：0

结构体定义见下文 [btrfs_dir_item](#btrfs_dir_item)。

## VERITY_DESC_ITEM (36) / VERITY_MERKLE_ITEM (37)

fs-verity 的磁盘格式数据，用于文件完整性保护。只在 inode 的 `flags` 中设置了 `BTRFS_INODE_RO_VERITY` 时存在。其内部格式由 fs-verity 子系统定义，不在 on-disk format 层面解析。

## DIR_ITEM (84) / DIR_INDEX (96)

目录项。每个文件/子目录名在父目录中由一对 item 表示——二者 body 内容完全相同，仅 key 不同：

- `DIR_ITEM`：按**文件名哈希**索引，用于按名称查找
- `DIR_INDEX`：按**目录内序号**索引，用于按顺序遍历

### DIR_ITEM (84)

key 的三元组：

- objectid：目录的 inode 号
- type：84
- offset：`crc32c(filename)` ——文件名的 CRC32C 哈希

### DIR_INDEX (96)

key 的三元组：

- objectid：目录的 inode 号
- type：96
- offset：此条目在目录内的顺序索引（单调递增，可能有间隙）

### btrfs_dir_item

```c
struct btrfs_dir_item {
    struct btrfs_disk_key location;
    __le64 transid;
    __le16 data_len;
    __le16 name_len;
    __u8 type;
    /* name[name_len] follows */
} __attribute__ ((__packed__));
```

| 字段名 | 偏移 | 大小 | 说明 |
|--------|------|------|------|
| `location` | 0x0 | 17 | 指向目标 inode 的 key（`(inode_number, INODE_ITEM, 0)`） |
| `transid` | 0x11 | 8 | 创建此目录项的事务代次 |
| `data_len` | 0x19 | 2 | 附加数据长度（通常为 0） |
| `name_len` | 0x1b | 2 | 文件名长度（字节） |
| `type` | 0x1d | 1 | 文件类型（`BTRFS_FT_*`），见下表 |

`type` 后紧接 `name_len` 字节的文件名（不含结尾 `\0`）。

### 文件类型

| 常量 | 值 | 说明 |
|------|-----|------|
| `BTRFS_FT_UNKNOWN` | 0 | 未知 |
| `BTRFS_FT_REG_FILE` | 1 | 普通文件 |
| `BTRFS_FT_DIR` | 2 | 目录 |
| `BTRFS_FT_CHRDEV` | 3 | 字符设备 |
| `BTRFS_FT_BLKDEV` | 4 | 块设备 |
| `BTRFS_FT_FIFO` | 5 | FIFO/命名管道 |
| `BTRFS_FT_SOCK` | 6 | Unix 域套接字 |
| `BTRFS_FT_SYMLINK` | 7 | 符号链接 |
| `BTRFS_FT_XATTR` | 8 | 扩展属性（XATTR_ITEM 内部使用） |
| `BTRFS_FT_ENCRYPTED` | 0x80 | 加密标志（可与上述类型组合） |

## EXTENT_DATA (108)

文件的数据 extent，将文件逻辑偏移映射到磁盘 extent。

key 的三元组：

- objectid：文件的 inode 号
- type：108
- offset：此 extent 在文件内的逻辑起始偏移（字节）

```c
struct btrfs_file_extent_item {
    __le64 generation;
    __le64 ram_bytes;
    __u8 compression;
    __u8 encryption;
    __le16 other_encoding;
    __u8 type;
    __le64 disk_bytenr;
    __le64 disk_num_bytes;
    __le64 offset;
    __le64 num_bytes;
} __attribute__ ((__packed__));
```

### type 字段

| 常量 | 值 | 说明 |
|------|-----|------|
| `BTRFS_FILE_EXTENT_INLINE` | 0 | 数据内联在 item body 中（小文件，整体数据容纳于单个 item） |
| `BTRFS_FILE_EXTENT_REG` | 1 | 常规 extent，数据存储在独立的 extent 中 |
| `BTRFS_FILE_EXTENT_PREALLOC` | 2 | 预分配 extent（空间已预留但未写入） |

### compression 字段

| 常量 | 值 | 说明 |
|------|-----|------|
| `BTRFS_COMPRESS_NONE` | 0 | 无压缩 |
| `BTRFS_COMPRESS_ZLIB` | 1 | zlib |
| `BTRFS_COMPRESS_LZO` | 2 | LZO |
| `BTRFS_COMPRESS_ZSTD` | 3 | zstd |

### 通用字段

| 字段名 | 偏移 | 大小 | 说明 |
|--------|------|------|------|
| `generation` | 0x0 | 8 | 创建此 extent 的事务代次 |
| `ram_bytes` | 0x8 | 8 | 解压后大小 |
| `compression` | 0x10 | 1 | 压缩算法 |
| `encryption` | 0x11 | 1 | 加密算法 |
| `other_encoding` | 0x12 | 2 | 其他编码方式（预留） |
| `type` | 0x14 | 1 | extent 类型 |

### INLINE (type = 0)

数据直接嵌入 item body，不占用独立 extent。仅限整个文件数据可容纳于单个 item 的小文件。

以上限制由 `can_cow_file_range_inline()` 检查，具体条件如下：

- 写入偏移必须为 0（只能从文件开头内联）
- 未压缩大小 ≤ `sectorsize`
- 实际存储字节数 < `sectorsize`（`data_len`，非压缩时即为 `size`，严格小于）
- 大小 ≤ `PAGE_SIZE`
- `data_len` ≤ `max_inline` 挂载选项（默认 2048 字节）
- `data_len` ≤ `BTRFS_MAX_INLINE_DATA_SIZE`（由 `nodesize` 决定的理论上限）
- 必须是整个文件的全部数据
- 文件未加密

**on-disk 布局**：item body 的 `type` 字段（偏移 0x14）之后即为 inline 数据，从结构体 `disk_bytenr` 应有的位置（偏移 0x15）开始，延续至 item body 末尾。`disk_bytenr`、`disk_num_bytes`、`offset`、`num_bytes` 字段不出现在磁盘上。

item body 总大小 = `BTRFS_FILE_EXTENT_INLINE_DATA_START + data_len`（`BTRFS_FILE_EXTENT_INLINE_DATA_START` = 0x15 = 21）

- 非压缩：`data_len` 等于文件大小，`ram_bytes` 等于文件大小
- 压缩：`data_len` 等于压缩后字节数，`ram_bytes` 等于未压缩原始大小

### REG (type = 1) / PREALLOC (type = 2)

完整结构为 53 字节：

| 字段名 | 偏移 | 大小 | 说明 |
|--------|------|------|------|
| `generation` | 0x0 | 8 | 事务代次 |
| `ram_bytes` | 0x8 | 8 | 解压后大小 |
| `compression` | 0x10 | 1 | 压缩算法 |
| `encryption` | 0x11 | 1 | 加密算法 |
| `other_encoding` | 0x12 | 2 | 其他编码 |
| `type` | 0x14 | 1 | `1` 或 `2` |
| `disk_bytenr` | 0x15 | 8 | extent 的磁盘逻辑地址（通过 [Chunk Tree](chunk-tree.md) 转物理地址） |
| `disk_num_bytes` | 0x1d | 8 | extent 占用的磁盘字节数 |
| `offset` | 0x25 | 8 | 此片段在 extent 内的逻辑起始偏移 |
| `num_bytes` | 0x2d | 8 | 此片段的逻辑字节数 |

`offset` 字段允许一个文件 extent 指向已有 extent 的中间部分，用于快照间共享 extent 时只引用其中部分区间。
