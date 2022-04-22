module squiz_box.c.bzip2;

import core.stdc.stdio : FILE;

enum BZ_RUN = 0;
enum BZ_FLUSH = 1;
enum BZ_FINISH = 2;

enum BZ_OK = 0;
enum BZ_RUN_OK = 1;
enum BZ_FLUSH_OK = 2;
enum BZ_FINISH_OK = 3;
enum BZ_STREAM_END = 4;
enum BZ_SEQUENCE_ERROR = (-1);
enum BZ_PARAM_ERROR = (-2);
enum BZ_MEM_ERROR = (-3);
enum BZ_DATA_ERROR = (-4);
enum BZ_DATA_ERROR_MAGIC = (-5);
enum BZ_IO_ERROR = (-6);
enum BZ_UNEXPECTED_EOF = (-7);
enum BZ_OUTBUFF_FULL = (-8);
enum BZ_CONFIG_ERROR = (-9);

struct bz_stream
{
    ubyte* next_in;
    uint avail_in;
    uint total_in_lo32;
    uint total_in_hi32;

    ubyte* next_out;
    uint avail_out;
    uint total_out_lo32;
    uint total_out_hi32;

    void* state;

    void* function(void*, int, int) bzalloc;
    void function(void*, void*) bzfree;

    void* opaque;
}

/*-- Core (low-level) library functions --*/

extern (C) int BZ2_bzCompressInit(
    bz_stream* strm,
    int blockSize100k,
    int verbosity,
    int workFactor
);

extern (C) int BZ2_bzCompress(
    bz_stream* strm,
    int action
);

extern (C) int BZ2_bzCompressEnd(
    bz_stream* strm
);

extern (C) int BZ2_bzDecompressInit(
    bz_stream* strm,
    int verbosity,
    int small
);

extern (C) int BZ2_bzDecompress(
    bz_stream* strm
);

extern (C) int BZ2_bzDecompressEnd(
    bz_stream* strm
);

/*-- High(er) level library functions --*/

enum BZ_MAX_UNUSED = 5000;

alias BZFILE = void;

extern (C) BZFILE* BZ2_bzReadOpen(
    int* bzerror,
    FILE* f,
    int verbosity,
    int small,
    void* unused,
    int nUnused
);

extern (C) void BZ2_bzReadClose(
    int* bzerror,
    BZFILE* b
);

extern (C) void BZ2_bzReadGetUnused(
    int* bzerror,
    BZFILE* b,
    void** unused,
    int* nUnused
);

extern (C) int BZ2_bzRead(
    int* bzerror,
    BZFILE* b,
    void* buf,
    int len
);

extern (C) BZFILE* BZ2_bzWriteOpen(
    int* bzerror,
    FILE* f,
    int blockSize100k,
    int verbosity,
    int workFactor
);

extern (C) void BZ2_bzWrite(
    int* bzerror,
    BZFILE* b,
    void* buf,
    int len
);

extern (C) void BZ2_bzWriteClose(
    int* bzerror,
    BZFILE* b,
    int abandon,
    uint* nbytes_in,
    uint* nbytes_out
);

extern (C) void BZ2_bzWriteClose64(
    int* bzerror,
    BZFILE* b,
    int abandon,
    uint* nbytes_in_lo32,
    uint* nbytes_in_hi32,
    uint* nbytes_out_lo32,
    uint* nbytes_out_hi32
);

/*-- Utility functions --*/

extern (C) int BZ2_bzBuffToBuffCompress(
    char* dest,
    uint* destLen,
    char* source,
    uint sourceLen,
    int blockSize100k,
    int verbosity,
    int workFactor
);

extern (C) int BZ2_bzBuffToBuffDecompress(
    char* dest,
    uint* destLen,
    char* source,
    uint sourceLen,
    int small,
    int verbosity
);

/*--
   Code contributed by Yoshioka Tsuneo (tsuneo@rr.iij4u.or.jp)
   to support better zlib compatibility.
   This code is not _officially_ part of libbzip2 (yet);
   I haven't tested it, documented it, or considered the
   threading-safeness of it.
   If this code breaks, please contact both Yoshioka and me.
--*/

extern (C) const(char)* BZ2_bzlibVersion();

extern (C) BZFILE* BZ2_bzopen(
    const(char)* path,
    const(char)* mode
);

extern (C) BZFILE* BZ2_bzdopen(
    int fd,
    const(char)* mode
);

extern (C) int BZ2_bzread(
    BZFILE* b,
    void* buf,
    int len
);

extern (C) int BZ2_bzwrite(
    BZFILE* b,
    void* buf,
    int len
);

extern (C) int BZ2_bzflush(
    BZFILE* b
);

extern (C) void BZ2_bzclose(
    BZFILE* b
);

extern (C) const(char)* BZ2_bzerror(
    BZFILE* b,
    int* errnum
);
