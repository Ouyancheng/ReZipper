#import "RZDocument.h"
#import "RZMainWindowController.h"

static void RZAddVirtualFolders(RZFolderNode *node,
                                NSMutableArray<RZItem *> *items,
                                NSMutableSet<NSString *> *dirPaths) {
    for (RZFolderNode *child in node.children) {
        if (![dirPaths containsObject:child.path]) {
            RZItem *folder = [[RZItem alloc] init];
            folder.isDir = YES;
            folder.isVirtual = YES;
            folder.name = child.name;
            folder.path = child.path;
            folder.method = @"";
            [items addObject:folder];
            [dirPaths addObject:child.path];
        }
        RZAddVirtualFolders(child, items, dirPaths);
    }
}

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
@property (nonatomic, copy, readwrite) NSString *nestRootPath;
@property (nonatomic, copy, readwrite) NSArray<NSNumber *> *nestIndices;
@property (nonatomic, copy, readwrite) NSString *nestTitle;
- (void)applyInfo:(const rz::ArchiveInfo &)info rootName:(NSString *)rootName;
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
        _nestIndices = @[];
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

+ (BOOL)isArchiveFileName:(NSString *)name {
    return rz::Engine::isArchiveFileName(RZStd(name));
}

+ (instancetype)prepareNestedFrom:(RZDocument *)parent item:(RZItem *)item {
    if (!parent || !item || item.isDir || !parent.archiveFilePath.length) {
        return nil;
    }
    RZDocument *doc = [[RZDocument alloc] init];
    doc.password = parent.password ?: @"";
    doc.nestRootPath = parent.archiveFilePath;
    NSMutableArray<NSNumber *> *chain = [parent.nestIndices mutableCopy] ?: [NSMutableArray array];
    [chain addObject:@(item.index)];
    doc.nestIndices = chain;
    doc.nestTitle = item.name;
    return doc;
}

- (void)presentNestedWindows {
    [[NSDocumentController sharedDocumentController] addDocument:self];
    [self makeWindowControllers];
    [self showWindows];
}

+ (instancetype)openNestedFrom:(RZDocument *)parent item:(RZItem *)item error:(NSError **)error {
    RZDocument *doc = [self prepareNestedFrom:parent item:item];
    if (!doc) {
        return nil;
    }
    if (![doc reload:error]) {
        return nil;
    }
    [doc presentNestedWindows];
    return doc;
}

- (NSString *)archiveFilePath {
    if (self.nestRootPath.length) {
        return self.nestRootPath;
    }
    return self.fileURL.path;
}

- (std::vector<std::uint32_t>)engineNestIndices {
    std::vector<std::uint32_t> nest;
    nest.reserve(self.nestIndices.count);
    for (NSNumber *number in self.nestIndices) {
        nest.push_back(number.unsignedIntValue);
    }
    return nest;
}

- (NSString *)displayName {
    if (self.nestTitle.length) {
        return self.nestTitle;
    }
    return [super displayName];
}

- (void)applyInfo:(const rz::ArchiveInfo &)info rootName:(NSString *)rootName {
    NSMutableArray<RZItem *> *items = [NSMutableArray arrayWithCapacity:info.items.size()];
    NSMutableSet<NSString *> *dirPaths = [NSMutableSet set];
    RZFolderNode *root = [[RZFolderNode alloc] init];
    root.name = rootName.length ? rootName : @"Archive";
    root.path = @"";
    for (const auto& entry : info.items) {
        RZItem *item = [[RZItem alloc] initWithEngineItem:entry];
        [items addObject:item];
        if (item.isDir) {
            [dirPaths addObject:item.path];
        }
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
    // Zips often store "folder/file.txt" without a "folder/" directory entry.
    RZAddVirtualFolders(root, items, dirPaths);
    self.items = items;
    self.formatName = RZNS(info.formatName);
    self.canUpdate = info.canUpdate && self.nestIndices.count == 0;
    self.encrypted = info.encrypted;
    self.solid = info.solid;
    self.fileCount = info.fileCount;
    self.folderCount = info.folderCount;
    self.totalSize = info.totalSize;
    self.packedSize = info.packedSize;
    self.rootFolder = root;
}

- (BOOL)reload:(NSError **)error {
    if (self.nestRootPath.length) {
        try {
            const auto info = rz::Engine::instance().list(RZStd(self.nestRootPath),
                                                          self.engineNestIndices,
                                                          RZStd(self.password));
            [self applyInfo:info rootName:self.nestTitle ?: @"Archive"];
            return YES;
        } catch (const std::exception& ex) {
            if (error) {
                *error = RZErrorFromException(ex);
            }
            return NO;
        }
    }
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
        [self applyInfo:info rootName:url.lastPathComponent];
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
        if (!item.isVirtual) {
            [set addIndex:item.index];
        }
        if (includeChildren && item.isDir) {
            NSString *prefix = item.path.length ? [item.path stringByAppendingString:@"/"] : @"";
            for (RZItem *candidate in self.items) {
                if (candidate.isVirtual) {
                    continue;
                }
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
