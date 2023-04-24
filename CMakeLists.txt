cmake_minimum_required(VERSION 3.13)

# cmake_policy(SET CMP0079 NEW)
# cmake_policy(SET CMP0048 NEW)

project(examples)

add_subdirectory(openssl)

function(add_example target_name)
    set(multiValueArgs FILES)
    cmake_parse_arguments(opt "" "" "${multiValueArgs}" ${ARGN})
    add_executable(${target_name} ${opt_FILES})
    target_include_directories(${target_name} PRIVATE "${CMAKE_CURRENT_LIST_DIR}/asio/include")
endfunction()

function(add_ssl_example target_name)
    set(multiValueArgs FILES)
    cmake_parse_arguments(opt "" "" "${multiValueArgs}" ${ARGN})
    add_executable(${target_name} ${opt_FILES})
    target_include_directories(${target_name} 
        PRIVATE "${CMAKE_CURRENT_LIST_DIR}/asio/include"
        PRIVATE "${OPENSSL_INCLUDE_DIR}"
    )
    target_link_libraries(${target_name} OpenSSL::SSL OpenSSL::Crypto)
endfunction()


add_example(cpp03_http_async_client FILES "asio/src/examples/cpp03/http/client/async_client.cpp")
add_ssl_example(cpp11_ssl_client FILES "asio/src/examples/cpp11/ssl/client.cpp")

