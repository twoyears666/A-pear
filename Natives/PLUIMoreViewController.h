#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// PCL2「更多」页：聚合二级功能入口。
/// 顶栏五个页签（启动/下载/联机/设置/更多）中「更多」的落地页，
/// 复用旧引擎既有功能页（Mod/光影/整合包/世界管理、壁纸设置、联机大厅），
/// 并提供关于（版本/开源仓库/问题反馈）与游戏日志入口。
/// 行为契约：行点击只发 Show* 通知或 push 既有 VC，不引入新业务逻辑。
@interface PLUIMoreViewController : UITableViewController

@end

NS_ASSUME_NONNULL_END
