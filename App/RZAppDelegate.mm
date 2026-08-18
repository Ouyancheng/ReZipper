#import "RZAppDelegate.h"
#import "RZDocument.h"
#import "RZSheets.h"

@implementation RZAppDelegate

- (void)applicationWillFinishLaunching:(NSNotification *)notification {
    (void)notification;
    [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"NSQuitAlwaysKeepsWindows"];
    [RZAppDelegate installLibrary];
    [self buildMenu];
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    NSArray<NSString *> *args = NSProcessInfo.processInfo.arguments;
    BOOL openedFile = NO;
    for (NSUInteger i = 1; i < args.count; i++) {
        NSString *arg = args[i];
        if ([arg hasPrefix:@"-"]) {
            continue;
        }
        NSURL *url = [NSURL fileURLWithPath:arg];
        if ([[NSFileManager defaultManager] fileExistsAtPath:url.path]) {
            [[NSDocumentController sharedDocumentController] openDocumentWithContentsOfURL:url
                                                                                    display:YES
                                                                          completionHandler:^(NSDocument *doc, BOOL already, NSError *error) {
                (void)doc;
                (void)already;
                if (error) {
                    [NSApp presentError:error];
                }
            }];
            openedFile = YES;
        }
    }
    if (!openedFile) {
        NSArray<NSDocument *> *restored = [NSDocumentController.sharedDocumentController.documents copy];
        for (NSDocument *document in restored) {
            [document close];
        }
    }
}

- (BOOL)applicationSupportsSecureRestorableState:(NSApplication *)app {
    (void)app;
    return YES;
}

- (BOOL)applicationShouldRestoreApplicationState:(NSCoder *)coder {
    (void)coder;
    return NO;
}

- (BOOL)applicationShouldOpenUntitledFile:(NSApplication *)sender {
    (void)sender;
    return NO;
}

+ (void)installLibrary {
    NSString *bundled = [[NSBundle mainBundle].privateFrameworksPath stringByAppendingPathComponent:@"7z.so"];
    NSString *env = NSProcessInfo.processInfo.environment[@"REZIPPER_7Z_LIB"];
    NSString *path = env.length ? env : bundled;
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"7-Zip library missing";
        alert.informativeText = [NSString stringWithFormat:
            @"ReZipper could not find 7z.so at %@.\nBuild Format7zF and place it in Contents/Frameworks.", path];
        [alert runModal];
    }
    rz::Engine::instance().setLibraryPath(RZStd(path));
}

- (NSMenuItem *)rz_item:(NSString *)title
                 action:(SEL)action
                      key:(NSString *)key
                 symbol:(NSString *)symbol
                 target:(id)target {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:key];
    if (target) {
        item.target = target;
    }
    if (symbol.length) {
        item.image = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:title];
    }
    return item;
}

