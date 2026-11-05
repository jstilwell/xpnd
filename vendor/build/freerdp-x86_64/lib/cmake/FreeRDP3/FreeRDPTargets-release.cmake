#----------------------------------------------------------------
# Generated CMake target import file for configuration "Release".
#----------------------------------------------------------------

# Commands may need to know the format version.
set(CMAKE_IMPORT_FILE_VERSION 1)

# Import target "freerdp" for configuration "Release"
set_property(TARGET freerdp APPEND PROPERTY IMPORTED_CONFIGURATIONS RELEASE)
set_target_properties(freerdp PROPERTIES
  IMPORTED_LINK_INTERFACE_LANGUAGES_RELEASE "C"
  IMPORTED_LOCATION_RELEASE "${_IMPORT_PREFIX}/lib/libfreerdp3.a"
  )

list(APPEND _cmake_import_check_targets freerdp )
list(APPEND _cmake_import_check_files_for_freerdp "${_IMPORT_PREFIX}/lib/libfreerdp3.a" )

# Import target "remdesk-common" for configuration "Release"
set_property(TARGET remdesk-common APPEND PROPERTY IMPORTED_CONFIGURATIONS RELEASE)
set_target_properties(remdesk-common PROPERTIES
  IMPORTED_LINK_INTERFACE_LANGUAGES_RELEASE "C"
  IMPORTED_LOCATION_RELEASE "${_IMPORT_PREFIX}/lib/freerdp3/libremdesk-common.a"
  )

list(APPEND _cmake_import_check_targets remdesk-common )
list(APPEND _cmake_import_check_files_for_remdesk-common "${_IMPORT_PREFIX}/lib/freerdp3/libremdesk-common.a" )

# Import target "rdpsnd-common" for configuration "Release"
set_property(TARGET rdpsnd-common APPEND PROPERTY IMPORTED_CONFIGURATIONS RELEASE)
set_target_properties(rdpsnd-common PROPERTIES
  IMPORTED_LINK_INTERFACE_LANGUAGES_RELEASE "C"
  IMPORTED_LOCATION_RELEASE "${_IMPORT_PREFIX}/lib/freerdp3/librdpsnd-common.a"
  )

list(APPEND _cmake_import_check_targets rdpsnd-common )
list(APPEND _cmake_import_check_files_for_rdpsnd-common "${_IMPORT_PREFIX}/lib/freerdp3/librdpsnd-common.a" )

# Commands beyond this point should not need to know the version.
set(CMAKE_IMPORT_FILE_VERSION)
