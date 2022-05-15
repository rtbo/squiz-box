
# use zlib from phobos
#subdir('zlib-1.2.12')

bz2_dep = dependency('bzip2',
    version: '>=1.0.8',
    method: 'pkg-config',
    required: false,
)
if not bz2_dep.found()
    message('Will build bzip2 from source')
    subdir('bzip2-1.0.8')
endif

xz_dep = dependency('liblzma',
    version: '>=5.2.5',
    method: 'pkg-config',
    required: false,
)
if not xz_dep.found()
    message('Will build liblzma from source')
    subdir('xz-5.2.5')
endif

zstd_dep = dependency('libzstd',
    version: '>=1.5.2',
    method: 'pkg-config',
    required: false,
)
if not zstd_dep.found()
    message('Will build libzstd from source')
    subdir('zstd-1.5.2')
endif
