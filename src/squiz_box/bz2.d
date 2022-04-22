module squiz_box.bz2;

import squiz_box.c.bzip2;
import squiz_box.core;
import squiz_box.priv;

import std.exception;
import std.typecons;

enum BZ_RUN = 0;
enum BZ_FLUSH = 1;
enum BZ_FINISH = 2;

private string bzActionToString(int action)
{
    switch (action)
    {
    case BZ_RUN:
        return "RUN";
    case BZ_FLUSH:
        return "FLUSH";
    case BZ_FINISH:
        return "FINISH";
    default:
        return "(Unknown result)";
    }
}

private string bzResultToString(int res)
{
    switch (res)
    {
    case BZ_OK:
        return "OK";
    case BZ_RUN_OK:
        return "RUN_OK";
    case BZ_FLUSH_OK:
        return "FLUSH_OK";
    case BZ_FINISH_OK:
        return "FINISH_OK";
    case BZ_STREAM_END:
        return "STREAM_END";
    case BZ_SEQUENCE_ERROR:
        return "SEQUENCE_ERROR";
    case BZ_PARAM_ERROR:
        return "PARAM_ERROR";
    case BZ_MEM_ERROR:
        return "MEM_ERROR";
    case BZ_DATA_ERROR:
        return "DATA_ERROR";
    case BZ_DATA_ERROR_MAGIC:
        return "DATA_ERROR_MAGIC";
    case BZ_IO_ERROR:
        return "IO_ERROR";
    case BZ_UNEXPECTED_EOF:
        return "UNEXPECTED_EOF";
    case BZ_OUTBUFF_FULL:
        return "OUTBUFF_FULL";
    case BZ_CONFIG_ERROR:
        return "CONFIG_ERROR";
    default:
        return "(Unknown result)";
    }
}

auto compressBz2(I)(I input, size_t chunkSize = defaultChunkSize) if (isByteRange!I)
{
    CompressBz2Policy params;
    return CompressDecompressAlgo!(I, CompressBz2Policy)(input, chunkSize, params);
}

private struct CompressBz2Policy
{
    alias Stream = bz_stream;

    int blockSize100k = 9;
    int verbosity = 0;
    int workFactor = 0;

    static bz_stream* initialize(CompressBz2Policy params)
    {
        auto stream = new bz_stream;
        stream.bzalloc = &(gcAlloc!int);
        stream.bzfree = &gcFree;

        const ret = BZ2_bzCompressInit(
            stream, params.blockSize100k, params.verbosity, params.workFactor);

        enforce(
            ret == BZ_OK,
            "Could not initialize Bzip2 encoder: " ~ bzResultToString(ret)
        );
        return stream;
    }

    static Flag!"streamEnded" process(bz_stream* stream, bool inputEmpty)
    {
        const action = inputEmpty ? BZ_FINISH : BZ_RUN;
        const res = BZ2_bzCompress(stream, action);

        if (res == BZ_STREAM_END)
            return Yes.streamEnded;

        enforce(
            (action == BZ_RUN && res == BZ_RUN_OK) ||
                (action == BZ_FINISH && res == BZ_FINISH_OK),
                "Bzip2 compress failed with code: " ~ bzResultToString(res)
        );

        return No.streamEnded;
    }
}
