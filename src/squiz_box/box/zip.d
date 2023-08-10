module squiz_box.box.zip;

import squiz_box.c.zlib;
import squiz_box.box;
import squiz_box.squiz;
import squiz_box.priv;

import std.exception;
import std.traits : isIntegral;
import std.range;
import std.stdio : File;
import std.string;
import std.typecons;

/// BoxAlgo for ".zip" files
struct ZipAlgo
{
    auto box(I)(I entries, size_t chunkSize = defaultChunkSize)
            if (isBoxEntryRange!I)
    {
        return ZipBox!I(entries, chunkSize);
    }

    auto unbox(I)(I input, Flag!"removePrefix" removePrefix = No.removePrefix)
            if (isByteRange!I)
    {
        auto stream = new ByteRangeCursor!I(input);
        return ZipUnbox!Cursor(stream, removePrefix);
    }
}

static assert(isBoxAlgo!ZipAlgo);

auto boxZip(I)(I entries, size_t chunkSize = defaultChunkSize)
        if (isBoxEntryRange!I)
{
    return ZipBox!I(entries, chunkSize);
}

auto unboxZip(I)(I input, Flag!"removePrefix" removePrefix = No.removePrefix)
        if (isByteRange!I)
{
    auto stream = new ByteRangeCursor!I(input);
    return ZipUnbox!Cursor(stream, removePrefix);
}

auto unboxZip(File input, Flag!"removePrefix" removePrefix = No.removePrefix)
{
    auto stream = new FileCursor(input);
    return ZipUnbox!SearchableCursor(stream, removePrefix);
}

auto unboxZip(ubyte[] zipData, Flag!"removePrefix" removePrefix = No.removePrefix)
{
    auto stream = new ArrayCursor(zipData);
    return ZipUnbox!SearchableCursor(stream, removePrefix);
}

private struct ZipBox(I)
{
    private I entries;

    private ubyte[] outBuffer;
    private ubyte[] outChunk;

    private ubyte[] localHeaderBuffer;
    private ubyte[] currentLocalHeader;
    private ulong localHeaderOffset;

    private Deflater deflater;
    private ubyte[] currentDeflated;

    private ubyte[] centralHeaderBuffer;
    private ubyte[] centralDirectory;
    private ulong centralDirEntries;
    private ulong centralDirOffset;
    private ulong centralDirSize;

    private ubyte[] endOfCentralDirectory;
    private bool endOfCentralDirReady;

    enum madeBy = 45;

    this(I entries, ulong chunkSize)
    {
        this.entries = entries;
        outBuffer = new ubyte[chunkSize];
        deflater = new Deflater;

        static if (isForwardRange!I)
        {
            preallocate(entries.save);
        }

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
        prime();
    }

    private void preallocate(I entries)
    {
        import std.algorithm : max;

        size_t maxHeaderSize;
        size_t centralDirectorySize;

        foreach (entry; entries)
        {
            // Note: this do not check for Zip64 extra field.
            // more header allocation will be needed if Zip64 extra field is needed.

            version (Posix)
                size_t extraFieldLength =
                    UnixExtraField.computeTotalLength(entry.linkname) + SquizBoxExtraField.sizeof;
            else
                size_t extraFieldLength;

            const path = entry.path;

            maxHeaderSize = max(
                maxHeaderSize,
                LocalFileHeader.computeTotalLength(path, null) + extraFieldLength
            );
            centralDirectorySize += CentralFileHeader.computeTotalLength(path, null, null) + extraFieldLength;
        }

        auto buf = new ubyte[maxHeaderSize + centralDirectorySize];
        localHeaderBuffer = buf[0 .. maxHeaderSize];
        centralHeaderBuffer = buf[maxHeaderSize .. $];
    }

