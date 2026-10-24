# DeskLoom · Clojure REPL 控制层

本层使用真实嵌入式 **XTDB 2.2.0**，不是 v1/RocksDB API。JDK 和 Maven 缓存保存在项目 `.runtime/`；数据默认保存在 `~/Library/Application Support/DeskLoom/xtdb/`。旧版 `ComputerUsePrototype` 数据目录在应用启动时迁移并保留兼容链接；迁移前控制层仍兼容旧路径。同一数据库目录只允许一个 REPL 或 demo 进程打开。Clojure `desktop.*` 命名空间保持不变。

## 安装和验证

在项目根目录执行：

```sh
scripts/clj-setup
scripts/clj-test
```

测试实际启动本地 XTDB，写入中文快照、动作和验证记录，关闭节点，重新打开同一目录并核对数据；随后用两个独立 JVM 分别写入和恢复中文记录。测试不会操作桌面。第一次加载 XTDB 可能需要约数十秒。

运行 `dlm open` 启动 DeskLoom 并授予无障碍权限后，运行完整 TextEdit 闭环：

```sh
scripts/clj -M:xtdb:demo
```

只创建和修改原生端生成的独立测试文档，不选择已有文档。成功输出同时包含 `:passed true` 和 `:reopened true`。原生端若拒绝请求，demo 会退出非零；超时的动作不自动重发。

## 实时 REPL

```sh
dlm repl
```

源码目录也可使用 `scripts/dlm repl` 或原有的 `scripts/clj -M:xtdb:repl`。安装版 CLI 从应用内配置定位源码和本地运行时；`dlm status` 可先检查原生连接与权限，`dlm settings` 在当前浮窗或工作台内进入设置页面。

```clojure
(def c (desktop/connect!))
(desktop/status c)
(desktop/start! c)
(def snapshot (desktop/ready-snapshot! c))
(map #(select-keys % [:id :role :title :value :settable]) (:nodes snapshot))
(desktop/unique-text-area snapshot)
(desktop/set-text! c "你好，从 Clojure REPL 实时操作 TextEdit。\n")
(desktop/preview c)
(desktop/history c)
(db/text-areas (:store c) (:session_id @(:session c)))
(desktop/stop! c)
(desktop/close! c)

;; 关闭后重新打开同一本地数据库，查询仍然存在的操作历史。
(with-open [store (db/open!)] (db/sessions store))
```

退出上面的 REPL 后，可在独立 JVM 审计真实桌面会话：

```sh
scripts/clj -M:xtdb -m desktop.audit SESSION_ID
```

该命令核对持久化的动作、前后 AX 快照和验证文本，输出 `:independent-process true`；不会操作桌面。打开数据库时会提交一个空事务，等待旧日志完成重放，防止刚重启时查询到未恢复的空状态。

`set-text!` 总是重新观察，再使用同一快照的 `snapshot_id + node_id`。数据库中的旧 token 仅用于审计，不能作为后续操作目标。`stop!` 停止原生会话；`close!` 关闭本地数据库，二者分开，便于检查停止后的历史。

## 同一 REPL 的真实桌面验收

无障碍和屏幕录制权限都已授予、原生端当前没有活跃会话时，在上述持久 REPL 中运行：

```clojure
(require '[desktop.acceptance :as acceptance])
(def c (desktop/connect!))
(def result (acceptance/run! c))
(:outcome result)                 ; 只有整个流程通过才返回 "passed"
(:session_id result)
(:evidence_dir result)
(desktop/history c)              ; XTDB 仍由当前 REPL 持有，可继续查询
(desktop/close! c)               ; 调用方负责关闭；失败后也执行这一行
```

`run!` 不请求系统授权。缺少任一权限会在 `start` 前拒绝；已有活跃会话也会拒绝，以免接管另一轮操作。每次运行只操作原生端新建的 TextEdit 测试文档，并依次检查：

