# DeskLoom

DeskLoom 是带有 LLM 操作面板的本地 **Computer Use** 工作台：选择窗口、输入任务，即可复用本机 Codex 的 **ChatGPT 订阅登录态**执行操作。也可通过 **MCP stdio** 或 **JSON Lines** 为其他 Agent 提供窗口选择、元素观察、点击、文本输入、快捷键、滚动、拖动和截图，并把访问过的页面保存到本地 **XTDB 2.2**。当前实现 macOS 后端；外部工具接口与模型厂商无关。

## 使用 ChatGPT 订阅操作窗口

1. 打开 DeskLoom，在「交给 LLM 操作」中检查登录状态。已有 Codex ChatGPT 登录会自动复用；尚未登录时点击「登录 ChatGPT」，在浏览器完成官方登录。
2. 点击协作窗口旁的「刷新」，勾选允许操作的窗口（最多 8 个），再填写任务，例如「读取资料窗口，把摘要填写到另一个窗口」。模型可留空使用 Codex 内置默认值，也可填入账号支持的模型。
3. 点击「执行任务」，LLM 会结合所有选定窗口的内容规划操作，并明确选择每一步的目标。「停止任务」取消推理并释放本任务的所有窗口。

无需填写 API Key。登录复用由官方 Codex CLI 完成，DeskLoom 不读取或复制 OAuth token、Keychain 凭据或浏览器 Cookie；仅在浏览器登录过 ChatGPT 时，仍需完成一次 Codex 登录。当前内置规划使用窗口无障碍文本与元素信息，窗口内容会发送给所选的 OpenAI 模型。详细边界及 CLI 示例见 [LLM 接入说明](docs/LLM.md)。

启动已安装的应用后，让 Agent 运行 `dlm mcp`；自定义程序运行 `dlm agent`。完整配置、Claude Code / Cursor / Gemini CLI / VS Code 示例、动作参数及运行边界见 **[通用 Computer Use 接入指南](docs/COMPUTER_USE.md)**。CLI、LLM、MCP 和 Clojure REPL 使用同一套通用窗口控制。

提速通过常驻 JVM、AX 直接操作、变化节点返回、最多 20 步批量操作、按需截图及页面内容去重实现。工具返回本地实测耗时；历史页面只提供语义选择器线索，操作前仍使用新观察校验。当前每个数据库目录只允许一个控制进程，该进程可同时保持最多 8 个明确选择的窗口会话；各窗口的快照、动作回执独立保存，具体输入操作按顺序执行。

