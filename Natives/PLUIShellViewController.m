#import "PLUIShellViewController.h"
#import "PLUIPackManager.h"
#import "PLLuaRuntime.h"
#import "PLUILayoutEngine.h"
#import "PLUINodeView.h"
#import "PLUIActionRouter.h"
#import "PLThemeManager.h"
#import "BackgroundManager.h"
#import "PLProfiles.h"
#import "LauncherPreferences.h"
#import "utils.h"
// 内容区功能页
#import "LauncherNewsViewController.h"
#import "DownloadViewController.h"
#import "VersionManagerViewController.h"
#import "ProfileSettingsViewController.h"
#import "LauncherPreferencesViewController.h"
#import "ModsManagerViewController.h"
#import "ModService.h"
#import "ShaderService.h"
#import "ModItem.h"
#import "ShadersManagerViewController.h"
#import "ModpackImportViewController.h"
#import "LauncherPrefGameDirViewController.h"
#import "AccountListViewController.h"
#import "MultiplayerViewController.h"
#import "PLUIMoreViewController.h"
#import "MultiplayerManager.h"
#import "AI/AIViewController.h"
#import "AI/AiSessionStore.h"
#import "authenticator/BaseAuthenticator.h"

@interface PLUIShellViewController () <UINavigationControllerDelegate, UIDocumentPickerDelegate>
@property (nonatomic, strong) PLUILayoutEngine *engine;
@property (nonatomic, strong) PLLuaRuntime *runtime;
@property (nonatomic, strong) PLUINodeView *contentNode;
@property (nonatomic, strong) UIViewController *contentViewController;
@property (nonatomic, strong) NSArray<NSLayoutConstraint *> *currentContentConstraints;
@property (nonatomic, assign) BOOL isShowingProfileEditor;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *localVersionList;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *remoteVersionList;
/// 资源中心（Mods）缓存：ModService 扫描结果的 Lua 可渲染结构；refresh 后派发 onModsUpdated。
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *modsCache;
/// 光影包（Shaders）缓存：ShaderService 扫描结果的 Lua 可渲染结构；refresh 后派发 onShadersUpdated。
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *shadersCache;
/// 当前内容页标识（home/download/settings/...），变化时向 Lua 包派发 onPageChange
@property (nonatomic, copy, nullable) NSString *currentLuaPage;
/// 首个布局完成是否已向 Lua 派发 onLayout（游标等依赖真实 frame 的定位需在布局后执行）。
@property (nonatomic, assign) BOOL didDispatchOnLayout;
@end

@implementation PLUIShellViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
    // 先初始化版本/账号数据源：buildShell 阶段 Lua 页会通过 launcher.service
    // 拉取版本列表，必须保证列表在 buildTree 前已就绪（否则首次构建为空）。
    [self initializeVersionLists];
    [self buildShell];
    [self registerNotifications];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

// 首个真实布局完成后通知 Lua（onLayout）：游标等依赖实际 frame 的定位需在布局后执行，
// onReady 在 buildShell 期间已派发，彼时 frame 尚未就绪，故在此补发一次。
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if (self.didDispatchOnLayout) return;
    if (!self.runtime) return;
    self.didDispatchOnLayout = YES;
    [self.runtime dispatchEvent:@"onLayout" arguments:@[]];
}

#pragma mark - 材质包加载与渲染

- (void)buildShell {
    for (UIView *sub in [self.view.subviews copy]) [sub removeFromSuperview];
    self.contentNode = nil;
    self.engine = nil;
    self.runtime = nil;
    self.currentLuaPage = nil; // 重建后重新派发 onPageChange（Lua 状态已随新 VM 重置）

    // 无激活包（未导入且未选中 UI 包）→ 欢迎界面：不渲染引擎，
    // 提供 导入 UI 包 / 获取 UI 包 / 切回旧引擎 / 问题反馈，作为闪退的兜底。
    @try {
        [PLUIPackManager.sharedManager reload];
        PLUIPack *pack = PLUIPackManager.sharedManager.activePack;
        if (!pack) {
            [self buildWelcomeView];
            return;
        }

        // 主题数据源切到激活 UI 包：$color: 令牌严格按包 colors.json 解析（黑底根治）。
        [PLThemeManager.sharedManager loadColorsFromRoot:pack.rootPath];

        NSDictionary *tree = nil;
        NSString *source = [PLUIPackManager.sharedManager mainLuaSourceForPack:pack];
        if (source) {
            NSError *error = nil;
            PLLuaRuntime *runtime = [[PLLuaRuntime alloc] initWithPack:pack scriptSource:source error:&error];
            if (runtime) {
                // 首块状态在 buildTree 前注入：让 build() 能读取 launcher.state.settings
                // 等数据驱动清单，动态生成设置页条目（启动器新增条目无需改 UI 包）。
                [runtime setState:@{ @"settings": [self launcherSettingsList] }];
                // build() 阶段就会调用 launcher.service(version/account) 拉取列表，
                // 因此服务分发必须在 buildTree 之前接好（否则首次构建列表为空）。
                __weak typeof(self) weakSelf = self;
                runtime.serviceHandler = ^NSDictionary *(NSString *service, NSString *method, NSDictionary *args) {
                    __strong typeof(weakSelf) strongSelf = weakSelf;
                    return [strongSelf handleLuaService:service method:method args:args];
                };
                tree = [runtime buildTreeWithError:&error];
                if (tree) self.runtime = runtime;
            }
        }

        PLUILayoutEngine *engine = [PLUILayoutEngine engineWithTree:tree];
        PLUINodeView *root = [engine buildRootViewInHost:self.view traitCollection:self.traitCollection];
        if (!root) {
            [NSException raise:@"PLUIShellBuildFailed" format:@"layout engine failed to build root view"];
        }
        self.engine = engine;

        [self.engine enumerateNodes:^(PLUINodeView *node) {
            if (node.isContentArea) self.contentNode = node;
        }];
        [self wireActions];
        [self wireRuntime];
        [self refreshShellBackdrop];
        [self showInitialPage];
        [self refreshStateAndNotifyReady];
    } @catch (NSException *exception) {
        // 引擎/脚本异常：壳内消化，回欢迎界面（仍可切回旧引擎），不再冒泡闪退。
        NSLog(@"[PLUIShell] engine build failed: %@ — %@", exception.name, exception.reason);
        for (UIView *sub in [self.view.subviews copy]) [sub removeFromSuperview];
        self.contentNode = nil;
        self.engine = nil;
        self.runtime = nil;
        [self buildWelcomeView];
    }
}

- (void)wireActions {
    __weak typeof(self) weakSelf = self;
    [self.engine enumerateNodes:^(PLUINodeView *node) {
        // 所有可点击节点都挂 tapHandler：带 action 的按钮/容器走原生命令，
        // 不带 action 的控件（分段标签/主按钮等）仍派发 onClick 供 Lua 处理选中态，
        // 否则这些控件点击无任何响应。
        [node attachTapGestureIfNeeded];
        node.tapHandler = ^(PLUINodeView *tapped) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            if (tapped.action.length > 0) {
                [PLUIActionRouter.sharedRouter performAction:tapped.action
                                         fromViewController:strongSelf];
            }
            [strongSelf.runtime dispatchEvent:@"onClick" arguments:@[tapped.nodeId ?: @""]];
        };
    }];
}

- (void)wireRuntime {
    if (!self.runtime) return;
    __weak typeof(self) weakSelf = self;
    self.runtime.actionHandler = ^(NSString *action) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        [PLUIActionRouter.sharedRouter performAction:action
                                 fromViewController:strongSelf];
    };
    self.runtime.viewCommandHandler = ^BOOL(NSString *viewId, NSString *command, id argument) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return NO;
        PLUINodeView *node = [strongSelf.engine viewForId:viewId];
        if (!node) return NO;
        if ([command isEqualToString:@"setText"]) {
            [node updateText:[argument isKindOfClass:NSString.class] ? argument : [argument description]];
        } else if ([command isEqualToString:@"setTextColor"]) {
            [node updateTextColorSpec:[argument isKindOfClass:NSString.class] ? argument : nil];
        } else if ([command isEqualToString:@"setImage"]) {
            [node updateImageSpec:[argument isKindOfClass:NSString.class] ? argument : nil];
        } else if ([command isEqualToString:@"setVisible"]) {
            // updateVisible 会触发父容器重排：隐藏节点坍缩，其余子节点重新瓜分空间
            [node updateVisible:[argument boolValue]];
        } else if ([command isEqualToString:@"fade"]) {
            // 页面淡入淡出切换（alpha 过渡；隐藏仍在栈布局中坍缩）
            [node fadeToVisible:[argument boolValue] duration:0.18];
        } else if ([command isEqualToString:@"setEnabled"]) {
            [node updateEnabled:[argument boolValue]];
        } else if ([command isEqualToString:@"setStyle"]) {
            // 样式热更新（PCL2 顶栏页签选中态药丸）：background/tint/border/corner
            [node updateStyleSpec:[argument isKindOfClass:NSDictionary.class] ? argument : nil];
        } else if ([command isEqualToString:@"setFrame"]) {
            // 绝对定位覆盖层（页签滑动高亮游标）：argument = { rect, animated }
            NSDictionary *payload = (NSDictionary *)argument;
            NSDictionary *rect = payload[@"rect"];
            BOOL animated = [payload[@"animated"] boolValue];
            if ([rect isKindOfClass:NSDictionary.class]) {
                [node updateFrameRect:rect animated:animated];
            }
        }
        return YES;
    };
    self.runtime.viewFrameHandler = ^NSDictionary *(NSString *viewId) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        PLUINodeView *node = [strongSelf.engine viewForId:viewId];
        return node ? [node currentFrameRect] : nil;
    };
    self.runtime.viewTextHandler = ^NSString *(NSString *viewId) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        return [strongSelf.engine viewForId:viewId].currentText;
    };
