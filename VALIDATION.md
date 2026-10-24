---
created: 2026-10-23
---

# 原型验收状态

当前状态：**可编译运行，独立数据/RPC测试通过；真实桌面闭环等待 macOS 系统授权。尚未完成目标验收。**

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

- 用户明确选择“仅测试窗口浮动”。已原子更新 `/Users/geb/.config/omniwm/settings.toml`，追加唯一规则 `7AFB8506-5015-40D1-8D1A-0F107B8A1A7F`：`bundleId=com.apple.TextEdit`，标题匹配 `^DeskLoom [0-9A-F]{8}(?:\.txt)?(?: —.*)?$`，`layout=float`。原有 12 条规则及其他设置保持相同；原文件备份为 `/Users/geb/.config/omniwm/settings.toml.backup-deskloom-20261024-203236`。
- 标题匹配的 10 项边界断言通过，普通 TextEdit 文档及其他应用不受影响。OmniWM 的文件监控已重新持有替换后的配置 inode；未开启 IPC 或重启窗口管理器。运行效果以下述新窗口实测为准。
- 新建会话 `0C19F441-9720-42DD-8B3D-C506B1DC9066`：目标窗口尺寸为 `656×422`，位置 `(338,132)`，不再是原先 Niri 半屏平铺几何；中文写入与 AX 精确读回成功。
- 从启动前至停止后共有 60 次焦点采样，前台一直为 `com.openai.codex` / PID `73620`，应用激活序号及基于 AX `CFEqual` 的焦点窗口标识保持不变，`focus_unchanged=true`。本轮解决了上节实际采样未通过的情况。
- 当前浮动目标被 Codex 窗口遮挡，提示正确报告 `target_covered` 并隐藏，没有抬到用户窗口上方。右上角实际可见效果仍由上节截图证明。本轮未为截图主动提升目标或改变用户焦点。
- 停止后 `active=false`、`overlayVisible=false`、`previewLive=false`，JVM 正常退出。配置差异、完整焦点采样和复现脚本保存于 `evidence/focus-validation-float-20261024/`。
