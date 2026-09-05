from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
NATIVES = ROOT / "Natives"
CMAKE = (NATIVES / "CMakeLists.txt").read_text()
UI_PACK_MANAGER = (NATIVES / "PLUIPackManager.m").read_text()
UI_PACK_HEADER = (NATIVES / "PLUIPackManager.h").read_text()
THEME_MANAGER = (NATIVES / "PLThemeManager.m").read_text()
LUA_RUNTIME = (NATIVES / "PLLuaRuntime.m").read_text()
LUA_RUNTIME_H = (NATIVES / "PLLuaRuntime.h").read_text()
NODE_VIEW = (NATIVES / "PLUINodeView.m").read_text()
LAYOUT_ENGINE = (NATIVES / "PLUILayoutEngine.m").read_text()
LAYOUT_ENGINE_H = (NATIVES / "PLUILayoutEngine.h").read_text()
LINIT = (NATIVES / "external/lua/linit.c").read_text()
LUA_DIR = NATIVES / "external/lua"
SHELL_VC = (NATIVES / "PLUIShellViewController.m").read_text()
ACTION_ROUTER = (NATIVES / "PLUIActionRouter.m").read_text()
SCENE_DELEGATE = (NATIVES / "SceneDelegate.m").read_text()
PREFERENCES = (NATIVES / "PLPreferences.m").read_text()
PREF_VC = (NATIVES / "LauncherPreferencesViewController.m").read_text()
PACK_ROOT = NATIVES / "resources/themes/pcl-classic"
MAIN_LUA = (PACK_ROOT / "main.lua").read_text()
PACK_MANIFEST = (PACK_ROOT / "manifest.json").read_text()


