#import "RZSheets.h"
#import "RZDocument.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static void RZApplyDialogButton(NSButton *button) {
    button.bezelStyle = NSBezelStyleRounded;
    button.controlSize = NSControlSizeRegular;
}

#pragma mark - Progress

@interface RZProgressController ()
@property (nonatomic, strong) NSTextField *titleField;
@property (nonatomic, strong) NSTextField *statusField;
@property (nonatomic, strong) NSProgressIndicator *bar;
@property (nonatomic, strong) NSButton *cancelButton;
@end

@implementation RZProgressController

- (instancetype)init {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 420, 148)
                                                   styleMask:NSWindowStyleMaskTitled
                                                     backing:NSBackingStoreBuffered
                                                       defer:YES];
    window.title = @"ReZipper";
    self = [super initWithWindow:window];
    if (!self) {
        return nil;
    }

    NSView *content = window.contentView;
    NSTextField *title = [NSTextField labelWithString:@"Working…"];
    title.font = [NSFont boldSystemFontOfSize:13];
    title.translatesAutoresizingMaskIntoConstraints = NO;

    NSTextField *status = [NSTextField wrappingLabelWithString:@"Preparing"];
    status.textColor = NSColor.secondaryLabelColor;
    status.translatesAutoresizingMaskIntoConstraints = NO;

    NSProgressIndicator *bar = [[NSProgressIndicator alloc] initWithFrame:NSZeroRect];
    bar.style = NSProgressIndicatorStyleBar;
    bar.indeterminate = YES;
    bar.translatesAutoresizingMaskIntoConstraints = NO;

    NSButton *cancel = [NSButton buttonWithTitle:@"Cancel" target:self action:@selector(cancel:)];
    cancel.keyEquivalent = @"\033";
    cancel.translatesAutoresizingMaskIntoConstraints = NO;
    RZApplyDialogButton(cancel);

    [content addSubview:title];
    [content addSubview:status];
    [content addSubview:bar];
    [content addSubview:cancel];

    [NSLayoutConstraint activateConstraints:@[
        [title.topAnchor constraintEqualToAnchor:content.topAnchor constant:18],
        [title.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:20],
        [title.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-20],
        [status.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:8],
        [status.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
        [status.trailingAnchor constraintEqualToAnchor:title.trailingAnchor],
        [bar.topAnchor constraintEqualToAnchor:status.bottomAnchor constant:14],
        [bar.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
        [bar.trailingAnchor constraintEqualToAnchor:title.trailingAnchor],
        [cancel.topAnchor constraintEqualToAnchor:bar.bottomAnchor constant:16],
        [cancel.trailingAnchor constraintEqualToAnchor:title.trailingAnchor],
        [cancel.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-16],
    ]];

    self.titleField = title;
    self.statusField = status;
    self.bar = bar;
    self.cancelButton = cancel;
    return self;
}

- (void)setTitleText:(NSString *)title {
    self.titleField.stringValue = title ?: @"";
}

- (void)setStatus:(NSString *)status {
    self.statusField.stringValue = status ?: @"";
}

- (void)setProgress:(double)fraction indeterminate:(BOOL)indeterminate {
    self.bar.indeterminate = indeterminate;
    if (indeterminate) {
        [self.bar startAnimation:nil];
    } else {
        [self.bar stopAnimation:nil];
        self.bar.minValue = 0;
        self.bar.maxValue = 1;
        self.bar.doubleValue = MAX(0.0, MIN(1.0, fraction));
    }
}

- (void)cancel:(id)sender {
    (void)sender;
    self.cancelButton.enabled = NO;
    if (self.cancelHandler) {
        self.cancelHandler();
    }
}

@end

#pragma mark - Password

@interface RZPasswordController ()
@property (nonatomic, copy, readwrite) NSString *password;
@end

@implementation RZPasswordController

- (instancetype)init {
    self = [super initWithWindow:nil];
    if (self) {
        _password = @"";
    }
    return self;
}

- (NSModalResponse)runSheetForWindow:(NSWindow *)window message:(NSString *)message {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Password";
    alert.informativeText = message.length ? message : @"This archive is encrypted.";
    [alert addButtonWithTitle:@"OK"];
    [alert addButtonWithTitle:@"Cancel"];
    alert.alertStyle = NSAlertStyleInformational;

    NSSecureTextField *field = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(0, 0, 260, 24)];
    field.placeholderString = @"Password";
    field.stringValue = @"";
    alert.accessoryView = field;
    alert.window.initialFirstResponder = field;

    NSModalResponse result = NSAlertSecondButtonReturn;
    if (window.visible && window.attachedSheet == nil) {
        __block NSModalResponse sheetResult = NSAlertSecondButtonReturn;
        [alert beginSheetModalForWindow:window completionHandler:^(NSModalResponse returnCode) {
            sheetResult = returnCode;
            [NSApp stopModal];
        }];
        [NSApp runModalForWindow:window];
        result = sheetResult;
    } else {
        result = [alert runModal];
    }

    if (result == NSAlertFirstButtonReturn) {
        self.password = field.stringValue ?: @"";
        return NSModalResponseOK;
    }
    self.password = @"";
    return NSModalResponseCancel;
}

