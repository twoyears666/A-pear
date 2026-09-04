#import "LauncherLaunchService.h"
#import "authenticator/BaseAuthenticator.h"
#import "PLProfiles.h"
#import "LauncherPreferences.h"
#import "MinecraftResourceDownloadTask.h"
#import "DownloadTaskManager.h"
#import "DownloadTaskItem.h"
#import "PLTaskProgressViewController.h"
#import "ALTServerConnection.h"
#import "ios_uikit_bridge.h"
#import "utils.h"

#include <sys/time.h>

static void *LaunchServiceProgressContext = &LaunchServiceProgressContext;

@interface LauncherLaunchService ()
@property (nonatomic, strong, nullable) MinecraftResourceDownloadTask *task;
// 从启动按钮进入账号登录，登录成功后（UpdateAccountInfo）自动续启。
@property (nonatomic, assign) BOOL pendingLaunchAfterLogin;
// 续启时用的宿主（弱引用，壳可能已重建）。
@property (nonatomic, weak, nullable) UIViewController *pendingPresenter;
@end

@implementation LauncherLaunchService

+ (instancetype)sharedService {
    static LauncherLaunchService *service;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        service = [LauncherLaunchService new];
    });
    return service;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        // 登录完成后续启（与旧壳右面板 updateAccountInfo 行为一致）
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(accountInfoUpdated:)
                                                     name:@"UpdateAccountInfo"
                                                   object:nil];
    }
    return self;
}

- (BOOL)isLaunchInProgress {
    return self.task != nil;
}

#pragma mark - 入口

- (void)launchGameFromViewController:(UIViewController *)presenter {
    // 下载中重复点击：打开统一进度页（与旧壳 launchButtonTapped 一致）
    if (self.task) {
        NSString *taskId = nil;
        for (DownloadTaskItem *item in [DownloadTaskManager sharedManager].allTasks) {
            if (item.rawTask == self.task) {
                taskId = item.taskId;
                break;
            }
        }
        if (taskId) [PLTaskProgressViewController presentForTaskId:taskId];
        return;
    }
    [self launchGame:presenter];
}

#pragma mark - 启动链路（自 LauncherRightPanelViewController 移植，行为保持一致）

- (void)launchGame:(UIViewController *)presenter {
    // 下载任务不阻断启动（Mod/光影下载与游戏本体无依赖，强制等待会卡死启动）。
    BaseAuthenticator *currentAuth = BaseAuthenticator.current;
    if (!currentAuth) {
        // 无账号：跳账号管理，登录成功后 UpdateAccountInfo 自动续启
        self.pendingLaunchAfterLogin = YES;
        self.pendingPresenter = presenter;
        [[NSNotificationCenter defaultCenter] postNotificationName:@"ShowAccountManager" object:nil];
        return;
    }
    self.pendingLaunchAfterLogin = NO;

    NSString *selectedProfile = PLProfiles.current.selectedProfileName;
    if (!selectedProfile) {
        [self showAlert:localize(@"i18n_str_431", nil) presenter:presenter];
        return;
    }

    NSString *versionId = PLProfiles.current.profiles[selectedProfile][@"lastVersionId"];
    if (!versionId) {
        [self showAlert:localize(@"i18n_str_43", nil) presenter:presenter];
        return;
    }

    // 记录最后游玩时间戳（版本管理页显示用）
    NSMutableDictionary *profiles = PLProfiles.current.profiles;
    NSMutableDictionary *profile = [profiles[selectedProfile] mutableCopy];
    if (profile) {
        profile[@"lastPlayed"] = @([[NSDate date] timeIntervalSince1970]);
        profiles[selectedProfile] = profile;
        [PLProfiles.current save];
    }

    UIApplication.sharedApplication.idleTimerDisabled = YES;

    // 版本对象经 FindVersionInRemoteList 请求壳的数据源（新旧壳都注册该通知）
    NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
    userInfo[@"versionId"] = versionId;
    userInfo[@"callback"] = ^(NSDictionary *version) {
        if (version) {
            [self startDownloadWithVersion:version presenter:presenter];
        } else {
            dispatch_async(dispatch_get_main_queue(), ^{
                UIApplication.sharedApplication.idleTimerDisabled = NO;
                [self showAlert:localize(@"i18n_str_432", nil) presenter:presenter];
            });
        }
    };
    [[NSNotificationCenter defaultCenter] postNotificationName:@"FindVersionInRemoteList"
                                                        object:nil
                                                      userInfo:userInfo];
}

