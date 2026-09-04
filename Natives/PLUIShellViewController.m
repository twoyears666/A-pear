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
#import "ShadersManagerViewController.h"
#import "ModpackImportViewController.h"
#import "LauncherPrefGameDirViewController.h"
#import "AccountListViewController.h"
#import "AI/AIViewController.h"
#import "AI/AiSessionStore.h"
#import "authenticator/BaseAuthenticator.h"

@interface PLUIShellViewController () <UINavigationControllerDelegate>
@property (nonatomic, strong) PLUILayoutEngine *engine;
@property (nonatomic, strong) PLLuaRuntime *runtime;
@property (nonatomic, strong) PLUINodeView *contentNode;
@property (nonatomic, strong) UIViewController *contentViewController;
@property (nonatomic, strong) NSArray<NSLayoutConstraint *> *currentContentConstraints;
@property (nonatomic, assign) BOOL isShowingProfileEditor;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *localVersionList;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *remoteVersionList;
@end

@implementation PLUIShellViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
    [self buildShell];
    [self registerNotifications];
    [self initializeVersionLists];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - 材质包加载与渲染

- (void)buildShell {
    for (UIView *sub in [self.view.subviews copy]) [sub removeFromSuperview];
    self.contentNode = nil;
    self.engine = nil;
    self.runtime = nil;

    // 回退链：选中包 → 程序化默认树（包缺失/脚本坏/树非法都落到这里）
    [PLUIPackManager.sharedManager reload];
    PLUIPack *pack = PLUIPackManager.sharedManager.activePack;
    NSDictionary *tree = nil;
    if (pack) {
        NSString *source = [PLUIPackManager.sharedManager mainLuaSourceForPack:pack];
        if (source) {
            NSError *error = nil;
            PLLuaRuntime *runtime = [[PLLuaRuntime alloc] initWithPack:pack scriptSource:source error:&error];
            if (runtime) {
                tree = [runtime buildTreeWithError:&error];
                if (tree) self.runtime = runtime;
            }
        }
    }

    PLUILayoutEngine *engine = [PLUILayoutEngine engineWithTree:tree];
    PLUINodeView *root = [engine buildRootViewInHost:self.view traitCollection:self.traitCollection];
    if (!root) {
        // 连程序化默认树都构建失败：视为引擎 bug，抛给 SceneDelegate 的 @try 换回旧壳
        [NSException raise:@"PLUIShellBuildFailed" format:@"layout engine failed to build root view"];
    }
    self.engine = engine;

    [self.engine enumerateNodes:^(PLUINodeView *node) {
        if (node.isContentArea) self.contentNode = node;
    }];
    [self wireActions];
    [self wireRuntime];
    [self showInitialPage];
    [self refreshStateAndNotifyReady];
}

- (void)wireActions {
    __weak typeof(self) weakSelf = self;
    [self.engine enumerateNodes:^(PLUINodeView *node) {
        if (!node.action) return;
        node.tapHandler = ^(PLUINodeView *tapped) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            [PLUIActionRouter.sharedRouter performAction:tapped.action
                                     fromViewController:strongSelf];
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
            node.hidden = ![argument boolValue];
        } else if ([command isEqualToString:@"setEnabled"]) {
            [node updateEnabled:[argument boolValue]];
        }
        return YES;
    };
    self.runtime.viewTextHandler = ^NSString *(NSString *viewId) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        return [strongSelf.engine viewForId:viewId].currentText;
    };
}

- (void)showInitialPage {
    if (!self.contentNode) return;
    NSString *page = self.contentNode.initialPage;
    if ([page isEqualToString:@"download"]) {
        [self showDownloadPage];
    } else if ([page isEqualToString:@"versionManager"]) {
        [self showVersionManager];
    } else if ([page isEqualToString:@"settings"]) {
        [self showSettings];
    } else if ([page isEqualToString:@"ai"]) {
        [self showAIPage];
    } else {
        [self showHomePage];
    }
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
        @"darkMode": @(self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark),
        @"locale": [NSLocale currentLocale].localeIdentifier ?: @"",
    };
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
    on(@"ShowZeroTier", @selector(showZeroTier));
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
    LauncherNewsViewController *newsVC = [[LauncherNewsViewController alloc] init];
    [self setContentViewController:newsVC animated:YES];
}

- (void)showDownloadPage {
    DownloadViewController *downloadVC = [[DownloadViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:downloadVC];
    nav.navigationBar.prefersLargeTitles = NO;
    [self setContentViewController:nav animated:YES];
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
    LauncherPreferencesViewController *vc = [[LauncherPreferencesViewController alloc] init];
    UINavigationController *navVC = [[UINavigationController alloc] initWithRootViewController:vc];
    navVC.navigationBar.prefersLargeTitles = YES;
    [self setContentViewController:navVC animated:YES];
}

- (void)showAIPage {
    AiSession *session = [[AiSessionStore sharedStore] lastActiveSession];
    AIViewController *vc = [[AIViewController alloc] initWithSession:session];
    UINavigationController *navVC = [[UINavigationController alloc] initWithRootViewController:vc];
    navVC.navigationBar.prefersLargeTitles = NO;
    [self setContentViewController:navVC animated:YES];
}

- (void)showMultiplayer {
    [PLUIActionRouter.sharedRouter performAction:@"open:multiplayer" fromViewController:self];
}

- (void)showZeroTier {
    [PLUIActionRouter.sharedRouter performAction:@"open:zeroTier" fromViewController:self];
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
}

- (void)uiEffectChanged:(NSNotification *)notification {
    // 对根容器的直接子节点（侧栏/面板等容器节点）重应用毛玻璃
    for (PLUINodeView *child in self.engine.rootView.subviews) {
        if ([child isKindOfClass:PLUINodeView.class]) {
            [[BackgroundManager sharedManager] applyEffectToView:child];
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

@end