    private void processNextEntry()
    in (!entries.empty)
    {
        import std.datetime.systime : SysTimeToDosFileTime;

        auto entry = entries.front;

        deflater.deflateEntry(entry.byChunk());
        currentDeflated = deflater.deflated;

        string path = entry.path;

        ushort extractVersion = 20;
        bool zip64;

        ExtraFieldInfo efInfo;

        if (deflater.inflatedSize >= 0xffff_ffff ||
            currentDeflated.length >= 0xffff_ffff ||
            localHeaderOffset >= 0xffff_ffff)
        {
            zip64 = true;
            extractVersion = madeBy;
            efInfo.addZip64(deflater.inflatedSize, currentDeflated.length, localHeaderOffset);
        }
        version (Posix)
        {
            efInfo.addUnix(entry.linkname, entry.timeLastModified, entry.ownerId, entry.groupId);
            efInfo.addSquizBox(entry.attributes);
        }

        const localExtraFieldData = efInfo.toZipData();
        const localHeaderLength = LocalFileHeader.computeTotalLength(path, localExtraFieldData);

        const centralExtraFieldData = localExtraFieldData;
        const centralHeaderLength = CentralFileHeader.computeTotalLength(path, centralExtraFieldData, null);

        if (localHeaderBuffer.length < localHeaderLength)
            localHeaderBuffer.length = localHeaderLength;
        centralHeaderBuffer.length += centralHeaderLength;

        LocalFileHeader local = void;
        local.signature = LocalFileHeader.expectedSignature;
        local.extractVersion = extractVersion;
        local.flag = 0;
        local.compressionMethod = 8;
        local.lastModDosTime = SysTimeToDosFileTime(entry.timeLastModified);
        local.crc32 = deflater.calculatedCrc32;
        local.compressedSize = zip64 ? 0xffff_ffff : cast(uint) currentDeflated.length;
        local.uncompressedSize = zip64 ? 0xffff_ffff : cast(uint) deflater.inflatedSize;
        // TODO: use store instead of deflate if smaller
        local.fileNameLength = cast(ushort) path.length;
        local.extraFieldLength = cast(ushort) localExtraFieldData.length;
        currentLocalHeader = local.writeTo(localHeaderBuffer, path, localExtraFieldData);

        version (Posix)
        {
            const versionMadeBy = madeBy | 0x0300;
            const externalAttributes = (entry.attributes & 0xffff) << 16;
        }
        else
        {
            const versionMadeBy = madeBy;
            const externalAttributes = entry.attributes;
        }

        CentralFileHeader central = void;
        central.signature = CentralFileHeader.expectedSignature;
        central.versionMadeBy = versionMadeBy;
        central.extractVersion = extractVersion;
        central.flag = 0;
        central.compressionMethod = 8;
        central.lastModDosTime = SysTimeToDosFileTime(entry.timeLastModified);
        central.crc32 = deflater.calculatedCrc32;
        central.compressedSize = zip64 ? 0xffff_ffff : cast(uint) currentDeflated.length;
        central.uncompressedSize = zip64 ? 0xffff_ffff : cast(uint) deflater.inflatedSize;
        central.fileNameLength = cast(ushort) path.length;
        central.extraFieldLength = cast(ushort) centralExtraFieldData.length;
        central.fileCommentLength = 0;
        central.diskNumberStart = 0;
        central.internalFileAttributes = 0;
        central.externalFileAttributes = externalAttributes;
        central.relativeLocalHeaderOffset = zip64 ? 0xffff_ffff : cast(uint) localHeaderOffset;
        central.writeTo(
            centralHeaderBuffer[centralDirectory.length .. centralDirectory.length + centralHeaderLength],
            path, centralExtraFieldData, null
        );

        const entryLen = localHeaderLength + currentDeflated.length;
        localHeaderOffset += entryLen;
        centralDirectory = centralHeaderBuffer[0 .. centralDirectory.length + centralHeaderLength];

        centralDirEntries += 1;
        centralDirOffset += entryLen;
        centralDirSize += centralHeaderLength;

        entries.popFront();
    }

    private void prepareEndOfCentralDir()
    {
        const zip64 = centralDirEntries >= 0xffff || centralDirSize >= 0xffff_ffff || centralDirOffset >= 0xffff_ffff;

        auto len = EndOfCentralDirectory.sizeof;
        if (zip64)
            len += Zip64EndOfCentralDirRecord.sizeof + Zip64EndOfCentralDirLocator.sizeof;

        endOfCentralDirectory = new ubyte[len];
        size_t offset;

        if (zip64)
        {
            auto record = cast(Zip64EndOfCentralDirRecord*)&endOfCentralDirectory[offset];
            record.signature = Zip64EndOfCentralDirRecord.expectedSignature;
            record.zip64EndOfCentralDirRecordSize = Zip64EndOfCentralDirRecord.sizeof - 12;
            version (Posix)
                record.versionMadeBy = madeBy | 0x0300;
            else
                record.versionMadeBy = madeBy;
            record.extractVersion = madeBy;
            record.centralDirEntriesOnThisDisk = centralDirEntries;
            record.centralDirEntries = centralDirEntries;
            record.centralDirSize = centralDirSize;
            record.centralDirOffset = centralDirOffset;
            offset += Zip64EndOfCentralDirRecord.sizeof;

            auto locator = cast(Zip64EndOfCentralDirLocator*)&endOfCentralDirectory[offset];
            locator.signature = Zip64EndOfCentralDirLocator.expectedSignature;
            locator.zip64EndOfCentralDirRecordOffset = centralDirOffset + centralDirSize;
            offset += Zip64EndOfCentralDirLocator.sizeof;
        }

        auto footer = cast(EndOfCentralDirectory*)&endOfCentralDirectory[offset];
        footer.signature = EndOfCentralDirectory.expectedSignature;
        footer.centralDirEntriesOnThisDisk = zip64 ? 0xffff : cast(ushort) centralDirEntries;
        footer.centralDirEntries = zip64 ? 0xffff : cast(ushort) centralDirEntries;
        footer.centralDirSize = zip64 ? 0xffff_ffff : cast(uint) centralDirSize;
        footer.centralDirOffset = zip64 ? 0xffff_ffff : cast(uint) centralDirOffset;

        endOfCentralDirReady = true;
    }

    private bool needNextEntry()
    {
        return currentLocalHeader.length == 0 && currentDeflated.length == 0;
    }

    private void prime()
    {
        import std.algorithm : min;

        ubyte[] outAvail = outBuffer;

        void writeOut(ref ubyte[] inBuffer)
        {
            const len = min(inBuffer.length, outAvail.length);
            outAvail[0 .. len] = inBuffer[0 .. len];
            outAvail = outAvail[len .. $];
            inBuffer = inBuffer[len .. $];
        }

        while (outAvail.length)
        {
            if (needNextEntry() && !entries.empty)
                processNextEntry();

            if (currentLocalHeader.length)
            {
                writeOut(currentLocalHeader);
                continue;
            }

            if (currentDeflated.length)
            {
                writeOut(currentDeflated);
                continue;
            }

            assert(entries.empty);

            if (centralDirectory.length)
            {
                writeOut(centralDirectory);
                continue;
            }

            if (deflater)
            {
                deflater.end();
            }

            if (!endOfCentralDirReady)
            {
                prepareEndOfCentralDir();
            }

            if (endOfCentralDirectory.length)
            {
                writeOut(endOfCentralDirectory);
                continue;
            }

            break;
        }

        outChunk = outBuffer[0 .. $ - outAvail.length];
    }
}

