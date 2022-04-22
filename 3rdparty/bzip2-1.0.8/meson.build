bz2_src = files([
    'src/blocksort.c',
    'src/bzlib_private.h',
    'src/bzlib.c',
    'src/bzlib.h',
    'src/compress.c',
    'src/crctable.c',
    'src/decompress.c',
    'src/huffman.c',
    'src/randtable.c',
])

bz2_inc = include_directories('src')

bz2_lib = static_library('bz2', bz2_src,
    install: false,
    include_directories: bz2_inc,
)

bz2_dep = declare_dependency(
    link_with: bz2_lib,
)
