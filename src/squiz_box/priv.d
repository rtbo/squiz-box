module squiz_box.priv;

package(squiz_box):

import squiz_box.core : defaultChunkSize, EntryType, isByteRange;

import std.datetime.systime;
import std.traits : isDynamicArray, isIntegral;

extern (C) void* gcAlloc(T)(void* opaque, T n, T m) if (isIntegral!T)
{
    import core.memory : GC;

    return GC.malloc(n * m);
}

extern (C) void gcFree(void* opaque, void* addr)
{
    import core.memory : GC;

    GC.free(addr);
}

/// A forward only data input iterator
/// This is used either as adapter to File reading
/// or as adapter to by-chunk data where arbitrary read length
/// ease the implementation of an algorithm
interface Stream
{
    /// Position in the stream (how many bytes read so far)
    @property size_t pos();

    /// Whether end-of-input was reached
    @property bool eoi();

    /// Fast-forward and discard dist bytes.
    /// Passing size_t.max will exhaust the input.
    void ffw(size_t dist);

    /// Read up to buffer.length bytes into buffer and return what was read.
    /// Returns a smaller slice only if EOI was reached.
    ubyte[] read(ubyte[] buffer);

    /// Read T.sizeof data and returns it as a T.
    void read(T)(T* val)
    if (!isDynamicArray!T)
    {
        import std.exception : enforce;

        auto ptr = cast(ubyte*)val;
        auto buf = ptr[0 .. T.sizeof];
        auto res = read(buf);
        enforce(res.length == T.sizeof, "Could not read enough bytes for " ~ T.stringof);
    }
}

/// Common interface between File and ubyte[].
/// Similar to Stream, but allows to seek backwards.
/// Implementers other than ubyte[] MUST have internal buffer.
interface SearchableStream : Stream
{
    /// Complete size of the data
    @property size_t size();

    /// Seek to a position (relative to beginning)
    void seek(size_t pos);

    /// Read up to len bytes and return what was read.
    /// Returns an array smaller than len only if EOI was reached, or if internal buffer is too small.
    ubyte[] readLength(size_t len);
}


/// Range based data input
class ByteRangeStream(BR) : Stream if (isByteRange!BR)
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
                else
                    break;
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
                else
                    break;
            }
        }
        return buffer[0 .. filled];
    }
}

class ArrayStream : SearchableStream
{
    private ubyte[] _array;
    private size_t _pos;

    this(ubyte[] array)
    {
        _array = array;
    }

    @property size_t pos()
    {
        return _pos;
    }

    @property bool eoi()
    {
        return _pos == _array.length;
    }

    @property size_t size()
    {
        return _array.length;
    }

    void seek(size_t pos)
    {
        import std.algorithm : min;

        _pos = min(pos, _array.length);
    }

    void ffw(size_t dist)
    {
        seek(pos + dist);
    }

    ubyte[] readLength(size_t len)
    {
        import std.algorithm : min;

        const l = min(len, _array.length - _pos);
        const p = _pos;
        _pos += l;
        return _array[p .. p + l];
    }

    ubyte[] read(ubyte[] buffer)
    {
        import std.algorithm : min;

        const l = min(buffer.length, _array.length - _pos);
        buffer[0 .. l] = _array[_pos .. _pos + l];
        _pos += l;
        return buffer[0 .. l];
    }
}

class FileStream : SearchableStream
{
    import std.stdio : File;

    File _file;
    size_t _pos;
    size_t _start;
    size_t _end;
    ubyte[] _buffer;

    this(File file, size_t bufferSize = defaultChunkSize, size_t start = 0, size_t end = size_t.max)
    in (start <= end)
    {
        import std.algorithm : min;
        import std.exception : enforce;
        import std.stdio : LockType;

        enforce(file.isOpen, "File is not open");
        file.lock(LockType.read);
        _file = file;
        _start = start;

        const fs = file.size;
        enforce(fs < ulong.max, "File is not searchable");
        _end = min(fs, end);
        enforce(_start <= _end, "Bounds out of File range");

        const bufSize = min(bufferSize, _end - _start);
        if (bufSize > 0)
            _buffer = new ubyte[bufSize];
    }

