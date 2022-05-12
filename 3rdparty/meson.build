
# use zlib from phobos
#subdir('zlib-1.2.12')

bz2_dep = dependency('bzip2',
    version: '>=1.0.8',
    required: false,
)
xz_dep = dependency('liblzma',
    version: '>=5.2.5',
    required: false,
)

if not bz2_dep.found()
    subdir('bzip2-1.0.8')
endif

if not xz_dep.found()
    subdir('xz-5.2.5')
endif
