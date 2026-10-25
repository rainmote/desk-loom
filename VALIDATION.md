---
created: 2026-10-23
---

# 原型验收状态

当前状态（2026-10-26）：**v0.11.0 build 19 已安装，通用多窗口控制没有应用名称或 Bundle ID 白名单；每个受控窗口右上角持续显示“控制中”，菜单栏仅显示图标及实际连接数。跨应用真实填写和独立菜单计数已取得证据，但修复后的完整跨应用 LLM 验收尚未复测，不能宣称整轮通过。** 原有截图和 XTDB 功能保留。实际控件能力取决于 macOS Accessibility 支持；macOS 之外的后端未实现。下方早期记录保留为历史，旧版本的专用流程现已移除。

文件整理说明：旧版 `tests/` 下的日志、截图及诊断输出已清理，历史记录中的这些路径不再保留。当前 `evidence/` 验收证据和运行依赖留在本地忽略目录，不纳入 Git；源码、可重复执行的测试及夹具均保留。

## 2026-10-26 合并提示刷新（build 19 已安装）

- build 18 的标记生命周期已经稳定，但每次观察和动作会发布多个模型字段，每个字段都排队刷新标记，导致 WindowServer 尚未完成排序时收到重复请求。上一轮两个标记的排序计数分别达到 297、309，原验收只检查隐藏和静止状态，未限制焦点切换时的重复排序。
- 菜单刷新按主线程批次合并，与标记刷新分开；预览切换不刷新标记。目标变化、窗口可见性通知和定时跟随仍保留，并合并同一批次的标记更新。实际窗口层级变化时才重新排序。
- 已通过标准安装器升级至 build 19。新旧 designated requirement 相同，Accessibility 和 Screen Recording 权限均保持 true；安装后严格签名校验通过。原生双窗口验收再次通过，覆盖 40 次选择/激活通知、移动、遮挡、隐藏恢复及移除。
- 新增可重复执行的 `python3 -B tests/overlay_acceptance.py --live`：通过安装版原生 RPC，对独立 WindowLab 的两个真实窗口交替 focus 20 次。两标记的窗口编号、frame、可见性变化数全程不变；每次焦点切换、每个标记最多 2 次排序，最终累计排序分别为 11、12（含首次显示），静止时连续 20 次采样完全不变。菜单实际计数 2 → 1 → 0，测试自有会话和窗口全部释放。
- 证据：`evidence/overlay-acceptance-d99c5310813f452dbd5d1f61e18e3562/result.json`。测试会记录动作前后及稳定采样的排序增量，超过上限即失败；动作不重发，异常也清理自有窗口。该项没有调用 LLM，且两个窗口属于同一个测试应用，不替代跨应用 LLM 验收。

## 2026-10-26 控制提示持续显示（build 18 已安装）

- 每个已接受的控制会话独立持有右上角“控制中”标记；切换预览和应用激活通知不再先隐藏标记。相同位置不重复设置窗口 frame，层级已经正确时不重复排序；坐标取整以避免 AppKit 舍入造成持续刷新。提示保留普通窗口层级、鼠标穿透和非焦点行为，遮挡由窗口系统处理。
- 首次几何关联同时要求同应用 AX 窗口身份唯一和全部 CG 窗口（包含其他 Space）几何唯一；重复连接被接受前不创建标记。绑定后持续跟随 CG 窗口，不因短暂缺失 AX frame 闪烁；目标隐藏、最小化或离开当前 Space 时隐藏，断开对应会话时移除。
- `NativeComputerUnitTests` 通过，包括多会话路由及拒绝重复连接的标记生命周期检查。`tests/native_overlay_acceptance.swift` 与原生应用源码（排除 `main.swift`）共同编译后通过：两个测试自有的真实 AppKit 窗口，40 次目标选择与激活通知期间，标记窗口身份、可见性变化数、frame 变化数、排序变化数均保持不变；移动、遮挡层级、隐藏恢复、鼠标穿透及菜单计数 2 → 1 → 0 验证通过。测试结束关闭所有自有窗口，不发送桌面输入。
- 初次构建安装被系统盘空间不足阻塞；随后在共享盘构建并签名候选，用户释放空间后已通过标准安装器更新至 **build 18**。安装前清除了旧应用包内一份未封存的 Python 字节码缓存，恢复原签名校验；新旧 designated requirement 一致，无障碍与屏幕录制权限均保持 true，安装后及真实窗口测试后严格签名检查均通过。
- 安装版真实验证通过：由独立 WindowLab 应用提供两个测试自有窗口，实际通过原生 RPC 交替 focus **20 次**，两个标记的窗口编号保持不变，可见性变化数始终为 1（仅首次显示），frame 变化数始终为 1；静止时另连续采样 20 次，完整标记状态不变。截图已目视确认两个窗口右上角均显示“控制中”。测试后释放全部自有会话、关闭测试窗口，菜单计数恢复为 0。证据：`evidence/overlay-installed-9ea7aee97fc34bf4b608be5f37955b11/result.json` 及同目录 `window-1.png`、`window-2.png`；本项没有调用 LLM，不替代跨应用整轮验收。

## 2026-10-26 两个真实应用的跨窗口验收

- 新增 `tests/cross_app_acceptance.py --live`，使用 Google Chrome（`com.google.Chrome`）和 Microsoft Edge（`com.microsoft.edgemac`）的两个独立临时配置与本地表单。核对不同 PID、Bundle ID、窗口 ID；随机源值通过 AX 写入，明确断言任务提示和参数中不含该值。模型复用本机 ChatGPT 订阅，要求从 Chrome 读取备注并填写 Edge、追加固定后缀，源内容和标题保持不变。`--dlm` 可指定安装包内 CLI。
- 真实模型已执行一次目标 `set_value`，回执为 `dispatched`，模型运行时实际控制数为 2：`evidence/cross-app-a5c3b54875114456adb54eb1ebf7436d/llm-events.json`。持久化窗口版本确认源备注未变，目标精确等于源值加 `｜跨应用协作完成`；模型完成检查因状态变化停止，该轮仍判失败。诊断对原数据库副本执行，只读核对原库 SHA 未变，详见同目录 `diagnostic-analysis.md`、`diagnostic-aligned-diff.json`。
- 差异为两窗口 `AXFullScreenButton` 下各消失一个临时空 `AXGroup`：Chrome 119 → 118 节点、Edge 127 → 126 节点。对齐删除节点后其余持久化语义完全相同；原始最终全量快照没有保留，不能排除未入库几何等字段同时变化，但该节点消失本身足以触发严格比较。
- 修复通用完成确认：全部所选窗口身份不变、前后观察均完整时，若语义变化，仅以新观察重新规划，计入原步骤和时间上限；稳定前不展示模型的完成消息。保留全部比较字段，动作派发前的源/目标检查、未知结果不重试均不变，没有应用专属例外。Python LLM **36 项测试通过**，包括 `dispatched` 后不重复操作、持续变化的步骤/时间上限、会话/窗口变化和不完整观察拒绝。独立代码复审通过。
- build 17 已完整构建、固定身份签名安装至 `/Applications/DeskLoom.app`，designated requirement 不变，无障碍与屏幕录制均保持 true；安装包 LLM 脚本 SHA 与源码一致。安装日志保存于 `evidence/cross-app-455173b2985d47b09e48e4d3bbc4fd1e/build-install.log`。
- **菜单计数独立验证通过：2 → 1 → 0**，图标显示、缩略图隐藏，UI 数值与原生实际会话数一致。该项仅连接和释放现有 Chrome、Edge 窗口，不读取页面内容、不发送输入、不运行模型。证据：`evidence/cross-app-menu-f3f94850a6e74a1d808ec1af7325e249/result.json`。最终受控窗口数为 0；所有本轮临时浏览器进程均已关闭。
- 修复后的整轮复测尚未通过。安装版 CLI 最新证据：`evidence/cross-app-455173b2985d47b09e48e4d3bbc4fd1e/result.json`，连接阶段 `operation-failed`，尚未调用模型；同时原生保存 `inspector.png` 明确报本地系统盘空间不足，独立诊断文件创建也返回 `ENOSPC`。另观察到 NFS 生成缓存及源码间歇 `EACCES`；不可读生成缓存已隔离，未改共享权限。早期 agent EOF 的 stderr 未保存，不能据此确认其具体根因。无窗口服务/数据库 readiness 曾成功，不替代实际跨应用验收。等待释放足够本地磁盘空间、共享目录稳定可读后再复测。
- 测试脚本已修正浏览器异步写值的验收：允许 `dispatched` 后仅有界读回精确值，保留原请求和回执，不重发动作。失败后也尝试保存独立读回和窗口截图；未保存/重置同时检查 AX 内同步结果 JSON 与服务端事件。NFS 临时浏览器配置启动超时的残留仅归档到忽略目录，详见 `evidence/cross-app-75278f43f47446ea9161b98013389dec/cleanup-diagnostic.json`。

