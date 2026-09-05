#import "PLUIMoreViewController.h"
#import "BackgroundManager.h"
#import "BackgroundSettingsViewController.h"
#import "WorldsManagerViewController.h"
#import "utils.h"

/// 行为：发 Show* 通知（切内容页）/ push 既有 VC / 打开链接 / 纯展示。
typedef NS_ENUM(uint8_t, PLUIMoreRowKind) {
    PLUIMoreRowKindNotification = 0,
    PLUIMoreRowKindPush,
    PLUIMoreRowKindLink,
    PLUIMoreRowKindStatic,
};

@interface PLUIMoreViewController ()
@property (nonatomic, strong) NSArray<NSArray<NSDictionary *> *> *sections;
@end

@implementation PLUIMoreViewController

- (instancetype)initWithStyle:(UITableViewStyle)style {
    self = [super initWithStyle:style];
    if (self) {
        self.title = localize(@"uipack.more.title", nil);
        self.sections = @[
            // 资源管理：复用旧引擎资源页（与首页快捷入口同一批 VC/通知）
            @[
                @{ @"icon": @"puzzlepiece.fill",
                   @"title": @"uipack.more.mods",
                   @"kind": @(PLUIMoreRowKindNotification), @"action": @"ShowModsManager" },
                @{ @"icon": @"camera.aperture",
                   @"title": @"uipack.more.shaders",
                   @"kind": @(PLUIMoreRowKindNotification), @"action": @"ShowShadersManager" },
                @{ @"icon": @"shippingbox.fill",
                   @"title": @"uipack.more.modpacks",
                   @"kind": @(PLUIMoreRowKindNotification), @"action": @"ShowModpackImport" },
                @{ @"icon": @"globe.asia.australia.fill",
                   @"title": @"uipack.more.worlds",
                   @"kind": @(PLUIMoreRowKindPush), @"vc": @"worlds" },
            ],
            // 个性化：壁纸设置（含背景透明度滑条，实时调节并保存）
            @[
                @{ @"icon": @"photo.fill",
                   @"title": @"uipack.more.wallpaper",
                   @"kind": @(PLUIMoreRowKindPush), @"vc": @"wallpaper" },
            ],
            // 关于与日志
            @[
                @{ @"icon": @"info.circle.fill",
                   @"title": @"uipack.more.version",
                   @"kind": @(PLUIMoreRowKindStatic), @"detail": [self versionDetail] },
                @{ @"icon": @"square.and.arrow.up.fill",
                   @"title": @"uipack.more.repository",
                   @"kind": @(PLUIMoreRowKindLink), @"url": @"https://github.com/twoyears666/A-pear" },
                @{ @"icon": @"exclamationmark.bubble.fill",
                   @"title": @"uipack.more.feedback",
                   @"kind": @(PLUIMoreRowKindLink), @"url": @"https://github.com/twoyears666/A-pear/issues" },
                @{ @"icon": @"doc.text.fill",
                   @"title": @"uipack.more.logs",
                   @"kind": @(PLUIMoreRowKindPush), @"vc": @"logs" },
            ],
        ];
    }
    return self;
}

- (NSString *)versionDetail {
    NSString *version = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    NSString *build = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"];
    if (version && build) return [NSString stringWithFormat:@"%@ (%@)", version, build];
    return version ?: @"Pear";
}

#pragma mark - Table data source

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return self.sections.count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.sections[section].count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case 0: return localize(@"uipack.more.section.resources", nil);
        case 1: return localize(@"uipack.more.section.personalize", nil);
        case 2: return localize(@"uipack.more.section.about", nil);
        default: return nil;
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *row = self.sections[indexPath.section][indexPath.row];
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"MoreRow"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"MoreRow"];
    }
    cell.imageView.image = [UIImage systemImageNamed:row[@"icon"]];
    cell.textLabel.text = localize(row[@"title"], nil);
    cell.detailTextLabel.text = row[@"detail"];
    cell.accessoryType = [row[@"kind"] intValue] == PLUIMoreRowKindStatic
        ? UITableViewCellAccessoryNone : UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

