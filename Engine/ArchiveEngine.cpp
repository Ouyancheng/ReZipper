#include "ArchiveEngine.hpp"

#include <bit7z/bit7z.hpp>

#include <algorithm>
#include <cctype>
#include <chrono>
#include <climits>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <filesystem>
#include <fstream>
#include <iconv.h>
#include <map>
#include <memory>
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
    if (ex.code() == BitFailureSource::WrongPassword) {
        return true;
    }
    std::string message = ex.what();
    for (char& ch : message) {
        ch = static_cast<char>(std::tolower(static_cast<unsigned char>(ch)));
    }
    return message.find("password") != std::string::npos;
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
        progress->setCurrentFile(file);
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

int32_t rz_i32(const char* p) {
    return static_cast<int32_t>(rz_u32(p));
}

constexpr uint64_t kZipCdRecordSize = 46;
constexpr uint64_t kZipMaxCdSize = 64ull * 1024 * 1024;

struct ZipCdName {
    std::string raw;
    bool utf8 = false;
    std::int64_t mtimeUnix = 0;
};

// DOS stamps are local time by definition, so this needs mktime rather than
// plain arithmetic. Callers memoize it: archives repeat few distinct stamps.
// tm_isdst = -1 resolves each stamp with the offset in effect on that date,
// which is why results differ from 7-Zip's by an hour in DST zones: 7-Zip
// applies today's offset to every entry, dating winter files an hour early.
std::int64_t dosToUnix(uint32_t dosDateTime) {
    const int seconds = static_cast<int>(dosDateTime & 0x1F) * 2;
    const int minutes = static_cast<int>((dosDateTime >> 5) & 0x3F);
    const int hours = static_cast<int>((dosDateTime >> 11) & 0x1F);
    const int day = static_cast<int>((dosDateTime >> 16) & 0x1F);
    const int month = static_cast<int>((dosDateTime >> 21) & 0x0F);
    const int year = static_cast<int>((dosDateTime >> 25) & 0x7F) + 1980;
    if (month < 1 || month > 12 || day < 1 || day > 31) {
        return 0;
    }
    std::tm parts{};
    parts.tm_sec = seconds;
    parts.tm_min = minutes;
    parts.tm_hour = hours;
    parts.tm_mday = day;
    parts.tm_mon = month - 1;
    parts.tm_year = year - 1900;
    parts.tm_isdst = -1;
    const std::time_t stamp = std::mktime(&parts);
    return stamp == static_cast<std::time_t>(-1) ? 0 : static_cast<std::int64_t>(stamp);
}

std::int64_t filetimeToUnix(uint64_t filetime) {
    constexpr uint64_t kTicksPerSecond = 10000000ull;
    constexpr std::int64_t kEpochDelta = 11644473600ll;
    return static_cast<std::int64_t>(filetime / kTicksPerSecond) - kEpochDelta;
}

// An extended timestamp beats the DOS stamp: it is UTC with at least one-second
// precision, while the DOS stamp is local time rounded to two seconds.
bool extraFieldMtime(const char* extra, size_t length, std::int64_t& mtime) {
    size_t pos = 0;
    while (pos + 4 <= length) {
        const uint16_t id = rz_u16(extra + pos);
        const uint16_t size = rz_u16(extra + pos + 2);
        if (pos + 4 + size > length) {
            break;
        }
        const char* data = extra + pos + 4;
        // 0x5455 "UT": flags byte, then mtime/atime/ctime as int32 Unix seconds.
        if (id == 0x5455 && size >= 5 && (static_cast<unsigned char>(data[0]) & 0x01) != 0) {
            mtime = rz_i32(data + 1);
            return true;
        }
        // 0x000A "NTFS": reserved dword, then tag/size pairs; tag 1 holds FILETIMEs.
        if (id == 0x000A && size >= 12) {
            size_t inner = 4;
            while (inner + 4 <= size) {
                const uint16_t tag = rz_u16(data + inner);
                const uint16_t tagSize = rz_u16(data + inner + 2);
                if (inner + 4 + tagSize > size) {
                    break;
                }
                if (tag == 1 && tagSize >= 8) {
                    mtime = filetimeToUnix(rz_u64(data + inner + 4));
                    return true;
                }
                inner += 4 + tagSize;
            }
        }
        pos += 4 + size;
    }
    return false;
}

