#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// M4 启动服务：把旧壳右面板的启动链路（账号检查 → 版本解析 → 资源完整性
/// 下载 → JIT 等待 → 进游戏）抽成与壳无关的服务。Lua UI 引擎的 launch 动作
/// 与旧壳右面板共用同一套逻辑，行为（含登录后续启、下载不阻断、KVO 清理）
/// 与 LauncherRightPanelViewController 保持一致。
@interface LauncherLaunchService : NSObject

+ (instancetype)sharedService;

/// 当前是否有启动前的资源下载任务进行中（启动按钮防重入）。
@property (nonatomic, readonly) BOOL isLaunchInProgress;

/// 从当前选中档案启动游戏。
/// presenter：alert / JIT 等待框 / 统一进度页的呈现宿主（Lua 引擎壳或旧壳）。
- (void)launchGameFromViewController:(UIViewController *)presenter;

@end

NS_ASSUME_NONNULL_END