class UIPackContracts(unittest.TestCase):
    """M3 UI 材质包契约：包管理器、Lua 沙箱、manifest 版本放宽。"""

    def test_ui_pack_manager_is_built(self):
        self.assertIn("PLUIPackManager.m", CMAKE)
        self.assertTrue((NATIVES / "PLUIPackManager.h").exists())
        self.assertTrue((NATIVES / "PLUIPackManager.m").exists())

    def test_lua_engine_is_vendored_and_built(self):
        # 引擎核心源码必须 vendored 且进入 CMake 构建
        for header in ("lua.h", "luaconf.h", "lualib.h", "lauxlib.h", "ljumptab.h"):
            self.assertTrue((LUA_DIR / header).exists(), f"missing {header}")
        self.assertIn("add_library(lua STATIC", CMAKE)
        self.assertIn("external/lua/linit.c", CMAKE)

    def test_lua_sandbox_drops_unsafe_libraries(self):
        # 编译期裁剪：脚本层永远无法触达 os/io/package/debug
        for forbidden in ("luaopen_os", "luaopen_io", "luaopen_package", "luaopen_debug"):
            self.assertNotIn(forbidden, LINIT)
        for allowed in ("luaopen_base", "luaopen_coroutine", "luaopen_table",
                        "luaopen_string", "luaopen_math", "luaopen_utf8"):
            self.assertIn(allowed, LINIT)

    def test_theme_manifest_accepts_ui_packs(self):
        # schemaVersion 2 = UI 材质包；纯颜色包（1）保持兼容
        self.assertIn("PLThemeMaxManifestVersion", THEME_MANAGER)
        self.assertIn("version > PLThemeMaxManifestVersion", THEME_MANAGER)
        self.assertIn('@"schemaVersion"', THEME_MANAGER)

    def test_entry_script_is_sandboxed(self):
        # 入口脚本只允许包根下的单段文件名，且限 256KB
        self.assertIn("PLUIPackMaxScriptBytes = 256 * 1024", UI_PACK_MANAGER)
        self.assertIn('isEqualToString:entry.lastPathComponent', UI_PACK_MANAGER)
        self.assertIn('containsString:@".."', UI_PACK_MANAGER)
        self.assertIn("PLUIPackSchemaVersion = 2", UI_PACK_MANAGER)

    def test_pack_discovery_reuses_theme_roots(self):
        # UI 包与主题包共用 themes/ 目录解析规则，不另起炉灶
        self.assertIn("rootForIdentifier", UI_PACK_MANAGER)
        self.assertIn("rootForIdentifier", (NATIVES / "PLThemeManager.h").read_text())

    def test_colors_only_pack_is_valid_state(self):
        # 纯颜色包（schemaVersion 1）→ activePack 为 nil 是合法状态而非错误
        self.assertIn("@property (nonatomic, nullable, readonly) PLUIPack *activePack", UI_PACK_HEADER)

    def test_lua_runtime_is_built(self):
        self.assertIn("PLLuaRuntime.m", CMAKE)
        # 主 target 必须链接 lua 静态库
        self.assertRegex(CMAKE, r"target_link_libraries\(AngelAuraAmethyst[^)]*lua")

    def test_runtime_has_no_file_or_network_bridges(self):
        # 沙箱契约：脚本运行时不得出现文件/网络 API，脚本层无法触达
        for forbidden in ("NSFileManager", "NSURLSession", "dataWithContentsOfFile", "NSURL"):
            self.assertNotIn(forbidden, LUA_RUNTIME, f"PLLuaRuntime.m must not use {forbidden}")

    def test_runtime_has_budgets_and_limits(self):
        # 内存限额 + 指令钩子超时 + 默认预算
        self.assertIn("PLLuaRuntimeMemoryCap", LUA_RUNTIME)
        self.assertIn("lua_sethook", LUA_RUNTIME)
        self.assertIn("buildTimeout", LUA_RUNTIME_H)
        self.assertIn("eventTimeout", LUA_RUNTIME_H)

    def test_launcher_api_surface(self):
        # 脚本可用的 view 句柄命令与动作回调
        self.assertIn("viewCommandHandler", LUA_RUNTIME_H)
        self.assertIn("actionHandler", LUA_RUNTIME_H)
        self.assertIn("dispatchEvent", LUA_RUNTIME_H)
        for cmd in ("setText", "setTextColor", "setImage", "setVisible", "setEnabled", "getText"):
            self.assertIn(cmd, LUA_RUNTIME)
        # prelude 必须提供全部节点构建器与 launcher 封装
        for kind in ("'row'", "'column'", "'button'", "'text'", "'image'", "'spacer'",
                     "'divider'", "'content'", "'nav'", "'panel'", "'tileGrid'"):
            self.assertIn(kind, LUA_RUNTIME)
        for name in ("ui.dimen", "launcher.view", "launcher.action", "launcher.log"):
            self.assertIn(name, LUA_RUNTIME)

    def test_layout_engine_is_built(self):
        self.assertIn("PLUINodeView.m", CMAKE)
        self.assertIn("PLUILayoutEngine.m", CMAKE)

    def test_tree_validation_limits(self):
        # 节点数 ≤ 500、深度 ≤ 12、恰好一个 content 挂载点
        self.assertIn("PLUILayoutMaxNodes = 500", LAYOUT_ENGINE)
        self.assertIn("PLUILayoutMaxDepth = 12", LAYOUT_ENGINE)
        self.assertIn("contentCount != 1", LAYOUT_ENGINE)

    def test_bad_tree_falls_back_to_default(self):
        # 回退链最后一环：程序化默认三栏树
        self.assertIn("defaultTree", LAYOUT_ENGINE_H)
        self.assertIn('@"content"', LAYOUT_ENGINE)
        self.assertIn('@"kind"', LAYOUT_ENGINE)

    def test_weighted_stack_layout(self):
        # 权重分配在容器 layoutSubviews 中完成，不依赖 UIStackView
        self.assertIn("layoutSubviews", NODE_VIEW)
        self.assertIn("weightSum", NODE_VIEW)
        self.assertIn("weightedAvail", NODE_VIEW)

    def test_corner_mask_outer_propagation(self):
        # cornerMask=outer：父容器递归传递外沿边，只圆贴外的角
        self.assertIn("outerEdges", NODE_VIEW)
        self.assertIn("maskedCorners", NODE_VIEW)
        self.assertIn("kCALayerMinXMinYCorner", NODE_VIEW)

    def test_value_refs_resolved(self):
        for ref in ("$color:", "$image:", "$i18n:", "sf:"):
            self.assertIn(ref, NODE_VIEW)

    def test_responsive_and_visibility(self):
        # responsive.phone 覆盖 + visibleWhen 条件显隐
        self.assertIn('@"responsive"', NODE_VIEW)
        self.assertIn('@"visibleWhen"', NODE_VIEW)
        self.assertIn('@"phone"', NODE_VIEW)


