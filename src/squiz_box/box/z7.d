/// Support for .7z archives.
///
/// This module was made possible thanks to the great 7z format
/// specification done by the py7zr project.
/// https://py7zr.readthedocs.io/en/latest/archive_format.html
///
/// The original format documentation from Igor Pavlov is also useful.
/// See "doc/7zformat.txt" in this project source code.
///
/// I also took inspiration from a few algorithms in py7zr.
module squiz_box.box.z7;

import squiz_box.c.zlib;
import squiz_box.priv;
import squiz_box.squiz;

import std.array;
import std.conv;
import std.exception;
import std.format;
import std.range;
import std.typecons;
import std.stdio;

class Z7ArchiveException : Exception
{
    mixin basicExceptionCtors!();
}

class NotA7zArchiveException : Z7ArchiveException
{
    string source;
    string reason;

    this(string source, string reason, string file = __FILE__, size_t line = __LINE__)
    {
        super(format!"'%s' is not a 7z archive (%s)"(source, reason));
        this.source = source;
        this.reason = reason;
    }
}

class Corrupted7zArchiveException : Z7ArchiveException
{
    string source;
    string reason;

    this(string source, string reason, string file = __FILE__, size_t line = __LINE__)
    {
        super(format!"'%s' is a corrupted 7z archive (%s)"(source, reason));
        this.source = source;
        this.reason = reason;
    }
}

auto read7zArchive(File file)
{
    auto cursor = new FileCursor(file);
    return Z7ArchiveRead!FileCursor(cursor);
}

auto read7zArchive(ubyte[] data)
{
    auto cursor = new ArrayCursor(data);
    return Z7ArchiveRead!ArrayCursor(cursor);
}

private struct Z7ArchiveRead(C) if (is(C : SearchableCursor))
{
    // using template to eliminate virtual function calls
    // (both FileCursor and ArrayCursor are final)
    private C cursor;
    private SignatureHeader signHeader;
    private Nullable!Header header;

    this(C cursor)
    {
        this.cursor = cursor;

        readHeaders();
    }

    private void readHeaders()
    {
        signHeader = parse!SignatureHeader(cursor);
        cursor.ffw(signHeader.headerDbOffset);

        static if (is(C : ArrayCursor))
        {
            const(ubyte)[] headerDb = cursor.readInner(signHeader.headerDbSize);
        }
        else
        {
            auto buf = new ubyte[signHeader.headerDbSize];
            const(ubyte)[] headerDb = cursor.read(buf);
        }

        enforce(
            headerDb.length == signHeader.headerDbSize,
            new Corrupted7zArchiveException(cursor.name, "Not enough bytes for the header database")
        );

        const dbCrc = crc32(0, headerDb.ptr, cast(uint) headerDb.length);

        enforce(
            dbCrc == signHeader.headerDbCrc,
            new Corrupted7zArchiveException(cursor.name, "Could not verify header database CRC-32")
        );

        ArrayCursor dbCursor = new ArrayCursor(headerDb, cursor.name);

        if (dbCursor.eoi)
            return;

        header = Header.read(dbCursor, cursor, 32);
    }
}

const(ubyte)[] readCursor(C)(C cursor, size_t len)
{
    static if (is(C : ArrayCursor))
    {
        return cursor.readInner(len);
    }
    else
    {
        auto buf = new ubyte[len];
        return cursor.read(buf);
    }
}

// void unpackStreamsInfo(C)(C cursor, StreamsInfo info)
// {
//     import std.array : join;

//     auto packInfo = info.packInfo.get;
//     cursor.seek(packInfo.packPos + 32);
//     DecompressLzma algo;
//     algo.format = LzmaFormat.rawLegacy;
//     auto input = readCursor(cursor, packInfo.packSizes[0]);
//     writefln("stream input [%(%02x, %)]", input);
//     auto output = [input]
//         .squiz(algo)
//         .join();
//     writefln("stream output [%(%02x, %)]", output);
// }

