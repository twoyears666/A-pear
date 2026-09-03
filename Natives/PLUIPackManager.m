#import "PLUIPackManager.h"
#import "PLThemeManager.h"
#import "LauncherPreferences.h"

// UI 包 = schemaVersion 2 的主题包。纯颜色包（1）不进入本管理器。
static NSInteger const PLUIPackSchemaVersion = 2;
// 脚本总量限额（与沙箱预算一致），超限直接判坏包走回退。
static NSUInteger const PLUIPackMaxScriptBytes = 256 * 1024;

@interface PLUIPackManager ()
@property (nonatomic, nullable, copy, readwrite) PLUIPack *activePack;
@end

@implementation PLUIPack

- (instancetype)initWithIdentifier:(NSString *)identifier
                        displayName:(NSString *)displayName
                             author:(NSString *)author
                           rootPath:(NSString *)rootPath
                          entryPath:(NSString *)entryPath {
    self = [super init];
    if (self) {
        _identifier = [identifier copy];
        _displayName = [displayName copy];
        _author = [author copy];
        _rootPath = [rootPath copy];
        _entryPath = [entryPath copy];
    }
    return self;
}

@end

@implementation PLUIPackManager

+ (PLUIPackManager *)sharedManager {
    static PLUIPackManager *manager;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        manager = [PLUIPackManager new];
        [manager reload];
    });
    return manager;
}

- (void)reload {
    NSString *selected = getPrefObject(@"general.theme_pack");
    self.activePack = [self loadPackWithIdentifier:selected];
}

- (NSArray<PLUIPack *> *)availableUIPacks {
    NSMutableArray<PLUIPack *> *packs = [NSMutableArray array];
    for (NSDictionary *theme in [PLThemeManager.sharedManager availableThemes]) {
        NSString *identifier = theme[@"id"];
        if (![theme[@"schemaVersion"] isKindOfClass:NSNumber.class]) continue;
        if ([theme[@"schemaVersion"] integerValue] != PLUIPackSchemaVersion) continue;
        PLUIPack *pack = [self loadPackWithIdentifier:identifier];
        if (pack) [packs addObject:pack];
    }
    return [packs sortedArrayUsingComparator:^NSComparisonResult(PLUIPack *a, PLUIPack *b) {
        return [a.displayName localizedCaseInsensitiveCompare:b.displayName];
    }];
}

- (nullable NSString *)mainLuaSourceForPack:(PLUIPack *)pack {
    if (!pack.entryPath) return nil;
    NSData *data = [NSData dataWithContentsOfFile:pack.entryPath];
    if (!data || data.length == 0 || data.length > PLUIPackMaxScriptBytes) return nil;
    NSString *source = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return source.length > 0 ? source : nil;
}

#pragma mark - 加载与校验

- (nullable NSDictionary *)JSONDictionaryAtPath:(NSString *)path {
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) return nil;
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [object isKindOfClass:NSDictionary.class] ? object : nil;
}

- (nullable PLUIPack *)loadPackWithIdentifier:(NSString *)identifier {
    if (![identifier isKindOfClass:NSString.class]) return nil;
    // rootForIdentifier 内部完成安全标识符校验与 外部覆盖内置 的解析。
    NSString *root = [PLThemeManager.sharedManager rootForIdentifier:identifier];
    if (!root) return nil;

    NSDictionary *manifest = [self JSONDictionaryAtPath:[root stringByAppendingPathComponent:@"manifest.json"]];
    if (!manifest) return nil;
    NSInteger version = [manifest[@"schemaVersion"] isKindOfClass:NSNumber.class]
        ? [manifest[@"schemaVersion"] integerValue] : 0;
    BOOL idMatches = [manifest[@"id"] isKindOfClass:NSString.class] &&
                     [manifest[@"id"] isEqualToString:identifier];
    if (version != PLUIPackSchemaVersion || !idMatches) {
        return nil;
    }

    NSString *entryPath = [self validatedEntryPathInRoot:root manifest:manifest];
    if (!entryPath) {
        NSLog(@"[PLUIPackManager] pack %@ rejected: missing or invalid entry script", identifier);
        return nil;
    }

    return [[PLUIPack alloc] initWithIdentifier:identifier
                                     displayName:[manifest[@"name"] isKindOfClass:NSString.class] ? manifest[@"name"] : identifier
                                          author:[manifest[@"author"] isKindOfClass:NSString.class] ? manifest[@"author"] : @""
                                        rootPath:root
                                       entryPath:entryPath];
}

/// 校验入口脚本路径与大小。只允许包根下的单段文件名（默认 main.lua），
/// 禁止子目录、绝对路径与 ".."，从源头挡住目录穿越。
- (nullable NSString *)validatedEntryPathInRoot:(NSString *)root manifest:(NSDictionary *)manifest {
    NSString *entry = [manifest[@"entry"] isKindOfClass:NSString.class] ? manifest[@"entry"] : @"main.lua";
    if (entry.length == 0 || entry.isAbsolutePath) return nil;
    if (![entry isEqualToString:entry.lastPathComponent]) return nil;
    if ([entry hasPrefix:@"."] || [entry containsString:@".."] || [entry containsString:@"/"]) return nil;

    NSString *path = [root stringByAppendingPathComponent:entry];
    NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
    unsigned long long size = [attrs[NSFileSize] unsignedLongLongValue];
    if (size == 0 || size > PLUIPackMaxScriptBytes) return nil;
    return path;
}

@end