- (void)startDownloadWithVersion:(NSDictionary *)versionObject presenter:(UIViewController *)presenter {
    self.task = [MinecraftResourceDownloadTask new];
    __weak LauncherLaunchService *weakSelf = self;

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        weakSelf.task.handleError = ^{
            dispatch_async(dispatch_get_main_queue(), ^{
                UIApplication.sharedApplication.idleTimerDisabled = NO;
                // KVO 清理防野指针（多次启动累积后崩溃的既有修复，行为保持一致）
                @try {
                    [weakSelf.task.progress removeObserver:weakSelf
                                                forKeyPath:@"fractionCompleted"
                                                   context:LaunchServiceProgressContext];
                } @catch (NSException *e) {}
                weakSelf.task = nil;
            });
        };

        [weakSelf.task downloadVersion:versionObject];

        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf.task.progress addObserver:weakSelf
                                    forKeyPath:@"fractionCompleted"
                                       options:NSKeyValueObservingOptionInitial
                                       context:LaunchServiceProgressContext];
            // 进度展示：downloadVersion 内部已注册统一进度页并 autoPresentDetail
        });
    });
}

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary *)change
                         context:(void *)context {
    if (context != LaunchServiceProgressContext) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }

    // 下载速度 / 剩余时间统计（textProgress 供统一进度页展示）
    static CGFloat lastMsTime;
    static NSUInteger lastSecTime, lastCompletedUnitCount;
    NSProgress *progress = self.task.textProgress;
    struct timeval tv;
    gettimeofday(&tv, NULL);
    NSInteger completedUnitCount = self.task.progress.totalUnitCount * self.task.progress.fractionCompleted;
    progress.completedUnitCount = completedUnitCount;
    if (lastSecTime < tv.tv_sec) {
        CGFloat currentTime = tv.tv_sec + tv.tv_usec / 1000000.0;
        NSInteger throughput = (completedUnitCount - lastCompletedUnitCount) / (currentTime - lastMsTime);
        progress.throughput = @(throughput);
        progress.estimatedTimeRemaining = @((progress.totalUnitCount - completedUnitCount) / throughput);
        lastCompletedUnitCount = completedUnitCount;
        lastSecTime = tv.tv_sec;
        lastMsTime = currentTime;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        if (!progress.finished || !self.task) return;

        // 完成即摘除 KVO（既有修复：防多次启动累积观察者）
        @try {
            [self.task.progress removeObserver:self
                                    forKeyPath:@"fractionCompleted"
                                       context:LaunchServiceProgressContext];
        } @catch (NSException *e) {}

        if (self.task.metadata) {
            // 应用档案特定设置（renderer/graphicsApi 由 JavaLauncher 直接解析 profile）
            NSString *profileName = PLProfiles.current.selectedProfileName;
            NSDictionary *profile = PLProfiles.current.profiles[profileName];
            if (profile) {
                // Java 版本（兼容旧版直装器的 NSDictionary 格式）
                id javaVerRaw = profile[@"javaVersion"];
                NSString *javaVer;
                if ([javaVerRaw isKindOfClass:NSDictionary.class]) {
                    id major = javaVerRaw[@"majorVersion"];
                    javaVer = major ? [major description] : @"auto";
                } else if ([javaVerRaw isKindOfClass:NSString.class]) {
                    javaVer = javaVerRaw;
                } else {
                    javaVer = @"auto";
                }
                if (![javaVer isEqualToString:@"auto"]) {
                    setPrefString(@"java.java_version", javaVer);
                }
                NSInteger allocatedMemory = [profile[@"allocatedMemory"] integerValue];
                if (allocatedMemory > 0) {
                    setPrefInt(@"general.ram_allocation", (int)allocatedMemory);
                }
            }
            [self invokeAfterJITEnabled:^{
                UIKit_launchMinecraftSurfaceVC(presenter.view.window, self.task.metadata);
            } presenter:presenter];
        } else {
            self.task = nil;
            UIApplication.sharedApplication.idleTimerDisabled = NO;
            [[NSNotificationCenter defaultCenter] postNotificationName:@"ReloadProfileList" object:nil];
        }
    });
}

