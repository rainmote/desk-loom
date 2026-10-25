# 本地 ChatGPT 订阅与窗口操作

DeskLoom 通过已安装的 Codex CLI 使用 ChatGPT 订阅。官方文档说明 [Codex 支持 ChatGPT 订阅登录](https://learn.chatgpt.com/docs/auth)，且 [`codex exec` 默认复用保存的 CLI 登录态并支持结构化输出](https://learn.chatgpt.com/docs/non-interactive-mode)。DeskLoom 自身不解析或复制登录凭据，也不会修改用户的 Codex 全局配置。

## 前提与界面

- 安装支持 `exec --ignore-user-config --ignore-rules --output-schema` 的 Codex CLI。本次开发环境为 `codex-cli 0.157.1`。
- 启动 `/Applications/DeskLoom.app` 并授予无障碍权限。内置文本规划无需截图；使用已有截图工具仍需屏幕录制权限。
- 点击「登录 ChatGPT」或执行 `dlm llm login`。已有本地 Codex ChatGPT 登录可直接复用；浏览器网站的 Cookie 不会被导入。API Key 登录会被识别并提示改用 ChatGPT 登录，不自动改成 API 计费。
- 在 LLM 面板刷新并勾选 1–8 个窗口，填写任务，执行。刷新只移除已消失的选择，不自动勾选新窗口。启动内置 LLM 任务前需要停止已有 MCP/REPL 控制；同一任务会同时保持所有选定窗口的会话。
- 模型留空采用 Codex 内置默认值；可填写账号支持的模型名称。模型选择保存在本机，任务与界面结果仅保留在内存；原有 XTDB 页面及操作记录仍按原流程保存。

菜单栏仅显示图标和实际受控窗口数，勾选数与连接数分开计算。关闭或释放一个窗口时数量减少，任务停止后释放其拥有的所有窗口。预览与角标跟随当前操作目标；每个窗口的快照、回执及会话身份独立保存。

## CLI

```sh
dlm llm status
dlm llm login
dlm rpc computer_windows
```

从 `computer_windows` 返回值中选择目标窗口的 `pid` 和 `window_id`，然后运行：

```sh
printf '%s' '读取资料窗口，将三条摘要填写到笔记窗口，保留资料内容。' | \
  dlm llm run --window '12345:资料窗口ID' --window '23456:笔记窗口ID' --prompt-stdin --json
```

`--window PID:WINDOW_ID` 可重复指定，允许同一应用的多个窗口；重复或超出上限的选择会被拒绝。原有单窗口 `--pid 12345 --window-id ID` 调用仍兼容，不能与 `--window` 混用。

可选参数为 `--model`、`--max-steps`（默认 12，范围 1–40）、`--timeout`（默认 600 秒，范围 30–1800）、`--db-path` 和 `--endpoint`。`--prompt-stdin` 避免把任务内容放入进程参数；也提供 `--prompt` 供简单调用使用。按 Ctrl-C 取消。

JSONL 事件包含 `type` 和 `message`；类型为 `status`、`message`、`tool`、`completed` 或 `error`。连接事件及 `tool` 带有 `window_id`、`session_id`，操作事件带有动作名与结果。错误返回非零退出码；只有 `completed` 表示模型根据新观测判断任务完成，仍应以目标应用的实际状态为准。

## 执行方式与边界

Python 工作进程维持一个常驻 Clojure 工具进程，先连接所有选定窗口。每步将用户任务、所有窗口的当前无障碍观察和有限步骤历史传给 Codex，模型通过 `window_id` 指定操作目标；DeskLoom 校验允许列表，使用对应 `session_id` 调用 `computer_act`。Codex 在临时工作目录运行，不加载用户配置与项目规则，关闭 shell、插件、MCP 等额外执行入口。保留 `CODEX_HOME` 让 Codex 自行管理登录，移除子进程继承的 API Key 环境变量。

每次推理后重新观察所有窗口，核对来源内容和目标元素，再换用新的节点标识；不把超过 15 秒的旧快照直接用于操作。合成输入前显式聚焦对应窗口，各窗口可同时保持连接，键鼠输入仍按顺序执行。操作派发前发现来源或目标状态变化时停止；目标消失、会话变化、选择不唯一、无障碍树不完整、结果未知、超时或达到步数上限时也会停止，不重放不确定的动作。部分连接失败及取消都会释放本任务已取得的会话，不影响其他客户端后来建立的会话。

模型提出完成时，DeskLoom 再次核对全部窗口。若身份不变且前后观察均完整，但语义状态有变化，则使用最新观察重新判断，计入原步骤与时间上限；此时不执行动作，也不提前展示完成消息。只有状态稳定且模型确认后才发送 `completed`。

当前内置规划使用无障碍树，不向模型上传截图。复杂画布、缺少无障碍元素的控件、弹出另一个窗口的操作可能无法完成；外部 MCP Agent 仍可使用截图接口。模型服务需要网络和可用的订阅额度。每步为独立 Codex 推理，延迟包含模型响应与本地工具执行。单个数据库目录一次只能被一个控制进程持有，可为独立 CLI 任务指定 `--db-path`。

## 验证

```sh
python3 tests/test_llm.py
python3 tests/test_dlm.py
scripts/clj-test
```

单元测试使用隔离的假 Codex 与工具进程，不消耗订阅额度，也不修改真实窗口。真实登录、模型请求及窗口操作验证单独记录在项目 `VALIDATION.md`。
