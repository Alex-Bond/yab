cmake_minimum_required(VERSION 3.21)
project(YabCore LANGUAGES C CXX OBJCXX)
if(NOT APPLE)
  message(FATAL_ERROR "YabCore requires macOS")
endif()
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_OBJCXX_STANDARD 20)
set(CMAKE_MODULE_PATH ${CMAKE_MODULE_PATH} "${CEF_ROOT}/cmake")
find_package(CEF REQUIRED)
add_subdirectory(${CEF_LIBCEF_DLL_WRAPPER_PATH} libcef_dll_wrapper)
SET_CEF_TARGET_OUT_DIR()
set(VERSION_SHORT "0.1.0")
set(EXECUTABLE_NAME "YabCore")
set(PRODUCT_NAME "YabCore")
set(BUNDLE_ID_SUFFIX "")
configure_file(src/Info.plist.in "${CMAKE_CURRENT_BINARY_DIR}/main-Info.plist" @ONLY)
add_executable(YabCore MACOSX_BUNDLE src/main.mm src/core.mm src/transport.mm src/original_caller.mm)
SET_EXECUTABLE_TARGET_PROPERTIES(YabCore)
target_compile_options(YabCore PRIVATE -fobjc-arc -std=c++20)
# Optional trusted BUILD input only. It never changes acceptedVersion0.
set(YABCORE_PARENT_POLICY_HEADER "" CACHE FILEPATH "Exact precompile parent policy input")
if(YABCORE_PARENT_POLICY_HEADER)
  if(NOT EXISTS "${YABCORE_PARENT_POLICY_HEADER}" OR IS_DIRECTORY "${YABCORE_PARENT_POLICY_HEADER}")
    message(FATAL_ERROR "Missing exact parent policy input")
  endif()
  file(MAKE_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/trusted-parent-policy")
  configure_file("${YABCORE_PARENT_POLICY_HEADER}" "${CMAKE_CURRENT_BINARY_DIR}/trusted-parent-policy/original_parent_policy.generated.inc" COPYONLY)
  target_include_directories(YabCore PRIVATE "${CMAKE_CURRENT_BINARY_DIR}/trusted-parent-policy")
  target_compile_definitions(YabCore PRIVATE YABCORE_BUILD_HAS_PARENT_POLICY=1)
endif()

target_link_libraries(YabCore libcef_dll_wrapper ${CEF_STANDARD_LIBS} "-framework Cocoa" "-framework QuartzCore" "-framework Security")
set_target_properties(YabCore PROPERTIES MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_BINARY_DIR}/main-Info.plist")
set(CEF_APP "${CEF_TARGET_OUT_DIR}/YabCore.app")
# Unlike the sample's ln -sf, -sfn never follows an existing directory link
# on an incremental relink, which would create Resources/Resources and A/A.
set(CORE_FRAMEWORK "${CEF_APP}/Contents/Frameworks/Chromium Embedded Framework.framework")
add_custom_command(TARGET YabCore POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E copy_directory "${CEF_BINARY_DIR}/Chromium Embedded Framework.framework" "${CORE_FRAMEWORK}/Versions/A"
  COMMAND ln -sfn "Versions/A/Chromium Embedded Framework" "${CORE_FRAMEWORK}/Chromium Embedded Framework"
  COMMAND ln -sfn "Versions/A/Libraries" "${CORE_FRAMEWORK}/Libraries"
  COMMAND ln -sfn "Versions/A/Resources" "${CORE_FRAMEWORK}/Resources"
  COMMAND ln -sfn "A" "${CORE_FRAMEWORK}/Versions/Current"
  VERBATIM)
foreach(suffix ${CEF_HELPER_APP_SUFFIXES})
  string(REPLACE ":" ";" parts "${suffix}")
  list(GET parts 0 name)
  list(GET parts 1 target)
  list(GET parts 2 BUNDLE_ID_SUFFIX)
  set(BUNDLE_ID_SUFFIX ".helper${BUNDLE_ID_SUFFIX}")
  set(EXECUTABLE_NAME "YabCore Helper${name}")
  set(PRODUCT_NAME "${EXECUTABLE_NAME}")
  configure_file(src/Info.plist.in "${CMAKE_CURRENT_BINARY_DIR}/helper${target}.plist" @ONLY)
  add_executable(YabCore_Helper${target} MACOSX_BUNDLE src/helper.cc)
  SET_EXECUTABLE_TARGET_PROPERTIES(YabCore_Helper${target})
  target_link_libraries(YabCore_Helper${target} libcef_dll_wrapper ${CEF_STANDARD_LIBS})
  set_target_properties(YabCore_Helper${target} PROPERTIES OUTPUT_NAME "${EXECUTABLE_NAME}"
    MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_BINARY_DIR}/helper${target}.plist")
  add_dependencies(YabCore YabCore_Helper${target})
  add_custom_command(TARGET YabCore POST_BUILD COMMAND ${CMAKE_COMMAND} -E copy_directory
    "${CEF_TARGET_OUT_DIR}/${EXECUTABLE_NAME}.app" "${CEF_APP}/Contents/Frameworks/${EXECUTABLE_NAME}.app" VERBATIM)
endforeach()
