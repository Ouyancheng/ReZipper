#import "RZDocument.h"
#import "RZMainWindowController.h"

@interface RZDocument ()
@property (nonatomic, copy, readwrite) NSArray<RZItem *> *items;
@property (nonatomic, copy, readwrite) NSString *formatName;
@property (nonatomic, assign, readwrite) BOOL canUpdate;
@property (nonatomic, assign, readwrite) BOOL encrypted;
@property (nonatomic, assign, readwrite) BOOL solid;
@property (nonatomic, assign, readwrite) NSUInteger fileCount;
@property (nonatomic, assign, readwrite) NSUInteger folderCount;
@property (nonatomic, assign, readwrite) unsigned long long totalSize;
@property (nonatomic, assign, readwrite) unsigned long long packedSize;
@property (nonatomic, strong, readwrite) RZFolderNode *rootFolder;
@end

@implementation RZDocument

+ (BOOL)autosavesInPlace {
    return NO;
}

+ (BOOL)autosavesDrafts {
    return NO;
}

- (void)encodeRestorableStateWithCoder:(NSCoder *)coder {
    (void)coder;
}

+ (BOOL)canConcurrentlyReadDocumentsOfType:(NSString *)typeName {
    (void)typeName;
    return NO;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _password = @"";
        _items = @[];
        _formatName = @"archive";
        _rootFolder = [[RZFolderNode alloc] init];
        _rootFolder.name = @"Archive";
    }
    return self;
}

- (void)makeWindowControllers {
    RZMainWindowController *controller = [[RZMainWindowController alloc] init];
    [self addWindowController:controller];
}

- (BOOL)readFromURL:(NSURL *)url ofType:(NSString *)typeName error:(NSError **)outError {
    (void)typeName;
    NSError *error = nil;
    if ([self reloadFromURL:url error:&error]) {
        self.needsPassword = NO;
        [self notifyWindows];
        return YES;
    }
    if (RZIsPasswordError(error)) {
        self.needsPassword = YES;
        [self notifyWindows];
        return YES;
    }
    if (outError) {
        *outError = error;
    }
    return NO;
}

- (void)setFileURL:(NSURL *)url {
    [super setFileURL:url];
    if (url.isFileURL && self.items.count == 0 && !self.needsPassword) {
        if ([self reloadFromURL:url error:nil]) {
            [self notifyWindows];
        }
    }
}

- (void)notifyWindows {
    for (NSWindowController *controller in self.windowControllers) {
        if ([controller respondsToSelector:@selector(reloadBrowser)]) {
            [(id)controller reloadBrowser];
        }
    }
}

- (BOOL)writeToURL:(NSURL *)url ofType:(NSString *)typeName error:(NSError **)outError {
    (void)url;
    (void)typeName;
    if (outError) {
        *outError = RZError(@"ReZipper archives are saved by adding or deleting items.");
    }
    return NO;
}

- (BOOL)reload:(NSError **)error {
    return [self reloadFromURL:self.fileURL error:error];
}

- (BOOL)reloadFromURL:(NSURL *)url error:(NSError **)error {
    if (!url.isFileURL) {
        url = self.fileURL;
    }
    if (!url.isFileURL) {
        if (error) {
            *error = RZError(@"The archive is not on disk.");
        }
        return NO;
    }
    try {
        const auto info = rz::Engine::instance().list(RZStd(url.path), RZStd(self.password));
        NSMutableArray<RZItem *> *items = [NSMutableArray arrayWithCapacity:info.items.size()];
        RZFolderNode *root = [[RZFolderNode alloc] init];
        root.name = url.lastPathComponent;
        root.path = @"";
        for (const auto& entry : info.items) {
            RZItem *item = [[RZItem alloc] initWithEngineItem:entry];
            [items addObject:item];
            if (item.isDir || [item.path containsString:@"/"]) {
                RZFolderNode *node = root;
                NSArray<NSString *> *parts = [item.path componentsSeparatedByString:@"/"];
                NSUInteger limit = item.isDir ? parts.count : parts.count - 1;
                for (NSUInteger i = 0; i < limit; i++) {
                    NSString *part = parts[i];
                    if (part.length == 0) {
                        continue;
                    }
                    node = [node childNamed:part create:YES];
                }
            }
        }
        self.items = items;
        self.formatName = RZNS(info.formatName);
        self.canUpdate = info.canUpdate;
        self.encrypted = info.encrypted;
        self.solid = info.solid;
        self.fileCount = info.fileCount;
        self.folderCount = info.folderCount;
        self.totalSize = info.totalSize;
        self.packedSize = info.packedSize;
        self.rootFolder = root;
        return YES;
    } catch (const std::exception& ex) {
        if (error) {
            *error = RZErrorFromException(ex);
        }
        return NO;
    }
}

- (NSArray<RZItem *> *)itemsInFolder:(NSString *)folderPath {
    NSMutableArray<RZItem *> *result = [NSMutableArray array];
    for (RZItem *item in self.items) {
        if ([[item parentPath] isEqualToString:folderPath]) {
            [result addObject:item];
        }
    }
    [result sortUsingComparator:^NSComparisonResult(RZItem *lhs, RZItem *rhs) {
        if (lhs.isDir != rhs.isDir) {
            return lhs.isDir ? NSOrderedAscending : NSOrderedDescending;
        }
        return [lhs.name localizedStandardCompare:rhs.name];
    }];
    return result;
}

- (NSArray<NSNumber *> *)indicesForItems:(NSArray<RZItem *> *)items includeChildren:(BOOL)includeChildren {
    NSMutableIndexSet *set = [NSMutableIndexSet indexSet];
    for (RZItem *item in items) {
        [set addIndex:item.index];
        if (includeChildren && item.isDir) {
            NSString *prefix = item.path.length ? [item.path stringByAppendingString:@"/"] : @"";
            for (RZItem *candidate in self.items) {
                if ([candidate.path isEqualToString:item.path] ||
                    (prefix.length && [candidate.path hasPrefix:prefix])) {
                    [set addIndex:candidate.index];
                }
            }
        }
    }
    NSMutableArray<NSNumber *> *indices = [NSMutableArray array];
    [set enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
        (void)stop;
        [indices addObject:@(idx)];
    }];
    return indices;
}

@end
