cmake_minimum_required(VERSION 3.20)

project(seastar_echo LANGUAGES CXX)

include(CTest)
include(FetchContent)

set(Seastar_APPS OFF CACHE BOOL "" FORCE)
set(Seastar_DEMOS OFF CACHE BOOL "" FORCE)
set(Seastar_DOCS OFF CACHE BOOL "" FORCE)
set(Seastar_INSTALL OFF CACHE BOOL "" FORCE)
set(Seastar_TESTING OFF CACHE BOOL "" FORCE)
set(Seastar_DPDK OFF CACHE BOOL "" FORCE)
set(Seastar_LTTNG OFF CACHE BOOL "" FORCE)

FetchContent_Declare(
    seastar
    GIT_REPOSITORY https://github.com/scylladb/seastar.git
    GIT_TAG seastar-25.05.0
    GIT_SHALLOW TRUE
)
FetchContent_MakeAvailable(seastar)

add_executable(seastar_echo_server src/seastar_echo_server.cc)
add_executable(seastar_echo_client src/seastar_echo_client.cc)

foreach(target seastar_echo_server seastar_echo_client)
    target_compile_features(${target} PRIVATE cxx_std_20)
    target_link_libraries(${target} PRIVATE Seastar::seastar)
endforeach()

add_executable(protocol_check test/protocol_check.cc)
target_compile_features(protocol_check PRIVATE cxx_std_20)
add_test(NAME seastar_echo.protocol COMMAND protocol_check)

set(IOUR_ADA_ECHO_SERVER "${CMAKE_CURRENT_LIST_DIR}/../../bin/echo_server" CACHE FILEPATH "Path to the Ada echo server")
set(IOUR_ADA_ECHO_CLIENT "${CMAKE_CURRENT_LIST_DIR}/../../bin/echo_client" CACHE FILEPATH "Path to the Ada echo client")
set(IOUR_TOKIO_ECHO_SERVER "${CMAKE_CURRENT_LIST_DIR}/../tokio_echo/target/release/tokio_echo_server" CACHE FILEPATH "Path to the Tokio echo server")
set(IOUR_TOKIO_ECHO_CLIENT "${CMAKE_CURRENT_LIST_DIR}/../tokio_echo/target/release/tokio_echo_client" CACHE FILEPATH "Path to the Tokio echo client")

find_package(Python3 COMPONENTS Interpreter QUIET)
if(BUILD_TESTING AND Python3_Interpreter_FOUND
   AND EXISTS "${IOUR_ADA_ECHO_SERVER}" AND EXISTS "${IOUR_ADA_ECHO_CLIENT}"
   AND EXISTS "${IOUR_TOKIO_ECHO_SERVER}" AND EXISTS "${IOUR_TOKIO_ECHO_CLIENT}")
    add_test(
        NAME seastar_echo.interoperability
        COMMAND ${Python3_EXECUTABLE} ${CMAKE_CURRENT_LIST_DIR}/test/interoperability_check.py
            --seastar-server $<TARGET_FILE:seastar_echo_server>
            --seastar-client $<TARGET_FILE:seastar_echo_client>
            --tokio-server ${IOUR_TOKIO_ECHO_SERVER}
            --tokio-client ${IOUR_TOKIO_ECHO_CLIENT}
            --ada-server ${IOUR_ADA_ECHO_SERVER}
            --ada-client ${IOUR_ADA_ECHO_CLIENT}
    )
    set_tests_properties(seastar_echo.interoperability PROPERTIES TIMEOUT 60)
endif()