class ShellContracts(unittest.TestCase):
    """M3e/M3f 双轨壳契约：新壳、动作白名单、SceneDelegate 杀开关、内置包。"""

    def test_shell_and_router_are_built(self):
        for source in ("PLUIShellViewController.m", "PLUIActionRouter.m"):
            self.assertIn(source, CMAKE)
            self.assertTrue((NATIVES / source).exists())

    def test_shell_takes_over_show_notifications(self):
        # 新壳完整接管 13 个 Show* 通知
        for name in ("ShowHomePage", "ShowDownloadPage", "ShowVersionManager",
                     "ShowProfileEditor", "ShowSettings", "ShowAIPage",
                     "ShowMultiplayer", "ShowZeroTier", "ShowModsManager",
                     "ShowShadersManager", "ShowModpackImport",
                     "ShowGameDirectory", "ShowAccountManager"):
            self.assertIn(f'@"{name}"', SHELL_VC)

    def test_shell_preserves_historical_fixes(self):
        # 从旧壳搬迁的三处历史修复必须保留
        self.assertIn("viewController == self.contentViewController", SHELL_VC)  # 同实例跳过
        self.assertIn("deactivateConstraints", SHELL_VC)  # 约束先 deactivate
        self.assertIn("UIViewAnimationOptionTransitionCrossDissolve", SHELL_VC)  # 单 transition

    def test_shell_reload_chain_falls_back(self):
        # 回退链：选中包 → 程序化默认树；引擎建根失败抛异常给 SceneDelegate 兜底
        self.assertIn("buildTreeWithError", SHELL_VC)
        self.assertIn("PLUIShellBuildFailed", SHELL_VC)
        self.assertIn("engineWithTree", SHELL_VC)

    def test_shell_wires_runtime_events(self):
        for wire in ("viewCommandHandler", "actionHandler", "dispatchEvent:@\"onReady\""):
            self.assertIn(wire, SHELL_VC)

    def test_action_router_is_whitelist_only(self):
        # 绝不动态方法调用：白名单映射 + 未知动作 log 后 no-op
        self.assertIn("PLUIActionNotificationMap", ACTION_ROUTER)
        self.assertNotIn("NSSelectorFromString", ACTION_ROUTER)
        self.assertIn("unknown action ignored", ACTION_ROUTER)

    def test_action_router_covers_open_actions(self):
        for action in ("open:home", "open:download", "open:versionManager",
                       "open:settings", "open:ai", "open:multiplayer",
                       "open:zeroTier", "open:more", "open:mods", "open:shaders",
                       "open:modpackImport", "open:gameDirectory",
                       "open:accountManager", "open:profileEditor"):
            self.assertIn(f'@"{action}"', ACTION_ROUTER)

    def test_scene_delegate_has_kill_switch(self):
        # 双轨开关：engine 壳构建异常时写回 legacy 换回旧壳
        self.assertIn("PLUIShellViewController", SCENE_DELEGATE)
        self.assertIn("@try", SCENE_DELEGATE)
        self.assertIn('setPrefObject(@"general.ui_shell", @"legacy")', SCENE_DELEGATE)
        self.assertIn("UIShellChanged", SCENE_DELEGATE)

    def test_ui_shell_defaults_to_legacy(self):
        self.assertIn('@"ui_shell": @"legacy"', PREFERENCES)

    def test_settings_offer_shell_and_pack_pickers(self):
        self.assertIn('@"key": @"ui_shell"', PREF_VC)
        self.assertIn('@"key": @"theme_pack"', PREF_VC)
        self.assertIn("applyThemeIdentifier", PREF_VC)

    def test_builtin_pack_is_colors_only(self):
        # pcl-classic 保持纯颜色包（schemaVersion 1）：新引擎默认显示欢迎界面，
        # 内置 main.lua 仅作为脚本模板保留（导入到 uipack/active 才作为 UI 包生效）。
        self.assertIn('"schemaVersion": 1', PACK_MANIFEST)
        self.assertTrue((PACK_ROOT / "colors.json").exists())

    def test_welcome_screen_when_no_pack(self):
        # 无导入包 → 欢迎界面（不渲染引擎）；引擎异常也在壳内回欢迎界面，不再冒泡闪退
        self.assertIn("buildWelcomeView", SHELL_VC)
        self.assertIn("@try", SHELL_VC)
        self.assertIn("@catch", SHELL_VC)

    def test_welcome_screen_components(self):
        # 左：app 图标 + 标题；右：导入 / 获取 /（切旧引擎 | 反馈）
        self.assertIn("PLUIWelcomeAppIcon", SHELL_VC)
        self.assertIn("uipack.welcome.title", SHELL_VC)
        self.assertIn("uipack.welcome.import", SHELL_VC)
        self.assertIn("uipack.welcome.get", SHELL_VC)
        self.assertIn("uipack.welcome.legacy", SHELL_VC)
        self.assertIn("uipack.welcome.feedback", SHELL_VC)

    def test_welcome_actions(self):
        # 切旧引擎：写偏好 + UIShellChanged；反馈：A-pear issues；导入：文档选择器
        self.assertIn('setPrefObject(@"general.ui_shell", @"legacy")', SHELL_VC)
        self.assertIn("github.com/twoyears666/A-pear/issues", SHELL_VC)
        self.assertIn("UIDocumentPickerViewController", SHELL_VC)
        self.assertIn("importPackFromURL", SHELL_VC)

    def test_import_pack_contract(self):
        # 导入目标 uipack/active：staging 校验 → 原子替换；zip 先拷贝到 tmp 再解压
        self.assertIn("importPackFromURL", UI_PACK_HEADER)
        self.assertIn('stringByAppendingPathComponent:@"uipack/active"', UI_PACK_MANAGER)
        self.assertIn("active-staging", UI_PACK_MANAGER)
        self.assertIn("hoistWrappedRootDirectoryIfNeeded", UI_PACK_MANAGER)
        self.assertIn("validateImportedPackAtRoot", UI_PACK_MANAGER)
        self.assertIn("startAccessingSecurityScopedResource", UI_PACK_MANAGER)

    def test_imported_pack_takes_priority(self):
        # reload 优先级：导入包（uipack/active，不校验目录名）→ theme_pack 指向的 UI 包
        self.assertIn("loadPackAtRoot", UI_PACK_MANAGER)
        self.assertIn("expectedIdentifier:nil", UI_PACK_MANAGER)

    def test_builtin_pack_lua_contract(self):
        # 入口脚本：describe + build(ui)，恰好一个 content 挂载点，含事件函数
        self.assertIn("function describe()", MAIN_LUA)
        self.assertIn("function build(ui)", MAIN_LUA)
        self.assertEqual(MAIN_LUA.count("ui.content {"), 1)
        for handler in ("function onReady()", "function onAccountChange("):
            self.assertIn(handler, MAIN_LUA)
        # 脚本限额 256KB
        self.assertLessEqual(len(MAIN_LUA.encode("utf-8")), 256 * 1024)

    def test_builtin_pack_uses_only_whitelisted_actions(self):
        # main.lua 中引用的 action 必须全部在路由器白名单内
        import re
        actions = set(re.findall(r'action = "([^"]+)"', MAIN_LUA))
        self.assertTrue(actions, "main.lua should reference at least one action")
        for action in actions:
            self.assertIn(f'@"{action}"', ACTION_ROUTER, f"action {action} not whitelisted")


