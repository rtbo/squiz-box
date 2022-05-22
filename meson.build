project('squiz-box', ['c', 'd'],
    version: '0.1.0',
    default_options: ['default_library=static'],
)


thread_dep = dependency('threads')

subdir('3rdparty')

squiz_src = files([
    'src/squiz_box/c/bzip2.d',
    'src/squiz_box/c/lzma.d',
    'src/squiz_box/c/zlib.d',
    'src/squiz_box/c/zstd.d',

    'src/squiz_box/box/package.d',
    'src/squiz_box/box/tar.d',
    'src/squiz_box/box/z7.d',
    'src/squiz_box/box/zip.d',
    'src/squiz_box/package.d',
    'src/squiz_box/priv.d',
    'src/squiz_box/squiz.d',
    'src/squiz_box/util.d',
])

squiz_inc = include_directories('src')

squiz_ver = []
if host_machine.system() == 'windows'
    squiz_ver = ['Windows10']
endif

squiz_deps = [bz2_dep, xz_dep, zstd_dep]

squiz_lib = library('squiz-box', squiz_src,
    install: true,
    include_directories: squiz_inc,
    dependencies: squiz_deps,
    d_module_versions: squiz_ver,
)

squiz_dep = declare_dependency(
    link_with: squiz_lib,
    include_directories: squiz_inc,
    dependencies: squiz_deps,
    d_module_versions: squiz_ver,
)

squiz_test_src = squiz_src + files([
    'test/archive.d',
    'test/compress.d',
    'test/main.d',
    'test/util.d',
])

squiz_test_exe = executable('squiz-test', squiz_test_src,
    d_unittest: true,
    install: false,
    include_directories: squiz_inc,
    dependencies: squiz_deps,
    d_module_versions: squiz_ver,
)

test('unit tests', squiz_test_exe)
