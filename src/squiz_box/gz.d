module squiz_box.gz;

import squiz_box.c.zlib;
import squiz_box.core;
import squiz_box.priv;

import std.exception;
import std.typecons;

auto compressGz(I)(I input, uint level = 6, size_t chunkSize = defaultChunkSize)
        if (isByteRange!I)
{
    CompressGzPolicy params;
    params.level = level;
    return CompressDecompressAlgo!(I, CompressGzPolicy)(input, chunkSize, params);
}

private struct CompressGzPolicy
{
    alias Stream = z_stream;

    int level = 6;
    int windowBits = 15;
    int memLevel = 8;
    int strategy = Z_DEFAULT_STRATEGY;

    static Stream* initialize(CompressGzPolicy params)
    {
        auto stream = new z_stream;
        stream.zalloc = &(gcAlloc!uint);
        stream.zfree = &gcFree;

        const ret = deflateInit2(
            stream, params.level, Z_DEFLATED,
            16 + params.windowBits /* +16 for gzip instead of zlib wrapper */ ,
            params.memLevel,
            params.strategy);

        enforce(
            ret == Z_OK,
            "Could not initialize Zlib encoder: " ~ zResultToString(ret)
        );


        return stream;
    }

    static Flag!"streamEnded" process(Stream* stream, bool inputEmpty)
    {
        const flush = inputEmpty ? Z_FINISH : Z_NO_FLUSH;
        const res = deflate(stream, flush);
        if (res == Z_STREAM_END)
            return Yes.streamEnded;
        enforce(
            res == Z_OK,
            "Zlib deflate failed with code: " ~ zResultToString(res)
        );
        return No.streamEnded;
    }
}

auto decompressGz(I)(I input, size_t chunkSize = defaultChunkSize)
if (isByteRange!I)
{
    DecompressGzPolicy params;
    return CompressDecompressAlgo!(I, DecompressGzPolicy)(input, chunkSize, params);
}

private struct DecompressGzPolicy
{
    alias Stream = z_stream;

    int windowBits = 15;

    static Stream* initialize(DecompressGzPolicy params)
    {
        auto stream = new z_stream;
        stream.zalloc = &(gcAlloc!uint);
        stream.zfree = &gcFree;

        const ret = inflateInit2(
            stream, 16 + params.windowBits /* +16 for gzip instead of zlib wrapper */ ,
        );

        enforce(
            ret == Z_OK,
            "Could not initialize Zlib inflate stream: " ~ zResultToString(ret)
        );

        return stream;
    }

    static Flag!"streamEnded" process(Stream* stream, bool inputEmpty)
    {
        const flush = Z_NO_FLUSH;
        const res = inflate(stream, flush);
        if (res == Z_STREAM_END)
            return Yes.streamEnded;
        enforce(
            res == Z_OK,
            "Zlib inflate failed with code: " ~ zResultToString(res)
        );
        return No.streamEnded;
    }
}

private string zResultToString(int res)
{
    switch (res)
    {
    case Z_OK:
        return "OK";
    case Z_STREAM_END:
        return "STREAM_END";
    case Z_NEED_DICT:
        return "NEED_DICT";
    case Z_ERRNO:
        return "ERRNO";
    case Z_STREAM_ERROR:
        return "STREAM_ERROR";
    case Z_DATA_ERROR:
        return "DATA_ERROR";
    case Z_MEM_ERROR:
        return "MEM_ERROR";
    case Z_BUF_ERROR:
        return "BUF_ERROR";
    case Z_VERSION_ERROR:
        return "VERSION_ERROR";
    default:
        return "(Unknown result)";
    }
}

private string zFlushToString(int flush)
{
    switch (flush)
    {
    case Z_NO_FLUSH:
        return "NO_FLUSH";
    case Z_PARTIAL_FLUSH:
        return "PARTIAL_FLUSH";
    case Z_SYNC_FLUSH:
        return "SYNC_FLUSH";
    case Z_FULL_FLUSH:
        return "FULL_FLUSH";
    case Z_FINISH:
        return "FINISH";
    case Z_BLOCK:
        return "BLOCK";
    case Z_TREES:
        return "TREES";
    default:
        return "(Unknown flush)";
    }
}

private void zPrintStream(z_stream* strm, string label)
{
    import std.stdio;
    import std.string : fromStringz;

    if (label)
        writefln("Stream %s:", label);
    else
        writefln("Stream:");

    if (!strm)
    {
        writeln("    null");
        return;
    }
    else
    {
        writeln("    address = %x", cast(void*) strm);
    }
    writeln("    next_in = ", strm.next_in);
    writeln("    avail_in = ", strm.avail_in);
    writeln("    total_in = ", strm.total_in);
    writeln("    next_out = ", strm.next_out);
    writeln("    avail_out = ", strm.avail_out);
    writeln("    total_out = ", strm.total_out);
    if (strm.msg)
        writeln("    msg = ", fromStringz(strm.msg));
}
