#import "PLUIActionRouter.h"
#import "LauncherLaunchService.h"

/// 五类通用动作的专用通知名（由壳统一分发，引擎零页面名）。
static NSString * const PLUIActionNavigateNotif  = @"PLUIActionNavigate";   // object = page token
static NSString * const PLUIActionOpenSubpageNotif = @"PLUIActionOpenSubpage"; // object = subpage token
static NSString * const PLUIActionSwitchTabNotif  = @"PLUIActionSwitchTab"; // object = tab/branch key
static NSString * const PLUIActionSubmitNotif     = @"PLUIActionSubmit";    // object = form id
static NSString * const PLUIActionServiceNotif    = @"PLUIActionService";   // object = payload

/// 已由 LauncherLaunchService 接管的动作。
static NSSet<NSString *> *PLUIActionReservedForLaunchService(void) {
    static NSSet *actions;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        actions = [NSSet setWithArray:@[
            @"launch", @"pickVersion", @"executeJar", @"openDownloadCenter", @"selectAccount",
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

    // 启动链路 = 唯一特定于功能的特例（用户明确的豁免，禁止改动）。
    if ([action isEqualToString:@"launch"]) {
        [[LauncherLaunchService sharedService] launchGameFromViewController:presenter];
        return;
    }
    if ([PLUIActionReservedForLaunchService() containsObject:action]) {
        NSLog(@"[PLUIActionRouter] action '%@' reserved for LauncherLaunchService", action);
        return;
    }

    // 通用五类动作：只解析前缀，目标 token 全部来自 UI 包配置（引擎零页面名）。
    NSString *suffix = [self suffixAfterColon:action];
    if ([action hasPrefix:@"navigate:"] || [action hasPrefix:@"open:"]) {
        if (suffix && suffix.length > 0) {
            [[NSNotificationCenter defaultCenter] postNotificationName:PLUIActionNavigateNotif object:suffix];
        }
        return;
    }
    if ([action hasPrefix:@"open_subpage:"]) {
        if (suffix && suffix.length > 0) {
            [[NSNotificationCenter defaultCenter] postNotificationName:PLUIActionOpenSubpageNotif object:suffix];
        }
        return;
    }
    if ([action hasPrefix:@"switch_tab:"]) {
        if (suffix && suffix.length > 0) {
            [[NSNotificationCenter defaultCenter] postNotificationName:PLUIActionSwitchTabNotif object:suffix];
        }
        return;
    }
    if ([action hasPrefix:@"submit:"]) {
        if (suffix && suffix.length > 0) {
            [[NSNotificationCenter defaultCenter] postNotificationName:PLUIActionSubmitNotif object:suffix];
        }
        return;
    }
    if ([action hasPrefix:@"action:"]) {
        [[NSNotificationCenter defaultCenter] postNotificationName:PLUIActionServiceNotif object:suffix ?: @""];
        return;
    }

    // 未知/无前缀动作：log + no-op，绝不做动态 selector 派发。
    NSLog(@"[PLUIActionRouter] unknown action ignored: %@", action);
}

- (nullable NSString *)suffixAfterColon:(NSString *)action {
    NSRange colon = [action rangeOfString:@":"];
    if (colon.location == NSNotFound) return nil;
    return [action substringFromIndex:colon.location + 1];
}

@end