@end

#pragma mark - Info

@interface RZInfoController () <NSWindowDelegate>
@property (nonatomic, strong) NSTextField *body;
@end

@implementation RZInfoController

- (instancetype)init {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 440, 300)
                                                   styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                                     backing:NSBackingStoreBuffered
                                                       defer:YES];
    window.title = @"Archive Info";
    self = [super initWithWindow:window];
    if (!self) {
        return nil;
    }
    window.delegate = self;

    NSTextField *body = [NSTextField wrappingLabelWithString:@""];
    body.font = [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightRegular];
    body.translatesAutoresizingMaskIntoConstraints = NO;

    NSButton *done = [NSButton buttonWithTitle:@"Done" target:self action:@selector(dismiss:)];
    done.keyEquivalent = @"\r";
    done.translatesAutoresizingMaskIntoConstraints = NO;
    RZApplyDialogButton(done);

    [window.contentView addSubview:body];
    [window.contentView addSubview:done];
    [NSLayoutConstraint activateConstraints:@[
        [body.topAnchor constraintEqualToAnchor:window.contentView.topAnchor constant:20],
        [body.leadingAnchor constraintEqualToAnchor:window.contentView.leadingAnchor constant:20],
        [body.trailingAnchor constraintEqualToAnchor:window.contentView.trailingAnchor constant:-20],
        [done.topAnchor constraintGreaterThanOrEqualToAnchor:body.bottomAnchor constant:16],
        [done.trailingAnchor constraintEqualToAnchor:window.contentView.trailingAnchor constant:-20],
        [done.bottomAnchor constraintEqualToAnchor:window.contentView.bottomAnchor constant:-16],
    ]];
    self.body = body;
    return self;
}

- (void)presentForDocument:(NSDocument *)document onWindow:(NSWindow *)window {
    RZDocument *doc = (RZDocument *)document;
    NSByteCountFormatter *bytes = [[NSByteCountFormatter alloc] init];
    bytes.countStyle = NSByteCountFormatterCountStyleFile;
    NSMutableString *text = [NSMutableString string];
    if (doc.nestTitle.length) {
        [text appendFormat:@"Name: %@\n", doc.nestTitle];
        [text appendFormat:@"Path: %@ → %@\n", doc.nestRootPath, doc.nestTitle];
    } else {
        [text appendFormat:@"Name: %@\n", doc.fileURL.lastPathComponent];
        [text appendFormat:@"Path: %@\n", doc.fileURL.path];
    }
    [text appendFormat:@"Format: %@\n", doc.formatName];
    [text appendFormat:@"Files: %lu\n", (unsigned long)doc.fileCount];
    [text appendFormat:@"Folders: %lu\n", (unsigned long)doc.folderCount];
    [text appendFormat:@"Size: %@\n", [bytes stringFromByteCount:(long long)doc.totalSize]];
    [text appendFormat:@"Packed: %@\n", [bytes stringFromByteCount:(long long)doc.packedSize]];
    [text appendFormat:@"Encrypted: %@\n", doc.encrypted ? @"Yes" : @"No"];
    [text appendFormat:@"Solid: %@\n", doc.solid ? @"Yes" : @"No"];
    [text appendFormat:@"Writable: %@\n", doc.canUpdate ? @"Yes" : @"Read-only"];
    self.body.stringValue = text;
    __weak RZInfoController *weakSelf = self;
    [window beginSheet:self.window completionHandler:^(NSModalResponse returnCode) {
        (void)returnCode;
        (void)weakSelf;
    }];
}