// launcher.service：由宿主统一分发到各服务（settings/version/account/system/download）。
    self.runtime.serviceHandler = ^NSDictionary *(NSString *service, NSString *method, NSDictionary *args) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        return [strongSelf handleLuaService:service method:method args:args];
    };
    // launcher.emit：广播给宿主，供其他监听方（壳/游戏窗口等）响应。
    self.runtime.emitHandler = ^(NSString *event, id payload) {
        [[NSNotificationCenter defaultCenter]
            postNotificationName:@"PLUIServiceEmit"
                          object:event
                        userInfo:(payload ? @{@"payload": payload} : nil)];
    };
    // launcher.getState：拉取当前完整状态快照。
    self.runtime.stateHandler = ^NSDictionary *(void) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        return [strongSelf currentState];
    };
}

#pragma mark - WS-B 服务分发（launcher.service 落点，宿主拥有数据/能力）

- (NSDictionary *)handleLuaService:(NSString *)service
                            method:(NSString *)method
                              args:(NSDictionary *)args {
    // 未知服务/方法：返回 ok=NO（干净降级，不抛 Lua 错误）。
    if ([service isEqualToString:@"settings"] && [method isEqualToString:@"list"]) {
        return @{ @"ok": @YES, @"count": @([self launcherSettingsList].count),
                  @"items": [self launcherSettingsList] };
    }
    if ([service isEqualToString:@"version"] && [method isEqualToString:@"current"]) {
        return @{ @"ok": @YES, @"name": PLProfiles.current.selectedProfileName ?: @"" };
    }
    if ([service isEqualToString:@"version"] && [method isEqualToString:@"list"]) {
        // 本地已安装版本（结构式：id + 类型占位，动态数据由磁盘填充）
        NSMutableArray *items = [NSMutableArray new];
        for (NSDictionary *v in self.localVersionList) {
            BOOL selected = [v[@"id"] isEqualToString:PLProfiles.current.selectedProfileName];
            [items addObject:@{ @"id": v[@"id"] ?: @"", @"type": v[@"type"] ?: @"custom",
                                @"selected": @(selected) }];
        }
        return @{ @"ok": @YES, @"items": items };
    }
    if ([service isEqualToString:@"account"] && [method isEqualToString:@"current"]) {
        BaseAuthenticator *auth = BaseAuthenticator.current;
        NSString *name = auth.authData[@"username"];
        return name ? @{ @"ok": @YES, @"name": name } : @{ @"ok": @NO };
    }
    if ([service isEqualToString:@"account"] && [method isEqualToString:@"list"]) {
        // 已保存账号：扫描 POJAV_HOME/accounts/*.json（结构式：id + username + selected）
        NSMutableArray *items = [NSMutableArray new];
        NSString *listPath = [NSString stringWithFormat:@"%s/accounts", getenv("POJAV_HOME")];
        NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:listPath error:nil];
        BaseAuthenticator *auth = BaseAuthenticator.current;
        NSString *currentId = auth.authData[@"accountId"];
        for (NSString *file in files) {
            if ([file hasSuffix:@".json"]) {
                NSDictionary *acc = parseJSONFromFile([listPath stringByAppendingPathComponent:file]);
                if (![acc isKindOfClass:NSDictionary.class]) continue;
                NSString *aid = acc[@"accountId"] ?: acc[@"username"] ?: @"";
                // 分类：按 json 特征判定（离线=无有效期；微软/第三方按 clientToken），供 UI 包「离线/正版」过滤。
                NSNumber *exp = acc[@"expiresAt"];
                NSString *type;
                if ([exp longValue] == 0) type = @"offline";
                else type = (acc[@"clientToken"] != nil) ? @"thirdparty" : @"microsoft";
                [items addObject:@{
                    @"id": aid,
                    @"username": acc[@"username"] ?: @"",
                    @"type": type,
                    @"selected": [aid isEqualToString:currentId] ? @YES : @NO,
                }];
            }
        }
        return @{ @"ok": @YES, @"items": items };
    }
    if ([service isEqualToString:@"account"] && [method isEqualToString:@"select"]) {
        // 切换当前账号：args.id = 已存账号的 accountId，加载并设为 current（复用 loadSavedName，路径同为 Documents/accounts）。
        NSString *aid = args[@"id"];
        if (![aid isKindOfClass:NSString.class] || aid.length == 0) return @{ @"ok": @NO };
        NSString *path = [NSString stringWithFormat:@"%s/accounts/%@.json", getenv("POJAV_HOME"), aid];
        if (![[NSFileManager defaultManager] fileExistsAtPath:path]) return @{ @"ok": @NO };
        BaseAuthenticator *auth = [BaseAuthenticator loadSavedName:aid];
        if (!auth) return @{ @"ok": @NO };
        setPrefObject(@"internal.selected_account", aid);
        [self accountInfoChanged];
        NSString *name = auth.authData[@"username"] ?: @"";
        return @{ @"ok": @YES, @"name": name };
    }
    if ([service isEqualToString:@"versionSettings"] && [method isEqualToString:@"list"]) {
        // 版本独立设置的读写读写：返回当前 profile 各字段真实值（未设置为默认）。
        NSDictionary *prof = PLProfiles.current.selectedProfile ?: @{};
        NSArray *keys = @[@"versionIsolation", @"windowTitle", @"windowInfo",
                          @"javaVersion", @"ramType", @"ram", @"ramOptimize", @"serverIp", @"loginMode"];
        NSDictionary *defs = @{
            @"versionIsolation": @"开启",
            @"windowTitle": @"",
            @"windowInfo": @"",
            @"javaVersion": @"自动选择",
            @"ramType": @"自动配置",
            @"ram": @"",
            @"ramOptimize": @"跟随全局设置",
            @"serverIp": @"",
            @"loginMode": @"正版登录或离线登录",
        };
        NSMutableArray *items = [NSMutableArray new];
        for (NSString *k in keys) {
            id v = prof[k];
            if (![v isKindOfClass:NSString.class]) v = defs[k] ?: @"";
            [items addObject:@{ @"key": k, @"value": v ?: @"" }];
        }
        return @{ @"ok": @YES, @"items": items };
    }
    if ([service isEqualToString:@"versionSettings"] && [method isEqualToString:@"set"]) {
        // 写入当前 profile 的版本独立设置（白名单 key，存 launcher_profiles.json 的 profiles.<name>）。
        static NSSet<NSString *> *allowed = nil;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            allowed = [NSSet setWithArray:@[@"versionIsolation", @"windowTitle", @"windowInfo",
                                            @"javaVersion", @"ramType", @"ram", @"ramOptimize", @"serverIp", @"loginMode"]];
        });
        NSString *k = args[@"key"];
        id rawV = args[@"value"];
        if (![k isKindOfClass:NSString.class] || ![allowed containsObject:k]) return @{ @"ok": @NO };
        NSString *v = [rawV isKindOfClass:NSString.class] ? rawV : @"";
        PLProfiles *p = PLProfiles.current;
        NSString *name = p.selectedProfileName;
        if (name.length == 0) return @{ @"ok": @NO };
        NSMutableDictionary *profile = [[p.profiles objectForKey:name] mutableCopy] ?: [NSMutableDictionary new];
        profile[k] = v;
        [p saveProfile:profile withName:name];
        return @{ @"ok": @YES };
    }
    if ([service isEqualToString:@"instance"] && [method isEqualToString:@"list"]) {
        // 版本选择界面右侧目录：直接渲染 /Documents/instances 下所有文件夹（default 为根目录内置，不列入）。
        NSMutableArray *items = [NSMutableArray new];
        NSString *instPath = [NSString stringWithFormat:@"%s/instances", getenv("POJAV_HOME")];
        NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:instPath error:nil];
        NSString *current = getPrefObject(@"general.game_directory") ?: @"default";
        for (NSString *file in files) {
            BOOL isDir = NO;
            if (![NSFileManager.defaultManager fileExistsAtPath:[instPath stringByAppendingPathComponent:file] isDirectory:&isDir]) continue;
            if (!isDir || [file isEqualToString:@"default"]) continue;
            [items addObject:@{
                @"id": file,
                @"name": file,
                @"path": [instPath stringByAppendingPathComponent:file],
                @"selected": [file isEqualToString:current] ? @YES : @NO,
            }];
        }
        return @{ @"ok": @YES, @"items": items };
    }
    if ([service isEqualToString:@"gameDir"] && [method isEqualToString:@"list"]) {
        // 已配置游戏目录：default 常驻 + POJAV_HOME/instances 下的子目录（结构式）。
        NSMutableArray *items = [NSMutableArray new];
        [items addObject:@{ @"id": @"default", @"name": @"default", @"selected": @NO }];
        NSString *instancesPath = [NSString stringWithFormat:@"%s/instances", getenv("POJAV_HOME")];
        NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:instancesPath error:nil];
        NSString *current = getPrefObject(@"general.game_directory") ?: @"default";
        BOOL found = NO;
        for (NSString *file in files) {
            BOOL isDir = NO;
            if (![NSFileManager.defaultManager fileExistsAtPath:[instancesPath stringByAppendingPathComponent:file] isDirectory:&isDir]) continue;
            if (!isDir || [file isEqualToString:@"default"]) continue;
            BOOL sel = [file isEqualToString:current];
            if (sel) found = YES;
            [items addObject:@{ @"id": file, @"name": file, @"selected": @(sel) }];
        }
        items[0] = @{ @"id": @"default", @"name": @"default", @"selected": @(!found) };
        return @{ @"ok": @YES, @"items": items };
    }
    if ([service isEqualToString:@"gameDir"] && [method isEqualToString:@"set"]) {
        NSString *name = args[@"name"];
        if (![name isKindOfClass:NSString.class] || name.length == 0) return @{ @"ok": @NO };
        NSArray *list = [self handleLuaService:@"gameDir" method:@"list" args:@{}][@"items"];
        BOOL exists = NO;
        for (NSDictionary *it in list) if ([it[@"id"] isEqualToString:name]) { exists = YES; break; }
        if (!exists) return @{ @"ok": @NO, @"error": @"not found" };
        [self setGameDirectory:name];
        return @{ @"ok": @YES };
    }
    if ([service isEqualToString:@"gameDir"] && [method isEqualToString:@"new"]) {
        // 新建游戏目录：在 POJAV_HOME/instances 下创建 <name> 目录并切换（镜像原生页脚逻辑）
        NSString *name = args[@"name"];
        if (![name isKindOfClass:NSString.class] || name.length == 0) return @{ @"ok": @NO };
        NSString *dest = [NSString stringWithFormat:@"%s/instances/%@", getenv("POJAV_HOME"), name];
        NSError *error = nil;
        [NSFileManager.defaultManager createDirectoryAtPath:dest
                              withIntermediateDirectories:NO
                                              attributes:nil
                                                   error:&error];
        if (error != nil) {
            return @{ @"ok": @NO, @"error": error.localizedDescription ?: @"create failed" };
        }
        [self setGameDirectory:name];
        return @{ @"ok": @YES };
    }
    // ---- 资源中心（Mods）服务：list 同步返回缓存 / refresh 异步扫描后 emit 刷新 ----
    if ([service isEqualToString:@"mods"] && [method isEqualToString:@"list"]) {
        if (self.modsCache.count == 0) [self restartModsScan];
        return @{ @"ok": @YES, @"profile": PLProfiles.current.selectedProfileName ?: @"",
                  @"items": self.modsCache ?: @[] };
    }
    if ([service isEqualToString:@"mods"] && [method isEqualToString:@"refresh"]) {
        [self restartModsScan];
        return @{ @"ok": @YES };
    }
    if ([service isEqualToString:@"mods"] && [method isEqualToString:@"toggle"]) {
        NSUInteger idx = [args[@"index"] unsignedIntegerValue];
        if (self.modsCache && idx < self.modsCache.count) {
            NSDictionary *item = self.modsCache[idx];
            ModItem *mod = [ModItem new];
            mod.fileName = item[@"fileName"];
            mod.filePath = item[@"filePath"];
            mod.disabled = [item[@"enabled"] boolValue] == NO;
            NSError *err = nil;
            BOOL ok = [[ModService sharedService] toggleEnableForMod:mod error:&err];
            [self restartModsScan];
            return ok ? @{ @"ok": @YES } : @{ @"ok": @NO, @"error": err.localizedDescription ?: @"" };
        }
    }
    if ([service isEqualToString:@"mods"] && [method isEqualToString:@"delete"]) {
        NSUInteger idx = [args[@"index"] unsignedIntegerValue];
        if (self.modsCache && idx < self.modsCache.count) {
            NSDictionary *item = self.modsCache[idx];
            ModItem *mod = [ModItem new];
            mod.fileName = item[@"fileName"];
            mod.filePath = item[@"filePath"];
            NSError *err = nil;
            BOOL ok = [[ModService sharedService] deleteMod:mod error:&err];
            [self restartModsScan];
            return ok ? @{ @"ok": @YES } : @{ @"ok": @NO, @"error": err.localizedDescription ?: @"" };
        }
    }
    // ---- 光影包（Shaders）服务：与 mods 同构（ShaderService 扫描 shaderpacks，.zip/.zip.disabled 启停）----
    if ([service isEqualToString:@"shaders"] && [method isEqualToString:@"list"]) {
        if (self.shadersCache.count == 0) [self restartShadersScan];
        return @{ @"ok": @YES, @"profile": PLProfiles.current.selectedProfileName ?: @"",
                  @"items": self.shadersCache ?: @[] };
    }
    if ([service isEqualToString:@"shaders"] && [method isEqualToString:@"refresh"]) {
        [self restartShadersScan];
        return @{ @"ok": @YES };
    }
    if ([service isEqualToString:@"shaders"] && [method isEqualToString:@"toggle"]) {
        NSUInteger idx = [args[@"index"] unsignedIntegerValue];
        if (self.shadersCache && idx < self.shadersCache.count) {
            NSDictionary *item = self.shadersCache[idx];
            ShaderItem *sh = [ShaderItem new];
            sh.fileName = item[@"fileName"];
            sh.filePath = item[@"filePath"];
            sh.disabled = [item[@"enabled"] boolValue] == NO;
            NSError *err = nil;
            BOOL ok = [[ShaderService sharedService] toggleEnableForShader:sh error:&err];
            [self restartShadersScan];
            return ok ? @{ @"ok": @YES } : @{ @"ok": @NO, @"error": err.localizedDescription ?: @"" };
        }
    }
    if ([service isEqualToString:@"shaders"] && [method isEqualToString:@"delete"]) {
        NSUInteger idx = [args[@"index"] unsignedIntegerValue];
        if (self.shadersCache && idx < self.shadersCache.count) {
            NSDictionary *item = self.shadersCache[idx];
            ShaderItem *sh = [ShaderItem new];
            sh.fileName = item[@"fileName"];
            sh.filePath = item[@"filePath"];
            NSError *err = nil;
            BOOL ok = [[ShaderService sharedService] deleteShader:sh error:&err];
            [self restartShadersScan];
            return ok ? @{ @"ok": @YES } : @{ @"ok": @NO, @"error": err.localizedDescription ?: @"" };
        }
    }
    if ([service isEqualToString:@"system"] && [method isEqualToString:@"info"]) {
        // 仅描述结构：动态值由设备/运行时填充，不写死。
        return @{ @"ok": @YES,
                  @"os": [UIDevice currentDevice].systemName ?: @"",
                  @"systemVersion": [UIDevice currentDevice].systemVersion ?: @"",
                  @"model": [UIDevice currentDevice].model ?: @"" };
    }
    if ([service isEqualToString:@"storage"] && [method isEqualToString:@"summary"]) {
        return @{ @"ok": @YES, @"summary": @"" };
    }
    // 下载进度等异步服务：返回占位结构，真实实现由服务类异步回调后 emit 刷新。
    if ([service isEqualToString:@"download"] && [method isEqualToString:@"summary"]) {
        return @{ @"ok": @YES, @"activity": @0, @"downloaded": @0, @"total": @0 };
    }
    NSLog(@"[PLUIShell] unknown lua service %@.%@", service, method);
    return @{ @"ok": @NO };
}

