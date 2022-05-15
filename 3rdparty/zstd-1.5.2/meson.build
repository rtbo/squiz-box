#meson script adapted from upstream script for squiz-box

zstd_inc = include_directories([
    'lib',
    'lib/common',
    'lib/compress',
    'lib/decompress',
    'lib/dictBuilder',
])

zstd_src = files([
    'lib/common/entropy_common.c',
    'lib/common/fse_decompress.c',
    'lib/common/threading.c',
    'lib/common/pool.c',
    'lib/common/zstd_common.c',
    'lib/common/error_private.c',
    'lib/common/xxhash.c',
    'lib/compress/hist.c',
    'lib/compress/fse_compress.c',
    'lib/compress/huf_compress.c',
    'lib/compress/zstd_compress.c',
    'lib/compress/zstd_compress_literals.c',
    'lib/compress/zstd_compress_sequences.c',
    'lib/compress/zstd_compress_superblock.c',
    'lib/compress/zstdmt_compress.c',
    'lib/compress/zstd_fast.c',
    'lib/compress/zstd_double_fast.c',
    'lib/compress/zstd_lazy.c',
    'lib/compress/zstd_opt.c',
    'lib/compress/zstd_ldm.c',
    'lib/decompress/huf_decompress.c',
    'lib/decompress/zstd_decompress.c',
    'lib/decompress/zstd_decompress_block.c',
    'lib/decompress/zstd_ddict.c',
    'lib/dictBuilder/cover.c',
    'lib/dictBuilder/fastcover.c',
    'lib/dictBuilder/divsufsort.c',
    'lib/dictBuilder/zdict.c',
])

cc = meson.get_compiler('c')
cc_id = cc.get_id()

zstd_defs = []

# really we need anything that defines __GNUC__ as that is what ZSTD_ASM_SUPPORTED is gated on
# but these are the two compilers that are supported in tree and actually handle this correctly
# Otherwise, explicitly disable assmebly.
if cc_id == 'gcc' or cc_id == 'clang'
    zstd_src += files('lib/decompress/huf_decompress_amd64.S')
else
    zstd_defs += '-DZSTD_DISABLE_ASM'
endif

zstd_defs += '-DZSTD_MULTITHREAD'
zstd_deps = [ thread_dep ]

zstd_defs += ['-DZSTD_HEAPMODE=0', '-D_CRT_SECURE_NO_WARNINGS']

zstd_lib = static_library('zstd', zstd_src,
    include_directories: zstd_inc,
    c_args: zstd_defs,
    install: false,
)

zstd_dep = declare_dependency(
    link_with: zstd_lib,
    include_directories: zstd_inc,
)
