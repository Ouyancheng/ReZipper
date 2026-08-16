#include "ArchiveEngine.hpp"

#include <iostream>
#include <string>
#include <vector>

static void usage() {
    std::cerr << "Usage:\n"
              << "  rezipper-cli --lib <7z.so> list <archive> [password]\n"
              << "  rezipper-cli --lib <7z.so> test <archive> [password]\n"
              << "  rezipper-cli --lib <7z.so> extract <archive> <dest> [password]\n"
              << "  rezipper-cli --lib <7z.so> create <archive> <file...>\n"
              << "  rezipper-cli --lib <7z.so> add <archive> <file...>\n"
              << "  rezipper-cli --lib <7z.so> remove <archive> <index...>\n";
}

int main(int argc, char** argv) {
    if (argc < 5) {
        usage();
        return 2;
    }

    std::string lib;
    std::vector<std::string> args;
    for (int i = 1; i < argc; ++i) {
        const std::string arg = argv[i];
        if (arg == "--lib" && i + 1 < argc) {
            lib = argv[++i];
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
            const std::string password = args.size() > 2 ? args[2] : "";
            const auto info = rz::Engine::instance().list(args[1], password);
            std::cout << info.formatName << "  files=" << info.fileCount
                      << " folders=" << info.folderCount
                      << " size=" << info.totalSize
                      << " packed=" << info.packedSize << "\n";
            for (const auto& item : info.items) {
                std::cout << (item.isDir ? "D " : "F ")
                          << item.size << "\t" << item.path << "\n";
            }
            return 0;
        }
        if (cmd == "test") {
            const std::string password = args.size() > 2 ? args[2] : "";
            auto progress = std::make_shared<rz::Progress>();
            rz::Engine::instance().test(args[1], password, progress);
            std::cout << "OK\n";
            return 0;
        }
        if (cmd == "extract") {
            if (args.size() < 3) {
                usage();
                return 2;
            }
            const std::string password = args.size() > 3 ? args[3] : "";
            auto progress = std::make_shared<rz::Progress>();
            rz::Engine::instance().extract(args[1], args[2], {}, password, progress);
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
                indices.push_back(static_cast<std::uint32_t>(std::stoul(args[i])));
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
