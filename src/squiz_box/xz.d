module squiz_box.xz;

import squiz_box.c.lzma;
import squiz_box.core;
import squiz_box.priv;

import std.exception;

auto compressXz(BR)(BR input, uint level=6, size_t chunkSize=4096)
if (isByteRange!BR)
{
    return CompressXz!BR(input, level, chunkSize);
}

private struct CompressXz(BR)
if (isByteRange!BR)
{
    import std.conv : to;

    private BR _input;
    private uint _level;
    private lzma_stream _stream;
    private lzma_allocator* _alloc;

    private ubyte[] _inChunk;

    private ubyte[] _outBuffer;
    private ubyte[] _outChunk;

    this (BR input, uint level, size_t chunkSize)
    {
        _input = input;
        _level = level;

        _outBuffer = new ubyte[chunkSize];

        _alloc = new lzma_allocator;
        _alloc.alloc = &(gcAlloc!size_t);
        _alloc.free = &gcFree;
        _stream.allocator = _alloc;

        const ret = lzma_easy_encoder(&_stream, level, lzma_check.CRC64);
        enforce(ret == lzma_ret.OK, "Could not initialize LZMA encoder: " ~ ret.to!string);

        prime();
    }

    private void prime()
    {

        while(_outChunk.length < _outBuffer.length)
        {
            import std.stdio;

            if (_inChunk.length == 0 && !_input.empty)
                _inChunk = _input.front;

            _stream.next_in = _inChunk.ptr;
            _stream.avail_in = _inChunk.length;

            _stream.next_out = _outBuffer.ptr + _outChunk.length;
            _stream.avail_out = _outBuffer.length - _outChunk.length;

            const action = _input.empty ? lzma_action.FINISH : lzma_action.RUN;
            const res = lzma_code(&_stream, action);

            const readIn = _inChunk.length - _stream.avail_in;
            _inChunk = _inChunk[readIn .. $];

            const outEnd = _outBuffer.length - _stream.avail_out;
            _outChunk = _outBuffer[0 .. outEnd];

            // popFront must be called at the end because it may invalidate
            // inChunk with some ranges.
            if (_inChunk.length == 0 && !_input.empty)
                _input.popFront();

            if (res == lzma_ret.STREAM_END)
                break;

            enforce(res == lzma_ret.OK, "LZMA encoding failed with code: " ~ res.to!string);
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
        prime();
    }
}
