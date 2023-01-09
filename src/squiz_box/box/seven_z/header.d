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

static assert(PropId.sizeof == 1);

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
    ubyte[6] magicBytes;
    ubyte[2] versionBytes;
    Crc32 signHeaderCrc;
    ulong headerOffset;
    ulong headerSize;
    Crc32 headerCrc;

    enum byteLength = 32;
    static const ubyte[6] magicBytesRef = ['7', 'z', 0xbc, 0xaf, 0x27, 0x1c];
    static const ubyte[2] versionBytesRef = [0, 4];

    static SignatureHeader read(C)(C cursor)
    {
        SignatureHeader res;

        ubyte[byteLength] buf;
        cursor.read(buf[]);

        auto bufC = new ArrayCursor(buf[]);

        bufC.readValue(&res.magicBytes);
        if (res.magicBytes != magicBytesRef)
            bad7z(cursor.source, "Not a 7z file");

        bufC.readValue(&res.versionBytes);
        if (res.versionBytes != versionBytesRef)
            unsupported7z(
                cursor.source,
                format!"Unsupported 7z version: %s.%s"(res.versionBytes[0], res.versionBytes[1])
        );

        res.signHeaderCrc = bufC.readCrc32();

        res.headerOffset = bufC.getValue!ulong;
        res.headerSize = bufC.getValue!ulong;
        res.headerCrc = bufC.getValue!Crc32;

        if (res.signHeaderCrc != res.calcSignHeaderCrc)
            bad7z(cursor.source, "Could not verify signature header integrity");

        return res;
    }

    void write(C)(C cursor)
    {
        cursor.write(magicBytes);
        cursor.write(versionBytes);
        cursor.putValue(signHeaderCrc);
        cursor.putValue(headerOffset);
        cursor.putValue(headerSize);
        cursor.putValue(headerCrc);
    }

    @property ulong headerPos() const
    {
        return headerOffset + byteLength;
    }

    Crc32 calcSignHeaderCrc() const
    {
        Crc32 crc;
        crc.updateWith(headerOffset);
        crc.updateWith(headerSize);
        crc.updateWith(headerCrc);
        return crc;
    }
}

struct Header
{
    MainStreamsInfo streamsInfo;
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
        res.streamsInfo = traceRead!(() => MainStreamsInfo.read(headerCursor));

        auto nextId = headerCursor.readPropId();
        if (nextId == PropId.filesInfo)
        {
            res.filesInfo = traceRead!(() => FilesInfo.read(headerCursor));

            nextId = headerCursor.readPropId();
        }

        if (nextId != PropId.end)
            bad7z(headerCursor.source, "Expected end property id");

        return res;
    }

    static Header readEncoded(HC, C)(HC headerCursor, C mainCursor, ulong packStartOffset)
    {
        const headerStreamsInfo = traceRead!(() => HeaderStreamsInfo.read(headerCursor));

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
            import squiz_box.util : hexDump;
            import std.range : only;

            io.writeln();
            io.writefln!"Unpacked header:";
            only(unpacked).hexDump(io.stdout.lockingTextWriter);
            io.writeln();
        }

        auto hc = new ArrayCursor(unpacked, mainCursor.source);
        hc.enforceGetPropId(PropId.header);
        return readPlain(hc, mainCursor, packStartOffset);
    }

    void write(C : WriteCursor)(C cursor)
    {
        cursor.put(PropId.header);

        streamsInfo.traceWrite(cursor);
        filesInfo.traceWrite(cursor);

        cursor.put(PropId.end);
    }

    @property size_t numFiles() const
    {
        return filesInfo.files.length;
    }
}

struct HeaderStreamsInfo
{
    PackInfo packInfo;
    CodersInfo codersInfo;

    static HeaderStreamsInfo read(C)(C cursor)
    {
        HeaderStreamsInfo res;

        cursor.whileNotEndPropId!((PropId propId) {
            switch (propId)
            {
            case PropId.packInfo:
                res.packInfo = traceRead!(() => PackInfo.read(cursor));
                break;
            case PropId.unpackInfo:
                res.codersInfo = traceRead!(() => CodersInfo.read(cursor));
                break;
            default:
                unexpectedPropId(cursor.source, propId);
            }
        });

        if (res.numStreams != res.numFolders)
            unsupported7z(cursor.source, "Only single stream folders are supported");

        return res;
    }