- (void)accountInfoUpdated:(NSNotification *)notification {
    if (self.pendingLaunchAfterLogin && BaseAuthenticator.current) {
        self.pendingLaunchAfterLogin = NO;
        UIViewController *presenter = self.pendingPresenter;
        if (presenter) [self launchGame:presenter];
    } else if (self.pendingLaunchAfterLogin && !BaseAuthenticator.current) {
        // 用户取消了登录：清除待启动标记
        self.pendingLaunchAfterLogin = NO;
    }
}

#pragma mark - JIT 等待（自旧壳右面板移植）

- (void)invokeAfterJITEnabled:(void(^)(void))handler presenter:(UIViewController *)presenter {
    BOOL hasTrollStoreJIT = getEntitlementValue(@"jb.pmap_cs.custom_trust");

    if (isJITEnabled(false)) {
        [ALTServerManager.sharedManager stopDiscovering];
        handler();
        return;
    } else if (hasTrollStoreJIT) {
        NSURL *jitURL = [NSURL URLWithString:[NSString stringWithFormat:@"apple-magnifier://enable-jit?bundle-id=%@", NSBundle.mainBundle.bundleIdentifier]];
        [UIApplication.sharedApplication openURL:jitURL options:@{} completionHandler:nil];
    } else if (getPrefBool(@"debug.debug_skip_wait_jit")) {
        NSLog(@"Debug option skipped waiting for JIT. Java might not work.");
        handler();
        return;
    } else if (@available(iOS 17.4, *)) {
        NSString *scriptDataString = @"";
        if (DeviceNeedsDebugJITMapping()) {
            NSData *scriptData = [NSData dataWithContentsOfFile:[NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"UniversalJIT26.js"]];
            scriptDataString = [@"&script-data=" stringByAppendingString:[scriptData base64EncodedStringWithOptions:0]];
        }
        [UIApplication.sharedApplication openURL:[NSURL URLWithString:[NSString stringWithFormat:@"stikjit://enable-jit?bundle-id=%@&pid=%d%@", NSBundle.mainBundle.bundleIdentifier, getpid(), scriptDataString]] options:@{} completionHandler:nil];
    } else {
        // 16.7-17.3.1：SideStore 无 URL scheme，仅跳转 SideStore
        [UIApplication.sharedApplication openURL:[NSURL URLWithString:[NSString stringWithFormat:@"sidestore://sidejit-enable?pid=%d", getpid()]] options:@{} completionHandler:nil];
    }

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:localize(@"i18n_str_437", nil)
                                                                   message:hasTrollStoreJIT ? localize(@"i18n_str_2054", nil) : localize(@"i18n_str_439", nil)
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [presenter presentViewController:alert animated:YES completion:nil];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        while (!isJITEnabled(false)) {
            usleep(1000 * 200);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [alert dismissViewControllerAnimated:YES completion:handler];
        });
    });
}

- (void)showAlert:(NSString *)message presenter:(UIViewController *)presenter {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:localize(@"i18n_str_388", nil)
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"i18n_str_44", nil) style:UIAlertActionStyleDefault handler:nil]];
    [presenter presentViewController:alert animated:YES completion:nil];
}

@end
