add_files(
    crashlog_osx.cpp
    font_osx.cpp
    font_osx.h
    macos.h
    osx_stdafx.h
    string_osx.cpp
    string_osx.h
    survey_osx.cpp
    CONDITION APPLE
)

# macos.mm and macos_objective_c.h pull in AppKit and are replaced by the
# UIKit-based ios.mm on iOS.
add_files(
    macos.mm
    macos_objective_c.h
    CONDITION APPLE AND NOT IOS
)

if(APPLE AND NOT IOS)
    target_sources(openttd PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/osx_main.cpp)
endif()
