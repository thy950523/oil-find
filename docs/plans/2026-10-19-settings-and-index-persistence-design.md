# Oil Find 设置与索引持久化设计

日期：2026-10-19
范围：**免费功能**，做进公开仓库。
起因：用户反馈「有些配置不要在每次重新构建或重新安装时都全部清空，应该优先读取用户的配置；只有当设置中提供相关选项、且用户主动选择清空所有配置时，才恢复到默认状态」。

本文所有 `file:line` 指向 `/Users/zhuzhong/superconductor/projects/oil-find`。

## 1. 现状核查

先确认「重装/重建到底清掉了什么」，避免修错地方。核查结论：

| 数据 | 位置 | 重装（`install.sh`） | 更新（`UpdateInstaller`） | 卸载（`uninstall.sh`） |
| --- | --- | --- | --- | --- |
| 偏好项 | `UserDefaults` 域 `com.oiloil.find` | 不动 | 不动 | **默认全删** |
| 文件索引 | `Application Support/Oil Find/index.oilfind` | 不动 | 不动 | **默认全删** |
| 内容索引 | `Application Support/Oil Find/content/index.sqlite` | 不动 | 不动 | **默认全删** |
| AI 主题 / license | `Application Support/Oil Find/` | 不动 | 不动 | **默认全删** |

### 1.1 应用自身从不擦除偏好

所有 `UserDefaults` 写入都由用户动作触发：`SettingsWindow.swift:156,162,174,189,221,222`、`ContentManager.swift:83`、`AITopicManager.swift:81,85`、`UpdateManifest.swift:122,124`、`L10n.swift:11`、`SearchViewController.swift:126,127`。启动路径用的是 `SettingsPreferences.register()`（`SettingsPreferences.swift:14-20`）→ `defaults.register(defaults:)`，是**非破坏性**注册，只补缺、不覆盖。代码里不存在按版本号重置偏好的逻辑。

### 1.2 `install.sh` 与更新流程都不碰当前配置

`install.sh:25-28` 只清理旧产品名 `Sift` 的域与目录。`UpdateInstaller` 只做 `.app` 包替换与 `.oilfind-update-*` 工作区清理（`UpdateInstaller.swift:157-190`），不涉及 `Application Support` 与偏好域。

### 1.3 索引的丢失只发生在「格式版本变更」时

同一格式版本下重装，索引本来就会保留——`IndexManager.start()` 在 `IndexStore.load` 成功、`configFingerprint` 匹配、`cursorIsValid` 通过时直接复用磁盘索引、不重扫（`IndexManager.swift:163-168`）。`IndexConfig.fingerprint`（`IndexConfig.swift:58-65`）只由配置项构成，**不含构建或版本信息**，所以重装不会改变指纹。

真正会丢弃索引的是三处版本门槛：

- 文件索引：`IndexStore+Persistence.swift:61` 的 `guard u32(8) == 4, p[112] <= 1 else { return nil }`，注释明说「旧版本拒绝而非迁移」。同文件 `:90` 的 `expected == data.count` 是精确长度校验，任何布局变化都会让它失败。
- 内容索引：`ContentIndex.swift:144-145` 版本不符直接抛错；`:166-172` 用 `DROP TABLE files/chunks/chunk_fts` 就地重建。
- 配置指纹变化：`IndexManager.swift:379-381` 的 `scanLatestConfigIfNeeded` 在 `store.configFingerprint != fingerprint(config)` 时触发全量重扫。这是**有意行为**（改了排除规则就该重扫），本次不改。

内容索引除 `migrate()` 与设置里的「清除索引」按钮（`ContentManager.swift:174`）外，没有任何其他清除路径。

## 2. 目标与不做

**做**：

1. 偏好项不被 `install.sh` / 卸载 / 更新清空；只有用户在设置里主动「清空所有配置」才恢复默认。
2. 文件索引的格式演进不再等于数据清零——纯追加型变更不再 bump 格式版本（3b）。
3. 无法避免的重建不再表现为「搜索结果是空的」（3c）。

**不做**：

- 不为已存在的 v2/v3 文件索引补迁移解析。当前 v4 的拒绝逻辑原样保留，这些老文件该丢还是丢。用户确认接受这个边界。
- 不改 AI 主题索引的重建方式（`AITopicIndex.swift:186` 有同类问题，记为后续项）。
- 不改「配置指纹变化触发全量重扫」这条有意行为。

## 3. 第 1 部分：`uninstall.sh` 默认保留偏好

**现状**：`uninstall.sh:43` 无条件 `defaults delete com.oiloil.find`，只在删除前把三个 `proEvaluation*` 键读出来、删完再写回（`:44-49`）。`Tests/Scripts/test_uninstall.py:57` 把这个行为固化成断言 `values == {}`。

**改法**：

- **默认（无参数）**：删 `/Applications/Oil Find.app` 与 `Application Support/Oil Find`；**保留** `com.oiloil.find` 偏好域全部内容，保留两个 keychain 锚点。索引是派生数据且体积大，仍在默认卸载范围内。
- **`--purge`**：在默认行为之上，额外删除 `com.oiloil.find` 偏好域，并删除 `com.oiloil.find.pro.evaluation` 与 `com.oiloil.find.trial` 两个 keychain 项。语义从「连试用锚点一起清」扩为「彻底清除」，仍是单一开关，不引入新的命令行概念。