// Deflates entries successively while reusing the allocated resources from one entry to the next.
// deflateBuffer, deflated, inflatedSize and crc are invalidated each time deflateEntry is called
private class Deflater
{
    Deflate algo;
    StreamType!Deflate stream;

    // buffer that receive compressed data. Only grows from one entry to the next
    ubyte[] deflateBuffer;
    // slice of buffer that contains compressed data of the last entry.
    ubyte[] deflated;
    // unompressed size of the last entry
    ulong inflatedSize;
    // CRC32 checksum of the last entry
    uint calculatedCrc32;

    this()
    {
        algo.format = ZlibFormat.raw;
    }

    void end()
    {
        algo.end(stream);
    }

    void deflateEntry(ByteRange input)
    {
        if (!stream)
        {
            stream = algo.initialize();
            // arbitrary initial buffer size
            deflateBuffer = new ubyte[64 * 1024];
        }
        else
        {
            // the stream was used, we have to reset it
            algo.reset(stream);
            deflated = null;
            inflatedSize = 0;
        }

        calculatedCrc32 = crc32(0, null, 0);

        while (true)
        {
            if (stream.input.length == 0 && !input.empty)
            {
                auto inp = input.front;
                inflatedSize += inp.length;
                calculatedCrc32 = crc32(calculatedCrc32, inp.ptr, cast(uint)(inp.length));
                stream.input = inp;
            }

            if (deflated.length == deflateBuffer.length)
            {
                deflateBuffer.length += 8192;
                deflated = deflateBuffer[0 .. deflated.length];
            }

            stream.output = deflateBuffer[deflated.length .. $];

            const ended = algo.process(stream, cast(Flag!"lastChunk") input.empty);

            deflated = deflateBuffer[0 .. $ - stream.output.length];

            if (stream.input.length == 0 && !input.empty)
                input.popFront();

            if (ended)
                break;
        }
    }
}

private struct ZipUnbox(C) if (is(C : Cursor))
{
    enum isSearchable = is(C : SearchableCursor);

    private C input;
    private UnboxEntry currentEntry;
    ubyte[] fieldBuf;
    ulong nextHeader;
    Flag!"removePrefix" removePrefix;
    string prefix;

    static if (isSearchable)
    {
        struct CentralDirInfo
        {
            ulong numEntries;
            ulong pos;
            ulong size;
        }

        ZipEntryInfo[string] centralDirectory;
    }

    this(C input, Flag!"removePrefix" removePrefix)
    {
        this.input = input;
        this.removePrefix = removePrefix;

        fieldBuf = new ubyte[ushort.max];

        static if (isSearchable)
        {
            readCentralDirectory();
        }

        readEntry();
    }

    @property bool empty()
    {
        return !currentEntry;
    }

    @property UnboxEntry front()
    {
        return currentEntry;
    }

    void popFront()
    {
        assert(input.pos <= nextHeader);

        if (input.pos < nextHeader)
        {
            // the current entry was not fully read, we move the stream forward
            // up to the next header
            const dist = nextHeader - input.pos;
            input.ffw(dist);
        }
        currentEntry = null;
        readEntry();
    }

