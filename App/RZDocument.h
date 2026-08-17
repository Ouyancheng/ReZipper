#pragma once

#import <Cocoa/Cocoa.h>
#import "RZCommon.h"

NS_ASSUME_NONNULL_BEGIN

@interface RZDocument : NSDocument
@property (nonatomic, copy) NSString *password;
@property (nonatomic, assign) BOOL needsPassword;
@property (nonatomic, copy, readonly) NSArray<RZItem *> *items;
@property (nonatomic, copy, readonly) NSString *formatName;
@property (nonatomic, assign, readonly) BOOL canUpdate;
@property (nonatomic, assign, readonly) BOOL encrypted;
@property (nonatomic, assign, readonly) BOOL solid;
@property (nonatomic, assign, readonly) NSUInteger fileCount;
@property (nonatomic, assign, readonly) NSUInteger folderCount;
@property (nonatomic, assign, readonly) unsigned long long totalSize;
@property (nonatomic, assign, readonly) unsigned long long packedSize;
@property (nonatomic, strong, readonly) RZFolderNode *rootFolder;
@property (nonatomic, copy, readonly, nullable) NSString *nestRootPath;
@property (nonatomic, copy, readonly) NSArray<NSNumber *> *nestIndices;
@property (nonatomic, copy, readonly, nullable) NSString *nestTitle;

+ (BOOL)isArchiveFileName:(NSString *)name;
+ (nullable instancetype)prepareNestedFrom:(RZDocument *)parent item:(RZItem *)item;
+ (nullable instancetype)openNestedFrom:(RZDocument *)parent
                                   item:(RZItem *)item
                                  error:(NSError * _Nullable * _Nullable)error;
- (void)presentNestedWindows;

- (NSString *)archiveFilePath;
- (std::vector<std::uint32_t>)engineNestIndices;
- (BOOL)reload:(NSError * _Nullable * _Nullable)error;
- (BOOL)reloadFromURL:(NSURL *)url error:(NSError * _Nullable * _Nullable)error;
- (void)notifyWindows;
- (NSArray<RZItem *> *)itemsInFolder:(NSString *)folderPath;
- (NSArray<NSNumber *> *)indicesForItems:(NSArray<RZItem *> *)items includeChildren:(BOOL)includeChildren;
@end

NS_ASSUME_NONNULL_END
