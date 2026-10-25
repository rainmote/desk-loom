# DeskLoom 通用 Computer Use 接入

DeskLoom 将桌面操作封装为与模型厂商无关的工具：LLM Agent 通过 MCP stdio 或 JSON Lines 调用常驻 Clojure 控制层，由已签名的 macOS 应用执行真实操作；访问过的页面以语义快照保存在本机 XTDB。Agent 负责理解任务和判断业务结果，DeskLoom 负责目标校验、动作执行、结果读回和本地记忆。

目前只有 **macOS 原生后端**。通用指的是 Agent 接入协议及窗口选择不限定应用名称或 Bundle ID，并不表示已实现 Windows、Linux、远程桌面或全部应用的自动化适配。应用能暴露多少语义节点，取决于它的 macOS Accessibility 支持；Canvas、游戏、特殊控件可能需要窗口截图和坐标操作。产品不含自动启动编辑器或新建测试文档的专用流程。

## 架构与运行边界

```text
Codex / Claude / Cursor / Gemini / VS Code / 自定义 Agent
               │ MCP stdio 或 JSON Lines
               ▼
       常驻 Clojure 控制进程
       工具校验 · 串行动作 · 页面记忆 · 耗时统计
            │                      │
            │ 本地带令牌 RPC        └─ 本机嵌入式 XTDB 2.2
            ▼
   /Applications/DeskLoom.app
   macOS Accessibility · CGEvent · ScreenCaptureKit
            │
            ▼
       明确选择的 1–8 个应用窗口
```

- 原生应用承担系统授权身份；Agent 无须分别获取 DeskLoom 的无障碍权限。读取 AX 和控制窗口需要无障碍权限，截图另需屏幕录制权限。
- 原生 RPC 只监听 `127.0.0.1`，控制层从私有 endpoint 文件读取令牌。不要把该内部 RPC 当作远程 MCP HTTP 服务发布。
- MCP stdio 进程必须运行在要操作的 Mac 上。云端 Agent 在云主机启动同名命令，不会自动获得这台 Mac 的桌面。
- 原生应用同时接受最多 8 个窗口会话，同一窗口不能重复连接。每个 XTDB 数据目录同时只允许一个控制进程持有，该进程可管理多个窗口。默认目录已被其他进程占用时需先关闭占用者或使用另一个 `--db-path`。
- 同一控制进程串行执行工具，每个窗口的快照和观察选项独立保存。多个窗口同时连接时，observe/act/batch/screenshot/detach 必须显式提供 `session_id`；只有一个会话时可省略以兼容旧调用。输入前仍需显式聚焦相应窗口。
- 默认数据库是 `~/Library/Application Support/DeskLoom/xtdb/`，数据不写入远端 XTDB 或云服务。页面文本可能包含应用里的工作内容；接入的 Agent 仍会收到工具所返回的内容。

## 安装与启动

在源码目录准备项目本地 Clojure/JDK 运行时，构建并启动已签名应用：

```sh
scripts/clj-setup
bash scripts/build-native.sh
scripts/dlm status
```

构建脚本会安装到 `/Applications/DeskLoom.app` 并自动重启，随后检查 RPC 就绪状态。它使用固定签名身份；活跃控制会话期间拒绝更新。已有安装可用 `scripts/dlm open` 启动。系统授权在 DeskLoom 设置中完成，以 `status` 返回的实际权限为准。

启动一种控制入口并保持进程运行：

```sh
scripts/dlm mcp
```

或供自定义程序使用：

```sh
scripts/dlm agent
```

两种入口支持可选参数：

```sh
scripts/dlm mcp --db-path /absolute/path/to/xtdb --endpoint /absolute/path/to/endpoint.json
scripts/dlm agent --db-path /absolute/path/to/xtdb
```

`--endpoint` 指向原生应用生成的 endpoint JSON 文件，不是远程服务 URL。集成配置应使用可执行文件的绝对路径，以免 GUI 应用的 `PATH` 和工作目录与终端不同。源码入口及安装版 `dlm` 的 Clojure 功能仍依赖保留的源码目录和 `.runtime/`。

## 工具接口

