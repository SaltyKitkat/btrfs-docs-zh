# RAID Stripe Tree

树 ID `RAID_STRIPE_TREE (12)`。

RAID Stripe Tree 为 RAID profile（DUP、RAID0、RAID1、RAID10）下的**数据** extent 存储物理位置映射。传统 Btrfs 通过 Chunk Tree 中的 stripe 布局将逻辑地址转换为物理地址——给定逻辑地址，按 chunk 的 stripe 公式计算出物理设备位置。RAID Stripe Tree 则改为**逐 extent** 直接记录物理地址，允许更灵活的数据放置。

此树为实验性特性，需要 `RAID_STRIPE_TREE` 不兼容特性启用。仅对数据 block group 生效，元数据和系统 block group 仍使用 Chunk Tree 的 stripe 映射。

RAID Stripe Tree 的根节点作为 `ROOT_ITEM` 存入 [Root Tree](root-tree.md)，key 为 `(RAID_STRIPE_TREE_OBJECTID, ROOT_ITEM_KEY, 0)`。

## Key-Item 结构

RAID Stripe Tree 仅使用一种 key type。item 按 `(objectid, type, offset)` 升序排列，同一逻辑地址范围的 item 在 Tree 中相邻。

| Object ID | Type | Offset | Item 结构 | 说明 |
|-----------|------|--------|-----------|------|
| extent 逻辑起始地址（bytenr） | `RAID_STRIPE_KEY (230)` | extent 逻辑长度（字节） | `struct btrfs_raid_stride[]` | 一段逻辑地址范围到物理设备的直接映射 |

## RAID_STRIPE_KEY (230)

key 的三元组：

- objectid：数据 extent 的逻辑起始地址（bytenr），必须 sectorsize 对齐
- type：230
- offset：extent 的逻辑长度（字节）

item body 为一个或多个 `btrfs_raid_stride` 结构的数组：

```c
/* include/uapi/linux/btrfs_tree.h */

struct btrfs_raid_stride {
    __le64 devid;
    __le64 physical;
} __attribute__ ((__packed__));

struct btrfs_stripe_extent {
    __DECLARE_FLEX_ARRAY(struct btrfs_raid_stride, strides);
} __attribute__ ((__packed__));
```

| 字段名 | 偏移 | 大小 | 说明 |
|--------|------|------|------|
| `devid` | 0x0 | 8 | 此 stride 所在的设备 ID |
| `physical` | 0x8 | 8 | 此 stride 在设备上的物理字节偏移 |

每个 `btrfs_raid_stride` 为 16 字节。item 中 stride 的数量由 item body 大小决定：

```
num_stripes = item_size / sizeof(struct btrfs_raid_stride)
```

stride 数量等于 block group profile 的副本数（`btrfs_bg_type_to_factor()` 返回的 `ncopies`）：

| Profile | stride 数 | 说明 |
|---------|-----------|------|
| RAID0 | 1 | 单副本条带化，每条带仅存储所在设备的位置 |
| RAID1 | 2 | 双设备镜像，各一份副本 |
| RAID1C3 | 3 | 三设备镜像 |
| RAID1C4 | 4 | 四设备镜像 |
| RAID10 | 2 | 镜像对，每对一份副本 |
| DUP | 2 | 同设备双副本 |

SINGLE profile 不使用 RAID Stripe Tree，因为无需区分副本位置。

### 示例：RAID1 下的一个 extent

一个 4 KiB 的数据 extent 在 RAID1 block group 中写入，item body 为 32 字节：

```
strides[0]: devid=1, physical=0x100000   ← 副本 1
strides[1]: devid=2, physical=0x200000   ← 副本 2
```

## 适用范围

RAID Stripe Tree 的写入由 `btrfs_need_stripe_tree_update()` 控制，仅在以下条件**全部**满足时插入条目：

1. `RAID_STRIPE_TREE` 不兼容特性已启用
2. extent 属于 DATA block group（`BTRFS_BLOCK_GROUP_DATA`）
3. block group profile 为 `DUP`、`RAID0`、`RAID1`（含 RAID1C3/RAID1C4）或 `RAID10`

元数据和系统 block group 不产生 RAID Stripe Tree 条目，仍通过 [Chunk Tree](chunk-tree.md) 的 stripe 公式定位。

## 生命周期

**写入**：ordered extent 完成 IO 后，`btrfs_insert_raid_extent()` 遍历 extent 的 `bioc_list`，对每个 `struct btrfs_io_context` 调用 `btrfs_insert_one_raid_extent()` 创建一条 RAID_STRIPE_KEY 条目。若同 key 的条目已存在（-EEXIST），则原地覆写 stride 数组。

**删除**：extent 释放时，`btrfs_delete_raid_extent()` 按逻辑地址范围删除或截断对应条目。支持以下场景：

- 精确匹配：直接删除整条 item
- 前缀截断：保留重叠部分之后的数据（缩短现有 item 的 offset）
- 后缀截断：创建新 item 存放重叠部分之后的数据
- 中间挖空：split 为两条 item，分别保留前后两部分

## 读取路径

读取数据时，`btrfs_get_raid_extent_offset()` 在 RAID Stripe Tree 中查找覆盖目标逻辑地址的条目：

1. 搜索 `(logical, 230, 0)` 或之前最近的条目
2. 确认 `logical` 在条目的 `[objectid, objectid + offset)` 范围内
3. 遍历 stride 数组，找到 `devid` 匹配目标设备的 stride
4. 计算物理偏移：`physical = stride.physical + (logical - key.objectid)`

仅在读路径使用——写路径不查询 RAID Stripe Tree，而是通过 Chunk Tree 确定物理位置后写入，完成后再插入条目记录实际写入位置。

## 与 Chunk Tree 的关系

RAID Stripe Tree 并不替代 Chunk Tree——Chunk Tree 仍负责逻辑→物理的 stripe 映射，供所有元数据 IO 和数据的**写入**路径使用。RAID Stripe Tree 为数据的**读取**路径提供更精确的物理地址：Chunk Tree 的 stripe 布局描述了 block group 的配置方式，而 RAID Stripe Tree 记录了每个独立 extent 实际写入的物理位置。两者同时存在，分工不同。
