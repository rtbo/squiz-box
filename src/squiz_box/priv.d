module squiz_box.priv;

package(squiz_box):

import squiz_box.core : ByteChunk, defaultChunkSize, EntryType, isByteRange;

import std.datetime.systime;
import std.exception;
import std.traits : isDynamicArray, isIntegral;

extern (C) void* gcAlloc(T)(void* opaque, T n, T m) nothrow if (isIntegral!T)
{
    import core.memory : GC;

    return GC.malloc(n * m);
}

extern (C) void gcFree(void* opaque, void* addr) nothrow
{
    import core.memory : GC;

    GC.free(addr);
}

/// A forward only data input iterator
/// This is used either as adapter to File reading
/// or as adapter to by-chunk data where arbitrary read length
/// ease the implementation of an algorithm
interface Cursor
{
    /// The name of the data source
    /// For FileCursor, this will be the filename,
    /// otherwise a description of the type of data.
    @property string name();

    /// Position in the stream (how many bytes read so far)
    @property ulong pos();

    /// Whether end-of-input was reached
    @property bool eoi();

    /// Fast-forward and discard dist bytes.
    /// Passing size_t.max will exhaust the input.
    void ffw(ulong dist);

    /// Reads a single byte
    ubyte get()
    in (!eoi);

    /// Similar to read!T, but returns the value.
    /// This form may be preferred for smaller values (e.g. a few bytes)
    T get(T)()
    {
        T val = void;
        read(&val);
        return val;
    }

    /// Read up to buffer.length bytes into buffer and return what was read.
    /// Returns a smaller slice only if EOI was reached.
    ubyte[] read(ubyte[] buffer);

    /// Read T.sizeof data and returns it as a T.
    /// Similar to get!T but the value is passed as pointer to be filled in.
    /// Prefer this form for greater values (e.g. dozens of bytes)
    void read(T)(T* val) if (!isDynamicArray!T)
    {
        import std.exception : enforce;

        auto ptr = cast(ubyte*) val;
        auto buf = ptr[0 .. T.sizeof];
        auto res = read(buf);
        enforce(res.length == T.sizeof, "Could not read enough bytes for " ~ T.stringof);
    }

    T[] read(T)(T[] buffer)
    {
        auto ptr = cast(ubyte)&buffer[0];
        auto arr = ptr[0 .. buffer.length * T.sizeof];
        auto res = read(arr);
        enforce(res.length % T.sizeof == 0, "Could not read aligned bytes for " ~ T.stringof);
        if (!res.length)
            return [];
        auto resptr = cast(T*)&res[0];
        return resptr[0 .. res.length / T.sizeof];
    }
}

/// A Cursor whose size is known and that can seek to arbitrary positions,
/// including backwards.
/// Implementers other than ubyte[] MUST have internal buffer.
interface SearchableCursor : Cursor
{
    /// Complete size of the data
    @property ulong size();

    /// Seek to a new position (relative to beginning)
    void seek(ulong pos);

    /// Read up to len bytes and return what was read.
    /// Returns an array smaller than len only if EOI was reached, or if internal buffer is too small.
    const(ubyte)[] readLength(size_t len);
}

/// Range based data input
final class ByteRangeCursor(BR) : Cursor if (isByteRange!BR)
{
    private BR _input;
    private ulong _pos;
    private ByteChunk _chunk;

    this(BR input)
    {
        _input = input;

        if (!_input.empty)
            _chunk = _input.front;
    }

    @property string name()
    {
        return "Byte Range";
    }

    @property ulong pos()
    {
        return _pos;
    }

    @property bool eoi()
    {
        return _chunk.length == 0;
    }

