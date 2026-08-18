#import "RZMainWindowController.h"
#import "RZDocument.h"
#import "RZPreview.h"
#import "RZSheets.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static const unsigned long long RZPreviewMaxBytes = 128ull * 1024 * 1024;
static const NSTimeInterval RZPreviewDebounce = 0.12;

@interface RZFileTableView : NSTableView
@property (nonatomic, copy, nullable) void (^spaceHandler)(void);
@end

@implementation RZFileTableView

- (void)keyDown:(NSEvent *)event {
    NSEventModifierFlags mods = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
    if (mods == 0 && event.charactersIgnoringModifiers.length == 1 &&
        [event.charactersIgnoringModifiers characterAtIndex:0] == ' ') {
        if (self.spaceHandler) {
            self.spaceHandler();
            return;
        }
    }
    [super keyDown:event];
}

@end

static NSString * const RZColName = @"name";
static NSString * const RZColSize = @"size";
static NSString * const RZColPacked = @"packed";
static NSString * const RZColModified = @"modified";
static NSString * const RZColCRC = @"crc";
static NSString * const RZColMethod = @"method";

@interface RZMainWindowController () <NSToolbarDelegate, NSTableViewDataSource, NSTableViewDelegate,
                                      NSOutlineViewDataSource, NSOutlineViewDelegate,
                                      NSFilePromiseProviderDelegate>
@property (nonatomic, strong) NSSplitViewController *splitController;
@property (nonatomic, strong) NSSplitView *splitView;
@property (nonatomic, strong) NSOutlineView *treeView;
@property (nonatomic, strong) NSTableView *tableView;
@property (nonatomic, strong) NSStackView *pathStack;
@property (nonatomic, strong) NSSearchField *searchField;
@property (nonatomic, strong) NSTextField *statusLabel;
@property (nonatomic, strong) NSTextField *sizeLabel;
@property (nonatomic, copy) NSString *currentPath;
@property (nonatomic, copy) NSArray<RZItem *> *visibleItems;
@property (nonatomic, strong) RZProgressController *progressController;
@property (nonatomic, strong) RZInfoController *infoController;
@property (nonatomic, strong) RZPreviewController *previewController;
@property (nonatomic, assign) NSUInteger previewToken;
@property (nonatomic, assign) BOOL busy;
- (NSString *)askPassword:(NSString *)message;
- (void)togglePreview:(id)sender;
- (void)startPreviewExtract:(RZItem *)item token:(NSUInteger)token;
@end

@implementation RZMainWindowController {
    rz::ProgressPtr _previewProgress;
}

- (instancetype)init {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1040, 643)
                                                   styleMask:(NSWindowStyleMaskTitled |
                                                              NSWindowStyleMaskClosable |
                                                              NSWindowStyleMaskMiniaturizable |
                                                              NSWindowStyleMaskResizable |
                                                              NSWindowStyleMaskFullSizeContentView)
                                                     backing:NSBackingStoreBuffered
                                                       defer:YES];
    window.minSize = NSMakeSize(720, 420);
    window.title = @"ReZipper";
    window.titlebarAppearsTransparent = YES;
    window.restorable = NO;
    self = [super initWithWindow:window];
    if (!self) {
        return nil;
    }
    _currentPath = @"";
    _visibleItems = @[];
    [self buildToolbar];
    [self buildContent];
    [self.window setContentSize:NSMakeSize(1040, 643)];
    return self;
}

- (RZDocument *)archiveDocument {
    return (RZDocument *)self.document;
}

#pragma mark - Layout

- (void)buildToolbar {
    NSToolbar *toolbar = [[NSToolbar alloc] initWithIdentifier:@"RZToolbar"];
    toolbar.delegate = self;
    toolbar.displayMode = NSToolbarDisplayModeIconOnly;
    toolbar.allowsUserCustomization = YES;
    toolbar.autosavesConfiguration = NO;
    self.window.toolbar = toolbar;
    self.window.toolbarStyle = NSWindowToolbarStyleUnified;
}

- (NSImage *)rz_symbol:(NSString *)name size:(CGFloat)size {
    NSImage *image = [NSImage imageWithSystemSymbolName:name accessibilityDescription:name];
    NSImageSymbolConfiguration *config = [NSImageSymbolConfiguration configurationWithPointSize:size
                                                                                          weight:NSFontWeightMedium
                                                                                           scale:NSImageSymbolScaleMedium];
    image = [image imageWithSymbolConfiguration:config] ?: image;
    NSImage *fixed = [image copy];
    fixed.size = NSMakeSize(size, size);
    fixed.alignmentRect = NSMakeRect(0, 0, size, size);
    return fixed;
}

- (NSView *)rz_glassWrap:(NSView *)inner cornerRadius:(CGFloat)radius {
    if (@available(macOS 26.0, *)) {
        NSGlassEffectView *glass = [[NSGlassEffectView alloc] initWithFrame:NSZeroRect];
        glass.cornerRadius = radius;
        glass.style = NSGlassEffectViewStyleRegular;
        glass.contentView = inner;
        glass.translatesAutoresizingMaskIntoConstraints = NO;
        return glass;
    }
    inner.wantsLayer = YES;
    inner.layer.cornerRadius = radius;
    inner.layer.masksToBounds = YES;
    inner.layer.backgroundColor = [NSColor.controlBackgroundColor colorWithAlphaComponent:0.72].CGColor;
    return inner;
}