#pragma mark - Table delegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *row = self.sections[indexPath.section][indexPath.row];
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    switch ([row[@"kind"] intValue]) {
        case PLUIMoreRowKindNotification:
            // 与顶栏页签同一条路由：复用 Show* 通知切换内容区
            [[NSNotificationCenter defaultCenter] postNotificationName:row[@"action"] object:nil];
            break;
        case PLUIMoreRowKindPush: {
            UIViewController *vc = [self viewControllerForKey:row[@"vc"]];
            if (vc) [self.navigationController pushViewController:vc animated:YES];
            break;
        }
        case PLUIMoreRowKindLink: {
            NSURL *url = [NSURL URLWithString:row[@"url"]];
            if (url) [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
            break;
        }
        case PLUIMoreRowKindStatic:
            break;
    }
}

- (nullable UIViewController *)viewControllerForKey:(NSString *)key {
    if ([key isEqualToString:@"worlds"]) {
        return [[WorldsManagerViewController alloc] init];
    }
    if ([key isEqualToString:@"wallpaper"]) {
        return [[BackgroundSettingsViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    }
    if ([key isEqualToString:@"logs"]) {
        return [self logViewerViewController];
    }
    return nil;
}

/// 日志查看页：优先游戏日志（POJAV_GAME_DIR/logs/latest.log），
/// 回退启动器日志（POJAV_HOME/latestlog.txt），展示末尾内容（等宽字体）。
- (UIViewController *)logViewerViewController {
    UIViewController *vc = [[UIViewController alloc] init];
    vc.title = localize(@"uipack.more.logs", nil);
    vc.view.backgroundColor = [UIColor clearColor];

    UITextView *textView = [[UITextView alloc] init];
    textView.translatesAutoresizingMaskIntoConstraints = NO;
    textView.editable = NO;
    textView.selectable = YES;
    textView.font = [UIFont fontWithName:@"Menlo" size:11] ?: [UIFont systemFontOfSize:11];
    textView.textColor = UIColor.labelColor;
    textView.backgroundColor = [UIColor clearColor];
    textView.text = [self latestLogContent];
    [vc.view addSubview:textView];
    [NSLayoutConstraint activateConstraints:@[
        [textView.topAnchor constraintEqualToAnchor:vc.view.layoutMarginsGuide.topAnchor],
        [textView.bottomAnchor constraintEqualToAnchor:vc.view.bottomAnchor],
        [textView.leadingAnchor constraintEqualToAnchor:vc.view.leadingAnchor constant:12],
        [textView.trailingAnchor constraintEqualToAnchor:vc.view.trailingAnchor constant:-12],
    ]];
    [textView scrollRangeToVisible:NSMakeRange(textView.text.length, 0)];
    return vc;
}

- (NSString *)latestLogContent {
    NSMutableArray<NSString *> *candidates = [NSMutableArray array];
    const char *gameDir = getenv("POJAV_GAME_DIR");
    if (gameDir) {
        [candidates addObject:[NSString stringWithFormat:@"%s/logs/latest.log", gameDir]];
    }
    const char *pojavHome = getenv("POJAV_HOME");
    if (pojavHome) {
        [candidates addObject:[NSString stringWithFormat:@"%s/latestlog.txt", pojavHome]];
    }
    for (NSString *path in candidates) {
        NSString *content = [NSString stringWithContentsOfFile:path
                                                      encoding:NSUTF8StringEncoding
                                                         error:nil];
        if (content.length == 0) continue;
        if (content.length > 32000) {
            content = [@"…\n" stringByAppendingString:[content substringFromIndex:content.length - 32000]];
        }
        return content;
    }
    return localize(@"uipack.more.logs.empty", nil);
}

@end
