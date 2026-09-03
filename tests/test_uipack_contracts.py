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
LINIT = (NATIVES / "external/lua/linit.c").read_text()
LUA_DIR = NATIVES / "external/lua"


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


if __name__ == "__main__":
    unittest.main()