- (void)buildContent {
    NSScrollView *treeScroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    treeScroll.hasVerticalScroller = YES;
    treeScroll.borderType = NSNoBorder;
    treeScroll.drawsBackground = NO;
    treeScroll.automaticallyAdjustsContentInsets = YES;
    NSOutlineView *tree = [[NSOutlineView alloc] initWithFrame:NSZeroRect];
    tree.style = NSTableViewStyleSourceList;
    tree.headerView = nil;
    tree.backgroundColor = NSColor.clearColor;
    tree.allowsMultipleSelection = NO;
    tree.rowSizeStyle = NSTableViewRowSizeStyleDefault;
    NSTableColumn *treeCol = [[NSTableColumn alloc] initWithIdentifier:@"folder"];
    treeCol.title = @"Folders";
    [tree addTableColumn:treeCol];
    tree.outlineTableColumn = treeCol;
    tree.dataSource = self;
    tree.delegate = self;
    treeScroll.documentView = tree;
    self.treeView = tree;

    NSViewController *sidebarVC = [[NSViewController alloc] init];
    sidebarVC.view = treeScroll;

    NSScrollView *tableScroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    tableScroll.hasVerticalScroller = YES;
    tableScroll.hasHorizontalScroller = YES;
    tableScroll.autohidesScrollers = YES;
    tableScroll.borderType = NSNoBorder;
    tableScroll.drawsBackground = NO;
    tableScroll.automaticallyAdjustsContentInsets = YES;
    RZFileTableView *table = [[RZFileTableView alloc] initWithFrame:NSZeroRect];
    table.style = NSTableViewStyleInset;
    table.usesAlternatingRowBackgroundColors = NO;
    table.backgroundColor = NSColor.clearColor;
    table.gridStyleMask = NSTableViewGridNone;
    table.allowsMultipleSelection = YES;
    table.allowsColumnReordering = YES;
    table.rowSizeStyle = NSTableViewRowSizeStyleDefault;
    table.doubleAction = @selector(tableDoubleClicked:);
    table.target = self;
    [self addColumn:RZColName title:@"Name" width:280 to:table];
    [self addColumn:RZColSize title:@"Size" width:90 to:table];
    [self addColumn:RZColPacked title:@"Packed" width:90 to:table];
    [self addColumn:RZColModified title:@"Modified" width:150 to:table];
    [self addColumn:RZColCRC title:@"CRC" width:80 to:table];
    [self addColumn:RZColMethod title:@"Method" width:90 to:table];
    table.dataSource = self;
    table.delegate = self;
    [table registerForDraggedTypes:@[NSPasteboardTypeFileURL]];
    [table setDraggingSourceOperationMask:NSDragOperationCopy forLocal:NO];
    tableScroll.documentView = table;
    __weak RZMainWindowController *weakSelf = self;
    table.spaceHandler = ^{
        [weakSelf togglePreview:weakSelf];
    };
    self.tableView = table;

    NSButton *upButton = [NSButton buttonWithImage:[self rz_symbol:@"chevron.up" size:13]
                                            target:self
                                            action:@selector(goUp:)];
    upButton.toolTip = @"Go to Parent Folder";
    upButton.imagePosition = NSImageOnly;
    upButton.imageScaling = NSImageScaleNone;
    upButton.translatesAutoresizingMaskIntoConstraints = NO;
    if (@available(macOS 26.0, *)) {
        upButton.bezelStyle = NSBezelStyleGlass;
    } else {
        upButton.bezelStyle = NSBezelStyleTexturedRounded;
    }
    [NSLayoutConstraint activateConstraints:@[
        [upButton.widthAnchor constraintEqualToConstant:32],
        [upButton.heightAnchor constraintEqualToConstant:32],
    ]];

    NSStackView *crumbs = [NSStackView stackViewWithViews:@[]];
    crumbs.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    crumbs.alignment = NSLayoutAttributeCenterY;
    crumbs.spacing = 4;
    crumbs.distribution = NSStackViewDistributionGravityAreas;
    crumbs.translatesAutoresizingMaskIntoConstraints = NO;
    [crumbs setHuggingPriority:NSLayoutPriorityDefaultHigh forOrientation:NSLayoutConstraintOrientationHorizontal];
    [crumbs setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    [crumbs setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationVertical];
    self.pathStack = crumbs;

    NSView *pathSpacer = [[NSView alloc] initWithFrame:NSZeroRect];
    pathSpacer.translatesAutoresizingMaskIntoConstraints = NO;
    [pathSpacer setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    [pathSpacer setContentCompressionResistancePriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];

    NSStackView *pathRow = [NSStackView stackViewWithViews:@[upButton, crumbs, pathSpacer]];
    pathRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    pathRow.alignment = NSLayoutAttributeCenterY;
    pathRow.spacing = 10;
    pathRow.edgeInsets = NSEdgeInsetsMake(10, 14, 10, 14);
    pathRow.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [crumbs.heightAnchor constraintEqualToConstant:28],
        [pathRow.heightAnchor constraintGreaterThanOrEqualToConstant:48],
    ]];
    NSView *pathChrome = [self rz_glassWrap:pathRow cornerRadius:20];
    [pathChrome.heightAnchor constraintGreaterThanOrEqualToConstant:48].active = YES;

    NSTextField *status = [NSTextField labelWithString:@"Open an archive to get started"];
    status.font = [NSFont systemFontOfSize:13];
    status.textColor = NSColor.secondaryLabelColor;
    status.translatesAutoresizingMaskIntoConstraints = NO;
    NSTextField *size = [NSTextField labelWithString:@""];
    size.font = [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightRegular];
    size.textColor = NSColor.secondaryLabelColor;
    size.alignment = NSTextAlignmentRight;
    size.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusLabel = status;
    self.sizeLabel = size;
    NSStackView *statusRow = [NSStackView stackViewWithViews:@[status, size]];
    statusRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    statusRow.alignment = NSLayoutAttributeCenterY;
    statusRow.distribution = NSStackViewDistributionFill;
    statusRow.edgeInsets = NSEdgeInsetsMake(11, 16, 11, 16);
    statusRow.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [statusRow.heightAnchor constraintGreaterThanOrEqualToConstant:40],
    ]];
    NSView *statusChrome = [self rz_glassWrap:statusRow cornerRadius:18];
    [statusChrome.heightAnchor constraintGreaterThanOrEqualToConstant:40].active = YES;

    NSViewController *contentVC = [[NSViewController alloc] init];
    if (@available(macOS 26.0, *)) {
        contentVC.view = tableScroll;
    } else {
        tableScroll.automaticallyAdjustsContentInsets = NO;
        tableScroll.translatesAutoresizingMaskIntoConstraints = NO;
        NSView *column = [[NSView alloc] initWithFrame:NSZeroRect];
        [column addSubview:pathChrome];
        [column addSubview:tableScroll];
        [column addSubview:statusChrome];
        contentVC.view = column;
    }

    NSSplitViewController *split = [[NSSplitViewController alloc] init];
    NSSplitViewItem *sidebarItem = [NSSplitViewItem sidebarWithViewController:sidebarVC];
    sidebarItem.canCollapse = YES;
    sidebarItem.minimumThickness = 180;
    sidebarItem.maximumThickness = 300;
    NSSplitViewItem *contentItem = [NSSplitViewItem contentListWithViewController:contentVC];
    if (@available(macOS 26.0, *)) {
        contentItem.automaticallyAdjustsSafeAreaInsets = YES;
    }
    [split addSplitViewItem:sidebarItem];
    [split addSplitViewItem:contentItem];
    self.splitController = split;
    self.splitView = split.splitView;
    self.contentViewController = split;

    if (@available(macOS 26.0, *)) {
        NSSplitViewItemAccessoryViewController *pathAccessory = [[NSSplitViewItemAccessoryViewController alloc] init];
        pathAccessory.view = pathChrome;
        pathAccessory.automaticallyAppliesContentInsets = YES;
        if (@available(macOS 26.1, *)) {
            pathAccessory.preferredScrollEdgeEffectStyle = NSScrollEdgeEffectStyle.softStyle;
        }
        [contentItem addTopAlignedAccessoryViewController:pathAccessory];

        NSSplitViewItemAccessoryViewController *statusAccessory = [[NSSplitViewItemAccessoryViewController alloc] init];
        statusAccessory.view = statusChrome;
        statusAccessory.automaticallyAppliesContentInsets = YES;
        if (@available(macOS 26.1, *)) {
            statusAccessory.preferredScrollEdgeEffectStyle = NSScrollEdgeEffectStyle.softStyle;
        }
        [contentItem addBottomAlignedAccessoryViewController:statusAccessory];
    } else {
        NSView *column = contentVC.view;
        NSLayoutAnchor *pathTop = column.safeAreaLayoutGuide.topAnchor;
        NSLayoutGuide *contentGuide = (NSLayoutGuide *)self.window.contentLayoutGuide;
        if ([contentGuide isKindOfClass:[NSLayoutGuide class]]) {
            pathTop = contentGuide.topAnchor;
        }
        [NSLayoutConstraint activateConstraints:@[
            [pathChrome.topAnchor constraintEqualToAnchor:pathTop constant:8],
            [pathChrome.leadingAnchor constraintEqualToAnchor:column.leadingAnchor constant:12],
            [pathChrome.trailingAnchor constraintEqualToAnchor:column.trailingAnchor constant:-12],
            [tableScroll.topAnchor constraintEqualToAnchor:pathChrome.bottomAnchor constant:8],
            [tableScroll.leadingAnchor constraintEqualToAnchor:column.leadingAnchor],
            [tableScroll.trailingAnchor constraintEqualToAnchor:column.trailingAnchor],
            [tableScroll.bottomAnchor constraintEqualToAnchor:statusChrome.topAnchor constant:-8],
            [statusChrome.leadingAnchor constraintEqualToAnchor:column.leadingAnchor constant:12],
            [statusChrome.trailingAnchor constraintEqualToAnchor:column.trailingAnchor constant:-12],
            [statusChrome.bottomAnchor constraintEqualToAnchor:column.bottomAnchor constant:-8],
        ]];
    }
}