- (void)dismiss:(id)sender {
    (void)sender;
    NSWindow *parent = self.window.sheetParent;
    if (parent) {
        [parent endSheet:self.window returnCode:NSModalResponseOK];
    } else {
        [self.window close];
    }
}

- (BOOL)windowShouldClose:(NSWindow *)sender {
    (void)sender;
    [self dismiss:nil];
    return NO;
}

- (void)cancelOperation:(id)sender {
    (void)sender;
    [self dismiss:nil];
}

@end

#pragma mark - Create accessory

@interface RZCreateAccessory ()
@property (nonatomic, strong) NSPopUpButton *formatPopup;
@property (nonatomic, strong) NSPopUpButton *levelPopup;
@property (nonatomic, strong) NSSecureTextField *passwordField;
@property (nonatomic, strong) NSButton *encryptHeadersButton;
@property (nonatomic, strong) NSButton *solidButton;
@end

@implementation RZCreateAccessory

- (instancetype)initAccessory {
    self = [super initWithFrame:NSMakeRect(0, 0, 420, 204)];
    if (!self) {
        return nil;
    }
    self.autoresizingMask = NSViewWidthSizable;

    NSTextField *formatLabel = [NSTextField labelWithString:@"Format:"];
    NSPopUpButton *format = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [format addItemsWithTitles:@[@"7-Zip (*.7z)", @"ZIP (*.zip)", @"TAR (*.tar)", @"GZip (*.gz)", @"BZip2 (*.bz2)", @"XZ (*.xz)", @"WIM (*.wim)"]];
    format.target = self;
    format.action = @selector(formatChanged:);

    NSTextField *levelLabel = [NSTextField labelWithString:@"Compression:"];
    NSPopUpButton *level = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [level addItemsWithTitles:@[@"Store", @"Fastest", @"Fast", @"Normal", @"Maximum", @"Ultra"]];
    [level selectItemAtIndex:3];

    NSTextField *passwordLabel = [NSTextField labelWithString:@"Password:"];
    NSSecureTextField *password = [[NSSecureTextField alloc] initWithFrame:NSZeroRect];
    password.placeholderString = @"Optional";

    NSButton *encrypt = [NSButton checkboxWithTitle:@"Encrypt file names (7z)" target:nil action:nil];
    NSButton *solid = [NSButton checkboxWithTitle:@"Solid archive" target:nil action:nil];
    solid.state = NSControlStateValueOn;

    for (NSView *view in @[formatLabel, format, levelLabel, level, passwordLabel, password, encrypt, solid]) {
        view.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:view];
    }
    for (NSTextField *label in @[formatLabel, levelLabel, passwordLabel]) {
        label.alignment = NSTextAlignmentRight;
        [label setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    }

    [NSLayoutConstraint activateConstraints:@[
        [formatLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:12],
        [formatLabel.topAnchor constraintEqualToAnchor:self.topAnchor constant:10],
        [formatLabel.widthAnchor constraintEqualToConstant:100],
        [format.centerYAnchor constraintEqualToAnchor:formatLabel.centerYAnchor],
        [format.leadingAnchor constraintEqualToAnchor:formatLabel.trailingAnchor constant:8],
        [format.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-12],

        [levelLabel.leadingAnchor constraintEqualToAnchor:formatLabel.leadingAnchor],
        [levelLabel.topAnchor constraintEqualToAnchor:formatLabel.bottomAnchor constant:12],
        [levelLabel.widthAnchor constraintEqualToAnchor:formatLabel.widthAnchor],
        [level.centerYAnchor constraintEqualToAnchor:levelLabel.centerYAnchor],
        [level.leadingAnchor constraintEqualToAnchor:format.leadingAnchor],
        [level.trailingAnchor constraintEqualToAnchor:format.trailingAnchor],

        [passwordLabel.leadingAnchor constraintEqualToAnchor:formatLabel.leadingAnchor],
        [passwordLabel.topAnchor constraintEqualToAnchor:levelLabel.bottomAnchor constant:12],
        [passwordLabel.widthAnchor constraintEqualToAnchor:formatLabel.widthAnchor],
        [password.centerYAnchor constraintEqualToAnchor:passwordLabel.centerYAnchor],
        [password.leadingAnchor constraintEqualToAnchor:format.leadingAnchor],
        [password.trailingAnchor constraintEqualToAnchor:format.trailingAnchor],
        [password.heightAnchor constraintGreaterThanOrEqualToConstant:22],

        [encrypt.leadingAnchor constraintEqualToAnchor:format.leadingAnchor],
        [encrypt.topAnchor constraintEqualToAnchor:password.bottomAnchor constant:12],
        [encrypt.trailingAnchor constraintLessThanOrEqualToAnchor:self.trailingAnchor constant:-12],
        [solid.leadingAnchor constraintEqualToAnchor:encrypt.leadingAnchor],
        [solid.topAnchor constraintEqualToAnchor:encrypt.bottomAnchor constant:6],
        [solid.trailingAnchor constraintLessThanOrEqualToAnchor:self.trailingAnchor constant:-12],
        [solid.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-10],
    ]];

    self.formatPopup = format;
    self.levelPopup = level;
    self.passwordField = password;
    self.encryptHeadersButton = encrypt;
    self.solidButton = solid;
    return self;
}

