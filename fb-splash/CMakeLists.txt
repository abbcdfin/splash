cmake_minimum_required(VERSION 3.14)
project(fb-splash VERSION 1.0.0 LANGUAGES C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

option(STATIC_BUILD "Link fb-splash as a fully static binary (for embedded targets)" OFF)

add_executable(fb-splash fb-splash.c)
target_compile_options(fb-splash PRIVATE -Wall -Wextra)

if(STATIC_BUILD)
    target_link_options(fb-splash PRIVATE -static)
endif()

include(GNUInstallDirs)
install(TARGETS fb-splash RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR})
install(FILES systemd/fb-splash.service
        DESTINATION ${CMAKE_INSTALL_PREFIX}/lib/systemd/system)
