# Superblock（超级块）

超级块是 Btrfs 文件系统的全局元数据结构，列出了文件系统的主要树。

## 位置

主超级块位于偏移量 `0x10000`（64 KiB）处。镜像副本分别位于：

- `0x4000000`（64 MiB）
- `0x4000000000`（256 GiB）

镜像会同时更新。挂载时，内核模块只读取第一个超级块（64 KiB 处），如果检测到错误则挂载失败。Btrfs 只识别在 `0x10000` 处具有有效超级块的磁盘。

副本的存在使得 `btrfs restore` 等工具在主超级块损坏时仍能从其他位置读取超级块，从而恢复数据。

## 结构定义

```c
/* include/uapi/linux/btrfs_tree.h */

/*
 * The super block basically lists the main trees of the FS.
 */
struct btrfs_super_block {
    /* The first 4 fields must match struct btrfs_header */
    __u8 csum[BTRFS_CSUM_SIZE];
    /* FS specific UUID, visible to user */
    __u8 fsid[BTRFS_FSID_SIZE];
    /* This block number */
    __le64 bytenr;
    __le64 flags;

    /* Allowed to be different from the btrfs_header from here own down */
    __le64 magic;
    __le64 generation;
    __le64 root;
    __le64 chunk_root;
    __le64 log_root;

    /*
     * This member has never been utilized since the very beginning, thus
     * it's always 0 regardless of kernel version.  We always use
     * generation + 1 to read log tree root.  So here we mark it deprecated.
     */
    __le64 __unused_log_root_transid;
    __le64 total_bytes;
    __le64 bytes_used;
    __le64 root_dir_objectid;
    __le64 num_devices;
    __le32 sectorsize;
    __le32 nodesize;
    __le32 __unused_leafsize;
    __le32 stripesize;
    __le32 sys_chunk_array_size;
    __le64 chunk_root_generation;
    __le64 compat_flags;
    __le64 compat_ro_flags;
    __le64 incompat_flags;
    __le16 csum_type;
    __u8 root_level;
    __u8 chunk_root_level;
    __u8 log_root_level;
    struct btrfs_dev_item dev_item;

    char label[BTRFS_LABEL_SIZE];

    __le64 cache_generation;
    __le64 uuid_tree_generation;

    /* The UUID written into btree blocks */
    __u8 metadata_uuid[BTRFS_FSID_SIZE];

    __u64 nr_global_roots;
    __le64 remap_root;
    __le64 remap_root_generation;
    __u8 remap_root_level;

    /* Future expansion */
    __u8 reserved[199];
    __u8 sys_chunk_array[BTRFS_SYSTEM_CHUNK_ARRAY_SIZE];
    struct btrfs_root_backup super_roots[BTRFS_NUM_BACKUP_ROOTS];

    /* Padded to 4096 bytes */
    __u8 padding[565];
} __attribute__ ((__packed__));
```

## 字段详解

