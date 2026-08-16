#import "RZCommon.h"

@implementation RZItem

- (instancetype)initWithEngineItem:(const rz::Item &)item {
    self = [super init];
    if (self) {
        _index = item.index;
        _path = RZNS(item.path);
        _name = RZNS(item.name);
        _method = RZNS(item.method);
        _isDir = item.isDir;
        _encrypted = item.encrypted;
        _size = item.size;
        _packedSize = item.packedSize;
        _mtimeUnix = item.mtimeUnix;
        _crc = item.crc;
        if (_name.length == 0) {
            _name = _path.lastPathComponent;
        }
    }
    return self;
}

- (NSString *)parentPath {
    NSString *path = self.path;
    NSRange slash = [path rangeOfString:@"/" options:NSBackwardsSearch];
    if (slash.location == NSNotFound) {
        return @"";
    }
    return [path substringToIndex:slash.location];
}

@end

@implementation RZFolderNode

- (instancetype)init {
    self = [super init];
    if (self) {
        _name = @"";
        _path = @"";
        _children = [NSMutableArray array];
    }
    return self;
}

- (RZFolderNode *)childNamed:(NSString *)name create:(BOOL)create {
    for (RZFolderNode *child in self.children) {
        if ([child.name isEqualToString:name]) {
            return child;
        }
    }
    if (!create) {
        return nil;
    }
    RZFolderNode *child = [[RZFolderNode alloc] init];
    child.name = name;
    child.path = self.path.length == 0 ? name : [self.path stringByAppendingPathComponent:name];
    [self.children addObject:child];
    return child;
}

- (RZFolderNode *)nodeForPath:(NSString *)path {
    if (path.length == 0) {
        return self;
    }
    RZFolderNode *node = self;
    for (NSString *part in [path componentsSeparatedByString:@"/"]) {
        if (part.length == 0) {
            continue;
        }
        node = [node childNamed:part create:NO];
        if (!node) {
            return nil;
        }
    }
    return node;
}

@end