具体参数以 MCP `tools/list` 返回的 JSON Schema 为准；JSON Lines 使用相同工具名与参数。

| 工具 | 参数要点 | 行为 |
| --- | --- | --- |
| `computer_capabilities` | `{}` | 查询平台、系统权限、支持动作、按键、坐标约定和快照有效期。 |
| `computer_windows` | `bundle_id?`、`pid?` | 列出应用窗口及 `window_id`，返回枚举是否完整。 |
| `computer_attach` | `window_id`，或能唯一定位窗口的 `bundle_id` / `pid` | 连接指定窗口，并返回初次观察及本地页面记忆标识。多匹配时拒绝猜测。 |
| `computer_observe` | `delta?`、`since_snapshot_id?`、`max_nodes?`、`max_depth?` | 读取新 AX 快照并存入 XTDB；默认返回完整节点列表。 |
| `computer_act` | `request_id`、`action`，及当前 `snapshot_id` / `node_id` 或语义 `selector` | 执行一次动作，随后再次观察；可用 `observe_after: false` 缩减返回体，页面仍会保存。 |
| `computer_batch` | `request_id`、`steps` | 顺序执行最多 20 步，每步重新观察并解析目标；失败或结果不明时停止。 |
| `computer_screenshot` | `max_width?` | 按需捕获已连接窗口，返回 PNG、坐标缩放信息和对应的新观察。 |
| `computer_detach` | `session_id?` | 只结束指定窗口控制；多个会话时必须指定，不影响其他窗口。 |
| `computer_memory_search` | `query?`、`bundle_id?`、`limit?` | 搜索本地已保存页面；`limit` 为 1–100，默认 20。 |
| `computer_memory_recall` | `page_id` | 返回该页面最新保存的语义内容和历史选择器建议。 |
| `computer_metrics` | `{}` | 返回各工具调用次数、总耗时、最近耗时和最大耗时。 |

`computer_attach` 可连续调用，每次返回独立 `session_id`。对 `computer_observe`、`computer_act`、`computer_batch`、`computer_screenshot` 也可传入该字段；多窗口时必填，跨窗口节点或快照会被拒绝。批次中的所有步骤属于顶层 `session_id`，跨窗口任务需分别调用工具。`computer_capabilities` 返回会话列表与控制窗口数量；退出控制进程会释放其拥有的全部会话，原生 `stop` / 界面「停止全部操作」释放全部控制窗口。

`computer_act` 的动作字段：

| `action` | 主要参数 | 执行方式与条件 |
| --- | --- | --- |
| `focus` | 当前 `snapshot_id` | 显式激活应用并提升目标窗口。之后使用新观察再输入。 |
| `click` | `node_id` / `selector`，或 `x`、`y` | 优先 `AXPress`；不能语义点击时使用窗口内坐标，要求目标在前台。 |
| `set_value` | `node_id` / `selector`、`value` | 直接写入支持 AXValue 的控件；普通文本会进行精确读回。 |
| `type_text` | `text`，可选目标节点 | 合成 Unicode 键盘输入，最多 4096 个 UTF-16 单元；目标窗口及输入控件必须已有焦点。 |
| `key` | `key`、`modifiers?` | 合成按键。支持键名通过 `computer_capabilities` 查询。 |
| `scroll` | `x`、`y`、`delta_x?`、`delta_y?` | 在窗口内目标点滚动；必须保持前台焦点。 |
| `drag` | `x`、`y`、`to_x`、`to_y` | 起点和终点均在目标窗口内，且命中该窗口。 |

语义选择器对节点字段进行精确匹配，例如 `{"role":"AXTextArea","settable":true}`。选择器必须在新的完整观察中唯一匹配一个可用节点；零个或多个匹配都不会执行。历史选择器只提供定位线索。

观察默认最多 300 个节点、24 层；较复杂页面可调用 `computer_observe` 设置 `max_nodes: 1000`、`max_depth: 40`。这些上限会保留到该控制进程的后续观察及选择器解析。超过节点、深度、时间或文本预算时返回 `complete: false`，不能声称完整匹配；仍可对新快照中的明确节点操作，或按截图走坐标路径。