    static if (isSearchable)
    {
        private void readCentralDirectory()
        {
            import std.datetime.systime : DosFileTimeToSysTime;

            auto cdi = readCentralDirInfo();
            input.seek(cdi.pos);

            while (cdi.numEntries != 0)
            {
                CentralFileHeader header = void;
                input.readValue(&header);
                enforce(
                    header.signature == CentralFileHeader.expectedSignature,
                    "Corrupted Zip: Expected Central directory header"
                );

                ZipEntryInfo info = void;

                info.path = cast(string) input.read(fieldBuf[0 .. header.fileNameLength.val]).idup;
                enforce(info.path.length == header.fileNameLength.val, "Unexpected end of input");

                const extraFieldData = input.read(fieldBuf[0 .. header.extraFieldLength.val]);
                enforce(extraFieldData.length == header.extraFieldLength.val, "Unexpected end of input");

                const efInfo = ExtraFieldInfo.parse(extraFieldData);

                if (header.fileCommentLength.val)
                    input.ffw(header.fileCommentLength.val);

                fillEntryInfo(info, efInfo, header);

                // will be added later to entrySize: LocalFileHeader size + name and extra fields
                info.entrySize = info.compressedSize +
                    CentralFileHeader.sizeof +
                    header.fileNameLength.val +
                    header.extraFieldLength.val +
                    header.fileCommentLength.val;

                version (Posix)
                {
                    if ((header.versionMadeBy.val & 0xff00) == 0x0300)
                        info.attributes = header.externalFileAttributes.val >> 16;
                    else
                        info.attributes = 0;
                }
                else
                {
                    if ((header.versionMadeBy.val & 0xff00) == 0x0000)
                        info.attributes = header.externalFileAttributes.val;
                    else
                        info.attributes = 0;
                }

                cdi.numEntries -= 1;

                centralDirectory[info.path] = info;
            }

            input.seek(0);
        }

        private CentralDirInfo readCentralDirInfo()
        {
            import std.algorithm : max;

            enforce(
                input.size > EndOfCentralDirectory.sizeof, "Not a Zip file"
            );
            ulong pos = input.size - EndOfCentralDirectory.sizeof;
            enum maxCommentSz = 0xffff;
            const ulong stopSearch = max(pos, maxCommentSz) - maxCommentSz;
            while (pos != stopSearch)
            {
                input.seek(pos);
                EndOfCentralDirectory record = void;
                input.readValue(&record);
                if (record.signature == EndOfCentralDirectory.expectedSignature)
                {
                    enforce(
                        record.thisDisk == 0 && record.centralDirDisk == 0,
                        "multi-disk Zip archives are not supported"
                    );
                    if (record.centralDirEntries == 0xffff ||
                        record.centralDirOffset == 0xffff_ffff ||
                        record.centralDirSize == 0xffff_ffff)
                    {
                        return readZip64CentralDirInfo(pos);
                    }
                    return CentralDirInfo(
                        record.centralDirEntries.val,
                        record.centralDirOffset.val,
                        record.centralDirSize.val,
                    );
                }
                // we are likely in the zip file comment.
                // we continue backward until we hit the signature
                // of the end of central directory record
                pos -= 1;
            }
            throw new Exception("Corrupted Zip: Could not find end of central directory record");
        }

        private CentralDirInfo readZip64CentralDirInfo(size_t endCentralDirRecordPos)
        {
            enforce(
                endCentralDirRecordPos > Zip64EndOfCentralDirLocator.sizeof,
                "Corrupted Zip: Not enough bytes"
            );

            input.seek(endCentralDirRecordPos - Zip64EndOfCentralDirLocator.sizeof);
            Zip64EndOfCentralDirLocator locator = void;
            input.readValue(&locator);
            enforce(
                locator.signature == Zip64EndOfCentralDirLocator.expectedSignature,
                "Corrupted Zip: Expected Zip64 end of central directory locator"
            );

            input.seek(locator.zip64EndOfCentralDirRecordOffset.val);
            Zip64EndOfCentralDirRecord record = void;
            input.readValue(&record);
            enforce(
                record.signature == Zip64EndOfCentralDirRecord.expectedSignature,
                "Corrupted Zip: Expected Zip64 end of central directory record"
            );

            return CentralDirInfo(
                record.centralDirEntries.val,
                record.centralDirOffset.val,
                record.centralDirSize.val,
            );
        }
    }

    private void fillEntryInfo(H)(ref ZipEntryInfo info, const ref ExtraFieldInfo efInfo, const ref H header)
            if (is(H == LocalFileHeader) || is(H == CentralFileHeader))
    {
        const flag = cast(ZipFlag) header.flag.val;
        enforce(
            (flag & ZipFlag.encryption) == ZipFlag.none,
            "Zip encryption unsupported"
        );
        enforce(
            (flag & ZipFlag.dataDescriptor) == ZipFlag.none,
            "Zip format unsupported (data descriptor)"
        );
        enforce(
            header.compressionMethod.val == 0 || header.compressionMethod.val == 8,
            "Unsupported Zip compression method"
        );

        info.deflated = header.compressionMethod.val == 8;
        info.expectedCrc32 = header.crc32.val;

        if (efInfo.has(KnownExtraField.zip64))
        {
            info.size = efInfo.uncompressedSize;
            info.compressedSize = efInfo.compressedSize;
        }
        else
        {
            info.size = header.uncompressedSize.val;
            info.compressedSize = header.compressedSize.val;
        }

        info.type = info.compressedSize == 0 ? EntryType.directory : EntryType.regular;

        version (Posix)
        {
            if (efInfo.has(KnownExtraField.unix))
            {
                info.linkname = efInfo.linkname;
                if (info.linkname)
                    info.type = EntryType.symlink;
                info.timeLastModified = efInfo.timeLastModified;
                info.ownerId = efInfo.ownerId;
                info.groupId = efInfo.groupId;
            }
            else
            {
                info.timeLastModified = DosFileTimeToSysTime(header.lastModDosTime.val);
            }

            if (efInfo.has(KnownExtraField.squizBox))
                info.attributes = efInfo.attributes;
            else
                info.attributes = defaultAttributes(info.type);
        }
        else
        {
            info.timeLastModified = DosFileTimeToSysTime(header.lastModDosTime.val);
            info.attributes = defaultAttributes(info.type);
        }
    }

    private void readEntry()
    {
        import std.datetime.systime : DosFileTimeToSysTime, unixTimeToStdTime, SysTime;

        LocalFileHeader header = void;
        input.readValue(&header);
        if (header.signature == CentralFileHeader.expectedSignature)
        {
            // last entry was consumed
            input.ffw(ulong.max);
            return;
        }

        enforce(
            header.signature == LocalFileHeader.expectedSignature,
            "Corrupted Zip: Expected a Zip local header signature."
        );

        // TODO check for presence of encryption header and data descriptor
        const path = cast(string) input.read(fieldBuf[0 .. header.fileNameLength.val]).idup;
        enforce(path.length == header.fileNameLength.val, "Unexpected end of input");

        const extraFieldData = input.read(fieldBuf[0 .. header.extraFieldLength.val]);
        enforce(extraFieldData.length == header.extraFieldLength.val, "Unexpected end of input");

        const efInfo = ExtraFieldInfo.parse(extraFieldData);

        static if (isSearchable)
        {
            auto info = centralDirectory[path];
            info.entrySize += header.totalLength();
        }
        else
        {
            ZipEntryInfo info;
            info.path = path;
            fillEntryInfo(info, efInfo, header);
            // educated guess for the size in the central directory
            info.entrySize = header.totalLength() +
                info.compressedSize +
                CentralFileHeader.sizeof +
                path.length +
                extraFieldData.length;
        }

        nextHeader = input.pos + info.compressedSize;

        version (Windows)
            info.path = info.path.replace('\\', '/');

        if (removePrefix)
        {
            import std.algorithm : min;

            const pref = enforce(entryPrefix(info.path, info.type), format!`"%s": no prefix to be removed`(
                    info.path));

            if (!prefix)
                prefix = pref;

            enforce(prefix == pref, format!`"%s": path prefix mismatch with "%s"`(info.path, prefix));

            const len = min(info.path.length, prefix.length);
            info.path = info.path[len .. $];

            // skipping empty directory
            if (!info.path.length && info.type == EntryType.directory)
                readEntry();
        }

        currentEntry = new ZipUnboxEntry!C(input, info);
    }
}

