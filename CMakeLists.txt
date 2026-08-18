cmake_minimum_required(VERSION 3.22)
project(ReZipper LANGUAGES C CXX OBJCXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_OBJCXX_STANDARD 17)
set(CMAKE_OBJCXX_STANDARD_REQUIRED ON)
set(CMAKE_OSX_DEPLOYMENT_TARGET "12.0" CACHE STRING "Minimum macOS version")

if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release CACHE STRING "" FORCE)
endif()

# --- 7-Zip shared library (Format7zF → 7z.so) ---
set(SEVENZIP_SRC "${CMAKE_SOURCE_DIR}/ThirdParty/7zip")
set(SEVENZIP_TARBALL "${CMAKE_SOURCE_DIR}/ThirdParty/7z2602-src.tar.xz")
if(NOT EXISTS "${SEVENZIP_SRC}/DOC/readme.txt")
    message(STATUS "Extracting 7-Zip 26.02 sources")
    file(MAKE_DIRECTORY "${SEVENZIP_SRC}")
    file(ARCHIVE_EXTRACT INPUT "${SEVENZIP_TARBALL}" DESTINATION "${SEVENZIP_SRC}")
endif()
if(CMAKE_OSX_ARCHITECTURES)
    set(_rz_arch "${CMAKE_OSX_ARCHITECTURES}")
else()
    set(_rz_arch "${CMAKE_SYSTEM_PROCESSOR}")
endif()
if(_rz_arch MATCHES "arm64|aarch64")
    set(SEVENZIP_MAKEFILE ../../cmpl_mac_arm64.mak)
    set(SEVENZIP_SO "${SEVENZIP_SRC}/CPP/7zip/Bundles/Format7zF/b/m_arm64/7z.so")
else()
    set(SEVENZIP_MAKEFILE ../../cmpl_mac_x64.mak)
    set(SEVENZIP_SO "${SEVENZIP_SRC}/CPP/7zip/Bundles/Format7zF/b/m_x64/7z.so")
endif()

find_program(GNU_MAKE_PROGRAM make REQUIRED)
include(ProcessorCount)
ProcessorCount(RZ_JOBS)
if(NOT RZ_JOBS)
    set(RZ_JOBS 4)
endif()

add_custom_command(
    OUTPUT "${SEVENZIP_SO}"
    COMMAND "${GNU_MAKE_PROGRAM}" -j "${RZ_JOBS}" -f "${SEVENZIP_MAKEFILE}"
    WORKING_DIRECTORY "${SEVENZIP_SRC}/CPP/7zip/Bundles/Format7zF"
    COMMENT "Building 7-Zip Format7zF library"
    VERBATIM
)
add_custom_target(sevenzip_lib DEPENDS "${SEVENZIP_SO}")

# --- bit7z C++ wrapper ---
set(BIT7Z_SRC "${CMAKE_SOURCE_DIR}/ThirdParty/bit7z")
if(NOT EXISTS "${BIT7Z_SRC}/CMakeLists.txt")
    message(STATUS "Cloning bit7z")
    execute_process(
        COMMAND git clone --depth 1 https://github.com/rikyoz/bit7z.git "${BIT7Z_SRC}"
        RESULT_VARIABLE BIT7Z_CLONE
    )
    if(NOT BIT7Z_CLONE EQUAL 0)
        message(FATAL_ERROR "Failed to clone bit7z")
    endif()
