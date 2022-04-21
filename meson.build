project('squiz-box', ['c', 'd'],
    version: '0.1.0',
)

subdir('3rdparty')

squiz_src = files([
    'src/squiz_box/c/lzma.d',
    'src/squiz_box/c/zlib.d',

    'src/squiz_box/core.d',
    'src/squiz_box/tar.d',
    'src/squiz_box/xz.d',
])

squiz_inc = include_directories('src')

squiz_lib = library('squiz-box', squiz_src,
    install: true,
    include_directories: squiz_inc,
)

squiz_deps = [xz_dep]

squiz_dep = declare_dependency(
    link_with: squiz_lib,
    include_directories: squiz_inc,
    dependencies: squiz_deps,
)

squiz_test_src = squiz_src + files([
    'test/archive.d',
    'test/filter.d',
    'test/main.d',
    'test/util.d',
])

squiz_test_exe = executable('squiz-test', squiz_test_src,
    d_unittest: true,
    install: false,
    dependencies: squiz_dep,
)

test('unit tests', squiz_test_exe)
