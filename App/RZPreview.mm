#import "RZPreview.h"
#import <PDFKit/PDFKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

// +stringEncodingForData: costs roughly a second per megabyte on non-UTF-8
// input, and no one reads a 128 MB file in a preview pane, so cap what is fed
// to it. The cap is on the decoded prefix only; the file itself is untouched.
static const NSUInteger RZPreviewTextMaxBytes = 2u * 1024 * 1024;

static NSString *RZDecodePreviewText(NSData *data) {
    if (data.length == 0) {
        return @"";
    }
    const unsigned char *bytes = static_cast<const unsigned char *>(data.bytes);
    if (data.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
        return [[NSString alloc] initWithData:data encoding:NSUTF16LittleEndianStringEncoding];
    }
    if (data.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
        return [[NSString alloc] initWithData:data encoding:NSUTF16BigEndianStringEncoding];
    }
    NSString *utf8 = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (utf8) {
        return utf8;
    }
    // Detection is the expensive step and scales with input length, so run it
    // on a sample and reuse the answer to decode the rest cheaply.
    static const NSUInteger kDetectSampleBytes = 64u * 1024;
    NSData *sample = data.length > kDetectSampleBytes
        ? [data subdataWithRange:NSMakeRange(0, kDetectSampleBytes)]
        : data;
    NSString *sampleText = nil;
    NSStringEncoding encoding =
        [NSString stringEncodingForData:sample
                        encodingOptions:@{
                            NSStringEncodingDetectionSuggestedEncodingsKey: @[
                                @(CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingGB_18030_2000)),
                                @(CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingGBK_95)),
                                @(NSShiftJISStringEncoding),
                                @(CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingBig5)),
                                @(CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingEUC_KR)),
                                @(NSISOLatin1StringEncoding),
                            ],
                            NSStringEncodingDetectionUseOnlySuggestedEncodingsKey: @NO,
                        }
                        convertedString:&sampleText
                    usedLossyConversion:NULL];
    NSString *decoded = encoding != 0 ? [[NSString alloc] initWithData:data encoding:encoding] : nil;
    if (decoded.length == 0) {
        decoded = sampleText;
    }
    if (decoded.length == 0) {
        return nil;
    }
    NSUInteger nuls = 0;
    NSUInteger probe = MIN(data.length, (NSUInteger)4096);
    for (NSUInteger i = 0; i < probe; i++) {
        if (bytes[i] == 0) {
            nuls++;
        }
    }
    if (probe > 0 && nuls * 20 > probe) {
        return nil;
    }
    return decoded;
}

typedef NS_ENUM(NSInteger, RZPreviewKind) {
    RZPreviewKindNone = 0,
    RZPreviewKindImage,
    RZPreviewKindPDF,
    RZPreviewKindRTF,
    RZPreviewKindText,
};

@interface RZPreviewContent ()
@property (nonatomic, assign) RZPreviewKind kind;
@property (nonatomic, strong, nullable) NSImage *image;
@property (nonatomic, strong, nullable) PDFDocument *pdf;
@property (nonatomic, strong, nullable) NSData *rtfData;
@property (nonatomic, strong, nullable) NSAttributedString *text;
@end

@implementation RZPreviewContent

+ (NSDictionary *)textAttributes {
    return @{
        NSFontAttributeName: [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular],
        NSForegroundColorAttributeName: NSColor.labelColor,
    };
}

+ (instancetype)contentForData:(NSData *)data name:(NSString *)name {
    RZPreviewContent *content = [[RZPreviewContent alloc] init];
    content.kind = RZPreviewKindNone;
    if (data.length == 0) {
        return content;
    }

    NSString *ext = name.pathExtension;
    UTType *type = ext.length ? [UTType typeWithFilenameExtension:ext] : nil;

    if (!type || [type conformsToType:UTTypeImage]) {
        NSImage *image = [[NSImage alloc] initWithData:data];
        if (image && image.size.width > 0 && image.size.height > 0) {
            content.kind = RZPreviewKindImage;
            content.image = image;
            return content;
        }
        if (type && [type conformsToType:UTTypeImage]) {
            return content;
        }
    }

    if ([type conformsToType:UTTypePDF] || [[ext lowercaseString] isEqualToString:@"pdf"]) {
        PDFDocument *pdf = [[PDFDocument alloc] initWithData:data];
        if (pdf.pageCount > 0) {
            content.kind = RZPreviewKindPDF;
            content.pdf = pdf;
        }
        return content;
    }

    // The AppKit RTF importer is not documented as thread-safe, so hand the
    // bytes to the main thread instead of parsing them here.
    if ([type conformsToType:UTTypeRTF]) {
        content.kind = RZPreviewKindRTF;
        content.rtfData = data;
        return content;
    }

    const BOOL looksText = !type ||
        [type conformsToType:UTTypeText] ||
        [type conformsToType:UTTypeSourceCode] ||
        [type conformsToType:UTTypeJSON] ||
        [type conformsToType:UTTypeXML] ||
        [type conformsToType:UTTypeHTML];
    if (!looksText) {
        return content;
    }

    const BOOL truncated = data.length > RZPreviewTextMaxBytes;
    NSData *head = truncated ? [data subdataWithRange:NSMakeRange(0, RZPreviewTextMaxBytes)] : data;
    NSString *decoded = RZDecodePreviewText(head);
    if (decoded.length == 0) {
        return content;
    }
    if (truncated) {
        decoded = [decoded stringByAppendingFormat:
            @"\n\n… preview truncated at %lu MB of %llu MB. Press Return to open the whole file.",
            (unsigned long)(RZPreviewTextMaxBytes / (1024 * 1024)),
            (unsigned long long)(data.length / (1024 * 1024))];
    }
    content.kind = RZPreviewKindText;
    content.text = [[NSAttributedString alloc] initWithString:decoded
                                                   attributes:[self textAttributes]];
    return content;
}

