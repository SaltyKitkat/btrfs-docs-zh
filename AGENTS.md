# AGENTS.md — Btrfs 中文文档写作指南

本仓库是 Btrfs 磁盘格式（On-disk Format）的中文技术文档。LLM 在此仓库生成或修改文档时，遵循以下准则。这些准则提炼自仓库中人工审校的实际改动，反映了本仓库对"好文档"的判断标准。

## 核心原则：准确性优先于流畅

历史上最重要的修正类改动（`fix: correct inaccurate claims across 7 docs after kernel source review` 等）几乎全部针对 LLM 常见错误：

1. **结构体大小与偏移必须逐一核对**，以 `include/uapi/linux/btrfs_tree.h` 为准。LLM 易犯的错误：
   - 忽略尾部数组/柔性成员（如 `btrfs_stripe` 的 `dev_uuid` 使大小为 32 而非 24）
   - inline ref 大小算错（`EXTENT_DATA_REF` 29 字节、`SHARED_DATA_REF` 13 字节）
   - 结构体随特性版本变化（如 `btrfs_block_group_item_v2` 为 36 字节）
2. **Key 三元组必须精确**：objectid/type/offset 各是什么值、什么含义，不要笼统写"设备 ID"，要写 `DEV_ITEMS_OBJECTID (1)` 这类常量名加数值。
3. **机制归因要准确**：不要臆断字段来源（如 root lookup 走 Root Tree 而非超级块字段）；区分内核强制与 btrfs-progs 用户态限制。
4. **类型宽度要核对**：如 `timespec` 秒字段是 `__le64` 无符号，不是有符号。

## 措辞准则：具体、不夸饰、不冗余

从人工改写（reword 类提交）总结的倾向：

- **删掉冗余修饰**。例如"`bytenr` … 和 `level` 一起描述树的根节点位置"被精简为"该树根节点的逻辑地址。"——若信息无增量，宁缺毋滥。
- **避免错误的枚举式概括**。"每个条目对应一个子卷、快照或系统树"被改为"每个条目对应一个树"——分类列举容易遗漏或误导，用更贴近本质的表述。
- **语义区分要落在实际成因上**。"原始子卷为全零"不如"未使用 snapshot 创建的子卷为全零"准确；描述字段取值时说明*何时*出现该值，而非含糊的类别词。
- **术语保持一致**：树 ID、事务代次（generation）、逻辑地址（bytenr）、子卷/快照等译法在各文档间统一。

## 内容深度要求

高质量文档（如 orphan.md、superblock.md 的 sys_chunk_array 章节）体现的深度标准：

1. **不止描述格式，还解释机制与时机**：谁在什么代码路径写入/消费（引用函数名如 `btrfs_add_system_chunk()`、文件如 `fs/btrfs/inode.c`）。
2. **指出上游注释/文档过时之处**并给出证据链：如逐条列出上游提交哈希、结构体大小演变表、容量计算过程（`2048 / 161 = 12.7` → 上限 12 条）。
3. **说明设计动机**：如 orphan item 的 key 排序位置使其便于挂载时线性扫描。
4. **区分同一结构在不同位置的语义差异**（orphan item 在 FS tree vs Root Tree 中 offset 含义不同）。

不确定的内容宁可标注不确定性或留待核实，也不要编造。所有数值（偏移、大小、常量）写入前应对照内核源码验证。

## 格式约定

- 正文为中文；代码、常量、函数名保留英文反引号包裹。
- 每篇文档开头给出树 ID 或概览定位。
- 结构体先贴 `include/uapi/linux/btrfs_tree.h` 的 C 定义（注明头文件路径），后接字段表格：`| 字段名 | 偏移 | 大小 | 说明 |`。
- Key 描述使用统一三元组格式（objectid / type / offset 各一行）。
- 相关概念跨文档使用相对链接（如 `[inode item](fs-tree.md#inode_item-结构)`）。
- 新主题独立成文（如 orphan 从 tree-log 拆出），并在 overview.md/key.md 索引中登记。

## 提交信息约定

- 格式：`<scope>: <祈使句摘要>`，scope 多为 `on-disk-format:` 或涉及的具体文档/主题。
- 摘要下空一行，用 `-` 列表说明各处实质变更（尤其是修正了什么错误、依据是什么）。
- 修正类提交应在正文中点明错误原因或核对依据（如 "after kernel source review"）。
- 进行中的措辞调整可用 `wip:` 前缀，但合入前应替换为规范格式。