if __name__ == "__main__":
    unittest.main()


class UINodeLayoutContracts(unittest.TestCase):
    """节点布局引擎契约：文字按钮铺满节点、嵌套容器可测量（PCL2 包前置修复）。"""

    def test_button_fills_node_bounds(self):
        # 此前按钮按 min(宽,高) 居中成正方形，宽文字按钮（启动按钮）文字被裁切
        self.assertIn("if (self.button) self.button.frame = self.bounds;", NODE_VIEW)
        self.assertNotIn("CGFloat side = MIN(self.bounds.size.width, self.bounds.size.height);", NODE_VIEW)

    def test_leaf_content_sized_before_stack_early_return(self):
        # 叶子内容布局必须在栈早退之前：button/text/image 均为叶子节点（非 stack），
        # 早退后其 UIKit 子视图永远停留在 CGRectZero —— 按钮与文字整体不可见，
        # 只剩容器背景色（真机 PCL2 包首渲暴露：顶栏/左栏背景在，导航与主题按钮全缺失）
        early_return = NODE_VIEW.index("if (!self.horizontalStack && !self.verticalStack) return;")
        button_fill = NODE_VIEW.index("if (self.button) self.button.frame = self.bounds;")
        text_fill = NODE_VIEW.index("if (self.textLabel) self.textLabel.frame = self.bounds;")
        image_fill = NODE_VIEW.index("if (self.contentImageView) self.contentImageView.frame = self.bounds;")
        self.assertLess(button_fill, early_return, "button.frame 赋值必须位于栈早退之前")
        self.assertLess(text_fill, early_return, "textLabel.frame 赋值必须位于栈早退之前")
        self.assertLess(image_fill, early_return, "contentImageView.frame 赋值必须位于栈早退之前")

    def test_nested_container_autosize(self):
        # 嵌套 row/column 在父栈中必须能测出聚合首选尺寸，否则高度塌为 0
        self.assertIn("if (self.horizontalStack || self.verticalStack) {", NODE_VIEW)
        self.assertIn("main += self.spacing * (CGFloat)(count - 1);", NODE_VIEW)

    def test_image_intrinsic_query_guard(self):
        # 固有尺寸查询（双向 CGFLOAT_MAX）时直接返回原始尺寸，避免 aspect-fit 比例溢出
        self.assertIn("if (size.width >= CGFLOAT_MAX && size.height >= CGFLOAT_MAX) return s;", NODE_VIEW)

    def test_cross_axis_defaults_to_stretch(self):
        # 交叉轴缺省必须 stretch（flexbox 语义）：content 节点 sizeThatFits 为零尺寸、
        # 权重子节点内容测量贡献 0，缺省按内容对齐会让整链容器交叉轴逐级坍缩
        # （真机复现：PCL2 包左栏挤成窄条、内容区高 0 全黑；两台设备稳定复现）
        self.assertIn(
            "if (![value isKindOfClass:NSString.class]) return PLUICrossAlignStretch;",
            NODE_VIEW)

    def test_fixed_cross_size_wins_over_stretch(self):
        # flex 语义：固定交叉尺寸优先于 stretch——固定高药丸在默认 stretch 容器内
        # 保持原高，不被拉成椭圆。顺序：百分比 > 固定 > stretch > 内容对齐
        self.assertIn("} else if (!isnan(fixedCross)) {", NODE_VIEW)
        self.assertIn("} else if (_crossAlign == PLUICrossAlignStretch) {", NODE_VIEW)
        self.assertLess(
            NODE_VIEW.index("} else if (!isnan(fixedCross)) {"),
            NODE_VIEW.index("} else if (_crossAlign == PLUICrossAlignStretch) {"),
            "固定交叉尺寸分支必须先于 stretch 分支")

    def test_content_view_frame_prealigned_before_constraints(self):
        # 页面 VC view 添加前必须按内容区 bounds 预对齐：
        # 约束生效前一帧按默认 frame (0,0) 渲染，真机上表现为「界面从左上角一闪而过」
        self.assertIn("viewController.view.frame = self.contentNode.bounds;", SHELL_VC)


