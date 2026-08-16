#pragma once

#import <Cocoa/Cocoa.h>

@interface RZAppDelegate : NSObject <NSApplicationDelegate>
+ (void)installLibrary;
- (void)createArchive:(id)sender;
@end