@end

@interface RZPreviewPanel : NSPanel
@property (nonatomic, copy, nullable) BOOL (^keyHandler)(NSEvent *event);
@end

@implementation RZPreviewPanel

- (BOOL)canBecomeKeyWindow {
    return YES;
}

- (void)keyDown:(NSEvent *)event {
    if (self.keyHandler && self.keyHandler(event)) {
        return;
    }
    [super keyDown:event];
}

@end

@interface RZPreviewController () <NSWindowDelegate>
@property (nonatomic, strong) NSView *container;
@property (nonatomic, strong) NSProgressIndicator *spinner;
@end

@implementation RZPreviewController

- (instancetype)init {
    RZPreviewPanel *panel = [[RZPreviewPanel alloc] initWithContentRect:NSMakeRect(0, 0, 780, 560)
                                                              styleMask:(NSWindowStyleMaskTitled |
                                                                         NSWindowStyleMaskClosable |
                                                                         NSWindowStyleMaskResizable |
                                                                         NSWindowStyleMaskMiniaturizable)
                                                                backing:NSBackingStoreBuffered
                                                                  defer:YES];
    panel.title = @"Preview";
    panel.minSize = NSMakeSize(360, 240);
    panel.releasedWhenClosed = NO;
    panel.restorable = NO;
    panel.delegate = self;
    self = [super initWithWindow:panel];
    if (!self) {
        return nil;
    }
    NSView *container = [[NSView alloc] initWithFrame:NSZeroRect];
    container.translatesAutoresizingMaskIntoConstraints = NO;
    [panel.contentView addSubview:container];
    [NSLayoutConstraint activateConstraints:@[
        [container.topAnchor constraintEqualToAnchor:panel.contentView.topAnchor],
        [container.leadingAnchor constraintEqualToAnchor:panel.contentView.leadingAnchor],
        [container.trailingAnchor constraintEqualToAnchor:panel.contentView.trailingAnchor],
        [container.bottomAnchor constraintEqualToAnchor:panel.contentView.bottomAnchor],
    ]];
    self.container = container;
    return self;
}

- (void)setKeyHandler:(BOOL (^)(NSEvent *))keyHandler {
    _keyHandler = [keyHandler copy];
    ((RZPreviewPanel *)self.window).keyHandler = _keyHandler;
}

- (void)clearContent {
    for (NSView *view in [self.container.subviews copy]) {
        [view removeFromSuperview];
    }
    [self.spinner stopAnimation:nil];
    self.spinner = nil;
}

- (void)pin:(NSView *)view {
    view.translatesAutoresizingMaskIntoConstraints = NO;
    [self.container addSubview:view];
    [NSLayoutConstraint activateConstraints:@[
        [view.topAnchor constraintEqualToAnchor:self.container.topAnchor],
        [view.leadingAnchor constraintEqualToAnchor:self.container.leadingAnchor],
        [view.trailingAnchor constraintEqualToAnchor:self.container.trailingAnchor],
        [view.bottomAnchor constraintEqualToAnchor:self.container.bottomAnchor],
    ]];
}

- (void)showLoading:(NSString *)name {
    self.window.title = name.length ? name : @"Preview";
    [self clearContent];
    NSProgressIndicator *spinner = [[NSProgressIndicator alloc] initWithFrame:NSZeroRect];
    spinner.style = NSProgressIndicatorStyleSpinning;
    spinner.controlSize = NSControlSizeRegular;
    spinner.translatesAutoresizingMaskIntoConstraints = NO;
    [self.container addSubview:spinner];
    [NSLayoutConstraint activateConstraints:@[
        [spinner.centerXAnchor constraintEqualToAnchor:self.container.centerXAnchor],
        [spinner.centerYAnchor constraintEqualToAnchor:self.container.centerYAnchor],
    ]];
    [spinner startAnimation:nil];
    self.spinner = spinner;
}

