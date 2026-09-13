add_files(
    ios_stdafx.h
    ios.h
    ios.mm
    ios_main.h
    CONDITION IOS
)

if(IOS)
    target_sources(openttd PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/main_ios.mm)
endif()