通用截图返回 `capture_match` 窗口关联证据。所有符合标题和几何规则的候选必须唯一，完整标题与中间省略标题同时匹配也会拒绝。省略路径还检查同进程 AX 与截图窗口的几何唯一性，并返回 `ax_selected_window_confirmed: true`；该字段仅在省略路径出现。具体字段与边界见[接入指南](docs/COMPUTER_USE.md#工具接口)。

SwiftUI 工作台显示目标应用、窗口预览与停止控制。应用不限定为某个编辑器：从系统可枚举的已有窗口中选择目标，DeskLoom 不自动启动应用或创建文档。通用会话通过显式 `focus` 激活目标。紫色角标贴合当前操作窗口的标题栏右端，不接收鼠标或键盘焦点；窗口被遮挡或切换到其他空间时按实际可见性隐藏，停止后移除。窗口截图按需获取，避免持续后台捕获；窗口丢失或截图过期时会明确标记。

## 图标与菜单栏

- 菜单栏始终只显示当前应用图标和实际受控窗口数量：空闲为 **0**，连接两个窗口为 **2**。窗口关闭或释放后自动减计数；勾选但尚未连接的窗口不计入。状态详情放在浮窗与悬停提示中。
- 默认使用 **C · 可编程桌面**，可切换 **D · 窗口层叠**；两款均为透明背景。菜单栏与窗口立即生效，重启保留选择。
- 工作台和菜单栏浮窗的顶部图标、名称与齿轮保持固定。点击齿轮时按钮高亮，下方内容切到设置页；再次点击回到控制页并取消高亮。两处页面状态独立，不另开设置窗口。
- 菜单栏左键单击打开贴合按钮下方的原生浮窗，再点一次关闭；切换窗口、应用或点击外部时自动收起。
- 菜单栏右键显示 **显示窗口 / 更新 / 退出**；“显示窗口”打开独立工作台，“退出”先停止控制会话。
- “更新”从已配置的本地源码构建、安装并自动重启。后台任务独立于旧应用运行，重复更新被阻止，控制会话进行中不能更新；失败会显示原因和日志位置。
- “应用程序”中的图标随更新同步为当前选择。切换时不直接修改已签名的安装包，避免自定义 Finder 图标产生的扩展属性破坏签名校验。更新仍使用同一代码身份。

## 安装、启动和更新

```sh
bash scripts/run-native.sh
```

DeskLoom 固定安装到 **`/Applications/DeskLoom.app`**，可直接从“应用程序”启动。首次运行上面的脚本会编译、安装并打开；之后只打开这份已安装应用，不从项目构建目录启动。安装器同步创建 `~/.local/bin/dlm`，指向应用包内的 CLI；如果该目录已在 `PATH` 中，可直接执行 `dlm`。

源码变更后运行：

```sh
bash scripts/build-native.sh
```

脚本先在临时目录完成编译、签名和验证，然后停止空闲的旧实例，更新“应用程序”中的同一路径并重新启动。若有活跃控制会话，会停止安装并提示先结束会话；构建失败不会影响正在使用的安装版。旧版备份保留到新版启动并通过 RPC 就绪检查，失败会尝试恢复旧版。旧 `.build` 应用首次迁移时保存为 ZIP 归档并移除可启动副本。

构建使用本机已有的 Apple Development / Developer ID 签名，并将证书选择固定在 `.runtime/signing-identity`。首次可用 `DESKLOOM_SIGNING_IDENTITY` 指定现有证书；旧环境变量 `COMPUTER_USE_SIGNING_IDENTITY` 兼容保留，后续拒绝无意切换。安装前还会验证新版本符合已安装版本的 designated requirement，防止重新编译改变代码身份。没有有效签名身份时停止，不回退临时签名。

旧版 `Computer Use Prototype.app` 迁移到新的固定安装路径；内部 Bundle ID **`local.geb.ComputerUsePrototype`** 有意保留，配合同一签名身份延续已有代码身份，避免仅为品牌更名重新建立授权身份。项目目录及 Clojure `desktop.*` 命名空间保持兼容。数据迁移到 `~/Library/Application Support/DeskLoom/`，旧数据路径保留兼容符号链接；CLI 和 Clojure 也能读取尚未迁移的旧路径。

应用启动和返回前台时会自动检查无障碍、屏幕录制两项权限。点击“打开设置”会进入对应权限页，引导卡从点击位置移动到系统设置底部，与右侧权限内容区对齐。卡片用箭头指向上方列表，整行 DeskLoom 应用卡都可拖动。拖入的是 **`/Applications/DeskLoom.app`** 的真实文件 URL，使用当前选择的 C / D 图标，不生成应用副本。添加后仍需打开系统开关。

引导卡跟随系统设置窗口移动，切到其他应用时隐藏，返回系统设置时恢复；拖动时暂停跟随、降低卡片不透明度并让鼠标事件穿透，结束后恢复。卡片始终保留在屏幕可见区域，底部空间不足时贴在内容区底缘；尊重系统“减少动态效果”设置。检测到本项权限已生效后自动关闭，也可手动关闭。位置跟随只读取窗口边界元数据，不依赖无障碍或屏幕录制授权。无法取得窗口边界时回退到屏幕边缘；仍可使用“在 Finder 中显示”或权限列表的「＋」添加。返回 DeskLoom 会自动更新权限状态，也可点击“重新检查”。若系统要求重启，退出后重新运行启动脚本即可，不需要重新编译。

该交互参考 [PermissionFlow](https://github.com/jaywcjlove/PermissionFlow/tree/65434c9ae04dba97cf52c1dffbe3e4e62b547c82)，采用其底部对齐、从点击位置移动、横向拖拽卡和拖动穿透的设计，保留 DeskLoom 自身的权限检测与固定安装路径。参考源码与 MIT 许可存放在 `references/permissionflow/`，应用包内附带许可。拖拽完成不会被当作授权成功；状态仍以 macOS 权限 API 为准。

macOS 27 将“辅助功能”权限改名为“设备控制和数据访问”，两者是同一项权限，设置入口仍为 `Privacy_Accessibility`。从旧版临时签名迁移后，需要在该列表移除旧的 **Computer Use Prototype** 条目，再从 Finder 添加当前应用并开启；屏幕录制若显示未生效，也重新添加一次。仅重启不能修复绑定旧签名的授权条目。使用同一证书重建可保持代码身份稳定。

若已经添加当前 DeskLoom、开关已开启且重启仍无效，应先检查系统 `tccd` 日志。2026-10-24 的实际诊断中，系统接收了新授权，后续校验却仍使用早期临时签名的 CDHash，报 `Failed to match existing code requirement`。这种情况需退出 DeskLoom，仅清除本应用的两项旧授权，再重新添加；不是每次编译都执行。Apple 提供按应用限定范围的 [tccutil 重置方式](https://developer.apple.com/documentation/xcode/resetting-access-to-protected-resources-in-macos)：

```sh
tccutil reset Accessibility local.geb.ComputerUsePrototype
tccutil reset ScreenCapture local.geb.ComputerUsePrototype
```

重置后用 `dlm open` 启动，分别通过权限引导授权；以 `dlm status` 两项都为 `true` 为准，再实测一次重编译后权限保持。完整证据和仍待验证的边界见 `VALIDATION.md`。

## CLI：`dlm`

```sh
dlm open            # 打开已安装的 DeskLoom
dlm status          # 读取控制会话与真实系统权限
dlm settings        # 在当前浮窗或工作台内进入设置页
dlm icon            # 查看当前图标与安装包图标
dlm icon D          # 切换为 D；dlm icon C 恢复默认
dlm repl            # 启动 Clojure + XTDB REPL
dlm mcp             # 启动通用 computer use MCP stdio 服务
dlm agent           # 自定义 Agent 使用相同工具的 JSON Lines 服务
dlm llm status      # 检查本机 Codex 的 ChatGPT 订阅登录状态
dlm llm login       # 使用官方浏览器流程登录 ChatGPT
dlm llm run --help  # 对明确选择的窗口执行自然语言任务
dlm update          # 请求本地源码更新、安装并重启
dlm rpc ui_state    # 发送一次原生 RPC
dlm rpc focus_state # 只读前台应用、焦点窗口标识和应用激活序号
dlm --help
```

`mcp`、`agent` 是常驻服务，握手和工具发现无需连接原生应用；实际桌面操作前先执行 `dlm open`。其他状态和控制命令连接已运行的应用。`update` 返回请求是否被接受，最终结果显示在工作台、菜单栏浮窗及本地 `update-state.json`。图标切换立即更新菜单栏和窗口，“应用程序”中的图标经过 `dlm update` 后同步。`rpc METHOD 'JSON对象'` 可传递原生协议参数；发生错误或超时不会自动重试动作。

CLI 入口仅使用 Python 标准库，连接 `127.0.0.1` 并从私有 endpoint 文件读取令牌，不输出令牌。`repl`、`mcp`、`agent` 使用安装包记录的源码目录与项目本地 Clojure 运行时，因此仍需要保留源码项目。源码内也可直接运行 `scripts/dlm`；若 `~/.local/bin` 尚未加入 `PATH`，可使用完整路径 `~/.local/bin/dlm`，安装器不修改 shell 配置。

## Clojure REPL

```sh
dlm repl
```

```clojure
(def c (desktop/connect!))
(desktop/status c)
(desktop/windows c) ; 从返回列表中明确选择窗口 ID
(def attached (desktop/attach! c {:window_id "从列表选择的窗口ID"}))
(def sid (:session_id attached))
(desktop/observe! c sid)
;; 对选定窗口的唯一可写文本区域写入，并读取实际回执：
(desktop/act! c sid {:action "set_value"
                    :selector {:role "AXTextArea" :settable true}
                    :value "Hello from Clojure"})
(desktop/history c sid)
(desktop/detach! c sid)
(desktop/close! c)
```

可再次调用 `attach!` 连接其他应用或同一应用的其他窗口。操作始终指定对应的 `session_id`；选择器必须在该窗口内唯一匹配。控制进程关闭时释放它拥有的所有窗口。不要同时启动两个使用同一数据库目录的控制进程，详情见 [controller/README.md](controller/README.md)。

## 范围与协议

- `computer_*` 接口控制调用者明确选择的已有应用窗口，没有应用名称或 Bundle ID 白名单。已移除旧测试文档的专用 RPC；连接和操作统一使用通用接口。
- HTTP RPC 仅监听 `127.0.0.1`，每次启动生成 token；endpoint 文件权限为 0600。token 不写入日志。
- 原生 AX 句柄只留内存；快照有效期为 15 秒。动作前再确认进程、窗口、祖先关系、角色和旧值，动作后旧快照失效。
- 同一 `request_id` 的同一动作返回已记录结果；不同内容复用 ID 会被拒绝。DeskLoom 重启后不重放旧动作。
- 通用回执区分 dispatched、verified、unknown；只有真实读回确认的写值才返回 verified，点击和按键的业务效果仍需后续观察。结果未知时记录状态，不自动重试。
- LLM 宣布完成前重新观察全部所选窗口；完整状态发生变化时，用最新内容重新判断，并计入原步骤与时间上限。写入前仍严格校验所有来源和目标窗口，未确认的完成消息不会提前展示。
- 使用有界 AX 树采集与定时窗口位置检查，尚未实现 AXObserver 事件流、Windows/Linux 后端或锁屏使用。通用操作的实际能力取决于目标应用的 AX 支持。

## 文件与数据

- `native/Sources/`：Swift AX、RPC、SwiftUI 与原生应用入口。
- `controller/src/desktop/`：Clojure RPC、选择器、验证与 XTDB。
- `.runtime/`：项目独立 Java、Clojure CLI、Maven 缓存。
- `/Applications/DeskLoom.app`：唯一的日常运行与授权应用；包内包含 `dlm` 和 RPC 模块。
- `~/.local/bin/dlm`：指向应用包内 CLI 的符号链接。
- `.build/`：旧开发版迁移归档；不保留日常启动副本。签名应用和图标先在本机临时目录构建，避免网络盘的 AppleDouble `._*` 附加文件破坏签名。
- `.runtime/signing-identity`：固定的签名证书选择；`.runtime/installation.json`：最近安装与权限检查摘要。
- `assets/icons/`：选定的 C / D PNG 与生成提示词；构建时生成完整尺寸 ICNS 并打包。
- `~/Library/Application Support/DeskLoom/appearance.json`：图标选择；同目录的 `update-state.json`、`update.log` 保存更新结果与日志。
- `~/Library/Application Support/DeskLoom/xtdb/`：本地日志与数据库存储。
- 同目录 `ui-evidence/`：DeskLoom 自身界面渲染；通用窗口截图通过 `computer_screenshot` 按需返回。

## 检查

```sh
bash scripts/build-native.sh
python3 tests/native_contract.py
python3 tests/test_install_native.py
python3 tests/test_update_native.py
python3 tests/test_app_storage.py
python3 tests/test_dlm.py
python3 tests/test_mcp.py
python3 tests/test_llm.py
scripts/clj-test
python3 tests/multiwindow_acceptance.py --live --with-llm # 独立测试应用双窗口协作，使用当前订阅
# 可选：真实 Chrome → Edge 跨应用 LLM 读取/填写、独立读回与菜单计数
python3 tests/cross_app_acceptance.py --live
# 可选：真实通用接口闭环，仅操作独立测试应用
python3 tests/computer_acceptance.py --live
# 可选：已注册 Codex MCP + 独立 Chrome 窗口 + 默认 XTDB + 配对测速
python3 tests/browser_acceptance.py --live
# 可选：3 次独立 Chrome 启动、21 张截图，覆盖短标题和中间省略的长标题
python3 tests/screenshot_acceptance.py --live
```

RPC 诊断：`dlm status`，兼容入口为 `python3 scripts/rpc.py status`。CLI 测试使用隔离目录和临时本地服务，不连接真实应用。无系统权限时，负向协议测试仍可执行；它们不能证明真实 AX 操作和截图已经成功。端到端验证必须单独完成，并保留实际证据。