class UIPackCrashRegressionContracts(unittest.TestCase):
    """启动闪退回归：activePack copy 崩溃 + dispatch_once 内异常不可捕获（Amethyst 5.0.0 实机日志）。"""

    def test_active_pack_property_is_strong(self):
        # PLUIPack 未实现 NSCopying：copy 修饰的 activePack 在 reload 赋值时
        # 调 copyWithZone: 必崩（默认主题 pcl-classic 即 schemaVersion 2，启动必触发）
        self.assertIn("@property (nonatomic, nullable, strong, readwrite) PLUIPack *activePack", UI_PACK_MANAGER)
        self.assertNotIn("copy, readwrite) PLUIPack *activePack", UI_PACK_MANAGER)

    def test_shared_manager_init_has_no_side_effects(self):
        # dispatch_once 块内抛出的 ObjC 异常无法被调用方 @try 捕获，
        # 会击穿欢迎界面兜底直接闪退：单例初始化只允许纯 new，reload 由壳显式调用
        self.assertIn("manager = [PLUIPackManager new];", UI_PACK_MANAGER)
        self.assertNotIn("[manager reload]", UI_PACK_MANAGER)
        # 壳在 @try 内先 reload 再取 activePack（异常 → 欢迎界面兜底）
        self.assertIn("[PLUIPackManager.sharedManager reload];", SHELL_VC)