uint defaultAttributes(EntryType type)
{
    version (Posix)
    {
        import std.conv : octal;

        final switch (type)
        {
        case EntryType.regular:
            return octal!"100644";
        case EntryType.symlink:
            return octal!"120644";
        case EntryType.directory:
            return octal!"040644";
        }
    }
    else
    {
        import core.sys.windows.winnt : FILE_ATTRIBUTE_NORMAL, FILE_ATTRIBUTE_DIRECTORY;

        final switch (type)
        {
        case EntryType.regular:
            return FILE_ATTRIBUTE_NORMAL;
        case EntryType.symlink:
            // TODO: symlinks on Windows
            return FILE_ATTRIBUTE_NORMAL;
        case EntryType.directory:
            return FILE_ATTRIBUTE_DIRECTORY;
        }
    }
}

private struct ZipEntryInfo
{
    string path;
    string linkname;
    EntryType type;
    ulong size;
    ulong entrySize;
    ulong compressedSize;
    SysTime timeLastModified;
    uint attributes;
    bool deflated;
    uint expectedCrc32;

    version (Posix)
    {
        int ownerId;
        int groupId;
    }
}

private enum KnownExtraField
{
    none = 0,
    zip64 = 1,
    unix = 2,
    squizBox = 4,
}

private struct ExtraFieldInfo
{
    KnownExtraField fields;

    // zip64
    ulong uncompressedSize;
    ulong compressedSize;
    ulong localHeaderPos;

    version (Posix)
    {
        // unix
        string linkname;
        SysTime timeLastModified;
        int ownerId;
        int groupId;

        // squizBox
        uint attributes;
    }

    bool has(KnownExtraField f) const
    {
        return (fields & f) != KnownExtraField.none;
    }

    void addZip64(ulong uncompressedSize, ulong compressedSize, ulong localHeaderPos)
    {
        fields |= KnownExtraField.zip64;
        this.uncompressedSize = uncompressedSize;
        this.compressedSize = compressedSize;
        this.localHeaderPos = localHeaderPos;
    }

    version (Posix)
    {
        void addUnix(string linkname, SysTime timeLastModified, int ownerId, int groupId)
        {
            fields |= KnownExtraField.unix;
            this.linkname = linkname;
            this.timeLastModified = timeLastModified;
            this.ownerId = ownerId;
            this.groupId = groupId;
        }

        void addSquizBox(uint attributes)
        {
            fields |= KnownExtraField.squizBox;
            this.attributes = attributes;
        }
    }

    size_t computeLength()
    {
        size_t sz;

        if (has(KnownExtraField.zip64))
            sz += Zip64ExtraField.sizeof;
        version (Posix)
        {
            if (has(KnownExtraField.unix))
                sz += UnixExtraField.computeTotalLength(linkname);
            if (has(KnownExtraField.squizBox))
                sz += SquizBoxExtraField.sizeof;
        }

        return sz;
    }

    static ExtraFieldInfo parse(const(ubyte)[] data)
    {
        ExtraFieldInfo info;

        while (data.length != 0)
        {
            enforce(data.length >= 4, "Corrupted Zip File (incomplete extra-field)");

            auto header = cast(const(ExtraFieldHeader)*) data.ptr;

            const efLen = header.size.val + 4;
            enforce(data.length >= efLen, "Corrupted Zip file (incomplete extra-field)");

            switch (header.id.val)
            {
            case Zip64ExtraField.expectedId:
                info.fields |= KnownExtraField.zip64;
                auto ef = cast(Zip64ExtraField*) data.ptr;
                info.uncompressedSize = ef.uncompressedSize.val;
                info.compressedSize = ef.compressedSize.val;
                info.localHeaderPos = ef.localHeaderPos.val;
                break;
                // dfmt off
            version (Posix)
            {
                case UnixExtraField.expectedId:
                    info.fields |= KnownExtraField.unix;
                    auto ef = cast(UnixExtraField*) data.ptr;
                    info.timeLastModified = SysTime(unixTimeToStdTime(ef.mtime.val));
                    info.ownerId = ef.uid.val;
                    info.groupId = ef.gid.val;
                    if (efLen > UnixExtraField.sizeof)
                    {
                        info.linkname = cast(string)
                            data[UnixExtraField.sizeof .. efLen].idup;
                    }
                    break;
                case SquizBoxExtraField.expectedId:
                    info.fields |= KnownExtraField.squizBox;
                    auto ef = cast(SquizBoxExtraField*) data.ptr;
                    info.attributes = ef.mode.val;
                    break;
            }
            // dfmt on
            default:
                break;
            }

            data = data[efLen .. $];
        }

        return info;
    }

