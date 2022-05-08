/// Compression, decompression algorithms
///
/// Each compression or decompression algorithm is represented by a struct
/// that contains parameters for compression/decompression.
///
module squiz_box.squiz;

import squiz_box.c.zlib;
import squiz_box.core;
import squiz_box.priv;

import std.datetime.systime;
import std.exception;
import std.range;
import std.typecons;

/// Check whether a type is a proper squiz algorithm.
template isSquizAlgo(A)
{
    enum isSquizAlgo = is(typeof((A algo) {
                auto state = algo.initialize();
                Flag!"streamEnded" ended = algo.process(state, Yes.inputEmpty);
                algo.reset(state);
                algo.end(state);
                static assert(is(typeof(state) : SquizState));
                static assert(is(typeof(state) : SquizStream));
            }));
}

/// Get the type of a SquizState for the Squiz algorithm
template StateType(A) if (isSquizAlgo!A)
{
    import std.traits : ReturnType;

    alias StateType = ReturnType!(A.initialize);
}

/// A squiz algorithm whom type is erased behind an interface.
/// This helps to choose algorithm at run time.
interface SquizAlgo
{
    SquizState initialize();
    Flag!"streamEnded" process(SquizState, Flag!"inputEmpty");
    void reset(SquizState state);
    void end(SquizState state);
}

static assert(isSquizAlgo!SquizAlgo);

/// Runtime state for SquizAlgo
interface SquizState : SquizStream
{
}

/// Get a runtime type for the provided algorithm
SquizAlgo squizAlgo(A)(A algo)
if (isSquizAlgo!A)
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

    const ctSquized = [input].squiz(ctAlgo).join();
    const rtSquized = [input].squiz(rtAlgo).join();

    assert(ctSquized == rtSquized);
}

private class CSquizAlgo(A) : SquizAlgo
{
    alias State = StateType!A;

    A algo;

    private this(A algo)
    {
        this.algo = algo;
    }

    private State checkState(SquizState state)
    {
        auto s = cast(State)state;
        assert(s, "provided state is not produced by this algorithm");
        return s;
    }

    SquizState initialize()
    {
        return algo.initialize();
    }

    Flag!"streamEnded" process(SquizState state, Flag!"inputEmpty" inputEmpty)
    {
        return algo.process(checkState(state), inputEmpty);
    }

    void reset(SquizState state)
    {
        return algo.reset(checkState(state));
    }

