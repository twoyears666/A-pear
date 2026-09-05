#import "PLUIActionRouter.h"
#import "LauncherLaunchService.h"
#import "PLProfiles.h"

/// 动作名 → Show* 通知名。内容区页面切换全部复用既有通知，零新增逻辑。
static NSDictionary<NSString *, NSString *> *PLUIActionNotificationMap(void) {
    static NSDictionary *map;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        map = @{
            @"open:home": @"ShowHomePage",
            @"open:download": @"ShowDownloadPage",
            @"open:versionManager": @"ShowVersionManager",
            @"open:settings": @"ShowSettings",
            @"open:ai": @"ShowAIPage",
            @"open:multiplayer": @"ShowMultiplayer",
            @"open:zeroTier": @"ShowMultiplayer",
            @"open:joinRoom": @"ShowMultiplayer",
            @"open:createRoom": @"ShowMultiplayer",
            @"open:more": @"ShowMorePage",
            @"open:mods": @"ShowModsManager",
            @"open:shaders": @"ShowShadersManager",
            @"open:modpackImport": @"ShowModpackImport",
            @"open:gameDirectory": @"ShowGameDirectory",
            @"open:accountManager": @"ShowAccountManager",
            @"open:profileEditor": @"ShowProfileEditor",
        };
    });
    return map;
}

/// 已由 LauncherLaunchService 接管的动作。
static NSSet<NSString *> *PLUIActionReservedForLaunchService(void) {
    static NSSet *actions;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        actions = [NSSet setWithArray:@[
            @"pickVersion", @"executeJar", @"openDownloadCenter", @"selectAccount",
        ]];
    });
    return actions;
}

@implementation PLUIActionRouter

+ (instancetype)sharedRouter {
    static PLUIActionRouter *router;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        router = [PLUIActionRouter new];
    });
    return router;
}

- (void)performAction:(NSString *)action fromViewController:(nullable UIViewController *)presenter {
    if (![action isKindOfClass:NSString.class] || action.length == 0) return;

    NSString *notificationName = PLUIActionNotificationMap()[action];
    if (notificationName) {
        // profileEditor 需要携带当前版本名（与旧壳 ShowProfileEditor 的 object 语义一致）
        id object = [action isEqualToString:@"open:profileEditor"]
            ? PLProfiles.current.selectedProfileName : nil;
        [[NSNotificationCenter defaultCenter] postNotificationName:notificationName object:object];
        return;
    }

    // M4：launch 动作接通真实启动链路（账号检查→版本解析→完整性下载→JIT→进游戏）
    if ([action isEqualToString:@"launch"]) {
        [[LauncherLaunchService sharedService] launchGameFromViewController:presenter];
        return;
    }

    if ([PLUIActionReservedForLaunchService() containsObject:action]) {
        NSLog(@"[PLUIActionRouter] action '%@' reserved for LauncherLaunchService (M4)", action);
        return;
    }

    // 未知动作：log + no-op，绝不做动态 selector 派发
    NSLog(@"[PLUIActionRouter] unknown action ignored: %@", action);
}

@end
