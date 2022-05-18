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

import squiz_box.box;
import squiz_box.c.zlib;
import squiz_box.priv;
import squiz_box.squiz;

import std.array;
import std.conv;
import std.datetime.systime;
import std.encoding;
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

private noreturn bad7z(string source, string reason, string file = __FILE__, size_t line = __LINE__)
{
    throw new Corrupted7zArchiveException(source, reason, file, line);
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
    private Header header;
    private ulong startPos;
    private ulong nextPos;

    private size_t fileInd;
    private size_t foldInd;
    private size_t streamInd;
    private EntryDecoder decoder;

    private Z7ExtractEntry currentEntry;

    this(C cursor)
    {
        this.cursor = cursor;

        readHeaders();

        if (fileInd < header.fileInfos.length)
            prime();
    }

    private void readHeaders()
    {
        import std.algorithm : all;

        signHeader = parse!SignatureHeader(cursor);
        startPos = cursor.pos;
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

        static if (print7zDecode)
        {
            writeln("Read header ", header);
        }

        enforce(
            header.mainStreams.codersInfo.folders.all!(f => !f.isComplex),
            "squiz-box does not support multiplexed streams"
        );

        nextPos = startPos + header.mainStreams.packInfo.packPos;
    }

    private void prime()
    {
        const fileInfo = header.fileInfos[fileInd];
        Folder.SubStream ssInfo;
        ulong decoderPos;
        size_t filI;
        size_t thisFoldI;

        outerLoop: foreach (foldI, ref Folder f; header.mainStreams.codersInfo.folders)
        {
            decoderPos = 0;
            foreach (ref ss; f.subStreams)
            {
                if (filI == fileInd)
                {
                    thisFoldI = foldI;
                    ssInfo = ss;
                    break outerLoop;
                }
                else
                {
                    filI++;
                    decoderPos += ss.size;
                }
            }
        }
        if (!decoder || thisFoldI != foldInd)
        {
            auto folder = header.mainStreams.codersInfo.folders[thisFoldI];
            foldInd = thisFoldI;
            decoder = new EntryDecoder(cursor, folder);
        }

        const path = fileInfo.name;
        const size = ssInfo.size;
        const mtime = fileInfo.mtime;
        const attrs = fileInfo.attributes;

        currentEntry = new Z7ExtractEntry(path, size, mtime, attrs, decoderPos, decoder);
        fileInd++;
    }

    @property ArchiveExtractEntry front()
    {
        return currentEntry;
    }

    @property bool empty()
    {
        return currentEntry is null;
    }

    void popFront()
    {
        currentEntry = null;
        if (fileInd < header.fileInfos.length)
            prime();
    }
}

final class Z7ExtractEntry : ArchiveExtractEntry
{
    string _path;
    ulong _size;
    long _mtime;
    uint _attrs;
    size_t _decoderPos;
    EntryDecoder _decoder;

    this(string path, ulong size, long mtime, uint attrs, size_t decoderPos, EntryDecoder decoder)
    {
        _path = path;
        _size = size;
        _mtime = mtime;
        _attrs = attrs;
        _decoderPos = decoderPos;
        _decoder = decoder;
    }

    ByteRange byChunk(size_t chunkSize = defaultChunkSize)
    {
        return null;
    }

    @property size_t entrySize()
    {
        // not meaningful for 7z, several files encoded in the same compression pass
        return 0;
    }

    @property EntryMode mode()
    {
        return EntryMode.extraction;
    }

    @property string path()
    {
        return _path;
    }

    @property EntryType type()
    {
        return attrIsDir(_attrs) ? EntryType.directory : EntryType.regular;
    }

    @property string linkname()
    {
        return null;
    }

    @property ulong size()
    {
        return _size;
    }

    @property SysTime timeLastModified()
    {
        return SysTime(_mtime);
    }