    ubyte[] toZipData()
    {
        const sz = computeLength();

        auto data = new ubyte[sz];
        size_t pos;

        if (has(KnownExtraField.zip64))
        {
            auto f = cast(Zip64ExtraField*)&data[pos];
            f.id = Zip64ExtraField.expectedId;
            f.size = Zip64ExtraField.sizeof - 4;
            f.uncompressedSize = uncompressedSize;
            f.compressedSize = compressedSize;
            f.localHeaderPos = localHeaderPos;
            f.diskStartNumber = 0;
            pos += Zip64ExtraField.sizeof;
        }
        version (Posix)
        {
            if (has(KnownExtraField.unix))
            {
                import std.datetime.systime : Clock, stdTimeToUnixTime;

                auto f = cast(UnixExtraField*)&data[pos];
                f.id = UnixExtraField.expectedId;
                f.size = cast(ushort)(UnixExtraField.sizeof - 4 + linkname.length);
                f.atime = stdTimeToUnixTime!int(Clock.currStdTime);
                f.mtime = stdTimeToUnixTime!int(timeLastModified.stdTime);
                f.uid = cast(ushort) ownerId;
                f.gid = cast(ushort) groupId;
                pos += UnixExtraField.sizeof;
                if (linkname.length)
                {
                    data[pos .. pos + linkname.length] = cast(const(ubyte)[]) linkname;
                    pos += linkname.length;
                }
            }

            if (has(KnownExtraField.squizBox))
            {
                auto f = cast(SquizBoxExtraField*)&data[pos];
                f.id = SquizBoxExtraField.expectedId;
                f.size = SquizBoxExtraField.sizeof - 4;
                f.mode = attributes;
                pos += SquizBoxExtraField.sizeof;
            }
        }

        assert(pos == sz);
        return data;
    }
}

private class ZipUnboxEntry(C) : UnboxEntry if (is(C : Cursor))
{
    enum isSearchable = is(C : SearchableCursor);

    C input;
    ulong startPos;
    ZipEntryInfo info;

    this(C input, ZipEntryInfo info)
    {
        this.input = input;
        this.startPos = input.pos;
        this.info = info;
    }

    @property EntryMode mode()
    {
        return EntryMode.extraction;
    }

    @property string path()
    {
        return info.path;
    }

    @property EntryType type()
    {
        return info.type;
    }

    @property string linkname()
    {
        return info.linkname;
    }

    @property ulong size()
    {
        return info.size;
    }

    @property ulong entrySize()
    {
        return info.entrySize;
    }

    @property SysTime timeLastModified()
    {
        return info.timeLastModified;
    }

    @property uint attributes()
    {
        return info.attributes;
    }

    version (Posix)
    {
        @property int ownerId()
        {
            return info.ownerId;
        }

        @property int groupId()
        {
            return info.groupId;
        }
    }

    ByteRange byChunk(size_t chunkSize)
    {
        static if (!isSearchable)
            enforce(
                input.pos == startPos,
                "Data cursor has moved, this entry is not valid anymore"
            );

        if (info.deflated)
            return new InflateByChunk!C(input, startPos, info.compressedSize, chunkSize, info
                    .expectedCrc32);
        else
            return new StoredByChunk!C(input, startPos, info.compressedSize, chunkSize, info
                    .expectedCrc32);
    }
}

/// common code between InflateByChunk and StoredByChunk
private abstract class ZipByChunk : ByteRange
{
    ubyte[] moveFront()
    {
        throw new Exception(
            "Cannot move the front of a(n) Zip `Inflater`"
        );
    }

    int opApply(scope int delegate(ByteChunk) dg)
    {
        int res;

        while (!empty)
        {
            res = dg(front);
            if (res)
                break;
            popFront();
        }

        return res;
    }

    int opApply(scope int delegate(size_t, ByteChunk) dg)
    {
        int res;

        size_t i = 0;

        while (!empty)
        {
            res = dg(i, front);
            if (res)
                break;
            i++;
            popFront();
        }

        return res;
    }
}

/// implements byChunk for stored entries (no compression)
private class StoredByChunk(C) : ZipByChunk if (is(C : Cursor))
{
    enum isSearchable = is(C : SearchableCursor);

    C input;
    ulong currentPos;
    ulong size;
    ubyte[] chunkBuffer;
    ubyte[] chunk;
    uint calculatedCrc32;
    uint expectedCrc32;
    bool ended;

    this(C input, ulong startPos, ulong size, size_t chunkSize, uint expectedCrc32)
    {
        static if (!isSearchable)
            assert(input.pos == startPos);

        this.input = input;
        this.currentPos = startPos;
        this.size = size;
        this.chunkBuffer = new ubyte[chunkSize];
        this.expectedCrc32 = expectedCrc32;

        this.calculatedCrc32 = crc32(0, null, 0);

        prime();
    }

    @property bool empty()
    {
        return size == 0 && chunk.length == 0;
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

        static if (isSearchable)
            input.seek(currentPos);
        else
            enforce(input.pos == currentPos,
                "Data cursor has moved. Entry is no longer valid."
            );

        const len = min(size, chunkBuffer.length);
        chunk = input.read(chunkBuffer[0 .. len]);
        enforce(chunk.length == len, "Corrupted Zip file: unexpected end of input");
        currentPos += len;
        size -= len;

        calculatedCrc32 = crc32(calculatedCrc32, chunk.ptr, cast(uint) len);

        if (size == 0)
        {
            ended = true;
            enforce(
                calculatedCrc32 == expectedCrc32,
                "Corrupted Zip file: Wrong CRC32 checkum"
            );
        }
    }
}