## 2026-10-25 移除专用编辑器流程

- 删除 `DesktopEngine.swift`、旧演示与专属验收流程；权限引导、焦点诊断和 UI/菜单路由拆入通用 `DesktopServices.swift`。状态、控制会话、截图和停止统一由 `ComputerCoordinator` 管理。空闲界面改为「刷新应用窗口」，不再默认显示或自动启动某个编辑器。
- 旧 `start`、`observe`、`set_value`、`move_window`、`verify`、`report_verification_error`、`preview` RPC 全部返回 `unknown-method`。控制统一使用 `computer_*`；REPL 的 `attach!` 必须明确指定窗口，后续操作指定会话。旧持久化记录仅保留只读审计，新通用记录按各自的动作与回执审计。
- v0.11.0（build 16）已签名安装至 `/Applications/DeskLoom.app`，代码身份不变，两项系统权限安装前后保持 true。实际 MCP 握手返回 `deskloom / 0.11.0`，本机 ChatGPT 登录复用仍有效。
- 全体 Swift 源编译检查与两套原生单元程序通过；真实原生 RPC **6 项**（含全部 7 个旧方法拒绝、伪造会话拒绝）、Python CLI **9 项**通过。原样 `scripts/clj-test` 通过 **36 tests / 274 assertions**，独立 JVM 持久化写入/读回通过；计数变化来自删除旧专属验收测试并新增通用 REPL、审计测试。
- NFS 的两份不可读生成缓存已移至 `.runtime/cache-recovery/`，重新生成后，正常 CLI/MCP 和完整测试入口恢复；未修改共享权限或减少测试范围。
- 验收改用 `tests/fixtures/WindowLab.swift` 的独立 AppKit 应用，只有内存文本和两个自有窗口。首次模型测试因全屏按钮下的暂态 `AXGroup` 消失而在派发前停止；精确差异保存在 `evidence/windowlab-diff-472f3cf1304a453abeca165d97dfdde2/difference.json`。测试夹具隐藏不参与验收的全屏/缩放按钮后，两窗口连续 34 秒、各 6 次完整观察均为相同的 7 节点（`evidence/windowlab-stable-b919d14e9f8548d3a1728b37ec91c83b/`）；产品状态校验未放宽。
- 修复后的真实订阅协作通过：`evidence/multiwindow-384f4b20400b481daa1d4ee5fcfc9fbb/result.json`。模型读取随机源正文，将其写入另一个 WindowLab 窗口并追加指定后缀，独立 AX 读回确认源未变、目标精确匹配；LLM 阶段 31.50 秒。当时已有其他客户端的 1 个会话，菜单实际为 **3 → 2 → 1**，本测试所属会话为 **2 → 1 → 0**；其他会话保留，跨窗口使用快照的负向检查通过。

- 通用接口闭环通过：`evidence/computer-59a1bd6aab9041fa84bc6222dd914873/result.json`，覆盖 3 次原生验证写入、请求重放不派发、batch、delta、560 × 472 真实窗口截图、独立 JVM 恢复页面记忆。已视觉检查截图。另一个 JVM 审计返回 `format=computer-agent`、`outcome=verified`，结果保存在同目录 `audit.json`。两个验收均释放自身会话并关闭测试应用，原有其他客户端会话保留。

## 2026-10-25 多窗口 LLM 协作

- v0.10.0（build 15）已构建、签名并安装至 `/Applications/DeskLoom.app`。固定签名要求保持不变，无障碍与屏幕录制授权安装前后均为 true；安装包中的 LLM 脚本与当前源码一致。MCP 握手返回 `deskloom / 0.10.0`。
- 界面可勾选 1–8 个窗口；CLI 支持重复 `--window PID:WINDOW_ID`。每个窗口独立维护会话、快照及动作回执；多会话工具调用需要显式 `session_id`。同一任务同时保持所有连接，键鼠操作按顺序执行。规划后重新观察所有来源及目标窗口，最后刷新即将操作的目标，避免多窗口遍历消耗其快照有效期。
- 运行 `python3 tests/multiwindow_acceptance.py --live --with-llm`，只操作两份新建 TextEdit 测试文档。源文档预写随机校验码，任务提示只提供窗口标题、不提供校验码；真实订阅模型将观察到的源正文写入目标，并追加 `｜协作完成`。工具返回 `verified`，下一步模型观察确认完成；独立重新连接 AX 精确核对源正文未变、目标正文完全符合预期。LLM 阶段耗时 **25.70 秒**，仅代表此次样本。
- 实测两个会话同时存在，跨窗口复用源快照向目标写入被拒绝。定向释放源窗口后目标仍可观察；菜单栏计数实际为 **2 → 1 → 0**。模型运行时另行核对计数为 2，结束后为 0。真实图标与数字渲染为 `status-two-windows.png`；布局检查的合成 AppModel 渲染单独放在 `layout-fixture/`。
- 验收证据：`evidence/multiwindow-57de83db53714d6ba82f372fd9ab59e5/result.json`、`llm-events.json`、`ui-two-windows.json`、`final-state.json`。所有测试会话已释放，最终实际连接数为 0。
- 回归通过：Python LLM **33 项**、CLI **9 项**、MCP **5 项**、真实原生 RPC **9 项**；Clojure **45 tests / 359 assertions**，独立 JVM 持久化写入/恢复通过。Swift 全应用构建与原生断言程序通过，覆盖关闭窗口减数、8 窗口全部停止、会话隔离、异步截图与切换、旧会话清理不影响其他控制。
- NFS 一度拒绝读取源码，恢复后构建和实际 CLI/MCP 启动正常。完整 Clojure 测试使用等价的空 alias 绕过一个仍不可读的旧生成缓存，测试代码和配置未缩减。取消清理等待覆盖全部会话与未确认的连接；相关慢窗口、未知 attach 和重复取消回归通过。