    @property uint attributes()
    {
        version (Posix)
        {
            if (_attrs & 0x8000)
                return (_attrs & 0xffff0000) >> 16;
            else
                return octal!"100644";
        }
        else
        {
            return _attrs & 0xffff;
        }
    }

    version (Posix)
    {
        @property int ownerId()
        {
            return int.max;
        }

        @property int groupId()
        {
            return int.max;
        }
    }

}

private bool attrIsDir(uint attributes) nothrow pure
{
    version (Posix)
    {
        const unixAttrs = attributes & 0x8000 ? ((attributes & 0xffff0000) >> 16) : octal!"100644";
        return !!(unixAttrs & octal!"40_000");
    }
    else
    {
        import core.sys.windows.windows : FILE_ATTRIBUTE_DIRECTORY;

        const dosAttrs = attributes & 0xffff;
        return !!(dosAttrs & FILE_ATTRIBUTE_DIRECTORY);
    }
}

private const(ubyte)[] readCursor(C)(C cursor, size_t len)
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

enum print7zDecode = true;

private template parse(T)
{
    T parse(C, Args...)(C cursor, Args args)
    {
        auto d = T.read(cursor, args);
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
    filesInfo               = 0x05,
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
    names                   = 0x11,
    ctime                   = 0x12,
    atime                   = 0x13,
    mtime                   = 0x14,
    attributes              = 0x15,
    comment                 = 0x16,
    encodeHeader            = 0x17,
    startPos                = 0x18,
    dummy                   = 0x19,
}
// dfmt on

PropId readPropId(C)(C cursor)
{
    return cast(PropId) cursor.get;
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

    static struct SubStream
    {
        ulong size;
        uint crc;
    }

    CodecInfo[] codecInfos;
    size_t numInStreams;
    size_t numOutStreams;
    BindPair[] bindPairs;
    ulong[] indices;
    ulong[] unpackSizes;
    uint unpackCrc;

    // substream info
    SubStream[] subStreams;

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

    @property bool isComplex() const
    {
        return numInStreams != 1 || numOutStreams != 1;
    }

    size_t findInBindPair(size_t ind) const
    {
        foreach (i, bp; bindPairs)
        {
            if (bp.inIndex == ind)
                return i;
        }
        return size_t.max - 1;
    }

    size_t findOutBindPair(size_t ind) const
    {
        foreach (i, bp; bindPairs)
        {
            if (bp.outIndex == ind)
                return i;
        }
        return size_t.max;
    }

    size_t unpackSize() const
    {
        if (unpackSizes.length == 0)
            return 0;
        foreach (i; iota(unpackSizes.length, -1, -1))
        {
            if (findOutBindPair(i) == size_t.max)
                return unpackSizes[i];
        }
        return unpackSizes[$ - 1];
    }

    @property bool crcDefined() const
    {
        return unpackCrc != 0;
    }

    @property size_t numCrcUndefined() const
    {
        import std.algorithm : count;

        if (subStreams.length <= 1)
            return unpackCrc == 0 ? 1 : 0;
        return subStreams.count!(ss => ss.crc == 0);
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
    PackInfo packInfo;
    CodersInfo codersInfo;

    static StreamsInfo read(C)(C cursor)
    {
        StreamsInfo res;

        auto nextId = cast(PropId) cursor.get;
        while (nextId != PropId.end)
        {
            switch (nextId)
            {
            case PropId.packInfo:
                res.packInfo = cursor.parse!PackInfo();
                break;
            case PropId.unpackInfo:
                res.codersInfo = cursor.parse!CodersInfo();
                break;
            case PropId.subStreamsInfo:
                SubStreamsInfo.read(cursor, res.codersInfo.folders);
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
    // SubStreamsInfo sets it state into Folder.subStreams
    static void read(C)(C cursor, Folder[] folders)
    {
        auto propId = cursor.readPropId();
        if (propId == PropId.numUnpackStream)
        {
            writefln("read numUnPackStream at %02x", cursor.pos);
            foreach (ref f; folders)
            {
                const num = cursor.readUint64();
                writeln("  ", num);
                f.subStreams.length = 3;
            }
            propId = cursor.readPropId();
        }
        else
        {
            foreach (ref f; folders)
                f.subStreams = [Folder.SubStream(f.unpackSize, f.unpackCrc)];
        }
        if (propId == PropId.size)
        {
            writefln("read size at %02x", cursor.pos);
            foreach (ref f; folders)
            {
                ulong allButLast = 0;
                foreach (ref s; f.subStreams[0 .. $ - 1])
                {
                    const pos = cursor.pos;
                    const size = cursor.readUint64();
                    writefln("  %02x: %d", pos, size);
                    s.size = size;
                    allButLast += size;
                }
                f.subStreams[$ - 1].size = f.unpackSize() - allButLast;
            }
            const pos = cursor.pos;
            propId = cursor.readPropId();
            writefln("0x%02x: %s", pos, propId);
        }
        if (propId == PropId.crc)
        {
            import std.algorithm : map, sum;

            writefln!"read CRC at %02x"(cursor.pos);

            const numDigest = folders.map!(f => f.numCrcUndefined()).sum();
            const digestDefined = BooleanList.read(cursor, numDigest, Yes.checkAllDefined);

            writefln!"  num digest = %s"(numDigest);
            writefln!"  digest defined = %s"(digestDefined);

            size_t i;
            foreach (ref f; folders)
            {
                foreach (ref ss; f.subStreams)
                {
                    if (ss.crc == 0)
                    {
                        if (digestDefined[i++])
                        {
                            ss.crc = cursor.getValue!uint();
                            writefln!"  crc = %08x"(ss.crc);
                        }
                    }
                }
            }
            propId = cursor.readPropId();
        }

        if (propId != PropId.end)
            unexpectedPropId(cursor.name, propId, "SubStreamsInfo");
    }
}

private enum long hnsecsFrom1601 = 504_911_232_000_000_000L;

private struct FileInfo
{
    string name;

    long ctime;
    long atime;
    long mtime;

    uint attributes;

    bool emptyStream;
    bool emptyFile;
    bool antiFile;

    void setTime(PropId typ, long tim)
    {
        const stdTime = tim + hnsecsFrom1601;
        switch (typ)
        {
        case PropId.ctime:
            ctime = stdTime;
            break;
        case PropId.atime:
            atime = stdTime;
            break;
        case PropId.mtime:
            mtime = stdTime;
            break;
        default:
            assert(false);
        }
    }

    static FileInfo[] read(C)(C cursor)
    {
        import std.algorithm : count;

        const numFiles = cursor.readUint64();
        auto files = new FileInfo[numFiles];
        size_t numEmptyStreams;

        while (true)
        {
            const pos = cursor.pos;
            const propType = cursor.readPropId();

            if (propType == PropId.end)
            {
                writefln!"FilesInfo end at %04x"(pos);
                break;
            }

            const size = cursor.readUint64();
            writefln!"FilesInfo %s %s at %04x"(propType, size, pos);
            // cursor.ffw(size);
            // continue;

            switch (propType)
            {
            case PropId.dummy:
                cursor.ffw(size);
                break;
            case PropId.emptyStream:
                const emptyStreams = BooleanList.read(cursor, numFiles, No.checkAllDefined);
                numEmptyStreams = emptyStreams.count!(e => e);
                foreach (i, ref f; files)
                    f.emptyStream = emptyStreams[i];
                break;
            case PropId.emptyFile:
                auto emptyFiles = BooleanList.read(cursor, numEmptyStreams, No.checkAllDefined);
                size_t i;
                foreach (ref f; files)
                    if (f.emptyStream)
                        f.emptyFile = emptyFiles[i++];
                break;
            case PropId.anti:
                auto antiFiles = BooleanList.read(cursor, numEmptyStreams, No.checkAllDefined);
                size_t i;
                foreach (ref f; files)
                    if (f.emptyStream)
                        f.antiFile = antiFiles[i++];
                break;
            case PropId.ctime:
            case PropId.atime:
            case PropId.mtime:
            case PropId.attributes:
                const defined = BooleanList.read(cursor, numFiles, Yes.checkAllDefined);
                const external = !!cursor.get;
                writefln("  external %s", external);
                writefln("  defined %s", defined);
                ulong gotoPos = ulong.max;
                if (external)
                {
                    const dataIndex = cursor.readUint64();
                    gotoPos = cursor.pos;
                    writefln("  external to %04x", dataIndex);
                    cursor.seek(dataIndex);
                }
                scope (success)
                {
                    if (gotoPos != ulong.max)
                    {
                        writefln("  seeking back to %04x", gotoPos);
                        cursor.seek(gotoPos);
                    }
                }
                foreach (i, ref f; files)
                {
                    if (defined[i])
                    {
                        if (propType == PropId.attributes)
                        {
                            const data = cursor.getValue!uint();
                            f.attributes = data;
                        }
                        else
                        {
                            const data = cursor.getValue!long();
                            if (data >= long.max - hnsecsFrom1601)
                                bad7z(cursor.name, "Inconsistent file timestamp");
                            f.setTime(propType, data);
                        }
                    }
                }
                break;
            case PropId.names:
                const external = !!cursor.get;
                ulong gotoPos = ulong.max;
                if (external)
                {
                    const dataIndex = cursor.readUint64();
                    gotoPos = cursor.pos;
                    writefln("  external to %04x", dataIndex);
                    cursor.seek(dataIndex);
                }
                scope (success)
                {
                    if (gotoPos != ulong.max)
                    {
                        writefln("  seeking back to %04x", gotoPos);
                        cursor.seek(gotoPos);
                    }
                }
                foreach (ref f; files)
                {
                    wstring wname;
                    while (true)
                    {
                        const c = cursor.getValue!wchar();
                        if (c == 0)
                            break;
                        wname ~= c;
                    }
                    transcode(wname, f.name);
                    writeln("  found name ", f.name);
                }
                break;
            default:
                unexpectedPropId(cursor.name, propType, "FilesInfo");
            }
        }
        return files;
    }
}

private struct Header
{
    StreamsInfo mainStreams;
    FileInfo[] fileInfos;

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

        if (cursor.eoi)
            return res;

        enforceGetPropId(cursor, PropId.filesInfo, "Header");
        res.fileInfos = FileInfo.read(cursor);
        writefln("read FileInfo %s", res.fileInfos);

        enforceGetPropId(cursor, PropId.end, "Header");

        return res;
    }

    static Header readEncodedHeader(DB, C)(DB dbCursor, C cursor, ulong packedStreamStart)
    {
        import std.array : join;

        auto info = StreamsInfo.read(dbCursor);

        PackInfo packInfo = info.packInfo;
        CodersInfo codersInfo = info.codersInfo;

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
                uint crc = crc32(0, decompressed.ptr, cast(uint) decompressed.length);
                enforce(folder.unpackCrc == crc, "Header CRC check failed");
            }

            headerBuf ~= decompressed;
        }

        import std.algorithm : min;

        size_t pos = 0;
        writefln!"        %(%02x  %)"(iota(0, 16));
        writeln();
        while (pos < headerBuf.length)
        {
            const len = min(16, headerBuf.length - pos);
            writefln!"%04x    %(%02x  %)"(pos, headerBuf[pos .. pos + len]);
            pos += len;
        }

        auto hc = new ArrayCursor(headerBuf, cursor.name);
        hc.enforceGetPropId(PropId.header, "Header decoded database");
        return readHeader(hc);
    }
}

class EntryDecoder
{
    Cursor cursor;
    SquizAlgo algo;
    SquizStream stream;

    this(Cursor cursor, Folder folder)
    {
        this.cursor = cursor;
        algo = folder.unpackAlgo();
        stream = algo.initialize();
    }
}