`set_value` 内容上限为 100000 个 UTF-8 字节。`type_text` 仅表示向目标应用发送 Unicode 事件，应用是否接受仍需观察确认；能直接设置 AXValue 时优先使用 `set_value`。

坐标使用桌面逻辑点：主显示器左上为原点，向右为正 X，向下为正 Y；其他显示器可以有负坐标。截图像素应按返回的 `window_bounds`、`scale_x`、`scale_y` 转换：`x = window_bounds.x + pixel_x / scale_x`，Y 同理。不能把缩小截图的像素直接当成桌面坐标。

截图返回 `capture_match`，记录本次窗口关联的检查结果：

| 字段 | 含义 |
| --- | --- |
| `mode` | `exact_title`、`application_suffix` 或 `middle_ellipsis`，分别表示完整标题、去除精确应用名后缀、中间省略形式匹配。 |
| `cg_window_id` | 本次使用的系统窗口编号；不同于 `computer_windows` 返回的 `window_id`。 |
| `sc_geometry_candidates` | 同进程截图窗口列表中，几何位置符合目标的候选数；省略路径必须为 `1`。 |
| `ax_state_stable` | 成功响应中为 `true`，表示目标 AX 标题及边界读取成功，查询前后及截图后保持一致。 |
| `ax_geometry_candidates` | 仅省略路径返回，值为 `1`。 |
| `ax_selected_window_confirmed` | 仅省略路径返回，值为 `true`，表示唯一的 AX 几何候选与已连接的 AX 对象相同。其他模式不返回此字段。 |

Chrome 的 AX 标题可能带应用名后缀，而系统截图接口可能提供中间含一个 `…` 的缩略标题。每个候选分别按上述规则分类；同进程、几何相符且标题符合任一种规则的候选必须只有一个。完整标题候选与省略标题候选同时匹配也会拒绝，不能用完整标题优先来消除歧义。

中间省略只接受一个内部 `U+2026`，两侧均须非空并精确匹配完整标题的两端；完整标题必须更长，且自身不含 `U+2026`。这一限制不影响包含省略号的完整标题精确匹配。省略路径还要求同进程截图窗口列表在目标几何位置只有一个候选，并完整读取同进程全部 AX 窗口的几何信息、确认其中唯一匹配者就是已连接对象；不可读或枚举不完整时拒绝。已有系统窗口编号不得被另一个编号替换。此关联依赖应用与系统公开的窗口元数据，不能视为系统提供的 AX 与截图窗口身份映射。

匹配失败时，`error.details`（MCP 工具结果中的 `details`）保留有界的同进程窗口诊断：AX 前后状态和读取错误、候选标题/边界、匹配计数等。标题属于不可信页面元数据；诊断最多 32 个候选、每个标题最多 512 字节。它不会使不明确的目标被自动重试或执行。

## 推荐操作闭环

1. 读取 `computer_capabilities`，确认权限和实际支持的动作。
2. 调用 `computer_windows`，选择返回的明确 `window_id`，再调用 `computer_attach`。
3. 从观察结果获取当前 `snapshot_id` 和目标 `node_id`，或构造唯一语义选择器。
4. 分配新的 `request_id`，调用 `computer_act`。键盘输入和坐标动作前先显式 `focus`，使用 focus 后的新观察；点击输入控件后也需要再次观察确认焦点。
5. 检查动作回执以及后续观察中的真实变化；业务效果未确认时继续只读观察。
6. 后续任务可先用 `computer_memory_search` / `computer_memory_recall` 找回页面结构，再对当前窗口重新观察、唯一定位。完成后 `computer_detach`。

原生快照有效期为 15 秒，每次动作后消耗旧快照。窗口位置、标题、节点身份、旧值或焦点变化都可能使目标过期；收到 `stale-target` 应重新观察。观察本身也会产生新的快照，因此总要引用最新返回的标识。

`request_id` 是业务动作幂等标识，与 JSON-RPC 的消息 `id` 不同。同一动作标识和相同参数再次提交只返回已有记录；不同参数复用标识会被拒绝。发生超时、断连或持久化中断时不会自动重放动作，应先观察当前状态。不能通过换一个标识盲目重试可能已执行的点击或按键。