- (void)addColumn:(NSString *)identifier title:(NSString *)title width:(CGFloat)width to:(NSTableView *)table {
    NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:identifier];
    column.title = title;
    column.width = width;
    column.minWidth = 60;
    if (![identifier isEqualToString:RZColName]) {
        column.resizingMask = NSTableColumnUserResizingMask;
    }
    [table addTableColumn:column];
}

- (void)showWindow:(id)sender {
    [super showWindow:sender];
    [self.splitView setPosition:220 ofDividerAtIndex:0];
    RZDocument *doc = self.archiveDocument;
    if ((doc.fileURL || doc.nestRootPath.length) && doc.items.count == 0 && !doc.needsPassword) {
        [doc reload:nil];
    }
    [self unlockIfNeeded];
    [self reloadBrowser];
}

- (NSString *)askPassword:(NSString *)message {
    RZPasswordController *sheet = [[RZPasswordController alloc] init];
    NSModalResponse response = [sheet runSheetForWindow:self.window message:message];
    if (response != NSModalResponseOK || sheet.password.length == 0) {
        return nil;
    }
    return sheet.password;
}

- (void)unlockIfNeeded {
    RZDocument *doc = self.archiveDocument;
    while (doc.needsPassword) {
        NSString *password = [self askPassword:@"This archive is encrypted. Enter the password to open it."];
        if (password.length == 0) {
            break;
        }
        doc.password = password;
        NSError *error = nil;
        if ([doc reload:&error]) {
            doc.needsPassword = NO;
            break;
        }
        if (!RZIsPasswordError(error)) {
            [self presentError:error];
            break;
        }
    }
}

- (void)setDocument:(id)document {
    [super setDocument:document];
    [self reloadBrowser];
}

#pragma mark - Toolbar

- (NSArray<NSToolbarItemIdentifier> *)toolbarAllowedItemIdentifiers:(NSToolbar *)toolbar {
    (void)toolbar;
    return @[
        NSToolbarToggleSidebarItemIdentifier,
        NSToolbarSidebarTrackingSeparatorItemIdentifier,
        @"RZAdd", @"RZExtract", @"RZTest", @"RZView", @"RZDelete",
        NSToolbarSpaceItemIdentifier,
        @"RZInfo",
        NSToolbarFlexibleSpaceItemIdentifier,
        @"RZSearch"
    ];
}

- (NSArray<NSToolbarItemIdentifier> *)toolbarDefaultItemIdentifiers:(NSToolbar *)toolbar {
    return [self toolbarAllowedItemIdentifiers:toolbar];
}

- (NSToolbarItem *)toolbar:(NSToolbar *)toolbar
     itemForItemIdentifier:(NSToolbarItemIdentifier)itemIdentifier
 willBeInsertedIntoToolbar:(BOOL)flag {
    (void)toolbar;
    (void)flag;
    if ([itemIdentifier isEqualToString:NSToolbarToggleSidebarItemIdentifier] ||
        [itemIdentifier isEqualToString:NSToolbarSidebarTrackingSeparatorItemIdentifier] ||
        [itemIdentifier isEqualToString:NSToolbarFlexibleSpaceItemIdentifier] ||
        [itemIdentifier isEqualToString:NSToolbarSpaceItemIdentifier]) {
        return [[NSToolbarItem alloc] initWithItemIdentifier:itemIdentifier];
    }
    if ([itemIdentifier isEqualToString:@"RZSearch"]) {
        NSSearchToolbarItem *item = [[NSSearchToolbarItem alloc] initWithItemIdentifier:itemIdentifier];
        item.searchField.target = self;
        item.searchField.action = @selector(filterChanged:);
        item.searchField.placeholderString = @"Filter";
        self.searchField = item.searchField;
        return item;
    }

    NSDictionary *map = @{
        @"RZAdd": @[ @"Add", @"plus", @"addFiles:" ],
        @"RZExtract": @[ @"Extract To", @"square.and.arrow.down", @"extract:" ],
        @"RZTest": @[ @"Test", @"checkmark.seal", @"testArchive:" ],
        @"RZView": @[ @"View", @"eye", @"viewSelection:" ],
        @"RZDelete": @[ @"Delete", @"trash", @"deleteSelection:" ],
        @"RZInfo": @[ @"Info", @"info.circle", @"showInfo:" ],
    };
    NSArray *spec = map[itemIdentifier];
    if (!spec) {
        return nil;
    }
    NSToolbarItem *item = [[NSToolbarItem alloc] initWithItemIdentifier:itemIdentifier];
    item.label = spec[0];
    item.paletteLabel = spec[0];
    item.toolTip = spec[0];
    item.image = [NSImage imageWithSystemSymbolName:spec[1] accessibilityDescription:spec[0]];
    item.target = self;
    item.action = NSSelectorFromString(spec[2]);
    item.bordered = YES;
    if (@available(macOS 26.0, *)) {
        if ([itemIdentifier isEqualToString:@"RZExtract"]) {
            item.style = NSToolbarItemStyleProminent;
            item.backgroundTintColor = [NSColor colorWithSRGBRed:0.86 green:0.36 blue:0.22 alpha:1.0];
        }
    }
    return item;
}

