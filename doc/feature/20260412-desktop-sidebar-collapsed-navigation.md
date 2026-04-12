# Desktop Sidebar Collapsed Navigation

## 功能说明
为桌面主应用左侧总菜单补充了收缩态导航能力。在桌面宽度变小时，侧栏不再强制保留完整标题文本，而是自动切换为仅图标模式；用户将鼠标悬浮到图标上时，通过 `Tooltip` 查看对应栏目标题。这样可以在不改变整体视觉风格的前提下，为右侧主内容区域释放更多空间。

## 代码位置
- `client/apps/desktop_app/lib/main.dart`

## 实现方法
1. 在 `DesktopHomePage` 中基于当前窗口宽度计算 `useCollapsedSidebar`，并按模式切换总菜单宽度。
2. 侧栏头部在完整模式显示产品标题和连接节点信息；在收缩模式下改为仅显示品牌图标，并将完整信息放入悬浮提示。
3. 将主导航项抽离为 `_DesktopSidebarNavItem`，统一处理选中态颜色、图标显示以及收缩态下的 `Tooltip` 行为。
4. 将底部 `Support`、`Logs` 区域同步改造成支持收缩态的 `_SidebarFooterItem`，保证总菜单交互风格一致。