## 2026-10-25 LLM 接入与菜单栏

- 使用本机 `codex-cli 0.157.1`。`dlm llm status` 与原生 `llm_status` 均确认 `available=true`、`authenticated=true`，认证类型为 ChatGPT；未读取、复制登录令牌，也未更改 Codex 全局配置。真实 `codex exec` 结构化连接检查成功。
- 新建专用 TextEdit fixture `DeskLoom 3A658309`，通过 `dlm llm run --prompt-stdin --json` 请求写入单行中文测试文本。模型第一步选择 `set_value`，工具返回 `verified`；第二步根据读回判断完成。退出后另行连接原生 AX 精确核对，实际文本与预期一致，任务结束时已自动 detach。耗时 **33.01 秒**，包含两次模型推理与本地工具启动，仅代表该测试。证据：`evidence/llm-18fefe6658534611ad51ed09a5232620/result.json` 与同目录 `events.json`。
- 活动会话菜单栏实测 `statusTitle="1"`、`controlledWindowCount=1`，结束后为 `"0"` / `0`；图标一直显示、缩略图不显示。菜单栏与工作台已生成并视觉检查截图，窗口及紧凑浮窗也已检查长标题、任务输入及结果区域的布局。
- 新增 LLM 后端 **21 项测试**，覆盖登录类型区分、API Key 环境隔离、不复制凭据、标准输入传递任务、结构化协议、模型工具禁用、过期快照刷新、会话与窗口变化、唯一节点映射、坐标边界、安全字段、显式聚焦、未知结果不重试、步骤/时间上限、阻塞管道、取消子进程及重复取消信号清理。
- 原有 Python CLI 8 项、MCP 5 项、安装器 14 项、更新器 4 项、存储迁移 4 项通过；真实原生 RPC 9 项通过。Clojure **34 tests / 288 assertions** 通过，独立 JVM 持久化写入/恢复通过；Swift 全项目编译检查及 ComputerEngine 单元测试通过。
- 取消在原生端幂等处理；工作进程忽略重复取消信号直至清理结束。原生释放窗口时同步核对本任务记录的会话，Clojure detach/退出通过 `session_id` 原子校验，避免在并发会话更换后释放其他客户端的窗口。
- 构建安装到 `/Applications/DeskLoom.app`，版本 0.9.0（build 14）；签名 designated requirement 不变，无障碍与屏幕录制授权安装前后均保持 true。网页登录新账号流程未实际注销重登；复用已有本地 ChatGPT 登录已实测。

## 2026-10-25 截图匹配拒绝修复

- 生产进程内诊断复现了标题表示差异：AX 返回完整页面标题及 ` - Google Chrome`，SC 有时返回单个中间省略号 `…`（U+2026）。修复前固定计划为 3 次独立 Chrome 启动、每次 7 张，共 21 张：7 成功、14 次 `ambiguous-capture`。14 次失败都只有一个同 PID 几何候选，四项边界差值均为 0；AX 前后标题/边界不变且读取错误均为 0，标题匹配数却为 0。诊断标题自身没有被日志截断。证据：`evidence/screenshots-268293ad430d4b0c94df03d6f5431eab/result.json`。
- 代表性原始值：AX 为 `DeskLoom Browser Lab · 21cad08262a0410e9a499e3194cd02ae - Google Chrome`，SC 为 `DeskLoom Browser Lab · 21ca…8262a0410e9a499e3194cd02ae`。这组复现定位到中间省略形式无法匹配，不支持用失焦或坐标变化解释这些拒绝。
- 新增严格的中间省略匹配：仅一个内部 U+2026，两端精确对应，完整标题更长且不含字面 U+2026；同进程全部 SC 几何候选及完整可读的 AX 几何候选都必须唯一，AX 候选须为当前已连接对象。完整标题与省略标题同时匹配时仍拒绝，已绑定的 CGWindowID 不允许换绑；查询前后及截图后再次验证 AX 状态。没有截图重试、任意前缀匹配或选择首个候选。成功结果增加 `capture_match`；失败诊断经原生 RPC、MCP 和 JSON Lines 保留。
- 该关联使用应用与系统公开的元数据，并非系统提供的 AX ↔ CG 身份映射。存在歧义、枚举不完整、窗口状态变化时仍会拒绝。
- 已构建安装至 `/Applications/DeskLoom.app`（2026-10-25 11:37 +08）。固定签名要求保持不变，无障碍及屏幕录制权限安装前后均为 true。原生单测及全部 Swift typecheck 通过，包含生产标题、Unicode 边界、同位置多窗口、AX 读取失败、完整/省略候选混合、已绑定窗口编号变化等负向情况；独立代码审查发现的混合候选误选风险已修正。错误诊断透传的实际 MCP/JSONL 进程测试通过；本轮 Clojure 32 tests / 275 assertions、Python MCP 5 项、原生 RPC 9 项均通过。
- 修复后运行 `python3 tests/screenshot_acceptance.py --live`：预先固定 3 次独立 Chrome 启动 × 7 张，覆盖启动后、真实保存后、720/1100 两种截图宽度及连续截图。**21/21 通过，失败 0、未执行 0、截图重试 0**；7 张为 `application_suffix`、14 张实际走 `middle_ellipsis`。每张均校验 PNG、SHA256、尺寸、会话/窗口/进程、URL、坐标比例及绑定 CGWindowID，省略路径的 SC/AX 候选数均为 1。已视觉检查长标题保存后截图。证据：`evidence/screenshots-3de3875961074da6914a4ee41b79f952/result.json`；此固定样本结果不代表所有应用、窗口变化或多屏场景。

- 回归中另保留了两个页面状态时序失败：`browser-abb4054578ff48c89702714a6196db4a` 在异步回执 DOM 替换时读到不完整 AX 树；`browser-f1894e44903d458fab41cf4415eca89b` 的重置返回仍为 `Sending · 3`，约 77 微秒后立即发起下一批次，首步因 `incomplete-snapshot` 停止、完成数为 0，没有重发。后者内部预观察未附在错误回执中，不能断言具体失效节点。验收脚本现仅通过有界只读观察等待完整的当前事件回执；重置前等待上一保存回执、重置后等待当前 `Reset` 与 `Recorded`，再校验字段。重置及其就绪等待单独记录在计时外；被测动作仍要求完整观察，原始不完整样本和失败运行都保留。

### 修复后的完整浏览器、XTDB 与加速回归

