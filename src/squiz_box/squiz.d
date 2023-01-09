/// Compression and decompression streaming algorithms.
///
/// Each compression or decompression algorithm is represented by a struct
/// that contains parameters for compression/decompression.
/// Besides the parameters they carry, algorithms have no state. Each
/// algorithm instance can be used for an unlimited number of parallel jobs.
///
/// The algorithms create a stream, which carry the state and allocated
/// resources of the ongoing compression.
///
/// The compression/decompression jobs are run by the `squiz` function,
/// or one of the related helpers built upon it (e.g. deflate, deflateGz, inflate, ...).
///
/// `squiz` and related functions take and InputRange of ubyte[] and return an InputRange of ubyte[].
/// This allows streaming in the most natural way for a D program and provide
/// the greatest versatility.
/// It is possible to read the data from any source (file, network, memory),
/// process the data, and write to any kind of destination.
/// This also allows to process gigabytes of data with little memory usage.
///
/// Compression often wraps the compressed data with header and trailer
/// that give the decompression algorithm useful information, especially
/// to check the integrity of the data after decompression.
/// This is called the format.
/// Some compressions algorithms offer different formats, and sometimes
/// the possibility to not wrap the data at all (raw format), in which
/// case integrity check is not performed. This is usually used when
/// an external integrity check is done, for example when archiving
/// compressed stream in Zip or 7z archives.
module squiz_box.squiz;

import squiz_box.c.zlib;
import squiz_box.priv;

import std.datetime.systime;
import std.exception;
import std.range;
import std.typecons;

version (HaveSquizBzip2)
{
    import squiz_box.c.bzip2;
}
version (HaveSquizLzma)
{
    import squiz_box.c.lzma;
}
version (HaveSquizZstandard)
{
    import squiz_box.c.zstd;
}

/// default chunk size for data exchanges and I/O operations
enum defaultChunkSize = 8192;

/// definition of a byte chunk, which is the unit of data
/// exchanged during I/O and data transformation operations
alias ByteChunk = const(ubyte)[];

/// A dynamic type of input range of chunks of bytes
alias ByteRange = InputRange!ByteChunk;

/// Static check that a type is a byte range.
template isByteRange(BR)
{
    import std.traits : isArray, Unqual;
    import std.range : ElementType, isInputRange;

    alias Arr = ElementType!BR;
    alias El = ElementType!Arr;

    enum isByteRange = isInputRange!BR && is(Unqual!El == ubyte);
}

static assert(isByteRange!ByteRange);

/// Exception thrown when inconsistent data is given to
/// a decompression algorithm.
/// I.e. the data was not compressed with the corresponding algorithm
/// or the wrapping format is not the one expected.
@safe class DataException : Exception
{
    mixin basicExceptionCtors!();
}

/// Check whether a type is a proper squiz algorithm.
template isSquizAlgo(A)
{
    enum isSquizAlgo = is(typeof((A algo) {
                auto stream = algo.initialize();
                Flag!"streamEnded" ended = algo.process(stream, Yes.lastChunk);
                algo.reset(stream);
                algo.end(stream);
                static assert(is(typeof(stream) : SquizStream));
            }));
}

/// Get the type of a SquizStream for the Squiz algorithm
template StreamType(A) if (isSquizAlgo!A)
{
    import std.traits : ReturnType;

    alias StreamType = ReturnType!(A.initialize);
}

/// A squiz algorithm whom type is erased behind an interface.
/// This helps to choose algorithm at run time.
interface SquizAlgo
{
    /// Initialize a new stream for processing data
    /// with this algorithm.
    SquizStream initialize() @safe;

    /// Processes the input stream data to produce output stream data.
    /// lastChunk indicates that the input chunk in stream is the last one.
    /// This is an indication to the algorithm that it can start to finish
    /// the work.
    /// Returned value indicates that there won't be more output generated
    /// than the one in stream.output
    Flag!"streamEnded" process(SquizStream stream, Flag!"lastChunk" lastChunk) @safe;

    /// Reset the state of this stream, yet reusing the same
    /// allocating resources, in order to start processing
    /// another data stream.
    void reset(SquizStream stream) @safe;

    /// Release the resources used by this stream.
    /// Most of the memory (if not all) used by algorithm
    /// is allocating with the garbage collector, so not
    /// calling this function has little consequence (if not none).
    void end(SquizStream stream) @safe;
}

static assert(isSquizAlgo!SquizAlgo);

/// Get a runtime type for the provided algorithm
SquizAlgo squizAlgo(A)(A algo) @safe if (isSquizAlgo!A)
{
    return new CSquizAlgo!A(algo);
}

///
@("squizAlgo")
unittest
{
    import test.util;
    import std.array : join;

    auto ctAlgo = Deflate.init;
    auto rtAlgo = squizAlgo(Deflate.init);

    const len = 10_000;
    const phrase = cast(const(ubyte)[]) "Some very repetitive phrase.\n";
    const input = generateRepetitiveData(len, phrase).join();

    const ctSquized = only(input).squiz(ctAlgo).join();
    const rtSquized = only(input).squiz(rtAlgo).join();

    assert(ctSquized == rtSquized);
}

private class CSquizAlgo(A) : SquizAlgo
{
    alias Stream = StreamType!A;

    A algo;

    private this(A algo) @safe
    {
        this.algo = algo;
    }

    private Stream checkStream(SquizStream stream)
    {
        auto s = cast(Stream) stream;
        assert(s, "provided stream is not produced by this algorithm");
        return s;
    }

    SquizStream initialize() @safe
    {
        return algo.initialize();
    }

    Flag!"streamEnded" process(SquizStream stream, Flag!"lastChunk" lastChunk) @safe
    {
        return algo.process(checkStream(stream), lastChunk);
    }

    void reset(SquizStream stream) @safe
    {
        return algo.reset(checkStream(stream));
    }

    void end(SquizStream stream) @safe
    {
        return algo.end(checkStream(stream));
    }
}

/// A state carrying, processing stream for squiz algorithms.
/// The stream does not carry any buffer, only slices to external buffer.
/// One may normally not use this directly as everything is handled
/// by the `squiz` function.
interface SquizStream
{
    /// Input data for the algorithm
    /// The slice is reduced by its begining as the processing moves on.
    /// Must be refilled when empty before calling the algorithm `process` method.
    @property const(ubyte)[] input() const @safe;
    /// Ditto
    @property void input(const(ubyte)[] inp) @safe;

    /// How many bytes read since the start of the stream processing.
    @property size_t totalInput() const @safe;

    /// Output buffer for the algorithm to write to.
    /// This is NOT the data ready after process, but where the
    /// algorithm must write next.
    /// after a call to process, the slice is reduced by its beginning,
    /// and the data written is therefore the one before the slice.
    @property inout(ubyte)[] output() inout @safe;
    @property void output(ubyte[] outp) @safe;

    /// How many bytes written since the start of the stream processing.
    @property size_t totalOutput() const @safe;
}

/// Build an algo that process data over the provided streams, in the given order
SquizAlgo squizCompoundAlgo(SquizAlgo[] algos)
{
    return new SquizCompoundAlgo(algos);
}

private class SquizCompoundAlgo : SquizAlgo
{
    private SquizAlgo[] algos;
    alias Stream = SquizCompoundStream;

    this(SquizAlgo[] algos)
    {
        assert(algos.length >= 1);

        this.algos = algos;
    }

    private Stream checkStream(SquizStream stream) @safe
    {
        auto s = cast(Stream) stream;
        assert(s, "provided stream is not produced by this algorithm");
        assert(s.streams.length == algos.length, "provided stream is not produced by this algorithm");
        return s;
    }

    override SquizStream initialize() @safe
    {
        import std.algorithm : map;

        return new SquizCompoundStream(algos.map!(a => a.initialize()).array);
    }

    override Flag!"streamEnded" process(SquizStream stream, Flag!"lastChunk" lastChunk)
    {
        import std.stdio;

        auto cs = checkStream(stream);

        bool prevEnded = cast(bool) lastChunk;

        foreach (i; 0 .. algos.length)
        {
            auto alg = algos[i];
            auto stm = cs.streams[i];

            const bool first = i == 0;
            const bool last = i == cast(ptrdiff_t) algos.length - 1;

            if (!last && !stm.output.length)
            {
                stm.output = cs.innerBuffer(i);
                cs.cursor(i, 0);
            }

            if (!first)
            {
                auto prevStm = cs.streams[i - 1];
                auto prevBuf = cs.innerBuffer(i - 1);
                auto prevCursor = cs.cursor(i - 1);
                stm.input = prevBuf[prevCursor .. $ - prevStm.output.length];
            }

            const inp1 = stm.input.length;
            bool ended = last ? false : cs.ended(i);

            while ((stm.input.length || prevEnded) && stm.output.length && !ended)
            {
                ended = cast(bool) alg.process(stm, cast(Flag!"lastChunk") prevEnded);
            }
            assert(stm.input.length == 0 || stm.output.length == 0);

            const inp2 = stm.input.length;
            const read = inp1 - inp2;

            prevEnded = ended;

            if (!first)
                cs.cursor(i - 1, cs.cursor(i - 1) + read);
            if (!last)
                cs.ended(i, ended);
        }

        return cast(Flag!"streamEnded") prevEnded;
    }

    void reset(SquizStream stream) @safe
    {
        auto cs = checkStream(stream);
        foreach (i; 0 .. algos.length)
            algos[i].reset(cs.streams[i]);
    }

    void end(SquizStream stream) @safe
    {
        auto cs = checkStream(stream);
        foreach (i; 0 .. algos.length)
            algos[i].end(cs.streams[i]);
    }
}

private class SquizCompoundStream : SquizStream
{
    private SquizStream[] streams;
    private ubyte[] buffer;
    private size_t[] cursors;
    private bool[] endeds;

    enum innerBufferSize = 8192;

    this(SquizStream[] streams) @safe
    {
        assert(streams.length >= 1);

        this.streams = streams;
        if (streams.length > 1)
        {
            const num = cast(ptrdiff_t) streams.length - 1;
            this.buffer = new ubyte[innerBufferSize * num];
            this.cursors = new size_t[num];
            this.endeds = new bool[num];
        }
    }

    // buffer between i and i+1
    private ubyte[] innerBuffer(size_t i) @safe
    {
        return buffer[i * innerBufferSize .. (i + 1) * innerBufferSize];
    }

    private size_t cursor(size_t i) @safe
    {
        return cursors[i];
    }

    private void cursor(size_t i, size_t val) @safe
    {
        cursors[i] = val;
    }

    private bool ended(size_t i) @safe
    {
        return endeds[i];
    }

    private void ended(size_t i, bool val) @safe
    {
        endeds[i] = val;
    }

    override @property const(ubyte)[] input() const @safe
    {
        return streams[0].input;
    }

    override @property void input(const(ubyte)[] inp) @safe
    {
        streams[0].input = inp;
    }

    override @property size_t totalInput() const @safe
    {
        return streams[0].totalInput;
    }

    override @property inout(ubyte)[] output() inout @safe
    {
        return streams[$ - 1].output;
    }

    override @property void output(ubyte[] outp) @safe
    {
        streams[$ - 1].output = outp;
    }

    override @property size_t totalOutput() const @safe
    {
        return streams[$ - 1].totalOutput;
    }
}