- (void)formatChanged:(id)sender {
    (void)sender;
    NSSavePanel *panel = (NSSavePanel *)self.window;
    if ([panel isKindOfClass:[NSSavePanel class]]) {
        [self syncAllowedFileTypes:panel];
    }
}

- (void)syncAllowedFileTypes:(NSSavePanel *)panel {
    NSString *ext = RZNS(rz::Engine::extensionForFormat(self.format));
    UTType *type = [UTType typeWithFilenameExtension:ext] ?: UTTypeData;
    panel.allowedContentTypes = @[type];
    NSString *base = panel.nameFieldStringValue.stringByDeletingPathExtension;
    if (base.length) {
        panel.nameFieldStringValue = [base stringByAppendingPathExtension:ext];
    }
    BOOL sevenZip = self.format == rz::Format::SevenZip;
    self.encryptHeadersButton.enabled = sevenZip;
    self.solidButton.enabled = sevenZip;
}

- (rz::Format)format {
    switch (self.formatPopup.indexOfSelectedItem) {
    case 1: return rz::Format::Zip;
    case 2: return rz::Format::Tar;
    case 3: return rz::Format::GZip;
    case 4: return rz::Format::BZip2;
    case 5: return rz::Format::Xz;
    case 6: return rz::Format::Wim;
    default: return rz::Format::SevenZip;
    }
}

- (int)compressionLevel {
    static const int levels[] = {0, 1, 3, 5, 7, 9};
    NSInteger index = self.levelPopup.indexOfSelectedItem;
    if (index < 0 || index > 5) {
        return 5;
    }
    return levels[index];
}

- (NSString *)password {
    return self.passwordField.stringValue ?: @"";
}

- (BOOL)encryptHeaders {
    return self.encryptHeadersButton.state == NSControlStateValueOn;
}

- (BOOL)solid {
    return self.solidButton.state == NSControlStateValueOn;
}

@end
