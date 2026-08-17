#include "ArchiveEngine.hpp"

#include <bit7z/bit7z.hpp>

#include <cctype>
#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iconv.h>
#include <mutex>
#include <optional>
#include <stdexcept>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>

namespace fs = std::filesystem;
using namespace bit7z;

namespace rz {
namespace {

std::mutex gMutex;
std::unique_ptr<Bit7zLibrary> gLib;
std::string gLoadedPath;

Bit7zLibrary& library(const std::string& path) {
    if (path.empty()) {
        throw EngineError("7-Zip library path is empty");
    }
    if (!gLib || gLoadedPath != path) {
        gLib = std::make_unique<Bit7zLibrary>(path);
        gLoadedPath = path;
    }
    return *gLib;
}

bool isPasswordFailure(const BitException& ex) {
    return ex.code() == BitFailureSource::WrongPassword;
}

[[noreturn]] void rethrow(const BitException& ex) {
    throw EngineError(ex.what(), isPasswordFailure(ex));
}

const BitInOutFormat& inoutFormat(Format format) {
    switch (format) {
    case Format::SevenZip: return BitFormat::SevenZip;
    case Format::Zip:      return BitFormat::Zip;
    case Format::Tar:      return BitFormat::Tar;
    case Format::GZip:     return BitFormat::GZip;
    case Format::BZip2:    return BitFormat::BZip2;
    case Format::Xz:       return BitFormat::Xz;
    case Format::Wim:      return BitFormat::Wim;
    case Format::Unknown:
        break;
    }
    throw EngineError("Unsupported archive format for writing");
}

Format formatFromBit(const BitInFormat& fmt) {
    if (fmt == BitFormat::SevenZip) return Format::SevenZip;
    if (fmt == BitFormat::Zip)      return Format::Zip;
    if (fmt == BitFormat::Tar)      return Format::Tar;
    if (fmt == BitFormat::GZip)     return Format::GZip;
    if (fmt == BitFormat::BZip2)    return Format::BZip2;
    if (fmt == BitFormat::Xz)       return Format::Xz;
    if (fmt == BitFormat::Wim)      return Format::Wim;
    return Format::Unknown;
}

std::string nameFromBit(const BitInFormat& fmt) {
    if (fmt == BitFormat::SevenZip) return "7z";
    if (fmt == BitFormat::Zip)      return "zip";
    if (fmt == BitFormat::Tar)      return "tar";
    if (fmt == BitFormat::GZip)     return "gzip";
    if (fmt == BitFormat::BZip2)    return "bzip2";
    if (fmt == BitFormat::Xz)       return "xz";
    if (fmt == BitFormat::Wim)      return "wim";
    if (fmt == BitFormat::Rar || fmt == BitFormat::Rar5) return "rar";
    if (fmt == BitFormat::Cab)      return "cab";
    if (fmt == BitFormat::Iso)      return "iso";
    if (fmt == BitFormat::Dmg)      return "dmg";
    if (fmt == BitFormat::Nsis)     return "nsis";
    if (fmt == BitFormat::Cpio)     return "cpio";
    if (fmt == BitFormat::Rpm)      return "rpm";
    if (fmt == BitFormat::Deb)      return "deb";
    if (fmt == BitFormat::Chm)      return "chm";
    if (fmt == BitFormat::Hfs)      return "hfs";
    if (fmt == BitFormat::Ntfs)     return "ntfs";
    if (fmt == BitFormat::Fat)      return "fat";
    if (fmt == BitFormat::Vhd || fmt == BitFormat::Vhdx) return "vhd";
    if (fmt == BitFormat::Udf)      return "udf";
    if (fmt == BitFormat::Xar)      return "xar";
    if (fmt == BitFormat::Split)    return "split";
    if (fmt == BitFormat::Lzma)     return "lzma";
    if (fmt == BitFormat::Zstd)     return "zstd";
    if (fmt == BitFormat::Compound) return "compound";
    return "archive";
}

BitCompressionLevel compressionLevel(int level) {
    switch (level) {
    case 0: return BitCompressionLevel::None;
    case 1: return BitCompressionLevel::Fastest;
    case 3: return BitCompressionLevel::Fast;
    case 7: return BitCompressionLevel::Max;
    case 9: return BitCompressionLevel::Ultra;
    default: return BitCompressionLevel::Normal;
    }
}

void attachProgress(BitAbstractArchiveHandler& handler, const ProgressPtr& progress) {
    if (!progress) {
        return;
    }
    handler.setTotalCallback([progress](std::uint64_t total) {
        progress->total.store(total, std::memory_order_relaxed);
    });
    handler.setProgressCallback([progress](std::uint64_t processed) {
        progress->processed.store(processed, std::memory_order_relaxed);
        return !progress->cancel.load(std::memory_order_relaxed);
    });
    handler.setFileCallback([progress](const tstring& file) {
        progress->currentFile = file;
    });
}

std::string posixPath(std::string path) {
    for (char& ch : path) {
        if (ch == '\\') {
            ch = '/';
        }
    }
    while (!path.empty() && path.front() == '/') {
        path.erase(path.begin());
    }
    // ZIP directory entries are stored as "folder/". That trailing slash
    // makes parentPath() skip the folder at the archive root.
    while (!path.empty() && path.back() == '/') {
        path.pop_back();
    }
    return path;
}

std::string leafName(const std::string& path) {
    const auto pos = path.find_last_of('/');
    if (pos == std::string::npos) {
        return path;
    }
    return path.substr(pos + 1);
}

uint16_t rz_u16(const char* p) {
    return static_cast<uint16_t>(static_cast<unsigned char>(p[0]) |
                                 (static_cast<unsigned char>(p[1]) << 8));
}

uint32_t rz_u32(const char* p) {
    return static_cast<uint32_t>(static_cast<unsigned char>(p[0]) |
                                 (static_cast<unsigned char>(p[1]) << 8) |
                                 (static_cast<unsigned char>(p[2]) << 16) |
                                 (static_cast<unsigned char>(p[3]) << 24));
}

uint64_t rz_u64(const char* p) {
    return static_cast<uint64_t>(rz_u32(p)) | (static_cast<uint64_t>(rz_u32(p + 4)) << 32);
}

struct ZipCdName {
    std::string raw;
    bool utf8 = false;
};

std::vector<ZipCdName> readZipCentralNames(const std::string& path) {
    std::ifstream file(path, std::ios::binary);
    if (!file) {
        return {};
    }
    file.seekg(0, std::ios::end);
    const auto fileSize = static_cast<uint64_t>(file.tellg());
    if (fileSize < 22) {
        return {};
    }

    const uint64_t scan = std::min<uint64_t>(fileSize, 65557);
    std::vector<char> tail(scan);
    file.seekg(static_cast<std::streamoff>(fileSize - scan));
    file.read(tail.data(), static_cast<std::streamsize>(scan));
    if (file.gcount() != static_cast<std::streamsize>(scan)) {
        return {};
    }

    int eocd = -1;
    for (int i = static_cast<int>(scan) - 22; i >= 0; --i) {
        if (tail[static_cast<size_t>(i)] == 'P' && tail[static_cast<size_t>(i) + 1] == 'K' &&
            static_cast<unsigned char>(tail[static_cast<size_t>(i) + 2]) == 5 &&
            static_cast<unsigned char>(tail[static_cast<size_t>(i) + 3]) == 6) {
            eocd = i;
            break;
        }
    }
    if (eocd < 0) {
        return {};
    }

    const char* e = tail.data() + eocd;
    uint64_t nent = rz_u16(e + 10);
    uint64_t cdSize = rz_u32(e + 12);
    uint64_t cdOff = rz_u32(e + 16);
    if (nent == 0xffff || cdSize == 0xffffffffu || cdOff == 0xffffffffu) {
        int loc = -1;
        for (int i = eocd - 20; i >= 0; --i) {
            if (tail[static_cast<size_t>(i)] == 'P' && tail[static_cast<size_t>(i) + 1] == 'K' &&
                static_cast<unsigned char>(tail[static_cast<size_t>(i) + 2]) == 6 &&
                static_cast<unsigned char>(tail[static_cast<size_t>(i) + 3]) == 7) {
                loc = i;
                break;
            }
        }
        if (loc < 0) {
            return {};
        }
        const uint64_t zip64Off = rz_u64(tail.data() + loc + 8);
        std::vector<char> z64(56);
        file.clear();
        file.seekg(static_cast<std::streamoff>(zip64Off));
        file.read(z64.data(), 56);
        if (file.gcount() < 56 || z64[0] != 'P' || z64[1] != 'K') {
            return {};
        }
        nent = rz_u64(z64.data() + 32);
        cdSize = rz_u64(z64.data() + 40);
        cdOff = rz_u64(z64.data() + 48);
    }
    if (nent == 0 || cdSize == 0 || cdOff + cdSize > fileSize || cdSize > 64 * 1024 * 1024) {
        return {};
    }

    std::vector<char> cd(cdSize);
    file.clear();
    file.seekg(static_cast<std::streamoff>(cdOff));
    file.read(cd.data(), static_cast<std::streamsize>(cdSize));
    if (file.gcount() != static_cast<std::streamsize>(cdSize)) {
        return {};
    }

    std::vector<ZipCdName> names;
    names.reserve(static_cast<size_t>(nent));
    size_t pos = 0;
    while (pos + 46 <= cd.size() && names.size() < nent) {
        if (cd[pos] != 'P' || cd[pos + 1] != 'K' ||
            static_cast<unsigned char>(cd[pos + 2]) != 1 ||
            static_cast<unsigned char>(cd[pos + 3]) != 2) {
            break;
        }
        const uint16_t flags = rz_u16(cd.data() + pos + 8);
        const uint16_t nameLen = rz_u16(cd.data() + pos + 28);
        const uint16_t extraLen = rz_u16(cd.data() + pos + 30);
        const uint16_t commentLen = rz_u16(cd.data() + pos + 32);
        if (pos + 46 + nameLen + extraLen + commentLen > cd.size()) {
            break;
        }
        ZipCdName entry;
        entry.raw.assign(cd.data() + pos + 46, nameLen);
        entry.utf8 = (flags & 0x800) != 0;
        names.push_back(std::move(entry));
        pos += 46 + nameLen + extraLen + commentLen;
    }
    return names;
}

bool isValidUtf8(const std::string& text) {
    const auto* p = reinterpret_cast<const unsigned char*>(text.data());
    const auto* end = p + text.size();
    while (p < end) {
        if (*p <= 0x7F) {
            ++p;
            continue;
        }
        int extra = 0;
        if ((*p & 0xE0) == 0xC0) {
            extra = 1;
        } else if ((*p & 0xF0) == 0xE0) {
            extra = 2;
        } else if ((*p & 0xF8) == 0xF0) {
            extra = 3;
        } else {
            return false;
        }
        if (p + extra >= end) {
            return false;
        }
        for (int i = 1; i <= extra; ++i) {
            if ((p[i] & 0xC0) != 0x80) {
                return false;
            }
        }
        p += extra + 1;
    }
    return true;
}

std::optional<std::string> iconvToUtf8(const std::string& input, const char* from) {
    iconv_t cd = iconv_open("UTF-8", from);
    if (cd == reinterpret_cast<iconv_t>(-1)) {
        return std::nullopt;
    }
    std::string output;
    output.resize(input.size() * 4 + 16);
    char* inPtr = const_cast<char*>(input.data());
    size_t inLeft = input.size();
    char* outPtr = output.data();
    size_t outLeft = output.size();
    const size_t rc = iconv(cd, &inPtr, &inLeft, &outPtr, &outLeft);
    iconv_close(cd);
    if (rc == static_cast<size_t>(-1) || inLeft != 0) {
        return std::nullopt;
    }
    output.resize(output.size() - outLeft);
    return output;
}

int scoreUtf8Text(const std::string& text) {
    int score = 0;
    const auto* p = reinterpret_cast<const unsigned char*>(text.data());
    const auto* end = p + text.size();
    while (p < end) {
        if (*p <= 0x7F) {
            if (*p < 0x20 && *p != '\t') {
                score -= 8;
            } else {
                score += 1;
            }
            ++p;
            continue;
        }
        int extra = 0;
        uint32_t cp = 0;
        if ((*p & 0xE0) == 0xC0) {
            extra = 1;
            cp = *p & 0x1F;
        } else if ((*p & 0xF0) == 0xE0) {
            extra = 2;
            cp = *p & 0x0F;
        } else if ((*p & 0xF8) == 0xF0) {
            extra = 3;
            cp = *p & 0x07;
        } else {
            return -100000;
        }
        if (p + extra >= end) {
            return -100000;
        }
        for (int i = 1; i <= extra; ++i) {
            cp = (cp << 6) | (p[i] & 0x3F);
        }
        p += extra + 1;
        if (cp == 0xFFFD) {
            score -= 50;
        } else if ((cp >= 0x4E00 && cp <= 0x9FFF) || (cp >= 0x3400 && cp <= 0x4DBF) ||
                   (cp >= 0x3040 && cp <= 0x30FF) || (cp >= 0xAC00 && cp <= 0xD7AF) ||
                   (cp >= 0xFF00 && cp <= 0xFFEF)) {
            score += 8;
        } else {
            score += 2;
        }
    }
    return score;
}

const char* preferredLegacyEncoding() {
    const char* lang = std::getenv("LANG");
    const char* lc = std::getenv("LC_ALL");
    const char* ctype = std::getenv("LC_CTYPE");
    std::string locale = lc ? lc : (ctype ? ctype : (lang ? lang : ""));
    for (char& ch : locale) {
        ch = static_cast<char>(std::tolower(static_cast<unsigned char>(ch)));
    }
    if (locale.find("zh_tw") != std::string::npos || locale.find("zh_hk") != std::string::npos ||
        locale.find("zh_mo") != std::string::npos) {
        return "BIG5";
    }
    if (locale.find("zh") != std::string::npos) {
        return "GB18030";
    }
    if (locale.find("ja") != std::string::npos) {
        return "SHIFT_JIS";
    }
    if (locale.find("ko") != std::string::npos) {
        return "EUC-KR";
    }
    return nullptr;
}

const char* detectLegacyEncoding(const std::vector<std::string>& rawNames) {
    if (rawNames.empty()) {
        return nullptr;
    }
    bool allUtf8 = true;
    bool anyHigh = false;
    for (const auto& name : rawNames) {
        for (unsigned char ch : name) {
            if (ch >= 0x80) {
                anyHigh = true;
                break;
            }
        }
        if (!isValidUtf8(name)) {
            allUtf8 = false;
        }
    }
    if (!anyHigh || allUtf8) {
        return nullptr;
    }

    static const char* kEncodings[] = {"GB18030", "GBK", "SHIFT_JIS", "CP932", "BIG5", "EUC-KR"};
    const char* best = nullptr;
    int bestScore = 0;
    const char* preferred = preferredLegacyEncoding();
    for (const char* enc : kEncodings) {
        int score = 0;
        bool ok = true;
        for (const auto& name : rawNames) {
            const auto decoded = iconvToUtf8(name, enc);
            if (!decoded) {
                ok = false;
                break;
            }
            score += scoreUtf8Text(*decoded);
        }
        if (!ok) {
            continue;
        }
        if (preferred && std::strcmp(enc, preferred) == 0) {
            score += 40;
        }
        if (score > bestScore) {
            bestScore = score;
            best = enc;
        }
    }
    return best;
}

std::unordered_map<std::uint32_t, std::string> zipDecodedPaths(const std::string& archivePath) {
    const auto entries = readZipCentralNames(archivePath);
    if (entries.empty()) {
        return {};
    }
    std::vector<std::string> legacy;
    for (const auto& entry : entries) {
        if (!entry.utf8) {
            legacy.push_back(entry.raw);
        }
    }
    const char* encoding = detectLegacyEncoding(legacy);
    if (!encoding) {
        return {};
    }

    std::unordered_map<std::uint32_t, std::string> names;
    for (std::uint32_t i = 0; i < entries.size(); ++i) {
        const auto& entry = entries[i];
        std::optional<std::string> decoded;
        if (entry.utf8 || isValidUtf8(entry.raw)) {
            decoded = entry.raw;
        } else {
            decoded = iconvToUtf8(entry.raw, encoding);
        }
        if (!decoded || decoded->empty()) {
            continue;
        }
        names[i] = posixPath(*decoded);
    }
    return names;
}

void applyZipNames(std::vector<Item>& items, const std::unordered_map<std::uint32_t, std::string>& names) {
    if (names.empty()) {
        return;
    }
    for (auto& item : items) {
        const auto it = names.find(item.index);
        if (it == names.end()) {
            continue;
        }
        item.path = it->second;
        item.name = leafName(item.path);
    }
}

Item itemFromInfo(const BitArchiveItemInfo& info) {
    Item item;
    item.index = info.index();
    item.path = posixPath(info.path());
    item.name = info.name();
    if (item.name.empty()) {
        item.name = leafName(item.path);
    }
    item.isDir = info.isDir();
    item.size = info.size();
    item.packedSize = info.packSize();
    item.crc = info.crc();
    item.encrypted = info.isEncrypted();
    try {
        const auto mtime = info.lastWriteTime();
        item.mtimeUnix = static_cast<std::int64_t>(
            std::chrono::system_clock::to_time_t(mtime));
    } catch (...) {
        item.mtimeUnix = 0;
    }
    try {
        const auto method = info.itemProperty(BitProperty::Method);
        if (!method.isEmpty()) {
            item.method = method.toString();
        }
    } catch (...) {
    }
    return item;
}

const BitInOutFormat* writableFormat(const BitInFormat& fmt) {
    if (fmt == BitFormat::SevenZip) return &BitFormat::SevenZip;
    if (fmt == BitFormat::Zip)      return &BitFormat::Zip;
    if (fmt == BitFormat::Tar)      return &BitFormat::Tar;
    if (fmt == BitFormat::GZip)     return &BitFormat::GZip;
    if (fmt == BitFormat::BZip2)    return &BitFormat::BZip2;
    if (fmt == BitFormat::Xz)       return &BitFormat::Xz;
    if (fmt == BitFormat::Wim)      return &BitFormat::Wim;
    return nullptr;
}

void applyCreateOptions(BitAbstractArchiveCreator& creator, const CreateOptions& options) {
    creator.setCompressionLevel(compressionLevel(options.level));
    if (options.format == Format::SevenZip) {
        creator.setSolidMode(options.solid);
    }
    if (!options.password.empty()) {
        creator.setPassword(
            options.password,
            options.encryptHeaders ? EncryptionScope::DataAndHeaders
                                   : EncryptionScope::DataOnly);
    }
}

std::string joinArchivePath(const std::string& folder, const std::string& name) {
    if (folder.empty()) {
        return name;
    }
    if (!folder.empty() && folder.back() == '/') {
        return folder + name;
    }
    return folder + "/" + name;
}

ArchiveInfo fillInfo(BitArchiveReader& reader, const std::string& path, bool canUpdate) {
    ArchiveInfo info;
    info.path = path;
    info.formatName = nameFromBit(reader.detectedFormat());
    info.format = formatFromBit(reader.detectedFormat());
    info.canUpdate = canUpdate && writableFormat(reader.detectedFormat()) != nullptr;
    info.encrypted = reader.hasEncryptedItems() || reader.isEncrypted();
    info.solid = reader.isSolid();
    info.fileCount = reader.filesCount();
    info.folderCount = reader.foldersCount();
    info.totalSize = reader.size();
    info.packedSize = reader.packSize();
    info.items.reserve(reader.itemsCount());
    for (const auto& entry : reader.items()) {
        info.items.push_back(itemFromInfo(entry));
    }
    return info;
}

// Pull each nested item into memory so the inner archive can be opened
// without writing it to disk (zip-in-zip, tar inside gz, etc.).
buffer_t peelNested(const Bit7zLibrary& lib,
                    const std::string& archivePath,
                    const std::vector<std::uint32_t>& nestIndices,
                    const std::string& password) {
    if (nestIndices.empty()) {
        return {};
    }
    buffer_t blob;
    {
        BitArchiveReader reader{lib, archivePath, BitFormat::Auto, password};
        reader.extractTo(blob, nestIndices.front());
    }
    for (std::size_t i = 1; i < nestIndices.size(); ++i) {
        BitArchiveReader reader{lib, blob, BitFormat::Auto, password};
        buffer_t next;
        reader.extractTo(next, nestIndices[i]);
        blob.swap(next);
    }
    return blob;
}

} // namespace

Engine& Engine::instance() {
    static Engine engine;
    return engine;
}

void Engine::setLibraryPath(const std::string& path) {
    std::lock_guard<std::mutex> lock(gMutex);
    libraryPath_ = path;
    if (gLoadedPath != path) {
        gLib.reset();
        gLoadedPath.clear();
    }
}

ArchiveInfo Engine::list(const std::string& archivePath, const std::string& password) {
    return list(archivePath, {}, password);
}

ArchiveInfo Engine::list(const std::string& archivePath,
                         const std::vector<std::uint32_t>& nestIndices,
                         const std::string& password) {
    std::lock_guard<std::mutex> lock(gMutex);
    try {
        auto& lib = library(libraryPath_);
        if (nestIndices.empty()) {
            BitArchiveReader reader{lib, archivePath, BitFormat::Auto, password};
            ArchiveInfo info = fillInfo(reader, archivePath, true);
            if (info.format == Format::Zip) {
                applyZipNames(info.items, zipDecodedPaths(archivePath));
            }
            return info;
        }
        const buffer_t blob = peelNested(lib, archivePath, nestIndices, password);
        BitArchiveReader reader{lib, blob, BitFormat::Auto, password};
        return fillInfo(reader, archivePath, false);
    } catch (const BitException& ex) {
        rethrow(ex);
    }
}

void Engine::extract(const std::string& archivePath,
                     const std::string& destination,
                     const std::vector<std::uint32_t>& indices,
                     const std::string& password,
                     const ProgressPtr& progress,
                     const std::vector<std::uint32_t>& nestIndices) {
    std::lock_guard<std::mutex> lock(gMutex);
    try {
        auto& lib = library(libraryPath_);
        fs::create_directories(destination);
        if (!nestIndices.empty()) {
            const buffer_t blob = peelNested(lib, archivePath, nestIndices, password);
            BitArchiveReader reader{lib, blob, BitFormat::Auto, password};
            reader.setOverwriteMode(OverwriteMode::Overwrite);
            attachProgress(reader, progress);
            if (indices.empty()) {
                reader.extractTo(destination);
            } else {
                reader.extractTo(destination, indices);
            }
            return;
        }
        BitArchiveReader reader{lib, archivePath, BitFormat::Auto, password};
        reader.setOverwriteMode(OverwriteMode::Overwrite);
        attachProgress(reader, progress);
        const auto zipNames = (formatFromBit(reader.detectedFormat()) == Format::Zip)
                                  ? zipDecodedPaths(archivePath)
                                  : std::unordered_map<std::uint32_t, std::string>{};
        std::unordered_set<std::uint32_t> wanted(indices.begin(), indices.end());
        if (!zipNames.empty()) {
            reader.extractTo(destination, [&](const BitArchiveItem& item) -> tstring {
                if (!wanted.empty() && wanted.find(item.index()) == wanted.end()) {
                    return {};
                }
                const auto it = zipNames.find(item.index());
                return it != zipNames.end() ? it->second : item.path();
            });
        } else if (indices.empty()) {
            reader.extractTo(destination);
        } else {
            reader.extractTo(destination, indices);
        }
    } catch (const BitException& ex) {
        rethrow(ex);
    }
}

void Engine::test(const std::string& archivePath,
                  const std::string& password,
                  const ProgressPtr& progress,
                  const std::vector<std::uint32_t>& nestIndices) {
    std::lock_guard<std::mutex> lock(gMutex);
    try {
        auto& lib = library(libraryPath_);
        if (!nestIndices.empty()) {
            const buffer_t blob = peelNested(lib, archivePath, nestIndices, password);
            BitArchiveReader reader{lib, blob, BitFormat::Auto, password};
            attachProgress(reader, progress);
            reader.test();
            return;
        }
        BitFileExtractor extractor{lib, BitFormat::Auto};
        if (!password.empty()) {
            extractor.setPassword(password);
        }
        attachProgress(extractor, progress);
        extractor.test(archivePath);
    } catch (const BitException& ex) {
        rethrow(ex);
    }
}

void Engine::create(const std::string& archivePath,
                    const std::vector<std::string>& inputPaths,
                    const CreateOptions& options,
                    const ProgressPtr& progress) {
    if (inputPaths.empty()) {
        throw EngineError("No files selected to compress");
    }
    std::lock_guard<std::mutex> lock(gMutex);
    try {
        auto& lib = library(libraryPath_);
        const auto& format = inoutFormat(options.format);
        BitFileCompressor compressor{lib, format};
        applyCreateOptions(compressor, options);
        compressor.setOverwriteMode(OverwriteMode::Overwrite);
        attachProgress(compressor, progress);
        compressor.compress(inputPaths, archivePath);
    } catch (const BitException& ex) {
        rethrow(ex);
    }
}

void Engine::add(const std::string& archivePath,
                 const std::vector<std::string>& inputPaths,
                 const std::string& archiveFolder,
                 const std::string& password,
                 const ProgressPtr& progress) {
    if (inputPaths.empty()) {
        throw EngineError("No files selected to add");
    }
    std::lock_guard<std::mutex> lock(gMutex);
    try {
        auto& lib = library(libraryPath_);
        BitArchiveReader reader{lib, archivePath, BitFormat::Auto, password};
        const auto* format = writableFormat(reader.detectedFormat());
        if (!format) {
            throw EngineError("This archive format cannot be updated");
        }
        BitArchiveEditor editor{lib, archivePath, *format, password};
        editor.setUpdateMode(UpdateMode::Update);
        attachProgress(editor, progress);
        std::vector<std::pair<tstring, tstring>> pairs;
        pairs.reserve(inputPaths.size());
        for (const auto& input : inputPaths) {
            const auto name = fs::path(input).filename().string();
            pairs.emplace_back(input, joinArchivePath(posixPath(archiveFolder), name));
        }
        editor.addItems(pairs);
        editor.applyChanges();
    } catch (const BitException& ex) {
        rethrow(ex);
    }
}

void Engine::remove(const std::string& archivePath,
                    const std::vector<std::uint32_t>& indices,
                    const std::string& password,
                    const ProgressPtr& progress) {
    if (indices.empty()) {
        throw EngineError("No items selected to delete");
    }
    std::lock_guard<std::mutex> lock(gMutex);
    try {
        auto& lib = library(libraryPath_);
        BitArchiveReader reader{lib, archivePath, BitFormat::Auto, password};
        const auto* format = writableFormat(reader.detectedFormat());
        if (!format) {
            throw EngineError("This archive format cannot be updated");
        }
        BitArchiveEditor editor{lib, archivePath, *format, password};
        attachProgress(editor, progress);
        for (auto index : indices) {
            editor.deleteItem(index, DeletePolicy::RecurseDirs);
        }
        editor.applyChanges();
    } catch (const BitException& ex) {
        rethrow(ex);
    }
}

std::string Engine::extensionForFormat(Format format) {
    switch (format) {
    case Format::SevenZip: return "7z";
    case Format::Zip:      return "zip";
    case Format::Tar:      return "tar";
    case Format::GZip:     return "gz";
    case Format::BZip2:    return "bz2";
    case Format::Xz:       return "xz";
    case Format::Wim:      return "wim";
    case Format::Unknown:  return "7z";
    }
    return "7z";
}

std::string Engine::displayNameForFormat(Format format) {
    switch (format) {
    case Format::SevenZip: return "7-Zip";
    case Format::Zip:      return "ZIP";
    case Format::Tar:      return "TAR";
    case Format::GZip:     return "GZip";
    case Format::BZip2:    return "BZip2";
    case Format::Xz:       return "XZ";
    case Format::Wim:      return "WIM";
    case Format::Unknown:  return "Archive";
    }
    return "Archive";
}

Format Engine::formatFromExtension(const std::string& pathOrExt) {
    std::string ext = pathOrExt;
    const auto dot = ext.find_last_of('.');
    if (dot != std::string::npos && dot + 1 < ext.size()) {
        ext = ext.substr(dot + 1);
    }
    for (char& ch : ext) {
        ch = static_cast<char>(std::tolower(static_cast<unsigned char>(ch)));
    }
    if (ext == "7z") return Format::SevenZip;
    if (ext == "zip" || ext == "zipx" || ext == "jar" || ext == "apk") return Format::Zip;
    if (ext == "tar") return Format::Tar;
    if (ext == "gz" || ext == "gzip" || ext == "tgz") return Format::GZip;
    if (ext == "bz2" || ext == "bzip2" || ext == "tbz" || ext == "tbz2") return Format::BZip2;
    if (ext == "xz" || ext == "txz") return Format::Xz;
    if (ext == "wim") return Format::Wim;
    return Format::Unknown;
}

bool Engine::isArchiveFileName(const std::string& name) {
    static const char* const kExts[] = {
        "7z", "zip", "zipx", "jar", "apk", "tar", "gz", "gzip", "tgz",
        "bz2", "bzip2", "tbz", "tbz2", "xz", "txz", "rar", "wim", "iso",
        "cab", "dmg", "cpio", "rpm", "deb", "lzh", "lha", "lzma", "z",
    };
    std::string ext = name;
    const auto dot = ext.find_last_of('.');
    if (dot == std::string::npos || dot + 1 >= ext.size()) {
        return false;
    }
    ext = ext.substr(dot + 1);
    for (char& ch : ext) {
        ch = static_cast<char>(std::tolower(static_cast<unsigned char>(ch)));
    }
    for (const char* known : kExts) {
        if (ext == known) {
            return true;
        }
    }
    return false;
}

} // namespace rz
