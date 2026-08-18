#pragma once

#include <atomic>
#include <cstdint>
#include <functional>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <vector>

namespace rz {

enum class Format {
    SevenZip,
    Zip,
    Tar,
    GZip,
    BZip2,
    Xz,
    Wim,
    Unknown
};

struct Item {
    std::uint32_t index = 0;
    std::string path;
    std::string name;
    bool isDir = false;
    std::uint64_t size = 0;
    std::uint64_t packedSize = 0;
    std::int64_t mtimeUnix = 0;
    std::uint32_t crc = 0;
    std::string method;
    bool encrypted = false;
};

struct ArchiveInfo {
    std::string path;
    std::string formatName;
    Format format = Format::Unknown;
    bool canUpdate = false;
    bool encrypted = false;
    bool solid = false;
    std::uint32_t fileCount = 0;
    std::uint32_t folderCount = 0;
    std::uint64_t totalSize = 0;
    std::uint64_t packedSize = 0;
    std::vector<Item> items;
};

struct CreateOptions {
    Format format = Format::SevenZip;
    int level = 5;
    std::string password;
    bool encryptHeaders = false;
    bool solid = true;
};

struct Progress {
    std::atomic<std::uint64_t> total{0};
    std::atomic<std::uint64_t> processed{0};
    std::atomic<bool> cancel{false};

    // Written by the worker thread, polled by the UI thread, so the string
    // itself must never be touched by both at once.
    void setCurrentFile(const std::string& file) {
        std::lock_guard<std::mutex> lock(fileMutex_);
        currentFile_ = file;
    }

    std::string takeCurrentFile() const {
        std::lock_guard<std::mutex> lock(fileMutex_);
        return currentFile_;
    }

private:
    mutable std::mutex fileMutex_;
    std::string currentFile_;
};

using ProgressPtr = std::shared_ptr<Progress>;

class EngineError : public std::runtime_error {
public:
    explicit EngineError(const std::string& message, bool password = false)
        : std::runtime_error(message), passwordError_(password) {}

    bool isPasswordError() const { return passwordError_; }

private:
    bool passwordError_ = false;
};

class Engine {
public:
    static Engine& instance();

    void setLibraryPath(const std::string& path);
    const std::string& libraryPath() const { return libraryPath_; }

    ArchiveInfo list(const std::string& archivePath, const std::string& password = "");
    ArchiveInfo list(const std::string& archivePath,
                     const std::vector<std::uint32_t>& nestIndices,
                     const std::string& password);

    void extract(const std::string& archivePath,
                 const std::string& destination,
                 const std::vector<std::uint32_t>& indices,
                 const std::string& password,
                 const ProgressPtr& progress,
                 const std::vector<std::uint32_t>& nestIndices = {});

    // Decompress one item into memory. Does not write the archive to disk.
    // If maxBytes > 0, stops and throws when that item (not its nest container)
    // is larger than that. Nested archives reuse the blob from list() while
    // retainNestedBlob() holders remain, or until the outer archive changes.
    std::vector<std::uint8_t> extractItem(const std::string& archivePath,
                                          std::uint32_t index,
                                          const std::string& password,
                                          const ProgressPtr& progress,
                                          const std::vector<std::uint32_t>& nestIndices = {},
                                          std::uint64_t maxBytes = 0);

    void retainNestedBlob(const std::string& archivePath,
                          const std::vector<std::uint32_t>& nestIndices);
    void releaseNestedBlob(const std::string& archivePath,
                           const std::vector<std::uint32_t>& nestIndices);

    void test(const std::string& archivePath,
              const std::string& password,
              const ProgressPtr& progress,
              const std::vector<std::uint32_t>& nestIndices = {});

    void create(const std::string& archivePath,
                const std::vector<std::string>& inputPaths,
                const CreateOptions& options,
                const ProgressPtr& progress);

    void add(const std::string& archivePath,
             const std::vector<std::string>& inputPaths,
             const std::string& archiveFolder,
             const std::string& password,
             const ProgressPtr& progress);

    void remove(const std::string& archivePath,
                const std::vector<std::uint32_t>& indices,
                const std::string& password,
                const ProgressPtr& progress);

    static std::string extensionForFormat(Format format);
    static std::string displayNameForFormat(Format format);
    static Format formatFromExtension(const std::string& pathOrExt);
    static bool isArchiveFileName(const std::string& name);

private:
    Engine() = default;
    std::string libraryPath_;
};

} // namespace rz
