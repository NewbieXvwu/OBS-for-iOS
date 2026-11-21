get_property(modules GLOBAL PROPERTY OBS_IOS_STATIC_LIBRARIES)
get_property(module_data GLOBAL PROPERTY OBS_IOS_MODULE_DATA)
if(OBS_IOS_PRIVILEGED)
  set(OBS_PRIVILEGED_INFO [[
  <key>NSScreenCaptureUsageDescription</key>
  <string>OBS uses the display you select as a video source.</string>
  <key>UIBackgroundModes</key>
  <array>
    <string>processing</string>
    <string>screen-capture</string>
  </array>
  <key>BGTaskSchedulerPermittedIdentifiers</key>
  <array>
    <string>org.obsproject.studio.ios.rendering.*</string>
  </array>
  ]])
endif()

add_executable(OBSApp MACOSX_BUNDLE
  CoreBridge/OBSBridge.h
  CoreBridge/OBSBridge.mm
  CoreBridge/OBSFrontend.mm
  UI/OBSApp.swift
  UI/OBSLocale.swift
  UI/WorkspaceModel.swift
  UI/WorkspaceView.swift
  UI/WorkspacePanels.swift
  UI/OBSPropertiesView.swift
  UI/OBSSettingsView.swift
  UI/OBSWebSocketSettingsView.swift
  UI/OBSHotkeys.swift
  UI/OBSProjector.swift
)
if(ENABLE_WEBSOCKET)
  target_compile_definitions(OBSApp PRIVATE OBS_APP_WEBSOCKET=1)
endif()
if(OBS_IOS_PRIVILEGED)
  add_executable(OBSBroadcast MACOSX_BUNDLE BroadcastUploadExtension/SampleHandler.m)
  set_target_properties(OBSBroadcast PROPERTIES
    BUNDLE_EXTENSION appex
    MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/BroadcastUploadExtension/Info.plist"
    XCODE_PRODUCT_TYPE com.apple.product-type.app-extension
    XCODE_EXPLICIT_FILE_TYPE wrapper.app-extension
    XCODE_ATTRIBUTE_APPLICATION_EXTENSION_API_ONLY YES
    XCODE_ATTRIBUTE_CLANG_ENABLE_OBJC_ARC YES
    XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER org.obsproject.studio.ios.broadcast
    XCODE_ATTRIBUTE_SKIP_INSTALL YES
    XCODE_ATTRIBUTE_TARGETED_DEVICE_FAMILY "1,2"
  )
  target_link_libraries(OBSBroadcast PRIVATE "-framework ReplayKit" "-framework CoreMedia"
    "-framework CoreVideo" "-framework Foundation")
  target_sources(OBSApp PRIVATE HostPrivileged/HostPrivileged.m HostPrivileged/ReplayKit.m)
  if(NOT CMAKE_OSX_SYSROOT MATCHES "[iI][pP]hone[sS]imulator")
    target_sources(OBSApp PRIVATE HostPrivileged/ScreenCapture.m)
    target_link_libraries(OBSApp PRIVATE "-weak_framework ScreenCaptureKit")
  endif()
  set_target_properties(OBSApp PROPERTIES
    XCODE_EMBED_APP_EXTENSIONS OBSBroadcast
    XCODE_ATTRIBUTE_SWIFT_ACTIVE_COMPILATION_CONDITIONS OBS_APP_PRIVILEGED
  )
  target_compile_definitions(OBSApp PRIVATE OBS_APP_PRIVILEGED=1)
  target_link_options(OBSApp PRIVATE "LINKER:-export_dynamic")
  target_link_libraries(OBSApp PRIVATE "-framework BackgroundTasks" "-framework Security" "-framework ReplayKit")
endif()
target_link_libraries(OBSApp PRIVATE OBS::libobs OBS::libobs-metal OBS::frontend-api ${modules}
  "-framework UIKit" "-framework SwiftUI" "-framework Metal" "-framework QuartzCore")
set_target_properties(OBSApp PROPERTIES
  OUTPUT_NAME OBS
  MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/Info.plist"
  XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER org.obsproject.studio.ios
  XCODE_ATTRIBUTE_SWIFT_VERSION 5.0
  OBJCXX_STANDARD 17
  XCODE_ATTRIBUTE_CLANG_ENABLE_OBJC_ARC YES
  XCODE_ATTRIBUTE_SWIFT_OBJC_BRIDGING_HEADER "${CMAKE_CURRENT_SOURCE_DIR}/CoreBridge/OBSBridge.h"
  XCODE_ATTRIBUTE_TARGETED_DEVICE_FAMILY "1,2"
)

set(resources "${CMAKE_CURRENT_BINARY_DIR}/OBSData")
file(COPY "${CMAKE_SOURCE_DIR}/libobs/data/" DESTINATION "${resources}/libobs")
file(COPY "${CMAKE_SOURCE_DIR}/frontend/data/locale/" DESTINATION "${resources}/locale")
file(COPY_FILE "${OBS_IOS_CA_BUNDLE}" "${resources}/certs.pem" ONLY_IF_DIFFERENT)
foreach(entry IN LISTS module_data)
  string(REPLACE "|" ";" fields "${entry}")
  list(GET fields 0 module)
  list(GET fields 1 data_dir)
  if(IS_DIRECTORY "${data_dir}")
    file(COPY "${data_dir}/" DESTINATION "${resources}/obs-plugins/${module}")
  endif()
endforeach()
target_sources(OBSApp PRIVATE "${resources}")
set_source_files_properties("${resources}" PROPERTIES MACOSX_PACKAGE_LOCATION Resources)