- 最终运行：`python3 tests/browser_acceptance.py --live`，证据 `evidence/browser-db9e81336ced442286682b50cb71de65/result.json`，`outcome: passed`。实际 Codex app-server 读取已注册的 DeskLoom MCP，服务为 `connected`、11 个工具、无工具错误。全过程经 MCP 与原生 AX 操作独立 Chrome profile 的回环测试页；无 DevTools 或 DOM 注入。首次新鲜节点保存、召回页面选择器后的第二次保存，以及 5 组配对测量共完成 **12 次真实保存、12 次重置**，可信浏览器事件序号连续 1–24，没有重复动作。
- 页面 ID：`page-e13e341d9ac7ce919e9c4c6d8bdddcbcfe3b2c26cc3d524021a4c17a0c832180`。关闭 MCP 后，独立 JVM 重开默认 `~/Library/Application Support/DeskLoom/xtdb`，恢复该页 **74 个内容版本、150 次访问**。`page_id/version_id/content_hash/visit_count`、标题/备注、页面 URL 和最后事件 24 精确一致，搜索可找到，历史内容无可执行节点句柄；详见同目录 `xtdb-reopened.json`。这是持久版本/访问计数，不是浏览器保存动作次数。
- 最终目标窗口截图 `browser.png` 为 1100 × 900，SHA256 为 `96d8509c276924b2a506238e6a92d1e7ef8c432f9df4750f1687211d4794437d`；已验证 PNG、目标身份和实际画面。该次同样走 `middle_ellipsis`，SC/AX 几何候选均为 1、已选 AX 对象确认成功，CGWindowID 为 25427。

| 本轮 5 组暖进程配对测量 | 逐步 / 完整 | 批量 / 增量 | 结果 |
| --- | ---: | ---: | --- |
| 相同三步表单流程中位耗时 | 505.20 ms | 426.02 ms | 减少 15.7% |
| 每次流程外层工具调用 | 3 | 1 | 原生动作均为 3 次 |
| 每次流程响应字节中位数 | 286,783 | 96,973 | 减少 66.2% |
| 稳定页观察响应字节中位数 | 94,863 | 6,678 | 减少 93.0% |
| 稳定页观察往返中位耗时 | 83.36 ms | 50.79 ms | 含本地传输、序列化与解析 |

- 各组使用同页面、相同输入和语义选择器，交替执行次序；全部 5 组计入统计。重置及前后回执就绪等待在计时外并单独记录，业务保存事件及可见保存结果验证在计时内，并核对返回字段值。完整树为 119 节点，5 组 delta 均无变更节点、内容版本复用，访问继续增长。响应字节包含 MCP text/structuredContent 重复编码；协议日志计时后写盘。
- 冷阶段单列：Codex runtime 1.27 秒，首个能力调用 1.17 秒，首次 attach 与打开 XTDB 4.54 秒。首次新鲜节点保存为 401.10 ms，第二次记忆选择器批次为 487.35 ms；两次输入/路径不同，搜索召回在计时外，**不能据此声称记忆本身让第二次更快**。可比较的加速证据来自上述配对实验。delta 仍执行完整原生观察和持久化；以上均不含 LLM 推理时间，不代表任意网站效果。

- 独立证据复核将最终 wire 中 119 节点按持久化规则归一化，与重开 XTDB 的快照全对象比较一致，并重新计算得到相同内容哈希；102 个工具记录与 wire 对应、无工具错误，动作请求标识无复用。测试结束后无活动控制会话、无遗留测试 Chrome 主进程，两项权限仍有效。

## 2026-10-25 Codex MCP 与真实 Chrome 验收

- 全局配置 `~/.codex/config.toml` 已注册 `deskloom`，命令为 `~/.local/bin/dlm mcp`，启动超时 30 秒、工具超时 120 秒。实际安装的 Codex CLI `0.157.1` 经 app-server 临时 runtime 读取此配置，报告 `connected`、服务版本 `0.8.0`、11 个工具、`toolsError: null`；操作全部经过 `mcpServer/tool/call`。没有启动模型回合或保存新的用户聊天。
- 可重复脚本：`python3 tests/browser_acceptance.py --live`。使用独立 Chrome profile 和回环 HTTP 测试页，通过原生 AX 填写中文标题/备注并激活保存按钮。业务成功同时检查浏览器发出的可信事件、可见结果、字段读回；没有 DevTools、DOM 注入或 Playwright。首次新鲜节点操作、从 XTDB 召回选择器后的第二次操作及 5 组配对流程，共 12 次真实保存、12 次重置，事件序号连续，动作没有重发。
- 最终证据：`evidence/browser-1b0fbcfe15aa45b38f7cdb652da41349/result.json`，`outcome: passed`。`browser.png` 是经 Codex/DeskLoom 返回的真实目标窗口截图，1100 × 1202，SHA256 校验和视觉检查通过。该次运行仅在最终清理阶段暂留测试窗口供只读 SC/CG 对照，暂留不进入任何计时；随后已关闭。
- 页面 ID：`page-f0b41d2646265ef2259b4e6f76760044efb47aa9a3a59494963aa4d4784c6351`。默认库 `~/Library/Application Support/DeskLoom/xtdb` 保存该页 52 个内容版本、108 次访问。关闭 MCP 后，独立 JVM 重开同一路径，精确恢复最后的 `page_id/version_id/content_hash/visit_count`、标题、备注及最后保存事件 24；搜索可找到该页，历史快照无可执行节点句柄。详见同目录 `xtdb-reopened.json`。

| 5 组暖进程配对测量 | 逐步 / 完整 | 批量 / 增量 | 结果 |
| --- | ---: | ---: | --- |
| 相同三步表单流程中位耗时 | 422.39 ms | 395.31 ms | 本地端到端减少 6.4% |
| 每次流程外层工具调用 | 3 | 1 | 原生动作均为 3 次 |
| 每次流程响应字节中位数 | 288,107 | 97,415 | 减少 66.2% |
| 稳定页观察响应字节中位数 | 95,307 | 6,692 | 减少 93.0% |
| 稳定页观察往返中位耗时 | 66.11 ms | 43.65 ms | 包含序列化、Codex 传输与解析 |

- 两种表单流程使用同一页面、相同值、同一组语义选择器，交替执行顺序，每次使用新 `request_id`。重置在计时外，业务保存事件及可见结果检查在计时内；外层响应字节包含 MCP text/structuredContent 的实际重复编码。证据协议日志和 stderr 缓存在内存，计时结束后落盘，避免 NFS 写盘污染。完整树 119 个节点，5 组 delta 均无改变节点、复用相同内容版本，访问计数继续增长。
- 冷阶段单列：Codex 临时 runtime 启动 1.11 秒，首个能力调用 1.18 秒，首次 attach 加打开 XTDB 3.76 秒。首次实际保存 325.74 ms，记忆选择器加批次的第二次保存 426.55 ms；两次路径、输入不同，且搜索/召回在计时外，**不能据此声称页面记忆让第二次更快**。上表仅证明相同选择器流程的批次收益；delta 仍完整观察并同步持久化，不能把响应缩小等同原生 AX 加速。全部测量不包含 LLM 推理时间，也不代表任意网站性能。
- 浏览器验收发现并修复了 Chrome AX 标题比 SC/CG 标题多出精确应用名后缀的截图适配问题；仍检查同 PID、紧几何匹配和唯一候选。另补回通用状态中的 `controller_application_path`，避免通用会话结束后更新器无法核实应用身份。原生单元测试（含 8 项标题匹配断言）、全应用构建/稳定签名安装、9 项原生契约检查通过，两项系统权限仍为 true。
- 失败证据也保留：`browser-de4d0dc90cfd4a29972a999639f3484b` 暴露了测试未等异步回执稳定；`browser-1771988130f14a64b67c10858eff2c2c` 暴露原始标题匹配问题；修复后的 `browser-26f36b5d86c541b39e356d1b616989fd` 仍有一次 `ambiguous-capture` 拒绝，未取得当时生产进程内的候选元数据，当时原因尚未确认；本节是早期验收记录，上方新增诊断已复现并修复中间省略标题导致的同类拒绝。后续独立截图及该轮完整运行均成功；不能据此保证截图在所有窗口变化时稳定成功，也没有为通过验收而放宽唯一目标要求。

