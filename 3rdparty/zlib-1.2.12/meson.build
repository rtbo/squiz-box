
cc = meson.get_compiler('c')

zlib_conf_data = configuration_data()
zlib_conf_data.set('HAVE_UNISTD_H', cc.has_header('unistd.h'))
zlib_conf_data.set('HAVE_STDARG_H', cc.has_header('stdarg.h'))

zlib_conf = configure_file(
    input: 'zconf.h.in',
    output: 'zconf.h',
    configuration: zlib_conf_data,
)

zlib_src = files([
    'src/adler32.c',
    'src/compress.c',
    'src/crc32.c',
    'src/crc32.h',
    'src/deflate.c',
    'src/deflate.h',
    'src/gzclose.c',
    'src/gzguts.h',
    'src/gzlib.c',
    'src/gzread.c',
    'src/gzwrite.c',
    'src/infback.c',
    'src/inffast.c',
    'src/inffast.h',
    'src/inffixed.h',
    'src/inflate.c',
    'src/inflate.h',
    'src/inftrees.c',
    'src/inftrees.h',
    'src/trees.c',
    'src/trees.h',
    'src/uncompr.c',
    'src/zlib.h',
    'src/zutil.c',
    'src/zutil.h',
])

zlib_inc = include_directories('src')

zlib_lib = static_library('zlib', zlib_conf, zlib_src,
    install: false,
    include_directories: zlib_inc,
)

zlib_dep = declare_dependency(
    link_with: zlib_lib,
)
