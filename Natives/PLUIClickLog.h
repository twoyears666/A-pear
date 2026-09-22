// 点击链路诊断日志（调试用）。
// 写到 POJAV_HOME/clicktrace.log（同时 NSLog），便于手机/模拟器上直接查看点击链路每一环。
// header-only：多个 TU 各自持有一份 static inline 实现，写入同一文件，无需改 CMake 源列表。
#import <Foundation/Foundation.h>
#import <stdlib.h>

static inline void PLUIClickLog(NSString *format, ...) {
    @autoreleasepool {
        va_list args;
        va_start(args, format);
        NSString *line = [[NSString alloc] initWithFormat:format arguments:args];
        va_end(args);

        NSLog(@"[ClickTrace] %@", line);

        NSString *home = getenv("POJAV_HOME") ? [NSString stringWithUTF8String:getenv("POJAV_HOME")] : @"";
        if (home.length == 0) return;
        NSString *path = [home stringByAppendingPathComponent:@"clicktrace.log"];
        NSString *ts = [NSDateFormatter localizedStringFromDate:[NSDate date]
                                                      dateStyle:NSDateFormatterNoStyle
                                                      timeStyle:NSDateFormatterMediumStyle];
        NSString *entry = [NSString stringWithFormat:@"%@ %@\n", ts, line];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!fh) {
            [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
            fh = [NSFileHandle fileHandleForWritingAtPath:path];
        }
        @try {
            [fh seekToEndOfFile];
            [fh writeData:[entry dataUsingEncoding:NSUTF8StringEncoding]];
        }
        @catch (NSException *e) { /* 忽略写入失败，不影响 UI */ }
        @finally { [fh closeFile]; }
    }
}