| 字段名 | 偏移 | 大小 | 类型 | 说明 |
|--------|------|------|------|------|
| `csum` | 0x0 | 0x20 | CSUM | 本字段之后（0x20 到 0x1000）所有内容的校验和。超级块结构体并未占满 `BTRFS_SUPER_INFO_SIZE`（4096 字节），未使用部分以零填充，并包含在校验和范围内 |
| `fsid` | 0x20 | 0x10 | UUID | 文件系统 UUID |
| `bytenr` | 0x30 | 0x8 | UINT | 本块的物理地址（各镜像不同） |
| `flags` | 0x38 | 0x8 | flags | 标志位 |
| `magic` | 0x40 | 0x8 | ASCII | 魔数 `"_BHRfS_M"` |
| `generation` | 0x48 | 0x8 | UINT | 事务代次 |
| `root` | 0x50 | 0x8 | UINT | Root Tree 根节点的逻辑地址 |
| `chunk_root` | 0x58 | 0x8 | UINT | Chunk Tree 根节点的逻辑地址 |
| `log_root` | 0x60 | 0x8 | UINT | Log Tree 根节点的逻辑地址 |
| `__unused_log_root_transid` | 0x68 | 0x8 | UINT | 已废弃，始终为 0 |
| `total_bytes` | 0x70 | 0x8 | UINT | 文件系统总字节数 |
| `bytes_used` | 0x78 | 0x8 | UINT | 已使用字节数 |
| `root_dir_objectid` | 0x80 | 0x8 | UINT | Root Dir Object ID（通常为 6） |
| `num_devices` | 0x88 | 0x8 | UINT | 设备数量 |
| `sectorsize` | 0x90 | 0x4 | UINT | 扇区大小 |
| `nodesize` | 0x94 | 0x4 | UINT | 节点大小 |
| `__unused_leafsize` | 0x98 | 0x4 | UINT | 叶子大小（已废弃） |
| `stripesize` | 0x9c | 0x4 | UINT | 条带大小 |
| `sys_chunk_array_size` | 0xa0 | 0x4 | UINT | 系统 chunk 数组大小 |
| `chunk_root_generation` | 0xa4 | 0x8 | UINT | Chunk Root Generation |
| `compat_flags` | 0xac | 0x8 | UINT | 兼容标志 |
| `compat_ro_flags` | 0xb4 | 0x8 | UINT | 只读兼容标志 |
| `incompat_flags` | 0xbc | 0x8 | UINT | 不兼容标志 |
| `csum_type` | 0xc4 | 0x2 | UINT | 校验和类型：0=CRC32c（默认），1=XXHASH，2=SHA256，3=BLAKE2 |
| `root_level` | 0xc6 | 0x1 | UINT | Root Tree 根节点的层级 |
| `chunk_root_level` | 0xc7 | 0x1 | UINT | Chunk Tree 根节点的层级 |
| `log_root_level` | 0xc8 | 0x1 | UINT | Log Tree 根节点的层级 |
| `dev_item` | 0xc9 | 0x62 | DEV_ITEM | 本设备的 DEV_ITEM 数据 |
| `label` | 0x12b | 0x100 | ASCII | 标签（btrfs-progs 限制不可包含 `'/'` 或 `'\\'`，内核不作校验） |
| `cache_generation` | 0x22b | 0x8 | UINT | 空闲空间缓存 v1 的 generation。非零表示正使用 v1 缓存 |
| `uuid_tree_generation` | 0x233 | 0x8 | UINT | UUID Tree 根节点的事务代次 |
| `metadata_uuid` | 0x23b | 0x10 | UUID | 写入 B-tree 节点的 UUID，可能与 `fsid` 不同 |
| `nr_global_roots` | 0x24b | 0x8 | UINT | 全局根节点数量（CPU 序，非小端） |
| `remap_root` | 0x253 | 0x8 | UINT | Remap Tree 根节点的逻辑地址 |
| `remap_root_generation` | 0x25b | 0x8 | UINT | Remap Tree 根节点的事务代次 |
| `remap_root_level` | 0x263 | 0x1 | UINT | Remap Tree 根节点的层级 |
| `reserved` | 0x264 | 0xc7 | — | 保留（199 字节） |
| `sys_chunk_array` | 0x32b | 0x800 | array | 所有 SYSTEM chunk 的 (KEY, CHUNK_ITEM) 对 |
| `super_roots` | 0xb2b | 0x2a0 | array | 4 个 `btrfs_root_backup` |
| `padding` | 0xdcb | 0x235 | — | 填充至 4096 字节（565 字节） |

## 魔数

```c
/* include/uapi/linux/btrfs_tree.h */

/* ASCII for _BHRfS_M, no terminating nul */
#define BTRFS_MAGIC 0x4D5F53665248425FULL
```

## 备份根节点

为了防止丢失根节点导致无法挂载，超级块中存储了之前事务的根节点数组：

```c
/* include/uapi/linux/btrfs_tree.h */

#define BTRFS_NUM_BACKUP_ROOTS 4
struct btrfs_root_backup {
    __le64 tree_root;
    __le64 tree_root_gen;

    __le64 chunk_root;
    __le64 chunk_root_gen;

    __le64 extent_root;
    __le64 extent_root_gen;

    __le64 fs_root;
    __le64 fs_root_gen;

    __le64 dev_root;
    __le64 dev_root_gen;

    __le64 csum_root;
    __le64 csum_root_gen;

    __le64 total_bytes;
    __le64 bytes_used;
    __le64 num_devices;
    /* future */
    __le64 unused_64[4];

    __u8 tree_root_level;
    __u8 chunk_root_level;
    __u8 extent_root_level;
    __u8 fs_root_level;
    __u8 dev_root_level;
    __u8 csum_root_level;
    /* future and to align */
    __u8 unused_8[10];
} __attribute__ ((__packed__));
```

## 系统 Chunk 数组

`sys_chunk_array` 用于挂载时**自举** Chunk Tree。详见 [Chunk Tree 的自举章节](chunk-tree.md#自举)。

```c
/* include/uapi/linux/btrfs_tree.h */

/*
 * This is a very generous portion of the super block, giving us room to
 * translate 14 chunks with 3 stripes each.
 */
#define BTRFS_SYSTEM_CHUNK_ARRAY_SIZE 2048
```