endif()
set(BIT7Z_AUTO_FORMAT ON CACHE BOOL "" FORCE)
set(BIT7Z_USE_NATIVE_STRING ON CACHE BOOL "" FORCE)
set(BIT7Z_CUSTOM_7ZIP_PATH "${SEVENZIP_SRC}" CACHE STRING "" FORCE)
set(BIT7Z_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(BIT7Z_BUILD_DOCS OFF CACHE BOOL "" FORCE)
set(BIT7Z_USE_PCH OFF CACHE BOOL "" FORCE)
set(BIT7Z_GENERATE_PIC OFF CACHE BOOL "" FORCE)
add_subdirectory(ThirdParty/bit7z EXCLUDE_FROM_ALL)

# --- Engine ---
add_library(rezipper_engine STATIC Engine/ArchiveEngine.cpp)
target_include_directories(rezipper_engine PUBLIC "${CMAKE_SOURCE_DIR}/Engine")
target_link_libraries(rezipper_engine PUBLIC bit7z iconv)
target_compile_options(rezipper_engine PRIVATE -fPIC)

add_executable(rezipper-cli Engine/rezipper_cli.cpp)
target_link_libraries(rezipper-cli PRIVATE rezipper_engine)

# --- AppKit frontend ---
set(APP_SOURCES
    App/main.mm
    App/RZAppDelegate.mm
    App/RZCommon.mm
    App/RZDocument.mm
    App/RZMainWindowController.mm
    App/RZPreview.mm
    App/RZSheets.mm
)
set(APP_RESOURCES
    Resources/AppIcon.icns
    Resources/Info.plist
)

add_executable(ReZipper MACOSX_BUNDLE ${APP_SOURCES} Resources/AppIcon.icns)
target_include_directories(ReZipper PRIVATE "${CMAKE_SOURCE_DIR}/App" "${CMAKE_SOURCE_DIR}/Engine")
target_link_libraries(ReZipper PRIVATE
    rezipper_engine
    "-framework Cocoa"
    "-framework AppKit"
    "-framework PDFKit"
    "-framework UniformTypeIdentifiers"
)
target_compile_options(ReZipper PRIVATE -fobjc-arc -fobjc-weak)
add_dependencies(ReZipper sevenzip_lib)

set_source_files_properties(Resources/AppIcon.icns PROPERTIES MACOSX_PACKAGE_LOCATION Resources)

set_target_properties(ReZipper PROPERTIES
    MACOSX_BUNDLE TRUE
    MACOSX_BUNDLE_INFO_PLIST "${CMAKE_SOURCE_DIR}/Resources/Info.plist"
    MACOSX_BUNDLE_BUNDLE_NAME "ReZipper"
    MACOSX_BUNDLE_BUNDLE_VERSION "1"
    MACOSX_BUNDLE_SHORT_VERSION_STRING "1.0.0"
    MACOSX_BUNDLE_GUI_IDENTIFIER "app.rezipper"
    MACOSX_BUNDLE_ICON_FILE "AppIcon"
    MACOSX_BUNDLE_COPYRIGHT "Copyright © 2026 ReZipper. 7-Zip engine © Igor Pavlov."
    OUTPUT_NAME "ReZipper"
    XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER "app.rezipper"
    XCODE_ATTRIBUTE_CLANG_ENABLE_OBJC_ARC YES
)

# CMake's default plist substitution uses MACOSX_BUNDLE_* keys, not $(EXECUTABLE_NAME).
# Rewrite those Xcode-style placeholders after configure.
file(READ "${CMAKE_SOURCE_DIR}/Resources/Info.plist" RZ_PLIST)
string(REPLACE "$(EXECUTABLE_NAME)" "ReZipper" RZ_PLIST "${RZ_PLIST}")
string(REPLACE "$(PRODUCT_BUNDLE_IDENTIFIER)" "app.rezipper" RZ_PLIST "${RZ_PLIST}")
file(WRITE "${CMAKE_BINARY_DIR}/Info.plist" "${RZ_PLIST}")
set_target_properties(ReZipper PROPERTIES MACOSX_BUNDLE_INFO_PLIST "${CMAKE_BINARY_DIR}/Info.plist")

add_custom_command(TARGET ReZipper POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E make_directory "$<TARGET_FILE_DIR:ReZipper>/../Frameworks"
    COMMAND ${CMAKE_COMMAND} -E copy_if_different "${SEVENZIP_SO}" "$<TARGET_FILE_DIR:ReZipper>/../Frameworks/7z.so"
    COMMENT "Bundling 7z.so into ReZipper.app"
)

install(TARGETS ReZipper BUNDLE DESTINATION .)