std::vector<ZipCdName> parseZipCdRecords(const char* cd, uint64_t cdSize, uint64_t nent) {
    if (!cd || nent == 0 || cdSize == 0) {
        return {};
    }
    // nent comes straight from the archive, so cap it by what can physically
    // fit in the central directory before using it to size the vector.
    nent = std::min(nent, cdSize / kZipCdRecordSize);
    std::vector<ZipCdName> names;
    names.reserve(static_cast<size_t>(nent));
    std::unordered_map<uint32_t, std::int64_t> dosCache;
    size_t pos = 0;
    while (pos + kZipCdRecordSize <= cdSize && names.size() < nent) {
        if (cd[pos] != 'P' || cd[pos + 1] != 'K' ||
            static_cast<unsigned char>(cd[pos + 2]) != 1 ||
            static_cast<unsigned char>(cd[pos + 3]) != 2) {
            break;
        }
        const uint16_t flags = rz_u16(cd + pos + 8);
        const uint32_t dosStamp = rz_u32(cd + pos + 12);
        const uint16_t nameLen = rz_u16(cd + pos + 28);
        const uint16_t extraLen = rz_u16(cd + pos + 30);
        const uint16_t commentLen = rz_u16(cd + pos + 32);
        if (pos + kZipCdRecordSize + nameLen + extraLen + commentLen > cdSize) {
            break;
        }
        ZipCdName entry;
        entry.raw.assign(cd + pos + kZipCdRecordSize, nameLen);
        entry.utf8 = (flags & 0x800) != 0;
        if (!extraFieldMtime(cd + pos + kZipCdRecordSize + nameLen, extraLen, entry.mtimeUnix)) {
            const auto cached = dosCache.find(dosStamp);
            if (cached != dosCache.end()) {
                entry.mtimeUnix = cached->second;
            } else {
                entry.mtimeUnix = dosToUnix(dosStamp);
                dosCache.emplace(dosStamp, entry.mtimeUnix);
            }
        }
        names.push_back(std::move(entry));
        pos += kZipCdRecordSize + nameLen + extraLen + commentLen;
    }
    return names;
}

bool findZipEocd(const char* tail, uint64_t scan, uint64_t& nent, uint64_t& cdSize, uint64_t& cdOff,
                 uint64_t& zip64Off) {
    int eocd = -1;
    for (int i = static_cast<int>(scan) - 22; i >= 0; --i) {
        if (tail[i] == 'P' && tail[i + 1] == 'K' &&
            static_cast<unsigned char>(tail[i + 2]) == 5 &&
            static_cast<unsigned char>(tail[i + 3]) == 6) {
            eocd = i;
            break;
        }
    }
    if (eocd < 0) {
        return false;
    }
    const char* e = tail + eocd;
    nent = rz_u16(e + 10);
    cdSize = rz_u32(e + 12);
    cdOff = rz_u32(e + 16);
    zip64Off = UINT64_MAX;
    if (nent != 0xffff && cdSize != 0xffffffffu && cdOff != 0xffffffffu) {
        return true;
    }
    for (int i = eocd - 20; i >= 0; --i) {
        if (tail[i] == 'P' && tail[i + 1] == 'K' &&
            static_cast<unsigned char>(tail[i + 2]) == 6 &&
            static_cast<unsigned char>(tail[i + 3]) == 7) {
            zip64Off = rz_u64(tail + i + 8);
            return true;
        }
    }
    return false;
}

bool applyZip64Eocd(const char* z64, uint64_t& nent, uint64_t& cdSize, uint64_t& cdOff) {
    if (!z64 || z64[0] != 'P' || z64[1] != 'K') {
        return false;
    }
    nent = rz_u64(z64 + 32);
    cdSize = rz_u64(z64 + 40);
    cdOff = rz_u64(z64 + 48);
    return true;
}