- (void)showInitialPage {
    if (!self.contentNode) return;
    // 完全数据驱动：content 节点渲染 Lua 页子树，页 token 由 UI 包配置（pages 表）解析。
    NSString *token = self.contentNode.initialPage ?: @"home";
    NSString *pageId = [self.contentNode pageIdForToken:token];
    BOOL hasLuaPage = NO;
    for (PLUINodeView *p in self.contentNode.contentPages) {
        if (p.nodeId && [p.nodeId isEqualToString:pageId]) { hasLuaPage = YES; break; }
    }
    if (hasLuaPage) {
        [self.contentNode showLuaPage:pageId animated:NO];
        [self dispatchLuaPageChange:token];
        return;
    }
    // 原生 VC 降级路径（仅供未 Lua 化的功能页过渡，后续随服务化移除）。
    if ([token isEqualToString:@"download"]) {
        [self showDownloadPage];
    } else if ([token isEqualToString:@"ai"]) {
        [self showAIPage];
    } else {
        [self showHomePage];
    }
}

- (void)dispatchLuaPageChange:(NSString *)token {
    self.currentLuaPage = token;
    [self.runtime dispatchEvent:@"onPageChange" arguments:@[token ?: @""]];
}

- (void)pluiHandleNavigate:(NSNotification *)n {
    NSString *token = [n.object isKindOfClass:NSString.class] ? n.object : @"home";
    if (!self.contentNode) return;
    NSString *pageId = [self.contentNode pageIdForToken:token];
    BOOL hasLuaPage = NO;
    for (PLUINodeView *p in self.contentNode.contentPages) {
        if (p.nodeId && [p.nodeId isEqualToString:pageId]) { hasLuaPage = YES; break; }
    }
    if (hasLuaPage) {
        [self.contentNode showLuaPage:pageId animated:YES];
        [self dispatchLuaPageChange:token];
        return;
    }
    // 非 Lua 页 token 回退到原生 VC 加载。
    if ([token isEqualToString:@"settings"])            [self showSettings];
    else if ([token isEqualToString:@"ai"])             [self showAIPage];
    else if ([token isEqualToString:@"mods"])           [self showModsManager];
    else if ([token isEqualToString:@"shaders"])        [self showShadersManager];
    else if ([token isEqualToString:@"modpackImport"])  [self showModpackImport];
    else if ([token isEqualToString:@"gameDirectory"])  [self showGameDirectory];
    else if ([token isEqualToString:@"profileEditor"])  [self showProfileEditor:nil];
}

