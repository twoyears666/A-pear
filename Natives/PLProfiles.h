#import <Foundation/Foundation.h>

// 版本隔离模式（对齐 PCL2 三档）
// none = 不隔离（游戏数据在实例主目录）
// mod  = 仅 Mod 隔离（游戏数据共享，只有 mods 指向 versions/<版本>/mods）
// full = 完全隔离（游戏数据全部在 versions/<版本>）
extern NSString * const PLIsolationNone;
extern NSString * const PLIsolationMod;
extern NSString * const PLIsolationFull;

@interface PLProfiles : NSObject

@property(nonatomic) NSString *profilePath;
@property(nonatomic) NSMutableDictionary<NSString *, NSMutableDictionary<NSString *, NSMutableDictionary<NSString *, NSString *> *> *> *profileDict;

+ (PLProfiles *)current;
+ (void)updateCurrent;

+ (id)profile:(NSMutableDictionary *)profile resolveKey:(id)key;
+ (NSString *)resolveKeyForCurrentProfile:(id)key;

/// preferredName 非空时仅接受真实存在的档案，否则返回 nil；
/// preferredName 为空时依次回退到当前选中档案和首个可用档案。
+ (nullable NSString *)effectiveProfileNameForPreferredName:(nullable NSString *)preferredName;

/// 将档案 gameDir 统一解析为绝对路径（支持 "."、相对隔离目录和绝对目录）；
/// 版本隔离感知：完全隔离时返回 versions/<版本>；显式指定不存在的档案时返回 nil。
+ (nullable NSString *)resolvedGameDirectoryForProfileName:(nullable NSString *)profileName;

/// 将档案 mods 目录解析为绝对路径（版本隔离感知：仅 Mod 隔离指向 versions/<版本>/mods）；
/// 显式指定不存在的档案时返回 nil。
+ (nullable NSString *)resolvedModsDirectoryForProfileName:(nullable NSString *)profileName;

- (id)initWithCurrentInstance;
- (NSMutableDictionary<NSString *, NSMutableDictionary<NSString *, NSString *> *> *)profiles;

- (NSMutableDictionary<NSString *, NSString *> *)selectedProfile;
- (NSString *)selectedProfileName;
- (void)setSelectedProfileName:(NSString *)name;
- (void)save;

// 新增：修复构建错误 - 添加缺失的方法声明
- (void)saveProfile:(NSMutableDictionary<NSString *, NSString *> *)profile withName:(NSString *)name;

#pragma mark - 版本隔离

/// 归一化隔离模式：显式 isolation 优先；旧数据里 gameDir 为自定义路径时视为 full；否则 none。
+ (NSString *)isolationModeForProfile:(NSDictionary *)profile;

/// 写入隔离模式。customGameDir 非空时用于"自定义完全隔离目录"，否则走自动 versions/<版本>。
+ (void)setIsolationMode:(NSString *)mode customGameDir:(nullable NSString *)customGameDir forProfileName:(NSString *)name;

/// 游戏数据目录（相对 POJAV_GAME_DIR）。none/mod 为 "."；full 为自定义路径或 versions/<版本>。
+ (NSString *)effectiveGameDirForProfile:(NSDictionary *)profile;

/// mods 目录（相对 POJAV_GAME_DIR）。mod 为 versions/<版本>/mods；其余为 <有效游戏目录>/mods。
+ (NSString *)effectiveModsDirForProfile:(NSDictionary *)profile;

/// 上面两个的相对路径 → 绝对路径（相对 POJAV_GAME_DIR 解析）。
+ (NSString *)absoluteGameDirForProfile:(NSDictionary *)profile;
+ (NSString *)absoluteModsDirForProfile:(NSDictionary *)profile;

/// 按 PCL2 结构创建隔离目录（mods/saves/config/...）。仅建目录，不迁移、不动符号链接。
+ (void)ensureIsolationDirectoriesForProfile:(NSDictionary *)profile;

/// 启动前对齐共享 mods 目录：mod 隔离时把 <游戏主目录>/mods 指向版本 mods，其余模式恢复为真实目录。
+ (void)alignSharedModsDirectoryForProfile:(NSDictionary *)profile;

/// 老数据自动迁移：完全隔离时把共享主目录里已存在的标准子目录内容搬进版本目录，
/// 避免"开隔离后存档/Mod 消失"。不覆盖目标同名项、不搬迁 versions/libraries/assets 等启动器资源；
/// 仅移动标准子目录（见 PLIsolationStandardSubdirectories），幂等，可安全重复调用。
+ (void)migrateLegacyDataForProfile:(NSDictionary *)profile;

/// 新建 profile 的默认隔离：无显式 isolation 且无自定义 gameDir 时设为完全隔离。
+ (void)applyDefaultIsolationForNewProfile:(NSMutableDictionary *)profile;

#pragma mark - 服务器地址（FCL 风格：启动后自动加入服务器，留空则不加入）
- (NSString *)serverIpForCurrentProfile;
- (NSString *)serverIpForProfile:(NSString *)profileName;
- (void)setServerIp:(NSString *)serverIp forProfile:(NSString *)profileName;

@end
