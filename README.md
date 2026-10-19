# HEC-RAS 2025

面向 Apple Silicon Mac 的水力建模桌面应用。使用 SwiftUI 提供简体中文和英文界面，支持项目管理、几何与边界条件编辑、地图、计算任务和结果查看；C# 业务与计算服务由应用内的独立后端进程提供。

## 构建与运行

需要 Apple Silicon Mac、macOS 26 或更新版本、带相应 macOS SDK 的 Xcode、.NET 10 和 Python 3。首次构建需要访问 NuGet。

```sh
bash build-all.sh
open "macos/build/HEC-RAS 2025.app"
```

如安装了多个 Xcode，请先用 `DEVELOPER_DIR` 选择支持当前 SDK 的版本。构建入口同时编译 C# 后端和 SwiftUI 应用，编译警告按错误处理。生成的应用包含后端运行时。

运行完整自动化测试：

```sh
python3 test-all.py
```

可分别用 `HECRAS_APP_SWIFT_SCRATCH_PATH` 与 `HECRAS_SWIFT_SCRATCH_PATH` 指定应用和测试的编译缓存，避免两种编译配置相互覆盖。

## 目录

| 目录 | 内容 |
| --- | --- |
| `macos/Sources` | SwiftUI 界面、工作区状态与平台服务 |
| `macos/Tests` | Swift 单元测试和后端集成测试 |
| `backend/Source` | 业务模型、计算、地图与文件格式实现 |
| `backend/Host` | 进程协议、业务服务与计算任务调度 |
| `backend/Tests` | C# 业务、文件格式和运行时测试 |
| `backend/Packages` | 随项目提供的固定版本 NuGet 包 |
| `docs` | 界面状态、数据所有权与持久化契约 |

## 开发状态

当前为开发版本。地图提供源渲染器选项、要素上下文操作、File Geodatabase 图层导入和流式 TIN 显示，聊天服务暂未启用。源实现中尚无实际效果的选项会说明原因并禁用。File Geodatabase 栅格依赖当前 GDAL 驱动能力，真实栅格子数据集已纳入自动化验证；实际界面交互与工程模型仍需持续验收。

开发约定见 [AGENTS.md](AGENTS.md)，架构契约见 [docs/UI_RELATIONSHIPS.md](docs/UI_RELATIONSHIPS.md)，来源与许可信息见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