    void write(C)(C cursor)
    {
        cursor.put(PropId.encodedHeader);
        packInfo.traceWrite(cursor);
        codersInfo.traceWrite(cursor);
        cursor.put(PropId.end);
    }

    mixin StreamsInfoCommon!();
}

struct MainStreamsInfo
{
    PackInfo packInfo;
    CodersInfo codersInfo;
    SubStreamsInfo subStreamsInfo;

    static MainStreamsInfo read(C)(C cursor)
    {
        MainStreamsInfo res;

        cursor.whileNotEndPropId!((PropId propId) {
            switch (propId)
            {
            case PropId.packInfo:
                res.packInfo = traceRead!(() => PackInfo.read(cursor));
                break;
            case PropId.unpackInfo:
                res.codersInfo = traceRead!(() => CodersInfo.read(cursor));
                break;
            case PropId.subStreamsInfo:
                res.subStreamsInfo = traceRead!(() => SubStreamsInfo.read(cursor, res));
                break;
            default:
                unexpectedPropId(cursor.source, propId);
            }
        });

        if (res.numStreams != res.numFolders)
            unsupported7z(cursor.source, "Only single stream folders are supported");

        return res;
    }

    void write(C)(C cursor)
    {
        cursor.put(PropId.mainStreamsInfo);
        packInfo.traceWrite(cursor);
        codersInfo.traceWrite(cursor);
        subStreamsInfo.traceWrite(cursor);
        cursor.put(PropId.end);
    }

    mixin StreamsInfoCommon!();

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

private mixin template StreamsInfoCommon()
{
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
}

struct PackInfo
{
    ulong packStart;
    ulong[] packSizes;
    Crc32[] packCrcs;

