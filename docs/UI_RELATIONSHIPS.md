# UI 状态与服务契约

这份设计说明与 [UI_RELATIONSHIPS.json](UI_RELATIONSHIPS.json) 用于维护当前界面，也用于未来替换前端语言。它们描述状态、关系和持久化边界，不是测试日志或完成率统计。

## 主调用关系

`SwiftUI View → WorkspaceStore / editor session → typed provider → BackendProcessClient → C# Host service → domain model / algorithm`

界面使用 SwiftUI 的窗口、导航、表格、表单、菜单和文件面板。工程地图和图表由对应画布呈现。C# 后端通过 JSON 请求响应及任务事件交互；模型文件、计算算法和文件格式的语义保留在后端。

## 所有权

| UI 领域 | 状态所有者 | 持久化边界 |
| --- | --- | --- |
| 项目、资产目录、窗口路由 | `WorkspaceStore`、`ProjectDocument` | 项目 XML；当前会话和窗口状态分别管理 |
| 几何、拓扑、网格和涵洞编辑 | 对应 editor / child session | 子草稿、撤销栈与父几何保存事务绑定 |
| 边界条件、时间序列和网格输入 | Boundary / Spatial editor session | 当前输入身份、时间范围及父 HDF 保存 |
| 地形、糙率和分类数据 | 对应 source session | 源文件修订、关联对象与父编辑事务 |
| 保存的地图和图层树 | map-scoped source context | 精确地图索引、名称、类型、节点 locator 与 `.vis` 修订 |
| 结果、历史帧和实时计算 | Result session、compute run owner | 精确 Result 路径、输出块、逻辑 slot、profile 和计算读取租约 |
| 渲染样式、运行时绘图选项 | 当前渲染对象或样式 session | 保存样式与临时 renderer 选项分别处理 |
| 数据表、选择、剪贴板 | 表或矢量层 session | 稳定行列 ID、实际源 feature 身份与当前编辑代次 |
| 独立图表和剖面窗口 | 被捕获源上下文的 window session | 原窗口的源对象和当前请求，不借用其他活动窗口的数据 |
| 系统操作与凭据 | 窄平台服务 | macOS 文件面板、Keychain、终端和系统 URL 操作 |

## 不变量

- 名称相同不代表对象相同。异步请求捕获项目会话、资产路径、源 SHA、map locator、当前草稿与请求代次；响应只能写回仍匹配的所有者。
- 子编辑器不越过父事务单独保存。输入错误或未完成文本保留在展示草稿中，阻止保存和计算，不改写已确认模型值。
- 项目 XML、HDF、地图 `.vis`、全局偏好和临时渲染状态各有保存边界，不互相冒充。
- 计算期间保护实际写入路径。历史结果只有与写入租约不相交时才能读取；没有实际 profile 的 slot 不构造伪造帧。
- 矢量身份保留源 feature / component、XYZM、孔洞、属性类型和 CRS；屏幕坐标或显示名称不能代替源身份。
- 取消和过时响应不得覆盖新草稿。成功提交后的刷新失败必须保留真实提交回执，不能重试成第二次写入。
- 中文与英文只用于展示；源键、枚举存储值、路径、标识符和工程数据维持原语义。

配套 JSON 列出领域关系、状态作用域、服务流程、字段身份、地图工具和数据表契约。新增路由应明确真实数据所有者、提交边界及异步响应的有效条件。