批量步骤不接受历史 `snapshot_id` 或 `node_id`；元素动作使用 `selector`，由服务端为每步解析最新目标。坐标步骤仍需要满足窗口范围、前台焦点和命中校验。

回执的 `verified` 只表示已实现的局部读回验证，例如普通文本 `set_value` 精确匹配；`dispatched` 表示已发送动作，仍需检查页面；`unknown` 表示结果不明。批量执行的整体返回也不承诺业务任务成功。

## MCP 与自定义 JSON Lines

MCP 入口接收标准 JSON-RPC 消息，提供工具发现和调用。它使用兼容初始化握手的 MCP 修订版；实际协商版本以 `initialize` 响应为准。调用示意：

```json
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"example-agent","version":"1.0"}}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"computer_windows","arguments":{}}}
```

程序应先读取初始化响应，再发送后续消息。每行是一个紧凑 JSON 对象，字符串中的换行需要 JSON 转义。stdout 仅用于协议，日志写 stderr；关闭 stdin 结束桥接进程。结构错误使用 JSON-RPC 错误，桌面执行错误通过工具结果 `isError` 告知 Agent。[MCP stdio 规范](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports)、[工具结果及错误](https://modelcontextprotocol.io/specification/2025-11-25/server/tools)

MCP `2026-07-28` 引入了不同的无握手协议。此入口不宣称支持该现代协议；支持双版本机制的客户端可以从 `server/discover` 探测失败回退到 `initialize`。只实现现代协议的客户端需使用兼容配置或另外增加适配。[MCP 版本兼容规则](https://modelcontextprotocol.io/specification/2026-07-28/basic/versioning)

不使用 MCP 的程序可启动 `scripts/dlm agent`，按行发送：

```json
{"id":"list-1","tool":"computer_windows","arguments":{}}
{"id":"attach-1","tool":"computer_attach","arguments":{"window_id":"从列表选出的窗口 ID"}}
{"id":"read-1","tool":"computer_observe","arguments":{}}
{"id":"act-1","tool":"computer_act","arguments":{"request_id":"本次动作的唯一 ID","action":"click","snapshot_id":"最近观察的快照 ID","node_id":"目标节点 ID"}}
{"id":"search-1","tool":"computer_memory_search","arguments":{"query":"页面标题或内容片段","limit":10}}
{"id":"recall-1","tool":"computer_memory_recall","arguments":{"page_id":"搜索结果的 page_id"}}
```

示例中的标识是占位内容，必须使用前一响应中的真实值。程序逐条发送、读取对应响应并检查结果，再决定下一步；不要把整段示例直接作为无需判断的动作脚本。

正常 JSON Lines 响应使用 `{"id":"…","ok":true,"result":{…}}`，调用异常使用 `{"id":"…","ok":false,"error":{…}}`。动作结果不明、批次停止或观察失败时，也可能返回 `ok: false` 和完整的 `result`。即使 `ok` 为 true，`dispatched` 仍只是已发送动作，必须检查 `result.outcome` 和后续页面变化。

## 主流 Agent 配置示例

以下只展示配置格式，不会修改本机 Agent 设置。替换 `/absolute/path/to/desk-loom/scripts/dlm` 为实际绝对路径；先完成 DeskLoom 安装、运行时准备与系统授权。每次只让一个客户端持有默认 XTDB。

### Codex CLI 与桌面应用

已验证 Codex CLI `0.157.1` 的 stdio 注册方式。安装后的入口位于 `~/.local/bin/dlm`；以下命令让 shell 将 `$HOME` 展开为当前用户的绝对路径，无须把其他机器的用户名写入配置：

```sh
codex mcp add deskloom -- "$HOME/.local/bin/dlm" mcp
codex mcp get deskloom --json
```

全局配置默认保存到 `~/.codex/config.toml`。将已有 `[mcp_servers.deskloom]` 段的启动超时设为 30 秒、工具超时设为 120 秒，为本地运行时首次加载留出时间。下面只打印包含本机绝对路径的完整配置段，供合并到已有配置；不要追加重复的同名段：

```sh
python3 - <<'PY'
import json
from pathlib import Path

print('[mcp_servers.deskloom]')
print('command = ' + json.dumps(str(Path.home() / '.local/bin/dlm')))
print('args = ["mcp"]')
print('startup_timeout_sec = 30')
print('tool_timeout_sec = 120')
PY
```

同一 Codex 主机上的桌面应用、CLI 和 IDE 扩展共享 MCP 配置。可用 `codex mcp list` 检查注册；已有会话可能需要刷新 MCP 工具、重新打开会话或重启客户端，才能载入新增工具。命令、配置字段和共享范围见 [OpenAI 官方 MCP 文档](https://learn.chatgpt.com/docs/extend/mcp?surface=cli)。

这份全局配置没有指定 `--db-path`，因此使用 `~/Library/Application Support/DeskLoom/xtdb`。**一个 XTDB 目录同时只能由一个桥接进程持有**：共享配置不代表桌面应用、CLI、REPL 和手动启动的 `dlm mcp` 可以并行打开同一数据库。让当前使用的 Codex 客户端启动并持有桥接进程；切换客户端前关闭原桥接进程。确需隔离记忆时可使用不同 `--db-path`，但原生桌面仍只有一个控制会话。

### Claude Code

```sh
claude mcp add --transport stdio deskloom -- /absolute/path/to/desk-loom/scripts/dlm mcp
```

可用 `claude mcp get deskloom` 查看连接。服务器名称使用 `deskloom`，避免 Claude 的保留名称。CLI 注册格式来自 [Claude Code MCP 文档](https://code.claude.com/docs/en/mcp)。

### Cursor

在项目 `.cursor/mcp.json` 或个人 `~/.cursor/mcp.json` 合并：

```json
{
  "mcpServers": {
    "deskloom": {
      "type": "stdio",
      "command": "/absolute/path/to/desk-loom/scripts/dlm",
      "args": ["mcp"]
    }
  }
}
```

配置位置和 stdio 字段来自 [Cursor MCP 文档](https://prod.cursor.com/docs/mcp)。

### Gemini CLI

在 `~/.gemini/settings.json` 的已有配置中合并：

```json
{
  "mcpServers": {
    "deskloom": {
      "command": "/absolute/path/to/desk-loom/scripts/dlm",
      "args": ["mcp"],
      "timeout": 120000
    }
  }
}
```

用 `/mcp` 查看连接和工具。首次加载本地 JVM/XTDB 可能较慢，超时设置不意味着动作会被自动重试。[Gemini CLI MCP 文档](https://geminicli.com/docs/tools/mcp-server/)

### VS Code

在 VS Code 原生格式 `.vscode/mcp.json` 中合并：

```json
{
  "servers": {
    "deskloom": {
      "type": "stdio",
      "command": "/absolute/path/to/desk-loom/scripts/dlm",
      "args": ["mcp"]
    }
  }
}
```

也可运行命令面板的 `MCP: Add Server`，选择 `Command (stdio)`。VS Code 可使用多种 Agent harness，配置目的地可能不同；此示例明确使用 VS Code 的 `servers` 格式。[VS Code 添加 MCP 服务](https://code.visualstudio.com/docs/agent-customization/mcp-servers)、[配置管理](https://code.visualstudio.com/docs/agents/run/manage-mcp-servers)

## 本地页面记忆与提速方式

XTDB 保存页面索引、不可变语义内容版本、访问记录及动作请求记录。页面身份由应用 Bundle ID 和可用 URL 组成；没有 URL 时使用窗口标题，因此它是语义页面索引，并非浏览器标签页的永久身份。相同标题的不同窗口可能归入同一页面，动态标题也可能形成不同页面。

内容哈希排除临时节点 ID、PID、时间戳和坐标；重复观察未变化的内容时复用版本，只追加访问记录并更新页面索引。保存的是 AX 可见语义内容，不是网页源代码或完整浏览器 DOM，也不会自动为每页保存截图。密码控件的 AX 值在原生观察时隐藏；截图仍反映窗口实际可见像素。

动作意图只保留输入文本长度，幂等记录使用请求摘要；动作回执引用页面版本，避免再次复制整棵页面树。重复请求返回历史回执及版本引用，需要新的观察才能继续操作。

页面正文、历史值和选择器都标记为不可信历史数据，不能当成 Agent 指令或执行凭据。召回内容不会恢复 AX 句柄，也不能直接使用旧 `node_id` 操作；必须重新观察当前窗口并唯一解析选择器。

当前提速机制及边界：

- **保持进程运行**：连续工具调用复用 JVM、已打开的 XTDB 和会话，避免每一步重新启动运行时。进程启动、首次加载控制层和首次打开 XTDB 的耗时，应与已运行进程中的真实动作耗时分开记录。
- **优先语义操作**：AX 定位和直接写值可减少截图、视觉定位和逐字输入；不支持的控件仍需视觉路径。
- **增量观察**：`computer_observe` 传 `delta: true` 和客户端实际持有的 `since_snapshot_id`。基线匹配时返回 `changed_nodes`、`removed_indices`、完整的当前 `node_ids` / `parent_ids` 映射及新快照标识；否则回退完整结果。客户端必须按索引更新内容、节点及父节点标识，不能把旧节点令牌继续用于动作。当前 delta 仍执行完整 AX 观察和同步页面存储，只缩减返回内容及后续模型上下文，不能据此声称原生动作更快。
- **批量顺序执行**：`computer_batch` 最多 20 步，适合目标和动作已经明确的短流程。每步使用新观察；选择器重新唯一匹配，失败立即停止，不整批重试。需要 Agent 判断新页面或确认业务效果时应拆开调用。
- **按需截图**：只有需要视觉信息时调用截图，并限制图片宽度，减少图像传输与模型输入；AX 观察及页面存储无需每次截图。
- **语义内容去重**：页面版本按内容复用，避免把完全相同的 AX 树反复保存成新版本；访问时间和次数仍保留。

历史页面召回提供结构和选择器线索。使用历史选择器执行动作时，仍会先观察当前窗口、重新唯一匹配，动作后再观察并存储；召回本身不会跳过这条校验链，因此不能预设记忆路径的本地执行耗时一定更短。

`elapsed_ms` 和 `computer_metrics` 来自本地单调时钟，包含工具执行、原生 RPC 与同步持久化，不包含 LLM 推理、工具计时开始前的延迟加载，以及结果 JSON 编码和 stdio 传输。端到端耗时应由调用方额外测量。比较速度时需在同一应用、同一任务和权限状态下，分别记录冷启动、暖进程调用、完整/增量观察、逐步/批量调用及截图开销，并同时比较响应字节数和成功率。每次真实重复操作都应使用新的 `request_id`；同一标识的历史回执重放不能算作更快地执行了动作，`dispatched` 也不能当作业务任务成功样本。

## Codex 与真实浏览器验收

完成上面的 Codex 注册后，运行 `python3 tests/browser_acceptance.py --live`。测试使用已安装的 Codex app-server 及其 MCP 客户端，通过临时 runtime 显式调用工具，不启动模型回合。它启动独立 Chrome profile 和本机回环地址测试页，所有表单操作均通过 DeskLoom 原生 AX 完成；不依赖 DevTools、DOM 注入或 Playwright。页面的真实保存事件、可见结果与 AX 读回共同验证成功。

默认执行 5 组交替次序的逐步/批量配对测量，记录完整 Codex 工具响应字节与调用方耗时；证据日志在计时结束后落盘。完整/增量比较等待页面回执稳定后进行。首次操作和记忆复用操作用于验证功能，不能用这两次不同路径的耗时证明记忆本身加速。测试会在默认 XTDB 留下测试页历史，关闭 MCP 后由独立 JVM 重开同一数据库，精确比较最后的页面、版本、内容摘要和访问计数。结果、原始协议记录与目标窗口截图保存在 `evidence/browser-<run-token>/`；浏览器和控制会话在结束时关闭。

截图专项回归：`python3 tests/screenshot_acceptance.py --live`。固定 3 次独立 Chrome 启动、每次 7 个截图样本，覆盖短标题及必须实际进入 `middle_ellipsis` 分支的长标题。每个预定样本只调用一次，失败也保留在分母中；校验 PNG、hash、尺寸、坐标和目标身份，并在 `evidence/screenshots-<id>/` 保存诊断与协议记录。
