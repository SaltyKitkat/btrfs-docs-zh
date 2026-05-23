# UUID Tree

树 ID `UUID_TREE (9)`。

UUID Tree 维护子卷/快照的 UUID 到子卷 ID 的映射，为 send/receive 操作提供按 UUID 快速查找子卷的能力。每个 UUID 对应一个或多个子卷 ID（因快照可共享相同 UUID）。

UUID Tree 的根节点作为 `ROOT_ITEM` 存入 [Root Tree](root-tree.md)，key 为 `(UUID_TREE_OBJECTID, ROOT_ITEM_KEY, 0)`。若挂载时不存在，内核会自动创建并启动后台扫描填充已有子卷的条目。

## Key-Item 结构

UUID Tree 的 key 并不直接存储语义化的字段值，而是将 16 字节的 UUID 拆分为两个 64 位值作为 `objectid` 和 `offset`，结合 `type` 构成完整的 key。

| Object ID | Type | Offset | Item 结构 | 说明 |
|-----------|------|--------|-----------|------|
| UUID 前 8 字节（LE） | `UUID_KEY_SUBVOL (251)` | UUID 后 8 字节（LE） | `__le64[]` | 子卷自身的 UUID 到子卷 ID 的映射 |
| UUID 前 8 字节（LE） | `UUID_KEY_RECEIVED_SUBVOL (252)` | UUID 后 8 字节（LE） | `__le64[]` | 接收到的子卷 UUID（`btrfs receive` 设置）到子卷 ID 的映射 |

item body 为 `__le64` 子卷 ID 的数组。多个子卷可共享同一 UUID（例如快照），因此单个 key 下可能存储多个子卷 ID。数组按插入顺序排列。

## UUID 到 Key 的编码

```c
/* fs/btrfs/uuid-tree.c */

static void btrfs_uuid_to_key(const u8 *uuid, u8 type, struct btrfs_key *key)
{
    key->type = type;
    key->objectid = get_unaligned_le64(uuid);
    key->offset = get_unaligned_le64(uuid + sizeof(u64));
}
```

16 字节的 UUID 按 little-endian 拆分为两个 `u64`：

```
key.objectid = le64_to_cpu(uuid[0..7])
key.offset   = le64_to_cpu(uuid[8..15])
```

## UUID_KEY_SUBVOL (251)

子卷自身的 UUID（`root_item.uuid`）到子卷 ID 的映射。每个子卷创建或快照时插入。

key 的三元组：

- objectid：子卷 UUID 的前 8 字节（LE u64）
- type：251
- offset：子卷 UUID 的后 8 字节（LE u64）

item body 为 8 字节对齐的 `__le64` 子卷 ID 数组。添加新条目时，若 key 已存在则扩展已有 item 在末尾追加，若不存在则创建新 item。

条目在以下时机添加：

- 子卷创建（`btrfs_ioctl_create_subvol`）
- 快照创建（`create_snapshot`，包含对子卷自身 UUID 的映射）
- 首次挂载旧文件系统时后台扫描（`btrfs_uuid_scan_kthread`）

条目在子卷删除时移除。

## UUID_KEY_RECEIVED_SUBVOL (252)

btrfs send/receive 中接收方的子卷 UUID（`root_item.received_uuid`）到子卷 ID 的映射。仅在 `received_uuid` 非零（即此子卷由 `btrfs receive` 创建或已被设置 `received_uuid`）时存在。

key 的三元组：

- objectid：received UUID 的前 8 字节（LE u64）
- type：252
- offset：received UUID 的后 8 字节（LE u64）

item body 格式与 `UUID_KEY_SUBVOL` 相同（`__le64` 子卷 ID 数组）。

条目在以下时机添加：

- `btrfs receive` 创建子卷时
- 显式设置 `received_uuid`（`BTRFS_IOC_SET_RECEIVED_SUBVOL`）时：先移除旧的 `UUID_KEY_RECEIVED_SUBVOL` 条目，再添加新条目

条目在子卷删除时移除。

## 条目溢出与回退

单个 key 的 item body 必须在单个 leaf 中。插入前通过 `btrfs_uuid_tree_check_overflow()` 检查：

```
sizeof(struct btrfs_item) + item_size + sizeof(u64) > BTRFS_LEAF_DATA_SIZE
```

若添加新子卷 ID 会导致溢出，插入失败（返回 `-EOVERFLOW`）。对于快照场景，此错误可忽略——send/receive 能通过遍历 Root Tree 回退查找。对于 `btrfs receive` 场景，此错误会中止事务以确保一致性。

## 条目清理

挂载时，`btrfs_uuid_tree_iterate()` 遍历 UUID Tree 中所有条目，逐条验证对应的子卷是否仍然存在且 UUID 匹配：

- 若子卷已被删除：移除该条目
- 若子卷的 UUID 或 `received_uuid` 已变更：移除旧条目

此机制确保 UUID Tree 在子卷的完整生命周期内保持一致，防止 send/receive 根据过时条目查找不存在的子卷。

## 与子卷的关系

- 每个子卷（非零 UUID）在 UUID Tree 中至少有一个 `UUID_KEY_SUBVOL` 条目
- 由 `btrfs receive` 创建的子卷还有一个 `UUID_KEY_RECEIVED_SUBVOL` 条目
- 快照与源子卷共享相同 UUID，它们的子卷 ID 存储在同一 key 的 item body 数组中
- send 操作不从 UUID Tree 读取——它直接使用 `root_item.uuid` / `root_item.received_uuid`
- receive 操作通过 UUID Tree 按 received UUID 查找接收方已有的子卷克隆源