    void end(SquizState state)
    {
        return algo.end(checkState(state));
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

/// A processing stream for squiz algorithms
interface SquizStream
{
    @property const(ubyte)[] input() const;
    @property void input(const(ubyte)[] inp);
    @property size_t totalInput() const;

    @property inout(ubyte)[] output() inout;
    @property void output(ubyte[] outp);
    @property size_t totalOutput() const;
}

private mixin template StreamImpl(S)
if (isZlibLikeStream!S)
{
    S strm;

    @property const(ubyte)[] input() const
    {
        return strm.next_in[0 .. strm.avail_in];
    }

    @property void input(const(ubyte)[] inp)
    {
        strm.next_in = inp.ptr;
        strm.avail_in = cast(typeof(strm.avail_in)) inp.length;
    }

    @property size_t totalInput() const
    {
        return cast(size_t) strm.total_in;
    }

    @property inout(ubyte)[] output() inout
    {
        return strm.next_out[0 .. strm.avail_out];
    }

    @property void output(ubyte[] outp)
    {
        strm.next_out = outp.ptr;
        strm.avail_out = cast(typeof(strm.avail_out)) outp.length;
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
    auto state = algo.initialize();
    return Squiz!(I, A, Yes.endState)(input, algo, state, chunkBuffer);
}

/// Returns an InputRange containing the input data processed through the supplied algorithm.
/// To the difference of `squiz`, `squizReuse` will not manage the state of the algorithm,
/// which allows to reuse it (and its allocated resources) for several jobs.
/// The state must be either freshly initialized or freshly reset before being passed
/// to this function.
auto squizReuse(I, A, S)(I input, A algo, S state, ubyte[] chunkBuffer)
        if (isByteRange!I && isSquizAlgo!A)
{
    static assert(is(StateType!A == S), S.strinof ~ " is not the state produced by " ~ A.stringof);
    return Squiz!(I, A, No.endState)(input, algo, state, chunkBuffer);
}

// Common transformation range for all compression/decompression functions.
// I is a byte input range
// A is a squiz algorithm
// if Yes.end, the state is ended when data is done processing
private struct Squiz(I, A, Flag!"endState" endState)
{
    private alias State = StateType!A;

    // Byte input range (by chunks)
    private I input;

    // The algorithm
    private A algo;

    // Processed stream state
    private State state;

    // Buffer used to store the front chunk
    private ubyte[] chunkBuffer;
    // Slice of the buffer that is valid for read out
    private ByteChunk chunk;

    /// Whether the end of stream was reported by the Policy
    private bool ended;

    private this(I input, A algo, State state, ubyte[] chunkBuffer)
    {
        this.input = input;
        this.algo = algo;
        this.state = state;
        this.chunkBuffer = chunkBuffer;
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
        while (chunk.length < chunkBuffer.length)
        {
            if (state.input.length == 0 && !input.empty)
                state.input = input.front;

            state.output = chunkBuffer[chunk.length .. $];

            const streamEnded = algo.process(state, cast(Flag!"inputEmpty") input.empty);

            chunk = chunkBuffer[0 .. $ - state.output.length];

            // popFront must be called at the end because it invalidates inChunk
            if (state.input.length == 0 && !input.empty)
                input.popFront();

            if (streamEnded)
            {
                static if (endState)
                    algo.end(state);
                ended = true;
                break;
            }
        }
    }
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

private size_t strnlen(const(byte)* str, size_t maxlen)
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
/// These can be specified here when compressing from a stream.
struct GzHeader
{
    /// operating system encoded in the Gz header
    /// Not all possible values are listed here, only
    /// the most useful ones
    enum Os
    {
        fatFs = 0,
        unix = 3,
        macintosh = 7,
        ntFs = 11,
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

    /// Modification time
    SysTime mtime;

    /// Operating system that wrote the gz file
    Os os = defaultOs;

    /// Filename to be included in the header
    string filename;

    /// Comment to be included in the header
    string comment;

    private enum bufSize = 256;

    private string strz(const(byte)* ptr)
    {
        // ptr points to a buffer of bufSize characters
        // end of string is a null charactor or end of buffer
        // encoding is latin 1
        import std.encoding : Latin1Char, transcode;

        const len = strnlen(ptr, bufSize);
        auto str = cast(const(Latin1Char)[]) ptr[0 .. len];

        string res;
        transcode(str, res);
        return res;
    }

    private byte* toLatin1z(string str)
    {
        import std.encoding : Latin1Char, transcode;

        Latin1Char[] l1;
        transcode(str, l1);
        auto res = (cast(byte[]) l1) ~ 0;
        return res.ptr;
    }

    private this(gz_headerp gzh)
    {
        text = gzh.text ? Yes.text : No.text;
        mtime = SysTime(unixTimeToStdTime(gzh.time));
        os = cast(Os) gzh.os;
        if (gzh.name)
            filename = fromLatin1z(gzh.name);
        if (gzh.comment)
            comment = fromLatin1z(gzh.comment);
    }

    private gz_headerp toZlib()
    {
        import core.stdc.config : c_long;

        auto gzh = new gz_header;
        gzh.text = text ? 1 : 0;
        gzh.time = stdTimeToUnixTime!(c_long)(mtime.stdTime);
        gzh.os = cast(int) os;
        if (filename)
            gzh.name = toLatin1z(filename);
        if (comment)
            gzh.comment = toLatin1z(comment);
        return gzh;
    }
}

/// Helper to set GzHeader.text
/// Will check if the data are all ascii characters
Flag!"text" isText(const(ubyte)[] data)
{
    import std.algorithm : all;

    return cast(Flag!"text") data.all!(
        c => c == 0x0a || c == 0x0d || (c >= 0x20 && c <= 0x7e)
    );
}

class ZlibState : SquizState
{
    mixin StreamImpl!z_stream;

    private this()
    {
        strm.zalloc = &(gcAlloc!uint);
        strm.zfree = &gcFree;
    }

}

/// Returns an InputRange containing the input data processed through Zlib's deflate algorithm.
/// The produced stream of data is wrapped by Zlib header and trailer.
auto deflate(I)(I input, int level = 6, size_t chunkSize = defaultChunkSize)
        if (isByteRange!I)
{
    auto algo = Deflate.init;
    algo.level = level;
    return squiz(input, algo, chunkSize);
}

/// Returns an InputRange containing the input data processed through Zlib's deflate algorithm.
/// The produced stream of data is wrapped by Gzip header and trailer.
/// header can be supplied to replace the default header produced by Zlib.
auto deflateGz(I)(I input, int level = 6, Nullable!GzHeader header = null, size_t chunkSize = defaultChunkSize)
        if (isByteRange!I)
{
    auto algo = Deflate.init;
    algo.format = ZlibFormat.gz;
    algo.level = level;
    algo.gzHeader = header;
    return squiz(input, algo, chunkSize);
}

/// ditto
auto deflateGz(I)(I input, int level = 6, size_t chunkSize = defaultChunkSize)
        if (isByteRange!I)
{
    auto algo = Deflate.init;
    algo.format = ZlibFormat.gz;
    algo.level = level;
    return squiz(input, algo, chunkSize);
}

/// Returns an InputRange containing the input data processed through Zlib's deflate algorithm.
/// The produced stream of data isn't wrapped by any header or trailer.
auto deflateRaw(I)(I input, int level = 6, size_t chunkSize = defaultChunkSize)
        if (isByteRange!I)
{
    auto algo = Deflate.init;
    algo.format = ZlibFormat.raw;
    algo.level = level;
    return squiz(input, algo, chunkSize);
}

/// Zlib's deflate algorithm
struct Deflate
{
    static assert(isSquizAlgo!Deflate);
    static assert(is(StateType!Deflate == State));

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

    static final class State : ZlibState
    {
    }

    State initialize()
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

        auto state = new State();

        const res = deflateInit2(
            &state.strm, level, Z_DEFLATED,
            wb, memLevel, cast(int) strategy,
        );
        enforce(
            res == Z_OK,
            "Could not initialize Zlib deflate stream: " ~ zResultToString(res)
        );

        if (format == ZlibFormat.gz && !gzHeader.isNull)
        {
            auto head = gzHeader.get.toZlib();
            deflateSetHeader(&state.strm, head);
        }

        return state;
    }

    Flag!"streamEnded" process(State state, Flag!"inputEmpty" inputEmpty)
    {
        const flush = inputEmpty ? Z_FINISH : Z_NO_FLUSH;
        const res = squiz_box.c.zlib.deflate(&state.strm, flush);

        if (res == Z_STREAM_END)
            return Yes.streamEnded;

        enforce(
            res == Z_OK,
            "Zlib deflate failed with code: " ~ zResultToString(res)
        );
        return No.streamEnded;
    }

    void reset(State state)
    {
        deflateReset(&state.strm);
    }

    void end(State state)
    {
        deflateEnd(&state.strm);
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
auto inflateGz(I)(I input, GzHeader* header, size_t chunkSize = defaultChunkSize)
{
    auto algo = Inflate.init;
    algo.format = ZlibFormat.gz;
    algo.gzHeader = header;
    return squiz(input, algo, chunkSize);
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

    /// Type of delegate to use as callback for gzHeaderDg
    alias GzHeaderDg = void delegate(GzHeader header);

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

        this(GzHeaderDg dg)
        {
            gzh.name = &nameBuf[0];
            gzh.name_max = cast(uint) nameBuf.length;
            gzh.comment = &commentBuf[0];
            gzh.comm_max = cast(uint) commentBuf.length;

            this.dg = dg;
        }
    }

    static final class State : ZlibState
    {
        Gzh gzh;
    }

    State initialize()
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

        auto state = new State();

        const res = inflateInit2(&state.strm, wb);

        enforce(
            res == Z_OK,
            "Could not initialize Zlib's inflate stream: " ~ zResultToString(res)
        );

        if (gzHeaderDg)
        {
            state.gzh = new Gzh(gzHeaderDg);
            inflateGetHeader(&state.strm, &state.gzh.gzh);
        }

        return state;
    }

    package Flag!"streamEnded" process(State state, Flag!"inputEmpty" /+ inputEmpty +/ )
    {
        const res = squiz_box.c.zlib.inflate(&state.strm, Z_NO_FLUSH);

        auto gzh = state.gzh;
        if (gzh && !gzh.dgCalled && gzh.gzh.done)
        {
            gzh.dg(GzHeader(&gzh.gzh));
            gzh.dgCalled = true;
        }

        if (res == Z_STREAM_END)
            return Yes.streamEnded;

        enforce(
            res == Z_OK,
            "Zlib inflate failed with code: " ~ zResultToString(res)
        );
        return No.streamEnded;
    }

    package void reset(State state)
    {
        inflateReset(&state.strm);
    }

    package void end(State state)
    {
        inflateEnd(&state.strm);
    }
}

///
@("Delfate / Inflate")
unittest
{
    import test.util;
    import std.array : join;

    auto def = Deflate.init;
    auto inf = Inflate.init;

    const len = 10_000;
    const phrase = cast(const(ubyte)[]) "Some very repetitive phrase.\n";
    const input = generateRepetitiveData(len, phrase).join();

    // deflating
    const squized = [input].squiz(def).join();

    // re-inflating
    const output = [squized].squiz(inf).join();

    assert(squized.length < input.length);
    assert(output == input);

    // for such repetitive data, ratio is around 0.8%
    const ratio = cast(double)squized.length / cast(double)input.length;
    assert(ratio < 0.01);
}

package string zResultToString(int res)
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

package string zFlushToString(int flush)
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

package void zPrintStream(z_stream* strm, string label)
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
