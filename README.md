# DeskLoom

DeskLoom 是可通过 **`dlm`** 和 Clojure REPL 操作的本地桌面工具。当前验证范围为 TextEdit：Swift 无障碍读取与执行 → Clojure REPL 选择器 → AX 精确读回验证 → XTDB 2.2 本地持久化。没有 LLM 或云端调用。

SwiftUI 工作台和菜单栏显示目标应用、窗口预览与停止控制。测试文档在后台打开，连接、写入、读回和停止都不激活目标应用。紫色区域在测试窗口右上角显示简短的“控制中”，贴合标题栏右端，不遮挡正文，也不接收鼠标或键盘焦点；窗口被遮挡或切换到其他空间时按实际可见性隐藏，停止后移除。预览约每 0.6 秒捕获一次，仅捕获当前测试窗口。停止、窗口丢失或截图过期时会明确标记。

若正使用 TextEdit 的其他文档，新建控制会话会返回 `target-in-use`，避免后台开文档仍切走同应用内的焦点；先切换到其他应用即可连接。已建立的控制会话可继续使用。自动更新重启采用后台启动，手动点击菜单“显示窗口”仍会正常打开工作台。

后台打开不请求激活应用，但窗口管理器仍可能自行聚焦新窗口。例如 OmniWM 的 Niri 布局会激活新平铺窗口；可为 `com.apple.TextEdit` 中标题匹配 `^DeskLoom [0-9A-F]{8}(?:\.txt)?(?: —.*)?$` 的测试文档单独设置浮动规则，再验证实际焦点。DeskLoom 不自动修改窗口管理器配置。

## 图标与菜单栏

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

脚本先在临时目录完成编译、签名和验证，然后停止空闲的旧实例，更新“应用程序”中的同一路径并重新启动。若正在控制 TextEdit，会停止安装并提示先结束会话；构建失败不会影响正在使用的安装版。旧版备份保留到新版启动并通过 RPC 就绪检查，失败会尝试恢复旧版。旧 `.build` 应用首次迁移时保存为 ZIP 归档并移除可启动副本。

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
dlm update          # 请求本地源码更新、安装并重启
dlm rpc ui_state    # 发送一次原生 RPC
dlm rpc focus_state # 只读前台应用、焦点窗口标识和应用激活序号
dlm --help
```

除 `open`、`repl`、帮助外，以上命令连接已运行的应用；应用未启动时先执行 `dlm open`。`update` 返回请求是否被接受，最终结果显示在工作台、菜单栏浮窗及本地 `update-state.json`。图标切换立即更新菜单栏和窗口，“应用程序”中的图标经过 `dlm update` 后同步。`rpc METHOD 'JSON对象'` 可传递原生协议参数；发生错误或超时不会自动重试动作。

CLI 仅使用 Python 标准库，连接 `127.0.0.1` 并从私有 endpoint 文件读取令牌，不输出令牌。`repl` 使用安装包记录的源码目录与项目本地 Clojure 运行时，因此仍需要保留源码项目。源码内也可直接运行 `scripts/dlm`；若 `~/.local/bin` 尚未加入 `PATH`，可使用完整路径 `~/.local/bin/dlm`，安装器不修改 shell 配置。

## Clojure REPL

```sh
dlm repl
```

```clojure
(def c (desktop/connect!))
(desktop/status c)
(desktop/start! c)
(def snapshot (desktop/ready-snapshot! c))
(def target (desktop/unique-text-area snapshot))
(select-keys target [:id :role :value :settable])
(desktop/set-text! c "Hello from Clojure\n中文验证：Swift AX → XTDB\n")
(desktop/history c)
(db/text-areas (:store c) (:session_id @(:session c)))
(desktop/stop! c)
(desktop/close! c)
```

`set-text!` 会重新观察、唯一定位、先保存动作意图、只发送一次写入，再精确比较 AX 读回的字符串。不要同时启动两个连接同一数据库目录的 REPL/demo。

一键端到端运行：`scripts/clj -M:xtdb:demo`。详细命令和依赖说明见 [controller/README.md](controller/README.md)。

完整桌面验收使用已 `connect!`、但尚未 `start!` 的连接，从同一个 REPL 运行 `(require '[desktop.acceptance :as acceptance])` 后执行 `(acceptance/run! c)`。它检查两次中文文本写入、六帧真实截图、角标跟随窗口移动与停止后的界面状态，并保存 `evidence/`；两项系统权限缺一时直接记录失败，不启动会话。完成后关闭连接，再用独立 JVM 运行 `desktop.audit` 核对该 session 的持久化记录。

## 范围与协议

- 仅控制 DeskLoom 在 `~/Library/Application Support/DeskLoom/fixtures/` 创建的唯一 TextEdit 文档，不改已有文档。
- HTTP RPC 仅监听 `127.0.0.1`，每次启动生成 token；endpoint 文件权限为 0600。token 不写入日志。
- 原生 AX 句柄只留内存，元素绑定 30 秒内的观测快照；写入前再确认进程、窗口、祖先关系、角色和文本旧值。写入后旧快照失效。
- 同一 `request_id` 的同一动作返回已记录结果；不同内容复用 ID 会被拒绝。DeskLoom 重启后不重放旧动作。
- 操作成功必须通过新 AX 读回验证。结果未知时记录状态，不自动重试。
- 验证中断写入关联动作的 `verification-error`，界面显示“验证中断”；持久化审计只认可最新文本动作的完整成功记录。
- 验收使用 `move_window` 仅移动本次测试文档，并要求完整保留在可见屏幕内；通过新的 AX 观测验证角标跟随，最后恢复原位置。
- 首版用有界 AX 树采集与定时窗口位置检查，尚未实现通用 AXObserver 事件流、任意应用操作或锁屏使用。

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
- 同目录 `preview.png`：最新目标窗口图像；`ui-evidence/` 只保存DeskLoom 自身界面渲染。

## 检查

```sh
bash scripts/build-native.sh
python3 tests/native_contract.py
python3 tests/test_install_native.py
python3 tests/test_update_native.py
python3 tests/test_app_storage.py
python3 tests/test_dlm.py
scripts/clj-test
```

RPC 诊断：`dlm status`，兼容入口为 `python3 scripts/rpc.py status`。CLI 测试使用隔离目录和临时本地服务，不连接真实应用。无系统权限时，负向协议测试仍可执行；它们不能证明真实 AX 操作和截图已经成功。端到端验证必须单独完成，并保留实际证据。
