#include "ArchiveEngine.hpp"

#include <iostream>
#include <string>
#include <vector>

static void usage() {
    std::cerr << "Usage:\n"
              << "  rezipper-cli --lib <7z.so> [--password P] [--nest i,j] list <archive>\n"
              << "  rezipper-cli --lib <7z.so> [--password P] [--nest i,j] test <archive>\n"
              << "  rezipper-cli --lib <7z.so> [--password P] [--nest i,j] extract <archive> <dest>\n"
              << "  rezipper-cli --lib <7z.so> [--password P] [--encrypt-headers] [--no-solid]\n"
              << "                 create <archive> <file...>\n"
              << "  rezipper-cli --lib <7z.so> add <archive> <file...>\n"
              << "  rezipper-cli --lib <7z.so> remove <archive> <index...>\n";
}

// Returns false on anything that is not a plain unsigned number, so bad input
// reports usage instead of terminating on an uncaught std::invalid_argument.
static bool parseIndex(const std::string& token, std::uint32_t& out) {
    if (token.empty() || token.find_first_not_of("0123456789") != std::string::npos) {
        return false;
    }
    try {
        const unsigned long value = std::stoul(token);
        if (value > 0xFFFFFFFFul) {
            return false;
        }
        out = static_cast<std::uint32_t>(value);
        return true;
    } catch (const std::exception&) {
        return false;
    }
}

static bool parseNest(const std::string& spec, std::vector<std::uint32_t>& nest) {
    std::size_t start = 0;
    while (start < spec.size()) {
        const auto comma = spec.find(',', start);
        const auto token = spec.substr(start, comma == std::string::npos ? std::string::npos : comma - start);
        if (!token.empty()) {
            std::uint32_t index = 0;
            if (!parseIndex(token, index)) {
                return false;
            }
            nest.push_back(index);
        }
        if (comma == std::string::npos) {
            break;
        }
        start = comma + 1;
    }
    return true;
}

int main(int argc, char** argv) {
    std::string lib;
    std::string password;
    std::vector<std::uint32_t> nest;
    bool encryptHeaders = false;
    bool solid = true;
    std::vector<std::string> args;
    for (int i = 1; i < argc; ++i) {
        const std::string arg = argv[i];
        if (arg == "--lib" && i + 1 < argc) {
            lib = argv[++i];
        } else if ((arg == "--password" || arg == "--pass") && i + 1 < argc) {
            password = argv[++i];
        } else if (arg == "--nest" && i + 1 < argc) {
            if (!parseNest(argv[++i], nest)) {
                std::cerr << "Error: --nest expects a comma-separated list of item indices\n";
                return 2;
            }
        } else if (arg == "--encrypt-headers") {
            encryptHeaders = true;
        } else if (arg == "--no-solid") {
            solid = false;
        } else {
            args.push_back(arg);
        }
    }
    if (lib.empty() || args.size() < 2) {
        usage();
        return 2;
    }

    rz::Engine::instance().setLibraryPath(lib);
    const std::string cmd = args[0];
    try {
        if (cmd == "list") {
            if (password.empty() && args.size() > 2) {
                password = args[2];
            }
            const auto info = rz::Engine::instance().list(args[1], nest, password);
            std::cout << info.formatName << "  files=" << info.fileCount
                      << " folders=" << info.folderCount
                      << " size=" << info.totalSize
                      << " packed=" << info.packedSize
                      << " solid=" << (info.solid ? "1" : "0")
                      << " encrypted=" << (info.encrypted ? "1" : "0")
                      << " update=" << (info.canUpdate ? "1" : "0") << "\n";
            for (const auto& item : info.items) {
                std::cout << (item.isDir ? "D " : "F ")
                          << item.index << "\t"
                          << item.size << "\t" << item.path << "\n";
            }
            return 0;
        }
        if (cmd == "test") {
            if (password.empty() && args.size() > 2) {
                password = args[2];
            }
            auto progress = std::make_shared<rz::Progress>();
            rz::Engine::instance().test(args[1], password, progress, nest);
            std::cout << "OK\n";
            return 0;
        }
        if (cmd == "extract") {
            if (args.size() < 3) {
                usage();
                return 2;
            }
            if (password.empty() && args.size() > 3) {
                password = args[3];
            }
            auto progress = std::make_shared<rz::Progress>();
            rz::Engine::instance().extract(args[1], args[2], {}, password, progress, nest);
            std::cout << "Extracted to " << args[2] << "\n";
            return 0;
        }
        if (cmd == "create") {
            if (args.size() < 3) {
                usage();
                return 2;
            }
            std::vector<std::string> files(args.begin() + 2, args.end());
            rz::CreateOptions options;
            options.format = rz::Engine::formatFromExtension(args[1]);
            if (options.format == rz::Format::Unknown) {
                options.format = rz::Format::SevenZip;
            }
            options.password = password;
            options.encryptHeaders = encryptHeaders;
            options.solid = solid;
            auto progress = std::make_shared<rz::Progress>();
            rz::Engine::instance().create(args[1], files, options, progress);
            std::cout << "Created " << args[1] << "\n";
            return 0;
        }
        if (cmd == "add") {
            if (args.size() < 3) {
                usage();
                return 2;
            }
            std::vector<std::string> files(args.begin() + 2, args.end());
            auto progress = std::make_shared<rz::Progress>();
            rz::Engine::instance().add(args[1], files, "", "", progress);
            std::cout << "Updated " << args[1] << "\n";
            return 0;
        }
        if (cmd == "remove") {
            if (args.size() < 3) {
                usage();
                return 2;
            }
            std::vector<std::uint32_t> indices;
            for (size_t i = 2; i < args.size(); ++i) {
                std::uint32_t index = 0;
                if (!parseIndex(args[i], index)) {
                    std::cerr << "Error: '" << args[i] << "' is not a valid item index\n";
                    return 2;
                }
                indices.push_back(index);
            }
            auto progress = std::make_shared<rz::Progress>();
            rz::Engine::instance().remove(args[1], indices, "", progress);
            std::cout << "Removed from " << args[1] << "\n";
            return 0;
        }
        usage();
        return 2;
    } catch (const std::exception& ex) {
        std::cerr << "Error: " << ex.what() << "\n";
        return 1;
    }
}
