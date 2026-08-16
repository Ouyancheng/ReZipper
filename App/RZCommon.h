#pragma once

#import <Cocoa/Cocoa.h>
#include "ArchiveEngine.hpp"
#include <string>

NS_ASSUME_NONNULL_BEGIN

static inline NSString *RZNS(const std::string& value) {
    return [[NSString alloc] initWithUTF8String:value.c_str()] ?: @"";
}

static inline std::string RZStd(NSString * _Nullable value) {
    if (value.length == 0) {
        return {};
    }
    const char *utf8 = value.UTF8String;
    return utf8 ? std::string(utf8) : std::string();
}

static inline NSError *RZError(NSString *message, BOOL password = NO) {
    return [NSError errorWithDomain:@"app.rezipper"
                               code:password ? 2 : 1
                           userInfo:@{NSLocalizedDescriptionKey: message ?: @"Unknown error"}];
}

static inline NSError *RZErrorFromException(const std::exception& ex) {
    const auto *engine = dynamic_cast<const rz::EngineError *>(&ex);
    return RZError(RZNS(ex.what()), engine && engine->isPasswordError());
}

static inline BOOL RZIsPasswordError(NSError * _Nullable error) {
    return error && [error.domain isEqualToString:@"app.rezipper"] && error.code == 2;
}

@interface RZItem : NSObject
@property (nonatomic, assign) std::uint32_t index;
@property (nonatomic, copy) NSString *path;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *method;
@property (nonatomic, assign) BOOL isDir;
@property (nonatomic, assign) BOOL encrypted;
@property (nonatomic, assign) std::uint64_t size;
@property (nonatomic, assign) std::uint64_t packedSize;
@property (nonatomic, assign) std::int64_t mtimeUnix;
@property (nonatomic, assign) std::uint32_t crc;
- (instancetype)initWithEngineItem:(const rz::Item &)item;
- (NSString *)parentPath;
@end

@interface RZFolderNode : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *path;
@property (nonatomic, strong) NSMutableArray<RZFolderNode *> *children;
- (RZFolderNode *)childNamed:(NSString *)name create:(BOOL)create;
- (RZFolderNode *)nodeForPath:(NSString *)path;
@end

NS_ASSUME_NONNULL_END
