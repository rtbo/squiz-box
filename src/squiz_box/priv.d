module squiz_box.priv;

package(squiz_box):

import squiz_box.core : EntryType, isByteRange;

import std.datetime.systime;
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