#pragma mark - Data

- (void)reloadBrowser {
    RZDocument *doc = self.archiveDocument;
    if (!doc.fileURL && !doc.nestRootPath.length) {
        return;
    }
    if (doc.fileURL) {
        self.window.representedFilename = doc.fileURL.path;
        self.window.title = doc.fileURL.lastPathComponent;
    } else {
        self.window.representedFilename = doc.nestRootPath;
        self.window.title = doc.nestTitle ?: @"Archive";
    }
    self.window.subtitle = doc.formatName.uppercaseString;
    [self.treeView reloadData];
    [self.treeView expandItem:nil expandChildren:YES];
    RZFolderNode *node = [doc.rootFolder nodeForPath:self.currentPath];
    if (node) {
        [self.treeView selectRowIndexes:[NSIndexSet indexSetWithIndex:[self.treeView rowForItem:node]]
                   byExtendingSelection:NO];
    }
    [self refreshVisibleItems];
}

- (void)refreshVisibleItems {
    RZDocument *doc = self.archiveDocument;
    NSArray<RZItem *> *items = [doc itemsInFolder:self.currentPath];
    NSString *filter = self.searchField.stringValue.lowercaseString ?: @"";
    if (filter.length) {
        NSMutableArray<RZItem *> *filtered = [NSMutableArray array];
        for (RZItem *item in doc.items) {
            if ([item.name.lowercaseString containsString:filter] ||
                [item.path.lowercaseString containsString:filter]) {
                [filtered addObject:item];
            }
        }
        items = filtered;
    }
    self.visibleItems = items;
    [self.tableView reloadData];
    [self updatePathControl];
    [self updateStatus];
}