private template isZlibLikeStream(S)
{
    enum isZlibLikeStream = is(typeof((S stream) {
                stream.next_in = cast(const(ubyte)*) null;
                stream.avail_in = 0;
                stream.next_out = cast(ubyte*) null;
                stream.avail_out = 0;
            }));
}

private mixin template ZlibLikeStreamImpl(S) if (isZlibLikeStream!S)
{
    private S strm;

    @property const(ubyte)[] input() const @trusted
    {
        return strm.next_in[0 .. strm.avail_in];
    }

    @property void input(const(ubyte)[] inp) @trusted
    {
        strm.next_in = inp.ptr;
        strm.avail_in = cast(typeof(strm.avail_in)) inp.length;
    }

    @property inout(ubyte)[] output() inout @trusted
    {
        return strm.next_out[0 .. strm.avail_out];
    }

    @property void output(ubyte[] outp) @trusted
    {
        strm.next_out = outp.ptr;
        strm.avail_out = cast(typeof(strm.avail_out)) outp.length;
    }
}

mixin template ZlibLikeTotalInOutImpl()
{
    @property size_t totalInput() const
    {
        return cast(size_t) strm.total_in;
    }

    @property size_t totalOutput() const
    {
        return cast(size_t) strm.total_out;
    }
}

/// Returns an InputRange containing the input data processed through the supplied algorithm.
auto squiz(I, A)(I input, A algo, size_t chunkSize = defaultChunkSize)
        if (isByteRange!I && isSquizAlgo!A)
{
    return squiz(input, algo, new ubyte[chunkSize]);
}

/// ditto
auto squiz(I, A)(I input, A algo, ubyte[] chunkBuffer)
        if (isByteRange!I && isSquizAlgo!A)
{
    auto stream = algo.initialize();
    return Squiz!(I, A, Yes.endStream)(input, algo, stream, chunkBuffer, ulong.max);
}

/// Returns an InputRange containing the input data processed through the supplied algorithm.
/// To the difference of `squiz`, `squizReuse` will not manage the state (aka stream) of the algorithm,
/// which allows to reuse it (and its allocated resources) for several jobs.
/// squizReuse will drive the algorithm and move the stream forward until processing is over.
/// When the output stream must be finished, pass Yes.lastInput.
/// squizReuse is useful in two situations:
///  - concat several data sources to the same stream
///  - reuse allocated resources. In that case, if concat is not required,
///    algo.reset must be called between each call of squizReuse.
auto squizReuse(I, A, S)(I input, A algo, S stream, Flag!"lastInput" lastInput, ubyte[] chunkBuffer)
        if (isByteRange!I && isSquizAlgo!A)
{
    static assert(is(StreamType!A == S), S.strinof ~ " is not the stream produced by " ~ A.stringof);
    return Squiz!(I, A, No.endStream)(input, algo, stream, chunkBuffer, ulong.max, lastInput);
}

/// Same as squiz, but will stop encoding/decoding after len bytes has been written out
/// Useful to decode some raw encoded streams where the uncompressed size is known
/// and the algorithm not always report Yes.streamEnded.
auto squizMaxOut(I, A)(I input, A algo, ulong maxOut, size_t chunkSize = defaultChunkSize)
{
    import std.algorithm : min;

    const sz = cast(size_t) min(maxOut, chunkSize);
    auto chunkBuffer = new ubyte[sz];
    auto stream = algo.initialize();
    return Squiz!(I, A, Yes.endStream)(input, algo, stream, chunkBuffer, maxOut);
}

// Common transformation range for all compression/decompression functions.
// I is a byte input range
// A is a squiz algorithm
// if Yes.end, the stream is ended when data is done processing
private struct Squiz(I, A, Flag!"endStream" endStream)
{
    private alias Stream = StreamType!A;

    // Byte input range (by chunks)
    private I input;

    // The algorithm
    private A algo;

    // Processed stream stream
    private Stream stream;

    // Buffer used to store the front chunk
    private ubyte[] chunkBuffer;
    // Slice of the buffer that is valid for read out
    private ByteChunk chunk;

    // maximum number of bytes to write out
    private ulong maxLen;

    // whether the stream must be concluded
    Flag!"lastInput" lastInput;

    /// Whether the end of stream was reported by the Policy
    private bool ended;

    private this(I input, A algo, Stream stream, ubyte[] chunkBuffer, ulong maxLen,
    Flag!"lastInput" lastInput = Yes.lastInput)
    {
        this.input = input;
        this.algo = algo;
        this.stream = stream;
        this.chunkBuffer = chunkBuffer;
        this.maxLen = maxLen;
        this.lastInput = lastInput;
        prime();
    }

    @property bool empty()
    {
        return chunk.length == 0;
    }

    @property ByteChunk front()
    {
        return chunk;
    }

    void popFront()
    {
        chunk = null;
        if (!ended)
            prime();
    }

    private void prime()
    {
        import std.algorithm : min;

        while (chunk.length < chunkBuffer.length)
        {
            if (stream.input.length == 0 && !input.empty)
                stream.input = input.front;

            const len = min(chunkBuffer.length - chunk.length, maxLen);
            stream.output = chunkBuffer[chunk.length .. chunk.length + len];

            const streamEnded = algo.process(stream, cast(Flag!"lastChunk")(input.empty && lastInput));

            chunk = chunkBuffer[0 .. $ - stream.output.length];
            maxLen -= len;

            // popFront must be called at the end because it invalidates inChunk
            if (stream.input.length == 0 && !input.empty)
                input.popFront();

            if (stream.input.length == 0 && !lastInput)
            {
                // more input will come, we can leave here for the next round.
                ended = true;
                break;
            }

            if (streamEnded || maxLen == 0)
            {
                ended = true;
                static if (endStream)
                    algo.end(stream);
                break;
            }
        }
    }
}

version (HaveSquizLzma)
{
    @("squizMaxOut")
    unittest
    {
        // encoded header of test/data/archive.7z
        const(ubyte)[] dataIn = [
            0x00, 0x00, 0x81, 0x33, 0x07, 0xae, 0x0f, 0xd1, 0xf2, 0xfb, 0xfd, 0x40,
            0xc0, 0x90, 0xd2, 0xff, 0x7d, 0x69, 0x4d, 0x90, 0xd3, 0x2c, 0x42, 0x66,
            0xb0, 0xc6, 0xcc, 0xeb, 0xcf, 0x59, 0xcc, 0x96, 0x23, 0xf9, 0x91, 0xc8,
            0x75, 0x49, 0xe9, 0x9d, 0x1a, 0xa8, 0xa5, 0x9d, 0xf7, 0x75, 0x29, 0x1a,
            0x90, 0x78, 0x18, 0x8e, 0x42, 0x1a, 0x97, 0x0c, 0x40, 0xb7, 0xaa, 0xb6,
            0x16, 0xa9, 0x91, 0x0c, 0x58, 0xad, 0x75, 0xf7, 0x8f, 0xaf, 0x8f, 0x45,
            0xdb, 0x78, 0xd0, 0x8e, 0xc6, 0x1b, 0x72, 0xa5, 0xf4, 0xd2, 0x46, 0xf7,
            0xe1, 0xce, 0x01, 0x80, 0x7f, 0x3d, 0x66, 0xa5, 0x2d, 0x64, 0xd7, 0xb0,
            0x41, 0xdc, 0x92, 0x59, 0x88, 0xb0, 0x4c, 0x67, 0x34, 0xb6, 0x4e, 0xd3,
            0xd5, 0x01, 0x8d, 0x43, 0x13, 0x9c, 0x82, 0x78, 0x4d, 0xcf, 0x8c, 0x51,
            0x25, 0x0f, 0xd5, 0x1d, 0x80, 0x4b, 0x80, 0xea, 0x18, 0xc1, 0x29, 0x49,
            0xe4, 0x4d, 0x4d, 0x8b, 0xb9, 0xa1, 0xfc, 0x17, 0x2b, 0xb3, 0xe6, 0x00,
            0x00, 0x00
        ];
        // decoded header data of test/data/archive.7z
        const(ubyte)[] expectedDataOut = [
            0x01, 0x04, 0x06, 0x00, 0x01, 0x09, 0x40, 0x00, 0x07, 0x0b, 0x01, 0x00,
            0x01, 0x21, 0x21, 0x01, 0x00, 0x0c, 0x8d, 0xe2, 0x00, 0x08, 0x0d, 0x03,
            0x09, 0x8d, 0xc1, 0x07, 0x0a, 0x01, 0x84, 0x4d, 0x4d, 0xa8, 0x9e, 0xf4,
            0xb3, 0xdb, 0x12, 0xed, 0x64, 0x40, 0x00, 0x00, 0x05, 0x03, 0x19, 0x0d,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x11, 0x55, 0x00, 0x66, 0x00, 0x69, 0x00, 0x6c, 0x00, 0x65, 0x00,
            0x20, 0x00, 0x32, 0x00, 0x2e, 0x00, 0x74, 0x00, 0x78, 0x00, 0x74, 0x00,
            0x00, 0x00, 0x66, 0x00, 0x69, 0x00, 0x6c, 0x00, 0x65, 0x00, 0x31, 0x00,
            0x2e, 0x00, 0x74, 0x00, 0x78, 0x00, 0x74, 0x00, 0x00, 0x00, 0x66, 0x00,
            0x6f, 0x00, 0x6c, 0x00, 0x64, 0x00, 0x65, 0x00, 0x72, 0x00, 0x2f, 0x00,
            0x63, 0x00, 0x68, 0x00, 0x6d, 0x00, 0x6f, 0x00, 0x64, 0x00, 0x20, 0x00,
            0x36, 0x00, 0x36, 0x00, 0x36, 0x00, 0x2e, 0x00, 0x74, 0x00, 0x78, 0x00,
            0x74, 0x00, 0x00, 0x00, 0x14, 0x1a, 0x01, 0x00, 0x80, 0x96, 0x9f, 0xd5,
            0xc8, 0x53, 0xd8, 0x01, 0x80, 0x50, 0x82, 0x4f, 0xc6, 0x53, 0xd8, 0x01,
            0x00, 0xff, 0x13, 0x13, 0xb7, 0x52, 0xd8, 0x01, 0x15, 0x0e, 0x01, 0x00,
            0x20, 0x80, 0xa4, 0x81, 0x20, 0x80, 0xa4, 0x81, 0x20, 0x80, 0xb6, 0x81,
            0x00, 0x00
        ];

        DecompressLzma algo;
        algo.format = LzmaFormat.raw;
        algo.rawFilters = [
            LzmaFilter(Lzma1PresetFilter(6))
        ];

        const dataOut = only(dataIn)
            .squizMaxOut(algo, expectedDataOut.length)
            .join();

        assert(dataOut == expectedDataOut);
    }
}

/// Copy algorithm do not transform data at all
/// This is useful in cases of reading/writing data
/// that may or may not be compressed. Using Copy
/// allows that the same code handles both kind of streams.
final class CopyStream : SquizStream
{
    private const(ubyte)[] _inp;
    size_t _totalIn;
    private ubyte[] _outp;
    size_t _totalOut;

    @property const(ubyte)[] input() const @safe
    {
        return _inp;
    }

    @property void input(const(ubyte)[] inp) @safe
    {
        _inp = inp;
    }

    @property size_t totalInput() const @safe
    {
        return _totalIn;
    }

    @property inout(ubyte)[] output() inout @safe
    {
        return _outp;
    }