- (void)pluiHandleOpenSubpage:(NSNotification *)n {
    NSString *token = [n.object isKindOfClass:NSString.class] ? n.object : @"";
    // 次级页 = 内容区内的 Lua 页子树：token 若已注册（CONFIG.pages），直接走
    // 与 navigate 相同的切页管线（showLuaPage + onPageChange），引擎零子页特例。
    if (self.contentNode) {
        NSString *pageId = [self.contentNode pageIdForToken:token];
        BOOL hasLuaPage = NO;
        for (PLUINodeView *p in self.contentNode.contentPages) {
            if (p.nodeId && [p.nodeId isEqualToString:pageId]) { hasLuaPage = YES; break; }
        }
        if (hasLuaPage) {
            [self.contentNode showLuaPage:pageId animated:YES];
            [self dispatchLuaPageChange:token];
            return;
        }
    }
    // 无 Lua 次级页的令牌：回退派发给 Lua 包（onOpenSubpage），由包决定如何处理。
    [self.runtime dispatchEvent:@"onOpenSubpage" arguments:@[token]];
}

- (void)pluiHandleSwitchTab:(NSNotification *)n {
    NSString *key = [n.object isKindOfClass:NSString.class] ? n.object : @"";
    [self.runtime dispatchEvent:@"onSwitchTab" arguments:@[key]];
}

- (void)pluiHandleSubmit:(NSNotification *)n {
    NSString *formId = [n.object isKindOfClass:NSString.class] ? n.object : @"";
    [self.runtime dispatchEvent:@"onSubmit" arguments:@[formId]];
}

- (void)pluiHandleService:(NSNotification *)n {
    NSString *name = [n.object isKindOfClass:NSString.class] ? n.object : @"";
    [self.runtime dispatchEvent:@"onService" arguments:@[name]];
}

- (void)refreshStateAndNotifyReady {
    NSDictionary *state = [self currentState];
    [self.runtime setState:state];
    [self.runtime dispatchEvent:@"onReady" arguments:@[]];
}

- (NSDictionary *)currentState {
    BaseAuthenticator *auth = BaseAuthenticator.current;
    NSString *username = auth.authData[@"username"];
    return @{
        @"account": username ? @{@"name": username} : [NSNull null],
        @"version": @{@"name": PLProfiles.current.selectedProfileName ?: @""},
        @"profiles": [self profileStateList],
        @"servers": [self serverStateList],
        @"darkMode": @(self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark),
        @"locale": [NSLocale currentLocale].localeIdentifier ?: @"",
        @"settings": [self launcherSettingsList],
    };
}

// 设置列表数据源（启动器拥有）：由 launcher.state.settings 提供给 UI 包渲染。
// 启动器在此新增条目即可，UI 包无需改动 —— 引擎只提供数据，包只做渲染。
- (NSArray<NSDictionary *> *)launcherSettingsList {
    // 顺序即展示顺序；desc 非空时包会在卡片下方渲染灰色说明小字。
    // 无 desc 传空串（保证 JSON/字典字段结构一致，包端按结构读取）。
    return @[
        @{ @"label": @"启动器设置",   @"icon": @"sf:slider.horizontal.3",        @"desc": @"",                 @"action": @"open_subpage:launcher_settings" },
        @{ @"label": @"下载镜像策略", @"icon": @"sf:arrow.down.circle.fill",     @"desc": @"",                 @"action": @"open_subpage:download_mirror" },
        @{ @"label": @"视频设置",     @"icon": @"sf:display",                    @"desc": @"最大分辨率、垂直同步与渲染占比等显示选项。", @"action": @"open_subpage:video_settings" },
        @{ @"label": @"MobileGlues 渲染器", @"icon": @"sf:memorychip.fill",      @"desc": @"选择 OpenGL 兼容层，可能影响画面表现与性能。", @"action": @"open_subpage:gl_renderer" },
        @{ @"label": @"自定义控制键", @"icon": @"sf:keyboard.fill",              @"desc": @"",                 @"action": @"open_subpage:control_keys" },
        @{ @"label": @"Java 调整",    @"icon": @"sf:wrench.and.screwdriver.fill",@"desc": @"",                 @"action": @"open_subpage:java_tuning" },
        @{ @"label": @"UI 设置",      @"icon": @"sf:paintbrush.fill",            @"desc": @"界面缩放与视觉效果，可导入主题材质包调整外观。", @"action": @"open_subpage:ui_theme" },
        @{ @"label": @"AI 助手",      @"icon": @"sf:sparkles",                   @"desc": @"",                 @"action": @"open_subpage:ai_assistant" },
    ];
}

#pragma mark - 通知注册（与旧壳相同的 13 个 Show* + 状态源）

- (void)registerNotifications {
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    void (^on)(NSString *, SEL) = ^(NSString *name, SEL selector) {
        [center addObserver:self selector:selector name:name object:nil];
    };
    on(@"ShowHomePage", @selector(showHomePage));
    on(@"ShowDownloadPage", @selector(showDownloadPage));
    on(@"ShowVersionManager", @selector(showVersionManager));
    on(@"ShowProfileEditor", @selector(showProfileEditor:));
    on(@"ShowSettings", @selector(showSettings));
    on(@"ShowAIPage", @selector(showAIPage));
    on(@"ShowMultiplayer", @selector(showMultiplayer));
    on(@"ShowZeroTier", @selector(showMultiplayer));
    on(@"ShowMorePage", @selector(showMorePage));
    on(@"ShowModsManager", @selector(showModsManager));
    on(@"ShowShadersManager", @selector(showShadersManager));
    on(@"ShowModpackImport", @selector(showModpackImport));
    on(@"ShowGameDirectory", @selector(showGameDirectory));
    on(@"ShowAccountManager", @selector(showAccountManager));

    on(@"BackgroundChanged", @selector(backgroundChanged));
    on(@"BackgroundUIEffectChanged", @selector(uiEffectChanged));
    on(@"SelectedProfileChanged", @selector(reloadProfileEditorIfNeeded));
    on(@"ReloadProfileList", @selector(reloadVersionLists));
    on(@"FindVersionInRemoteList", @selector(findVersionInRemoteList:));
    on(@"UpdateAccountInfo", @selector(accountInfoChanged));
    on(PLThemeDidChangeNotification, @selector(themeDidChange));

    // 引擎通用五类动作（PLUIActionRouter 前缀解析后转发）：全部经 Lua / 内容区直渲分发。
    on(@"PLUIActionNavigate", @selector(pluiHandleNavigate:));
    on(@"PLUIActionOpenSubpage", @selector(pluiHandleOpenSubpage:));
    on(@"PLUIActionSwitchTab", @selector(pluiHandleSwitchTab:));
    on(@"PLUIActionSubmit", @selector(pluiHandleSubmit:));
    on(@"PLUIActionService", @selector(pluiHandleService:));
}