- (NSView *)rz_crumbWithTitle:(NSString *)title symbol:(NSString *)symbol tag:(NSInteger)tag {
    NSImageView *icon = [[NSImageView alloc] initWithFrame:NSZeroRect];
    icon.image = [self rz_symbol:symbol size:14];
    icon.imageScaling = NSImageScaleNone;
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    [icon setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    [NSLayoutConstraint activateConstraints:@[
        [icon.widthAnchor constraintEqualToConstant:16],
        [icon.heightAnchor constraintEqualToConstant:16],
    ]];

    NSButton *label = [NSButton buttonWithTitle:title target:self action:@selector(crumbClicked:)];
    label.bordered = NO;
    label.bezelStyle = NSBezelStyleAccessoryBarAction;
    label.imagePosition = NSNoImage;
    label.tag = tag;
    label.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [label setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    [label setContentCompressionResistancePriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    [label.widthAnchor constraintEqualToConstant:MAX(label.fittingSize.width, 12)].active = YES;

    NSStackView *crumb = [NSStackView stackViewWithViews:@[icon, label]];
    crumb.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    crumb.alignment = NSLayoutAttributeCenterY;
    crumb.spacing = 5;
    crumb.translatesAutoresizingMaskIntoConstraints = NO;
    [crumb setHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    [crumb setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    return crumb;
}

- (void)updatePathControl {
    NSMutableArray<NSView *> *views = [NSMutableArray array];
    NSString *rootTitle = self.archiveDocument.fileURL.lastPathComponent
        ?: (self.archiveDocument.nestTitle ?: @"Archive");
    [views addObject:[self rz_crumbWithTitle:rootTitle symbol:@"archivebox.fill" tag:0]];

    NSArray<NSString *> *parts = self.currentPath.length ? [self.currentPath componentsSeparatedByString:@"/"] : @[];
    NSInteger index = 1;
    for (NSString *part in parts) {
        if (part.length == 0) {
            continue;
        }
        NSImageView *chevron = [[NSImageView alloc] initWithFrame:NSZeroRect];
        chevron.image = [self rz_symbol:@"chevron.forward" size:9];
        chevron.imageScaling = NSImageScaleNone;
        chevron.contentTintColor = NSColor.tertiaryLabelColor;
        chevron.translatesAutoresizingMaskIntoConstraints = NO;
        [NSLayoutConstraint activateConstraints:@[
            [chevron.widthAnchor constraintEqualToConstant:10],
            [chevron.heightAnchor constraintEqualToConstant:10],
        ]];
        [views addObject:chevron];
        [views addObject:[self rz_crumbWithTitle:part symbol:@"folder.fill" tag:index]];
        index += 1;
    }
    for (NSView *view in [self.pathStack.arrangedSubviews copy]) {
        [self.pathStack removeView:view];
    }
    for (NSView *view in views) {
        [self.pathStack addView:view inGravity:NSStackViewGravityLeading];
    }
}

- (void)updateStatus {
    RZDocument *doc = self.archiveDocument;
    NSByteCountFormatter *bytes = [[NSByteCountFormatter alloc] init];
    bytes.countStyle = NSByteCountFormatterCountStyleFile;
    NSInteger selected = self.tableView.numberOfSelectedRows;
    if (selected > 0) {
        __block unsigned long long size = 0;
        NSIndexSet *rows = self.tableView.selectedRowIndexes;
        [rows enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
            (void)stop;
            if (idx < self.visibleItems.count) {
                size += self.visibleItems[idx].size;
            }
        }];
        self.statusLabel.stringValue = [NSString stringWithFormat:@"%ld selected", (long)selected];
        self.sizeLabel.stringValue = [bytes stringFromByteCount:(long long)size];
    } else {
        self.statusLabel.stringValue = [NSString stringWithFormat:@"%lu files, %lu folders",
                                        (unsigned long)doc.fileCount, (unsigned long)doc.folderCount];
        self.sizeLabel.stringValue = [NSString stringWithFormat:@"%@ → %@",
                                      [bytes stringFromByteCount:(long long)doc.totalSize],
                                      [bytes stringFromByteCount:(long long)doc.packedSize]];
    }
}

- (void)setCurrentPath:(NSString *)currentPath {
    _currentPath = currentPath ?: @"";
    [self refreshVisibleItems];
}

- (NSArray<RZItem *> *)selectedItems {
    NSMutableArray<RZItem *> *items = [NSMutableArray array];
    [self.tableView.selectedRowIndexes enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
        (void)stop;
        if (idx < self.visibleItems.count) {
            [items addObject:self.visibleItems[idx]];
        }
    }];
    return items;
}

#pragma mark - Outline

- (NSInteger)outlineView:(NSOutlineView *)outlineView numberOfChildrenOfItem:(id)item {
    (void)outlineView;
    RZFolderNode *node = item ?: self.archiveDocument.rootFolder;
    return (NSInteger)node.children.count;
}

- (id)outlineView:(NSOutlineView *)outlineView child:(NSInteger)index ofItem:(id)item {
    (void)outlineView;
    RZFolderNode *node = item ?: self.archiveDocument.rootFolder;
    return node.children[(NSUInteger)index];
}

- (BOOL)outlineView:(NSOutlineView *)outlineView isItemExpandable:(id)item {
    (void)outlineView;
    RZFolderNode *node = item;
    return node.children.count > 0;
}

- (NSView *)outlineView:(NSOutlineView *)outlineView viewForTableColumn:(NSTableColumn *)tableColumn item:(id)item {
    (void)tableColumn;
    NSTableCellView *cell = [outlineView makeViewWithIdentifier:@"folderCell" owner:self];
    if (!cell) {
        cell = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, 180, 24)];
        cell.identifier = @"folderCell";
        NSImageView *image = [[NSImageView alloc] initWithFrame:NSMakeRect(0, 2, 16, 16)];
        NSTextField *text = [NSTextField labelWithString:@""];
        text.lineBreakMode = NSLineBreakByTruncatingTail;
        image.translatesAutoresizingMaskIntoConstraints = NO;
        text.translatesAutoresizingMaskIntoConstraints = NO;
        [cell addSubview:image];
        [cell addSubview:text];
        cell.imageView = image;
        cell.textField = text;
        [NSLayoutConstraint activateConstraints:@[
            [image.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:2],
            [image.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
            [image.widthAnchor constraintEqualToConstant:16],
            [image.heightAnchor constraintEqualToConstant:16],
            [text.leadingAnchor constraintEqualToAnchor:image.trailingAnchor constant:6],
            [text.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-4],
            [text.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
        ]];
    }
    RZFolderNode *node = item;
    cell.textField.stringValue = node.name ?: @"";
    cell.imageView.image = [NSImage imageWithSystemSymbolName:@"folder.fill" accessibilityDescription:node.name];
    return cell;
}

- (void)outlineViewSelectionDidChange:(NSNotification *)notification {
    (void)notification;
    id selected = [self.treeView itemAtRow:self.treeView.selectedRow];
    if ([selected isKindOfClass:[RZFolderNode class]]) {
        self.currentPath = ((RZFolderNode *)selected).path;
    }
}

#pragma mark - Table

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    (void)tableView;
    return (NSInteger)self.visibleItems.count;
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    if (row < 0 || (NSUInteger)row >= self.visibleItems.count) {
        return nil;
    }
    RZItem *item = self.visibleItems[(NSUInteger)row];
    NSTableCellView *cell = [tableView makeViewWithIdentifier:tableColumn.identifier owner:self];
    if (!cell) {
        cell = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, 100, 24)];
        cell.identifier = tableColumn.identifier;
        NSTextField *text = [NSTextField labelWithString:@""];
        text.lineBreakMode = NSLineBreakByTruncatingTail;
        text.translatesAutoresizingMaskIntoConstraints = NO;
        [cell addSubview:text];
        cell.textField = text;
        if ([tableColumn.identifier isEqualToString:RZColName]) {
            NSImageView *image = [[NSImageView alloc] initWithFrame:NSZeroRect];
            image.translatesAutoresizingMaskIntoConstraints = NO;
            [cell addSubview:image];
            cell.imageView = image;
            [NSLayoutConstraint activateConstraints:@[
                [image.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:4],
                [image.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
                [image.widthAnchor constraintEqualToConstant:16],
                [image.heightAnchor constraintEqualToConstant:16],
                [text.leadingAnchor constraintEqualToAnchor:image.trailingAnchor constant:6],
                [text.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-4],
                [text.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
            ]];
        } else {
            [NSLayoutConstraint activateConstraints:@[
                [text.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:4],
                [text.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-4],
                [text.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
            ]];
        }
    }

    NSByteCountFormatter *bytes = [[NSByteCountFormatter alloc] init];
    bytes.countStyle = NSByteCountFormatterCountStyleFile;
    NSString *identifier = tableColumn.identifier;
    if ([identifier isEqualToString:RZColName]) {
        cell.textField.stringValue = item.name ?: @"";
        if (item.isDir) {
            cell.imageView.image = [NSImage imageWithSystemSymbolName:@"folder.fill" accessibilityDescription:item.name];
        } else {
            cell.imageView.image = [[NSWorkspace sharedWorkspace]
                iconForContentType:[UTType typeWithFilenameExtension:item.name.pathExtension] ?: UTTypeData];
        }
    } else if ([identifier isEqualToString:RZColSize]) {
        cell.textField.stringValue = item.isDir ? @"—" : [bytes stringFromByteCount:(long long)item.size];
        cell.textField.alignment = NSTextAlignmentRight;
    } else if ([identifier isEqualToString:RZColPacked]) {
        cell.textField.stringValue = item.isDir ? @"—" : [bytes stringFromByteCount:(long long)item.packedSize];
        cell.textField.alignment = NSTextAlignmentRight;
    } else if ([identifier isEqualToString:RZColModified]) {
        if (item.mtimeUnix > 0) {
            NSDate *date = [NSDate dateWithTimeIntervalSince1970:(NSTimeInterval)item.mtimeUnix];
            cell.textField.stringValue = [NSDateFormatter localizedStringFromDate:date
                                                                        dateStyle:NSDateFormatterMediumStyle
                                                                        timeStyle:NSDateFormatterShortStyle];
        } else {
            cell.textField.stringValue = @"—";
        }
    } else if ([identifier isEqualToString:RZColCRC]) {
        cell.textField.stringValue = item.isDir || item.crc == 0 ? @"—" :
            [NSString stringWithFormat:@"%08X", item.crc];
        cell.textField.font = [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightRegular];
    } else if ([identifier isEqualToString:RZColMethod]) {
        cell.textField.stringValue = item.method.length ? item.method : @"—";
    }
    return cell;
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    (void)notification;
    [self updateStatus];
    if (self.previewController.window.isVisible) {
        [self previewSelection];
    }
}

- (void)tableDoubleClicked:(id)sender {
    (void)sender;
    NSInteger row = self.tableView.clickedRow;
    if (row < 0 || (NSUInteger)row >= self.visibleItems.count) {
        return;
    }
    RZItem *item = self.visibleItems[(NSUInteger)row];
    if (item.isDir) {
        self.currentPath = item.path;
        RZFolderNode *node = [self.archiveDocument.rootFolder nodeForPath:item.path];
        if (node) {
            [self.treeView expandItem:nil expandChildren:YES];
            NSInteger treeRow = [self.treeView rowForItem:node];
            if (treeRow >= 0) {
                [self.treeView selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)treeRow]
                           byExtendingSelection:NO];
            }
        }
    } else {
        [self viewSelection:self];
    }
}

- (id<NSPasteboardWriting>)tableView:(NSTableView *)tableView pasteboardWriterForRow:(NSInteger)row {
    (void)tableView;
    if (row < 0 || (NSUInteger)row >= self.visibleItems.count) {
        return nil;
    }
    RZItem *item = self.visibleItems[(NSUInteger)row];
    if (item.isDir) {
        return nil;
    }
    NSFilePromiseProvider *provider = [[NSFilePromiseProvider alloc] initWithFileType:(item.name.pathExtension.length ? [UTType typeWithFilenameExtension:item.name.pathExtension].identifier : UTTypeData.identifier)
                                                                              delegate:(id)self];
    provider.userInfo = item;
    return provider;
}

- (NSString *)filePromiseProvider:(NSFilePromiseProvider *)filePromiseProvider fileNameForType:(NSString *)fileType {
    (void)fileType;
    RZItem *item = filePromiseProvider.userInfo;
    return item.name ?: @"extracted";
}

- (void)filePromiseProvider:(NSFilePromiseProvider *)filePromiseProvider
          writePromiseToURL:(NSURL *)url
          completionHandler:(void (^)(NSError * _Nullable))completionHandler {
    RZItem *item = filePromiseProvider.userInfo;
    RZDocument *doc = self.archiveDocument;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        try {
            NSString *folder = url.URLByDeletingLastPathComponent.path;
            rz::Engine::instance().extract(RZStd(doc.archiveFilePath),
                                           RZStd(folder),
                                           {item.index},
                                           RZStd(doc.password),
                                           nullptr,
                                           doc.engineNestIndices);
            NSString *extracted = [folder stringByAppendingPathComponent:item.path];
            if (![extracted isEqualToString:url.path] && [[NSFileManager defaultManager] fileExistsAtPath:extracted]) {
                [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
                [[NSFileManager defaultManager] moveItemAtPath:extracted toPath:url.path error:&error];
            }
        } catch (const std::exception& ex) {
            error = RZErrorFromException(ex);
        }
        completionHandler(error);
    });
}

