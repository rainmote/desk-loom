# DeskLoom · Clojure REPL 控制层

REPL、MCP 和 JSON Lines 共用 `desktop.agent` 的通用多窗口控制服务。连接只检查本机原生服务；必须从窗口列表明确选择 `window_id` 才会取得控制会话。所有应用使用相同的观察、动作、截图和退出接口，不会自动启动应用或创建文档。

本层使用嵌入式 **XTDB 2.2.0**。JDK 和 Maven 缓存在项目 `.runtime/`；数据默认位于 `~/Library/Application Support/DeskLoom/xtdb/`。同一数据库目录只能由一个 REPL 或 Agent 进程持有，可用 `:db-path` 或 CLI `--db-path` 指定其他目录。

## 安装和验证

在项目根目录执行：

```sh
scripts/clj-setup
scripts/clj-test
```

测试涵盖通用 REPL 路由、多会话隔离、工具参数、未知结果不重试、页面记忆、动作回执和历史审计。持久化测试实际启动 XTDB、写入中文记录、关闭重开，并使用两个独立 JVM 验证恢复。测试不会连接或修改真实应用窗口。

## 显式选择窗口

先运行 `dlm open`，为 DeskLoom 授予无障碍权限，再启动 REPL：

```sh
dlm repl
# 源码目录也可运行 scripts/clj -M:xtdb:repl
```

```clojure
(def c (desktop/connect!))
(desktop/status c)
(desktop/windows c)
;; 可以按已经知道的应用 PID 或 bundle_id 缩小列表。
;; (desktop/windows c {:pid 1234})

;; 将下面两个 ID 替换为上一步明确选择的已有窗口。
(def a (desktop/attach! c {:window_id "选定的源窗口 ID"}))
(def b (desktop/attach! c {:window_id "选定的目标窗口 ID"}))
(def sid-a (:session_id a))
(def sid-b (:session_id b))

(def source (desktop/observe! c sid-a {:max_nodes 1000 :max_depth 40}))
(map #(select-keys % [:id :role :identifier :title :value :settable]) (:nodes source))

;; 聚焦指定窗口；不会隐式选择另一个应用或窗口。
(def target (desktop/observe! c sid-b))
(desktop/act! c sid-b {:action "focus" :snapshot_id (:snapshot_id target)})

;; 使用屏幕录制权限截取指定窗口，返回 PNG 数据及坐标比例。
(desktop/screenshot! c sid-b {:max_width 720})
(desktop/history c sid-b)
```

最多控制 8 个窗口。REPL 操作总是显式传入 `session_id`。`attach!` 也可提供 `:pid` 或 `:bundle_id` 检查窗口归属，但仍要求 `:window_id`。重复窗口、其他客户端的会话和跨会话快照会被拒绝。

## 观察、修改和读回

从最新观察中选择唯一且启用的元素。下面的选择器必须替换成目标应用实际返回的语义属性：

```clojure
(def field {:role "AXTextField" :identifier "已从观察中确认的唯一标识"})
(def result
  (desktop/act! c sid-b {:action "set_value" :selector field :value "新的内容"}))
(:outcome result)       ; 可能为 verified、dispatched 或 unknown
(:observation result)   ; 动作后的新 AX 观察；应据此核对实际结果
```

`act!`、`batch!` 在未提供 `:request_id` 时生成一个唯一 ID。语义选择器会先重新观察，只允许精确匹配一个启用元素。使用节点 ID 时还必须提供同一会话最新的 `snapshot_id`。`type_text`、`key`、坐标动作需要先显式 `focus`，再使用新的观察。`batch!` 的所有步骤限制在同一个会话，错误或未知结果会立即停止。

```clojure
(desktop/batch! c sid-b
  [{:action "focus"}
   {:action "set_value" :selector field :value "新的内容"}])

;; 操作结束后，仅释放源窗口，目标窗口仍保持连接。
(desktop/detach! c sid-a)
(desktop/status c)
;; 无论成功、失败或取消，都应执行 close!；释放剩余所属会话并关闭数据库。
(desktop/close! c)
```

`dispatched` 只说明操作已派发；它不等同于任务已完成。发生 `unknown`、连接中断或读回错误时，不要重发该动作。先检查实际窗口，再决定下一步。历史节点和页面记忆不是可执行句柄，必须重新观察。

## 持久化审计

关闭控制器后，可从另一个 JVM 审计记录：

```sh
scripts/clj -M:xtdb -m desktop.audit SESSION_ID
# 自定义数据库时在 SESSION_ID 后提供 DB_PATH。
```

通用审计检查最近一次动作自己的意图、原生回执、完整请求记录和可用页面版本引用，不会拿上一动作的成功结果替代当前动作。输出区分 `verified` 和 `dispatched`；尚未完成、结果未知、会话不匹配或缺失保存的页面版本时拒绝确认。

旧版本已经写入的验证记录仍可只读审计，输出 `:format "legacy-verification"`；新记录为 `:format "computer-agent"`。旧格式不会调用已移除的原生流程。审计结果均标注为历史数据，不能用于执行动作。

```clojure
;; close! 后可重新打开数据库，查询已保存的会话。
(with-open [store (db/open!)] (db/sessions store))
```

- `desktop_events` 保存连接、动作意图和原生结果等事件。
- `desktop_pages`、`desktop_page_versions`、`desktop_page_visits` 保存页面索引、内容去重版本和访问记录。
- `desktop_requests` 保存动作幂等摘要与紧凑回执。派发前同步记录 pending；中断后不会自动重放。
- `desktop_nodes` 保留历史结构化快照查询能力；页面记忆中的历史内容不包含可执行句柄。

数据库不开放 TCP 端口；REPL 具有当前用户权限。MCP 使用 `dlm mcp`，JSON Lines 使用 `dlm agent`，完整工具说明见 [通用 Computer Use 指南](../docs/COMPUTER_USE.md)。
