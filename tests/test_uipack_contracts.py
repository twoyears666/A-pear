from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
NATIVES = ROOT / "Natives"
CMAKE = (NATIVES / "CMakeLists.txt").read_text()
UI_PACK_MANAGER = (NATIVES / "PLUIPackManager.m").read_text()
UI_PACK_HEADER = (NATIVES / "PLUIPackManager.h").read_text()
THEME_MANAGER = (NATIVES / "PLThemeManager.m").read_text()
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


if __name__ == "__main__":
    unittest.main()