enum print7zDecode = true;

private template parse(T)
{
    T parse(C)(C cursor)
    {
        auto d = T.read(cursor);
        static if (print7zDecode)
        {
            writefln!"Decoded %s"(d);
        }
        return d;
    }
}

private const ubyte[6] magicBytes = ['7', 'z', 0xbc, 0xaf, 0x27, 0x1c];
private const ubyte[2] versionBytes = [0, 4];

private struct SignatureHeader
{
    static struct Rep
    {
        ubyte[6] signature;
        ubyte[2] ver;
        LittleEndian!4 headerCrc;
        LittleEndian!8 nextHeaderOffset;
        LittleEndian!8 nextHeaderSize;
        LittleEndian!4 nextHeaderCrc;
    }

    static SignatureHeader read(C)(C cursor)
    {
        SignatureHeader.Rep rep = void;
        cursor.readValue(&rep);
        enforce(
            rep.signature == magicBytes,
            new NotA7zArchiveException(cursor.name, "Not starting by magic bytes"),
        );

        const crc = crc32(0, &(rep.signature[0]) + 12, 20);
        enforce(
            crc == rep.headerCrc.val,
            new Corrupted7zArchiveException(cursor.name, "Could not verify signature header CRC-32"),
        );

        SignatureHeader res = void;
        // check for 0.4?
        res.ver = rep.ver[0] * 10 + rep.ver[1];
        res.headerDbOffset = rep.nextHeaderOffset.val;
        res.headerDbSize = rep.nextHeaderSize.val;
        res.headerDbCrc = rep.nextHeaderCrc.val;

        return res;
    }

    uint ver;
    ulong headerDbOffset;
    ulong headerDbSize;
    uint headerDbCrc;

    @property ulong headerDbPos()
    {
        return headerDbOffset + 32;
    }
}

private struct BooleanList
{
    static bool[] read(C)(C cursor, size_t count, Flag!"checkAllDefined" checkAll)
    {
        if (checkAll && cursor.get != 0)
        {
            auto res = repeat(true)
                .take(count)
                .array;
            return res;
        }
        bool[] res = new bool[count];
        ubyte b;
        ubyte mask;
        while (count--)
        {
            if (mask == 0)
            {
                b = cursor.get;
                mask = 0x80;
            }
            res ~= (b & mask) != 0;
            mask >>= 1;
        }
        return res;
    }
}

private struct VarNumber
{
    static const ubyte[9] lenb = [
        0b0111_1111,
        0b1011_1111,
        0b1101_1111,
        0b1110_1111,
        0b1111_0111,
        0b1111_1011,
        0b1111_1101,
        0b1111_1110,
        0b1111_1111,
    ];

    static ulong read(C)(C cursor)
    {
        const b0 = cursor.get;
        if (b0 <= lenb[0])
            return b0;

        uint mask = 0xc0;
        uint len = 1;

        foreach (b; lenb[1 .. $])
        {
            if (b0 <= b)
                break;
            len++;
            mask |= mask >> 1;
        }

        const ulong masked = b0 & ~mask;

        LittleEndian!8 bn;
        enforce(cursor.read(bn.data[0 .. len]).length == len, "Not enough bytes");

        auto val = bn.val;
        if (len <= 6)
            val |= (b0 & masked) << (len * 8);
        return val;
    }