std::vector<ZipCdName> parseZipCentralNames(const char* data, uint64_t fileSize) {
    if (!data || fileSize < 22) {
        return {};
    }

    const uint64_t scan = std::min<uint64_t>(fileSize, 65557);
    uint64_t nent = 0;
    uint64_t cdSize = 0;
    uint64_t cdOff = 0;
    uint64_t zip64Off = UINT64_MAX;
    if (!findZipEocd(data + (fileSize - scan), scan, nent, cdSize, cdOff, zip64Off)) {
        return {};
    }
    if (zip64Off != UINT64_MAX) {
        // Both offsets are archive-controlled, so compare by subtraction:
        // zip64Off + 56 and cdOff + cdSize can each wrap past UINT64_MAX.
        if (fileSize < 56 || zip64Off > fileSize - 56 ||
            !applyZip64Eocd(data + zip64Off, nent, cdSize, cdOff)) {
            return {};
        }
    }
    if (nent == 0 || cdSize == 0 || cdSize > kZipMaxCdSize || cdOff > fileSize ||
        cdSize > fileSize - cdOff) {
        return {};
    }
    return parseZipCdRecords(data + cdOff, cdSize, nent);
}

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

    uint64_t nent = 0;
    uint64_t cdSize = 0;
    uint64_t cdOff = 0;
    uint64_t zip64Off = UINT64_MAX;
    if (!findZipEocd(tail.data(), scan, nent, cdSize, cdOff, zip64Off)) {
        return {};
    }
    if (zip64Off != UINT64_MAX) {
        if (fileSize < 56 || zip64Off > fileSize - 56) {
            return {};
        }
        std::vector<char> z64(56);
        file.clear();
        file.seekg(static_cast<std::streamoff>(zip64Off));
        file.read(z64.data(), 56);
        if (file.gcount() < 56 || !applyZip64Eocd(z64.data(), nent, cdSize, cdOff)) {
            return {};
        }
    }
    if (nent == 0 || cdSize == 0 || cdSize > kZipMaxCdSize || cdOff > fileSize ||
        cdSize > fileSize - cdOff) {
        return {};
    }

    std::vector<char> cd(static_cast<size_t>(cdSize));
    file.clear();
    file.seekg(static_cast<std::streamoff>(cdOff));
    file.read(cd.data(), static_cast<std::streamsize>(cdSize));
    if (file.gcount() != static_cast<std::streamsize>(cdSize)) {
        return {};
    }
    return parseZipCdRecords(cd.data(), cdSize, nent);
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

struct ScriptCounts {
    int ascii = 0;
    int han = 0;
    int hira = 0;
    int kata = 0;
    int hang = 0;
    int jamo = 0;
    int halfKata = 0;
    int other = 0;
    bool valid = true;
};

ScriptCounts countScripts(const std::string& text) {
    ScriptCounts counts;
    const auto* p = reinterpret_cast<const unsigned char*>(text.data());
    const auto* end = p + text.size();
    while (p < end) {
        if (*p <= 0x7F) {
            if (*p < 0x20 && *p != '\t') {
                counts.valid = false;
                return counts;
            }
            counts.ascii += 1;
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
            counts.valid = false;
            return counts;
        }
        if (p + extra >= end) {
            counts.valid = false;
            return counts;
        }
        for (int i = 1; i <= extra; ++i) {
            if ((p[i] & 0xC0) != 0x80) {
                counts.valid = false;
                return counts;
            }
            cp = (cp << 6) | (p[i] & 0x3F);
        }
        p += extra + 1;
        if (cp == 0xFFFD) {
            counts.valid = false;
            return counts;
        }
        if (cp >= 0xFF61 && cp <= 0xFF9F) {
            counts.halfKata += 1;
        } else if (cp >= 0x3040 && cp <= 0x309F) {
            counts.hira += 1;
        } else if (cp >= 0x30A0 && cp <= 0x30FF) {
            counts.kata += 1;
        } else if (cp >= 0xAC00 && cp <= 0xD7AF) {
            counts.hang += 1;
        } else if ((cp >= 0x3130 && cp <= 0x318F) || (cp >= 0x1100 && cp <= 0x11FF)) {
            counts.jamo += 1;
        } else if ((cp >= 0x4E00 && cp <= 0x9FFF) || (cp >= 0x3400 && cp <= 0x4DBF)) {
            counts.han += 1;
        } else {
            counts.other += 1;
        }
    }
    return counts;
}