    static PackInfo read(C)(C cursor)
    {
        PackInfo res;
        res.packStart = cursor.readNumber();

        const numStreams = cast(size_t) cursor.readNumber();

        cursor.whileNotEndPropId!((PropId propId) {
            switch (propId)
            {
            case PropId.size:
                res.packSizes = hatch!(() => cursor.readNumber())
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

    void write(C)(C cursor)
    {
        cursor.put(PropId.packInfo);
        cursor.writeNumber(packStart);
        cursor.writeNumber(packSizes.length);
        if (packSizes.length)
        {
            cursor.put(PropId.size);
            foreach (s; packSizes)
                cursor.writeNumber(s);
        }
        if (packCrcs.length)
        {
            enforce(packCrcs.length == packSizes.length, "Inconsistent CRC length");
            cursor.put(PropId.crc);
            cursor.put(0x01); // all defined
            foreach (crc; packCrcs)
                cursor.putValue(crc);
        }
        cursor.put(PropId.end);
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
        const numFolders = cast(size_t) cursor.readNumber();
        const bool ext = cursor.get != 0;
        if (ext)
            unsupported7z(cursor.source, "Unsupported out-of-band folder definition");

        CodersInfo res;
        res.folderInfos = hatch!(() => traceRead!(() => FolderInfo.read(cursor)))
            .take(numFolders)
            .array;

        cursor.whileNotEndPropId!((PropId propId) {
            switch (propId)
            {
            case PropId.codersUnpackSize:
                const numUnpackSizes = sum(res.folderInfos.map!(f => f.numOutStreams));
                res.unpackSizes = hatch!(() => cursor.readNumber())
                    .take(numUnpackSizes)
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

    void write(C)(C cursor)
    {
        cursor.put(PropId.unpackInfo);

        cursor.put(PropId.folder);
        cursor.writeNumber(folderInfos.length);
        cursor.put(0x00); // not external
        foreach (f; folderInfos)
            f.traceWrite(cursor);

        if (unpackSizes.length)
        {
            cursor.put(PropId.codersUnpackSize);
            foreach (sz; unpackSizes)
                cursor.writeNumber(sz);
        }

        if (unpackCrcs.length)
        {
            enforce(
                unpackCrcs.length == unpackSizes.length,
                "Inconsistent Unpack state"
            );
            cursor.put(PropId.crc);
            BitArray defined;
            defined.length = unpackCrcs.length;
            foreach (i, crc; unpackCrcs)
            {
                if (crc)
                    defined[i] = true;
            }
            cursor.writeBooleanList(defined);
            foreach (crc; unpackCrcs)
            {
                if (crc)
                    cursor.writeCrc32(crc);
            }
        }

        cursor.put(PropId.end);
    }
}

struct BindPair
{
    size_t input;
    size_t output;
}

struct FolderInfo
{

    CoderInfo[] coderInfos;
    BindPair[] bindPairs;

    static FolderInfo read(C)(C cursor)
    {
        FolderInfo res;

        const numCoders = cast(size_t) cursor.readNumber();

        res.coderInfos = hatch!(() => traceRead!(() => CoderInfo.read(cursor)))
            .take(numCoders)
            .array;

        const numBindPairs = res.numOutStreams - 1;
        if (numBindPairs > 0)
        {
            res.bindPairs = new BindPair[numBindPairs];
            foreach (ref bp; res.bindPairs)
            {
                bp.input = cursor.readNumber();
                bp.output = cursor.readNumber();
            }
        }
        const numPackedStreams = res.numInStreams - numBindPairs;
        if (numPackedStreams > 1)
            unsupported7z(cursor.source, "Unsupported packed stream index (complex coder)");

        return res;
    }

    void write(C)(C cursor)
    {
        cursor.writeNumber(coderInfos.length);
        foreach (coder; coderInfos)
            coder.traceWrite(cursor);
        foreach (bp; bindPairs)
        {
            cursor.writeNumber(bp.input);
            cursor.writeNumber(bp.output);
        }
    }

    size_t numInStreams() const
    {
        return sum(this.coderInfos.map!(ci => ci.numInStreams));
    }

    size_t numOutStreams() const
    {
        return sum(this.coderInfos.map!(ci => ci.numOutStreams));
    }

    SquizAlgo buildUnpackAlgo() const
    {
        if (coderInfos.all!(ci => ci.isLzmaFilter))
        {
            auto filters = coderInfos.map!(ci => ci.lzmaFilter).array;
            // 7z specify filters in decompression order, but LZMA expects them in compression order
            reverse(filters);
            return squizAlgo(DecompressLzma(filters));
        }

        auto algos = coderInfos.map!(ci => ci.buildUnpackSingleAlgo()).array;
        return squizCompoundAlgo(algos);
    }
}

struct SubStreamsInfo
{
    size_t[] nums; // one entry per folder
    ulong[] sizes; // one entry per substream except for last folder substream
    Crc32[] crcs; // one entry per undefined Crc in parent StreamsInfo

    static SubStreamsInfo read(C)(C cursor, const ref MainStreamsInfo streamsInfo)
    {
        SubStreamsInfo res;

        cursor.whileNotEndPropId!((PropId propId) {
            switch (propId)
            {
            case PropId.numUnpackStream:
                res.nums = hatch!(() => cast(size_t) cursor.readNumber())
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

    void readSizes(C)(C cursor, const ref MainStreamsInfo streamsInfo)
    {
        if (this.nums.length)
        {
            foreach (f; 0 .. streamsInfo.numFolders)
            {
                foreach (s; 0 .. this.nums[f] - 1)
                {
                    const size = cursor.readNumber();
                    this.sizes ~= size;
                }
            }
        }
    }

    void readCrcs(C)(C cursor, const ref MainStreamsInfo streamsInfo)
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

    void write(C)(C cursor)
    {
        if (nums.length == 0 && sizes.length == 0 && crcs.length == 0)
            return;

        cursor.put(PropId.subStreamsInfo);
        if (nums.length)
        {
            cursor.put(PropId.numUnpackStream);
            foreach (n; nums)
                cursor.writeNumber(n);
        }
        if (sizes.length)
        {
            cursor.put(PropId.size);
            foreach (s; sizes)
                cursor.writeNumber(s);
        }
        if (crcs.length)
        {
            cursor.put(PropId.crc);
            cursor.put(0x01); // all defined
            foreach (crc; crcs)
                cursor.putValue(crc);
        }
        cursor.put(PropId.end);
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

private long toStdTime(long sevZtime)
{
    return sevZtime + hnsecsFrom1601;
}

private long toSevZtime(long stdTime)
{
    return stdTime - hnsecsFrom1601;
}

struct FileInfo
{
    string name;
    long ctime;
    long atime;
    long mtime;

    uint attributes;

    bool emptyStream; // could be an empty file or directory
    bool emptyFile; // plain empty file

    void setTime(PropId id, long time)
    {
        switch (id)
        {
        case PropId.ctime:
            ctime = time;
            break;
        case PropId.atime:
            atime = time;
            break;
        case PropId.mtime:
            mtime = time;
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

        const numFiles = cast(size_t) cursor.readNumber();
        res.files = new FileInfo[numFiles];
        size_t numEmptyStreams = 0;

        cursor.whileNotEndPropId!((PropId propId) {
            const size = cursor.readNumber();
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
                // file item that delete a file or directory (used by 7-zip for updating archives)
                unsupported7z(cursor.source, "Anti-file are not supported");
            case PropId.names:
                const external = !!cursor.get;
                if (external)
                    unsupported7z(cursor.source, "Out-of-band file name");
                const sz = size - 1;
                if (sz % 2 != 0)
                    bad7z(cursor.source, "Expected even bytes for UTF16");
                const(wchar)[] nameData = cast(const(wchar)[]) readArray(cursor, sz);
                version (BigEndian)
                {
                    static assert(false, "Big endian not supported");
                }
                foreach (i, ref f; res.files)
                {
                    import std.encoding : transcode;

                    size_t len = 0;
                    while (nameData[len] != 0)
                    len++;

                    const wname = nameData[0 .. len];
                    nameData = nameData[len + 1 .. $];
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
                    const time = cursor.getValue!long();
                    if (time >= long.max - hnsecsFrom1601)
                        bad7z(cursor.source, "Inconsistent file timestamp");
                    f.setTime(propId, toStdTime(time));
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

    void write(C)(C cursor) const
    {
        if (!files.length)
            return;

        cursor.put(PropId.filesInfo);
        cursor.writeNumber(files.length);

        BitArray emptyStreams;
        BitArray emptyFiles;
        BitArray definedMtime;
        BitArray definedCtime;
        BitArray definedAtime;
        BitArray definedAttrs;

        emptyStreams.length = files.length;
        definedMtime.length = files.length;
        definedCtime.length = files.length;
        definedAtime.length = files.length;
        definedAttrs.length = files.length;

        foreach (i, const ref f; files)
        {
            if (f.emptyStream)
            {
                emptyStreams[i] = true;
                emptyFiles ~= f.emptyFile;
            }

            if (f.mtime)
                definedMtime[i] = true;
            if (f.ctime)
                definedCtime[i] = true;
            if (f.atime)
                definedAtime[i] = true;
            if (f.attributes)
                definedAttrs[i] = true;
        }

        void writeProperty(PropId propId, const(ubyte)[] data)
        {
            cursor.put(propId);
            cursor.writeNumber(data.length);
            cursor.write(data);
        }

        auto bufC = new ArrayWriteCursor();

        // empty streams
        bufC.writeBooleanList(emptyStreams);
        writeProperty(PropId.emptyStream, bufC.data);
        bufC.clear();

        // empty files
        bufC.writeBooleanList(emptyFiles);
        writeProperty(PropId.emptyFile, bufC.data);
        bufC.clear();

        // names
        bufC.put(0x00); // not external
        foreach (f; files)
        {
            import std.encoding : transcode;

            wstring utf16;
            transcode(f.name, utf16);
            utf16 ~= wchar(0);
            bufC.write(cast(const(ubyte)[]) utf16);
        }
        writeProperty(PropId.names, bufC.data);
        bufC.clear();

        // mtime
        bufC.writeBooleanList(definedMtime);
        bufC.put(0x00); // not external
        foreach (f; files)
        {
            if (f.mtime)
                bufC.putValue(toSevZtime(f.mtime));
        }
        writeProperty(PropId.mtime, bufC.data);
        bufC.clear();

        // ctime
        bufC.writeBooleanList(definedCtime);
        bufC.put(0x00); // not external
        foreach (f; files)
        {
            if (f.ctime)
                bufC.putValue(toSevZtime(f.ctime));
        }
        writeProperty(PropId.ctime, bufC.data);
        bufC.clear();

        // atime
        bufC.writeBooleanList(definedAtime);
        bufC.put(0x00); // not external
        foreach (f; files)
        {
            if (f.atime)
                bufC.putValue(toSevZtime(f.atime));
        }
        writeProperty(PropId.atime, bufC.data);
        bufC.clear();

        // attrs
        bufC.writeBooleanList(definedAttrs);
        bufC.put(0x00); // not external
        foreach (f; files)
        {
            if (f.attributes)
                bufC.putValue(f.attributes);
        }
        writeProperty(PropId.attributes, bufC.data);
        bufC.clear();

        cursor.put(PropId.end);
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

    @property void idSize(ubyte sz)
    {
        rep = (rep & 0xf0) | (sz & 0x0f);
    }

    @property bool isComplexCoder() const
    {
        return (rep & 0x10) != 0;
    }

    @property void isComplexCoder(bool complex)
    {
        if (complex)
            rep |= 0b0001_0000;
        else
            rep &= 0b1110_1111;
    }

    @property bool thereAreAttributes() const
    {
        return (rep & 0x20) != 0;
    }

    @property void thereAreAttributes(bool yes)
    {
        if (yes)
            rep |= 0b0010_0000;
        else
            rep &= 0b1101_1111;
    }
}

// dfmt off
enum CoderId : uint
{
    copy            = 0x00,
    delta           = 0x03,
    bcjX86          = 0x04,
    bcjPowerPc      = 0x05,
    bcjIa64         = 0x06,
    bcjArm          = 0x07,
    bcjArmThumb     = 0x08,
    bcjSparc        = 0x09,
    lzma2           = 0x21,
    swap2           = 0x020302,
    swap4           = 0x020304,
    lzma1           = 0x030101,
    bzip2           = 0x040202,
    deflate         = 0x040108,
    deflate64       = 0x040109,
    p7zBcj          = 0x03030103,
    p7zBcj2         = 0x0303011b,
    p7zBcjPowerPc   = 0x03030205,
    p7zBcjIa64      = 0x03030301,
    p7zBcjArm       = 0x03030501,
    p7zBcjArmThumb  = 0x03030701,
    p7zBcjSparc     = 0x03030805,
    zstd            = 0x04f71101,
    brotli          = 0x04f71102,
    lz4             = 0x04f71104,
    lzs             = 0x04f71105,
    lizard          = 0x04f71106,
    aes             = 0x06f10701,
}
// dfmt on

@property ubyte coderIdSize(CoderId id)
{
    const num = cast(uint) id;
    if (num <= 0xff)
        return 1;
    else if (num <= 0xffff)
        return 2;
    else if (num <= 0xff_ffff)
        return 3;
    else
        return 4;
}

struct CoderInfo
{
    CoderId id;
    ubyte[] props;

    // complex coder not supported
    enum numInStreams = 1;
    enum numOutStreams = 1;

    static CoderInfo read(C)(C cursor)
    {
        const flags = CoderFlags(cursor.get);
        if (flags.isComplexCoder)
            unsupported7z(cursor.source, "Complex coders are not supported");

        if (flags.idSize < 1 || flags.idSize > 4)
            bad7z(cursor.source, format!"Improper coder id size: %s"(flags.idSize));

        ubyte[4] idBuf;
        ubyte[] idSlice = idBuf[0 .. flags.idSize];
        cursor.read(idSlice);
        uint coderId = idSlice[0];
        foreach (idB; idSlice[1 .. $])
        {
            coderId <<= 8;
            coderId |= idB;
        }

        ubyte[] coderProps;
        if (flags.thereAreAttributes)
        {
            const size = cast(size_t) readNumber(cursor);
            coderProps = new ubyte[size];
            cursor.read(coderProps);
        }

        return CoderInfo(cast(CoderId) coderId, coderProps);
    }

    void write(C)(C cursor)
    {
        const flags = CoderFlags(
            coderIdSize(id),
            No.isComplexCoder,
            cast(Flag!"thereAreAttributes")(props.length > 0)
        );
        cursor.put(flags.rep);

        ubyte[4] idBuf;
        ubyte ind;
        uint pos = flags.idSize;
        uint cid = cast(uint) id;
        while (pos > 0)
        {
            pos--;
            const shift = pos * 8;
            const mask = 0xff << shift;
            idBuf[ind] = cast(ubyte)((cid & mask) >> shift);
            ind++;
        }
        cursor.write(idBuf[0 .. ind]);
        if (props.length)
        {
            cursor.writeNumber(props.length);
            cursor.write(props);
        }
    }

    @property bool isLzmaFilter() const
    {
        switch (this.id)
        {
        case CoderId.lzma2:
        case CoderId.lzma1:
        case CoderId.delta:
        case CoderId.bcjX86:
        case CoderId.bcjPowerPc:
        case CoderId.bcjIa64:
        case CoderId.bcjArm:
        case CoderId.bcjArmThumb:
        case CoderId.bcjSparc:
        case CoderId.p7zBcj:
        case CoderId.p7zBcjPowerPc:
        case CoderId.p7zBcjIa64:
        case CoderId.p7zBcjArm:
        case CoderId.p7zBcjArmThumb:
        case CoderId.p7zBcjSparc:
            return true;
        default:
            return false;
        }
    }

    @property LzmaFilter lzmaFilter() const
    {
        switch (this.id)
        {
        case CoderId.lzma2:
            return LzmaRawFilter.lzma2(this.props).into;
        case CoderId.lzma1:
            return LzmaRawFilter.lzma1(this.props).into;
        case CoderId.delta:
            return LzmaRawFilter.delta(this.props).into;
        case CoderId.bcjX86:
        case CoderId.p7zBcj:
            return LzmaRawFilter.bcjX86(this.props).into;
        case CoderId.bcjPowerPc:
        case CoderId.p7zBcjPowerPc:
            return LzmaRawFilter.bcjPowerPc(this.props).into;
        case CoderId.bcjIa64:
        case CoderId.p7zBcjIa64:
            return LzmaRawFilter.bcjIa64(this.props).into;
        case CoderId.bcjArm:
        case CoderId.p7zBcjArm:
            return LzmaRawFilter.bcjArm(this.props).into;
        case CoderId.bcjArmThumb:
        case CoderId.p7zBcjArmThumb:
            return LzmaRawFilter.bcjArmThumb(this.props).into;
        case CoderId.bcjSparc:
        case CoderId.p7zBcjSparc:
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
        switch (this.id)
        {
        case CoderId.copy:
            return squizAlgo(Copy());
        case CoderId.lzma2:
            return squizAlgo(DecompressLzma(
                    [LzmaRawFilter.lzma2(this.props).into],
            ));
        case CoderId.lzma1:
            return squizAlgo(DecompressLzma(
                    [LzmaRawFilter.lzma1(this.props).into],
            ));
        case CoderId.delta:
            return squizAlgo(DecompressLzma(
                    [LzmaRawFilter.delta(this.props).into],
            ));
        case CoderId.bcjX86:
        case CoderId.p7zBcj:
            return squizAlgo(DecompressLzma(
                    [LzmaRawFilter.bcjX86(this.props).into],
            ));
        case CoderId.bcjPowerPc:
        case CoderId.p7zBcjPowerPc:
            return squizAlgo(DecompressLzma(
                    [LzmaRawFilter.bcjPowerPc(this.props).into],
            ));
        case CoderId.bcjIa64:
        case CoderId.p7zBcjIa64:
            return squizAlgo(DecompressLzma(
                    [LzmaRawFilter.bcjIa64(this.props).into],
            ));
        case CoderId.bcjArm:
        case CoderId.p7zBcjArm:
            return squizAlgo(DecompressLzma(
                    [LzmaRawFilter.bcjArm(this.props).into],
            ));
        case CoderId.bcjArmThumb:
        case CoderId.p7zBcjArmThumb:
            return squizAlgo(DecompressLzma(
                    [LzmaRawFilter.bcjArmThumb(this.props).into],
            ));
        case CoderId.bcjSparc:
        case CoderId.p7zBcjSparc:
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
        default:
            throw new Exception(format!"Unsupported coder id: %s"(this.id));
        }
    }
}
