#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 已通过校验的 UI 材质包（schemaVersion 2 主题包）。
/// 纯颜色包（schemaVersion 1）不会产生 PLUIPack 实例。
@interface PLUIPack : NSObject

@property (nonatomic, copy, readonly) NSString *identifier;
@property (nonatomic, copy, readonly) NSString *displayName;
@property (nonatomic, copy, readonly) NSString *author;
/// 入口脚本（main.lua）的绝对路径。
@property (nonatomic, copy, readonly) NSString *entryPath;
/// 包根目录的绝对路径（images/ 等资源的定位基准）。
@property (nonatomic, copy, readonly) NSString *rootPath;

- (instancetype)initWithIdentifier:(NSString *)identifier
                        displayName:(NSString *)displayName
                             author:(NSString *)author
                           rootPath:(NSString *)rootPath
                          entryPath:(NSString *)entryPath;

@end

/// UI 材质包发现/校验/加载。
///
/// UI 包与主题包共用 themes/<identifier>/ 目录与 general.theme_pack 偏好：
/// schemaVersion 2 且含合法 main.lua 的包视为 UI 包；其余（纯颜色包）activePack 为 nil，
/// 由布局引擎使用内置默认树，仅颜色令牌生效。
@interface PLUIPackManager : NSObject

@property (class, nonatomic, readonly) PLUIPackManager *sharedManager;

/// 当前选中包。纯颜色包 / 未安装 / 校验失败时为 nil（合法状态，非错误）。
@property (nonatomic, nullable, readonly) PLUIPack *activePack;

/// 重新读取 general.theme_pack 并尝试按 UI 包加载。
/// 主题切换后由调用方（壳控制器）调用，保证 activePack 与 PLThemeManager 同步。
- (void)reload;

/// 所有可用的 UI 材质包（schemaVersion 2），按显示名排序。
- (NSArray<PLUIPack *> *)availableUIPacks;

/// 读取包的入口脚本源码（UTF-8）。文件缺失、超限（256KB）或解码失败返回 nil。
- (nullable NSString *)mainLuaSourceForPack:(PLUIPack *)pack;

@end

NS_ASSUME_NONNULL_END