- (void)accountInfoChanged {
    [self.runtime setState:[self currentState]];
    NSDictionary *account = [self currentState][@"account"];
    if (![account isEqual:[NSNull null]]) {
        [self.runtime dispatchEvent:@"onAccountChange" arguments:@[account ?: @{}]];
    } else {
        [self.runtime dispatchEvent:@"onAccountChange" arguments:@[[NSNull null]]];
    }
}

- (void)themeDidChange {
    // 主题/材质包切换：即时重渲染（保留当前内容区页面标识）
    NSString *currentPageIdentifier = nil;
    if ([self.contentViewController isKindOfClass:UINavigationController.class]) {
        UIViewController *top = ((UINavigationController *)self.contentViewController).topViewController;
        currentPageIdentifier = NSStringFromClass(top.class);
    }
    [self buildShell];
    if (currentPageIdentifier) {
        [self restorePageForClass:currentPageIdentifier];
    }
}

/// 主题重渲染后尽量恢复之前的内容页（按 VC 类名映射到对应 Show*）
- (void)restorePageForClass:(NSString *)className {
    NSDictionary *mapping = @{
        @"LauncherNewsViewController": @"open:home",
        @"DownloadViewController": @"open:download",
        @"VersionManagerViewController": @"open:versionManager",
        @"LauncherPreferencesViewController": @"open:settings",
        @"AIViewController": @"open:ai",
        @"MultiplayerViewController": @"open:multiplayer",
        @"PLUIMoreViewController": @"open:more",
        @"ModsManagerViewController": @"open:mods",
        @"ShadersManagerViewController": @"open:shaders",
        @"ModpackImportViewController": @"open:modpackImport",
        @"LauncherPrefGameDirViewController": @"open:gameDirectory",
        @"AccountListViewController": @"open:accountManager",
        @"ProfileSettingsViewController": @"open:profileEditor",
    };
    NSString *action = mapping[className];
    if (action) [PLUIActionRouter.sharedRouter performAction:action fromViewController:self];
}

#pragma mark - 内容区页面（实现搬迁自 LauncherRootViewController）

- (void)showHomePage {
    [self showLuaPage:@"home"];
}

- (void)showDownloadPage {
    [self showLuaPage:@"download"];
}