    void ffw(ulong dist)
    {
        import std.algorithm : min;

        while (dist > 0 && _chunk.length)
        {
            const len = cast(size_t) min(_chunk.length, dist);
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

    ubyte get()
    {
        const res = _chunk[0];
        _chunk = _chunk[1 .. $];
        if (_chunk.length == 0)
        {
            _input.popFront();
            if (!_input.empty)
                _chunk = _input.front;
        }
        return res;
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

final class ArrayCursor : SearchableCursor
{
    private ubyte[] _array;
    private size_t _pos;

    this(ubyte[] array)
    {
        _array = array;
    }

    @property string name()
    {
        return "Byte Array";
    }

    @property ulong pos()
    {
        return _pos;
    }

    @property bool eoi()
    {
        return _pos == _array.length;
    }

    @property ulong size()
    {
        return _array.length;
    }

    void seek(ulong pos)
    {
        import std.algorithm : min;

        _pos = cast(size_t) min(pos, _array.length);
    }

    void ffw(ulong dist)
    {
        seek(pos + dist);
    }

    ubyte get()
    {
        enforce(_pos < _array.length, "No more bytes");
        return _array[_pos++];
    }

    ubyte[] read(ubyte[] buffer)
    {
        import std.algorithm : min;

        const l = min(buffer.length, _array.length - _pos);
        buffer[0 .. l] = _array[_pos .. _pos + l];
        _pos += l;
        return buffer[0 .. l];
    }

    const(ubyte)[] readLength(size_t len)
    {
        import std.algorithm : min;

        const l = min(len, _array.length - _pos);
        const p = _pos;
        _pos += l;
        return _array[p .. p + l];
    }
}

/// The cursor MUST have exclusive access on the file
final class FileCursor : SearchableCursor
{
    import std.stdio : File;

    File _file;
    ulong _pos;
    ulong _start;
    ulong _end;
    ubyte[] _buffer;

    this(File file, size_t bufferSize = defaultChunkSize, ulong start = 0, ulong end = ulong.max)
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

    @property string name()
    {
        return _file.name;
    }

    @property ulong pos()
    {
        return _pos;
    }

    @property bool eoi()
    {
        return _pos == _end;
    }

    @property ulong size()
    {
        return _end - _start;
    }

    void seek(ulong pos)
    {
        _pos = pos;
        _file.seek(pos);
    }

    void ffw(ulong dist)
    {
        seek(pos + dist);
    }

    ubyte get()
    {
        // for efficiency we use getc
        import core.stdc.stdio : getc;

        assert(_file.tell == _pos);

        _pos++;
        enforce(_pos <= _end, "No more bytes");
        return cast(ubyte)getc(_file.getFP());
    }

    ubyte[] read(ubyte[] buffer)
    {
        import std.algorithm : min;

        assert(_file.tell == _pos);

        const len = cast(size_t) min(buffer.length, _end - _pos);
        auto result = _file.rawRead(buffer[0 .. len]);
        _pos += result.length;
        assert(_pos <= _end);
        return result;
    }

    const(ubyte)[] readLength(size_t len)
    {
        import std.algorithm : min;

        assert(_file.tell == _pos);
        assert(_buffer.length > 0, "FileDataAdapter constructed without buffer. Use read(buffer)");

        const l = min(len, _end - _pos, _buffer.length);
        auto res = _file.rawRead(_buffer[0 .. l]);
        _pos += res.length;
        assert(_pos <= _end);
        return res;
    }
}

/// ByteRange that takes its data from Cursor.
/// Optionally stopping before data is exhausted.
struct CursorByteRange
{
    private Cursor _input;
    private ulong _end;
    private ubyte[] _buffer;
    private ubyte[] _chunk;

    this(Cursor input, size_t chunkSize = 4096, ulong end = ulong.max)
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

        const len = cast(size_t) min(_buffer.length, _end - _input.pos);
        if (len == 0)
            _chunk = null;
        else
            _chunk = _input.read(_buffer[0 .. len]);
    }

    @property bool empty()
    {
        return (_input.eoi || _input.pos >= _end) && _chunk.length == 0;
    }

    @property ByteChunk front()
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
    ByteChunk inChunk;

    /// Buffer used to read from stream
    ubyte[] outBuffer;
    /// Slice of the buffer that is valid for read out
    ByteChunk outChunk;

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

    @property ByteChunk front()
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
                P.end(stream);
                ended = true;
                break;
            }
        }
    }
}

struct LittleEndian(size_t sz) if (sz == 2 || sz == 4 || sz == 8)
{
    static if (sz == 2)
    {
        alias T = ushort;
    }
    static if (sz == 4)
    {
        alias T = uint;
    }
    static if (sz == 8)
    {
        alias T = ulong;
    }

    ubyte[sz] data;

    this(T val) pure @safe @nogc nothrow
    {
        import std.bitmanip : nativeToLittleEndian;

        data = nativeToLittleEndian(val);
    }

    @property void val(T val) pure @safe @nogc nothrow
    {
        import std.bitmanip : nativeToLittleEndian;

        data = nativeToLittleEndian(val);
    }

    @property T val() const pure @safe @nogc nothrow
    {
        import std.bitmanip : littleEndianToNative;

        return littleEndianToNative!(T, sz)(data);
    }

    auto opAssign(T value)
    {
        val = value;
        return this;
    }

    bool opEquals(const T rhs) const
    {
        return val == rhs;
    }

    size_t toHash() const @nogc @safe pure nothrow
    {
        return val.hashOf();
    }

    int opCmp(const T rhs) const
    {
        const lhs = val;
        if (lhs < rhs)
            return -1;
        if (lhs > rhs)
            return 1;
        return 0;
    }
}

static assert((LittleEndian!2).sizeof == 2);
static assert((LittleEndian!4).sizeof == 4);
static assert((LittleEndian!8).sizeof == 8);