    @("readUint64")
    unittest
    {
        ulong read(ubyte[] pattern)
        {
            auto cursor = new ArrayCursor(pattern);
            return VarNumber.read(cursor);
        }

        assert(read([0x27, 0x27, 0x27, 0x27, 0x27, 0x27, 0x27, 0x27, 0x27]) == 0x27);
        assert(read([0xa7, 0x27, 0x27, 0x27, 0x27, 0x27, 0x27, 0x27, 0x27]) == 0x2727);
        assert(read([0xc7, 0x27, 0x27, 0x27, 0x27, 0x27, 0x27, 0x27, 0x27]) == 0x07_2727);
        assert(read([0xe7, 0x27, 0x27, 0x27, 0x27, 0x27, 0x27, 0x27, 0x27]) == 0x0727_2727);
        assert(read([0xf7, 0x27, 0x27, 0x27, 0x27, 0x27, 0x27, 0x27, 0x27]) == 0x07_2727_2727);
        assert(read([0xfb, 0x27, 0x27, 0x27, 0x27, 0x27, 0x27, 0x27, 0x27]) == 0x0327_2727_2727);
        assert(read([0xfd, 0x27, 0x27, 0x27, 0x27, 0x27, 0x27, 0x27, 0x27]) == 0x01_2727_2727_2727);
        assert(read([0xfe, 0x27, 0x27, 0x27, 0x27, 0x27, 0x27, 0x27, 0x27]) == 0x0027_2727_2727_2727);
        assert(read([0xff, 0x27, 0x27, 0x27, 0x27, 0x27, 0x27, 0x27, 0x27]) == 0x2727_2727_2727_2727);
    }

    static const ulong[] lenn = [
        0x7f,
        0x3fff,
        0x1f_ffff,
        0x0fff_ffff,
        0x07_ffff_ffff,
        0x03ff_ffff_ffff,
        0x01_ffff_ffff_ffff,
        0xff_ffff_ffff_ffff,
        0xffff_ffff_ffff_ffff,
    ];

    static ubyte[9] encodeBuffer;

    static const(ubyte)[] encode(ulong number)
    {
        // shortcut
        if (number <= lenn[0])
        {
            encodeBuffer[0] = cast(ubyte) number;
            return encodeBuffer[0 .. 1];
        }

        ubyte b0mask1 = 0x80;
        uint b0mask2 = 0xc0;
        ulong bnmask = 0xff;
        uint len = 1;
        foreach (n; lenn[1 .. $])
        {
            if (number <= n)
                break;
            b0mask1 |= b0mask1 >> 1;
            b0mask2 |= b0mask2 >> 1;
            bnmask |= bnmask << 8;
            len++;
        }

        LittleEndian!8 le = number & bnmask;

        encodeBuffer[0] = b0mask1;
        if (len <= 6)
            encodeBuffer[0] |= (number >> len * 8) & ~b0mask2;
        encodeBuffer[1 .. 1 + len] = le.data[0 .. len];

        return encodeBuffer[0 .. len + 1];
    }

    @("VarNumber.encode")
    unittest
    {
        const(ubyte)[] encode(ulong number)
        {
            return VarNumber.encode(number);
        }

        assert([0x27] == encode(0x27));
        assert([0xa7, 0x27] == encode(0x2727));
        assert([0xc7, 0x27, 0x27] == encode(0x07_2727));
        assert([0xe7, 0x27, 0x27, 0x27] == encode(0x0727_2727));
        assert([0xf7, 0x27, 0x27, 0x27, 0x27] == encode(0x07_2727_2727));
        assert([0xfb, 0x27, 0x27, 0x27, 0x27, 0x27] == encode(0x0327_2727_2727));
        assert([0xfd, 0x27, 0x27, 0x27, 0x27, 0x27, 0x27] == encode(0x01_2727_2727_2727));
        assert([0xfe, 0x27, 0x27, 0x27, 0x27, 0x27, 0x27, 0x27] == encode(0x0027_2727_2727_2727));
        assert([0xff, 0x27, 0x27, 0x27, 0x27, 0x27, 0x27, 0x27, 0x27] == encode(
                0x2727_2727_2727_2727));
    }
}

ulong readUint64(C)(C cursor)
{
    return VarNumber.read(cursor);
}