- (void)showVersionManager {
    VersionManagerViewController *vc = [[VersionManagerViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.navigationBar.prefersLargeTitles = NO;
    [self setContentViewController:nav animated:YES];
}

- (void)showProfileEditor:(NSNotification *)notification {
    NSString *profileName = notification.object;
    ProfileSettingsViewController *vc = [[ProfileSettingsViewController alloc] init];
    vc.profileName = profileName;
    UINavigationController *navVC = [[UINavigationController alloc] initWithRootViewController:vc];
    navVC.navigationBar.prefersLargeTitles = NO;
    self.isShowingProfileEditor = YES;
    [self setContentViewController:navVC animated:YES];
}

- (void)reloadProfileEditorIfNeeded {
    if (self.isShowingProfileEditor) {
        NSString *currentProfile = PLProfiles.current.selectedProfileName;
        if (currentProfile) {
            [[NSNotificationCenter defaultCenter] postNotificationName:@"ShowProfileEditor" object:currentProfile];
        }
    }
}

- (void)showSettings {
    [self showLuaPage:@"settings"];
}

- (void)showAIPage {
    AiSession *session = [[AiSessionStore sharedStore] lastActiveSession];
    AIViewController *vc = [[AIViewController alloc] initWithSession:session];
    UINavigationController *navVC = [[UINavigationController alloc] initWithRootViewController:vc];
    navVC.navigationBar.prefersLargeTitles = NO;
    [self setContentViewController:navVC animated:YES];
}

- (void)showMultiplayer {
    [self showLuaPage:@"multi"];
}

- (void)showMorePage {
    [self showLuaPage:@"more"];
}

/// Lua 页 → 内容区对应子树的节点 id（内容区五棵纯 Lua 页面约定）。
+ (NSString *)luaPageNodeIdForPage:(NSString *)page {
    NSDictionary *map = @{
        @"home": @"pageHome", @"download": @"pageDownload", @"multi": @"pageMulti",
        @"settings": @"pageSettings", @"more": @"pageMore",
    };
    return map[page];
}

/// 主内容页切换：优先切到内容区的纯 Lua 子树（隐藏坍缩 + 淡入淡出）。
/// 若激活包未定义该 Lua 页（旧包/兜底树），回退旧行为——挂载原生功能 VC。
- (void)showLuaPage:(NSString *)page {
    if (![page isKindOfClass:NSString.class]) return;
    if (!self.engine || !self.contentNode) return;

    NSString *pageNodeId = [self.class luaPageNodeIdForPage:page];
    PLUINodeView *target = pageNodeId ? [self.engine viewForId:pageNodeId] : nil;
    if (!target) {
        NSLog(@"[PLUIShell] no Lua subtree for page '%@'; falling back to native VC", page);
        [self fallbackNativePage:page];
        return;
    }

    // 撤下先前原生挂载的内容 VC（Mod/光影/设置编辑器等次级页），Lua 子树接管
    [self removeNativeContentViewController];

    NSArray<NSString *> *pageIds = @[@"pageHome", @"pageDownload", @"pageMulti",
                                     @"pageSettings", @"pageMore"];
    for (NSString *pid in pageIds) {
        PLUINodeView *n = [self.engine viewForId:pid];
        if (!n) continue;
        BOOL visible = [pid isEqualToString:pageNodeId];
        [n fadeToVisible:visible duration:0.18];
    }
    self.currentLuaPage = page;
    [self.runtime dispatchEvent:@"onPageChange" arguments:@[page]];
}

/// 包未定义 Lua 页子树时的回退：沿用旧机制的固定 VC 挂载。
- (void)fallbackNativePage:(NSString *)page {
    if ([page isEqualToString:@"download"]) {
        DownloadViewController *downloadVC = [[DownloadViewController alloc] init];
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:downloadVC];
        nav.navigationBar.prefersLargeTitles = NO;
        [self setContentViewController:nav animated:YES];
    } else if ([page isEqualToString:@"settings"]) {
        LauncherPreferencesViewController *vc = [[LauncherPreferencesViewController alloc] init];
        UINavigationController *navVC = [[UINavigationController alloc] initWithRootViewController:vc];
        navVC.navigationBar.prefersLargeTitles = YES;
        [self setContentViewController:navVC animated:YES];
    } else if ([page isEqualToString:@"multi"]) {
        MultiplayerViewController *vc = [[MultiplayerViewController alloc] initWithMode:MultiplayerVCModeLauncher];
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
        nav.navigationBar.prefersLargeTitles = NO;
        [self setContentViewController:nav animated:YES];
    } else if ([page isEqualToString:@"more"]) {
        PLUIMoreViewController *vc = [[PLUIMoreViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
        nav.navigationBar.prefersLargeTitles = NO;
        [self setContentViewController:nav animated:YES];
    } else {
        LauncherNewsViewController *newsVC = [[LauncherNewsViewController alloc] init];
        [self setContentViewController:newsVC animated:YES];
    }
}

/// 移除直接挂载在内容区上的原生功能 VC（若无则不做任何事）。
- (void)removeNativeContentViewController {
    if (!self.contentViewController) return;
    UIViewController *vc = self.contentViewController;
    if (vc.parentViewController == self && vc.view.superview == self.contentNode) {
        [vc willMoveToParentViewController:nil];
        [vc.view removeFromSuperview];
        [vc removeFromParentViewController];
    }
    self.contentViewController = nil;
    self.currentContentConstraints = nil;
}

- (void)showModsManager {
    VersionManagerViewController *vm = [[VersionManagerViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vm];
    nav.navigationBar.prefersLargeTitles = NO;
    ModsManagerViewController *m = [[ModsManagerViewController alloc] init];
    [nav pushViewController:m animated:NO];
    [self setContentViewController:nav animated:YES];
}

- (void)showShadersManager {
    VersionManagerViewController *vm = [[VersionManagerViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vm];
    nav.navigationBar.prefersLargeTitles = NO;
    ShadersManagerViewController *s = [[ShadersManagerViewController alloc] init];
    s.initialMode = ShadersManagerModeLocal;
    [nav pushViewController:s animated:NO];
    [self setContentViewController:nav animated:YES];
}

- (void)showGameDirectory {
    VersionManagerViewController *vm = [[VersionManagerViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vm];
    nav.navigationBar.prefersLargeTitles = NO;
    LauncherPrefGameDirViewController *g = [[LauncherPrefGameDirViewController alloc] init];
    [nav pushViewController:g animated:NO];
    [self setContentViewController:nav animated:YES];
}

// Lua 服务落点：切换游戏目录（镜像 LauncherPrefGameDirViewController.changeSelectionTo:）
- (void)setGameDirectory:(NSString *)name {
    if (getenv("DEMO_LOCK")) return;
    setPrefObject(@"general.game_directory", name);
    NSString *multidirPath = [NSString stringWithFormat:@"%s/instances/%@", getenv("POJAV_HOME"), name];
    NSString *lasmPath = @(getenv("POJAV_GAME_DIR"));
    NSError *removeError = nil;
    [NSFileManager.defaultManager removeItemAtPath:lasmPath error:&removeError];
    NSError *linkError = nil;
    BOOL linkOK = [NSFileManager.defaultManager createSymbolicLinkAtPath:lasmPath
                                                       withDestinationPath:multidirPath
                                                                     error:&linkError];
    if (!linkOK) {
        NSLog(@"[GameDir] createSymbolicLink failed: %@", linkError.localizedDescription);
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:localize(@"Error", nil)
                              message:[NSString stringWithFormat:localize(@"i18n_str_363", nil), linkError.localizedDescription]
                       preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:localize(@"i18n_str_44", nil)
                                                  style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    [NSFileManager.defaultManager changeCurrentDirectoryPath:lasmPath];
    toggleIsolatedPref(NO);
    [PLProfiles updateCurrent];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"ReloadProfileList" object:nil];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"SelectedProfileChanged" object:nil];
}

// 资源中心（Mods）异步扫描：ModService 扫描当前版本 mods/，结构化为缓存并推送 Lua。
- (void)restartModsScan {
    NSString *profile = PLProfiles.current.selectedProfileName;
    __weak typeof(self) weakSelf = self;
    [[ModService sharedService] scanModsForProfile:profile completion:^(NSArray<ModItem *> *mods) {
        NSMutableArray *items = [NSMutableArray new];
        [mods enumerateObjectsUsingBlock:^(ModItem *m, NSUInteger i, BOOL *stop) {
            NSString *name = m.displayName.length > 0 ? m.displayName : m.fileName;
            [items addObject:@{
                @"name": name ?: @"",
                @"fileName": m.fileName ?: @"",
                @"filePath": m.filePath ?: @"",
                @"enabled": @(!m.disabled),
                @"author": m.author ?: @"",
                @"gameVersion": m.gameVersion ?: @"",
            }];
        }];
        // Lua 状态单线程访问：合并更新 + 事件必须回到主线程。
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf.modsCache = items;
            if (strongSelf.runtime) {
                [strongSelf.runtime dispatchEvent:@"onModsUpdated"
                                        arguments:@[@{ @"ok": @YES, @"items": items }]];
            }
        });
    }];
}

// 光影包（Shaders）异步扫描：ShaderService 扫描当前版本 shaderpacks/，结构化为缓存并推送 Lua。
- (void)restartShadersScan {
    NSString *profile = PLProfiles.current.selectedProfileName;
    __weak typeof(self) weakSelf = self;
    [[ShaderService sharedService] scanShadersForProfile:profile completion:^(NSArray<ShaderItem *> *shaders) {
        NSMutableArray *items = [NSMutableArray new];
        [shaders enumerateObjectsUsingBlock:^(ShaderItem *s, NSUInteger i, BOOL *stop) {
            NSString *name = s.displayName.length > 0 ? s.displayName : s.fileName;
            [items addObject:@{
                @"name": name ?: @"",
                @"fileName": s.fileName ?: @"",
                @"filePath": s.filePath ?: @"",
                @"enabled": @(!s.disabled),
                @"author": s.author ?: @"",
                @"gameVersion": s.gameVersion ?: @"",
            }];
        }];
        // Lua 状态单线程访问：合并更新 + 事件必须回到主线程。
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf.shadersCache = items;
            if (strongSelf.runtime) {
                [strongSelf.runtime dispatchEvent:@"onShadersUpdated"
                                        arguments:@[@{ @"ok": @YES, @"items": items }]];
            }
        });
    }];
}

- (void)showModpackImport {
    DownloadViewController *d = [[DownloadViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:d];
    nav.navigationBar.prefersLargeTitles = NO;
    ModpackImportViewController *m = [[ModpackImportViewController alloc] init];
    [nav pushViewController:m animated:NO];
    [self setContentViewController:nav animated:YES];
}

- (void)showAccountManager {
    AccountListViewController *vc = [[AccountListViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    vc.whenItemSelected = ^void() {
        [[NSNotificationCenter defaultCenter] postNotificationName:@"UpdateAccountInfo" object:nil];
    };
    vc.whenDelete = ^void(NSString *name) {
        [[NSNotificationCenter defaultCenter] postNotificationName:@"UpdateAccountInfo" object:nil];
    };
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.navigationBar.prefersLargeTitles = NO;
    [self setContentViewController:nav animated:YES];
}

- (void)backgroundChanged {
    [[BackgroundManager sharedManager] applyBackgroundToView:self.view];
    // 壁纸设置/清除切换壳底色：有壁纸→透明透出窗口级壁纸；无壁纸→不透明主题底色
    [self refreshShellBackdrop];
}

/// 壳底色（黑边根治）：makeViewControllerTransparent 把壳视图置透明后，
/// Lua 树任何未覆盖/半透明区域都透出窗口底色 —— 而 general.ui_theme 默认
/// dark，systemBackgroundColor=黑，形成"黑边/黑底"。
/// 有壁纸：保持透明，让窗口最底层的壁纸容器透出（半透明包色叠加其上）；
/// 无壁纸：铺不透明主题底色，半透明包色叠加其上呈现正常浅色观感。
- (void)refreshShellBackdrop {
    BackgroundManager *background = [BackgroundManager sharedManager];
    // 兜底必须是浅色（仿 PCL：浅蓝灰 #E3EEF9）。禁止黑色/深灰/透明兜底。
    UIColor *fallbackLight = [PLThemeManager.sharedManager colorFromHex:@"#E3EEF9"];
    UIColor *base = [PLThemeManager.sharedManager colorForToken:@"background" fallback:fallbackLight] ?: fallbackLight;
    self.view.backgroundColor = background.hasBackground ? [UIColor clearColor] : base;
}

- (void)uiEffectChanged:(NSNotification *)notification {
    // 对根容器的直接子节点（侧栏/面板等容器节点）重应用毛玻璃
    for (PLUINodeView *child in self.engine.rootView.subviews) {
        if ([child isKindOfClass:PLUINodeView.class]) {
            [[BackgroundManager sharedManager] applyEffectToView:child];
        }
    }
    // 背景透明度/毛玻璃滑条实时生效：当前内容页同步重应用透明化
    if (self.contentViewController) {
        if ([self.contentViewController isKindOfClass:UINavigationController.class]) {
            for (UIViewController *stackVC in ((UINavigationController *)self.contentViewController).viewControllers) {
                [[BackgroundManager sharedManager] makeViewControllerTransparent:stackVC];
            }
        } else {
            [[BackgroundManager sharedManager] makeViewControllerTransparent:self.contentViewController];
        }
    }
}

#pragma mark - 版本列表（数据源，与旧壳一致）

- (void)reloadVersionLists {
    [self initializeVersionLists];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"SelectedProfileChanged" object:nil];
}

- (void)initializeVersionLists {
    if (!self.localVersionList) self.localVersionList = [NSMutableArray new];
    [self.localVersionList removeAllObjects];

    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *versionPath = [NSString stringWithFormat:@"%s/versions/", getenv("POJAV_GAME_DIR")];
    NSArray *list = [fileManager contentsOfDirectoryAtPath:versionPath error:nil];
    for (NSString *versionId in list) {
        NSString *localPath = [NSString stringWithFormat:@"%s/versions/%@", getenv("POJAV_GAME_DIR"), versionId];
        BOOL isDirectory;
        if ([fileManager fileExistsAtPath:localPath isDirectory:&isDirectory] && isDirectory) {
            [self.localVersionList addObject:@{@"id": versionId, @"type": @"custom"}];
        }
    }

    if (!self.remoteVersionList) self.remoteVersionList = [NSMutableArray new];
    [self.remoteVersionList removeAllObjects];
    [self.remoteVersionList addObjectsFromArray:@[
        @{@"id": @"latest-release", @"type": @"release"},
        @{@"id": @"latest-snapshot", @"type": @"snapshot"}
    ]];
    [self fetchRemoteVersionList];
}

- (void)fetchRemoteVersionList {
    NSString *downloadSource = getPrefObject(@"general.download_source");
    NSString *versionManifestURL = [downloadSource isEqualToString:@"bmclapi"]
        ? @"https://bmclapi2.bangbang93.com/mc/game/version_manifest_v2.json"
        : @"https://piston-meta.mojang.com/mc/game/version_manifest_v2.json";

    NSURLSessionDataTask *task = [[NSURLSession sharedSession]
        dataTaskWithURL:[NSURL URLWithString:versionManifestURL]
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            if (data && !error) {
                NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                if (json[@"versions"]) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [self.remoteVersionList addObjectsFromArray:json[@"versions"]];
                        setPrefObject(@"internal.latest_version", json[@"latest"]);
                    });
                }
            }
        }];
    [task resume];
}

