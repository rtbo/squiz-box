module squiz_box.box.seven_z.header;

package(squiz_box.box.seven_z):

import squiz_box.box.seven_z.error;
import squiz_box.box.seven_z.utils;
import squiz_box.priv;
import squiz_box.squiz;

import std.algorithm;
import std.array;
import std.bitmanip;
import std.conv;
import std.exception;
import std.format;
import std.typecons;

// dfmt off
enum PropId : ubyte
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
    encodedHeader           = 0x17,
    startPos                = 0x18,
    dummy                   = 0x19,
}
// dfmt on

PropId readPropId(C)(C cursor)
{
    return cast(PropId) cursor.get;
}

string propIdName(PropId id)
{
    return id > PropId.dummy ?
        format!"0x%02x"(
            cast(ubyte) id) : format!"%s (0x%02x)"(id.to!string, cast(ubyte) id);
}

noreturn unexpectedPropId(string source, PropId id, string section = __FUNCTION__)
{
    throw new Bad7zArchiveException(
        source,
        format!"Unexpected property in '%s': %s"(section, propIdName(id)),
    );
}

void enforceGetPropId(C)(C cursor, PropId propId, string section = __FUNCTION__)
{
    auto id = cast(PropId) cursor.get;
    if (id != propId)
        throw new Bad7zArchiveException(
            cursor.source,
            format!"Expected Property Id %s but found %s in '%s'"(
                propIdName(propId), propIdName(id), section
        )
        );
}

void whileNotEndPropId(alias fun, C)(C cursor)
{
    auto nextId = cursor.readPropId();
    while (!nextId == PropId.end)
    {
        fun(nextId);
        nextId = cursor.readPropId();
    }
}

struct SignatureHeader
{
    static const ubyte[6] magicBytes = ['7', 'z', 0xbc, 0xaf, 0x27, 0x1c];
    static const ubyte[2] versionBytes = [0, 4];

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
            new NotA7zArchiveException(cursor.source, "Not starting by magic bytes"),
        );

        const crc = Crc32.calc(&(rep.signature[0]) + 12, 20);
        if (crc != rep.headerCrc.val)
            bad7z(cursor.source, "Could not verify signature header CRC-32");

        SignatureHeader res = void;
        // check for 0.4
        res.ver = rep.ver[0] * 10 + rep.ver[1];
        if (res.ver != 4)
            unsupported7z(cursor.source, format!"Unsupported 7z version %s.%s"(rep.ver[0], rep.ver[1]));

        res.headerOffset = rep.nextHeaderOffset.val;
        res.headerSize = rep.nextHeaderSize.val;
        res.headerCrc = rep.nextHeaderCrc.val;

        return res;
    }

    uint ver;
    ulong headerOffset;
    ulong headerSize;
    uint headerCrc;

    @property ulong headerPos()
    {
        return headerOffset + Rep.sizeof;
    }
}

struct Header
{
    StreamsInfo streamsInfo;
    FilesInfo filesInfo;

    static Header read(HC, C)(HC headerCursor, C mainCursor, ulong packStartOffset)
    {
        const prop = headerCursor.readPropId();

        if (prop == PropId.header)
            return readPlain(headerCursor, mainCursor, packStartOffset);

        else if (prop == PropId.encodedHeader)
            return readEncoded(headerCursor, mainCursor, packStartOffset);

        unexpectedPropId(mainCursor.source, prop);
    }

    static Header readPlain(HC, C)(HC headerCursor, C mainCursor, ulong packStartOffset)
    {
        Header res;
        headerCursor.enforceGetPropId(PropId.mainStreamsInfo);
        res.streamsInfo = trace7z!(() => StreamsInfo.read(headerCursor));

        auto nextId = headerCursor.readPropId();
        if (nextId == PropId.filesInfo)
        {
            res.filesInfo = trace7z!(() => FilesInfo.read(headerCursor));

            nextId = headerCursor.readPropId();
        }

        if (nextId != PropId.end)
            bad7z(headerCursor.source, "Expected end property id");

        return res;
    }