## 2026-10-24 通用 Computer Use 与页面记忆

- Python 自动测试：34 项通过，包含实际 MCP 子进程握手、通知静默、版本协商、错误恢复、stdout 纯协议、JSON Lines、CLI 参数转发及原安装/更新测试。
- Clojure 自动测试：32 tests / 275 assertions，0 failures / 0 errors。包括真实 XTDB 页面去重、搜索、关闭重开、密码值脱敏，持久请求幂等、未知结果不重放、增量节点映射、批次停止和参数校验。另已运行原有两个独立 JVM 持久化脚本。
- Swift 全应用编译、固定身份签名及原生单元测试通过；单元测试覆盖 Unicode 分块、文本预算、伪造快照、无会话隔离，不向桌面发送输入。
- 已安装 `/Applications/DeskLoom.app` 0.8.0。安装前后无障碍、屏幕录制均为 true，designated requirement 保持不变。
- 可重复真实验收：`python3 tests/computer_acceptance.py --live`，仅修改本次新建的 DeskLoom 文本 fixture，通过通用 JSON Lines 服务列窗口、绑定、中文写入与精确读回、相同 request_id 回执复用、两步批次、增量观察、真实窗口截图、页面召回，并在第二个独立 JVM 中再次搜索和召回。
- 通用操作实机证据：`evidence/computer-9fae55e6f84d4e1e8daec7865d4abbae/result.json`，session `7AB5F564-7B5C-4B10-B4EA-08AAA77E3207`，三次文本动作均 `verified`；`window.png` 与返回 SHA256 一致；`independent_jvm_recovered=true`。
- 该测试页面完整响应 10,189 字节、未变化增量响应 1,773 字节，减少 82.6%。暖进程连续五次增量观察中位数 27.75 ms（包含本地 RPC 与同步 XTDB 持久化）；两步文本批次约 248.94 ms，窗口截图约 88.73 ms。它们是指定 TextEdit 样本的局部测量，不表示所有应用或包含 LLM 推理的整体速度。
- 页面内容保存在去重版本中；请求日志仅保存摘要、紧凑回执和版本引用。历史内容明确标为不可直接执行，操作仍重新解析当前窗口。

补充状态回归：通用会话 detach 后，状态接口与菜单栏应用名称一致，session/snapshot 标识为空，角标和预览已停止；旧 fixture 状态不再混入。证据：`evidence/computer-7d79ad56a3a4414fbb6950a10a11368d/result.json`，`detached_status_matches_ui=true`。随后 9 项只读/负向原生 RPC 契约检查全部通过。

当前限制：单个原生控制会话、每个 XTDB 路径一个桥接进程；标准 MCP stdio 兼容版本为 2024-11-05 至 2025-11-25，不宣称实现更新的 stateless 协议；没有多客户端共享守护进程、AXObserver 事件流或系统锁屏控制。

## 已验证

- Swift 原生应用完整编译通过，应用实际启动、显示工作台和菜单栏。
- 9 项原生 RPC 检查通过：鉴权、状态、未知方法、缺少动作身份、伪造快照、伪造验证、移动窗口快照检查、中断报告绑定、空闲 UI 状态。见 `tests/native-contract-results.txt`。
- Clojure 13 tests / 96 assertions 通过，覆盖唯一目标筛选、结果未知时不重复派发、验证中断落库、最新动作审计、真实 XTDB 持久化，以及验收脚本拒绝旧帧和错误 UI。桌面 RPC 的单元测试使用替身，不等同真实操作。
- 两个独立 JVM 在含空格路径写入并恢复中文记录。见 `tests/clojure-results.txt`。这证明数据库落盘，不证明桌面操作完成。
- 默认 `Application Support/ComputerUsePrototype/xtdb` 含空格目录真实打开/关闭成功。见 `tests/clojure-default-path.txt`。
- 在持久 `clojure.main` REPL 中打开实际 XTDB、调用原生 status；启动桌面会话被 `accessibility-required` 正确拒绝。见 `tests/repl-integration.edn`。
- 更新后再次在实际持久 REPL 运行 `desktop.acceptance/run!`：两项权限均为 false，在启动会话前以 `permissions-required` 失败，证据见 `tests/live-acceptance-permission-gate.json`。随后正常关闭真实 XTDB 和 REPL。
- 已视觉检查本应用自身工作台和菜单弹层渲染，没有用模拟截图冒充目标应用预览。

## 2026-10-24 权限引导更新

- 顶部显示辅助功能和屏幕录制的实际权限状态；启动、返回前台和后台轮询都会检查。
- 每项“打开设置”直接打开对应系统权限页，并在 Finder 中选中当前 `.app`；界面提供真实应用文件的拖拽来源和“重新检查”。
- 已重新编译运行，9 项原生 RPC 检查通过，已检查未授权引导的实际视图渲染。
- 两个设置入口的目标 URL 均被 `NSWorkspace` 接受，证据见 `tests/permission-settings-results.json`。这证明设置打开请求已发出，不等于拖入和系统授权已完成；当前两项权限仍为 false。

## 2026-10-24 授权签名失配修复

- 已确认用户选择的“设备控制和数据访问”就是 macOS 27 的无障碍权限。界面名称已按系统版本适配，底层继续使用 `AXIsProcessTrusted()` 检查真实授权。
- `tccd` 日志明确报告本应用的 Accessibility 代码要求失配：系统匹配旧 CDHash `84ba6f0160d99501fdf2cc653eefe3f7168a2f98`，当时运行版本为 `7cf4cab5a71620d1f856c4e1465a7cae5f7454ef`。证据见 `tests/permission-signature-mismatch.txt`。
- 构建已改用本机已有的 Apple Development 身份并固定选择，找不到有效身份直接失败。新 designated requirement 绑定应用标识和 Apple 证书身份，不再依赖 CDHash；静态严格签名验证和运行进程 `SecCodeCheckValidity` 均通过。
- 拖拽从 SwiftUI item provider 改为 AppKit 原生文件 URL，避免将 `.app` 经临时拖拽副本目录传给系统设置。已编译并检查权限引导的真实视图渲染；实际拖入和授权结果仍需用户完成。
- 新版 0.2.0 实际启动，9 项原生 RPC 检查再次通过。设置入口已成功请求打开“设备控制和数据访问”，Finder 已请求选中当前运行的应用。
- 签名迁移后，无障碍和屏幕录制检查均为 false；需要分别移除旧应用条目、重新添加当前应用并开启。未修改 TCC 数据库或代替用户授予权限。验证摘要见 `tests/permission-repair-results.json`。

## 2026-10-24 固定安装与持续更新

