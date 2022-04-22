module squiz_box.xz;

import squiz_box.c.lzma;
import squiz_box.core;
import squiz_box.priv;

import std.conv;
import std.exception;
import std.typecons;

auto compressXz(I)(I input, uint level = 6, size_t chunkSize = defaultChunkSize)
        if (isByteRange!I)
{
    CompressXzPolicy params;
    params.level = level;

    return CompressDecompressAlgo!(I, CompressXzPolicy)(input, chunkSize, params);
}

private struct CompressXzPolicy
{
    alias Stream = lzma_stream;

    uint level = 6;
    lzma_check check = lzma_check.CRC64;

    static Stream* initialize(CompressXzPolicy params)
    {
        auto alloc = new lzma_allocator;
        alloc.alloc = &(gcAlloc!size_t);
        alloc.free = &gcFree;

        auto stream = new lzma_stream;
        stream.allocator = alloc;

        const ret = lzma_easy_encoder(stream, params.level, params.check);
        enforce(ret == lzma_ret.OK, "Could not initialize LZMA encoder: " ~ ret.to!string);

        return stream;
    }

    static Flag!"streamEnded" process(Stream* stream, bool inputEmpty)
    {
        const action = inputEmpty ? lzma_action.FINISH : lzma_action.RUN;
        const res = lzma_code(stream, action);

        if (res == lzma_ret.STREAM_END)
            return Yes.streamEnded;

        enforce(res == lzma_ret.OK, "LZMA encoding failed with code: " ~ res.to!string);

        return No.streamEnded;
    }
}

auto decompressXz(I)(I input, size_t chunkSize = defaultChunkSize)
        if (isByteRange!I)
{
    DecompressXzPolicy params;

    return CompressDecompressAlgo!(I, DecompressXzPolicy)(input, chunkSize, params);
}

private struct DecompressXzPolicy
{
    alias Stream = lzma_stream;

    size_t memLimit = size_t.max;
    uint flags = 0;

    static Stream* initialize(DecompressXzPolicy params)
    {
        auto alloc = new lzma_allocator;
        alloc.alloc = &(gcAlloc!size_t);
        alloc.free = &gcFree;

        auto stream = new lzma_stream;
        stream.allocator = alloc;

        const ret = lzma_stream_decoder(stream, params.memLimit, params.flags);
        enforce(ret == lzma_ret.OK, "Could not initialize LZMA decoder: " ~ ret.to!string);

        return stream;
    }

    static Flag!"streamEnded" process(Stream* stream, bool inputEmpty)
    {
        const action = lzma_action.RUN;
        const res = lzma_code(stream, action);

        if (res == lzma_ret.STREAM_END)
            return Yes.streamEnded;

        enforce(res == lzma_ret.OK, "LZMA decoding failed with code: " ~ res.to!string);

        return No.streamEnded;
    }
}
