project('squiz-box', ['c', 'd'],
    version: '0.1.0',
    default_options: ['default_library=static'],
)

thread_dep = dependency('threads')

subdir('3rdparty')

squiz_src = files([
    'src/squiz_box/c/zlib.d',

    'src/squiz_box/box/package.d',
    'src/squiz_box/box/tar.d',
    'src/squiz_box/box/zip.d',
    'src/squiz_box/box/seven_z/error.d',
    'src/squiz_box/box/seven_z/header.d',
    'src/squiz_box/box/seven_z/package.d',
    'src/squiz_box/box/seven_z/read.d',
    'src/squiz_box/box/seven_z/utils.d',

    'src/squiz_box/package.d',
    'src/squiz_box/priv.d',
    'src/squiz_box/squiz.d',
    'src/squiz_box/util.d',
])

squiz_inc = include_directories('src')

squiz_ver = []
squiz_deps = []

if get_option('enable_bzip2') and not get_option('minimal')
    squiz_src += files('src/squiz_box/c/bzip2.d')
    squiz_ver += 'HaveSquizBzip2'
    squiz_deps += bz2_dep
endif
if get_option('enable_lzma') and not get_option('minimal')
    squiz_src += files('src/squiz_box/c/lzma.d')
    squiz_ver += 'HaveSquizLzma'
    squiz_deps += xz_dep
endif
if get_option('enable_zstd') and not get_option('minimal')
    squiz_src += files('src/squiz_box/c/zstd.d')
    squiz_ver += 'HaveSquizZstandard'
    squiz_deps += zstd_dep
endif

if host_machine.system() == 'windows'
    squiz_ver += ['Windows10']
endif

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

if get_option('enable_test')
    squiz_test_src = squiz_src + files([
        'test/archive.d',
        'test/compress.d',
        'test/main.d',
        'test/tar.d',
        'test/util.d',
    ])

    stupid_gen_exe = executable('stupid_gen', 'tools/stupid_gen.d',
        d_import_dirs: include_directories('tools'),
    )
    squiz_stupid = custom_target('squiz-stupid',
        capture: true,
        output: 'stupid.d',
        input: squiz_test_src,
        command: [
            stupid_gen_exe, '@INPUT@',
        ],
    )

    squiz_test_exe = executable('squiz-test', squiz_stupid, squiz_test_src,
        d_unittest: true,
        install: false,
        include_directories: squiz_inc,
        dependencies: squiz_deps,
        d_module_versions: squiz_ver,
    )

    test('unit tests', squiz_test_exe,
        timeout: 120,
    )
endif