    @property void output(ubyte[] outp) @safe
    {
        _outp = outp;
    }

    @property size_t totalOutput() const @safe
    {
        return _totalOut;
    }
}

/// ditto
struct Copy
{
    static assert(isSquizAlgo!Copy);

    CopyStream initialize() @safe
    {
        return new CopyStream;
    }

    Flag!"streamEnded" process(CopyStream stream, Flag!"lastChunk" lastChunk) @safe
    {
        import std.algorithm : min;

        const len = min(stream._inp.length, stream._outp.length);

        stream._outp[0 .. len] = stream._inp[0 .. len];

        stream._inp = stream._inp[len .. $];
        stream._outp = stream._outp[len .. $];
        stream._totalIn += len;
        stream._totalOut += len;

        return cast(Flag!"streamEnded")(lastChunk && stream._inp.length == 0);
    }

    void reset(CopyStream stream) @safe
    {
        stream._inp = null;
        stream._outp = null;
        stream._totalIn = 0;
        stream._totalOut = 0;
    }

    void end(CopyStream) @safe
    {
    }
}

/// ditto
auto copy(I)(I input, size_t chunkSize = defaultChunkSize)
{
    return squiz(input, Copy.init, chunkSize);
}

///
@("Copy")
unittest
{
    import test.util : generateRepetitiveData;
    import std.array : join;

    const len = 10_000;
    const phrase = cast(const(ubyte)[]) "Some very repetitive phrase.\n";
    const input = generateRepetitiveData(len, phrase).join();

    /// copying with arbitrary chunk sizes on input and output
    const cop1 = generateRepetitiveData(len, phrase, 1231).copy(234).join();
    const cop2 = generateRepetitiveData(len, phrase, 296).copy(6712).join();

    assert(input == cop1);
    assert(input == cop2);
}

/// Describe what type of header and trailer are wrapping
/// a deflated stream.
enum ZlibFormat
{
    /// Zlib header and trailer
    zlib,
    /// Gzip header and trailer
    gz,
    /// Auto detection of Zlib or Gzip format (only used with Inflate)
    autoDetect,
    /// No header and trailer, therefore no integrity check included.
    /// This to be used in other formats such as Zip.
    /// When using raw, it is advised to use an external integrity check.
    raw,
}

private size_t strnlen(const(byte)* str, size_t maxlen) @system
{
    if (!str)
        return 0;

    size_t l;
    while (*str != 0 && l < maxlen)
    {
        str++;
        l++;
    }
    return l;
}

@("strnlen")
unittest
{
    assert(strnlen(null, 0) == 0);
    assert(strnlen(cast(const(byte)*)("abcdefghij\0klmn".ptr), 15) == 10);
    assert(strnlen(cast(const(byte)*)("abcdefghij\0klmn".ptr), 10) == 10);
    assert(strnlen(cast(const(byte)*)("abcdefghij\0klmn".ptr), 9) == 9);
    assert(strnlen(cast(const(byte)*)("abcdefghij\0klmn".ptr), 0) == 0);
    assert(strnlen(cast(const(byte)*)("\0bcdefghij\0klmn".ptr), 15) == 0);
}

/// Header data for the Gzip format.
/// Gzip includes metadata about the file which is compressed.
/// These can be specified here when compressing from a stream
/// rather than directly from a file.
struct GzHeader
{
    import core.stdc.config : c_ulong;

    /// operating system encoded in the Gz header
    /// Not all possible values are listed here, only
    /// the most useful ones
    enum Os
    {
        fatFs = 0,
        unix = 3,
        macintosh = 7,
        ntFs = 11,
        unknown = 255,
    }

    version (OSX)
        enum defaultOs = Os.macintosh;
    else version (iOS)
        enum defaultOs = Os.macintosh;
    else version (Posix)
        enum defaultOs = Os.unix;
    else version (Windows)
        enum defaultOs = Os.ntFs;

    /// Whether the content is believed to be text
    Flag!"text" text;

    // storing in unix format to avoid
    // negative numbers with SysTime.init
    private c_ulong _mtime;

    /// Modification time
    @property SysTime mtime() const @safe
    {
        return SysTime(unixTimeToStdTime(_mtime));
    }

    /// ditto
    @property void mtime(SysTime time) @safe
    {
        _mtime = stdTimeToUnixTime(time.stdTime);
    }

    /// Operating system that wrote the gz file
    Os os = defaultOs;

    /// Filename to be included in the header
    string filename;

    /// Comment to be included in the header
    string comment;

    private enum bufSize = 256;

    private string fromLatin1z(const(byte)* ptr) @system
    {
        // ptr points to a buffer of bufSize characters.
        // End of string is a null character or end of buffer.
        // Encoding is latin 1.
        import std.encoding : Latin1Char, transcode;

        const len = strnlen(ptr, bufSize);
        auto str = cast(const(Latin1Char)[]) ptr[0 .. len];

        string res;
        transcode(str, res);
        return res;
    }

    private byte* toLatin1z(string str) @trusted
    {
        import std.encoding : Latin1Char, transcode;

        Latin1Char[] l1;
        transcode(str, l1);
        auto res = (cast(byte[]) l1) ~ 0;
        return res.ptr;
    }

    private this(gz_headerp gzh) @system
    {
        text = gzh.text ? Yes.text : No.text;
        _mtime = gzh.time;
        os = cast(Os) gzh.os;
        if (gzh.name)
            filename = fromLatin1z(gzh.name);
        if (gzh.comment)
            comment = fromLatin1z(gzh.comment);
    }

    private gz_headerp toZlib() @safe
    {
        import core.stdc.config : c_long;

        auto gzh = new gz_header;
        gzh.text = text ? 1 : 0;
        gzh.time = _mtime;
        gzh.os = cast(int) os;
        if (filename)
            gzh.name = toLatin1z(filename);
        if (comment)
            gzh.comment = toLatin1z(comment);
        return gzh;
    }
}

/// Type of delegate to use as callback for Inflate.gzHeaderDg
alias GzHeaderDg = void delegate(GzHeader header) @safe;

/// Helper to set GzHeader.text
/// Will check if the data are all ascii characters
Flag!"text" isText(const(ubyte)[] data)
{
    import std.algorithm : all;

    return cast(Flag!"text") data.all!(
        c => c == 0x0a || c == 0x0d || (c >= 0x20 && c <= 0x7e)
    );
}

class ZlibStream : SquizStream
{
    mixin ZlibLikeStreamImpl!z_stream;
    mixin ZlibLikeTotalInOutImpl!();

    private this() @safe
    {
        strm.zalloc = &(gcAlloc!uint);
        strm.zfree = &gcFree;
    }
}

/// Returns an InputRange containing the input data processed through Zlib's deflate algorithm.
/// The produced stream of data is wrapped by Zlib header and trailer.
auto deflate(I)(I input, size_t chunkSize = defaultChunkSize) if (isByteRange!I)
{
    return squiz(input, Deflate.init, chunkSize);
}

/// Returns an InputRange containing the input data processed through Zlib's deflate algorithm.
/// The produced stream of data is wrapped by Gzip header and trailer.
/// Suppliying a header is entirely optional. Zlib produces a default header if not supplied.
/// The default header has text false, mtime zero, unknown os, and
/// no name or comment.
auto deflateGz(I)(I input, GzHeader header, size_t chunkSize = defaultChunkSize)
        if (isByteRange!I)
{
    auto algo = Deflate.init;
    algo.format = ZlibFormat.gz;
    algo.gzHeader = header;
    return squiz(input, algo, chunkSize);
}

/// ditto
auto deflateGz(I)(I input, size_t chunkSize = defaultChunkSize) if (isByteRange!I)
{
    auto algo = Deflate.init;
    algo.format = ZlibFormat.gz;
    return squiz(input, algo, chunkSize);
}

/// Returns an InputRange containing the input data processed through Zlib's deflate algorithm.
/// The produced stream of data isn't wrapped by any header or trailer.
auto deflateRaw(I)(I input, size_t chunkSize = defaultChunkSize) if (isByteRange!I)
{
    auto algo = Deflate.init;
    algo.format = ZlibFormat.raw;
    return squiz(input, algo, chunkSize);
}

/// Zlib's deflate algorithm
struct Deflate
{
    static assert(isSquizAlgo!Deflate);
    static assert(is(StreamType!Deflate == Stream));

    /// Which format to use for the deflated stream.
    /// In case ZlibFormat.gz, the gzHeader field will be used if supplied,
    /// other wise default values will be used.
    ZlibFormat format;

    /// Compression level from 1 (fastest) to 9 (best compression).
    int level = 6;

    /// The GzHeader to be used with ZlibFormat.gz.
    Nullable!GzHeader gzHeader;

    /// Advanced parameters
    /// See zlib's documentation of `deflateInit2`.
    /// windowBits must be between 9 and 15 included
    /// and is adjusted according chosen format.
    int windowBits = 15;
    /// ditto
    int memLevel = 8;
    /// ditto
    int strategy = Z_DEFAULT_STRATEGY;

    static final class Stream : ZlibStream
    {
    }

    Stream initialize() @safe
    {
        assert(
            9 <= windowBits && windowBits <= 15,
            "inconsistent windowBits"
        );
        int wb = windowBits;
        final switch (format)
        {
        case ZlibFormat.zlib:
            break;
        case ZlibFormat.gz:
            wb += 16;
            break;
        case ZlibFormat.autoDetect:
            throw new Exception("invalid ZlibFormat for Deflate");
        case ZlibFormat.raw:
            wb = -wb;
            break;
        }

        auto stream = new Stream();

        const res = (() @trusted => deflateInit2(
                &stream.strm, level, Z_DEFLATED,
                wb, memLevel, cast(int) strategy,
        ))();

        enforce(
            res == Z_OK,
            "Could not initialize Zlib deflate stream: " ~ zResultToString(res)
        );

        if (format == ZlibFormat.gz && !gzHeader.isNull)
        {
            auto head = gzHeader.get.toZlib();
            (() @trusted => deflateSetHeader(&stream.strm, head))();
        }

        return stream;
    }

    Flag!"streamEnded" process(Stream stream, Flag!"lastChunk" lastChunk) @safe
    {
        const flush = lastChunk ? Z_FINISH : Z_NO_FLUSH;
        const res = (() @trusted => squiz_box.c.zlib.deflate(&stream.strm, flush))();

        enforce(
            res == Z_OK || res == Z_STREAM_END,
            "Zlib deflate failed with code: " ~ zResultToString(res)
        );

        return cast(Flag!"streamEnded")(res == Z_STREAM_END);
    }

    void reset(Stream stream) @trusted
    {
        deflateReset(&stream.strm);
    }

    void end(Stream stream) @trusted
    {
        deflateEnd(&stream.strm);
    }
}

/// Returns an InputRange streaming over data inflated with Zlib.
/// The input data must be deflated with a zlib format.
auto inflate(I)(I input, size_t chunkSize = defaultChunkSize)
{
    return squiz(input, Inflate.init, chunkSize);
}

/// Returns an InputRange streaming over data inflated with Zlib.
/// The input data must be deflated with a gz format.
/// If headerDg is not null, it will be called
/// as soon as the header is read from the stream.
auto inflateGz(I)(I input, GzHeaderDg headerDg, size_t chunkSize = defaultChunkSize)
{
    auto algo = Inflate.init;
    algo.format = ZlibFormat.gz;
    algo.gzHeaderDg = headerDg;
    return squiz(input, algo, chunkSize);
}

