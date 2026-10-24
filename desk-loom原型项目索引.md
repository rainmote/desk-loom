---
created: 2026-10-23
updated: 2026-10-24
---

# DeskLoom 项目索引

目标：DeskLoom（CLI：`dlm`）提供 TextEdit 的 Swift AX → Clojure REPL → 读回验证 → 本地 XTDB 闭环，不接 LLM；提供紫色目标角标、菜单栏应用名和实时缩略图。

状态：产品名称统一为 DeskLoom，标准安装位置为 `/Applications/DeskLoom.app`，CLI 入口为 `~/.local/bin/dlm`。C / D 透明图标、当前窗口内设置页与菜单栏浮窗失焦关闭已纳入界面；内部 Bundle ID 保留兼容，构建保持同一签名身份。RPC/Clojure/XTDB 独立测试通过；系统辅助功能与屏幕录制权限待用户开启，真实桌面闭环未验收。

- [[04-Project/computer-use-prototype/README|运行与 REPL 使用说明]]
- [[04-Project/computer-use-prototype/VALIDATION|验收证据与待完成项]]
- [[04-Project/computer-use-prototype/controller/README|Clojure 与 XTDB 细节]]
- [[99-LLM-OUTPUTS/Research/软件工程/ChatGPT Computer Use原理与Clojure桌面自动化方案|前期调研与架构方案]]

下一步：权限开启后，真实操作专用测试文档；检查角标跟随、菜单栏与连续截图；退出 REPL 后用独立 JVM 审计该真实 session 的持久化记录。