class UIThreeIssueFixContracts(unittest.TestCase):
    """v1.2.0 三修复契约：黑边（透明缝/窗口黑底）、页面导航、背景全窗生效。"""

    def test_shell_backdrop_overrides_black_window_background(self):
        # 问题 1 根因：壳视图透明化后，Lua 树缝隙/半透明区透出窗口底色，
        # 而 general.ui_theme 默认 dark → systemBackgroundColor=黑。
        # 契约：无壁纸铺不透明主题底色（background 令牌），有壁纸保持透明透出壁纸
        self.assertIn("refreshShellBackdrop", SHELL_VC)
        self.assertIn("hasBackground", SHELL_VC)
        self.assertIn('colorForToken:@"background"', SHELL_VC)
        self.assertIn("[UIColor clearColor]", SHELL_VC)
        # 背景设置/清除时同步刷新壳底色（切换壁纸不留旧底色）
        self.assertIn("- (void)backgroundChanged", SHELL_VC)

    def test_fallback_tree_has_no_spacing_gaps(self):
        # 兜底树根行同样不留缺省 8pt 透明缝
        self.assertIn('@"id": @"shell"', LAYOUT_ENGINE)
        self.assertIn('@"spacing": @0', LAYOUT_ENGINE)

    def test_hidden_nodes_collapse_in_stack_layout(self):
        # 问题 2（PCL2 导航行为）：非启动页收起左栏 → 内容区全幅。
        # 契约：hidden 子节点不占主轴/spacing，setVisible 触发父容器重排
        self.assertIn("visibleChildren", NODE_VIEW)
        self.assertIn("sub.hidden) continue", NODE_VIEW)
        self.assertIn("- (void)updateVisible:(BOOL)visible", NODE_VIEW)
        self.assertIn("[self.superview setNeedsLayout]", NODE_VIEW)
        # 壳的 setVisible 命令必须走 updateVisible（触发重排），不得直接置 hidden
        self.assertIn("[node updateVisible:[argument boolValue]]", SHELL_VC)

    def test_multiplayer_routes_to_real_page(self):
        # 问题 2：open:multiplayer 不再弹「不可用」，路由到真实联机页（FCL 风格房间列表）
        self.assertIn('@"open:multiplayer": @"ShowMultiplayer"', ACTION_ROUTER)
        self.assertIn("MultiplayerViewController", SHELL_VC)
        self.assertIn("MultiplayerVCModeLauncher", SHELL_VC)
        # 降级弹窗已删除（崩溃根因 NSCopying 已在 PR #5 修复）
        self.assertNotIn("showMultiplayerDisabledAlert", ACTION_ROUTER)
        self.assertNotIn("showMultiplayerDisabledAlert", SHELL_VC)

    def test_more_page_exists_and_wires_secondary_entries(self):
        # 问题 2：更多页聚合二级入口（资源管理/个性化/关于与日志），不再直接跳 Mod 管理
        self.assertIn("open:more", ACTION_ROUTER)
        self.assertIn("- (void)showMorePage", SHELL_VC)
        self.assertIn("PLUIMoreViewController", SHELL_VC)
        self.assertIn("PLUIMoreViewController.m", CMAKE)
        self.assertTrue((NATIVES / "PLUIMoreViewController.h").exists())
        more_vc = (NATIVES / "PLUIMoreViewController.m").read_text()
        # 二级入口复用既有通知/VC：Mod/光影/整合包/世界管理 + 壁纸设置
        for entry in ("ShowModsManager", "ShowShadersManager", "ShowModpackImport",
                      "WorldsManagerViewController", "BackgroundSettingsViewController"):
            self.assertIn(entry, more_vc)
        # 关于与日志：版本信息 / 开源仓库 / 反馈 / 日志查看
        self.assertIn("CFBundleShortVersionString", more_vc)
        self.assertIn("github.com/twoyears666/A-pear", more_vc)
        self.assertIn("logs/latest.log", more_vc)

    def test_page_identifiers_cover_five_tabs(self):
        # 五页签对应页面标识齐全（页签选中态/左栏收起跟随真实内容页）
        for cls, page in (("LauncherNewsViewController", "home"),
                          ("DownloadViewController", "download"),
                          ("MultiplayerViewController", "multiplayer"),
                          ("LauncherPreferencesViewController", "settings"),
                          ("PLUIMoreViewController", "more")):
            self.assertIn(f'@"{cls}": @"{page}"', SHELL_VC)

    def test_background_changes_apply_to_content_pages_live(self):
        # 问题 3：背景透明度/毛玻璃滑条实时生效 —— 效果变化通知同步重应用
        # 到当前内容页（含导航栈），不必重进页面
        self.assertIn("BackgroundUIEffectChanged", SHELL_VC)
        self.assertIn("makeViewControllerTransparent", SHELL_VC)

    def test_more_page_i18n_keys_exist(self):
        # 更多页文案走 uipack.more.* 令牌（6 语言随 welcome 套件）
        zh = (NATIVES / "resources/zh-Hans.lproj/Localizable.strings").read_text()
        en = (NATIVES / "resources/en.lproj/Localizable.strings").read_text()
        for key in ("uipack.more.title", "uipack.more.wallpaper", "uipack.more.logs"):
            self.assertIn(f'"{key}"', zh)
            self.assertIn(f'"{key}"', en)