/// ditto
auto inflateGz(I)(I input, size_t chunkSize = defaultChunkSize)
{
    return inflateGz(input, null, chunkSize);
}

/// Returns an InputRange streaming over data inflated with Zlib.
/// The input must be raw deflated data
auto inflateRaw(I)(I input, size_t chunkSize = defaultChunkSize)
{
    auto algo = Inflate.init;
    algo.format = ZlibFormat.raw;
    return squiz(input, algo, chunkSize);
}

/// Zlib's inflate algorithm
struct Inflate
{
    static assert(isSquizAlgo!Inflate);

    /// Which format to use for the deflated stream.
    /// In case ZlibFormat.gz, the gzHeader field will be written if set.
    ZlibFormat format;

    /// If set, will be assigned to the Gz header once it is known
    GzHeaderDg gzHeaderDg;

    /// Advanced parameters
    /// See zlib's documentation of `deflateInit2`.
    /// windowBits can be 0 if format is ZlibFormat.zlib.
    /// Otherwise it must be between 9 and 15 included.
    int windowBits = 15;

    private static final class Gzh
    {
        private gz_header gzh;
        private byte[GzHeader.bufSize] nameBuf;
        private byte[GzHeader.bufSize] commentBuf;

        private GzHeaderDg dg;
        private bool dgCalled;

        this(GzHeaderDg dg) @safe
        {
            gzh.name = &nameBuf[0];
            gzh.name_max = cast(uint) nameBuf.length;
            gzh.comment = &commentBuf[0];
            gzh.comm_max = cast(uint) commentBuf.length;

            this.dg = dg;
        }
    }

    static final class Stream : ZlibStream
    {
        Gzh gzh;
    }

    Stream initialize() @safe
    {
        assert(
            (windowBits == 0 && format == ZlibFormat.zlib) ||
                (9 <= windowBits && windowBits <= 15),
                "inconsistent windowBits"
        );
        int wb = windowBits;
        final switch (format)
        {
        case ZlibFormat.zlib:
            break;
        case ZlibFormat.gz:
            wb += 16;
            break;
        case ZlibFormat.autoDetect:
            wb += 32;
            break;
        case ZlibFormat.raw:
            wb = -wb;
            break;
        }

        auto stream = new Stream();

        const res = (() @trusted => inflateInit2(&stream.strm, wb))();

        enforce(
            res == Z_OK,
            "Could not initialize Zlib's inflate stream: " ~ zResultToString(res)
        );

        if (gzHeaderDg)
        {
            stream.gzh = new Gzh(gzHeaderDg);
            (() @trusted => inflateGetHeader(&stream.strm, &stream.gzh.gzh))();
        }

        return stream;
    }

    package Flag!"streamEnded" process(Stream stream, Flag!"lastChunk" /+ lastChunk +/ ) @safe
    {
        const res = (() @trusted => squiz_box.c.zlib.inflate(&stream.strm, Z_NO_FLUSH))();
        //
        if (res == Z_DATA_ERROR)
            throw new DataException("Improper data given to inflate");

        enforce(
            res == Z_OK || res == Z_STREAM_END,
            "Zlib inflate failed with code: " ~ zResultToString(res)
        );

        auto gzh = stream.gzh;
        if (gzh && !gzh.dgCalled && gzh.gzh.done)
        {
            auto head = (() @trusted => GzHeader(&gzh.gzh))();
            gzh.dg(head);
            gzh.dgCalled = true;
        }

        return cast(Flag!"streamEnded")(res == Z_STREAM_END);
    }

    package void reset(Stream stream) @trusted
    {
        inflateReset(&stream.strm);
    }

    package void end(Stream stream) @trusted
    {
        inflateEnd(&stream.strm);
    }
}

///
@("Deflate / Inflate")
unittest
{
    import test.util;
    import std.array : join;

    auto def = Deflate.init;
    auto inf = Inflate.init;

    const len = 100_000;
    const phrase = cast(const(ubyte)[]) "Some very repetitive phrase.\n";
    const input = generateRepetitiveData(len, phrase).join();

    // deflating
    const squized = only(input).squiz(def).join();

    // re-inflating
    const output = only(squized).squiz(inf).join();

    assert(squized.length < input.length);
    assert(output == input);

    // for such long and repetitive data, ratio is around 0.3%
    const ratio = cast(double) squized.length / cast(double) input.length;
    assert(ratio < 0.004);
}

///
@("Deflate / Inflate in Gz format and custom header")
unittest
{
    import test.util;
    import std.array : join;

    const len = 100_000;
    const phrase = cast(const(ubyte)[]) "Some very repetitive phrase.\n";
    const input = generateRepetitiveData(len, phrase).join();

    GzHeader inHead;
    inHead.mtime = Clock.currTime;
    inHead.os = GzHeader.Os.fatFs;
    inHead.text = Yes.text;
    inHead.filename = "boring.txt";
    inHead.comment = "A very boring file";

    // deflating
    const squized = only(input)
        .deflateGz(inHead)
        .join();

    // re-inflating
    GzHeader outHead;
    int numCalls;
    void setOutHead(GzHeader gzh)
    {
        outHead = gzh;
        numCalls++;
    }

    const output = only(squized)
        .inflateGz(&setOutHead)
        .join();

    assert(squized.length < input.length);
    assert(output == input);
    assert(inHead == outHead);
    assert(numCalls == 1);
}

///
@("Deflate / Inflate in raw format")
unittest
{
    import test.util;
    import std.array : join;

    const len = 100_000;
    const phrase = cast(const(ubyte)[]) "Some very repetitive phrase.\n";
    const input = generateRepetitiveData(len, phrase).join();

    // deflating
    const squized = only(input)
        .deflateRaw()
        .join();

    // re-inflating
    const output = only(squized)
        .inflateRaw()
        .join();

    assert(squized.length < input.length);
    assert(output == input);
}

package string zResultToString(int res) @safe pure nothrow @nogc
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

package string zFlushToString(int flush) @safe pure nothrow @nogc
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

version (HaveSquizBzip2)
{

    /// Returns an InputRange containing the input data processed through Bzip2 compression.
    auto compressBzip2(I)(I input, size_t chunkSize = defaultChunkSize)
            if (isByteRange!I)
    {
        return squiz(input, CompressBzip2.init, chunkSize);
    }

    final class Bz2Stream : SquizStream
    {
        mixin ZlibLikeStreamImpl!(bz_stream);

        @property size_t totalInput() const @safe
        {
            ulong hi = strm.total_in_hi32;
            return cast(size_t)(
                (hi << 32) | strm.total_in_lo32
            );
        }

        @property size_t totalOutput() const @safe
        {
            ulong hi = strm.total_out_hi32;
            return cast(size_t)(
                (hi << 32) | strm.total_out_lo32
            );
        }

        this() @safe
        {
            strm.bzalloc = &(gcAlloc!int);
            strm.bzfree = &gcFree;
        }
    }

    /// Compression with the Bzip2 algorithm.
    ///
    /// Although having better compression capabilities than Zlib (deflate),
    /// Bzip2 has poor latenty when it comes to streaming.
    /// I.e. it can swallow several Mb of data before starting to produce output.
    /// If streaming latenty is an important factor, deflate/inflate
    /// should be the favorite algorithm.
    ///
    /// This algorithm does not support resource reuse, so calling reset
    /// is equivalent to a call to end followed by initialize.
    /// (but the same instance of stream is kept).
    struct CompressBzip2
    {
        static assert(isSquizAlgo!CompressBzip2);

        /// Advanced Bzip2 parameters
        /// See Bzip2 documentation
        /// https://www.sourceware.org/bzip2/manual/manual.html#bzcompress-init
        int blockSize100k = 9;
        /// ditto
        int verbosity = 0;
        /// ditto
        int workFactor = 30;

        alias Stream = Bz2Stream;

        Stream initialize() @safe
        {
            auto stream = new Stream;

            const res = (() @trusted => BZ2_bzCompressInit(
                    &stream.strm, blockSize100k, verbosity, workFactor,
            ))();
            enforce(
                res == BZ_OK,
                "Could not initialize Bzip2 compressor: " ~ bzResultToString(res)
            );
            return stream;
        }

        Flag!"streamEnded" process(Stream stream, Flag!"lastChunk" lastChunk) @safe
        {
            const action = lastChunk ? BZ_FINISH : BZ_RUN;
            const res = (() @trusted => BZ2_bzCompress(&stream.strm, action))();

            if (res == BZ_STREAM_END)
                return Yes.streamEnded;

            enforce(
                (action == BZ_RUN && res == BZ_RUN_OK) ||
                    (action == BZ_FINISH && res == BZ_FINISH_OK),
                    "Bzip2 compress failed with code: " ~ bzResultToString(res)
            );

            return No.streamEnded;
        }

        void reset(Stream stream) @safe
        {
            (() @trusted => BZ2_bzCompressEnd(&stream.strm))();

            stream.strm = bz_stream.init;
            stream.strm.bzalloc = &(gcAlloc!int);
            stream.strm.bzfree = &gcFree;

            const res = (() @trusted => BZ2_bzCompressInit(
                    &stream.strm, blockSize100k, verbosity, workFactor,
            ))();
            enforce(
                res == BZ_OK,
                "Could not initialize Bzip2 compressor: " ~ bzResultToString(res)
            );
        }

        void end(Stream stream) @trusted
        {
            BZ2_bzCompressEnd(&stream.strm);
        }
    }

    /// Returns an InputRange streaming over data decompressed with Bzip2.
    auto decompressBzip2(I)(I input, size_t chunkSize = defaultChunkSize)
            if (isByteRange!I)
    {
        return squiz(input, DecompressBzip2.init, chunkSize);
    }

    /// Decompression of data encoded with Bzip2.
    ///
    /// This algorithm does not support resource reuse, so calling reset
    /// is equivalent to a call to end followed by initialize.
    /// (but the same instance of stream is kept).
    struct DecompressBzip2
    {
        static assert(isSquizAlgo!DecompressBzip2);

        /// Advanced Bzip2 parameters
        /// See Bzip2 documentation
        /// https://www.sourceware.org/bzip2/manual/manual.html#bzDecompress-init
        int verbosity;
        /// ditto
        bool small;

        alias Stream = Bz2Stream;

        Stream initialize() @safe
        {
            auto stream = new Stream;

            const res = (() @trusted => BZ2_bzDecompressInit(
                    &stream.strm, verbosity, small ? 1 : 0,
            ))();
            enforce(
                res == BZ_OK,
                "Could not initialize Bzip2 decompressor: " ~ bzResultToString(res)
            );
            return stream;
        }

        Flag!"streamEnded" process(Stream stream, Flag!"lastChunk") @safe
        {
            const res = (() @trusted => BZ2_bzDecompress(&stream.strm))();

            if (res == BZ_DATA_ERROR)
                throw new DataException("Input data was not compressed with Bzip2");

            enforce(
                res == BZ_OK || res == BZ_STREAM_END,
                "Bzip2 decompress failed with code: " ~ bzResultToString(res)
            );

            return cast(Flag!"streamEnded")(res == BZ_STREAM_END);
        }

        void reset(Stream stream) @safe
        {
            (() @trusted => BZ2_bzDecompressEnd(&stream.strm))();

            stream.strm = bz_stream.init;
            stream.strm.bzalloc = &(gcAlloc!int);
            stream.strm.bzfree = &gcFree;

            const res = (() @trusted => BZ2_bzDecompressInit(
                    &stream.strm, verbosity, small ? 1 : 0,
            ))();
            enforce(
                res == BZ_OK,
                "Could not initialize Bzip2 decompressor: " ~ bzResultToString(res)
            );
        }

        void end(Stream stream) @trusted
        {
            BZ2_bzDecompressEnd(&stream.strm);
        }
    }

    ///
    @("Compress / Decompress Bzip2")
    unittest
    {
        import test.util;
        import std.array : join;

        const len = 100_000;
        const phrase = cast(const(ubyte)[]) "Some very repetitive phrase.\n";
        const input = generateRepetitiveData(len, phrase).join();

        const squized = only(input)
            .compressBzip2()
            .join();

        const output = only(squized)
            .decompressBzip2()
            .join();

        assert(squized.length < input.length);
        assert(output == input);

        // for such long and repetitive data, ratio is around 0.12%
        const ratio = cast(double) squized.length / cast(double) input.length;
        assert(ratio < 0.002);
    }

    private string bzActionToString(int action) @safe pure nothrow @nogc
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

    private string bzResultToString(int res) @safe pure nothrow @nogc
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
}

