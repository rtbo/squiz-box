module squiz_box.priv;

package(squiz_box):

import squiz_box.squiz : ByteChunk, defaultChunkSize, isByteRange;

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
    @property string source();

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

    /// Get a value of type T.
    /// Is a convenience over readValue.
    T getValue(T)()
    {
        T val = void;
        readValue(&val);
        return val;
    }

    /// Read up to buffer.length bytes into buffer and return what was read.
    /// Returns a smaller slice only if EOI was reached.
    ubyte[] read(ubyte[] buffer);

    /// Read T.sizeof data and returns it as a T.
    /// Similar to getValue!T but the value is passed as pointer to be filled in.
    /// Prefer this form for greater values (e.g. dozens of bytes)
    void readValue(T)(scope T* val) if (!isDynamicArray!T)
    {
        import std.exception : enforce;

        auto ptr = cast(ubyte*) val;
        auto buf = ptr[0 .. T.sizeof];
        auto res = read(buf);
        enforce(res.length == T.sizeof, "Could not read enough bytes for " ~ T.stringof);
    }

    T[] read(T)(T[] buffer)
    {
        auto ptr = cast(ubyte*)&buffer[0];
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
interface SearchableCursor : Cursor
{
    /// Complete size of the data
    @property ulong size();

    /// Seek to a new position (relative to beginning)
    void seek(ulong pos);
}

/// Range based data input
final class ByteRangeCursor(BR) : Cursor if (isByteRange!BR)
{
    private BR _input;
    private string _source;
    private ulong _pos;
    private ByteChunk _chunk;

    this(BR input, string source = "Byte Range")
    {
        _input = input;
        _source = source;

        if (!_input.empty)
            _chunk = _input.front;
    }

    @property string source()
    {
        return _source;
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
    private const(ubyte)[] _array;
    private size_t _pos;
    private string _source;

    this(const(ubyte)[] array, string source = "Byte Array")
    {
        _array = array;
        _source = source;
    }

    @property string source()
    {
        return _source;
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

    /// Read up to len bytes from the inner array and return what was read.
    /// Returns an array smaller than len only if EOI was reached.
    const(ubyte)[] readInner(size_t len)
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

    @property string source()
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
        return cast(ubyte) getc(_file.getFP());
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
}

auto cursorByteRange(C)(C cursor, ulong len = ulong.max, size_t chunkSize = defaultChunkSize)
        if (is(C : Cursor))
{
    import std.algorithm : min;
    import std.range : only;

    static if (is(C : ArrayCursor))
    {
        const l = cast(size_t) min(len, cursor._array.length - cursor._pos);
        return only(cursor._array[cursor._pos .. cursor._pos + l]);
    }
    else
    {
        return CursorByteRange!C(cursor, len, cast(size_t) min(len, chunkSize));
    }
}

/// ByteRange that takes its data from Cursor.
/// Optionally stopping before data is exhausted.
struct CursorByteRange(C) if (is(C : Cursor))
{
    private C _input;
    private ulong _len;
    private ubyte[] _buffer;
    private ubyte[] _chunk;

    this(C input, ulong len = ulong.max, size_t chunkSize = 4096)
    {
        _input = input;
        _len = len;
        _buffer = new ubyte[chunkSize];
        if (!_input.eoi)
            prime();
    }

    private void prime()
    {
        import std.algorithm : min;

        const len = cast(size_t) min(_buffer.length, _len);
        if (len == 0)
            _chunk = null;
        else
            _chunk = _input.read(_buffer[0 .. len]);
        _len -= len;
    }

    @property bool empty()
    {
        return (_input.eoi || _len == 0) && _chunk.length == 0;
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

interface WriteCursor
{
    void put(ubyte val);

    void write(scope const(ubyte)[] arr);
}

interface SearchableWriteCursor : WriteCursor
{
    ulong tell();
    void seek(ulong pos);
}

class ArrayWriteCursor : SearchableWriteCursor
{
    ubyte[] _data;
    size_t _writePos;

    this(ubyte[] data)
    {
        _data = data;
        _writePos = cast(size_t)data.length;
    }

    this(size_t cap=0)
    {
        if (cap != 0)
            reserve(_data, cap);
    }

    @property ubyte[] data()
    {
        return _data;
    }

    @property size_t capacity()
    {
        return _data.capacity;
    }

    void reserveCapacity(size_t cap)
    {
        reserve(_data, cap);
    }

    ulong tell()
    {
        return _writePos;
    }

    void seek(ulong pos)
    {
        assert(pos < size_t.max);

        _writePos = cast(size_t)pos;
        if (_writePos > _data.length)
            _data.length = _writePos;
    }

    void put(ubyte val)
    {
        if (_writePos == _data.length)
            _data ~= val;
        else
            _data[_writePos] = val;
        _writePos++;
    }

    void write(scope const(ubyte)[] arr)
    {
        if (_writePos == _data.length)
        {
            _writePos += arr.length;
            _data ~= arr;
            return;
        }

        const overwrite = _data.length - _writePos;
        _data[_writePos .. _writePos + overwrite] = arr[0 .. overwrite];
        if (overwrite < arr.length)
            _data ~= arr[overwrite .. $];
        _writePos += arr.length;
    }
}

class FileWriteCursor : WriteCursor
{
    import std.stdio : File;

    File _file;

    this(File file)
    {
        _file = file;
    }

    this(string filename)
    {
        _file = File(filename, "wb");
    }

    void close()
    {
        _file.close();
        _file = File.init;
    }

    @property File file()
    {
        return _file;
    }

    ulong tell()
    {
        return _file.tell;
    }

    void seek(ulong pos)
    {
        _file.seek(pos);
    }

    void put(ubyte val)
    {
        auto buf = (&val)[0 .. 1];
        _file.rawWrite(buf);
    }

    void write(scope const(ubyte)[] arr)
    {
        _file.rawWrite(arr);
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

/// same as std.stdio.File.byChunk but returns const(ubyte)[]
struct ByChunkImpl
{
    import std.stdio : File;

private:
    File    file_;
    ubyte[] chunk_;

    void prime()
    {
        chunk_ = file_.rawRead(chunk_);
        if (chunk_.length == 0)
            file_.detach();
    }

public:
    this(File file, size_t size)
    {
        this(file, new ubyte[](size));
    }

    this(File file, ubyte[] buffer)
    {
        import std.exception : enforce;
        enforce(buffer.length, "size must be larger than 0");
        file_ = file;
        chunk_ = buffer;
        prime();
    }

    // `ByChunk`'s input range primitive operations.
    @property nothrow
    bool empty() const
    {
        return !file_.isOpen;
    }

    /// Ditto
    @property nothrow
    const(ubyte)[] front()
    {
        version (assert)
        {
            import core.exception : RangeError;
            if (empty)
                throw new RangeError();
        }
        return chunk_;
    }

    /// Ditto
    void popFront()
    {
        version (assert)
        {
            import core.exception : RangeError;
            if (empty)
                throw new RangeError();
        }
        prime();
    }
}

// copy of std.range.generate with phobos issue 19587 fixed
// see phobos#8453
auto hatch(alias fun)()
{
    return Hatch!(fun)();
}

struct Hatch(alias fun)
{
    import std.range : isInputRange;
    import std.traits : FunctionAttribute, functionAttributes, ReturnType;

    static assert(isInputRange!Hatch);

private:

    enum returnByRef_ = (functionAttributes!fun & FunctionAttribute.ref_) ? true : false;
    static if (returnByRef_)
        ReturnType!fun* elem_;
    else
        ReturnType!fun elem_;

    bool valid_;

public:
    /// Range primitives
    enum empty = false;

    static if (returnByRef_)
    {
        /// ditto
        ref front() @property
        {
            if (!valid_)
            {
                elem_ = &fun();
                valid_ = true;
            }
            return *elem_;
        }
    }
    else
    {
        /// ditto
        auto front() @property
        {
            if (!valid_)
            {
                elem_ = fun();
                valid_ = true;
            }
            return elem_;
        }
    }
    /// ditto
    void popFront()
    {
        // popFront called without calling front
        if (!valid_)
            cast(void) fun();
        valid_ = false;
    }
}