int scoreDecodedForEncoding(const char* enc, const ScriptCounts& counts) {
    if (!counts.valid) {
        return -100000;
    }
    const bool sjis = std::strcmp(enc, "SHIFT_JIS") == 0 || std::strcmp(enc, "CP932") == 0;
    const bool korean = std::strcmp(enc, "EUC-KR") == 0;
    const bool gb = std::strcmp(enc, "GB18030") == 0 || std::strcmp(enc, "GBK") == 0;
    const bool big5 = std::strcmp(enc, "BIG5") == 0;

    int score = counts.ascii + counts.other;
    score -= counts.halfKata * 12;

    if (sjis) {
        score += (counts.hira + counts.kata) * 24;
        score += counts.han * 2;
        if (counts.hira + counts.kata == 0) {
            score -= 16;
        }
        score -= counts.hang * 20;
    } else if (korean) {
        score += counts.hang * 24;
        score -= counts.jamo * 20;
        score -= counts.han * 25;
        const int cjk = counts.hang + counts.han + counts.hira + counts.kata + counts.jamo;
        // Real Korean names are almost all Hangul. GBK/Big5 misreads are mixed.
        if (cjk > 0 && counts.hang * 5 < cjk * 4) {
            score -= 80;
        }
        if (counts.hang == 0) {
            score -= 40;
        }
        score -= (counts.hira + counts.kata) * 20;
    } else if (gb || big5) {
        score += counts.han * 6;
        score -= (counts.hira + counts.kata) * 20;
        score -= counts.hang * 20;
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
            score += scoreDecodedForEncoding(enc, countScripts(*decoded));
        }
        if (!ok) {
            continue;
        }
        // Locale is only a tie-breaker. Script evidence must win for
        // Japanese / Korean zips opened under a Chinese locale.
        if (preferred && std::strcmp(enc, preferred) == 0) {
            score += 5;
        }
        if (score > bestScore) {
            bestScore = score;
            best = enc;
        }
    }
    return best;
}

struct ZipEntryMeta {
    std::string path;
    bool hasPath = false;
    std::int64_t mtimeUnix = 0;
};

struct ZipMeta {
    std::unordered_map<std::uint32_t, ZipEntryMeta> entries;
    std::uint32_t recordCount = 0;
};

ZipMeta zipMetaFromEntries(const std::vector<ZipCdName>& entries) {
    ZipMeta meta;
    if (entries.empty()) {
        return meta;
    }
    std::vector<std::string> legacy;
    for (const auto& entry : entries) {
        if (!entry.utf8) {
            legacy.push_back(entry.raw);
        }
    }
    const char* encoding = detectLegacyEncoding(legacy);
    meta.recordCount = static_cast<std::uint32_t>(entries.size());
    meta.entries.reserve(entries.size());
    for (std::uint32_t i = 0; i < entries.size(); ++i) {
        const auto& entry = entries[i];
        ZipEntryMeta info;
        info.mtimeUnix = entry.mtimeUnix;
        std::optional<std::string> decoded;
        if (entry.utf8 || isValidUtf8(entry.raw)) {
            decoded = entry.raw;
        } else if (encoding) {
            decoded = iconvToUtf8(entry.raw, encoding);
        }
        if (decoded && !decoded->empty()) {
            info.path = posixPath(*decoded);
            info.hasPath = !info.path.empty();
        }
        meta.entries.emplace(i, std::move(info));
    }
    return meta;
}

ZipMeta zipMeta(const std::string& archivePath) {
    return zipMetaFromEntries(readZipCentralNames(archivePath));
}

ZipMeta zipMeta(const buffer_t& blob) {
    if (blob.empty()) {
        return {};
    }
    return zipMetaFromEntries(parseZipCentralNames(
        reinterpret_cast<const char*>(blob.data()), blob.size()));
}

void applyZipMeta(std::vector<Item>& items, const ZipMeta& meta, bool applyMtime) {
    if (meta.entries.empty()) {
        return;
    }
    for (auto& item : items) {
        const auto it = meta.entries.find(item.index);
        if (it == meta.entries.end()) {
            continue;
        }
        if (it->second.hasPath) {
            item.path = it->second.path;
            item.name = leafName(item.path);
        }
        if (applyMtime) {
            item.mtimeUnix = it->second.mtimeUnix;
        }
    }
}