version (HaveSquizLzma)
{
    import std.sumtype;

    /// Filters to use with for the LZMA compression.
    ///
    /// Up to 4 filters can be used from this list,
    /// the last one being generally the compression filter.
    ///
    /// The delta and BCJ filters transform the input to increase
    /// redundancy of the data supplied to the LZMA compression.
    ///
    /// Compression with preset and advanced filters are essentially the same thing.
    /// Preset filters are used to setup an advanced filter in an easier way.
    alias LzmaFilter = SumType!(
        LzmaDeltaFilter,
        LzmaBcjFilter,
        Lzma1PresetFilter,
        Lzma2PresetFilter,
        Lzma1AdvancedFilter,
        Lzma2AdvancedFilter,
        LzmaRawFilter,
    );

    /// Delta filter, which store differences between bytes
    /// to produce more repetitive data in some circumstances.
    struct LzmaDeltaFilter
    {
        /// The distance between two successive byte pattern for the delta filter.
        /// Must be between 1 and 256.
        /// e.g.:
        ///  - should be 3 for raw RGB data
        ///  - should be 4 for raw 16bit PCM stereo data
        uint dist;

        @property inout(LzmaFilter) into() inout
        {
            return LzmaFilter(this);
        }
    }

    /// BCJ (Branch/Call/Jump) filters aim optimize machine code
    /// compression by converting relative branches, calls and jumps
    /// to absolute addresses. This increases redundancy and can be
    /// exploited by the LZMA compression.
    ///
    /// BCJ filters are available for a set of CPU architectures.
    /// Use one (or two) of them when compressing compiled binaries.
    struct LzmaBcjFilter
    {
        enum Arch
        {
            x86 = 0x04,
            powerPc = 0x05,
            ia64 = 0x06,
            arm = 0x07,
            armThumb = 0x08,
            sparc = 0x09,
        }

        Arch arch;
        uint startOffset;

        @property inout(LzmaFilter) into() inout
        {
            return LzmaFilter(this);
        }
    }

    mixin template LzmaPresetOptions()
    {
        /// The compression preset between 0 (fast) to 9 (higher compression).
        /// The default is 6.
        uint preset = 6;

        /// Makes the encoding significantly slower for marginal compression
        /// improvement. Only useful if you don't mind about CPU time at all.
        Flag!"extreme" extreme;
    }

    /// Legacy LZMA compression (aka. LZMA1).
    /// Setup is made easy with a preset between 0 and 9.
    struct Lzma1PresetFilter
    {
        mixin LzmaPresetOptions!();

        @property inout(LzmaFilter) into() inout
        {
            return LzmaFilter(this);
        }
    }

    /// LZMA compression (aka. LZMA2).
    /// Setup is made easy with a preset between 0 and 9.
    struct Lzma2PresetFilter
    {
        mixin LzmaPresetOptions!();

        @property inout(LzmaFilter) into() inout
        {
            return LzmaFilter(this);
        }
    }

    /+
     + Advanced filter parameters
     +/

    /// Match finder has major effect on both speed and compression ratio.
    /// Usually hash chains are faster than binary trees.
    ///
    /// If you will use LZMA_SYNC_FLUSH often, the hash chains may be a better
    /// choice, because binary trees get much higher compression ratio penalty
    /// with LZMA_SYNC_FLUSH.
    ///
    /// The memory usage formulas are only rough estimates, which are closest to
    /// reality when dict_size is a power of two. The formulas are  more complex
    /// in reality, and can also change a little between liblzma versions. Use
    /// lzma_raw_encoder_memusage() to get more accurate estimate of memory usage.
    enum LzmaMatchFinder
    {
        /// Hash Chain with 2- and 3-byte hashing
        ///
        /// Minimum nice_len: 3
        ///
        /// Memory usage:
        ///  - dict_size <= 16 MiB: dict_size * 7.5
        ///  - dict_size > 16 MiB: dict_size * 5.5 + 64 MiB
        hc3 = 0x03,
        /// Hash Chain with 2-, 3-, and 4-byte hashing
        /// Minimum nice_len: 4
        /// Memory usage:
        ///  - dict_size <= 32 MiB: dict_size * 7.5
        ///  - dict_size > 32 MiB: dict_size * 6.5
        hc4 = 0x04,
        /// Binary Tree with 2-byte hashing
        /// Minimum nice_len: 2
        /// Memory usage: dict_size * 9.5
        bt2 = 0x12,
        /// Binary Tree with 2- and 3-byte hashing
        /// Minimum nice_len: 3
        /// Memory usage:
        ///  - dict_size <= 16 MiB: dict_size * 11.5
        ///  - dict_size > 16 MiB: dict_size * 9.5 + 64 MiB
        bt3 = 0x13,
        /// Binary Tree with 2-, 3-, and 4-byte hashing
        /// Minimum nice_len: 4
        /// Memory usage:
        ///  - dict_size <= 32 MiB: dict_size * 11.5
        ///  - dict_size > 32 MiB: dict_size * 10.5
        bt4 = 0x14,
    }

    @property bool isMatchFinderSupported(LzmaMatchFinder mf)
    {
        return lzma_mf_is_supported(cast(lzma_match_finder) mf);
    }

    /// Compression mode
    ///
    /// This will select the function used to analyze the data
    /// produced by the match finder
    enum LzmaMode
    {
        /// Fast compression
        ///
        /// Fast mode is usually at its best when combined with
        /// a hash chain match finder.
        fast = 1,
        /// Normal compression
        ///
        /// This is usually notably slower than fast mode. Use this
        /// together with binary tree match finders to expose the
        /// full potential of the LZMA1 or LZMA2 encoder.
        normal = 2,
    }

    @property bool isModeSupported(LzmaMode mode)
    {
        return lzma_mode_is_supported(cast(lzma_mode) mode);
    }

    mixin template LzmaAdvancedOptions()
    {
        /// Dictionary size in bytes
        ///
        /// Dictionary size indicates how many bytes of the recently processed
        /// uncompressed data is kept in memory. One method to reduce size of
        /// the uncompressed data is to store distance-length pairs, which
        /// indicate what data to repeat from the dictionary buffer. Thus,
        /// the bigger the dictionary, the better the compression ratio
        /// usually is.
        ///
        /// Maximum size of the dictionary depends on multiple things:
        ///  - Memory usage limit
        ///  - Available address space (not a problem on 64-bit systems)
        ///  - Selected match finder (encoder only)
        ///
        /// Currently the maximum dictionary size for encoding is 1.5 GiB
        /// (i.e. (UINT32_C(1) << 30) + (UINT32_C(1) << 29)) even on 64-bit
        /// systems for certain match finder implementation reasons. In the
        /// future, there may be match finders that support bigger
        /// dictionaries.
        ///
        /// Decoder already supports dictionaries up to 4 GiB - 1 B (i.e.
        /// UINT32_MAX), so increasing the maximum dictionary size of the
        /// encoder won't cause problems for old decoders.
        ///
        /// Because extremely small dictionaries sizes would have unneeded
        /// overhead in the decoder, the minimum dictionary size is 4096 bytes.
        ///
        /// Note:        When decoding, too big dictionary does no other harm
        ///              than wasting memory.
        uint dictSize;

        /// An initial dictionary
        ///
        /// It is possible to initialize the LZ77 history window using
        /// a preset dictionary. It is useful when compressing many
        /// similar, relatively small chunks of data independently from
        /// each other. The preset dictionary should contain typical
        /// strings that occur in the files being compressed. The most
        /// probable strings should be near the end of the preset dictionary.
        ///
        /// This feature should be used only in special situations. For
        /// now, it works correctly only with raw encoding and decoding.
        /// Currently none of the container formats supported by
        /// liblzma allow preset dictionary when decoding, thus if
        /// you create a .xz or .lzma file with preset dictionary, it
        /// cannot be decoded with the regular decoder functions. In the
        /// future, the .xz format will likely get support for preset
        /// dictionary though.
        const(ubyte)[] presetDict;

        /// Number of literal context bits
        ///
        /// How many of the highest bits of the previous uncompressed
        /// eight-bit byte (also known as `literal') are taken into
        /// account when predicting the bits of the next literal.
        ///
        /// E.g. in typical English text, an upper-case letter is
        /// often followed by a lower-case letter, and a lower-case
        /// letter is usually followed by another lower-case letter.
        /// In the US-ASCII character set, the highest three bits are 010
        /// for upper-case letters and 011 for lower-case letters.
        /// When lc is at least 3, the literal coding can take advantage of
        /// this property in the uncompressed data.
        ///
        /// There is a limit that applies to literal context bits and literal
        /// position bits together: lc + lp <= 4. Without this limit the
        /// decoding could become very slow, which could have security related
        /// results in some cases like email servers doing virus scanning.
        /// This limit also simplifies the internal implementation in liblzma.
        ///
        /// There may be LZMA1 streams that have lc + lp > 4 (maximum possible
        /// lc would be 8). It is not possible to decode such streams with
        /// liblzma.
        uint lc;

        /// Number of literal position bits
        /// lp affects what kind of alignment in the uncompressed data is
        /// assumed when encoding literals. A literal is a single 8-bit byte.
        /// See pb below for more information about alignment.
        uint lp;

        /// Number of position bits
        /// pb affects what kind of alignment in the uncompressed data is
        /// assumed in general. The default means four-byte alignment
        /// (2^ pb =2^2=4), which is often a good choice when there's
        /// no better guess.
        ///
        /// When the alignment is known, setting pb accordingly may reduce
        /// the file size a little. E.g. with text files having one-byte
        /// alignment (US-ASCII, ISO-8859-*, UTF-8), setting pb=0 can
        /// improve compression slightly. For UTF-16 text, pb=1 is a good
        /// choice. If the alignment is an odd number like 3 bytes, pb=0
        /// might be the best choice.
        ///
        /// Even though the assumed alignment can be adjusted with pb and
        /// lp, LZMA1 and LZMA2 still slightly favor 16-byte alignment.
        /// It might be worth taking into account when designing file formats
        /// that are likely to be often compressed with LZMA1 or LZMA2.
        uint pb;

        /// The compression mode
        LzmaMode mode;

        /// The nice length of a match.
        ///
        /// This determines how many bytes the encoder compares from the match
        /// candidates when looking for the best match. Once a match of at
        /// least nice_len bytes long is found, the encoder stops looking for
        /// better candidates and encodes the match. (Naturally, if the found
        /// match is actually longer than nice_len, the actual length is
        /// encoded; it's not truncated to nice_len.)
        ///
        /// Bigger values usually increase the compression ratio and
        /// compression time. For most files, 32 to 128 is a good value,
        /// which gives very good compression ratio at good speed.
        ///
        /// The exact minimum value depends on the match finder. The maximum
        /// is 273, which is the maximum length of a match that LZMA1 and
        /// LZMA2 can encode.
        uint niceLen;

        /// The match finder.
        LzmaMatchFinder mf;

        /// Maximum search depth in the match finder
        ///
        /// For every input byte, match finder searches through the hash chain
        /// or binary tree in a loop, each iteration going one step deeper in
        /// the chain or tree. The searching stops if
        ///  - a match of at least nice_len bytes long is found;
        ///  - all match candidates from the hash chain or binary tree have
        ///    been checked; or
        ///  - maximum search depth is reached.
        ///
        /// Maximum search depth is needed to prevent the match finder from
        /// wasting too much time in case there are lots of short match
        /// candidates. On the other hand, stopping the search before all
        /// candidates have been checked can reduce compression ratio.
        ///
        /// Setting depth to zero tells liblzma to use an automatic default
        /// value, that depends on the selected match finder and nice_len.
        /// The default is in the range [4, 200] or so (it may vary between
        /// liblzma versions).
        ///
        /// Using a bigger depth value than the default can increase
        /// compression ratio in some cases. There is no strict maximum value,
        /// but high values (thousands or millions) should be used with care:
        /// the encoder could remain fast enough with typical input, but
        /// malicious input could cause the match finder to slow down
        /// dramatically, possibly creating a denial of service attack.
        uint depth;
    }

    /// Advanced parameters for Legacy LZMA compression
    struct Lzma1AdvancedFilter
    {
        mixin LzmaAdvancedOptions!();

        @property inout(LzmaFilter) into() inout
        {
            return LzmaFilter(this);
        }
    }

    /// Advanced parameters for LZMA compression
    struct Lzma2AdvancedFilter
    {
        mixin LzmaAdvancedOptions!();

        @property inout(LzmaFilter) into() inout
        {
            return LzmaFilter(this);
        }
    }

    /// Raw LZMA filter with encoded properties.
    /// This is used e.g. in the *.7z archive format.
    struct LzmaRawFilter
    {
        enum Id
        {
            delta = 0x03,
            bcjX86 = 0x04,
            bcjPowerPc = 0x05,
            bcjIa64 = 0x06,
            bcjArm = 0x07,
            bcjArmThumb = 0x08,
            bcjSparc = 0x09,
            lzma1 = 0x11,
            lzma2 = 0x21,
        }

        Id id;
        const(ubyte)[] props;

        /// construction helper
        static LzmaRawFilter delta(const(ubyte)[] props)
        {
            return LzmaRawFilter(LzmaRawFilter.Id.delta, props);
        }

        /// ditto
        static LzmaRawFilter bcjX86(const(ubyte)[] props)
        {
            return LzmaRawFilter(LzmaRawFilter.Id.bcjX86, props);
        }

        /// ditto
        static LzmaRawFilter bcjPowerPc(const(ubyte)[] props)
        {
            return LzmaRawFilter(LzmaRawFilter.Id.bcjPowerPc, props);
        }

        /// ditto
        static LzmaRawFilter bcjIa64(const(ubyte)[] props)
        {
            return LzmaRawFilter(LzmaRawFilter.Id.bcjIa64, props);
        }

        /// ditto
        static LzmaRawFilter bcjArm(const(ubyte)[] props)
        {
            return LzmaRawFilter(LzmaRawFilter.Id.bcjArm, props);
        }

        /// ditto
        static LzmaRawFilter bcjArmThumb(const(ubyte)[] props)
        {
            return LzmaRawFilter(LzmaRawFilter.Id.bcjArmThumb, props);
        }

        /// ditto
        static LzmaRawFilter bcjSparc(const(ubyte)[] props)
        {
            return LzmaRawFilter(LzmaRawFilter.Id.bcjSparc, props);
        }

        /// ditto
        static LzmaRawFilter lzma1(const(ubyte)[] props)
        {
            return LzmaRawFilter(LzmaRawFilter.Id.lzma1, props);
        }

        /// ditto
        static LzmaRawFilter lzma2(const(ubyte)[] props)
        {
            return LzmaRawFilter(LzmaRawFilter.Id.lzma2, props);
        }

        @property inout(LzmaFilter) into() inout
        {
            return LzmaFilter(this);
        }
    }

    bool isCompressionFilter(LzmaFilter filter) @safe
    {
        // dfmt off
        return filter.match!(
            (LzmaDeltaFilter f) => false,
            (LzmaBcjFilter f) => false,
            (Lzma1PresetFilter f) => true,
            (Lzma2PresetFilter f) => true,
            (Lzma1AdvancedFilter f) => true,
            (Lzma2AdvancedFilter f) => true,
            (LzmaRawFilter f) {
                switch (f.id)
                {
                case LzmaRawFilter.Id.lzma1:
                case LzmaRawFilter.Id.lzma2:
                    return true;
                default:
                    return false;
                }
            },
        );
        // dfmt on
    }

    private lzma_options_lzma* lzmaPresetToOptions(F)(F filter)
    {
        lzma_options_lzma* opts = new lzma_options_lzma;

        uint preset = filter.preset;
        if (filter.extreme)
            preset |= LZMA_PRESET_EXTREME;

        enforce(!lzma_lzma_preset(opts, preset), "unsupported LZMA preset");

        return opts;
    }

    private lzma_options_lzma* lzmaAdvancedToOptions(F)(F filter)
    {
        enforce(isMatchFinderSupported(filter.mf), "unsupported LZMA match finder");
        enforce(isModeSupported(filter.mode), "unsupported LZMA mode");

        lzma_options_lzma* opts = new lzma_options_lzma;

        opts.dict_size = filter.dictSize;
        if (filter.presetDict.length)
        {
            opts.preset_dict = &filter.presetDict[0];
            opts.preset_dict_size = cast(uint) filter.presetDict.length;
        }
        opts.lc = filter.lc;
        opts.lp = filter.lp;
        opts.pb = filter.pb;
        opts.mode = cast(lzma_mode) filter.mode;
        opts.nice_len = filter.niceLen;
        opts.mf = cast(lzma_match_finder) filter.mf;
        opts.depth = filter.depth;

        return opts;
    }

    package(squiz_box) lzma_filter toLzma(LzmaFilter filter) @trusted
    {
        // dfmt off
        return filter.match!(
            (LzmaDeltaFilter delta) {
               lzma_options_delta* opt = new lzma_options_delta;
                opt.type = lzma_delta_type.LZMA_DELTA_TYPE_BYTE;
                opt.dist = delta.dist;
                return lzma_filter(LZMA_FILTER_DELTA, cast(void*) opt);
            },
            (LzmaBcjFilter bcj) {
                lzma_options_bcj* opt = new lzma_options_bcj;
                opt.start_offset = bcj.startOffset;
                const vli = cast(lzma_vli)(bcj.arch);
                return lzma_filter(vli, cast(void*) opt);
            },
            (Lzma1PresetFilter f) {
                auto opts = lzmaPresetToOptions(f);
                return lzma_filter(LZMA_FILTER_LZMA1, cast(void*)opts);
            },
            (Lzma2PresetFilter f) {
                auto opts = lzmaPresetToOptions(f);
                return lzma_filter(LZMA_FILTER_LZMA2, cast(void*)opts);
            },
            (Lzma1AdvancedFilter f) {
                auto opts = lzmaAdvancedToOptions(f);
                return lzma_filter(LZMA_FILTER_LZMA1, cast(void*)opts);
            },
            (Lzma2AdvancedFilter f) {
                auto opts = lzmaAdvancedToOptions(f);
                return lzma_filter(LZMA_FILTER_LZMA2, cast(void*)opts);
            },
            (LzmaRawFilter f) {
                lzma_filter res;
                final switch (f.id)
                {
                case LzmaRawFilter.Id.delta:
                    res.id = LZMA_FILTER_DELTA;
                    break;
                case LzmaRawFilter.Id.bcjX86:
                    res.id = LZMA_FILTER_X86;
                    break;
                case LzmaRawFilter.Id.bcjPowerPc:
                    res.id = LZMA_FILTER_POWERPC;
                    break;
                case LzmaRawFilter.Id.bcjIa64:
                    res.id = LZMA_FILTER_IA64;
                    break;
                case LzmaRawFilter.Id.bcjArm:
                    res.id = LZMA_FILTER_ARM;
                    break;
                case LzmaRawFilter.Id.bcjArmThumb:
                    res.id = LZMA_FILTER_ARMTHUMB;
                    break;
                case LzmaRawFilter.Id.bcjSparc:
                    res.id = LZMA_FILTER_SPARC;
                    break;
                case LzmaRawFilter.Id.lzma1:
                    res.id = LZMA_FILTER_LZMA1;
                    break;
                case LzmaRawFilter.Id.lzma2:
                    res.id = LZMA_FILTER_LZMA2;
                    break;
                }
                lzma_allocator alloc;
                alloc.alloc = &(gcAlloc!size_t);
                alloc.free = &gcFree;
                const ptr = f.props.length ? &f.props[0] : null;
                lzma_properties_decode(&res, &alloc, ptr, f.props.length);
                return res;
            }
        );
        // dfmt on
    }

    private lzma_filter[] buildFilterChain(LzmaFilter[] filters) @safe
    {
        enforce(filters.length < 5, "Too large LZMA filter chain (maximum is 4)");

        lzma_filter[] res = new lzma_filter[5];

        foreach (i; 0 .. filters.length)
            res[i] = toLzma(filters[i]);

        foreach (i; filters.length .. 5)
            res[i].id = LZMA_VLI_UNKNOWN;

        return res;
    }

    final class LzmaStream : SquizStream
    {
        mixin ZlibLikeStreamImpl!(lzma_stream);
        mixin ZlibLikeTotalInOutImpl!();

        private lzma_allocator alloc;
        private lzma_filter[] filterChain;

        this() @safe
        {
            alloc.alloc = &(gcAlloc!size_t);
            alloc.free = &gcFree;
            strm.allocator = &alloc;
        }
    }

    /// Header/trailer format for Lzma compression
    enum LzmaFormat
    {
        /// Xz file format, suitable to write *.xz files
        xz,
        /// Legacy LZMA file format, suitable for *.lzma files
        /// This format doesn't support filters.
        legacy,
        /// Raw format, without header/trailer.
        /// Use this to include compressed LZMA data in
        /// a container defined externally (e.g. this is used
        /// for the *.7z archives)
        raw,
    }

    /// Integrity check to include in the compressed data
    /// (only for the Xz format)
    /// Default for xz is CRC-64.
    enum LzmaCheck
    {
        /// No integrity check included
        none,
        /// CRC-32 integrity check
        crc32,
        /// CRC-64 integrity check
        crc64,
        /// SHA-256 integrity check
        sha256,
    }

    private lzma_check toLzma(LzmaCheck check) @safe pure nothrow @nogc
    {
        final switch (check)
        {
        case LzmaCheck.none:
            return lzma_check.NONE;
        case LzmaCheck.crc32:
            return lzma_check.CRC32;
        case LzmaCheck.crc64:
            return lzma_check.CRC64;
        case LzmaCheck.sha256:
            return lzma_check.SHA256;
        }
    }

    auto compressXz(I)(I input, size_t chunkSize = defaultChunkSize)
    {
        return squiz(input, CompressLzma.init, chunkSize);
    }

    auto compressLzmaRaw(I)(I input, LzmaFilter[] filters, size_t chunkSize = defaultChunkSize)
    {
        CompressLzma algo;
        algo.format = LzmaFormat.raw;
        algo.filters = filters;
        return squiz(input, algo, chunkSize);
    }

    struct CompressLzma
    {
        import std.conv : to;

        static assert(isSquizAlgo!CompressLzma);

        /// The format of the compressed stream
        LzmaFormat format;

        /// Filters to include in the encoding, including the compression filter.
        /// Maximum four filters can be provided.
        /// For Xz format, if this array has no compression filter, a LZMA2 filter will be appended.
        /// For Raw format, the programmer has the responsibility to set all the filters correctly.
        /// Not supported by the legacy format
        LzmaFilter[] filters;

        /// The integrity check to include in compressed stream.
        /// Only used with XZ format.
        LzmaCheck check = LzmaCheck.crc64;

        /// Compression preset used for the legacy format
        uint legacyPreset = 6;

        alias Stream = LzmaStream;

        private void initStream(Stream stream) @trusted
        {
            import std.algorithm : any;

            lzma_ret res;
            final switch (format)
            {
            case LzmaFormat.xz:
                LzmaFilter[] chain;
                if (!filters.any!(f => f.isCompressionFilter()))
                    chain = filters.dup ~ LzmaFilter(Lzma2PresetFilter(6));
                else
                    chain = filters;

                const lzmaChain = buildFilterChain(chain);
                res = lzma_stream_encoder(&stream.strm, lzmaChain.ptr, check.toLzma());
                break;
            case LzmaFormat.legacy:
                enforce(filters.length == 0, "Filters are not supported with the legacy format");
                enforce(legacyPreset >= 1 && legacyPreset <= 9);
                auto opts = new lzma_options_lzma;
                lzma_lzma_preset(opts, legacyPreset);
                res = lzma_alone_encoder(&stream.strm, opts);
                break;
            case LzmaFormat.raw:
                const lzmaChain = buildFilterChain(filters);
                res = lzma_raw_encoder(&stream.strm, lzmaChain.ptr);
                break;
            }

            enforce(res == lzma_ret.OK, "Could not initialize LZMA encoder: ", res.to!string);
        }

        Stream initialize() @safe
        {
            auto stream = new LzmaStream;
            initStream(stream);
            return stream;
        }

        Flag!"streamEnded" process(Stream stream, Flag!"lastChunk" lastChunk) @safe
        {
            return lzmaCode(stream, lastChunk);
        }

        void reset(Stream stream) @safe
        {
            // Lzma supports reset out of the box by recalling initialization
            // function without calling lzma_end.

            initStream(stream);
        }

        void end(Stream stream) @trusted
        {
            lzma_end(&stream.strm);
        }
    }

    auto decompressXz(I)(I input, size_t chunkSize = defaultChunkSize)
    {
        return squiz(input, DecompressLzma.init, chunkSize);
    }

    auto decompressLzmaRaw(I)(I input, LzmaFilter[] filters, size_t chunkSize = defaultChunkSize)
    {
        DecompressLzma algo;
        algo.format = LzmaFormat.raw;
        algo.rawFilters = filters;
        return squiz(input, algo, chunkSize);
    }

    struct DecompressLzma
    {
        import std.conv : to;

        static assert(isSquizAlgo!DecompressLzma);

        /// The format of the compressed stream
        LzmaFormat format;

        /// Filters for the raw decompression.
        /// As there is no header to tell Lzma what filters were used during
        /// compression, it is the responsibility of the programmer to
        /// correctly ensure that the same options are used for decompression.
        /// Ignored when decompressing .xz stream.
        LzmaFilter[] rawFilters;

        /// The memory usage limit in bytes.
        /// by default no limit is enforced
        size_t memLimit = size_t.max;

        alias Stream = LzmaStream;

        this(LzmaFormat format, size_t memLimit = size_t.max) @safe
        {
            this.format = format;
            this.memLimit = memLimit;
        }

        /// convenience constructor to copy parameters of the compression
        /// for the decompression. Especially useful for the raw decompression,
        /// to ensure that the parameters fit the ones used for compression.
        this(CompressLzma compress, size_t memLimit = size_t.max) @safe
        {
            this.format = compress.format;
            this.rawFilters = compress.filters;
            this.memLimit = memLimit;
        }

        /// Builds a raw decompression algorithm with the provided filters
        this(LzmaFilter[] rawFilters, size_t memLimit = size_t.max)
        {
            this.format = LzmaFormat.raw;
            this.rawFilters = rawFilters;
            this.memLimit = memLimit;
        }

        private void initStream(Stream stream) @trusted
        {
            ulong memlim = memLimit;
            if (memLimit == size_t.max)
                memlim = ulong.max;

            lzma_ret res;

            final switch (format)
            {
            case LzmaFormat.xz:
                res = lzma_stream_decoder(&stream.strm, memlim, 0);
                break;
            case LzmaFormat.legacy:
                res = lzma_alone_decoder(&stream.strm, memlim);
                break;
            case LzmaFormat.raw:
                const chain = buildFilterChain(rawFilters);
                res = lzma_raw_decoder(&stream.strm, chain.ptr);
                break;
            }

            enforce(res == lzma_ret.OK, "Could not initialize LZMA encoder: " ~ res.to!string);
        }

        Flag!"streamEnded" process(Stream stream, Flag!"lastChunk" lastChunk) @safe
        {
            return lzmaCode(stream, lastChunk);
        }

        Stream initialize() @safe
        {
            auto stream = new LzmaStream;
            initStream(stream);
            return stream;
        }

        void reset(Stream stream) @safe
        {
            // Lzma supports reset out of the box by recalling initialization
            // function without calling lzma_end.

            initStream(stream);
        }

        void end(Stream stream) @trusted
        {
            lzma_end(&stream.strm);
        }
    }

    private Flag!"streamEnded" lzmaCode(LzmaStream stream, Flag!"lastChunk" lastChunk) @safe
    {
        import std.conv : to;

        const action = lastChunk ? lzma_action.FINISH : lzma_action.RUN;
        const res = (() @trusted => lzma_code(&stream.strm, action))();

        enforce(
            res == lzma_ret.OK || res == lzma_ret.STREAM_END,
            "LZMA encoding failed with code: " ~ res.to!string
        );

        return cast(Flag!"streamEnded")(res == lzma_ret.STREAM_END);
    }

    ///
    @("Compress / Decompress XZ")
    unittest
    {
        import test.util;
        import std.array : join;

        const len = 100_000;
        const phrase = cast(const(ubyte)[]) "Some very repetitive phrase.\n";
        const input = generateRepetitiveData(len, phrase).join();

        const squized = only(input)
            .compressXz()
            .join();

        const output = only(squized)
            .decompressXz()
            .join();

        assert(squized.length < input.length);
        assert(output == input);

        // for such long and repetitive data, ratio is around 0.2%
        const ratio = cast(double) squized.length / cast(double) input.length;
        assert(ratio < 0.003);
    }

    ///
    @("Integrity check XZ")
    unittest
    {
        import test.util;
        import std.array : join;

        const len = 100_000;
        const phrase = cast(const(ubyte)[]) "Some very repetitive phrase.\n";
        const input = generateRepetitiveData(len, phrase).join();

        auto squized = only(input)
            .compressXz()
            .join()
            .dup; // dup because const(ubyte)[] is returned

        squized[squized.length / 2] += 1;

        assertThrown(
            only(squized)
                .decompressXz()
                .join()
        );
    }

    ///
    @("Compress / Decompress XZ with filter")
    unittest
    {
        import test.util;
        import std.array : join;

        const len = 100_000;
        const input = generateSequentialData(len, 1245, 27).join();

        const reference = only(input)
            .compressXz()
            .join();

        CompressLzma comp;
        comp.filters ~= LzmaFilter(LzmaDeltaFilter(8)); // sequential data of 8 byte integers

        const withDelta = only(input)
            .squiz(comp)
            .join();

        const output = only(withDelta)
            .decompressXz()
            .join();

        assert(output == input);
        // < 20% compression without filter (sequential data is tough)
        // < 0.5% compression with delta (peace of cake)
        assert(input.length > reference.length * 5);
        assert(input.length > withDelta.length * 200);
    }

    ///
    @("Compress / Decompress Lzma Raw")
    unittest
    {
        import test.util;
        import std.array : join;

        const len = 100_000;
        const phrase = cast(const(ubyte)[]) "Some very repetitive phrase.\n";
        const input = generateRepetitiveData(len, phrase).join();

        const reference = only(input)
            .compressXz()
            .join();

        auto filters = [LzmaFilter(Lzma2PresetFilter())];

        const squized = only(input)
            .compressLzmaRaw(filters)
            .join();

        const output = only(squized)
            .decompressLzmaRaw(filters)
            .join();

        assert(output == input);
        assert(squized.length < input.length);
        assert(squized.length < reference.length); // win header/trailer space

        // for such repetitive data, ratio is around 1.13%
        // also generally better than zlib, bzip2 struggles a lot for repetitive data
        const ratio = cast(double) squized.length / cast(double) input.length;
        assert(ratio < 0.003);
    }

    ///
    @("Compress / Decompress Lzma Raw with filter")
    unittest
    {
        import test.util;
        import std.array : join;

        const len = 100_000;
        const input = generateSequentialData(len, 1245, 27).join();

        const reference = only(input)
            .compressLzmaRaw([LzmaFilter(Lzma2PresetFilter())])
            .join();

        CompressLzma comp;
        comp.format = LzmaFormat.raw;
        comp.filters = [
            LzmaFilter(LzmaDeltaFilter(8)), // sequential data of 8 byte integers
            LzmaFilter(Lzma2PresetFilter()),
        ];

        const withDelta = only(input)
            .squiz(comp)
            .join();

        const output = only(withDelta) // using compression parameters for decompression
            .squiz(DecompressLzma(comp))
            .join();

        assert(output == input);
        // < 20% compression without filter (sequential data is tough)
        // < 0.4% compression with delta (peace of cake)
        assert(input.length > reference.length * 5);
        assert(input.length > withDelta.length * 250);
    }

    ///
    @("Compress / Decompress Lzma Legacy")
    unittest
    {
        import test.util;
        import std.array : join;

        const len = 100_000;
        const phrase = cast(const(ubyte)[]) "Some very repetitive phrase.\n";
        const input = generateRepetitiveData(len, phrase).join();

        auto comp = CompressLzma(LzmaFormat.legacy);
        auto decomp = DecompressLzma(comp);

        const squized = only(input)
            .squiz(comp)
            .join();

        const output = only(squized)
            .squiz(decomp)
            .join();

        assert(squized.length < input.length);
        assert(output == input);

        // for such repetitive data, ratio is around 1.13%
        // also generally better than zlib, bzip2 struggles a lot for repetitive data
        const ratio = cast(double) squized.length / cast(double) input.length;
        assert(ratio < 0.003);
    }

    ///
    @("Compress / Decompress Lzma Raw Legacy")
    unittest
    {
        import test.util;
        import std.array : join;

        const len = 100_000;
        const phrase = cast(const(ubyte)[]) "Some very repetitive phrase.\n";
        const input = generateRepetitiveData(len, phrase).join();

        CompressLzma comp;
        comp.format = LzmaFormat.raw;
        comp.filters = [LzmaFilter(Lzma1PresetFilter())];

        auto decomp = DecompressLzma(comp);

        const squized = only(input)
            .squiz(comp)
            .join();

        const output = only(squized)
            .squiz(decomp)
            .join();

        assert(squized.length < input.length);
        assert(output == input);

        // for such repetitive data, ratio is around 1.13%
        // also generally better than zlib, bzip2 struggles a lot for repetitive data
        const ratio = cast(double) squized.length / cast(double) input.length;
        assert(ratio < 0.003);
    }

    ///
    @("Compress / Decompress Lzma rawLegacy with filter")
    unittest
    {
        import test.util;
        import std.array : join;

        const len = 100_000;
        const input = generateSequentialData(len, 1245, 27).join();

        const reference = only(input)
            .squiz(CompressLzma(LzmaFormat.legacy))
            .join();

        CompressLzma comp;
        comp.format = LzmaFormat.raw;
        comp.filters = [
            LzmaFilter(LzmaDeltaFilter(8)), // sequential data of 8 byte integers
            LzmaFilter(Lzma1PresetFilter()),
        ];

        auto decomp = DecompressLzma(comp);

        const withDelta = only(input)
            .squiz(comp)
            .join();

        const output = only(withDelta)
            .squiz(decomp)
            .join();

        assert(output == input);
        // < 20% compression without filter (sequential data is tough)
        // < 0.4% compression with delta (peace of cake)
        assert(input.length > reference.length * 5);
        assert(input.length > withDelta.length * 250);
    }
}

