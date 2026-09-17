# FlowIsle（知行岛）

FlowIsle 是一个原生 macOS 菜单栏待办面板，用来同时跟踪多个工作方向。每个方向可以标记为「等待 Agent」或「下一步工作」，并维护独立的待办清单。它不连接 Agent 服务；状态由你手动维护。

鼠标悬浮时展开详情，移开后收起，过渡带有动画。支持可拖动的悬浮模式，以及贴近屏幕顶部的灵动岛模式；后者可以指定显示屏。有摄像头刘海时，收起状态在左右分别显示 Logo 和「下一步方向数 / 总方向数」；无刘海时显示方向名称。方向的名称与备注可编辑；待办完成后保留 10 秒撤销机会，再淡出。

## 下载与安装

在 GitHub Releases 下载通用架构 DMG（Apple Silicon 和 Intel Mac 均适用）。打开后把 **FlowIsle.app** 拖到 **Applications**。需要 macOS 13 或更新版本。应用常驻菜单栏，不出现在 Dock。

当前发布包使用临时签名，尚无 Apple Developer ID 公证。下载后 macOS 可能拦截首次打开；可在「系统设置 → 隐私与安全性」中确认打开。若希望免除这一提示，需要维护者使用 Apple Developer ID 签名并提交公证。

## 使用

- 点击菜单栏图标可显示、隐藏或退出应用。
- 点击「管理」可添加、修改、删除和恢复方向，并切换悬浮或灵动岛模式、选择显示屏。删除的方向可清空。
- 点击方向右上角的加号添加待办，按回车保存；点击待办文字可编辑。点击编辑区外可取消未保存的修改。
- 点击待办左侧圆圈标记完成；10 秒内再点一次可撤销。
- 首次启动附带四个通用示例方向，可自行修改或删除。

所有状态保存在本机 `~/Library/Application Support/WorkIsland/state.json`；应用不发送网络请求。升级安装不会移除这个文件。备份时复制它；恢复时先退出应用再替换。旧版数据会自动迁移并保留迁移前备份。

## 从源码构建

需要 macOS 13+ 和 Xcode Command Line Tools，无第三方代码依赖：

```bash
bash build.sh
bash scripts/package.sh
```

`build.sh` 会编译 Apple Silicon 和 Intel 双架构 app、运行内建的状态及迁移自测、校验代码签名。`package.sh` 会生成可拖拽安装的 DMG 和 SHA-256 校验文件，输出在 `dist/`。推送 `v*` 标签后，GitHub Actions 会在 macOS runner 上运行同一打包脚本并创建 Release。当前自动构建包也是临时签名，不能替代 Apple 公证。

## 许可证

[MIT](LICENSE)。
