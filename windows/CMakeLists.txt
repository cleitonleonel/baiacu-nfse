# Project-level configuration.
cmake_minimum_required(VERSION 3.14)
project(emissor_nfse LANGUAGES CXX)

# The name of the executable created for the application. Change this to change
# the on-disk name of your application.
set(BINARY_NAME "emissor_nfse")

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(VERSION 3.14...3.25)

# Define build configuration option.
get_property(IS_MULTICONFIG GLOBAL PROPERTY GENERATOR_IS_MULTI_CONFIG)
if(IS_MULTICONFIG)
  set(CMAKE_CONFIGURATION_TYPES "Debug;Profile;Release"
    CACHE STRING "" FORCE)
else()
  if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE "Debug" CACHE
      STRING "Flutter build mode" FORCE)
    set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
      "Debug" "Profile" "Release")
  endif()
endif()
# Define settings for the Profile build mode.
set(CMAKE_EXE_LINKER_FLAGS_PROFILE "${CMAKE_EXE_LINKER_FLAGS_RELEASE}")
set(CMAKE_SHARED_LINKER_FLAGS_PROFILE "${CMAKE_SHARED_LINKER_FLAGS_RELEASE}")
set(CMAKE_C_FLAGS_PROFILE "${CMAKE_C_FLAGS_RELEASE}")
set(CMAKE_CXX_FLAGS_PROFILE "${CMAKE_CXX_FLAGS_RELEASE}")

# O executavel e os plugins levam a biblioteca do Visual C++ embutida (/MT): assim o .exe nao precisa
# de nenhuma DLL ao lado dele e todas elas podem morar em data/dll (ver runner/main.cpp).
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
foreach(NFSE_FLAGS CMAKE_C_FLAGS_DEBUG CMAKE_CXX_FLAGS_DEBUG CMAKE_C_FLAGS_PROFILE CMAKE_CXX_FLAGS_PROFILE
    CMAKE_C_FLAGS_RELEASE CMAKE_CXX_FLAGS_RELEASE)
  string(REPLACE "/MD" "/MT" ${NFSE_FLAGS} "${${NFSE_FLAGS}}")
endforeach()

# Use Unicode for all projects.
add_definitions(-DUNICODE -D_UNICODE)

# Compilation settings that should be applied to most targets.
#
# Be cautious about adding new options here, as plugins use this function by
# default. In most cases, you should add new options to specific targets instead
# of modifying this function.
function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_17)
  target_compile_options(${TARGET} PRIVATE /W4 /WX /wd"4100")
  target_compile_options(${TARGET} PRIVATE /EHsc)
  target_compile_definitions(${TARGET} PRIVATE "_HAS_EXCEPTIONS=0")
  target_compile_definitions(${TARGET} PRIVATE "$<$<CONFIG:Debug>:_DEBUG>")
endfunction()

# Flutter library and tool build rules.
set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")
add_subdirectory(${FLUTTER_MANAGED_DIR})

# Application build; see runner/CMakeLists.txt.
add_subdirectory("runner")


# Generated plugin build rules, which manage building the plugins and adding
# them to the application.
include(flutter/generated_plugins.cmake)

# As DLLs do Flutter e dos plugins moram em data/dll, nao ao lado do executavel: so sao carregadas
# quando o programa ja disse ao Windows onde procura-las (SetDllDirectory, em runner/main.cpp).
get_filename_component(NFSE_FLUTTER_DLL "${FLUTTER_LIBRARY}" NAME)
target_link_options(${BINARY_NAME} PRIVATE "/DELAYLOAD:${NFSE_FLUTTER_DLL}")
foreach(plugin ${FLUTTER_PLUGIN_LIST})
  target_link_options(${BINARY_NAME} PRIVATE "/DELAYLOAD:$<TARGET_FILE_NAME:${plugin}_plugin>")
endforeach(plugin)
target_link_libraries(${BINARY_NAME} PRIVATE delayimp advapi32 shell32)


