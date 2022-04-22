module squiz_box.gz;

import squiz_box.core;
import squiz_box.c.zlib;

import std.exception;

auto compressGz(BR)(BR input, uint level = 6, size_t chunkSize = 4096)
        if (isByteRange!BR)
{
    return CompressGz!BR(input, level, chunkSize);
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

private enum logGz = false;

private struct CompressGz(BR) if (isByteRange!BR)
{
    import std.conv : to;

    private BR _input;
    private uint _level;
    private z_stream* _stream;

    private ubyte[] _inChunk;

    private ubyte[] _outBuffer;
    private ubyte[] _outChunk;

    private bool _ended;

    this(BR input, uint level, size_t chunkSize)
    {
        _input = input;
        _level = level;

        // allocating on the heap to ensure the address never changes
        // which would creates stream error;
        _stream = new z_stream;

        _outBuffer = new ubyte[chunkSize];

        const ret = deflateInit2(
            _stream, level, Z_DEFLATED,
            16 + 15 /* +16 for gzip instead of zlib wrapper */ ,
            8,
            Z_DEFAULT_STRATEGY);

        enforce(
            ret == Z_OK,
            "Could not initialize Zlib encoder: " ~ zResultToString(ret)
        );

        prime();
    }

    private void prime()
    {
        static if (logGz)
        {
            import std.stdio;
        }

        while (_outChunk.length < _outBuffer.length)
        {
            if (_inChunk.length == 0 && !_input.empty)
                _inChunk = _input.front;

            _stream.next_in = _inChunk.ptr;
            _stream.avail_in = cast(uint) _inChunk.length;

            _stream.next_out = _outBuffer.ptr + _outChunk.length;
            _stream.avail_out = cast(uint)(_outBuffer.length - _outChunk.length);

            const flush = _input.empty ? Z_FINISH : Z_NO_FLUSH;

            static if (logGz)
            {
                zPrintStream(_stream, "before");
                writeln("Flush = ", zFlushToString(flush));
            }

            const res = deflate(_stream, flush);

            static if (logGz)
            {
                zPrintStream(_stream, "after");
                writeln("Deflate result = ", zResultToString(res));
                writeln();
            }

            const readIn = _inChunk.length - _stream.avail_in;
            _inChunk = _inChunk[readIn .. $];

            const outEnd = _outBuffer.length - _stream.avail_out;
            _outChunk = _outBuffer[0 .. outEnd];

            // popFront must be called at the end because it may invalidate
            // inChunk with some ranges.
            if (_inChunk.length == 0 && !_input.empty)
                _input.popFront();

            if (res == Z_STREAM_END)
            {
                _ended = true;
                break;
            }

            enforce(
                res == Z_OK,
                "Zlib deflate failed with code: " ~ zResultToString(res)
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
