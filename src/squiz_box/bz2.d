module squiz_box.bz2;

import squiz_box.core;
import squiz_box.c.bzip2;

import std.exception;

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

auto compressBz2(BR)(BR input, size_t chunkSize = 4096)
        if (isByteRange!BR)
{
    return CompressBz2!BR(input, chunkSize);
}

private struct CompressBz2(BR) if (isByteRange!BR)
{
    import std.conv : to;

    private BR _input;
    private bz_stream* _stream;

    private ubyte[] _inChunk;

    private ubyte[] _outBuffer;
    private ubyte[] _outChunk;

    private bool _ended;

    this(BR input, size_t chunkSize)
    {
        _input = input;

        // allocating on the heap to ensure the address never changes
        // which would creates stream error;
        _stream = new bz_stream;

        _outBuffer = new ubyte[chunkSize];

        const ret = BZ2_bzCompressInit(
            _stream, 9, 0, 0);

        enforce(
            ret == BZ_OK,
            "Could not initialize Bzip2 encoder: " ~ bzResultToString(ret)
        );

        prime();
    }

    private void prime()
    {
        while (_outChunk.length < _outBuffer.length)
        {
            if (_inChunk.length == 0 && !_input.empty)
                _inChunk = _input.front;

            _stream.next_in = _inChunk.ptr;
            _stream.avail_in = cast(uint) _inChunk.length;

            _stream.next_out = _outBuffer.ptr + _outChunk.length;
            _stream.avail_out = cast(uint)(_outBuffer.length - _outChunk.length);

            const action = _input.empty ? BZ_FINISH : BZ_RUN;

            const res = BZ2_bzCompress(_stream, action);

            const readIn = _inChunk.length - _stream.avail_in;
            _inChunk = _inChunk[readIn .. $];

            const outEnd = _outBuffer.length - _stream.avail_out;
            _outChunk = _outBuffer[0 .. outEnd];

            // popFront must be called at the end because it may invalidate
            // inChunk with some ranges.
            if (_inChunk.length == 0 && !_input.empty)
                _input.popFront();

            if (res == BZ_STREAM_END)
            {
                _ended = true;
                break;
            }

            enforce(
                action == BZ_RUN && res == BZ_RUN_OK || action == BZ_FINISH && res == BZ_FINISH_OK,
                "Bzip2 compress failed with code: " ~ bzResultToString(res)
            );
        }
    }

    @property bool empty()
    {
        return _outChunk.length == 0;
    }

    @property ubyte[] front()
    {
        return _outChunk;
    }

    void popFront()
    {
        _outChunk = null;
        if (!_ended)
            prime();
    }
}
