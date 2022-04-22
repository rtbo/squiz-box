module squiz_box.priv;

package(squiz_box):

import squiz_box.core : isByteRange;

import std.traits : isIntegral;

extern(C) void* gcAlloc(T)(void* opaque, T n, T m)
if (isIntegral!T)
{
    import core.memory : GC;

    return GC.malloc(n*m);
}

extern(C) void gcFree(void* opaque, void* addr)
{
    import core.memory : GC;

    GC.free(addr);
}

/// A forward only data input iterator
/// This is used either as adapter to File reading
/// or as adapter to by-chunk data where arbitrary read length
/// ease the implementation of an algorithm
interface DataInput
{
    @property size_t pos();
    @property bool eoi();
    void ffw(size_t dist);
    ubyte[] read(ubyte[] buffer);
}

/// File based data input
/// Includes possibility to slice in the data
class FileDataInput : DataInput
{
    import std.stdio : File;

    File _file;
    size_t _pos;
    size_t _end;

    this(File file, size_t start = 0, size_t end = size_t.max)
    {
        _file = file;
        _file.seek(start);
        _end = (end == size_t.max ? _file.size : end) - start;
    }

    @property size_t pos()
    {
        return _pos;
    }

    @property bool eoi()
    {
        return _pos >= _end;
    }

    void ffw(size_t dist)
    {
        import std.algorithm : min;
        import std.stdio : SEEK_CUR;

        dist = min(dist, _end - _pos);
        _file.seek(dist, SEEK_CUR);
        _pos += dist;
    }

    ubyte[] read(ubyte[] buffer)
    {
        import std.algorithm : min;

        const len = min(buffer.length, _end - _pos);
        auto result = _file.rawRead(buffer[0 .. len]);
        _pos += result.length;
        return result;
    }
}

/// Range based data input
class ByteRangeDataInput(BR) : DataInput if (isByteRange!BR)
{
    private BR _input;
    private size_t _pos;
    private ubyte[] _chunk;

    this(BR input)
    {
        _input = input;

        if (!_input.empty)
            _chunk = _input.front;
    }

    @property size_t pos()
    {
        return _pos;
    }

    @property bool eoi()
    {
        return _chunk.length == 0;
    }

    void ffw(size_t dist)
    {
        import std.algorithm : min;

        while (dist > 0 && _chunk.length)
        {
            const len = min(_chunk.length, dist);
            _chunk = _chunk[len .. $];
            _pos += len;
            dist -= len;

            if (_chunk.length == 0)
            {
                _input.popFront();
                if (!_input.empty)
                    _chunk = _input.front;
            }
        }
    }

    ubyte[] read(ubyte[] buffer)
    {
        import std.algorithm : min;

        size_t filled;

        while (_chunk.length && filled != buffer.length)
        {
            const len = min(_chunk.length, buffer.length - filled);
            buffer[filled .. filled + len] = _chunk[0 .. len];

            _pos += len;

            filled += len;
            _chunk = _chunk[len .. $];

            if (_chunk.length == 0)
            {
                _input.popFront();
                if (!_input.empty)
                    _chunk = _input.front;
            }
        }
        return buffer[0 .. filled];
    }
}

/// ByteRange that takes its data from DataInput.
/// Optionally stopping before data is exhausted.
struct DataInputByteRange
{
    private DataInput _input;
    private size_t _end;
    private ubyte[] _buffer;
    private ubyte[] _chunk;

    this (DataInput input, size_t chunkSize = 4096, size_t end = size_t.max)
    {
        _input = input;
        _end = end;
        _buffer = new ubyte[chunkSize];
        if (!_input.eoi)
            prime();
    }

    private void prime()
    {
        import std.algorithm : min;

        const len = min(_buffer.length, _end - _input.pos);
        if (len == 0)
            _chunk = null;
        else
            _chunk = _input.read(_buffer[0 .. len]);
    }

    @property bool empty()
    {
        return (_input.eoi || _input.pos >= _end) && _chunk.length == 0;
    }

    @property ubyte[] front()
    {
        return _chunk;
    }

    void popFront()
    {
        if (!_input.eoi)
            prime();
        else
            _chunk = null;
    }
}