- (NSDragOperation)tableView:(NSTableView *)tableView
                validateDrop:(id<NSDraggingInfo>)info
                 proposedRow:(NSInteger)row
       proposedDropOperation:(NSTableViewDropOperation)dropOperation {
    (void)tableView;
    (void)row;
    (void)dropOperation;
    if (!self.archiveDocument.canUpdate || self.busy) {
        return NSDragOperationNone;
    }
    return info.draggingPasteboard.pasteboardItems.count ? NSDragOperationCopy : NSDragOperationNone;
}

- (BOOL)tableView:(NSTableView *)tableView
       acceptDrop:(id<NSDraggingInfo>)info
              row:(NSInteger)row
    dropOperation:(NSTableViewDropOperation)dropOperation {
    (void)tableView;
    (void)row;
    (void)dropOperation;
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    for (NSPasteboardItem *item in info.draggingPasteboard.pasteboardItems) {
        NSString *urlString = [item stringForType:NSPasteboardTypeFileURL];
        if (urlString) {
            NSURL *url = [NSURL URLWithString:urlString];
            if (url.path) {
                [paths addObject:url.path];
            }
        }
    }
    if (paths.count == 0) {
        return NO;
    }
    [self addPaths:paths];
    return YES;
}

#pragma mark - Navigation

- (void)goUp:(id)sender {
    (void)sender;
    if (self.currentPath.length == 0) {
        return;
    }
    NSString *parent = self.currentPath.stringByDeletingLastPathComponent;
    if ([parent isEqualToString:@"."] || [parent isEqualToString:self.currentPath]) {
        parent = @"";
    }
    self.currentPath = parent;
}

- (void)crumbClicked:(NSButton *)sender {
    NSInteger index = sender.tag;
    if (index <= 0) {
        self.currentPath = @"";
        return;
    }
    NSMutableArray<NSString *> *keep = [NSMutableArray array];
    NSInteger count = 0;
    for (NSString *part in [self.currentPath componentsSeparatedByString:@"/"]) {
        if (part.length == 0) {
            continue;
        }
        [keep addObject:part];
        count += 1;
        if (count == index) {
            break;
        }
    }
    self.currentPath = [keep componentsJoinedByString:@"/"];
}

- (void)filterChanged:(id)sender {
    (void)sender;
    [self refreshVisibleItems];
}

#pragma mark - Operations

- (BOOL)ensureLoaded {
    return self.archiveDocument.archiveFilePath.length > 0;
}

- (BOOL)promptForPasswordIfNeeded:(NSError *)error {
    if (!RZIsPasswordError(error)) {
        return NO;
    }
    NSString *password = [self askPassword:@"Enter the archive password to continue."];
    if (password.length == 0) {
        return NO;
    }
    self.archiveDocument.password = password;
    return YES;
}

- (void)runWork:(NSString *)title
           work:(void (^)(rz::ProgressPtr progress))work
     completion:(void (^)(NSError * _Nullable error))completion {
    if (self.busy) {
        return;
    }
    self.busy = YES;
    auto progress = std::make_shared<rz::Progress>();
    RZProgressController *controller = [[RZProgressController alloc] init];
    [controller setTitleText:title];
    [controller setStatus:@"Starting…"];
    [controller setProgress:0 indeterminate:YES];
    controller.cancelHandler = ^{
        progress->cancel.store(true);
    };
    self.progressController = controller;
    __block NSError *workError = nil;
    [self.window beginSheet:controller.window completionHandler:^(NSModalResponse result) {
        (void)result;
        self.progressController = nil;
        self.busy = NO;
        if (completion) {
            completion(workError);
        }
    }];

    NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:0.15 repeats:YES block:^(NSTimer *t) {
        (void)t;
        uint64_t total = progress->total.load();
        uint64_t done = progress->processed.load();
        NSString *file = RZNS(progress->currentFile);
        if (file.length) {
            [controller setStatus:file.lastPathComponent];
        }
        if (total > 0) {
            [controller setProgress:(double)done / (double)total indeterminate:NO];
        }
    }];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        try {
            work(progress);
        } catch (const std::exception& ex) {
            error = RZErrorFromException(ex);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [timer invalidate];
            workError = error;
            [self.window endSheet:controller.window];
        });
    });
}

- (void)presentErrorOrPassword:(NSError *)error retry:(void (^)(void))retry {
    if ([self promptForPasswordIfNeeded:error]) {
        retry();
        return;
    }
    if (error) {
        [self presentError:error];
    }
}

- (void)reloadAfterChange {
    NSError *error = nil;
    if (![self.archiveDocument reload:&error]) {
        [self presentErrorOrPassword:error retry:^{
            [self reloadAfterChange];
        }];
        return;
    }
    [self reloadBrowser];
}

- (IBAction)addFiles:(id)sender {
    (void)sender;
    if (![self ensureLoaded] || !self.archiveDocument.canUpdate) {
        NSBeep();
        return;
    }
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = YES;
    panel.allowsMultipleSelection = YES;
    panel.prompt = @"Add";
    panel.message = @"Choose files or folders to add to the archive.";
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
        if (result != NSModalResponseOK) {
            return;
        }
        NSMutableArray<NSString *> *paths = [NSMutableArray array];
        for (NSURL *url in panel.URLs) {
            if (url.path) {
                [paths addObject:url.path];
            }
        }
        [self addPaths:paths];
    }];
}

