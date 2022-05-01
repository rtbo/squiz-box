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
    auto alloc = new lzma_allocator;
    alloc.alloc = &(gcAlloc!size_t);
    alloc.free = &gcFree;

    auto stream = new lzma_stream;
    stream.allocator = alloc;

    const check = lzma_check.CRC64;

    const ret = lzma_easy_encoder(stream, level, check);
    enforce(ret == lzma_ret.OK, "Could not initialize LZMA encoder: " ~ ret.to!string);

    auto buffer = new ubyte[chunkSize];

    return CompressDecompressAlgo!(I, LzmaCode)(input, stream, buffer);
}

private struct LzmaCode
{
    alias Stream = lzma_stream;

    static Flag!"streamEnded" process(Stream* stream, bool inputEmpty)
    {
        const action = inputEmpty ? lzma_action.FINISH : lzma_action.RUN;
        const res = lzma_code(stream, action);

        if (res == lzma_ret.STREAM_END)
            return Yes.streamEnded;

        enforce(res == lzma_ret.OK, "LZMA encoding failed with code: " ~ res.to!string);

        return No.streamEnded;
    }

    static void end(Stream* stream)
    {
        lzma_end(stream);
    }
}

auto decompressXz(I)(I input, size_t chunkSize = defaultChunkSize)
        if (isByteRange!I)
{
    auto alloc = new lzma_allocator;
    alloc.alloc = &(gcAlloc!size_t);
    alloc.free = &gcFree;

    auto stream = new lzma_stream;
    stream.allocator = alloc;

    const memLimit = size_t.max;
    const flags = 0;

    const ret = lzma_stream_decoder(stream, memLimit, flags);
    enforce(ret == lzma_ret.OK, "Could not initialize LZMA decoder: " ~ ret.to!string);

    auto buffer = new ubyte[chunkSize];

    return CompressDecompressAlgo!(I, LzmaCode)(input, stream, buffer);
}