version (HaveSquizZstandard)
{
    auto compressZstd(I)(I input, size_t chunkSize = defaultChunkSize)
    {
        return squiz(input, CompressZstd.init, chunkSize);
    }

    auto decompressZstd(I)(I input, size_t chunkSize = defaultChunkSize)
    {
        return squiz(input, DecompressZstd.init, chunkSize);
    }

    class ZstdStream : SquizStream
    {
        private ZSTD_inBuffer inBuf;
        private ZSTD_outBuffer outBuf;
        private size_t totalIn;
        private size_t totalOut;

        @property const(ubyte)[] input() const @trusted
        {
            auto ptr = cast(const(ubyte)*) inBuf.src;
            return ptr[inBuf.pos .. inBuf.size];
        }

        @property void input(const(ubyte)[] inp) @trusted
        {
            totalIn += inBuf.pos;
            inBuf.pos = 0;
            inBuf.src = cast(const(void)*) inp.ptr;
            inBuf.size = inp.length;
        }

        @property size_t totalInput() const @safe
        {
            return totalIn + inBuf.pos;
        }

        @property inout(ubyte)[] output() inout @trusted
        {
            auto ptr = cast(inout(ubyte)*) outBuf.dst;
            return ptr[outBuf.pos .. outBuf.size];
        }

        @property void output(ubyte[] outp) @trusted
        {
            totalOut += outBuf.pos;
            outBuf.pos = 0;
            outBuf.dst = cast(void*) outp.ptr;
            outBuf.size = outp.length;
        }

        @property size_t totalOutput() const @safe
        {
            return totalOut + outBuf.pos;
        }

        override string toString() const @safe
        {
            import std.format : format;

            string res;
            res ~= "ZstdStream:\n";
            res ~= "  Input:\n";
            res ~= format!"    start 0x%016x\n"(inBuf.src);
            res ~= format!"    pos %s\n"(inBuf.pos);
            res ~= format!"    size %s\n"(inBuf.size);
            res ~= format!"    total %s\n"(totalInput);
            res ~= "  Output:\n";
            res ~= format!"    start 0x%016x\n"(outBuf.dst);
            res ~= format!"    pos %s\n"(outBuf.pos);
            res ~= format!"    size %s\n"(outBuf.size);
            res ~= format!"    total %s"(totalOutput);

            return res;
        }
    }

    private string zstdSetCParam(string name)
    {
        return "if (" ~ name ~ ") " ~
            "ZSTD_CCtx_setParameter(cctx, ZSTD_cParameter." ~ name ~ ", " ~ name ~ ");";
    }

    private void zstdError(size_t code, string desc) @trusted
    {
        import std.string : fromStringz;

        if (ZSTD_isError(code))
        {
            const msg = fromStringz(ZSTD_getErrorName(code));
            throw new Exception((desc ~ ": " ~ msg).idup);
        }
    }

    /// Zstandard is a fast compression algorithm designed for streaming.
    /// See zstd.h (enum ZSTD_cParameter) for details.
    struct CompressZstd
    {
        static assert(isSquizAlgo!CompressZstd);

        /// Common paramters.
        /// A value of zero indicates that the default should be used.
        int compressionLevel;
        /// ditto
        int windowLog;
        /// ditto
        int hashLog;
        /// ditto
        int chainLog;
        /// ditto
        int searchLog;
        /// ditto
        int minMatch;
        /// ditto
        int targetLength;
        /// ditto
        int strategy;

        /// Long distance matching parameters (LDM)
        /// Can be activated for large inputs to improve the compression ratio.
        /// Increases memory usage and the window size
        /// A value of zero indicate that the default should be used.
        bool enableLongDistanceMatching;
        /// ditto
        int ldmHashLog;
        /// ditto
        int ldmMinMatch;
        /// ditto
        int ldmBucketSizeLog;
        /// ditto
        int ldmHashRateLog;

        // frame parameters

        /// If input data content size is known, before
        /// start of streaming, set contentSize to its value.
        /// It will enable the size to be written in the header
        /// and checked after decompression.
        ulong contentSize = ulong.max;
        /// Include a checksum of the content in the trailer.
        bool checksumFlag = false;
        /// When applicable, dictionary's ID is written in the header
        bool dictIdFlag = true;

        /// Multi-threading parameters
        int nbWorkers;
        /// ditto
        int jobSize;
        /// ditto
        int overlapLog;

        static final class Stream : ZstdStream
        {
            private ZSTD_CStream* strm;
        }

        private void setParams(Stream stream) @trusted
        {
            auto cctx = cast(ZSTD_CCtx*) stream.strm;

            mixin(zstdSetCParam("compressionLevel"));
            mixin(zstdSetCParam("windowLog"));
            mixin(zstdSetCParam("hashLog"));
            mixin(zstdSetCParam("chainLog"));
            mixin(zstdSetCParam("searchLog"));
            mixin(zstdSetCParam("minMatch"));
            mixin(zstdSetCParam("targetLength"));
            mixin(zstdSetCParam("strategy"));

            if (enableLongDistanceMatching)
            {
                ZSTD_CCtx_setParameter(cctx,
                    ZSTD_cParameter.enableLongDistanceMatching,
                    1
                );

                mixin(zstdSetCParam("ldmHashLog"));
                mixin(zstdSetCParam("ldmMinMatch"));
                mixin(zstdSetCParam("ldmBucketSizeLog"));
                mixin(zstdSetCParam("ldmHashRateLog"));
            }

            if (contentSize != size_t.max)
                ZSTD_CCtx_setPledgedSrcSize(cctx, contentSize);
            if (checksumFlag)
                ZSTD_CCtx_setParameter(
                    cctx,
                    ZSTD_cParameter.checksumFlag,
                    1
                );
            if (!dictIdFlag)
                ZSTD_CCtx_setParameter(
                    cctx,
                    ZSTD_cParameter.checksumFlag,
                    0
                );

            mixin(zstdSetCParam("nbWorkers"));
            mixin(zstdSetCParam("jobSize"));
            mixin(zstdSetCParam("overlapLog"));
        }

        Stream initialize() @trusted
        {
            auto stream = new Stream;

            stream.strm = ZSTD_createCStream();

            setParams(stream);

            return stream;
        }

        Flag!"streamEnded" process(Stream stream, Flag!"lastChunk" lastChunk) @safe
        {
            auto cctx = cast(ZSTD_CCtx*) stream.strm;
            const directive = lastChunk ? ZSTD_EndDirective.end : ZSTD_EndDirective._continue;

            const res = (() @trusted => ZSTD_compressStream2(cctx, &stream.outBuf, &stream.inBuf, directive))();

            zstdError(res, "Could not compress data with Zstandard");
            return cast(Flag!"streamEnded")(lastChunk && res == 0);
        }

        void reset(Stream stream) @trusted
        {
            auto cctx = cast(ZSTD_CCtx*) stream.strm;
            ZSTD_CCtx_reset(cctx, ZSTD_ResetDirective.session_only);

            if (contentSize != size_t.max)
                ZSTD_CCtx_setPledgedSrcSize(cctx, contentSize);

            stream.inBuf = ZSTD_inBuffer.init;
            stream.outBuf = ZSTD_outBuffer.init;
            stream.totalIn = 0;
            stream.totalOut = 0;
        }

        void end(Stream stream) @trusted
        {
            ZSTD_freeCStream(stream.strm);
        }
    }

    struct DecompressZstd
    {
        static assert(isSquizAlgo!DecompressZstd);

        int windowLogMax;

        static final class Stream : ZstdStream
        {
            private ZSTD_DStream* strm;
        }

        private void setParams(Stream stream) @trusted
        {
            auto dctx = cast(ZSTD_DCtx*) stream.strm;

            if (windowLogMax)
                ZSTD_DCtx_setParameter(dctx,
                    ZSTD_dParameter.windowLogMax, windowLogMax);
        }

        Stream initialize() @trusted
        {
            auto stream = new Stream;

            stream.strm = ZSTD_createDStream();

            setParams(stream);

            return stream;
        }

        Flag!"streamEnded" process(Stream stream, Flag!"lastChunk") @safe
        {
            const res = (() @trusted => ZSTD_decompressStream(stream.strm, &stream.outBuf, &stream
                    .inBuf))();

            zstdError(res, "Could not decompress data with Zstandard");
            return cast(Flag!"streamEnded")(res == 0);
        }

        void reset(Stream stream) @trusted
        {
            auto dctx = cast(ZSTD_DCtx*) stream.strm;
            ZSTD_DCtx_reset(dctx, ZSTD_ResetDirective.session_only);
        }

        void end(Stream stream) @trusted
        {
            ZSTD_freeDStream(stream.strm);
        }
    }

    ///
    @("Compress / Decompress Zstandard")
    unittest
    {
        import test.util;
        import std.array : join;

        const len = 100_000;
        const phrase = cast(const(ubyte)[]) "Some very repetitive phrase.\n";
        const input = generateRepetitiveData(len, phrase).join();

        const squized = only(input)
            .compressZstd()
            .join();

        const output = only(squized)
            .decompressZstd()
            .join();

        assert(squized.length < input.length);
        assert(output == input);

        // for such long and repetitive data, ratio is around 0.047%
        const ratio = cast(double) squized.length / cast(double) input.length;
        assert(ratio < 0.0005);
    }

}
