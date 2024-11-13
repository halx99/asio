cmake_minimum_required(VERSION 3.13)

# cmake_policy(SET CMP0079 NEW)
# cmake_policy(SET CMP0048 NEW)

project(asio)

set(_1kfetch_cache_dir "${CMAKE_CURRENT_LIST_DIR}/cache" CACHE STRING "" FORCE)
set(_1kfetch_manifest "${CMAKE_CURRENT_LIST_DIR}/manifest.json" CACHE STRING "" FORCE)

include(1k/platform.cmake)
include(1k/fetch.cmake)

include(CMakeDependentOption)

cmake_dependent_option(ASIO_WITH_EXAMPLES
  "Build the tests when we are the root project" ON
  "CMAKE_SOURCE_DIR STREQUAL PROJECT_SOURCE_DIR" OFF)


# asio win7+: suppress
add_definitions(-D_WIN32_WINNT=0x0601)

add_subdirectory(openssl)

macro(source_group_by_dir proj_dir source_files)
    if(MSVC OR APPLE)
        get_filename_component(sgbd_cur_dir ${proj_dir} ABSOLUTE)
        foreach(sgbd_file ${${source_files}})
            get_filename_component(sgbd_abs_file ${sgbd_file} ABSOLUTE)
            file(RELATIVE_PATH sgbd_fpath ${sgbd_cur_dir} ${sgbd_abs_file})
            string(REGEX REPLACE "\(.*\)/.*" \\1 sgbd_group_name ${sgbd_fpath})
            string(COMPARE EQUAL ${sgbd_fpath} ${sgbd_group_name} sgbd_nogroup)
            string(REPLACE "/" "\\" sgbd_group_name ${sgbd_group_name})
            if(sgbd_nogroup)
                set(sgbd_group_name "\\")
            endif(sgbd_nogroup)
            source_group(${sgbd_group_name} FILES ${sgbd_file})
        endforeach(sgbd_file)
    endif(MSVC OR APPLE)
endmacro(source_group_by_dir)

