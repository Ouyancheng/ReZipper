#pragma once

#import <Cocoa/Cocoa.h>
#import "RZCommon.h"

NS_ASSUME_NONNULL_BEGIN

@interface RZProgressController : NSWindowController
@property (nonatomic, copy) void (^cancelHandler)(void);
- (void)setTitleText:(NSString *)title;
- (void)setStatus:(NSString *)status;
- (void)setProgress:(double)fraction indeterminate:(BOOL)indeterminate;
@end

@interface RZPasswordController : NSWindowController
@property (nonatomic, copy, readonly) NSString *password;
- (NSModalResponse)runSheetForWindow:(NSWindow *)window message:(NSString *)message;
@end

@interface RZInfoController : NSWindowController
- (void)presentForDocument:(NSDocument *)document onWindow:(NSWindow *)window;
@end

@interface RZCreateAccessory : NSView
@property (nonatomic, readonly) rz::Format format;
@property (nonatomic, readonly) int compressionLevel;
@property (nonatomic, readonly, copy) NSString *password;
@property (nonatomic, readonly) BOOL encryptHeaders;
@property (nonatomic, readonly) BOOL solid;
- (instancetype)initAccessory;
- (void)syncAllowedFileTypes:(NSSavePanel *)panel;
@end

NS_ASSUME_NONNULL_END