    static Header readEncoded(HC, C)(HC headerCursor, C mainCursor, ulong packStartOffset)
    {
        const headerStreamsInfo = trace7z!(() => StreamsInfo.read(headerCursor));

        enforce(headerStreamsInfo.numFolders == 1, "Invalid encoded header (multiple folders)");
        const packSize = headerStreamsInfo.streamPackSize(0);
        const packStart = headerStreamsInfo.streamPackStart(0);
        const unpackSize = headerStreamsInfo.folderUnpackSize(0);

        auto algo = headerStreamsInfo.folderInfo(0).buildUnpackAlgo();
        mainCursor.seek(packStartOffset + packStart);
        auto unpacked = cursorByteRange(mainCursor, packSize)
            .squizMaxOut(algo, unpackSize)
            .join();
        assert(unpacked.length = unpackSize);

        static if (false)
        {
            size_t pos = 0;
            io.writefln!"Unpacked header:"();
            io.writefln!"        %(%02x  %)"(iota(0, 16));
            io.writeln();
            while (pos < unpacked.length)
            {
                const len = min(16, unpacked.length - pos);
                io.writefln!"%04x    %(%02x  %)"(pos, unpacked[pos .. pos + len]);
                pos += len;
            }
            io.writeln();
        }

        auto hc = new ArrayCursor(unpacked, mainCursor.source);
        hc.enforceGetPropId(PropId.header);
        return readPlain(hc, mainCursor, packStartOffset);
    }

    @property size_t numFiles() const
    {
        return filesInfo.files.length;
    }
}

struct StreamsInfo
{
    PackInfo packInfo;
    CodersInfo codersInfo;
    SubStreamsInfo subStreamsInfo;

    static StreamsInfo read(C)(C cursor)
    {
        StreamsInfo res;

        cursor.whileNotEndPropId!((PropId propId) {
            switch (propId)
            {
            case PropId.packInfo:
                res.packInfo = trace7z!(() => PackInfo.read(cursor));
                break;
            case PropId.unpackInfo:
                res.codersInfo = trace7z!(() => CodersInfo.read(cursor));
                break;
            case PropId.subStreamsInfo:
                res.subStreamsInfo = trace7z!(() => SubStreamsInfo.read(cursor, res));
                break;
            default:
                unexpectedPropId(cursor.source, propId);
            }
        });

        if (res.numStreams != res.numFolders)
            unsupported7z(cursor.source, "Only single stream folders are supported");

        return res;
    }

    @property size_t numStreams() const
    {
        return packInfo.packSizes.length;
    }

    ulong streamPackStart(size_t s) const
    {
        ulong start = packInfo.packStart;
        foreach (ss; 0 .. s)
            start += packInfo.packSizes[ss];
        return start;
    }

    ulong streamPackSize(size_t s) const
    {
        return packInfo.packSizes[s];
    }

    Crc32 streamPackCrc32(size_t s) const
    {
        return packInfo.packCrcs.length ? packInfo.packCrcs[s] : Crc32(0);
    }

    @property size_t numFolders() const
    {
        return codersInfo.folderInfos.length;
    }

    @property inout(FolderInfo) folderInfo(size_t f) inout
    {
        return codersInfo.folderInfos[f];
    }

    ulong folderUnpackSize(size_t f) const
    {
        return codersInfo.unpackSizes[f];
    }

    Crc32 folderUnpackCrc32(size_t f) const
    {
        return codersInfo.unpackCrcs.length ? codersInfo.unpackCrcs[f] : Crc32(0);
    }

    size_t folderSubstreams(size_t f) const
    {
        return subStreamsInfo.nums[f];
    }

    ulong folderSubstreamStart(size_t f, size_t s)
    {
        const s0 = subStreamsInfo.folderSizesStartIdx(f);

        ulong start = 0;
        foreach (ss; 0 .. s)
            start += subStreamsInfo.sizes[s0 + ss];

        return start;
    }

    ulong folderSubstreamSize(size_t f, size_t s)
    {
        const folderSize = codersInfo.unpackSizes[f];
        const numStreams = subStreamsInfo.nums[f];
        const s0 = subStreamsInfo.folderSizesStartIdx(f);

        if (s == numStreams - 1) // last stream of folder
            return folderSize - sum(subStreamsInfo.sizes[s0 .. s0 + s]);
        else
            return subStreamsInfo.sizes[s0 + s];
    }
}

struct PackInfo
{
    ulong packStart;
    ulong[] packSizes;
    Crc32[] packCrcs;

    static PackInfo read(C)(C cursor)
    {
        PackInfo res;
        res.packStart = cursor.readUint64();

        const numStreams = cursor.readUint32();

        cursor.whileNotEndPropId!((PropId propId) {
            switch (propId)
            {
            case PropId.size:
                res.packSizes = hatch!(() => cursor.readUint64())
                    .take(numStreams)
                    .array;
                break;
            case PropId.crc:
                auto defined = cursor.readBooleanList(numStreams);
                res.packCrcs = new Crc32[numStreams];
                foreach (i; 0 .. numStreams)
                {
                    // dfmt off
                    if (defined[i])
                        res.packCrcs[i] = cursor.readCrc32();
                    // dfmt on
                }
                break;
            default:
                unexpectedPropId(cursor.source, propId);
            }
        });

        return res;
    }
}