// wantMtime is false for zips: BitArchiveItem::lastWriteTime() costs ~70us per
// item on archives whose only timestamp is the DOS stamp, which dwarfs the rest
// of listing. Those come from the central directory we already parse instead.
Item itemFromInfo(const BitArchiveItem& info, bool wantMtime) {
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
    if (wantMtime) {
        try {
            const auto mtime = info.lastWriteTime();
            item.mtimeUnix = static_cast<std::int64_t>(
                std::chrono::system_clock::to_time_t(mtime));
        } catch (...) {
            item.mtimeUnix = 0;
        }
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

ArchiveInfo fillInfo(BitArchiveReader& reader, const std::string& path, bool canUpdate,
                     bool wantMtime) {
    ArchiveInfo info;
    info.path = path;
    info.formatName = nameFromBit(reader.detectedFormat());
    info.format = formatFromBit(reader.detectedFormat());
    info.canUpdate = canUpdate && writableFormat(reader.detectedFormat()) != nullptr;
    info.solid = reader.isSolid();
    info.items.reserve(reader.itemsCount());
    // One pass: bit7z computes each of these aggregates by walking every item
    // again, so folding them in here saves five extra traversals. Iterating the
    // reader directly also matters, because reader.items() eagerly reads all
    // ~95 properties per item, including the expensive timestamp.
    bool anyEncrypted = false;
    for (auto it = reader.begin(); it != reader.end(); ++it) {
        Item item = itemFromInfo(*it, wantMtime);
        if (item.isDir) {
            info.folderCount += 1;
        } else {
            info.fileCount += 1;
            info.totalSize += item.size;
            info.packedSize += item.packedSize;
            anyEncrypted = anyEncrypted || item.encrypted;
        }
        info.items.push_back(std::move(item));
    }
    info.encrypted = anyEncrypted || reader.isEncrypted();
    return info;
}

// The central directory is only read for zips, and only trusted for timestamps
// when it describes every item the reader reports.
ArchiveInfo listFromReader(BitArchiveReader& reader, const std::string& path, bool canUpdate,
                           const ZipMeta& meta) {
    const bool isZip = formatFromBit(reader.detectedFormat()) == Format::Zip;
    const bool metaCoversAll = isZip && meta.recordCount == reader.itemsCount();
    ArchiveInfo info = fillInfo(reader, path, canUpdate, !metaCoversAll);
    if (isZip) {
        applyZipMeta(info.items, meta, metaCoversAll);
    }
    return info;
}

bool readerIsZip(BitArchiveReader& reader) {
    return formatFromBit(reader.detectedFormat()) == Format::Zip;
}

bool extractCancelled(const ProgressPtr& progress) {
    return progress && progress->cancel.load(std::memory_order_relaxed);
}

buffer_t extractCapped(BitArchiveReader& reader,
                       std::uint32_t index,
                       const ProgressPtr& progress,
                       std::uint64_t maxBytes) {
    attachProgress(reader, progress);
    if (index >= reader.itemsCount()) {
        throw EngineError("Invalid archive item");
    }
    const std::uint64_t reported = reader.itemAt(index).size();
    if (maxBytes > 0 && reported > maxBytes) {
        throw EngineError("File is too large to preview");
    }
    if (extractCancelled(progress)) {
        throw EngineError("Cancelled");
    }
    buffer_t blob;
    if (maxBytes == 0 && !progress) {
        reader.extractTo(blob, index);
        return blob;
    }
    // Without this the streaming path below regrows the buffer repeatedly,
    // which is costly when peeling a large nested archive into memory.
    if (reported > 0) {
        blob.reserve(static_cast<size_t>(maxBytes > 0 ? std::min(reported, maxBytes) : reported));
    }
    bool overflow = false;
    try {
        reader.extractTo([&](const byte_t* data, std::size_t n) -> bool {
            if (extractCancelled(progress)) {
                return false;
            }
            if (maxBytes > 0 && blob.size() + n > maxBytes) {
                overflow = true;
                return false;
            }
            blob.insert(blob.end(), data, data + n);
            return true;
        }, {index});
    } catch (const BitException& ex) {
        if (overflow) {
            throw EngineError("File is too large to preview");
        }
        if (extractCancelled(progress)) {
            throw EngineError("Cancelled");
        }
        rethrow(ex);
    }
    if (overflow) {
        throw EngineError("File is too large to preview");
    }
    if (extractCancelled(progress)) {
        throw EngineError("Cancelled");
    }
    return blob;
}

// Pull each nested item into memory so the inner archive can be opened
// without writing it to disk (zip-in-zip, tar inside gz, etc.).
buffer_t peelNested(const Bit7zLibrary& lib,
                    const std::string& archivePath,
                    const std::vector<std::uint32_t>& nestIndices,
                    const std::string& password,
                    const ProgressPtr& progress = {},
                    std::uint64_t maxBytes = 0) {
    if (nestIndices.empty()) {
        return {};
    }
    BitArchiveReader reader{lib, archivePath, BitFormat::Auto, password};
    buffer_t blob = extractCapped(reader, nestIndices.front(), progress, maxBytes);
    for (std::size_t i = 1; i < nestIndices.size(); ++i) {
        BitArchiveReader inner{lib, blob, BitFormat::Auto, password};
        blob = extractCapped(inner, nestIndices[i], progress, maxBytes);
    }
    return blob;
}

struct PeelKey {
    std::string path;
    std::vector<std::uint32_t> nest;

    bool operator<(const PeelKey& other) const {
        if (path != other.path) {
            return path < other.path;
        }
        return nest < other.nest;
    }
};

struct PeelEntry {
    std::string password;
    std::uint64_t fileSize = 0;
    std::uint64_t fileMtime = 0;
    std::shared_ptr<buffer_t> blob;
    int holders = 0;
    std::uint64_t lastUsed = 0;
};

std::map<PeelKey, PeelEntry> gPeelCache;
std::uint64_t gPeelClock = 0;

// Peeled blobs are whole decompressed archives, so the cache needs a ceiling.
// Entries an open document still holds are never evicted.
constexpr std::uint64_t kPeelCacheBudget = 512ull * 1024 * 1024;

void trimPeelCache() {
    std::uint64_t total = 0;
    for (const auto& entry : gPeelCache) {
        if (entry.second.blob) {
            total += entry.second.blob->size();
        }
    }
    while (total > kPeelCacheBudget) {
        auto victim = gPeelCache.end();
        for (auto it = gPeelCache.begin(); it != gPeelCache.end(); ++it) {
            if (it->second.holders > 0 || !it->second.blob) {
                continue;
            }
            if (victim == gPeelCache.end() || it->second.lastUsed < victim->second.lastUsed) {
                victim = it;
            }
        }
        if (victim == gPeelCache.end()) {
            break;
        }
        total -= victim->second.blob->size();
        gPeelCache.erase(victim);
    }
}

void peelIdentity(const std::string& path, std::uint64_t& size, std::uint64_t& mtime) {
    std::error_code ec;
    size = fs::file_size(path, ec);
    if (ec) {
        size = 0;
    }
    const auto stamp = fs::last_write_time(path, ec);
    mtime = ec ? 0 : static_cast<std::uint64_t>(stamp.time_since_epoch().count());
}

void clearPeelCache() {
    gPeelCache.clear();
}

void adjustPeelHolders(const std::string& path, const std::vector<std::uint32_t>& nest, int delta) {
    const auto it = gPeelCache.find(PeelKey{path, nest});
    if (it == gPeelCache.end()) {
        return;
    }
    it->second.holders += delta;
    if (it->second.holders <= 0) {
        gPeelCache.erase(it);
    }
}

std::shared_ptr<buffer_t> cachedPeel(const Bit7zLibrary& lib,
                                     const std::string& archivePath,
                                     const std::vector<std::uint32_t>& nestIndices,
                                     const std::string& password,
                                     const ProgressPtr& progress = {}) {
    std::uint64_t size = 0;
    std::uint64_t mtime = 0;
    peelIdentity(archivePath, size, mtime);
    const PeelKey key{archivePath, nestIndices};
    const auto it = gPeelCache.find(key);
    if (it != gPeelCache.end() &&
        it->second.blob &&
        it->second.password == password &&
        it->second.fileSize == size &&
        it->second.fileMtime == mtime) {
        it->second.lastUsed = ++gPeelClock;
        return it->second.blob;
    }
    if (it != gPeelCache.end()) {
        it->second.blob.reset();
    }
    auto blob = std::make_shared<buffer_t>(
        peelNested(lib, archivePath, nestIndices, password, progress, 0));
    auto& entry = gPeelCache[key];
    entry.password = password;
    entry.fileSize = size;
    entry.fileMtime = mtime;
    entry.blob = blob;
    entry.lastUsed = ++gPeelClock;
    trimPeelCache();
    return blob;
}

void invalidatePeelPath(const std::string& path) {
    for (auto it = gPeelCache.begin(); it != gPeelCache.end(); ) {
        if (it->first.path == path) {
            it = gPeelCache.erase(it);
        } else {
            ++it;
        }
    }
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
        clearPeelCache();
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
            return listFromReader(reader, archivePath, true,
                                  readerIsZip(reader) ? zipMeta(archivePath) : ZipMeta{});
        }
        const auto blob = cachedPeel(lib, archivePath, nestIndices, password);
        BitArchiveReader reader{lib, *blob, BitFormat::Auto, password};
        return listFromReader(reader, archivePath, false,
                              readerIsZip(reader) ? zipMeta(*blob) : ZipMeta{});
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
        auto extractMapped = [&](BitArchiveReader& reader, const ZipMeta& meta) {
            std::unordered_set<std::uint32_t> wanted(indices.begin(), indices.end());
            reader.extractTo(destination, [&](const BitArchiveItem& item) -> tstring {
                if (!wanted.empty() && wanted.find(item.index()) == wanted.end()) {
                    return {};
                }
                const auto it = meta.entries.find(item.index());
                const std::string path = (it != meta.entries.end() && it->second.hasPath)
                                             ? it->second.path
                                             : posixPath(item.path());
                if (path.empty()) {
                    return {};
                }
                return path;
            });
        };
        if (!nestIndices.empty()) {
            const auto blob = cachedPeel(lib, archivePath, nestIndices, password, progress);
            BitArchiveReader reader{lib, *blob, BitFormat::Auto, password};
            reader.setOverwriteMode(OverwriteMode::Overwrite);
            attachProgress(reader, progress);
            extractMapped(reader, readerIsZip(reader) ? zipMeta(*blob) : ZipMeta{});
            return;
        }
        BitArchiveReader reader{lib, archivePath, BitFormat::Auto, password};
        reader.setOverwriteMode(OverwriteMode::Overwrite);
        attachProgress(reader, progress);
        extractMapped(reader, readerIsZip(reader) ? zipMeta(archivePath) : ZipMeta{});
    } catch (const BitException& ex) {
        rethrow(ex);
    }
}

