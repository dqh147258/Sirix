# AI Settings UI Refinements

## 功能说明
优化并重构了 AI Settings 界面的 UI 设计，使其更贴近全新的 reference design，同时确保不破坏 Sirix 统一的 App UI 主题与现有功能。处理了之前 Switch Button 会因为宽度限制而遮挡、截断文字的问题，并且修正了字体的规范化显示，确保排版更规整兼顾美观。

## 代码位置
主要修改涉及以下文件：
- `client/packages/feature_settings_ai/lib/src/settings_ui.dart`
- `client/packages/feature_settings_ai/lib/src/ai_settings_page.dart`

**输出文档位置** (对于不合理的 UI/设计做出的调整说明记录在此)：
- `doc/development/20260412/new-ui-deviations.md`

## 实现方法
1. **组件重构 (`AiSettingsToggleTile`)**：
   - 移除了强制固定的 `width`，改为可选宽度并在提供默认回退 `constraints` 的前提下，允许组件适应不同的屏幕空间，避免了 `Row` 内文字和 `Switch` 发生遮挡。
   - 使用了 `Expanded` 与 `Column` 的组合包装文本部分并增加了 `softWrap: true` 属性，当文本过长时可以合理换行，不再相互覆盖。
   - 更新了边距与圆角（将原本较圆的 `14` 或 `24` 全部修改为方形风格的 `8` 或 `4`，匹配最新的 Bento 布局语义）。
2. **主题接入 (`app_theme.dart`)**：
   - 没有使用 HTML demo 里的死码色彩 (如纯绿色 `#00FF41` 作为底色等硬编码)，改为复用 `context.sirix` 中现存的 `palette.primaryBright`, `palette.surfaceMuted`, `palette.glassStroke` 等变量，使其完全融入现有的 App 调色板系统。
3. **导航样式重写 (`_NavItem`)**：
   - 为选中项添加了左侧宽边框 `border-left` 加亮效果，同时替换了选中时的背景半透明颜色，彻底实现了侧边栏新的状态显示规则。字体在列表名称中强行利用 `Space Grotesk`，简介采用 `Inter`，匹配设计图要求。
4. **响应式回归修复 (`agent_settings_section.dart`, `provider_settings_section.dart`, `skills_settings_section.dart`)**：
   - `Agents` 页面补充了三档布局策略：宽屏保留完整侧栏，中等宽度自动收缩为仅图标模式，并通过 `Tooltip` 在鼠标悬浮时展示 Agent 标题；再更窄时切换为上下堆叠布局，避免在桌面最小支持宽度附近挤压详情区。
   - `Providers` 卡片头部将高密度摘要区改为基于宽度自动拆行的实现，保留原有视觉风格，但避免 provider 名称、默认模型信息和操作区在单行中互相抢占空间。
   - `Providers` 与 `Skills` 的溢出菜单改为走 `PopupMenuButton.onSelected`，避免菜单关闭和弹窗/删除逻辑竞争时序，减少编辑按钮偶发失效或行为不稳定的问题。
5. **外层导航收缩策略 (`ai_settings_page.dart`)**：
   - AI Settings 最外层左侧导航不再在窄宽度切换成顶部 `ChoiceChip`，而是保持桌面侧栏结构。
   - 当宽度不足时，导航自动收缩为仅图标模式，保留选中态高亮和整体风格；标题与说明文字隐藏，通过鼠标悬浮 `Tooltip` 补充展示栏目名称，优先把空间让给右侧配置内容。

此次改动提升了视觉的精致度，且所有配置数据的绑定依然走 `AiSettingsViewModel`，保证了功能连贯性。