struct CodersInfo
{
    FolderInfo[] folderInfos;
    ulong[] unpackSizes;
    Crc32[] unpackCrcs;

    static CodersInfo read(C)(C cursor)
    {
        cursor.enforceGetPropId(PropId.folder);
        const numFolders = cursor.readUint32();
        const bool ext = cursor.get != 0;
        if (ext)
            unsupported7z(cursor.source, "Unsupported out-of-band folder definition");

        CodersInfo res;
        res.folderInfos = hatch!(() => trace7z!(() => FolderInfo.read(cursor)))
            .take(numFolders)
            .array;

        cursor.whileNotEndPropId!((PropId propId) {
            switch (propId)
            {
            case PropId.codersUnpackSize:
                res.unpackSizes = hatch!(() => cursor.readUint64())
                    .take(numFolders)
                    .array;
                break;
            case PropId.crc:
                res.unpackCrcs = new Crc32[numFolders];
                auto defined = cursor.readBooleanList(numFolders);
                foreach (i; 0 .. numFolders)
                {
                    // dfmt off
                    if (defined[i])
                        res.unpackCrcs[i] = cursor.readCrc32();
                    // dfmt on
                }
                break;
            default:
                unexpectedPropId(cursor.source, propId);
            }
        });
        return res;
    }
}

struct FolderInfo
{
    CoderInfo[] coderInfos;

    static FolderInfo read(C)(C cursor)
    {
        const numCoders = cursor.readUint32();

        return FolderInfo(
            hatch!(() => trace7z!(() => CoderInfo.read(cursor)))
                .take(numCoders)
                .array
        );
    }

    SquizAlgo buildUnpackAlgo() const
    {
        if (coderInfos.all!(ci => ci.isLzmaFilter))
        {
            auto filters = coderInfos.map!(ci => ci.lzmaFilter).array;
            return squizAlgo(DecompressLzma(filters));
        }

        auto algos = coderInfos.map!(ci => ci.buildUnpackSingleAlgo()).array;
        return squizCompoundAlgo(algos);
    }
}

struct SubStreamsInfo
{

    uint[] nums; // one entry per folder
    ulong[] sizes; // one entry per substream except for last folder substream
    Crc32[] crcs; // one entry per undefined Crc in parent StreamsInfo

    static SubStreamsInfo read(C)(C cursor, const ref StreamsInfo streamsInfo)
    {
        SubStreamsInfo res;

        cursor.whileNotEndPropId!((PropId propId) {
            switch (propId)
            {
            case PropId.numUnpackStream:
                res.nums = hatch!(() => cursor.readUint32())
                    .take(streamsInfo.numFolders)
                    .array;
                break;
            case PropId.size:
                res.readSizes(cursor, streamsInfo);
                break;
            case PropId.crc:
                res.readCrcs(cursor, streamsInfo);
                break;
            default:
                unexpectedPropId(cursor.source, propId);
            }
        });

        return res;
    }

    void readSizes(C)(C cursor, const ref StreamsInfo streamsInfo)
    {
        if (this.nums.length)
        {
            foreach (f; 0 .. streamsInfo.numFolders)
            {
                foreach (s; 0 .. this.nums[f] - 1)
                {
                    const size = cursor.readUint64();
                    this.sizes ~= size;
                }
            }
        }
    }

    void readCrcs(C)(C cursor, const ref StreamsInfo streamsInfo)
    {
        const numFolders = streamsInfo.numFolders;
        size_t numCrcs = 0;
        // count number of undefined CRCs
        foreach (f; 0 .. numFolders)
        {
            const num = this.nums.length ? this.nums[f] : 1;
            if (num == 1 && !streamsInfo.folderUnpackCrc32(f))
                numCrcs += 1;
            else if (num > 1)
                numCrcs += num;
        }
        const defined = cursor.readBooleanList(numCrcs);
        foreach (i; 0 .. numCrcs)
        {
            // dfmt off
            if (defined[i])
                this.crcs ~= cursor.readCrc32();
            // dfmt on
        }
    }

    size_t folderSizesStartIdx(size_t f)
    {
        size_t idx = 0;
        foreach (ff; 0 .. f)
            idx += nums[ff] - 1;
        return idx;
    }
}

private enum long hnsecsFrom1601 = 504_911_232_000_000_000L;