- (void)addPaths:(NSArray<NSString *> *)paths {
    RZDocument *doc = self.archiveDocument;
    NSString *folder = self.currentPath;
    [self runWork:@"Adding files…" work:^(rz::ProgressPtr progress) {
        std::vector<std::string> input;
        for (NSString *path in paths) {
            input.push_back(RZStd(path));
        }
        rz::Engine::instance().add(RZStd(doc.fileURL.path), input, RZStd(folder), RZStd(doc.password), progress);
    } completion:^(NSError *error) {
        if (error) {
            [self presentErrorOrPassword:error retry:^{ [self addPaths:paths]; }];
            return;
        }
        [self reloadAfterChange];
    }];
}

- (IBAction)extract:(id)sender {
    (void)sender;
    if (![self ensureLoaded]) {
        return;
    }
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = NO;
    panel.canChooseDirectories = YES;
    panel.canCreateDirectories = YES;
    panel.allowsMultipleSelection = NO;
    panel.prompt = @"Extract";
    panel.message = self.tableView.numberOfSelectedRows > 0 ?
        @"Extract the selected items to:" : @"Extract the entire archive to:";
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
        if (result != NSModalResponseOK) {
            return;
        }
        [self extractTo:panel.URL.path selectedOnly:self.tableView.numberOfSelectedRows > 0];
    }];
}

- (void)rz_removeEmptyParentsOf:(NSString *)path stoppingAt:(NSString *)root {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *dir = path.stringByDeletingLastPathComponent;
    NSString *rootPrefix = [root stringByAppendingString:@"/"];
    while (dir.length > 0 && ![dir isEqualToString:root] && [dir hasPrefix:rootPrefix]) {
        NSArray<NSString *> *contents = [fm contentsOfDirectoryAtPath:dir error:nil];
        if (contents.count > 0) {
            break;
        }
        if (![fm removeItemAtPath:dir error:nil]) {
            break;
        }
        dir = dir.stringByDeletingLastPathComponent;
    }
}

- (void)rz_flattenExtractedItems:(NSArray<RZItem *> *)items toDestination:(NSString *)destination {
    NSFileManager *fm = NSFileManager.defaultManager;
    for (RZItem *item in items) {
        NSString *archivePath = [item.path stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
        if (archivePath.length == 0 || [archivePath isEqualToString:item.name]) {
            continue;
        }
        NSString *source = [destination stringByAppendingPathComponent:archivePath];
        NSString *target = [destination stringByAppendingPathComponent:item.name];
        if ([source isEqualToString:target] || ![fm fileExistsAtPath:source]) {
            continue;
        }
        if ([fm fileExistsAtPath:target]) {
            [fm removeItemAtPath:target error:nil];
        }
        if ([fm moveItemAtPath:source toPath:target error:nil]) {
            [self rz_removeEmptyParentsOf:source stoppingAt:destination];
        }
    }
}

- (void)extractTo:(NSString *)destination selectedOnly:(BOOL)selectedOnly {
    RZDocument *doc = self.archiveDocument;
    NSArray<RZItem *> *roots = selectedOnly ? [self selectedItems] : @[];
    std::vector<std::uint32_t> indices;
    if (selectedOnly) {
        NSArray<NSNumber *> *selected = [doc indicesForItems:roots includeChildren:YES];
        for (NSNumber *number in selected) {
            indices.push_back(number.unsignedIntValue);
        }
    }
    [self runWork:@"Extracting…" work:^(rz::ProgressPtr progress) {
        rz::Engine::instance().extract(RZStd(doc.archiveFilePath), RZStd(destination), indices,
                                       RZStd(doc.password), progress, doc.engineNestIndices);
        if (selectedOnly) {
            [self rz_flattenExtractedItems:roots toDestination:destination];
        }
    } completion:^(NSError *error) {
        if (error) {
            [self presentErrorOrPassword:error retry:^{
                [self extractTo:destination selectedOnly:selectedOnly];
            }];
            return;
        }
        [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:destination]];
    }];
}

- (IBAction)testArchive:(id)sender {
    (void)sender;
    if (![self ensureLoaded]) {
        return;
    }
    RZDocument *doc = self.archiveDocument;
    [self runWork:@"Testing archive…" work:^(rz::ProgressPtr progress) {
        rz::Engine::instance().test(RZStd(doc.archiveFilePath), RZStd(doc.password), progress,
                                   doc.engineNestIndices);
    } completion:^(NSError *error) {
        if (error) {
            [self presentErrorOrPassword:error retry:^{ [self testArchive:self]; }];
            return;
        }
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"Archive is valid";
        alert.informativeText = @"No errors were found.";
        alert.alertStyle = NSAlertStyleInformational;
        [alert beginSheetModalForWindow:self.window completionHandler:nil];
    }];
}

- (void)extractAndOpenItem:(RZItem *)item {
    NSString *temp = [NSTemporaryDirectory() stringByAppendingPathComponent:@"ReZipperView"];
    [[NSFileManager defaultManager] createDirectoryAtPath:temp withIntermediateDirectories:YES attributes:nil error:nil];
    RZDocument *doc = self.archiveDocument;
    [self runWork:@"Opening…" work:^(rz::ProgressPtr progress) {
        rz::Engine::instance().extract(RZStd(doc.archiveFilePath), RZStd(temp), {item.index},
                                       RZStd(doc.password), progress, doc.engineNestIndices);
    } completion:^(NSError *error) {
        if (error) {
            [self presentErrorOrPassword:error retry:^{ [self extractAndOpenItem:item]; }];
            return;
        }
        NSString *extracted = [temp stringByAppendingPathComponent:item.path];
        if (![[NSFileManager defaultManager] fileExistsAtPath:extracted]) {
            extracted = [temp stringByAppendingPathComponent:item.name];
        }
        [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:extracted]];
    }];
}

- (void)openNestedItem:(RZItem *)item document:(RZDocument *)nested {
    [self runWork:@"Opening archive…" work:^(rz::ProgressPtr progress) {
        (void)progress;
        NSError *error = nil;
        if (![nested reload:&error]) {
            throw rz::EngineError(RZStd(error.localizedDescription.length
                                            ? error.localizedDescription
                                            : @"Could not open nested archive"),
                                  RZIsPasswordError(error));
        }
    } completion:^(NSError *error) {
        if (RZIsPasswordError(error)) {
            NSString *password = [self askPassword:@"Enter the nested archive password to continue."];
            if (password.length) {
                nested.password = password;
                [self openNestedItem:item document:nested];
            }
            return;
        }
        if (error) {
            [self extractAndOpenItem:item];
            return;
        }
        [nested presentNestedWindows];
    }];
}