- (void)showPlaceholder:(NSString *)name message:(NSString *)message {
    self.window.title = name.length ? name : @"Preview";
    [self clearContent];
    NSTextField *label = [NSTextField wrappingLabelWithString:message ?: @"No preview"];
    label.alignment = NSTextAlignmentCenter;
    label.textColor = NSColor.secondaryLabelColor;
    label.font = [NSFont systemFontOfSize:13];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [self.container addSubview:label];
    [NSLayoutConstraint activateConstraints:@[
        [label.centerYAnchor constraintEqualToAnchor:self.container.centerYAnchor],
        [label.leadingAnchor constraintEqualToAnchor:self.container.leadingAnchor constant:32],
        [label.trailingAnchor constraintEqualToAnchor:self.container.trailingAnchor constant:-32],
    ]];
}

- (void)showImage:(NSImage *)image {
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    scroll.hasVerticalScroller = YES;
    scroll.hasHorizontalScroller = YES;
    scroll.autohidesScrollers = YES;
    scroll.borderType = NSNoBorder;
    scroll.drawsBackground = YES;
    scroll.backgroundColor = NSColor.windowBackgroundColor;
    NSImageView *view = [[NSImageView alloc] initWithFrame:NSZeroRect];
    view.image = image;
    view.imageScaling = NSImageScaleProportionallyUpOrDown;
    view.imageAlignment = NSImageAlignCenter;
    scroll.documentView = view;
    view.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [view.topAnchor constraintEqualToAnchor:scroll.contentView.topAnchor],
        [view.leadingAnchor constraintEqualToAnchor:scroll.contentView.leadingAnchor],
        [view.trailingAnchor constraintEqualToAnchor:scroll.contentView.trailingAnchor],
        [view.bottomAnchor constraintEqualToAnchor:scroll.contentView.bottomAnchor],
        [view.widthAnchor constraintGreaterThanOrEqualToConstant:1],
        [view.heightAnchor constraintGreaterThanOrEqualToConstant:1],
    ]];
    [self pin:scroll];
}

- (void)showPDF:(PDFDocument *)document {
    PDFView *view = [[PDFView alloc] initWithFrame:NSZeroRect];
    view.document = document;
    view.autoScales = YES;
    view.displayMode = kPDFDisplaySinglePageContinuous;
    [self pin:view];
}

- (void)showText:(NSAttributedString *)text {
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    scroll.hasVerticalScroller = YES;
    scroll.hasHorizontalScroller = YES;
    scroll.autohidesScrollers = YES;
    scroll.borderType = NSNoBorder;
    scroll.drawsBackground = YES;
    NSTextView *view = [[NSTextView alloc] initWithFrame:NSZeroRect];
    view.editable = NO;
    view.selectable = YES;
    view.richText = YES;
    view.importsGraphics = NO;
    view.font = [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular];
    view.textContainerInset = NSMakeSize(12, 12);
    view.minSize = NSMakeSize(0, 0);
    view.maxSize = NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX);
    view.verticallyResizable = YES;
    view.horizontallyResizable = YES;
    view.autoresizingMask = NSViewWidthSizable;
    view.textContainer.containerSize = NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX);
    view.textContainer.widthTracksTextView = NO;
    [view.textStorage setAttributedString:text];
    scroll.documentView = view;
    [self pin:scroll];
}

- (BOOL)tryShowContent:(RZPreviewContent *)content {
    switch (content.kind) {
    case RZPreviewKindImage:
        [self showImage:content.image];
        return YES;
    case RZPreviewKindPDF:
        [self showPDF:content.pdf];
        return YES;
    case RZPreviewKindRTF: {
        NSAttributedString *rtf = [[NSAttributedString alloc] initWithRTF:content.rtfData
                                                       documentAttributes:nil];
        if (rtf.length) {
            [self showText:rtf];
            return YES;
        }
        return NO;
    }
    case RZPreviewKindText:
        [self showText:content.text];
        return YES;
    case RZPreviewKindNone:
        break;
    }
    return NO;
}

- (void)showContent:(RZPreviewContent *)content name:(NSString *)name {
    self.window.title = name.length ? name : @"Preview";
    [self clearContent];
    if (!content) {
        [self showPlaceholder:name message:@"This file is empty."];
        return;
    }
    if (![self tryShowContent:content]) {
        [self showPlaceholder:name message:@"No in-memory preview for this file.\nPress Return to open it, which extracts this item only."];
    }
}

- (void)presentRelativeTo:(NSWindow *)parent {
    if (!self.window.isVisible) {
        if (parent) {
            NSRect frame = parent.frame;
            [self.window setFrameOrigin:NSMakePoint(NSMidX(frame) - self.window.frame.size.width / 2,
                                                    NSMidY(frame) - self.window.frame.size.height / 2)];
        } else {
            [self.window center];
        }
    }
    [self showWindow:nil];
    [self.window makeKeyAndOrderFront:nil];
}

- (void)cancelOperation:(id)sender {
    (void)sender;
    [self close];
}

- (void)windowWillClose:(NSNotification *)notification {
    (void)notification;
    if (self.closeHandler) {
        self.closeHandler();
    }
}

@end
