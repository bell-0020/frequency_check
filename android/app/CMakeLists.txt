cmake_minimum_required(VERSION 3.10.2)

add_library(analyzer SHARED
    ../../src/analyzer.c
    ../../src/kissfft/kiss_fft.c
)

target_link_libraries(analyzer m) 