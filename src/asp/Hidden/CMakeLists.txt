
# Hidden

add_executable(csv_filter csv_filter.cu)
target_link_libraries(csv_filter AspCore)
install(TARGETS csv_filter DESTINATION bin)

add_executable(s2p_fltr s2p_fltr.cu)
target_link_libraries(s2p_fltr AspCore)
install(TARGETS s2p_fltr DESTINATION bin)

add_executable(s2p_pprc s2p_pprc.cu)
target_link_libraries(s2p_pprc AspCore)
install(TARGETS s2p_pprc DESTINATION bin)
