#pragma once

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

// Decoded preview payload. Building one is safe off the main thread, which
// matters because encoding detection on a large non-UTF-8 file takes seconds.
@interface RZPreviewContent : NSObject
+ (instancetype)contentForData:(NSData *)data name:(NSString *)name;
@end

@interface RZPreviewController : NSWindowController
@property (nonatomic, copy, nullable) BOOL (^keyHandler)(NSEvent *event);
@property (nonatomic, copy, nullable) void (^closeHandler)(void);
- (void)showLoading:(NSString *)name;
- (void)showContent:(RZPreviewContent *)content name:(NSString *)name;
- (void)showPlaceholder:(NSString *)name message:(NSString *)message;
- (void)presentRelativeTo:(NSWindow *)parent;
@end

NS_ASSUME_NONNULL_END