- (void)findVersionInRemoteList:(NSNotification *)notification {
    NSDictionary *userInfo = notification.userInfo;
    NSString *versionId = userInfo[@"versionId"];
    void (^callback)(NSDictionary *) = userInfo[@"callback"];
    if (!versionId || !callback) return;

    NSDictionary *versionObject = nil;
    for (NSDictionary *version in self.remoteVersionList) {
        if ([version[@"id"] isEqualToString:versionId]) { versionObject = version; break; }
    }
    if (!versionObject) {
        for (NSDictionary *version in self.localVersionList) {
            if ([version[@"id"] isEqualToString:versionId]) { versionObject = version; break; }
        }
    }
    callback(versionObject);
}

#pragma mark - Content Switching（整段搬迁自 LauncherRootViewController，保留全部历史修复注释）

/// 内容页 VC 类 → 页面标识（onPageChange 派发与 restorePageForClass 共用语义）
+ (NSString *)pageIdentifierForViewController:(UIViewController *)viewController {
    UIViewController *target = viewController;
    if ([target isKindOfClass:UINavigationController.class]) {
        target = ((UINavigationController *)target).topViewController;
    }
    NSDictionary *mapping = @{
        @"LauncherNewsViewController": @"home",
        @"DownloadViewController": @"download",
        @"VersionManagerViewController": @"versionManager",
        @"LauncherPreferencesViewController": @"settings",
        @"AIViewController": @"ai",
        @"MultiplayerViewController": @"multiplayer",
        @"PLUIMoreViewController": @"more",
        @"ModsManagerViewController": @"mods",
        @"ShadersManagerViewController": @"shaders",
        @"ModpackImportViewController": @"modpackImport",
        @"LauncherPrefGameDirViewController": @"gameDirectory",
        @"AccountListViewController": @"accountManager",
        @"ProfileSettingsViewController": @"profileEditor",
    };
    return mapping[NSStringFromClass(target.class)];
}

/// 内容页变化时通知 Lua 包（页签选中态等跟随真实页面而非仅点击）
- (void)notifyLuaPageChangedForViewController:(UIViewController *)viewController {
    NSString *pageId = [self.class pageIdentifierForViewController:viewController];
    if (!pageId || [pageId isEqualToString:self.currentLuaPage]) return;
    self.currentLuaPage = pageId;
    [self.runtime dispatchEvent:@"onPageChange" arguments:@[pageId]];
}

- (void)setContentViewController:(UIViewController *)viewController animated:(BOOL)animated {
    if (!viewController) return;
    if (!self.contentNode) {
        NSLog(@"[PLUIShell] no content node; cannot switch content page");
        return;
    }

    // 关键修复（UI 累积异常）：同一实例直接跳过，避免对同一 VC 重复添加约束
    // 和反复调用 applyEffectToNavigationBar: 导致 hairline UIImageView 累积。
    if (viewController == self.contentViewController) return;

    // 检查是否切换到非编辑器页面
    if (![viewController isKindOfClass:[UINavigationController class]] ||
        ![((UINavigationController *)viewController).topViewController isKindOfClass:[ProfileSettingsViewController class]]) {
        self.isShowingProfileEditor = NO;
    }

    UIViewController *oldVC = self.contentViewController;

    // 移除旧的 + 添加新的
    self.contentViewController = viewController;
    [self addChildViewController:viewController];
    viewController.view.translatesAutoresizingMaskIntoConstraints = NO;
    // 约束生效前先按内容区 frame 预对齐，避免切换首帧从 (0,0) 左上角闪现（真机反馈）
    viewController.view.frame = self.contentNode.bounds;

    // FCL 风格：对 UINavigationController 应用 nav bar 毛玻璃效果，并对内容 VC 透明化处理，
    // 避免顶部出现默认白色 nav bar 形成"大白条"。
    if ([viewController isKindOfClass:[UINavigationController class]]) {
        UINavigationController *nav = (UINavigationController *)viewController;
        nav.delegate = self;
        [[BackgroundManager sharedManager] applyEffectToNavigationBar:nav.navigationBar];
        [[BackgroundManager sharedManager] makeViewControllerTransparent:nav.topViewController];
        for (UIViewController *stackVC in nav.viewControllers) {
            [[BackgroundManager sharedManager] makeViewControllerTransparent:stackVC];
        }
    } else {
        [[BackgroundManager sharedManager] makeViewControllerTransparent:viewController];
    }

    // 关键修复（UI 累积异常）：deactivate 旧约束，避免缓存复用的子 VC
    // 反复激活约束导致内容区左右变宽。
    if (self.currentContentConstraints.count > 0) {
        [NSLayoutConstraint deactivateConstraints:self.currentContentConstraints];
        self.currentContentConstraints = nil;
    }

    NSArray<NSLayoutConstraint *> *newConstraints = @[
        [viewController.view.leadingAnchor constraintEqualToAnchor:self.contentNode.leadingAnchor],
        [viewController.view.trailingAnchor constraintEqualToAnchor:self.contentNode.trailingAnchor],
        [viewController.view.topAnchor constraintEqualToAnchor:self.contentNode.topAnchor],
        [viewController.view.bottomAnchor constraintEqualToAnchor:self.contentNode.bottomAnchor]
    ];

    if (animated && oldVC) {
        // 单 transition crossDissolve：同一 animations block 内完成移除+添加，
        // animations 内 layoutIfNeeded 保证 snapshot 时新视图 frame 已撑满。
        [UIView transitionWithView:self.contentNode
                          duration:0.3
                           options:UIViewAnimationOptionTransitionCrossDissolve
                        animations:^{
                            [oldVC willMoveToParentViewController:nil];
                            [oldVC.view removeFromSuperview];
                            [self.contentNode addSubview:viewController.view];
                            [NSLayoutConstraint activateConstraints:newConstraints];
                            [self.contentNode layoutIfNeeded];
                        } completion:^(BOOL finished) {
                            [oldVC removeFromParentViewController];
                            [viewController didMoveToParentViewController:self];
                        }];
    } else {
        if (oldVC) {
            [oldVC willMoveToParentViewController:nil];
            [oldVC.view removeFromSuperview];
            [oldVC removeFromParentViewController];
        }
        [self.contentNode addSubview:viewController.view];
        [NSLayoutConstraint activateConstraints:newConstraints];
        [viewController didMoveToParentViewController:self];
    }

    self.currentContentConstraints = newConstraints;
    [self notifyLuaPageChangedForViewController:viewController];
}

#pragma mark - Orientation

- (BOOL)shouldAutorotate {
    return YES;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskLandscape;
}

#pragma mark - UINavigationControllerDelegate

- (void)navigationController:(UINavigationController *)navigationController
       didShowViewController:(UIViewController *)viewController
                    animated:(BOOL)animated {
    [[BackgroundManager sharedManager] makeViewControllerTransparent:viewController];
    for (UIViewController *stackVC in navigationController.viewControllers) {
        [[BackgroundManager sharedManager] makeViewControllerTransparent:stackVC];
    }
    [[BackgroundManager sharedManager] applyEffectToNavigationBar:navigationController.navigationBar];
}

#pragma mark - 欢迎界面（无导入包时的兜底，纯 UIKit，不依赖 Lua 引擎）

/// 取 app 图标：优先用户设置的备用图标，失败退回主图标 / 系统占位图标。
static UIImage *PLUIWelcomeAppIcon(void) {
    NSString *alternate = UIApplication.sharedApplication.alternateIconName;
    if (alternate.length > 0) {
        UIImage *image = [UIImage imageNamed:alternate];
        if (image) return image;
    }
    id icons = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleIcons"];
    if ([icons isKindOfClass:NSDictionary.class]) {
        id primary = ((NSDictionary *)icons)[@"CFBundlePrimaryIcon"];
        if ([primary isKindOfClass:NSDictionary.class]) {
            NSString *iconName = ((NSDictionary *)primary)[@"CFBundleIconName"];
            if ([iconName isKindOfClass:NSString.class]) {
                UIImage *image = [UIImage imageNamed:iconName];
                if (image) return image;
            }
        }
    }
    return [UIImage imageNamed:@"AppIcon60x60"] ?: [UIImage systemImageNamed:@"app.badge.fill"];
}