// dfmt off
private enum PropId : ubyte
{
    end                     = 0x00,
    header                  = 0x01,
    archiveProps            = 0x02,
    additionalStreamsInfo   = 0x03,
    mainStreamsInfo         = 0x04,
    fileInfo                = 0x05,
    packInfo                = 0x06,
    unpackInfo              = 0x07,
    subStreamsInfo          = 0x08,
    size                    = 0x09,
    crc                     = 0x0a,
    folder                  = 0x0b,
    codersUnpackSize        = 0x0c,
    numUnpackStream         = 0x0d,
    emptyStream             = 0x0e,
    emptyFile               = 0x0f,
    anti                    = 0x10,
    name                    = 0x11,
    ctime                   = 0x12,
    atime                   = 0x13,
    mtime                   = 0x14,
    winAttributes           = 0x15,
    comment                 = 0x16,
    encodeHeader            = 0x17,
    startPos                = 0x18,
    dummy                   = 0x19,
}
// dfmt on

PropId readPropId(C)(C cursor)
{
    return cast(PropId)cursor.get;
}

private string propIdName(PropId id)
{
    return id > PropId.dummy ?
        format!"0x%02x"(
            cast(ubyte) id) : format!"%s (0x%02x)"(id.to!string, cast(ubyte) id);
}

private noreturn unexpectedPropId(string source, PropId id, string section)
{
    throw new Corrupted7zArchiveException(
        source,
        format!"Unexpected property in '%s': %s"(section, propIdName(id)),
    );
}

private void enforceGetPropId(C)(C cursor, PropId propId, string section)
{
    auto id = cast(PropId) cursor.get;
    if (id != propId)
        throw new Corrupted7zArchiveException(
            cursor.name,
            format!"Expected Property Id %s but found %s in '%s'"(
                propIdName(propId), propIdName(id), section
        )
        );
}

private struct PackInfo
{
    enum id = PropId.packInfo;

    ulong packPos;
    ulong numPackStreams;

    /// One entry per numPackStreams.
    ulong[] packSizes;

    /// One entry per numPackStreams.
    /// CRC == 0 means that it is not defined.
    uint[] crcs;

    static PackInfo read(C)(C cursor)
    {
        import std.algorithm : map;

        PackInfo res;
        res.packPos = readUint64(cursor);
        res.numPackStreams = readUint64(cursor);

        auto nextId = cast(PropId) cursor.get;
        while (nextId != PropId.end)
        {
            switch (nextId)
            {
            case PropId.size:
                res.packSizes = hatch!(() => readUint64(cursor))
                    .take(res.numPackStreams)
                    .array;
                break;
            case PropId.crc:
                res.crcs = BooleanList.read(cursor, cast(size_t) res.numPackStreams, Yes
                        .checkAllDefined)
                    .map!(def => def ? cursor.getValue!uint() : 0)
                    .array;
                break;
            default:
                unexpectedPropId(cursor.name, nextId, "PackInfo");
            }
            nextId = cast(PropId) cursor.get;
        }
        return res;
    }
}

private struct CodecFlags
{
    ubyte rep;

    this(ubyte rep)
    {
        this.rep = rep;
    }

    this(ubyte idSize, Flag!"isComplexCoder" complex, Flag!"thereAreAttributes" attrs)
    in (idSize <= 0x0f)
    {
        rep = (idSize & 0x0f) | (complex ? 0x10 : 0x00) | (attrs ? 0x20 : 0x00);
    }

    @property ubyte idSize() const
    {
        return rep & 0x0f;
    }

    @property bool isComplexCoder() const
    {
        return (rep & 0x10) != 0;
    }

    @property bool thereAreAttributes() const
    {
        return (rep & 0x20) != 0;
    }
}

/// Folder describes a stream of compressed data
private struct Folder
{
    static struct CodecInfo
    {
        ubyte[] codecId;
        // complex coder
        size_t numInStreams;
        size_t numOutStreams;
        //attrs
        ubyte[] props;