**连带删除**：`:44-49` 那段「先读三个锚点、删域、再写回」的抢救逻辑整段移除——默认不再删域，抢救没有意义。

**文案**：`:9-17` 的删除清单要改成「设置：保留」，并在 `--purge` 分支单独说明会一并删除设置与试用锚点。

**测试**：`Tests/Scripts/test_uninstall.py` 按新语义重写。注意 stub 的 `defaults delete` 会把 state 直接写成 `{}`，所以默认用例应改为断言 `defaults delete` **未被调用**且偏好原样保留；`--purge` 用例断言被清空且两个 keychain 项都被删。

## 4. 第 2 部分：设置中的「清空所有配置」

**入口**：`SettingsWindow.swift:239` 的 `body` 末尾、`excludedTypes` Section（`:389-391`）之后、`.frame` 之前，新增一个 Section，标题走 L10n 新键 `settings.reset`，内含一个破坏性按钮（红色文字）。

**清空范围**——删 `com.oiloil.find` 域下**除保留键外**的全部键：

| 键 | 处理 | 理由 |
| --- | --- | --- |
| `proEvaluationStartedAt` / `proEvaluationLastSeenAt` / `proEvaluationEndedAt` | **保留** | 由私有 Pro 模块写入的试用期锚点。应用内清空若抹掉它们，等于免费重置试用。`uninstall.sh:44-46` 也一直在专门抢救这三个键 |
| `legacyAuthorizationCleanupCompleted`（`LegacyAuthorizationCleanup.swift:7`） | **保留** | 否则每次清空都会重跑一遍旧授权清理 |
| 其余全部键 | 删除 | 热键、拼音、排除扩展名/目录、预览、语言、索引开关、排序、内容搜索开关、AI 主题开关、自动更新等 |

**不动的**：keychain（`--purge` 的职责）；索引文件（偏好被重置后 `IndexConfig.fingerprint` 必然变化，`IndexManager.swift:379-381` 会自己触发全量重扫并覆盖旧索引，不需要手动删）；内容索引与 AI 主题（各有自己的「清除索引」按钮，不属于「配置」）。

**生效方式**：确认弹窗 → 清空 → **重启应用**。

- 确认弹窗照 `ExternalDriveCatalog.confirmRemove`（`ExternalDriveCatalog.swift:210-221`）的 `NSAlert` + `beginSheetModal(for:)` 模式，文案说明「将恢复所有设置为默认值，并重启应用」。
- 选重启而非就地重读，是因为配置快照散在三处：`SettingsModel` 的约 15 个 `@Published`、`IndexManager` 持有的 `config`、`AppDelegate` 已注册的 `HotKey`。就地重读要逐个重建这些状态，漏一个就是「界面显示默认值、实际仍在用旧值」的隐蔽 bug；重启的状态面最小，语义上也最贴合「恢复到默认状态」。

**连带改动**：

- `SettingsWindow.swift:82-85` 的 `contentHeight` 公式要加上新 Section 的高度。
- 设置窗口快照测试（`Tests/OilFindUITests/CoverageSourcesUITests.swift`、`LanguageTests.swift`、`M26UITests.swift`、`ExternalDriveTests.swift`、`AITopicTests.swift`）可能要跟着更新。
- L10n 新增中英对应键（`L10n.swift`，遵守 `AGENTS.md` 的文案维护约定）。

## 5. 第 3 部分：索引跨版本保留

### 5.1 3b：格式版本只在布局重排时 bump

**现状**：写端硬编码 `put32(4, 8)`（`IndexStore+Persistence.swift:38`），读端硬编码 `guard u32(8) == 4`（`:61`）。于是**任何**布局变化都必须 bump 版本，而 bump 版本就等于让所有用户重建索引。

**改法**：引入扩展表，把「纯追加」的布局变化从版本号里剥离出来。

文件头 `128..<256` 这 128 字节目前完全空闲（已用字段止于 `scopeFingerprint` 的 `120..128`），用它承载扩展表：

```
u32  @128        扩展项数 N
     @132+16i    u32 id         扩展编号
     @136+16i    u64 offset     扩展段在文件中的绝对偏移
     @144+16i    u64 length     扩展段长度
```

128 字节可容纳 7 项。扩展段紧跟在 `coverage` 之后，按 offset 升序排列。

约定：

- **纯追加字段**（v4 新增 `mtimeNsec` 就是这种）**不再 bump 版本**，改为在尾部追加一个扩展段 + 在扩展表里登记一位。
- 读端：忽略未知的扩展编号，按已知段计算 `expected`，长度校验从 `expected == data.count` 改为 `expected + Σlength == data.count`。
- 写端：`fileLength`（`IndexStore+Persistence.swift:7`，用于空间预检）要加上扩展段总长。
- 扩展编号一经分配，含义永久固定；废弃的扩展保留编号、写零长度，不复用。
- 版本号从此**只在条目布局真正重排**时 bump（例如 `parent` 从 u32 数组改成 delta 编码）。