/// implements byChunk for deflated entries
private class InflateByChunk(C) : ZipByChunk if (is(C : Cursor))
{
    enum isSearchable = is(C : SearchableCursor);

    Inflate algo;
    StreamType!Inflate stream;
    C input;
    ulong currentPos;
    ulong compressedSz;
    ubyte[] chunkBuffer;
    ubyte[] chunk;
    ubyte[] inBuffer;
    uint calculatedCrc32;
    uint expectedCrc32;
    Flag!"streamEnded" ended;

    this(C input, ulong startPos, ulong compressedSz, size_t chunkSize, uint expectedCrc32)
    {
        static if (!isSearchable)
            assert(input.pos == startPos);

        this.input = input;
        this.currentPos = startPos;
        this.compressedSz = compressedSz;
        this.chunkBuffer = new ubyte[chunkSize];
        this.inBuffer = new ubyte[defaultChunkSize];
        this.expectedCrc32 = expectedCrc32;

        this.calculatedCrc32 = crc32(0, null, 0);

        algo.format = ZlibFormat.raw;
        stream = algo.initialize();

        prime();
    }

    @property bool empty()
    {
        return compressedSz == 0 && chunk.length == 0;
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
            if (stream.input.length == 0 && compressedSz != 0)
            {
                static if (isSearchable)
                    input.seek(currentPos);
                else
                    enforce(input.pos == currentPos,
                        "Data cursor has moved. Entry is no longer valid."
                    );

                const len = min(compressedSz, inBuffer.length);
                auto inp = input.read(inBuffer[0 .. len]);
                enforce(inp.length == len, "Corrupted Zip file: unexpected end of input");
                stream.input = inp;
                currentPos += len;
                compressedSz -= len;
            }

            stream.output = chunkBuffer[chunk.length .. $];

            ended = algo.process(stream, cast(Flag!"lastChunk")(compressedSz == 0));

            chunk = chunkBuffer[0 .. $ - stream.output.length];

            if (ended)
                break;
        }

        calculatedCrc32 = crc32(calculatedCrc32, chunk.ptr, cast(uint) chunk.length);

        if (ended)
        {
            import std.format : format;

            enforce(compressedSz == 0, "Inflate ended before end of input");
            enforce(
                calculatedCrc32 == expectedCrc32,
                "CRC32 verification failed. Archive is may be corrupted",
            );
            algo.end(stream);
        }
    }
}

private void writeField(T)(ubyte[] buffer, const(T)[] field, ref size_t offset)
        if (T.sizeof == 1)
in (buffer.length >= field.length + offset)
{
    if (field.length)
    {
        buffer[offset .. offset + field.length] = cast(const(ubyte)[]) field;
        offset += field.length;
    }
}

private enum ZipFlag : ushort
{
    none = 0,
    encryption = 1 << 0,
    compress1 = 1 << 1,
    compress2 = 1 << 2,
    dataDescriptor = 1 << 3,
    compressedPatch = 1 << 5,
    strongEncryption = 1 << 6,
    efs = 1 << 11,
    masking = 1 << 13,
}

private struct LocalFileHeader
{
    enum expectedSignature = 0x04034b50;

    LittleEndian!4 signature;
    LittleEndian!2 extractVersion;
    LittleEndian!2 flag;
    LittleEndian!2 compressionMethod;
    LittleEndian!4 lastModDosTime;
    LittleEndian!4 crc32;
    LittleEndian!4 compressedSize;
    LittleEndian!4 uncompressedSize;
    LittleEndian!2 fileNameLength;
    LittleEndian!2 extraFieldLength;

    static size_t computeTotalLength(string fileName, const(ubyte)[] extraField)
    {
        return LocalFileHeader.sizeof + fileName.length + extraField.length;
    }

    size_t totalLength()
    {
        return LocalFileHeader.sizeof + fileNameLength.val + extraFieldLength.val;
    }

    ubyte[] writeTo(ubyte[] buffer, string fileName, const(ubyte)[] extraField)
    {
        assert(fileName.length == fileNameLength.val);
        assert(extraField.length == extraFieldLength.val);

        assert(buffer.length >= totalLength());

        auto ptr = signature.data.ptr;
        buffer[0 .. LocalFileHeader.sizeof] = ptr[0 .. LocalFileHeader.sizeof];

        size_t offset = LocalFileHeader.sizeof;
        writeField(buffer, fileName, offset);
        writeField(buffer, extraField, offset);

        return buffer[0 .. offset];
    }
}

private struct CentralFileHeader
{
    enum expectedSignature = 0x02014b50;

    LittleEndian!4 signature;
    LittleEndian!2 versionMadeBy;
    LittleEndian!2 extractVersion;
    LittleEndian!2 flag;
    LittleEndian!2 compressionMethod;
    LittleEndian!4 lastModDosTime;
    LittleEndian!4 crc32;
    LittleEndian!4 compressedSize;
    LittleEndian!4 uncompressedSize;
    LittleEndian!2 fileNameLength;
    LittleEndian!2 extraFieldLength;
    LittleEndian!2 fileCommentLength;
    LittleEndian!2 diskNumberStart;
    LittleEndian!2 internalFileAttributes;
    LittleEndian!4 externalFileAttributes;
    LittleEndian!4 relativeLocalHeaderOffset;

    static size_t computeTotalLength(string fileName, const(ubyte)[] extraField, string fileComment)
    {
        return CentralFileHeader.sizeof + fileName.length + extraField.length + fileComment.length;
    }