struct FileInfo
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
}

struct FilesInfo
{
    FileInfo[] files;

    size_t dummyBytes;

    static FilesInfo read(C)(C cursor)
    {
        FilesInfo res;

        const numFiles = cursor.readUint32();
        res.files = new FileInfo[numFiles];
        size_t numEmptyStreams = 0;

        cursor.whileNotEndPropId!((PropId propId) {
            const size = cursor.readUint64();
            const pos = cursor.pos;
            const nextPos = pos + size;
            scope (success)
            {
                if (cursor.pos > nextPos)
                    bad7z(cursor.source, format!"Inconsistent file properties: %s"(propId));
                cursor.seek(nextPos);
            }

            switch (propId)
            {
            case PropId.dummy:
                res.dummyBytes = size;
                break;
            case PropId.emptyStream:
                auto emptyStreams = cursor.readBitField(numFiles);
                numEmptyStreams = emptyStreams.count;
                foreach (i, es; emptyStreams)
                    res.files[i].emptyStream = es;
                break;
            case PropId.emptyFile:
                auto emptyFiles = cursor.readBitField(numEmptyStreams);
                size_t i;
                foreach (ref f; res.files)
                {
                    if (f.emptyStream)
                        f.emptyFile = emptyFiles[i++];
                }
                break;
            case PropId.anti:
                auto antiFiles = cursor.readBitField(numEmptyStreams);
                size_t i;
                foreach (ref f; res.files)
                {
                    if (f.emptyStream)
                        f.antiFile = antiFiles[i++];
                }
                break;
            case PropId.names:
                //const defined = cursor.readBooleanList(numFiles);
                const external = !!cursor.get;
                if (external)
                    unsupported7z(cursor.source, "Out-of-band file name");
                foreach (i, ref f; res.files)
                {
                    import std.encoding : transcode;

                    // if (!defined[i])
                    //     continue;

                    wstring wname;
                    wchar c = cursor.getValue!wchar();
                    while (c != 0)
                    {
                        wname ~= c;
                        c = cursor.getValue!wchar();
                    }
                    transcode(wname, f.name);
                }
                break;
            case PropId.mtime:
            case PropId.atime:
            case PropId.ctime:
                const defined = cursor.readBooleanList(numFiles);
                const external = !!cursor.get;
                if (external)
                    unsupported7z(cursor.source, "Out-of-band file timestamp");
                foreach (i, ref f; res.files)
                {
                    if (!defined[i])
                    continue;
                    const data = cursor.getValue!long();
                    if (data >= long.max - hnsecsFrom1601)
                        bad7z(cursor.source, "Inconsistent file timestamp");
                    f.setTime(propId, data);
                }
                break;
            case PropId.attributes:
                const defined = cursor.readBooleanList(numFiles);
                const external = !!cursor.get;
                if (external)
                    unsupported7z(cursor.source, "Out-of-band file timestamp");
                foreach (i, ref f; res.files)
                {
                    if (!defined[i])
                    continue;

                    f.attributes = cursor.getValue!uint();
                }
                break;
            default:
                unexpectedPropId(cursor.source, propId);
            }
        });

        return res;
    }
}

struct CoderFlags
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

// dfmt off
enum CoderId : uint
{
    copy        = 0x00,
    delta       = 0x03,
    bcjX86      = 0x04,
    lzma2       = 0x21,
    lzma1       = 0x030101,
    bzip2       = 0x040202,
    deflate     = 0x040108,
    deflate64   = 0x040109,
    p7zBcj      = 0x03030103,
    p7ZBcj2     = 0x0303011b,
    bcjPowerPc  = 0x03030205,
    bcjIa64     = 0x03030301,
    bcjArm      = 0x03030501,
    bcjArmThumb = 0x03030701,
    bcjSparc    = 0x03030805,
    zstd        = 0x04f71101,
    brotli      = 0x04f71102,
    lz4         = 0x04f71104,
    lzs         = 0x04f71105,
    lizard      = 0x04f71106,
    aes         = 0x06f10701,
}
// dfmt on

struct CoderInfo
{
    CoderId id;
    ubyte[] props;