- 两段不同的中文换行文本 A/B，分别经新 AX 快照定位、写入和精确读回；从 XTDB 查询两次验证及对应文本节点。
- A/B 各三帧真实目标窗口预览，序号和捕获时间严格递增；复制的 PNG 必须与原生返回 SHA256 一致，A/B 最后一帧的哈希必须不同。
- 菜单栏 TextEdit 名称与实时缩略图保持显示；紫色角标使用普通窗口层级、鼠标穿透，不能成为 key/main 窗口。可见时必须贴合目标右上角，并随目标宽度变化保持右侧对齐；被其他窗口遮挡或目标不在当前屏幕空间时，允许分别以 `target_covered`、`target_not_visible` 原因隐藏。失去目标、非活跃或未知原因的隐藏不能通过验收。
- 窗口在屏幕可见区域内小幅移动后，核对 AX 与界面记录的目标位置，再恢复原位置。移动前后角标都可见时验证其跟随；任一采样隐藏时记录 `overlay_follow_status=not_observed`，仅确认目标移动，不声称已观察到角标跟随。
- 直接保存 DeskLoom 自身视图渲染与当前界面状态，不主动展开菜单或激活窗口；最后无论成功或失败都尝试 `stop`，成功必须再次确认 `active=false`、`overlayVisible=false`、`previewLive=false`、`statusThumbnailVisible=false`。

当前线程执行 `run!` 时不要从另一线程同时发出 REPL 桌面指令。窗口必须留有小幅移动空间；最大化且完全填满屏幕时验收会明确失败，不自行缩放窗口。发生动作超时不重发该动作，恢复窗口位置会先重新观察再发出独立的恢复请求。移动和停止后仅对状态做有界只读轮询，容纳 AX/AppKit 刷新延迟，不会重复移动或停止动作。

证据默认在项目 `evidence/<真实 session_id>/`，可传 `{:evidence-root "/绝对路径"}` 修改。`rpc.jsonl` 保存每次真实 RPC 的方法、参数、时间及原始 `result` 字段（不记录连接令牌），`text-verifications.json` 保存 A/B 精确读回，`preview-samples.json` 关联六张目标窗口 PNG 和 SHA256，`active-ui.json`、`window-movement.json` 保存显示状态与几何验证，`xtdb-readback.json` 保存数据库查询结果，`result.json` 记录最终成功或失败及停止状态。未能建立会话的失败记录使用 `attempt-<UUID>` 目录，绝不生成成功证据。

目标窗口 PNG 是系统捕获；`ui-*.png` 是 DeskLoom 自身视图渲染，并不是整块桌面截图。只有角标可见时才用其窗口几何数据验证位置；隐藏角标可能保留旧坐标，不能用来证明当前定位，也不能把单独的视图渲染当作其已出现在桌面上的视觉证据。

完成后关闭 `c`，再用前述 `desktop.audit` 命令在独立 JVM 核验同一 `session_id` 的持久化记录。`run!` 不关闭数据库，也不将同一进程的查询冒充重启恢复验证。`scripts/clj-test` 中的 `acceptance-test` 仅测试拒绝缺失权限、旧帧和错误 UI 等纯逻辑，测试通过不代表真实桌面验收通过。

## 数据和失败语义

- `desktop_events`：会话、before/after 快照、动作意图、动作返回、结果验证、停止事件。原始 RPC 数据以 JSON 存在 `payload` 字段。
- `desktop_nodes`：每次快照中的结构化节点，支持 SQL 查询角色、文本、可写状态及历史变化。
- `action-intent` 在动作前同步落库；`action-result` 只表示 RPC 接受／派发，成功由新的 AX 读回值确认。
- 本地数据库使用事务日志与对象存储两个磁盘目录；进程独占锁避免两个嵌入式节点互相损坏数据。不开放数据库 TCP 端口。
- REPL 自身具有当前用户权限；这是本机开发工具，不是安全沙箱。

## 版本依据

- [XTDB v2.2.0 源码](https://github.com/xtdb/xtdb/tree/c6c19623d90c658c15400fb46dc056f3735ed57b)，已核对 `core/src/main/clojure/xtdb/node.clj` 的 `:log`、`:storage`、`:server` 配置和 `pgwire.clj` 对负数端口禁用监听的逻辑。
- [官方 Clojure 驱动说明](https://docs.xtdb.com/drivers/clojure.html)：JDK 21+、Arrow 所需 JVM flags。项目将这些选项放在 `:xtdb` alias。
- [官方本地存储配置](https://docs.xtdb.com/ops/config/clojure.html)。本项目使用 `:log [:local ...]` 与 `:storage [:local ...]`。
- Temurin 21.0.13+9 来自 [Eclipse Adoptium 官方发布](https://github.com/adoptium/temurin21-binaries/releases/tag/jdk-21.0.13%2B9)，安装脚本核对官方 API 给出的 SHA256。
- Clojure CLI 1.12.0.1530 来自 `download.clojure.org`，安装脚本固定下载文件的 SHA256；运行时 Clojure 库固定 1.12.4。
