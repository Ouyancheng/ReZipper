#pragma once

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface RZPreviewController : NSWindowController
@property (nonatomic, copy, nullable) BOOL (^keyHandler)(NSEvent *event);
@property (nonatomic, copy, nullable) void (^closeHandler)(void);
- (void)showLoading:(NSString *)name;
- (void)showData:(NSData *)data name:(NSString *)name;
- (void)showPlaceholder:(NSString *)name message:(NSString *)message;
- (void)presentRelativeTo:(NSWindow *)parent;
@end

NS_ASSUME_NONNULL_END
