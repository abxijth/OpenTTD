# This file is part of OpenTTD.
# OpenTTD is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 2.
# OpenTTD is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
# See the GNU General Public License for more details. You should have received a copy of the GNU General Public License along with OpenTTD. If not, see <https://www.gnu.org/licenses/old-licenses/gpl-2.0>.

# Cross-compilation toolchain file for building OpenTTD for iOS.
#
# Usage (from the OpenTTD source directory):
#     cmake -G Xcode -DCMAKE_TOOLCHAIN_FILE=os/ios/toolchain_ios.cmake -DIOS_PLATFORM=OS -B build-ios
# or, using plain Makefiles for a simulator/device build:
#     cmake -DCMAKE_TOOLCHAIN_FILE=os/ios/toolchain_ios.cmake -DIOS_PLATFORM=OS -B build-ios
#
# Configuration variables:
#   IOS_PLATFORM: OS         - build for a physical device (default)
#                 SIMULATOR  - build for the iOS Simulator
#   IOS_ARCH:     which architectures to target; defaults to the usual ones
#                 for the selected platform (arm64 for OS, x86_64+arm64 for SIMULATOR)
#   IOS_DEPLOYMENT_TARGET: minimum iOS version, defaults to 13.0

if(DEFINED IOS_CMAKE_TOOLCHAIN_LOADED)
    return()
endif()
set(IOS_CMAKE_TOOLCHAIN_LOADED ON)

# Only Apple's Clang can cross-compile for iOS.
set(CMAKE_SYSTEM_NAME iOS)

if(NOT DEFINED IOS_DEPLOYMENT_TARGET)
    set(IOS_DEPLOYMENT_TARGET "13.0" CACHE STRING "Minimum iOS deployment target" FORCE)
endif()
set(CMAKE_OSX_DEPLOYMENT_TARGET "${IOS_DEPLOYMENT_TARGET}")

if(NOT DEFINED IOS_PLATFORM)
    set(IOS_PLATFORM "OS" CACHE STRING "Target platform: OS or SIMULATOR" FORCE)
endif()

if(IOS_PLATFORM STREQUAL "OS")
    set(IOS_PLATFORM_IS_DEVICE ON)
    set(CMAKE_OSX_SYSROOT iphoneos)
    if(NOT DEFINED IOS_ARCH)
        set(IOS_ARCH "arm64" CACHE STRING "Architectures to build for" FORCE)
    endif()
elseif(IOS_PLATFORM STREQUAL "SIMULATOR")
    set(IOS_PLATFORM_IS_DEVICE OFF)
    set(CMAKE_OSX_SYSROOT iphonesimulator)
    if(NOT DEFINED IOS_ARCH)
        set(IOS_ARCH "arm64;x86_64" CACHE STRING "Architectures to build for" FORCE)
    endif()
else()
    message(FATAL_ERROR "Accepted IOS_PLATFORM values are OS and SIMULATOR, you passed '${IOS_PLATFORM}'")
endif()

set(CMAKE_OSX_ARCHITECTURES "${IOS_ARCH}" CACHE STRING "Architectures to build for" FORCE)

# --sysroot is set by CMake itself via CMAKE_OSX_SYSROOT; find the compiler.
find_program(CMAKE_CXX_COMPILER NAMES clang++ HINTS /usr/bin /opt/homebrew/opt/llvm/bin)
find_program(CMAKE_C_COMPILER NAMES clang HINTS /usr/bin /opt/homebrew/opt/llvm/bin)
MARK_AS_ADVANCED(CMAKE_CXX_COMPILER CMAKE_C_COMPILER)

if(NOT CMAKE_CXX_COMPILER)
    message(FATAL_ERROR "clang++ not found; Xcode and the Command Line Tools are required to build for iOS.")
endif()

# Force common iOS-specific settings.
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -fPIC -fvisibility=hidden")
set(CMAKE_EXE_LINKER_FLAGS "${CMAKE_EXE_LINKER_FLAGS} -fvisibility=hidden")

# iOS cannot produce shared libraries / modules.
set(CMAKE_SHARED_LIBRARY_LINK_C_FLAGS "")
set(CMAKE_SHARED_LIBRARY_LINK_CXX_FLAGS "")
set(CMAKE_SHARED_LIBRARY_CREATE_C_FLAGS "-shared")
set(CMAKE_SHARED_LIBRARY_CREATE_CXX_FLAGS "-shared")
set(CMAKE_SHARED_LIBRARY_C_FLAGS "")
set(CMAKE_SHARED_LIBRARY_CXX_FLAGS "")
set(CMAKE_MODULE_EXISTS 0)
set(CMAKE_SKIP_RPATH ON)

# No exceptions / RTTI is optional; keep them enabled as OpenTTD uses exceptions.
set(CMAKE_THREAD_PREFER_PTHREAD TRUE)
set(THREADS_PREFER_PTHREAD_FLAG TRUE)

# CMake does not automatically link libpthread on iOS; Threads::Threads works
# via the toolchain below.
set(IOS TRUE)