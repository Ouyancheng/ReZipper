#import <Cocoa/Cocoa.h>
#import "RZAppDelegate.h"
#import "RZDocument.h"

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        NSApp.activationPolicy = NSApplicationActivationPolicyRegular;

        RZAppDelegate *delegate = [[RZAppDelegate alloc] init];
        NSApp.delegate = delegate;
        [RZAppDelegate installLibrary];

        [NSDocumentController sharedDocumentController];
        [NSApp run];
        (void)argc;
        (void)argv;
    }
    return 0;
}