file(GLOB_RECURSE asio_source_files ${CMAKE_CURRENT_LIST_DIR}/asio/include/*.hpp;${CMAKE_CURRENT_LIST_DIR}/asio/include/*.ipp)
list(APPEND asio_source_files asio/src/asio.cpp)

find_package(OpenSSL)
if(OPENSSL_FOUND)
    list(APPEND asio_source_files asio/src/asio_ssl.cpp)
endif()
source_group_by_dir(${CMAKE_CURRENT_LIST_DIR} asio_source_files)

add_library(asio ${asio_source_files})
target_compile_features(asio PUBLIC cxx_std_17)
target_include_directories(asio PUBLIC ${CMAKE_CURRENT_LIST_DIR}/asio/include)
target_compile_definitions(asio PUBLIC ASIO_SEPARATE_COMPILATION=1)
if(BUILD_SHARED_LIBS)
    target_compile_definitions(asio PUBLIC ASIO_DYN_LINK=1)
endif()

if(OPENSSL_FOUND)
    target_include_directories(asio PRIVATE "${OPENSSL_INCLUDE_DIR}")
    target_link_libraries(asio OpenSSL::SSL OpenSSL::Crypto)
endif()

add_library(asio-header-only INTERFACE)
add_library(asio::asio-header-only ALIAS asio-header-only)
target_include_directories(asio-header-only INTERFACE ${CMAKE_CURRENT_LIST_DIR}/asio/include)
target_compile_features(asio-header-only INTERFACE cxx_std_17)
target_compile_definitions(asio-header-only INTERFACE ASIO_HEADER_ONLY=1)

if(ASIO_WITH_EXAMPLES)
    # 
    # add example target
    #  param example: the primary example name
    #  param cxxstd: cpp11, cpp14, cpp17, cpp20
    #  
    #  options:
    #    SUB: the sub example name
    #    PREFIX: add prefix target name
    #    CATALOG: default: examples
    # 
    function(asio_add_target example)
        set(oneValueArgs CATALOG SUB CXXSTD PREFIX SUFFIX)
        set(multiValueArgs FILES)
        cmake_parse_arguments(opt "" "${oneValueArgs}" "${multiValueArgs}" ${ARGN})

        if(opt_CATALOG)
            set(catalog ${opt_CATALOG})
        else()
            set(catalog examples)
        endif()

        set(target_name ${example})
        set(source_dir "${CMAKE_CURRENT_LIST_DIR}/asio/src/${catalog}")

        if(opt_CXXSTD)
            set(source_dir "${source_dir}/${opt_CXXSTD}")
        endif()

        set(source_dir "${source_dir}/${example}")

        if(opt_SUB) 
            set(source_dir "${source_dir}/${opt_SUB}")
            set(target_name ${target_name}_${opt_SUB})
        endif()

        if(opt_PREFIX)
            set(target_name ${opt_PREFIX}_${target_name})
        endif()

        if(opt_CXXSTD)
            set(target_name ${opt_CXXSTD}_${target_name})
        endif()

        if (opt_SUFFIX)
            set(target_name ${target_name}_${opt_SUFFIX})
        endif()

        if(opt_FILES)
            set(target_files )
            foreach(file_name ${opt_FILES})
                list(APPEND target_files ${source_dir}/${file_name})
            endforeach()
        else()
            file(GLOB_RECURSE target_files ${source_dir}/*.h;${source_dir}/*.cpp)
        endif()
        file(GLOB_RECURSE cert_files ${source_dir}/*.pem)

        add_executable(${target_name} ${target_files})
        target_link_libraries(${target_name} asio-header-only)

        if(cert_files) # assume require openssl
            target_include_directories(${target_name} PRIVATE "${OPENSSL_INCLUDE_DIR}")
            target_link_libraries(${target_name} OpenSSL::SSL OpenSSL::Crypto)
            # copy openssl dlls
            if (MSVC)
                get_property(SSL_DLL_PATH TARGET OpenSSL::SSL PROPERTY IMPORTED_LOCATION)
                get_property(CRYPTO_DLL_PATH TARGET OpenSSL::Crypto PROPERTY IMPORTED_LOCATION)
                add_custom_command(TARGET ${target_name}
                    COMMAND ${CMAKE_COMMAND} -E copy_if_different
                    ${SSL_DLL_PATH}
                    ${CRYPTO_DLL_PATH}
                    ${cert_files}
                    $<TARGET_FILE_DIR:${target_name}>
                )
            endif ()

            set_property(TARGET ${target_name} PROPERTY VS_DEBUGGER_WORKING_DIRECTORY "$<TARGET_FILE_DIR:${target_name}>")
        endif()

        set_target_properties(${target_name} PROPERTIES FOLDER "Apps")
    endfunction()

    # examples
    asio_add_target(http CXXSTD cpp11 SUB client PREFIX sync FILES sync_client.cpp)
    asio_add_target(http CXXSTD cpp11 SUB client PREFIX async FILES async_client.cpp)
    asio_add_target(http CXXSTD cpp11 SUB server2) # io_context_pool
    asio_add_target(ssl CXXSTD cpp11 FILES client.cpp SUFFIX client)
    asio_add_target(ssl CXXSTD cpp11 FILES server.cpp SUFFIX server)
    asio_add_target(chat CXXSTD cpp11 FILES chat_client.cpp SUFFIX client)
    asio_add_target(chat CXXSTD cpp11 FILES chat_server.cpp SUFFIX server)

    # tests: performance
    asio_add_target(performance CATALOG tests FILES client.cpp SUFFIX client)
    asio_add_target(performance CATALOG tests FILES server.cpp SUFFIX server)

    # tests: latency
    asio_add_target(latency CATALOG tests FILES tcp_client.cpp SUFFIX tcp_client)
    asio_add_target(latency CATALOG tests FILES tcp_server.cpp SUFFIX tcp_server)
    asio_add_target(latency CATALOG tests FILES udp_client.cpp SUFFIX udp_client)
    asio_add_target(latency CATALOG tests FILES udp_server.cpp SUFFIX udp_server)

endif()