    static CoderInfo read(C)(C cursor)
    {
        const flags = CoderFlags(cursor.get);
        if (flags.isComplexCoder)
            unsupported7z(cursor.source, "unsupported complex coder");

        if (flags.idSize < 1 || flags.idSize > 4)
            bad7z(cursor.source, format!"Improper coder id size: %s"(flags.idSize));

        ubyte[4] idBuf;
        ubyte[] idSlice = idBuf[0 .. flags.idSize];
        cursor.read(idSlice);

        ubyte[] coderProps;
        if (flags.thereAreAttributes)
        {
            const size = readUint32(cursor);
            coderProps = new ubyte[size];
            cursor.read(coderProps);
        }

        uint coderId = idSlice[0];
        foreach (idB; idSlice[1 .. $])
        {
            coderId <<= 8;
            coderId |= idB;
        }

        return CoderInfo(cast(CoderId) coderId, coderProps);
    }

    @property bool isLzmaFilter() const
    {
        switch (this.id)
        {
        case CoderId.delta:
        case CoderId.bcjX86:
        case CoderId.lzma2:
        case CoderId.lzma1:
        case CoderId.bcjPowerPc:
        case CoderId.bcjIa64:
        case CoderId.bcjArm:
        case CoderId.bcjArmThumb:
        case CoderId.bcjSparc:
            return true;
        default:
            return false;
        }
    }

    @property LzmaFilter lzmaFilter() const
    {
        switch (this.id)
        {
        case CoderId.delta:
            return LzmaRawFilter.delta(this.props).into;
        case CoderId.bcjX86:
            return LzmaRawFilter.bcjX86(this.props).into;
        case CoderId.lzma2:
            return LzmaRawFilter.lzma2(this.props).into;
        case CoderId.lzma1:
            return LzmaRawFilter.lzma1(this.props).into;
        case CoderId.bcjPowerPc:
            return LzmaRawFilter.bcjPowerPc(this.props).into;
        case CoderId.bcjIa64:
            return LzmaRawFilter.bcjIa64(this.props).into;
        case CoderId.bcjArm:
            return LzmaRawFilter.bcjArm(this.props).into;
        case CoderId.bcjArmThumb:
            return LzmaRawFilter.bcjArmThumb(this.props).into;
        case CoderId.bcjSparc:
            return LzmaRawFilter.bcjSparc(this.props).into;
        default:
            assert(false);
        }
    }

    /// Build a decompression SquizAlgo for this coder.
    /// This function must be called if there is a single coder
    /// in the chain or if the different coders can't be combined
    /// in a LZMA filter chain (e.g. deflate, aes, ...)
    SquizAlgo buildUnpackSingleAlgo() const
    {
        final switch (this.id)
        {
        case CoderId.copy:
            return squizAlgo(Copy());
        case CoderId.delta:
            return squizAlgo(DecompressLzma(
                    [LzmaRawFilter.delta(this.props).into],
            ));
        case CoderId.bcjX86:
            return squizAlgo(DecompressLzma(
                    [LzmaRawFilter.bcjX86(this.props).into],
            ));
        case CoderId.lzma2:
            return squizAlgo(DecompressLzma(
                    [LzmaRawFilter.lzma2(this.props).into],
            ));
        case CoderId.lzma1:
            return squizAlgo(DecompressLzma(
                    [LzmaRawFilter.lzma1(this.props).into],
            ));
        case CoderId.bcjPowerPc:
            return squizAlgo(DecompressLzma(
                    [LzmaRawFilter.bcjPowerPc(this.props).into],
            ));
        case CoderId.bcjIa64:
            return squizAlgo(DecompressLzma(
                    [LzmaRawFilter.bcjIa64(this.props).into],
            ));
        case CoderId.bcjArm:
            return squizAlgo(DecompressLzma(
                    [LzmaRawFilter.bcjArm(this.props).into],
            ));
        case CoderId.bcjArmThumb:
            return squizAlgo(DecompressLzma(
                    [LzmaRawFilter.bcjArmThumb(this.props).into],
            ));
        case CoderId.bcjSparc:
            return squizAlgo(DecompressLzma(
                    [LzmaRawFilter.bcjSparc(this.props).into],
            ));
        case CoderId.deflate:
            return squizAlgo(Inflate());
        case CoderId.bzip2:
            version (HaveSquizBzip2)
            {
                return squizAlgo(DecompressBzip2());
            }
            else
            {
                continue;
            }
        case CoderId.zstd:
            version (HaveSquizZstandard)
            {
                return squizAlgo(DecompressZstd());
            }
            else
            {
                continue;
            }
        case CoderId.deflate64:
        case CoderId.p7zBcj:
        case CoderId.p7ZBcj2:
        case CoderId.brotli:
        case CoderId.lz4:
        case CoderId.lzs:
        case CoderId.lizard:
        case CoderId.aes:
            throw new Exception(format!"Unsupported coder id: %s"(this.id));
        }
    }
}