    size_t totalLength()
    {
        return CentralFileHeader.sizeof + fileNameLength.val +
            extraFieldLength.val + fileCommentLength.val;
    }

    ubyte[] writeTo(ubyte[] buffer, string fileName, const(ubyte)[] extraField, string fileComment)
    {
        assert(fileName.length == fileNameLength.val);
        assert(extraField.length == extraFieldLength.val);
        assert(fileComment.length == fileCommentLength.val);

        assert(buffer.length >= totalLength());

        auto ptr = signature.data.ptr;
        buffer[0 .. CentralFileHeader.sizeof] = ptr[0 .. CentralFileHeader.sizeof];

        size_t offset = CentralFileHeader.sizeof;
        writeField(buffer, fileName, offset);
        writeField(buffer, extraField, offset);
        writeField(buffer, fileComment, offset);

        return buffer[0 .. offset];
    }
}

private struct Zip64EndOfCentralDirRecord
{
    enum expectedSignature = 0x06064b50;

    LittleEndian!4 signature;
    LittleEndian!8 zip64EndOfCentralDirRecordSize;
    LittleEndian!2 versionMadeBy;
    LittleEndian!2 extractVersion;
    LittleEndian!4 thisDisk;
    LittleEndian!4 centralDirDisk;
    LittleEndian!8 centralDirEntriesOnThisDisk;
    LittleEndian!8 centralDirEntries;
    LittleEndian!8 centralDirSize;
    LittleEndian!8 centralDirOffset;

}

private struct Zip64EndOfCentralDirLocator
{
    enum expectedSignature = 0x07064b50;

    LittleEndian!4 signature;
    LittleEndian!4 zip64EndOfCentralDirDisk;
    LittleEndian!8 zip64EndOfCentralDirRecordOffset;
    LittleEndian!4 diskCount;
}

private struct EndOfCentralDirectory
{
    enum expectedSignature = 0x06054b50;

    LittleEndian!4 signature;
    LittleEndian!2 thisDisk;
    LittleEndian!2 centralDirDisk;
    LittleEndian!2 centralDirEntriesOnThisDisk;
    LittleEndian!2 centralDirEntries;
    LittleEndian!4 centralDirSize;
    LittleEndian!4 centralDirOffset;
    LittleEndian!2 fileCommentLength;

    static size_t computeTotalLength(string comment)
    {
        return EndOfCentralDirectory.sizeof + comment.length;
    }

    size_t totalLength()
    {
        return EndOfCentralDirectory.sizeof + fileCommentLength.val;
    }

    ubyte[] writeTo(ubyte[] buffer, string comment)
    {
        assert(comment.length == fileCommentLength.val);

        assert(buffer.length >= totalLength());

        auto ptr = signature.data.ptr;
        buffer[0 .. EndOfCentralDirectory.sizeof] = ptr[0 .. EndOfCentralDirectory.sizeof];

        size_t offset = EndOfCentralDirectory.sizeof;
        writeField(buffer, comment, offset);

        return buffer[0 .. offset];
    }
}

static assert(LocalFileHeader.sizeof == 30);
static assert(CentralFileHeader.sizeof == 46);
static assert(Zip64EndOfCentralDirRecord.sizeof == 56);
static assert(Zip64EndOfCentralDirLocator.sizeof == 20);
static assert(EndOfCentralDirectory.sizeof == 22);

private struct ExtraFieldHeader
{
    LittleEndian!2 id;
    LittleEndian!2 size;
}

private struct Zip64ExtraField
{
    enum expectedId = 0x0001;

    LittleEndian!2 id;
    LittleEndian!2 size;
    LittleEndian!8 uncompressedSize;
    LittleEndian!8 compressedSize;
    LittleEndian!8 localHeaderPos;
    LittleEndian!4 diskStartNumber;
}

static assert(Zip64ExtraField.sizeof == 32);

version (Posix)
{
    private struct UnixExtraField
    {
        enum expectedId = 0x000d;

        LittleEndian!2 id;
        LittleEndian!2 size;
        LittleEndian!4 atime;
        LittleEndian!4 mtime;
        LittleEndian!2 uid;
        LittleEndian!2 gid;

        static size_t computeTotalLength(string linkname)
        {
            return UnixExtraField.sizeof + linkname.length;
        }

        ubyte[] writeTo(ubyte[] buffer, string linkname)
        {
            assert(linkname.length == size.val - 12);

            assert(buffer.length >= computeTotalLength(linkname));

            auto ptr = id.data.ptr;
            buffer[0 .. UnixExtraField.sizeof] = ptr[0 .. UnixExtraField.sizeof];

            size_t offset = UnixExtraField.sizeof;
            writeField(buffer, linkname, offset);

            return buffer[0 .. offset];
        }
    }

    static assert(UnixExtraField.sizeof == 16);

    /// Extra field that places the file Unix permission bits in the local header.
    /// The attribute field contain the Unix permission as returned in the `st_mode`
    /// of `struct stat`. (e.g. 100644). It is stored in little-endian.
    private struct SquizBoxExtraField
    {
        enum expectedId = 0x4273; // SB

        LittleEndian!2 id = expectedId;
        LittleEndian!2 size = 4;
        LittleEndian!4 mode;

        void writeTo(ubyte[] buffer)
        {
            assert(buffer.length == 8);
            auto ptr = id.data.ptr;
            buffer[0 .. SquizBoxExtraField.sizeof] = ptr[0 .. SquizBoxExtraField.sizeof];
        }
    }

    static assert(SquizBoxExtraField.sizeof == 8);
}