**基线**：v4 就是新机制的基线，不做回溯改造。对已存在的 v2/v3 文件无效，仍按当前逻辑拒绝——这一点用户已确认接受。

**收益**：从下一次格式变更起，追加型演进不再丢索引，也不需要维护历史解析分支（这是 3a 被否掉的原因：历史分支是长期负债，且只救得了已经发生的 v2/v3）。

### 5.2 3c：重建不再破坏性地清空

**文件索引：已经满足，无需改动。** `IndexManager.scan()` 只在扫描结束、reconcile 完成之后才发布新 store（`IndexManager.swift:272` 的 `self.currentStore = installed`），所以 rescan 期间旧 store 一直在服务搜索。本次不改代码，只补一个测试把这个不变量固定住，防止以后有人把发布时机提前。

至于版本门槛导致 `IndexStore.load` 返回 nil 的那条路径——旧文件本身就读不出来，没有「旧索引」可供服务，3c 无能为力，只能靠 5.1 从源头避免。

**内容索引：需要改。** `ContentIndex.migrate()`（`ContentIndex.swift:166-172`）在 schema 不符时**打开即** `DROP TABLE`，旧内容从那一刻起不可搜索，直到全量重解析完成。内容索引要跑文本解析和图片 OCR，全量一轮可能以小时计，这个窗口很长。

改为旁路重建 + 原子替换：

1. `migrate()` 检测到 `storedVersion() != schemaVersion` 且连接可写时，不在原库上 DROP。
2. 在同目录（`Application Support/Oil Find/content/`，目录 0700、文件 0600，与现有约定一致）另建 `index.next.sqlite`，在新库上建 schema、写 `user_version = schemaVersion`。
3. `writer` 与 `ContentIndexer` 指向新库；`reader` 继续打开 `index.sqlite` 只读，搜索照常返回旧结果。
4. 重解析跑完后：关闭 writer，把 `index.next.sqlite`（连同 WAL 的 `-wal` / `-shm` 边车文件）`rename` 成 `index.sqlite`，重开 reader，替换 `provider` 持有的 index 引用。
5. 启动时若发现遗留的 `index.next.sqlite`，直接删除重来——旧库完好，无损。

**边界与失败处理**：

- 重解析期间的文件变更仍走既有的 `pendingChange` 机制（`ContentManager.swift:52-56`）在新库上补一轮，`generation` / `cancelled` 语义不变。
- 新库建失败：保留旧库与旧 schema，下次启动重试，**绝不删旧库**。
- 替换完成前，内容搜索返回的是旧 schema 的结果（可能缺少新文件）。这是有意的取舍：比「什么都没有」好。
- `usesWAL` 为 false 的降级路径（网络家目录）同样适用，只是新旧库都不开 WAL。

**被否掉的替代方案**：把旧库改名留存、在新索引查不到结果时回退查旧库。它省掉一次替换，但把复杂度推到了查询路径上（去重、排序、结果合并），而查询路径是热路径。旁路 + 原子替换把复杂度留在写入侧，更划算。

## 6. 测试

| 主题 | 测试 |
| --- | --- |
| 卸载保留偏好 | `Tests/Scripts/test_uninstall.py` 默认用例断言偏好原样保留、`defaults delete` 未被调用；`--purge` 用例断言偏好与两个 keychain 项都被删 |
| 清空所有配置 | 保留键（三个 `proEvaluation*` + `legacyAuthorizationCleanupCompleted`）不被删；其余键被删；keychain 不受影响 |
| 3b 扩展表 | 追加扩展段后旧读端仍能读取；长度校验按 `expected + Σlength` 通过；未知扩展编号被忽略；空间预检计入扩展段 |
| 3c 文件索引不变量 | rescan 进行中旧 store 仍可查询，直到新 store 发布 |
| 3c 内容索引 | schema 不符时旧库仍可搜索；替换后新库生效；遗留 `index.next.sqlite` 被清理；新库建失败时旧库保留 |
| 快照 | 设置窗口快照测试按新 Section 更新 |

CI 通过 `CI=true` 跳过时间敏感或依赖本机真实索引的测试，本地照常运行。

## 7. 落地顺序与风险

建议顺序：第 1 部分（独立、低风险）→ 第 2 部分（独立、中等）→ 3c 内容索引（独立、中高）→ 3b（改动索引格式，风险最高，且**必须**在所有既有索引格式工作稳定之后动）。

主要风险：

- **3b 改的是索引文件格式本身。** 扩展表的写入与读取必须同批次落地，中间态会让索引读不出来——而那正好是本次要消除的故障。落地时必须保证「写扩展表」和「读扩展表」在同一个提交里，并且 v4 基线路径有回归测试。
- **3c 内容索引涉及双连接与文件替换。** 崩溃窗口、WAL 边车文件、以及替换时 reader 的重开都需要测试覆盖，否则可能丢掉整个内容索引——同样正是本次要消除的故障。
- 第 1 与第 2 部分没有这类风险，可以先行合入。