    @property size_t pos()
    {
        return _pos;
    }

    @property bool eoi()
    {
        return _pos == _end;
    }

    @property size_t size()
    {
        return _end - _start;
    }

    void seek(size_t pos)
    {
        _pos = pos;
    }

    void ffw(size_t dist)
    {
        seek(pos + dist);
    }

    ubyte[] readLength(size_t len)
    {
        import std.algorithm : min;

        assert(_buffer.length > 0, "FileDataAdapter constructed without buffer. Use read(buffer)");

        const l = min(len, _end - _pos, _buffer.length);
        _file.seek(_pos);
        auto res = _file.rawRead(_buffer[0 .. l]);
        _pos += res.length;
        assert(_pos <= _end);
        return res;
    }

    ubyte[] read(ubyte[] buffer)
    {
        import std.algorithm : min;

        const len = min(buffer.length, _end - _pos);
        _file.seek(_pos);
        auto result = _file.rawRead(buffer[0 .. len]);
        _pos += result.length;
        assert(_pos <= _end);
        return result;
    }
}

/// ByteRange that takes its data from Stream.
/// Optionally stopping before data is exhausted.
struct StreamByteRange
{
    private Stream _input;
    private size_t _end;
    private ubyte[] _buffer;
    private ubyte[] _chunk;

    this(Stream input, size_t chunkSize = 4096, size_t end = size_t.max)
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

struct EntryData
{
    string path;
    string linkname;
    EntryType type;
    size_t size;
    size_t entrySize;
    SysTime timeLastModified;
    uint attributes;

    version (Posix)
    {
        int ownerId;
        int groupId;
    }
}

// Common algorithm for all compression/decompression functions.
// I is a byte input range
// P is a stream processor
// This common struct is made possible thanks to the great job of the zlib, bzip2 and lzma authors.
// Zlib authors have defined an extremly versatile stream interface that bzip2 and lzma authors have reused.
struct CompressDecompressAlgo(I, P)
{
    /// Byte input range (by chunks)
    I input;
    /// Processed stream (with common interface by zlib, bzip2 and lzma)
    P.Stream* stream;

    /// Byte chunk from the input, provided to the stream
    ubyte[] inChunk;

    /// Buffer used to read from stream
    ubyte[] outBuffer;
    /// Slice of the buffer that is valid for read out
    ubyte[] outChunk;

    /// Whether the end of stream was reported by the Policy
    bool ended;

    this(I input, P.Stream* stream, ubyte[] outBuffer)
    {
        this.input = input;
        this.stream = stream;
        this.outBuffer = outBuffer;
        prime();
    }

    @property bool empty()
    {
        return outChunk.length == 0;
    }

    @property ubyte[] front()
    {
        return outChunk;
    }

    void popFront()
    {
        outChunk = null;
        if (!ended)
            prime();
    }

    private void prime()
    {
        while (outChunk.length < outBuffer.length)
        {
            if (inChunk.length == 0 && !input.empty)
                inChunk = input.front;

            stream.next_in = inChunk.ptr;
            stream.avail_in = cast(typeof(stream.avail_in)) inChunk.length;

            stream.next_out = outBuffer.ptr + outChunk.length;
            stream.avail_out = cast(typeof(stream.avail_out))(outBuffer.length - outChunk.length);

            const streamEnded = P.process(stream, input.empty);

            const readIn = inChunk.length - stream.avail_in;
            inChunk = inChunk[readIn .. $];

            const outEnd = outBuffer.length - stream.avail_out;
            outChunk = outBuffer[0 .. outEnd];

            // popFront must be called at the end because it invalidates inChunk
            if (inChunk.length == 0 && !input.empty)
                input.popFront();

            if (streamEnded)
            {
                ended = true;
                break;
            }
        }
    }
}
