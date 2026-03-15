cmake_minimum_required(VERSION 3.14)
project(drm-splash VERSION 1.0.0 LANGUAGES C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

find_package(PkgConfig REQUIRED)
pkg_check_modules(DRM REQUIRED libdrm)

option(STATIC_BUILD "Link drm-splash as a fully static binary (for initramfs)" OFF)

add_executable(drm-splash drm-splash.c)

target_include_directories(drm-splash PRIVATE ${DRM_INCLUDE_DIRS})
# Use DRM_LDFLAGS (includes -L<dir> -ldrm) rather than just DRM_LIBRARIES
# so the cross linker can locate libdrm.a when doing a static build.
target_link_libraries(drm-splash PRIVATE ${DRM_LDFLAGS})
target_compile_options(drm-splash PRIVATE ${DRM_CFLAGS_OTHER} -Wall -Wextra)

if(STATIC_BUILD)
    target_link_options(drm-splash PRIVATE -static)
    # pthreads and math are pulled in transitively by libdrm when linking static
    target_link_libraries(drm-splash PRIVATE pthread m)
endif()

include(GNUInstallDirs)
install(TARGETS drm-splash RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR})
install(FILES systemd/drm-splash.service
        DESTINATION ${CMAKE_INSTALL_PREFIX}/lib/systemd/system)
install(PROGRAMS bmp2raw.py
        DESTINATION ${CMAKE_INSTALL_BINDIR}
        RENAME bmp2raw)
