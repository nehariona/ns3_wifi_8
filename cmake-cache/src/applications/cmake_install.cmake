# Install script for directory: /Users/neharionaalice/Downloads/ns-3.48/src/applications

# Set the install prefix
if(NOT DEFINED CMAKE_INSTALL_PREFIX)
  set(CMAKE_INSTALL_PREFIX "/usr/local")
endif()
string(REGEX REPLACE "/$" "" CMAKE_INSTALL_PREFIX "${CMAKE_INSTALL_PREFIX}")

# Set the install configuration name.
if(NOT DEFINED CMAKE_INSTALL_CONFIG_NAME)
  if(BUILD_TYPE)
    string(REGEX REPLACE "^[^A-Za-z0-9_]+" ""
           CMAKE_INSTALL_CONFIG_NAME "${BUILD_TYPE}")
  else()
    set(CMAKE_INSTALL_CONFIG_NAME "default")
  endif()
  message(STATUS "Install configuration: \"${CMAKE_INSTALL_CONFIG_NAME}\"")
endif()

# Set the component getting installed.
if(NOT CMAKE_INSTALL_COMPONENT)
  if(COMPONENT)
    message(STATUS "Install component: \"${COMPONENT}\"")
    set(CMAKE_INSTALL_COMPONENT "${COMPONENT}")
  else()
    set(CMAKE_INSTALL_COMPONENT)
  endif()
endif()

# Is this installation the result of a crosscompile?
if(NOT DEFINED CMAKE_CROSSCOMPILING)
  set(CMAKE_CROSSCOMPILING "FALSE")
endif()

# Set path to fallback-tool for dependency-resolution.
if(NOT DEFINED CMAKE_OBJDUMP)
  set(CMAKE_OBJDUMP "/usr/bin/objdump")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("/Users/neharionaalice/Downloads/ns-3.48/cmake-cache/src/applications/examples/cmake_install.cmake")
endif()

if(CMAKE_INSTALL_COMPONENT STREQUAL "Unspecified" OR NOT CMAKE_INSTALL_COMPONENT)
  file(INSTALL DESTINATION "${CMAKE_INSTALL_PREFIX}/lib" TYPE SHARED_LIBRARY FILES "/Users/neharionaalice/Downloads/ns-3.48/build/lib/libns3.48-applications-default.dylib")
  if(EXISTS "$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/lib/libns3.48-applications-default.dylib" AND
     NOT IS_SYMLINK "$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/lib/libns3.48-applications-default.dylib")
    execute_process(COMMAND /usr/bin/install_name_tool
      -delete_rpath "/Users/neharionaalice/Downloads/ns-3.48/build/lib"
      -add_rpath "/usr/local/lib:$ORIGIN/:$ORIGIN/../lib:/usr/local/lib64:$ORIGIN/:$ORIGIN/../lib64"
      "$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/lib/libns3.48-applications-default.dylib")
    if(CMAKE_INSTALL_DO_STRIP)
      execute_process(COMMAND "/usr/bin/strip" -x "$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/lib/libns3.48-applications-default.dylib")
    endif()
  endif()
endif()

if(CMAKE_INSTALL_COMPONENT STREQUAL "Unspecified" OR NOT CMAKE_INSTALL_COMPONENT)
endif()

if(CMAKE_INSTALL_COMPONENT STREQUAL "Unspecified" OR NOT CMAKE_INSTALL_COMPONENT)
  file(INSTALL DESTINATION "${CMAKE_INSTALL_PREFIX}/include/ns3" TYPE FILE FILES
    "/Users/neharionaalice/Downloads/ns-3.48/src/applications/helper/bulk-send-helper.h"
    "/Users/neharionaalice/Downloads/ns-3.48/src/applications/helper/on-off-helper.h"
    "/Users/neharionaalice/Downloads/ns-3.48/src/applications/helper/packet-sink-helper.h"
    "/Users/neharionaalice/Downloads/ns-3.48/src/applications/helper/three-gpp-http-helper.h"
    "/Users/neharionaalice/Downloads/ns-3.48/src/applications/helper/udp-client-server-helper.h"
    "/Users/neharionaalice/Downloads/ns-3.48/src/applications/helper/udp-echo-helper.h"
    "/Users/neharionaalice/Downloads/ns-3.48/src/applications/model/application-packet-probe.h"
    "/Users/neharionaalice/Downloads/ns-3.48/src/applications/model/bulk-send-application.h"
    "/Users/neharionaalice/Downloads/ns-3.48/src/applications/model/onoff-application.h"
    "/Users/neharionaalice/Downloads/ns-3.48/src/applications/model/packet-loss-counter.h"
    "/Users/neharionaalice/Downloads/ns-3.48/src/applications/model/packet-sink.h"
    "/Users/neharionaalice/Downloads/ns-3.48/src/applications/model/rta-tig-mobile-gaming.h"
    "/Users/neharionaalice/Downloads/ns-3.48/src/applications/model/seq-ts-echo-header.h"
    "/Users/neharionaalice/Downloads/ns-3.48/src/applications/model/seq-ts-header.h"
    "/Users/neharionaalice/Downloads/ns-3.48/src/applications/model/seq-ts-size-header.h"
    "/Users/neharionaalice/Downloads/ns-3.48/src/applications/model/sink-application.h"
    "/Users/neharionaalice/Downloads/ns-3.48/src/applications/model/source-application.h"
    "/Users/neharionaalice/Downloads/ns-3.48/src/applications/model/tgax-video-traffic.h"
    "/Users/neharionaalice/Downloads/ns-3.48/src/applications/model/tgax-virtual-desktop.h"
    "/Users/neharionaalice/Downloads/ns-3.48/src/applications/model/tgax-voip-traffic.h"
    "/Users/neharionaalice/Downloads/ns-3.48/src/applications/model/three-gpp-http-client.h"
    "/Users/neharionaalice/Downloads/ns-3.48/src/applications/model/three-gpp-http-header.h"
    "/Users/neharionaalice/Downloads/ns-3.48/src/applications/model/three-gpp-http-server.h"
    "/Users/neharionaalice/Downloads/ns-3.48/src/applications/model/three-gpp-http-variables.h"
    "/Users/neharionaalice/Downloads/ns-3.48/src/applications/model/udp-client.h"
    "/Users/neharionaalice/Downloads/ns-3.48/src/applications/model/udp-echo-client.h"
    "/Users/neharionaalice/Downloads/ns-3.48/src/applications/model/udp-echo-server.h"
    "/Users/neharionaalice/Downloads/ns-3.48/src/applications/model/udp-server.h"
    "/Users/neharionaalice/Downloads/ns-3.48/src/applications/model/udp-trace-client.h"
    "/Users/neharionaalice/Downloads/ns-3.48/build/include/ns3/applications-module.h"
    "/Users/neharionaalice/Downloads/ns-3.48/build/include/ns3/applications-export.h"
    )
endif()

string(REPLACE ";" "\n" CMAKE_INSTALL_MANIFEST_CONTENT
       "${CMAKE_INSTALL_MANIFEST_FILES}")
if(CMAKE_INSTALL_LOCAL_ONLY)
  file(WRITE "/Users/neharionaalice/Downloads/ns-3.48/cmake-cache/src/applications/install_local_manifest.txt"
     "${CMAKE_INSTALL_MANIFEST_CONTENT}")
endif()