        static CodecInfo read(C)(C cursor)
        {
            CodecInfo res;

            const flags = CodecFlags(cursor.get);
            res.codecId = new ubyte[flags.idSize];
            cursor.read(res.codecId);
            if (flags.isComplexCoder)
            {
                res.numInStreams = cast(size_t) readUint64(cursor);
                res.numOutStreams = cast(size_t) readUint64(cursor);
            }
            else
            {
                res.numInStreams = 1;
                res.numOutStreams = 1;
            }
            if (flags.thereAreAttributes)
            {
                const size = cast(size_t) readUint64(cursor);
                res.props = new ubyte[size];
                cursor.read(res.props);
            }

            return res;
        }
    }

    static struct BindPair
    {
        ulong inIndex;
        ulong outIndex;
    }

    CodecInfo[] codecInfos;
    size_t numInStreams;
    size_t numOutStreams;
    BindPair[] bindPairs;
    ulong[] indices;
    ulong[] unpackSizes;
    uint unpackCrc;

    static Folder read(C)(C cursor)
    {
        Folder res;

        const numCoders = cast(size_t) readUint64(cursor);

        res.codecInfos = hatch!(() => parse!CodecInfo(cursor))
            .take(numCoders)
            .array;

        foreach (const ref ci; res.codecInfos)
        {
            res.numInStreams += ci.numInStreams;
            res.numOutStreams += ci.numOutStreams;
        }

        res.bindPairs = hatch!(() {
            const i = readUint64(cursor);
            const o = readUint64(cursor);
            return BindPair(i, o);
        })
            .take(res.numOutStreams - 1)
            .array;

        const numPackedStreams = res.numInStreams - res.bindPairs.length;
        if (numPackedStreams > 1)
        {
            res.indices = hatch!(() => readUint64(cursor))
                .take(numPackedStreams)
                .array;
        }

        return res;
    }

    private static const ubyte[1] copyId = [0];
    private static const ubyte[1] lzma2Id = [0x21];
    private static const ubyte[3] lzma1Id = [3, 1, 1];
    private static const ubyte[1] deltaId = [3];
    private static const ubyte[1] bcjX86Id = [4];
    private static const ubyte[4] bcjPowerPcId = [3, 3, 2, 5];
    private static const ubyte[4] bcjIa64Id = [3, 3, 3, 1];
    private static const ubyte[4] bcjArmId = [3, 3, 5, 1];
    private static const ubyte[4] bcjArmThumbId = [3, 3, 7, 1];
    private static const ubyte[4] bcjSparcId = [3, 3, 8, 5];
    private static const ubyte[3] bzip2Id = [4, 4, 2];
    private static const ubyte[3] deflateId = [4, 1, 8];

    SquizAlgo unpackAlgo()
    {
        // not sure this can ever happen, but copy is the logical thing to do if it does
        if (codecInfos.length == 0)
            return squizAlgo(Copy.init);

        /// TODO: support additional lzma filters such as bcj and delta
        enforce(codecInfos.length == 1, "compound codec not supported yet");

        const id = codecInfos[0].codecId;
        if (id == lzma2Id)
            return squizAlgo(DecompressLzma(LzmaFormat.raw));
        else if (id == lzma1Id)
            return squizAlgo(DecompressLzma(LzmaFormat.rawLegacy));
        else if (id == copyId)
            return squizAlgo(Copy.init);
        else if (id == bzip2Id)
            return squizAlgo(DecompressBzip2.init);
        else if (id == deflateId)
            return squizAlgo(Inflate(ZlibFormat.raw));

        return null;
    }
}

private struct CodersInfo
{
    Folder[] folders;
    ulong dataStreamIndex;
    ulong[] unpackSizes;