- 0.3.0 已安装到 `/Applications/Computer Use Prototype.app`，实际 RPC 与运行进程均确认来自此路径。`run-native.sh` 只打开安装版，重复启动复用同一进程。
- `build-native.sh` 在临时目录编译签名，成功后原位更新安装版并重新启动；不再覆盖运行中的项目构建副本。首次迁移的旧应用保存为 `.build/legacy-before-install.zip`，可启动的旧副本已移除。
- 连续两次真实构建安装成功，第二版满足上一版的 designated requirement，且要求文本一致。另将临时验证副本的版本修改后重新签名，确认 CDHash 改变但仍满足原代码要求；改成 ad-hoc 签名后，原要求拒绝该副本。验证副本未安装，未改变系统授权。
- 安装版 9 项 RPC 检查通过，实际路径、单一运行实例和启动脚本复用行为通过。签名与安装证据见 `tests/installation-identity-results.json`。
- 最终安装器再次真实更新并启动成功。5 项隔离恢复测试通过，覆盖启动失败、RPC 未就绪时恢复旧包、回滚失败保留备份、签名不匹配时保持旧进程，以及首次迁移失败保留原应用；测试不访问真实安装目录或系统权限。见 `tests/test_install_native.py`。
- 当前两项权限仍为 false，因此尚未实测“已授权 → 重编译 → 授权仍为 true”。后续只对“应用程序”中的安装版首次授权，再用同一构建脚本验证权限跨更新保持；不能把签名测试当成授权已生效。

## 2026-10-24 图标、菜单栏与应用内更新

- 0.4.0 打包 C / D 图标与完整尺寸 ICNS，默认 C。已验证 C → D 即时切换、退出后重新启动保留 D，切换运行时图标后严格代码签名仍通过。
- 右键菜单内容精确为“显示窗口、更新、退出”；通过同一菜单处理函数验证“显示窗口”关闭浮窗并打开工作台，以及“退出”实际结束原型进程。
- 原生浮窗开关验证通过；测得按钮锚点底边 y=1414，浮窗顶边 y=1414，浮窗覆盖按钮中点。该验证使用本应用自己的原生视图与诊断，不依赖外部桌面控制权限，也不冒充硬件鼠标点击。
- 已检查实际主窗口、图标设置和浮窗渲染；证据见 `tests/icon-menu-results.json`。首次测试固定等待 0.2 秒早于关闭动画完成，改为有界等待实际关闭状态后通过。
- 已通过“更新”处理函数完成真实后台构建、旧进程退出、安装和新进程启动；D 被写入安装版 CFBundleIconFile，签名要求保持相同。证据见 `tests/native-update-D.json`。
- 再次通过应用内更新将安装版恢复为默认 C，最终运行时选择和安装包图标均为 C；更新成功且严格签名验证通过。证据见 `tests/native-update-C.json`，最终主窗口、浮窗与菜单栏按钮的实际视图渲染见 `tests/ui-evidence-0.4.0/`。
- 9 项原生 RPC 检查、5 项安装恢复隔离测试与 4 项后台更新隔离测试通过。后台测试覆盖独立 session 存活、并发锁、成功/失败报告、缺失源码与文件权限。
- 在签名副本上调用 `NSWorkspace.setIcon` 后，严格校验报告 resource fork / Finder information 不允许。因此实际方案只改运行时图标及本地偏好，在下次正常签名更新时同步 Finder 图标；没有在实际安装包上添加自定义图标扩展属性。

## 2026-10-24 DeskLoom 更名、透明图标与独立设置

- 0.5.0 已实际安装至 `/Applications/DeskLoom.app`，可执行文件、窗口、CLI 与当前数据目录统一为 DeskLoom / `dlm`。旧安装包已通过事务式迁移替换；内部 Bundle ID 和 designated requirement 保持不变。
- 迁移前记录了原有图标偏好和 XTDB 文件，迁移至 `~/Library/Application Support/DeskLoom/` 后 4 个文件的大小及 SHA-256 完全一致；旧目录成为兼容符号链接，没有复制或清空数据库。
- C / D 外层白色底板已移除，两份 PNG 均带真实 alpha；菜单栏、窗口、设置卡片和权限拖拽预览使用透明图标。最终默认选择和安装包图标均为 C，ICNS 以 `DeskLoomIconC/D` 打包。图像由内置 image_gen 编辑，提示词见 `assets/icons/prompts.json`。
- 通过真实原生浮窗获得焦点后激活 Finder，确认浮窗自动关闭，关闭原因记录为 `popover_resigned_key`；再次单击的关闭操作通过。此项使用真实应用焦点切换，未模拟硬件鼠标点击。
- 设置改为独立的“DeskLoom 设置”窗口，打开时收起浮窗；验证窗口编号与工作台不同，最终内容尺寸为 540 × 370，关闭后设置状态同步。已检查最终设置与浮窗的实际视图渲染。
- 安装后的 `dlm --help/status/settings/icon/repl/update` 均实际调用成功。Clojure REPL 读到新的数据目录及 `/Applications/DeskLoom.app`；`dlm update` 完成后台构建、安装与重启，最终严格签名验证通过。CLI 未向签名包写入 `__pycache__`。
- 10 项安装/回滚、4 项后台更新、4 项真实 Swift 数据迁移、7 项 CLI 隔离测试通过；9 项原生 RPC 检查通过；Clojure 13 项测试 / 96 个断言及独立 JVM 持久化恢复通过。
- 证据集中于 `tests/deskloom-0.5.0/`：`results.json`、`repl.txt`、`clojure-tests.txt`、`settings.png` 和 `popover.png`。图像是本应用视图渲染，不是整屏截图。当前系统权限仍未开启，不能将以上验收当作真实 AX 写入或授权跨更新保持的验证。

## 2026-10-24 设置改为当前窗口内页面

- 0.5.1 已通过 `dlm update` 构建、安装并重启。移除了独立设置窗口，工作台和菜单栏浮窗分别在自己的原窗口内切换设置页，左上角“返回”恢复控制页。
- 实际验证进入设置与返回前后的原生 window number、窗口位置和尺寸完全一致；浮窗保持显示和焦点，不关闭后重新打开，也不创建新的设置窗口。
- 两处导航状态独立：工作台保持设置页时，浮窗可以单独进入设置、返回控制页；激活 Finder 后浮窗自动关闭并重置自己的页面，工作台页面保持不变。
- 已检查两种尺寸下的真实视图渲染、图标选择保持及严格签名校验。证据见 `tests/deskloom-0.5.1/results.json`、`main-settings.png` 和 `popover-settings.png`；使用与齿轮/返回按钮相同的操作函数验证导航，没有模拟硬件点击。

## 2026-10-24 固定顶部栏与设置按钮开关

- 0.5.2 已通过应用内更新安装。顶部图标、DeskLoom 名称和齿轮成为共用固定栏，只有下方内容切换；打开设置时齿轮呈紫色高亮，再次点击恢复控制页并取消高亮，移除返回栏。
- 主窗口和菜单栏浮窗分别实测连续两次切换，窗口编号及位置、大小保持不变；高亮状态各自独立。设置状态下激活 Finder，浮窗仍自动关闭。
- 已检查控制页与设置页的实际视图渲染，严格签名校验通过。证据见 `tests/deskloom-0.5.2/` 的 `results.json` 和前后 PNG；导航通过与设置按钮相同的 `toggle_settings` 操作验证。

## 2026-10-24 系统设置旁的权限拖拽引导