- (void)buildWelcomeView {
    PLThemeManager *theme = PLThemeManager.sharedManager;
    UIColor *background = [theme colorForToken:@"background" fallback:[theme colorFromHex:@"#E3EEF9"] ?: UIColor.whiteColor];
    UIColor *accent = [theme colorForToken:@"accent" fallback:UIColor.systemBlueColor];
    UIColor *surface = [theme colorForToken:@"surface" fallback:UIColor.secondarySystemBackgroundColor];
    UIColor *textPrimary = [theme colorForToken:@"textPrimary" fallback:UIColor.labelColor];
    UIColor *border = [theme colorForToken:@"border" fallback:UIColor.separatorColor];

    UIView *welcome = [[UIView alloc] init];
    welcome.translatesAutoresizingMaskIntoConstraints = NO;
    welcome.backgroundColor = background;
    [self.view addSubview:welcome];

    // 左半区布局锚（宽 45%），图标 + 标题在其垂直居中
    UILayoutGuide *leftGuide = [[UILayoutGuide alloc] init];
    [self.view addLayoutGuide:leftGuide];
    [leftGuide.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor].active = YES;
    [leftGuide.widthAnchor constraintEqualToAnchor:self.view.widthAnchor multiplier:0.45].active = YES;
    [leftGuide.topAnchor constraintEqualToAnchor:self.view.topAnchor].active = YES;
    [leftGuide.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor].active = YES;

    UIImageView *iconView = [[UIImageView alloc] initWithImage:PLUIWelcomeAppIcon()];
    iconView.translatesAutoresizingMaskIntoConstraints = NO;
    iconView.contentMode = UIViewContentModeScaleAspectFit;
    iconView.layer.cornerRadius = 28;
    iconView.clipsToBounds = YES;
    [iconView.widthAnchor constraintEqualToConstant:120].active = YES;
    [iconView.heightAnchor constraintEqualToConstant:120].active = YES;

    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.text = localize(@"uipack.welcome.title", nil);
    titleLabel.font = [UIFont systemFontOfSize:24 weight:UIFontWeightSemibold];
    titleLabel.textColor = textPrimary;
    titleLabel.textAlignment = NSTextAlignmentCenter;
    titleLabel.adjustsFontSizeToFitWidth = YES;

    UIStackView *leftStack = [[UIStackView alloc] initWithArrangedSubviews:@[iconView, titleLabel]];
    leftStack.translatesAutoresizingMaskIntoConstraints = NO;
    leftStack.axis = UILayoutConstraintAxisVertical;
    leftStack.spacing = 22;
    leftStack.alignment = UIStackViewAlignmentCenter;
    [welcome addSubview:leftStack];
    [leftStack.centerXAnchor constraintEqualToAnchor:leftGuide.centerXAnchor].active = YES;
    [leftStack.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor].active = YES;

    // 右侧按钮：导入 UI 包 / 获取 UI 包 /（切换旧引擎 | 问题反馈）
    UIButton *importButton = [UIButton buttonWithType:UIButtonTypeSystem];
    importButton.translatesAutoresizingMaskIntoConstraints = NO;
    [importButton setTitle:localize(@"uipack.welcome.import", nil) forState:UIControlStateNormal];
    [importButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    importButton.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    importButton.backgroundColor = accent;
    importButton.layer.cornerRadius = 12;
    [importButton addTarget:self action:@selector(welcomeImportTapped)
               forControlEvents:UIControlEventTouchUpInside];
    [importButton.heightAnchor constraintEqualToConstant:50].active = YES;
    [importButton.widthAnchor constraintEqualToConstant:260].active = YES;

    UIButton *getButton = [UIButton buttonWithType:UIButtonTypeSystem];
    getButton.translatesAutoresizingMaskIntoConstraints = NO;
    [getButton setTitle:localize(@"uipack.welcome.get", nil) forState:UIControlStateNormal];
    [getButton setTitleColor:accent forState:UIControlStateNormal];
    getButton.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightMedium];
    getButton.backgroundColor = surface;
    getButton.layer.cornerRadius = 12;
    getButton.layer.borderWidth = 1;
    getButton.layer.borderColor = border.CGColor;
    [getButton addTarget:self action:@selector(welcomeGetTapped)
        forControlEvents:UIControlEventTouchUpInside];
    [getButton.heightAnchor constraintEqualToConstant:50].active = YES;
    [getButton.widthAnchor constraintEqualToConstant:260].active = YES;

    UIButton *legacyButton = [UIButton buttonWithType:UIButtonTypeSystem];
    legacyButton.translatesAutoresizingMaskIntoConstraints = NO;
    [legacyButton setTitle:localize(@"uipack.welcome.legacy", nil) forState:UIControlStateNormal];
    [legacyButton setTitleColor:textPrimary forState:UIControlStateNormal];
    legacyButton.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    legacyButton.backgroundColor = surface;
    legacyButton.layer.cornerRadius = 10;
    [legacyButton addTarget:self action:@selector(welcomeLegacyTapped)
               forControlEvents:UIControlEventTouchUpInside];

    UIButton *feedbackButton = [UIButton buttonWithType:UIButtonTypeSystem];
    feedbackButton.translatesAutoresizingMaskIntoConstraints = NO;
    [feedbackButton setTitle:localize(@"uipack.welcome.feedback", nil) forState:UIControlStateNormal];
    [feedbackButton setTitleColor:accent forState:UIControlStateNormal];
    feedbackButton.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    feedbackButton.backgroundColor = surface;
    feedbackButton.layer.cornerRadius = 10;
    [feedbackButton addTarget:self action:@selector(welcomeFeedbackTapped)
               forControlEvents:UIControlEventTouchUpInside];

    UIStackView *pairStack = [[UIStackView alloc] initWithArrangedSubviews:@[legacyButton, feedbackButton]];
    pairStack.axis = UILayoutConstraintAxisHorizontal;
    pairStack.spacing = 12;
    pairStack.distribution = UIStackViewDistributionFillEqually;
    [pairStack.heightAnchor constraintEqualToConstant:44].active = YES;
    [pairStack.widthAnchor constraintEqualToConstant:260].active = YES;

    UIStackView *buttonStack = [[UIStackView alloc] initWithArrangedSubviews:@[importButton, getButton, pairStack]];
    buttonStack.translatesAutoresizingMaskIntoConstraints = NO;
    buttonStack.axis = UILayoutConstraintAxisVertical;
    buttonStack.spacing = 14;
    buttonStack.alignment = UIStackViewAlignmentCenter;
    [welcome addSubview:buttonStack];
    [buttonStack.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor].active = YES;
    [buttonStack.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-60].active = YES;

    [welcome.topAnchor constraintEqualToAnchor:self.view.topAnchor].active = YES;
    [welcome.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor].active = YES;
    [welcome.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor].active = YES;
    [welcome.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor].active = YES;
}

- (void)welcomeImportTapped {
    // public.item 同时覆盖 zip 与文件夹（import 模式下部分 iOS 版本的 public.folder 不可选）
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
        initWithDocumentTypes:@[@"public.zip", @"public.item"]
                       inMode:UIDocumentPickerModeImport];
    picker.delegate = self;
    picker.title = localize(@"uipack.welcome.import", nil);
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller
didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if (urls.count == 0) return;
    NSError *error = nil;
    if ([[PLUIPackManager sharedManager] importPackFromURL:urls.firstObject error:&error]) {
        // 导入成功：重走加载链，有包了 → 引擎渲染
        [self buildShell];
        return;
    }
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:localize(@"uipack.import.failed", nil)
                          message:error.localizedDescription ?: @""
                   preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"i18n_str_44", nil)
                                              style:UIAlertActionStyleDefault
                                            handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)welcomeGetTapped {
    // 获取 UI 包：跳转 Pear-ui 仓库 Releases（含 pcl2-totoro-blue 等材质包 zip）
    NSURL *url = [NSURL URLWithString:@"https://github.com/twoyears666/Pear-ui/releases"];
    if (!url) return;
    [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
}

- (void)welcomeLegacyTapped {
    setPrefObject(@"general.ui_shell", @"legacy");
    [[NSNotificationCenter defaultCenter] postNotificationName:@"UIShellChanged" object:@"legacy"];
}

- (void)welcomeFeedbackTapped {
    NSURL *url = [NSURL URLWithString:@"https://github.com/twoyears666/A-pear/issues"];
    if (!url) return;
    [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    // 欢迎界面跟随深浅色刷新（引擎路径由布局引擎自行处理）
    if (self.engine == nil &&
        previousTraitCollection.userInterfaceStyle != self.traitCollection.userInterfaceStyle) {
        [self buildShell];
    }
}

@end