    static CodersInfo read(C)(C cursor)
    {
        CodersInfo res;

        enforceGetPropId(cursor, PropId.folder, "CodersInfo");
        const numFolders = cast(size_t) readUint64(cursor);
        const external = cursor.get;
        switch (external) // external
        {
        case 0:
            res.folders = hatch!(() => parse!Folder(cursor))
                .take(numFolders)
                .array;
            break;
        case 1:
            res.dataStreamIndex = readUint64(cursor);
            break;
        default:
            throw new Corrupted7zArchiveException(
                cursor.name,
                format!"Unexpected external value in Coders info: 0x%02x"(external),
            );
        }

        auto nextId = cast(PropId) cursor.get;
        while (nextId != PropId.end)
        {
            switch (nextId)
            {
            case PropId.codersUnpackSize:
                foreach (ref f; res.folders)
                {
                    f.unpackSizes = hatch!(() => readUint64(cursor))
                        .take(f.numOutStreams)
                        .array;
                }
                break;
            case PropId.crc:
                const defined = BooleanList.read(cursor, res.folders.length, Yes.checkAllDefined);
                foreach (i, ref f; res.folders)
                {
                    if (defined[i])
                        f.unpackCrc = cursor.getValue!uint();
                }
                break;
            default:
                unexpectedPropId(cursor.name, nextId, "CodersInfo");
            }
            nextId = cast(PropId) cursor.get;
        }

        return res;
    }
}

private struct StreamsInfo
{
    Nullable!PackInfo packInfo;
    Nullable!CodersInfo codersInfo;

    static StreamsInfo read(C)(C cursor)
    {
        StreamsInfo res;

        auto nextId = cast(PropId) cursor.get;
        while (nextId != PropId.end)
        {
            switch (nextId)
            {
            case PropId.packInfo:
                res.packInfo = parse!PackInfo(cursor);
                break;
            case PropId.unpackInfo:
                res.codersInfo = parse!CodersInfo(cursor);
                break;
            default:
                unexpectedPropId(cursor.name, nextId, "StreamInfo");
            }
            nextId = cast(PropId) cursor.get;
        }

        return res;
    }
}

private struct SubStreamsInfo
{
    static SubStreamsInfo read(C)(C cursor)
    {

    }
}

private struct Header
{
    StreamsInfo mainStreams;


    static Header read(DB, C)(DB dbCursor, C cursor, ulong packedStreamStart)
    {
        const propId = cast(PropId) dbCursor.get;
        if (propId == PropId.header)
            return readHeader(dbCursor);
        if (propId == PropId.encodeHeader)
            return readEncodedHeader(dbCursor, cursor, packedStreamStart);

        unexpectedPropId(cursor.name, propId, "Header database");
    }

    static Header readHeader(C)(C cursor)
    {
        Header res;
        enforceGetPropId(cursor, PropId.mainStreamsInfo, "Header database");
        res.mainStreams = cursor.parse!StreamsInfo();
        return res;
    }

    static Header readEncodedHeader(DB, C)(DB dbCursor, C cursor, ulong packedStreamStart)
    {
        import std.array : join;

        auto info = StreamsInfo.read(dbCursor);
        enforce(!info.packInfo.isNull, "Encoded header without PackInfo");
        enforce(!info.codersInfo.isNull, "Encoded header without CodersInfo");

        PackInfo packInfo = info.packInfo.get;
        CodersInfo codersInfo = info.codersInfo.get;

        ulong streamPos = packedStreamStart;

        ubyte[] headerBuf;

        foreach (Folder folder; codersInfo.folders)
        {
            const decompressedSize = folder.unpackSizes[$ - 1];

            streamPos += packInfo.packPos;
            cursor.seek(streamPos);

            auto algo = folder.unpackAlgo();
            const compressedSize = packInfo.packSizes[0];

            // todo check if we can combined all folders in a single lazy range to avoid allocation
            auto decompressed = cursorByteRange(cursor, compressedSize)
                .squizMaxOut(algo, decompressedSize)
                .join();

            assert(decompressed.length == decompressedSize);

            if (folder.unpackCrc)
            {
                uint crc = crc32(0, decompressed.ptr, cast(uint)decompressed.length);
                enforce(folder.unpackCrc == crc, "Header CRC check failed");
            }

            headerBuf ~= decompressed;
        }

        auto hc = new ArrayCursor(headerBuf, cursor.name);
        hc.enforceGetPropId(PropId.header, "Header decoded database");
        return readHeader(hc);
    }
}