- 0.6.0 已实际安装至 `/Applications/DeskLoom.app`，保留既有 Bundle ID 和签名要求。点击权限入口不再自动弹出 Finder，改为 252 × 284 的非激活引导小窗。
- 在 DeskLoom 的无障碍与录屏检测均为 false 时，实测读到系统设置窗口边界并吸附右侧；将系统设置移到屏幕右缘后，引导自动转到左侧。测试结束恢复了系统设置原位置。跟随使用 `CGWindowListCopyWindowInfo` 元数据，不读取其他应用的 AX 树或画面。
- 通过 Codex 已有的桌面权限发送实际鼠标拖动，读取拖拽剪贴板确认 `public.file-url` 为 `file:///Applications/DeskLoom.app/`；随后取消拖动，没有往权限列表投放或改变系统授权。拖动前后系统设置保持前台，跟随状态正确恢复。
- 实测切到 Codex 时小窗隐藏，回到系统设置时恢复；两项入口打开对应权限页面；关闭按钮首击即可关闭。录屏引导名称与当前 macOS 27 的“录屏与系统录音”一致。
- 9 项交互检查通过，证据见 `tests/deskloom-0.6.0/results.json`；`permission-guide.png` 是应用自身视图渲染，`permission-guide-desktop.png` / `permission-guide-attached.png` 是 Codex 权限下取得的真实桌面局部截图。不能将这些截图当作 DeskLoom 已取得录屏权限的证据。
- 代码实现了检测到权限生效后自动关闭引导，但本次没有授予系统权限，因此该分支未进行真实授权验收。多屏转换与无窗口元数据的回退经过源码审查，本机只实测单屏。原有 TextEdit / REPL 桌面验收仍待权限实际生效。

## 2026-10-24 授权已开启但检测失败的当前诊断

- 当前运行进程 PID 66066 来自 `/Applications/DeskLoom.app/Contents/MacOS/DeskLoom`。磁盘严格签名校验及运行进程 `SecCodeCheckValidity` 都成功；当前 designated requirement 校验成功，排除运行了旧路径或当前安装包签名损坏。
- 13:34:55.646 的系统 tccd 日志确实记录用户将本应用 ScreenCapture 更新为 `Allowed (System Set)`，CodeReq 已是当前稳定 Apple Development 证书规则。因此不能把问题归结为用户未开启开关。
- 约 80ms 后，同一 tccd 仍使用旧的 `cdhash 7cf4cab5a71620d1f856c4e1465a7cae5f7454ef` 校验并失败。13:35:00 重启后的 PID 66066 查询两项权限，Accessibility 仍匹配旧 `cdhash 84ba6f0160d99501fdf2cc653eefe3f7168a2f98`，ScreenCapture 仍匹配上述旧哈希；均记录 `Failed to match existing code requirement` 和状态 `-67050`。
- 当前进程 CDHash 为 `a12b0af7635029dcaa29f5d139dd159feaf6a232`。独立使用 Security.framework 直接验证运行进程：符合当前证书规则，不符合两个历史哈希，结果与 tccd 日志一致。应用的两个权限 API 返回 false 反映了实际拒绝。
- 已定位到旧临时签名身份残留在权限判定中。当前证据尚不能区分残留于数据库记录还是 tccd 缓存；对权限数据库的正常只读查询被系统拒绝，没有绕过保护。不能将日志里的“Update Access Record”直接等同于已证明数据库提交成功。
- 后续修复应退出 DeskLoom，仅针对 `local.geb.ComputerUsePrototype` 重置 `Accessibility` 和 `ScreenCapture`，再用当前安装包重新授权并验证。使用 Apple 官方 `tccutil`，不修改数据库，不改变 Bundle ID 或签名身份；本次调查未执行重置。
- 证据见 `tests/permission-diagnosis-2026-10-24/`：`screen-grant-request-before-relaunch.json`、`current-process-tcc-mismatch.txt`、`running-signature.json`。这是用户本次授权及重启后的日志，不是早期测试结果。

## 2026-10-24 PermissionFlow 样式权限引导验收

- 0.7.0（build 9）已安装至 `/Applications/DeskLoom.app`。参考 `jaywcjlove/PermissionFlow` 的固定 commit `65434c9ae04dba97cf52c1dffbe3e4e62b547c82`，将侧边引导改为系统设置底部的横向卡片，与设置内容区右侧对齐。保留原有 Bundle ID、稳定签名和直接传递当前应用文件 URL 的原生拖拽。
- 实际点击无障碍、录屏两个权限入口，均触发从点击来源到系统设置的过渡动画；最终测试各记录约 35 帧。系统设置宽度 740 时，卡片为 510 × 127，状态为 `bottom_outside`，其右边缘与系统设置一致。
- 实际开始原生应用图标拖拽，状态记录 `dragPassthrough=true`、`panelAlpha=0.72`、`tracking_paused_for_drag=true`。按 Escape 取消后，透明度恢复为 1、鼠标穿透关闭、跟随恢复，原生拖拽结束回调已执行。没有向权限列表实际投放应用；`results.json` 中名为 `drag_cancelled` 的早期采样仍处于拖拽状态，恢复应以 `drag_after_escape` 和 `drag-transitions.json` 的最后状态为准。
- 通过系统设置的窗口菜单选择底部布置，实测引导切换为 `bottom_inside`，位置为 x=1139、y=8；恢复上个窗口大小后，回到 `bottom_outside`。这验证了窗口位置、尺寸改变后的跟随和屏幕下缘回退。标题栏鼠标拖动尝试没有实际移动窗口，不能记为鼠标拖动跟随通过。
- 点击卡片关闭按钮后，引导隐藏、计时器停止，原因记录为 `user_dismissed`。关闭系统设置后，本次系统设置进程随之退出，引导以 `settings_unavailable` 结束并隐藏；未将这一结果等同于“进程保留但窗口关闭”分支的验收。
- 几何跟随间隔为 1/30 秒，权限检测间隔独立为 1 秒。9 项原生 RPC 检查通过，安装包严格代码签名校验通过。
- 本次交互证据见 `tests/deskloom-0.7.0/results.json` 和 `tests/deskloom-0.7.0/drag-transitions.json`。两项权限始终为 false；没有代替用户授予权限，也没有执行权限重置。此前 TCC 旧签名失配问题没有因更换引导样式而解决。
- 真实投放进系统权限列表、真实授权成功后的自动关闭、系统“减少动态效果”及多屏场景尚未实测；原有 TextEdit / REPL 桌面闭环和权限跨编译保持仍待实际授权生效。

## 授权后必须完成

- [ ] Swift 实际读取专用 TextEdit 测试文档的 AXTextArea、value、可写状态。
- [ ] 同一 Clojure REPL 实际定位和写入含中文及换行的内容。
- [ ] 新 AX 观测精确读回一致，原生再次校验，verification 为真。
- [ ] 真实桌面 session 的 before/action/after/verification 入库，并在独立 JVM 用 `desktop.audit` 恢复验证。
- [ ] 紫色角标实际出现在目标窗口左上角，移动窗口后仍对齐；停止后消失。
- [ ] 菜单栏显示 TextEdit 及真实小图；弹层展示对应窗口。
- [ ] 至少三次截图的时间/sequence 前进，修改内容后图像 hash 改变；失败/停止显示非实时状态。

## 继续方式