- (IBAction)viewSelection:(id)sender {
    (void)sender;
    NSArray<RZItem *> *items = [self selectedItems];
    if (items.count != 1 || items.firstObject.isDir) {
        if (self.tableView.clickedRow >= 0 && (NSUInteger)self.tableView.clickedRow < self.visibleItems.count) {
            items = @[ self.visibleItems[(NSUInteger)self.tableView.clickedRow] ];
        }
    }
    RZItem *item = items.firstObject;
    if (!item || item.isDir) {
        return;
    }
    if ([RZDocument isArchiveFileName:item.name]) {
        RZDocument *nested = [RZDocument prepareNestedFrom:self.archiveDocument item:item];
        if (nested) {
            [self openNestedItem:item document:nested];
            return;
        }
    }
    [self extractAndOpenItem:item];
}

- (IBAction)deleteSelection:(id)sender {
    (void)sender;
    if (!self.archiveDocument.canUpdate) {
        NSBeep();
        return;
    }
    NSArray<RZItem *> *items = [self selectedItems];
    if (items.count == 0) {
        return;
    }
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Delete from archive?";
    alert.informativeText = [NSString stringWithFormat:@"%lu item(s) will be removed from the archive. This cannot be undone.",
                             (unsigned long)items.count];
    alert.alertStyle = NSAlertStyleWarning;
    [alert addButtonWithTitle:@"Delete"];
    [alert addButtonWithTitle:@"Cancel"];
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse returnCode) {
        if (returnCode != NSAlertFirstButtonReturn) {
            return;
        }
        RZDocument *doc = self.archiveDocument;
        std::vector<std::uint32_t> indices;
        for (NSNumber *number in [doc indicesForItems:items includeChildren:YES]) {
            indices.push_back(number.unsignedIntValue);
        }
        [self runWork:@"Deleting…" work:^(rz::ProgressPtr progress) {
            rz::Engine::instance().remove(RZStd(doc.fileURL.path), indices, RZStd(doc.password), progress);
        } completion:^(NSError *error) {
            if (error) {
                [self presentErrorOrPassword:error retry:^{ [self deleteSelection:self]; }];
                return;
            }
            [self reloadAfterChange];
        }];
    }];
}

- (IBAction)showInfo:(id)sender {
    (void)sender;
    if (self.infoController.window.sheetParent) {
        return;
    }
    self.infoController = [[RZInfoController alloc] init];
    [self.infoController presentForDocument:self.document onWindow:self.window];
}

- (RZItem *)previewableItem {
    for (RZItem *item in [self selectedItems]) {
        if (!item.isDir && !item.isVirtual) {
            return item;
        }
    }
    return nil;
}

- (void)cancelPreviewWork {
    self.previewToken++;
    if (_previewProgress) {
        _previewProgress->cancel.store(true, std::memory_order_relaxed);
    }
}

- (RZPreviewController *)ensurePreviewController {
    if (!self.previewController) {
        self.previewController = [[RZPreviewController alloc] init];
        __weak RZMainWindowController *weakSelf = self;
        self.previewController.closeHandler = ^{
            [weakSelf cancelPreviewWork];
        };
        self.previewController.keyHandler = ^BOOL(NSEvent *event) {
            RZMainWindowController *strongSelf = weakSelf;
            if (!strongSelf) {
                return NO;
            }
            NSEventModifierFlags mods = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
            if (mods == 0 && event.charactersIgnoringModifiers.length == 1 &&
                [event.charactersIgnoringModifiers characterAtIndex:0] == ' ') {
                [strongSelf togglePreview:strongSelf];
                return YES;
            }
            if (event.keyCode == 125 || event.keyCode == 126) {
                [strongSelf.tableView keyDown:event];
                return YES;
            }
            return NO;
        };
    }
    return self.previewController;
}

- (void)togglePreview:(id)sender {
    (void)sender;
    if (self.previewController.window.isVisible) {
        [self cancelPreviewWork];
        [self.previewController close];
        [self.window makeFirstResponder:self.tableView];
        return;
    }
    if (![self previewableItem]) {
        NSBeep();
        return;
    }
    [self previewSelection];
}

- (void)previewSelection {
    RZItem *item = [self previewableItem];
    RZPreviewController *preview = [self ensurePreviewController];
    [self cancelPreviewWork];
    if (!item) {
        [preview showPlaceholder:@"Preview" message:@"Select a file to preview."];
        [preview presentRelativeTo:self.window];
        return;
    }
    if (item.size > RZPreviewMaxBytes) {
        [preview showPlaceholder:item.name
                         message:@"This file is larger than 128 MB.\nPress Return to extract and open it."];
        [preview presentRelativeTo:self.window];
        return;
    }

    const NSUInteger token = ++self.previewToken;
    [preview showLoading:item.name];
    [preview presentRelativeTo:self.window];
    __weak RZMainWindowController *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(RZPreviewDebounce * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        RZMainWindowController *strongSelf = weakSelf;
        if (!strongSelf || token != strongSelf.previewToken) {
            return;
        }
        [strongSelf startPreviewExtract:item token:token];
    });
}

- (void)startPreviewExtract:(RZItem *)item token:(NSUInteger)token {
    RZDocument *doc = self.archiveDocument;
    auto progress = std::make_shared<rz::Progress>();
    _previewProgress = progress;
    const std::uint32_t index = item.index;
    const std::string path = RZStd(doc.archiveFilePath);
    const std::string password = RZStd(doc.password);
    const auto nest = doc.engineNestIndices;
    NSString *name = item.name;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        NSData *data = nil;
        try {
            const auto bytes = rz::Engine::instance().extractItem(
                path, index, password, progress, nest, RZPreviewMaxBytes);
            data = [NSData dataWithBytes:bytes.data() length:bytes.size()];
        } catch (const std::exception& ex) {
            error = RZErrorFromException(ex);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (token != self.previewToken || !self.previewController.window.isVisible) {
                return;
            }
            if (error) {
                if (RZIsPasswordError(error)) {
                    NSString *entered = [self askPassword:@"Enter the archive password to preview this file."];
                    if (entered.length) {
                        self.archiveDocument.password = entered;
                        [self previewSelection];
                    } else {
                        [self.previewController showPlaceholder:name message:error.localizedDescription];
                    }
                    return;
                }
                [self.previewController showPlaceholder:name message:error.localizedDescription];
                return;
            }
            [self.previewController showData:data name:name];
        });
    });
}

- (void)keyDown:(NSEvent *)event {
    if (event.keyCode == 51 || event.keyCode == 117) { // delete / forward delete
        [self deleteSelection:self];
        return;
    }
    if (event.keyCode == 126 && self.currentPath.length) { // up arrow with cmd is handled by menu
        [super keyDown:event];
        return;
    }
    [super keyDown:event];
}

@end