- (void)buildMenu {
    NSMenu *menubar = [[NSMenu alloc] init];
    NSApp.mainMenu = menubar;

    NSMenuItem *appItem = [[NSMenuItem alloc] init];
    [menubar addItem:appItem];
    NSMenu *appMenu = [[NSMenu alloc] initWithTitle:@"ReZipper"];
    appItem.submenu = appMenu;
    [appMenu addItem:[self rz_item:@"About ReZipper" action:@selector(showAbout:) key:@"" symbol:@"info.circle" target:self]];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItem:[self rz_item:@"Quit ReZipper" action:@selector(terminate:) key:@"q" symbol:@"power" target:nil]];

    NSMenuItem *fileItem = [[NSMenuItem alloc] init];
    [menubar addItem:fileItem];
    NSMenu *fileMenu = [[NSMenu alloc] initWithTitle:@"File"];
    fileItem.submenu = fileMenu;
    [fileMenu addItem:[self rz_item:@"New Archive…" action:@selector(createArchive:) key:@"n" symbol:@"plus.rectangle.on.folder" target:self]];
    [fileMenu addItem:[self rz_item:@"Open…" action:@selector(openDocument:) key:@"o" symbol:@"folder" target:nil]];
    [fileMenu addItem:[self rz_item:@"Close" action:@selector(performClose:) key:@"w" symbol:@"xmark.circle" target:nil]];
    [fileMenu addItem:[NSMenuItem separatorItem]];
    [fileMenu addItem:[self rz_item:@"Get Info" action:@selector(showInfo:) key:@"i" symbol:@"info.circle" target:nil]];

    NSMenuItem *editItem = [[NSMenuItem alloc] init];
    [menubar addItem:editItem];
    NSMenu *editMenu = [[NSMenu alloc] initWithTitle:@"Edit"];
    editItem.submenu = editMenu;
    [editMenu addItemWithTitle:@"Undo" action:@selector(undo:) keyEquivalent:@"z"];
    [editMenu addItemWithTitle:@"Redo" action:@selector(redo:) keyEquivalent:@"Z"];
    [editMenu addItem:[NSMenuItem separatorItem]];
    [editMenu addItemWithTitle:@"Cut" action:@selector(cut:) keyEquivalent:@"x"];
    [editMenu addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
    [editMenu addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"];
    [editMenu addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];

    NSMenuItem *archiveItem = [[NSMenuItem alloc] init];
    [menubar addItem:archiveItem];
    NSMenu *archiveMenu = [[NSMenu alloc] initWithTitle:@"Archive"];
    archiveItem.submenu = archiveMenu;
    [archiveMenu addItem:[self rz_item:@"Add Files…" action:@selector(addFiles:) key:@"" symbol:@"plus" target:nil]];
    [archiveMenu addItem:[self rz_item:@"Extract To…" action:@selector(extract:) key:@"e" symbol:@"square.and.arrow.down" target:nil]];
    [archiveMenu addItem:[self rz_item:@"Test Archive" action:@selector(testArchive:) key:@"t" symbol:@"checkmark.seal" target:nil]];
    [archiveMenu addItem:[self rz_item:@"View Selection" action:@selector(viewSelection:) key:@"" symbol:@"eye" target:nil]];
    [archiveMenu addItem:[self rz_item:@"Preview" action:@selector(togglePreview:) key:@"y" symbol:@"doc.text.magnifyingglass" target:nil]];
    [archiveMenu addItem:[NSMenuItem separatorItem]];
    [archiveMenu addItem:[self rz_item:@"Delete" action:@selector(deleteSelection:) key:@"" symbol:@"trash" target:nil]];

    NSMenuItem *windowItem = [[NSMenuItem alloc] init];
    [menubar addItem:windowItem];
    NSMenu *windowMenu = [[NSMenu alloc] initWithTitle:@"Window"];
    windowItem.submenu = windowMenu;
    [windowMenu addItemWithTitle:@"Minimize" action:@selector(performMiniaturize:) keyEquivalent:@"m"];
    [windowMenu addItemWithTitle:@"Zoom" action:@selector(performZoom:) keyEquivalent:@""];
    [windowMenu addItemWithTitle:@"Bring All to Front" action:@selector(arrangeInFront:) keyEquivalent:@""];
    NSApp.windowsMenu = windowMenu;

    NSMenuItem *helpItem = [[NSMenuItem alloc] init];
    [menubar addItem:helpItem];
    NSMenu *helpMenu = [[NSMenu alloc] initWithTitle:@"Help"];
    helpItem.submenu = helpMenu;
    [helpMenu addItem:[self rz_item:@"ReZipper Help" action:@selector(showHelp:) key:@"?" symbol:@"questionmark.circle" target:self]];
}

- (void)showAbout:(id)sender {
    (void)sender;
    NSMutableDictionary *options = [NSMutableDictionary dictionary];
    options[@"Credits"] = [[NSAttributedString alloc] initWithString:
        @"A native macOS frontend for the 7-Zip library.\n"
        @"Compression engine: 7-Zip 26.02 (Igor Pavlov).\n"
        @"C++ bindings: bit7z (Mozilla Public License 2.0)."];
    [NSApp orderFrontStandardAboutPanelWithOptions:options];
}

- (void)showHelp:(id)sender {
    (void)sender;
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"ReZipper";
    alert.informativeText = @"Open an archive to browse it like Finder. Use Add, Extract To, Test, View, and Delete in the toolbar — the same command layout as WinRAR, using macOS controls.\n\n"
        @"Press Space (or ⌘Y) to preview the selected file in memory without unpacking the archive to disk.\n\n"
        @"Supported write formats: 7z, zip, tar, gz, bz2, xz, wim.\n"
        @"Read formats include those plus rar, iso, cab, dmg, and other 7-Zip handlers.";
    [alert runModal];
}

- (void)createArchive:(id)sender {
    (void)sender;
    NSOpenPanel *openPanel = [NSOpenPanel openPanel];
    openPanel.canChooseFiles = YES;
    openPanel.canChooseDirectories = YES;
    openPanel.allowsMultipleSelection = YES;
    openPanel.prompt = @"Choose";
    openPanel.message = @"Choose the files and folders to compress.";
    [openPanel beginWithCompletionHandler:^(NSModalResponse result) {
        if (result != NSModalResponseOK || openPanel.URLs.count == 0) {
            return;
        }
        NSMutableArray<NSString *> *paths = [NSMutableArray array];
        for (NSURL *url in openPanel.URLs) {
            if (url.path) {
                [paths addObject:url.path];
            }
        }
        NSSavePanel *savePanel = [NSSavePanel savePanel];
        savePanel.title = @"Create Archive";
        savePanel.nameFieldStringValue = @"Archive.7z";
        savePanel.canCreateDirectories = YES;
        savePanel.prompt = @"Compress";
        RZCreateAccessory *accessory = [[RZCreateAccessory alloc] initAccessory];
        savePanel.accessoryView = accessory;
        [accessory syncAllowedFileTypes:savePanel];
        [savePanel beginWithCompletionHandler:^(NSModalResponse saveResult) {
            if (saveResult != NSModalResponseOK || !savePanel.URL.path) {
                return;
            }
            rz::CreateOptions options;
            options.format = accessory.format;
            options.level = accessory.compressionLevel;
            options.password = RZStd(accessory.password);
            options.encryptHeaders = accessory.encryptHeaders;
            options.solid = accessory.solid;
            NSString *archivePath = savePanel.URL.path;
            auto progress = std::make_shared<rz::Progress>();
            RZProgressController *sheet = [[RZProgressController alloc] init];
            [sheet setTitleText:@"Creating archive…"];
            [sheet setStatus:archivePath.lastPathComponent];
            [sheet setProgress:0 indeterminate:YES];
            sheet.cancelHandler = ^{ progress->cancel.store(true); };
            NSWindow *host = NSApp.keyWindow ?: NSApp.mainWindow;
            if (host) {
                [host beginSheet:sheet.window completionHandler:nil];
            } else {
                [sheet.window center];
                [sheet.window makeKeyAndOrderFront:nil];
            }
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                NSError *error = nil;
                try {
                    std::vector<std::string> input;
                    for (NSString *path in paths) {
                        input.push_back(RZStd(path));
                    }
                    rz::Engine::instance().create(RZStd(archivePath), input, options, progress);
                } catch (const std::exception& ex) {
                    error = RZErrorFromException(ex);
                }
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (host) {
                        [host endSheet:sheet.window];
                    } else {
                        [sheet.window close];
                    }
                    if (error) {
                        [NSApp presentError:error];
                        return;
                    }
                    [[NSDocumentController sharedDocumentController]
                        openDocumentWithContentsOfURL:[NSURL fileURLWithPath:archivePath]
                                              display:YES
                                    completionHandler:^(NSDocument *doc, BOOL already, NSError *openError) {
                        (void)doc;
                        (void)already;
                        if (openError) {
                            [NSApp presentError:openError];
                        }
                    }];
                });
            });
        }];
    }];
}

@end