用户在应用顶部的权限引导中点击对应“打开设置”，直接进入该权限页面；DeskLoom 在系统设置底部显示与内容区右侧对齐的横向卡片。将卡片中的 DeskLoom 应用拖到上方权限列表，或点击“在 Finder 中显示”选择 **`/Applications/DeskLoom.app`** 后通过「＋」添加，再开启开关。卡片会检查实际权限状态，返回应用也会自动检查。若系统要求重启，退出后运行 `dlm open`。若开关已开但检测仍为 false，应继续处理前文记录的 TCC 旧签名失配，不能将拖拽结束或新引导显示当作授权成功。

先运行 `dlm status` 确认两项权限为真，然后通过 `dlm repl` 在持久 REPL 中执行：

```clojure
(require '[desktop.acceptance :as acceptance])
(def c (desktop/connect!))
(def result (acceptance/run! c))
(:session_id result)
(desktop/close! c) ; 验收失败后也需执行
```

`run!` 会保存 A/B 写入与读回、六帧目标窗口 PNG、角标移动恢复、菜单栏实时状态和数据库查询的证据。失败也会记录，动作不自动重发。原型自身 UI 渲染与目标窗口系统截图分别标明来源。REPL关闭数据库后运行：

```sh
scripts/clj -M:xtdb -m desktop.audit SESSION_ID
```

不要以负向测试、静态源码或 UI 自身渲染替代上述真实桌面验收。

## 2026-10-24：0.7.1 后台控制与窗口提示

- 已构建、签名并安装到 `/Applications/DeskLoom.app`。安装后台重启使用 `open -g --args --background`；新旧 designated requirement 相同，无障碍和屏幕录制权限仍为 `true`。网络盘源码改用本机临时构建目录，避免 `._*` 附加文件进入签名包。
- `start` 使用 `activates=false`、禁止系统启动提示，不自动弹出工作台。若 TextEdit 已是前台，拒绝新建文档并返回 `target-in-use`，防止同应用内替换焦点；已有会话可继续使用。未通过“抢焦点后恢复”掩盖激活。
- 紫色提示显示“正在自动化控制 · TextEdit”，位于窗口左上角的标题栏内、红黄绿按钮右侧。Panel 为普通层级，不能成为 key/main，鼠标穿透。目标前方普通窗口覆盖提示区域时隐藏；较高层级系统窗口由 WindowServer 自然合成，避免把透明通知中心窗口的整块矩形误判为不透明遮挡。
- 最终 Clojure 实测会话：`8FC0BF10-A726-4A92-8C71-8DB0E6004597`。中文写入与新的 AX 读回完全一致；从连接前到停止后采样 61 次，前台 PID、应用激活序号和基于 AX `CFEqual` 的焦点窗口标识均未改变。实际基线前台为系统通知窗口；本轮未主动激活其他应用来构造测试。
- 原生返回 `overlayVisible=true`、`overlayCanBecomeKey=false`、`overlayCanBecomeMain=false`、`overlayIgnoresMouseEvents=true`、`overlayIsKeyWindow=false`、`overlayLevel=0`。目标 AX 边界 `(1288,51,1251,1368)`，提示 AppKit 边界 `(1285,1350,300,42)`，主屏顶部 `1440`，与左上角偏移契约一致。
- `evidence/focus-validation-titlebar-20261024/desktop-corner.png` 是实际桌面局部截图，已人工检查：灰色标题栏按钮保持未激活，紫色提示可见，正文首行未被遮挡。`overlay-render.png` 仅为应用自身视图渲染，不代替真实截图。
- 停止后确认 `active=false`、`overlayVisible=false`、`previewLive=false`，REPL 已关闭。详细结果及焦点采样在同目录的 `result.json`、`focus-samples.json`；复现脚本在 `evidence/focus-validation-20261024/run.clj`。
- 安装器 14 项、更新器 4 项、原生只读/负向协议 9 项测试通过；Clojure 验收逻辑 9 项测试、78 个断言通过。验收不再自动 `show_menu`，隐藏期间的角标移动明确记录 `not_observed`，不将隐藏面板旧坐标当作可见跟随证据。本轮真实验证未新增窗口移动或 Space 切换测试。

## 2026-10-24：0.7.2 提示移至右上角

- 已把提示及角描边镜像到目标标题栏右上角，面板为 `224×42`，遮挡判断同步使用右侧标签区域。保持普通窗口层级、不可 key/main、鼠标穿透。构建签名、后台安装重启成功，既有两项权限保持有效。
- 会话 `92885DD9-E380-4ACF-A2BA-4E4917D37AC1` 中文写入、读回成功，原生目标边界 `(1288,51,1251,1368)`，提示 AppKit 边界 `(2318,1350,224,42)`，面板右边缘等于目标右边缘加 3。真实截图 `evidence/focus-validation-right-20261024/desktop-corner.png` 已检查，紫色文案与描边位于窗口右上角，未覆盖正文。
- 停止后 `active=false`，提示隐藏。相关验收单测 9 项、82 个断言通过，包含窗口加宽时右侧跟随和拒绝旧左上角坐标。
- 本轮 65 次焦点采样发现 Chrome → TextEdit → Chrome，`focus_unchanged=false`，不能记为焦点验收通过。本机 OmniWM 0.7.6 / commit `3c078395` 的 Niri 新平铺窗口分支会发出主动聚焦指令；配置为所有工作区 Niri。这可以解释后台打开设置被外部管理器覆盖，但尚未通过 WM 执行日志排除该次切换中的用户操作。
- 已生成只匹配 TextEdit + DeskLoom 测试文档标题的浮动规则建议并校验 TOML；建议文件在同一证据目录 `omniwm-rule-proposal.toml`。未自动修改用户的 OmniWM 配置，已请求用户选择是否采用该局部布局规则。应用本身继续使用 `activates=false`，没有加入事后抢回焦点的逻辑。

## 2026-10-24：用户授权 OmniWM 局部浮动规则后的复测

- 用户明确选择“仅测试窗口浮动”。已在本机 OmniWM 配置中追加仅匹配旧测试应用及测试文档标题的浮动规则，原有规则及其他设置保持相同，并保存本地备份。该规则属于历史测试环境，不是项目运行要求。
- 标题匹配的 10 项边界断言通过，普通 TextEdit 文档及其他应用不受影响。OmniWM 的文件监控已重新持有替换后的配置 inode；未开启 IPC 或重启窗口管理器。运行效果以下述新窗口实测为准。
- 新建会话 `0C19F441-9720-42DD-8B3D-C506B1DC9066`：目标窗口尺寸为 `656×422`，位置 `(338,132)`，不再是原先 Niri 半屏平铺几何；中文写入与 AX 精确读回成功。
- 从启动前至停止后共有 60 次焦点采样，前台一直为 `com.openai.codex` / PID `73620`，应用激活序号及基于 AX `CFEqual` 的焦点窗口标识保持不变，`focus_unchanged=true`。本轮解决了上节实际采样未通过的情况。
- 当前浮动目标被 Codex 窗口遮挡，提示正确报告 `target_covered` 并隐藏，没有抬到用户窗口上方。右上角实际可见效果仍由上节截图证明。本轮未为截图主动提升目标或改变用户焦点。
- 停止后 `active=false`、`overlayVisible=false`、`previewLive=false`，JVM 正常退出。配置差异、完整焦点采样和复现脚本保存于 `evidence/focus-validation-float-20261024/`。