# === Installation ===
# Support files are copied into place next to the executable, so that it can
# run in place. This is done instead of making a separate bundle (as on Linux)
# so that building and running from within Visual Studio will work.
set(BUILD_BUNDLE_DIR "$<TARGET_FILE_DIR:${BINARY_NAME}>")
# Make the "install" step default, as it's required to run.
set(CMAKE_VS_INCLUDE_INSTALL_TO_DEFAULT_BUILD 1)
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "..." FORCE)
endif()

# Ao lado do executavel ficam so pastas: o que o programa carrega para rodar mora em data/ (arquivos
# do Flutter) e data/dll (todas as DLLs). Os bancos do usuario ficam em database/.
set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
set(INSTALL_BUNDLE_LIB_DIR "${INSTALL_BUNDLE_DATA_DIR}/dll")

install(TARGETS ${BINARY_NAME} RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

# Nucleo em Rust (regras do programa): compilado pelo cargo e instalado com as outras DLLs.
set(NUCLEO_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../rust")
set(NUCLEO_TARGET_DIR "$ENV{CARGO_TARGET_DIR}")
if(NOT NUCLEO_TARGET_DIR)
  set(NUCLEO_TARGET_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../extras/cache/target_cargo")
endif()
add_custom_target(nucleo_rust ALL
  COMMAND cargo build --release --locked --workspace --target-dir "${NUCLEO_TARGET_DIR}"
  WORKING_DIRECTORY "${NUCLEO_DIR}"
  COMMENT "Compilando o nucleo em Rust"
  VERBATIM)
add_dependencies(${BINARY_NAME} nucleo_rust)
install(FILES "${NUCLEO_TARGET_DIR}/release/baiacu-atualizador.exe"
  DESTINATION "${CMAKE_INSTALL_PREFIX}/service" COMPONENT Runtime)
install(FILES "${NUCLEO_TARGET_DIR}/release/baiacu-dados.exe"
  DESTINATION "${INSTALL_BUNDLE_LIB_DIR}" COMPONENT Runtime)
install(FILES "${NUCLEO_TARGET_DIR}/release/nucleo.dll"
  DESTINATION "${INSTALL_BUNDLE_LIB_DIR}" COMPONENT Runtime)
install(FILES "${NUCLEO_DIR}/recursos/danfse/LICENSE" "${NUCLEO_DIR}/recursos/danfse/LICENSE-QR" "${NUCLEO_DIR}/recursos/danfse/ORIGEM.md"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}/licencas" COMPONENT Runtime)
# As licencas do que vai compilado dentro do nucleo.dll: OpenSSL, libxml2 e a GPL-3.0 (a LGPL-3.0
# da DANFSe se apoia nela).
install(FILES "${NUCLEO_DIR}/terceiros/openssl/LICENSE.txt"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}/licencas" RENAME "OpenSSL-LICENSE.txt" COMPONENT Runtime)
install(FILES "${NUCLEO_DIR}/terceiros/libxml2/Copyright"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}/licencas" RENAME "libxml2-Copyright.txt" COMPONENT Runtime)
install(FILES "${NUCLEO_DIR}/recursos/danfse/LICENSE-GPL"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}/licencas" COMPONENT Runtime)

install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

if(PLUGIN_BUNDLED_LIBRARIES)
  install(FILES "${PLUGIN_BUNDLED_LIBRARIES}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()

# Copy the native assets provided by the build.dart from all packages.
set(NATIVE_ASSETS_DIR "${PROJECT_BUILD_DIR}native_assets/windows/")
install(DIRECTORY "${NATIVE_ASSETS_DIR}"
   DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
   COMPONENT Runtime)

# Fully re-copy the assets directory on each build to avoid having stale files
# from a previous install.
set(FLUTTER_ASSET_DIR_NAME "flutter_assets")
install(CODE "
  file(REMOVE_RECURSE \"${INSTALL_BUNDLE_DATA_DIR}/${FLUTTER_ASSET_DIR_NAME}\")
  " COMPONENT Runtime)
install(DIRECTORY "${PROJECT_BUILD_DIR}/${FLUTTER_ASSET_DIR_NAME}"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}" COMPONENT Runtime)

# Install the AOT library on non-Debug builds only.
install(FILES "${AOT_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  CONFIGURATIONS Profile;Release
  COMPONENT Runtime)