std::vector<std::uint8_t> Engine::extractItem(const std::string& archivePath,
                                              std::uint32_t index,
                                              const std::string& password,
                                              const ProgressPtr& progress,
                                              const std::vector<std::uint32_t>& nestIndices,
                                              std::uint64_t maxBytes) {
    std::lock_guard<std::mutex> lock(gMutex);
    try {
        auto& lib = library(libraryPath_);
        if (!nestIndices.empty()) {
            const auto nested = cachedPeel(lib, archivePath, nestIndices, password, progress);
            BitArchiveReader reader{lib, *nested, BitFormat::Auto, password};
            return extractCapped(reader, index, progress, maxBytes);
        }
        BitArchiveReader reader{lib, archivePath, BitFormat::Auto, password};
        return extractCapped(reader, index, progress, maxBytes);
    } catch (const BitException& ex) {
        if (extractCancelled(progress)) {
            throw EngineError("Cancelled");
        }
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
            const auto blob = cachedPeel(lib, archivePath, nestIndices, password, progress);
            BitArchiveReader reader{lib, *blob, BitFormat::Auto, password};
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
    std::error_code existsEc;
    const bool existedBefore = fs::exists(archivePath, existsEc);
    try {
        auto& lib = library(libraryPath_);
        const auto& format = inoutFormat(options.format);
        BitFileCompressor compressor{lib, format};
        applyCreateOptions(compressor, options);
        compressor.setOverwriteMode(OverwriteMode::Overwrite);
        attachProgress(compressor, progress);
        compressor.compress(inputPaths, archivePath);
        invalidatePeelPath(archivePath);
    } catch (const BitException& ex) {
        // A cancelled compression leaves a truncated archive behind. Only
        // remove it when we know we created it, so an existing archive the
        // user was replacing is never deleted on our way out.
        if (!existedBefore && progress && progress->cancel.load(std::memory_order_relaxed)) {
            std::error_code ec;
            fs::remove(archivePath, ec);
        }
        invalidatePeelPath(archivePath);
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
        invalidatePeelPath(archivePath);
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
        invalidatePeelPath(archivePath);
    } catch (const BitException& ex) {
        rethrow(ex);
    }
}

void Engine::retainNestedBlob(const std::string& archivePath,
                              const std::vector<std::uint32_t>& nestIndices) {
    std::lock_guard<std::mutex> lock(gMutex);
    adjustPeelHolders(archivePath, nestIndices, 1);
}

void Engine::releaseNestedBlob(const std::string& archivePath,
                               const std::vector<std::uint32_t>& nestIndices) {
    std::lock_guard<std::mutex> lock(gMutex);
    adjustPeelHolders(archivePath, nestIndices, -1);
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
