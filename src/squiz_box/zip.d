module squiz_box.zip;

import squiz_box.c.zlib;
import squiz_box.core;
import squiz_box.gz;
import squiz_box.priv;

import std.exception;
import std.traits : isIntegral;
import std.range;

auto createZipArchive(I)(I entries, size_t chunkSize = defaultChunkSize)
        if (isCreateEntryRange!I)
{
    return ZipArchiveCreate!I(entries, chunkSize);
}

private struct ZipArchiveCreate(I)
{
    private I entries;

    private ubyte[] outBuffer;
    private ubyte[] outChunk;

    private ubyte[] localHeaderBuffer;
    private ubyte[] currentLocalHeader;
    private size_t localHeaderOffset;

    private Deflater deflater;
    private ubyte[] currentDeflated;

    private ubyte[] centralHeaderBuffer;
    private ubyte[] centralDirectory;
    private size_t centralDirEntries;
    private size_t centralDirOffset;
    private size_t centralDirSize;

    private ubyte[] endOfCentralDirectory;
    private bool endOfCentralDirReady;

    this(I entries, size_t chunkSize)
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

    @property ubyte[] front()
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
            const path = entry.path;
            size_t extraFieldLength = SquizBoxExtraField.sizeof;
            version (Posix)
            {
                extraFieldLength += UnixExtraField.computeTotalLength(entry.linkname);
            }
            // Note: if the archive happens to need Zip64 extensions, more header allocations will be needed.

            maxHeaderSize = max(maxHeaderSize, LocalFileHeader.computeTotalLength(path, null) + extraFieldLength);
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

        version (Windows)
        {
            import std.string : replace;

            path = replace(path, '\\', '/');
        }

        ubyte[] extraField;

        version (Posix)
        {
            import std.datetime.systime : Clock, stdTimeToUnixTime;

            const linkname = entry.linkname;
            const atime = stdTimeToUnixTime!int(Clock.currStdTime);
            const mtime = stdTimeToUnixTime!int(entry.timeLastModified.stdTime);
            const uid = entry.ownerId;
            const gid = entry.groupId;

            UnixExtraField unix = void;
            unix.id = UnixExtraField.expectedId;
            unix.size = cast(ushort)(linkname.length + 12);
            unix.atime = atime;
            unix.mtime = mtime;
            unix.uid = cast(ushort) uid;
            unix.gid = cast(ushort) gid;

            extraField = new ubyte[unix.computeTotalLength(linkname) + SquizBoxExtraField.sizeof];
            unix.writeTo(extraField[0 .. $ - SquizBoxExtraField.sizeof], linkname);
        }
        else
        {
            extraField = new ubyte[SquizBoxExtraField.sizeof];
        }
        SquizBoxExtraField sb;
        sb.attributes = entry.attributes;
        sb.writeTo(extraField[$ - SquizBoxExtraField.sizeof .. $]);

        // TODO Zip64

        const localHeaderLength = LocalFileHeader.computeTotalLength(path, extraField);
        const centralHeaderLength = CentralFileHeader.computeTotalLength(path, extraField, null);

        static if (!isForwardRange!I)
        {
            if (localHeaderBuffer.length < localHeaderLength)
                localHeaderBuffer.length = localHeaderLength;
            centralHeaderBuffer.length += centralHeaderLength;
        }

        LocalFileHeader local = void;
        local.signature = LocalFileHeader.expectedSignature;
        local.extractVersion = 20;
        local.flag = 0;
        local.compressionMethod = 8;
        local.lastModDosTime = SysTimeToDosFileTime(entry.timeLastModified);
        local.crc32 = cast(uint) deflater.crc32;
        local.compressedSize = cast(uint) currentDeflated.length;
        local.uncompressedSize = cast(uint) deflater.inflatedSize;
        // TODO: use store instead of deflate if smaller
        local.fileNameLength = cast(ushort) path.length;
        local.extraFieldLength = cast(ushort) extraField.length;
        currentLocalHeader = local.writeTo(localHeaderBuffer, path, extraField);

        ushort versionMadeBy = 20;
        uint externalAttributes = entry.attributes;

        version (Posix)
        {
            versionMadeBy |= 0x0300;
            externalAttributes = (externalAttributes & 0xffff) << 16;
        }

        CentralFileHeader central = void;
        central.signature = CentralFileHeader.expectedSignature;
        central.versionMadeBy = versionMadeBy;
        central.extractVersion = 20;
        central.flag = 0;
        central.compressionMethod = 8;
        central.lastModDosTime = SysTimeToDosFileTime(entry.timeLastModified);
        central.crc32 = cast(uint) deflater.crc32;
        central.compressedSize = cast(uint) currentDeflated.length;
        central.uncompressedSize = cast(uint) deflater.inflatedSize;
        central.fileNameLength = cast(ushort) path.length;
        central.extraFieldLength = cast(ushort) extraField.length;
        central.fileCommentLength = 0;
        central.diskNumberStart = 0;
        central.internalFileAttributes = 0;
        central.externalFileAttributes = externalAttributes;
        central.relativeLocalHeaderOffset = cast(uint) localHeaderOffset;
        central.writeTo(
            centralHeaderBuffer[centralDirectory.length .. centralDirectory.length + centralHeaderLength],
            path, extraField, null
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
        EndOfCentralDirectory footer = void;
        footer.signature = EndOfCentralDirectory.expectedSignature;
        footer.thisDisk = 0;
        footer.centralDirDisk = 0;
        footer.centralDirEntriesOnThisDisk = cast(ushort) centralDirEntries;
        footer.centralDirEntries = cast(ushort) centralDirEntries;
        footer.centralDirSize = cast(uint) centralDirSize;
        footer.centralDirOffset = cast(uint) centralDirOffset;
        footer.fileCommentLength = 0;

        endOfCentralDirectory = new ubyte[EndOfCentralDirectory.computeTotalLength(null)];
        endOfCentralDirectory = footer.writeTo(endOfCentralDirectory, null);

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

            if (!endOfCentralDirReady)
                prepareEndOfCentralDir();

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
    // The zlib stream, configured to not perform any wrapping or integrity check.
    // As this is a heap allocated class, no need of pointer
    z_stream stream;

    // buffer that receive compressed data. Only grows from one entry to the next
    ubyte[] deflateBuffer;
    // slice of buffer that contains compressed data of the last entry.
    ubyte[] deflated;
    // unompressed size of the last entry
    size_t inflatedSize;
    // CRC32 checksum of the last entry
    ulong crc32;

    this()
    {
        stream.zalloc = &(gcAlloc!uint);
        stream.zfree = &gcFree;

        const level = 6;
        const windowBits = 15;
        const memLevel = 8;
        const strategy = Z_DEFAULT_STRATEGY;

        const ret = deflateInit2(
            &stream, level, Z_DEFLATED,
            -windowBits /* negative to remove zlib wrapper */ ,
            memLevel,
            strategy
        );

        enforce(
            ret == Z_OK,
            "Could not initialize Zlib deflate stream: " ~ zResultToString(ret)
        );
    }

    void deflateEntry(ByteRange input)
    {
        if (deflateBuffer)
        {
            // the stream was used, we have to reset it
            deflateReset(&stream);
            deflated = null;
            inflatedSize = 0;
        }
        else
        {
            // arbitrary initial buffer size
            deflateBuffer = new ubyte[64 * 1024];
        }

        crc32 = squiz_box.c.zlib.crc32(0, null, 0);

        ubyte[] inChunk;

        while (true)
        {
            if (inChunk.length == 0 && !input.empty)
            {
                inChunk = input.front;
                inflatedSize += inChunk.length;
                crc32 = squiz_box.c.zlib.crc32(crc32, inChunk.ptr, cast(uint)(inChunk.length));
            }

            if (deflated.length == deflateBuffer.length)
            {
                deflateBuffer.length += 8192;
                deflated = deflateBuffer[0 .. deflated.length];
            }

            stream.next_in = inChunk.ptr;
            stream.avail_in = cast(uint) inChunk.length;
            stream.next_out = deflateBuffer.ptr + deflated.length;
            stream.avail_out = cast(uint)(deflateBuffer.length - deflated.length);

            const action = input.empty ? Z_FINISH : Z_NO_FLUSH;
            const res = deflate(&stream, action);

            const processedIn = inChunk.length - stream.avail_in;
            const deflateEnd = deflateBuffer.length - stream.avail_out;
            inChunk = inChunk[processedIn .. $];
            deflated = deflateBuffer[0 .. deflateEnd];

            if (inChunk.length == 0 && !input.empty)
                input.popFront();

            if (res == Z_STREAM_END)
                break;

            enforce(
                res == Z_OK,
                "Zlib deflate failed with code: " ~ zResultToString(res)
            );
        }
    }
}

auto readZipArchive(I)(I input)
if (isByteRange!I && !isRandomAccessRange!I)
{
    auto dataInput = new ByteRangeDataInput!I(input);
    return ZipArchiveReadStream(dataInput);
}

private struct ZipArchiveReadStream
{
    private DataInput input;
    private ArchiveExtractEntry currentEntry;
    ubyte[] fieldBuf;
    size_t nextHeader;

    this(DataInput input)
    {
        this.input = input;
        fieldBuf = new ubyte[ushort.max];
        readEntryHeader();
    }

    @property bool empty()
    {
        return input.eoi;
    }

    @property ArchiveExtractEntry front()
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
        readEntryHeader();
    }

    private void readEntryHeader()
    {
        import std.datetime.systime : DosFileTimeToSysTime, unixTimeToStdTime, SysTime;

        LocalFileHeader header;
        auto ptr = cast(ubyte*)&header;
        auto buffer = ptr[0 .. LocalFileHeader.sizeof];
        auto read = input.read(buffer);
        if (read.length >= 4 && header.signature == CentralFileHeader.expectedSignature)
        {
            // we've gone through all entries, we have no interest in the central directory
            input.ffw(size_t.max);
            return;
        }
        enforce(
            read.length >= 4 && header.signature == LocalFileHeader.expectedSignature,
            "Expected a Zip local header signature. File could be corrupted or not a Zip file."
        );
        enforce(read.length == buffer.length, "Unexpected end of input");

        const flag = cast(ZipFlag) header.flag.val;
        enforce((flag & ZipFlag.encryption) == ZipFlag.none, "Zip encryption unsupported");
        enforce((flag & ZipFlag.dataDescriptor) == ZipFlag.none, "Zip format unsupported (data descriptor)");

        enforce(
            header.compressionMethod.val == 0 || header.compressionMethod.val == 8,
            "Unsupported Zip compression method"
        );

        // TODO check for presence of encryption header and data descriptor
        auto path = cast(string) input.read(fieldBuf[0 .. header.fileNameLength.val]).idup;
        enforce(path.length == header.fileNameLength.val, "Unexpected end of input");
        auto extraField = input.read(fieldBuf[0 .. header.extraFieldLength.val]).dup;
        enforce(extraField.length == header.extraFieldLength.val, "Unexpected end of input");

        EntryData data;
        data.path = path;
        data.type = EntryType.regular;
        data.size = header.uncompressedSize.val;
        size_t compressedSz = header.compressedSize.val;

        data.timeLastModified = DosFileTimeToSysTime(header.lastModDosTime.val);

        while (extraField.length != 0)
        {
            enforce(extraField.length >= 4, "Corrupted Zip File (incomplete extra-field)");

            auto efh = cast(ExtraFieldHeader*) extraField.ptr;

            const efLen = efh.size.val + 4;
            enforce(extraField.length >= efLen, "Corrupted Zip file (incomplete extra-field)");

            switch (efh.id.val)
            {
            case Zip64ExtraField.expectedId:
                auto ef = cast(Zip64ExtraField*) extraField.ptr;
                data.size = ef.uncompressedSize.val;
                compressedSz = ef.compressedSize.val;
                break;
            case SquizBoxExtraField.expectedId:
                auto ef = cast(SquizBoxExtraField*) extraField.ptr;
                data.attributes = ef.attributes.val;
                break;
                // dfmt off
            version (Posix)
            {
                case UnixExtraField.expectedId:
                    auto ef = cast(UnixExtraField*) extraField.ptr;
                    data.timeLastModified = SysTime(unixTimeToStdTime(ef.mtime.val));
                    data.ownerId = ef.uid.val;
                    data.groupId = ef.gid.val;
                    if (efLen > UnixExtraField.sizeof)
                    {
                        data.linkname = cast(string)
                            extraField[UnixExtraField.sizeof .. efLen].idup;
                        data.type = EntryType.symlink;
                    }
                    break;
            }
            // dfmt on
            default:
                break;
            }

            extraField = extraField[efLen .. $];
        }

        data.entrySize = header.totalLength() + compressedSz;

        nextHeader = input.pos + compressedSz;

        currentEntry = new ZipArchiveExtractEntry(
            input, data, compressedSz, header.crc32.val, header.compressionMethod.val == 8
        );
    }
}

private class ZipArchiveExtractEntry : ArchiveExtractEntry
{
    DataInput input;
    size_t startPos;
    EntryData data;
    size_t compressedSize;
    uint expectedCrc32;
    bool deflated;

    this(DataInput input, EntryData data, size_t compressedSize, uint expectedCrc32, bool deflated)
    {
        this.input = input;
        this.startPos = input.pos;
        this.data = data;
        this.compressedSize = compressedSize;
        this.expectedCrc32 = expectedCrc32;
        this.deflated = deflated;
    }

    @property EntryMode mode()
    {
        return EntryMode.extraction;
    }

    @property string path()
    {
        return data.path;
    }

    @property EntryType type()
    {
        return data.type;
    }

    @property string linkname()
    {
        return data.linkname;
    }

    @property size_t size()
    {
        return data.size;
    }

    @property size_t entrySize()
    {
        return data.entrySize;
    }

    @property SysTime timeLastModified()
    {
        return data.timeLastModified;
    }

    @property uint attributes()
    {
        return data.attributes;
    }

    version (Posix)
    {
        @property int ownerId()
        {
            return data.ownerId;
        }

        @property int groupId()
        {
            return data.groupId;
        }
    }

    ByteRange byChunk(size_t chunkSize)
    {
        enforce(
            input.pos == startPos,
            "Data cursor has moved, this entry is not valid anymore"
        );

        if (deflated)
            return new InflateByChunk(input, compressedSize, chunkSize, expectedCrc32);
        else
            return new StoredByChunk(input, compressedSize, chunkSize, expectedCrc32);
    }
}

/// common code between InflateByChunk and StoredByChunk
private abstract class ZipByChunk : ByteRange
{
    ubyte[] moveFront()
    {
        throw new UnsupportedRangeMethod(
            "Cannot move the front of a(n) Zip `Inflater`"
        );
    }

    int opApply(scope int delegate(ubyte[]) dg)
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

    int opApply(scope int delegate(size_t, ubyte[]) dg)
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
private class StoredByChunk : ZipByChunk
{
    DataInput input;
    size_t currentPos;
    size_t size;
    ubyte[] outBuffer;
    ubyte[] outChunk;
    ulong calculatedCrc32;
    uint expectedCrc32;
    bool ended;

    this(DataInput input, size_t size, size_t chunkSize, uint expectedCrc32)
    {
        this.input = input;
        this.currentPos = input.pos;
        this.size = size;
        this.outBuffer = new ubyte[chunkSize];
        this.expectedCrc32 = expectedCrc32;

        this.calculatedCrc32 = crc32(0, null, 0);

        prime();
    }

    @property bool empty()
    {
        return size == 0 && outChunk.length == 0;
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
        import std.algorithm : min;

        enforce(input.pos == currentPos,
            "Data cursor has moved. Entry is no longer valid."
        );
        const len = min(size, outBuffer.length);
        outChunk = input.read(outBuffer[0 .. len]);
        enforce(outChunk.length == len, "Corrupted Zip file: unexpected end of input");
        currentPos += len;
        size -= len;

        calculatedCrc32 = crc32(calculatedCrc32, outChunk.ptr, cast(uint) len);

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
private class InflateByChunk : ZipByChunk
{
    z_stream stream;
    DataInput input;
    size_t currentPos;
    size_t compressedSz;
    ubyte[] outBuffer;
    ubyte[] outChunk;
    ubyte[] inBuffer;
    ubyte[] inChunk;
    ulong calculatedCrc32;
    uint expectedCrc32;
    bool ended;

    this(DataInput input, size_t compressedSz, size_t chunkSize, uint expectedCrc32)
    {
        this.input = input;
        this.currentPos = input.pos;
        this.compressedSz = compressedSz;
        this.outBuffer = new ubyte[chunkSize];
        this.inBuffer = new ubyte[defaultChunkSize];
        this.expectedCrc32 = expectedCrc32;

        this.calculatedCrc32 = crc32(0, null, 0);
        const res = inflateInit2(&stream, -15);
        enforce(
            res == Z_OK,
            "Could not initialize Zlib inflate stream: " ~ zResultToString(res)
        );

        prime();
    }

    @property bool empty()
    {
        return compressedSz == 0 && outChunk.length == 0;
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
        import std.algorithm : min;

        while (outChunk.length < outBuffer.length)
        {
            if (inChunk.length == 0 && compressedSz != 0)
            {
                enforce(input.pos == currentPos,
                    "Data cursor has moved. Entry is no longer valid."
                );
                const len = min(compressedSz, inBuffer.length);
                inChunk = input.read(inBuffer[0 .. len]);
                enforce(inChunk.length == len, "Corrupted Zip file: unexpected end of input");
                currentPos += len;
                compressedSz -= len;
            }

            stream.next_in = inChunk.ptr;
            stream.avail_in = cast(typeof(stream.avail_in)) inChunk.length;

            stream.next_out = outBuffer.ptr + outChunk.length;
            stream.avail_out = cast(typeof(stream.avail_out))(outBuffer.length - outChunk.length);

            const res = inflate(&stream, Z_NO_FLUSH);

            enforce(res == Z_OK || res == Z_STREAM_END,
                "Error during Zip inflation: " ~ zResultToString(res)
            );

            const readIn = inChunk.length - stream.avail_in;
            inChunk = inChunk[readIn .. $];

            const outEnd = outBuffer.length - stream.avail_out;
            outChunk = outBuffer[0 .. outEnd];

            calculatedCrc32 = crc32(calculatedCrc32, outChunk.ptr, cast(uint) outChunk.length);

            if (res == Z_STREAM_END)
            {
                ended = true;
                enforce(
                    calculatedCrc32 == expectedCrc32,
                    "Corrupted Zip file: Wrong CRC32 checkum"
                );
                break;
            }
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
    LittleEndian!8 relHeaderOffset;
    LittleEndian!4 diskStartNumber;
}

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
}

// Extra field that places the file attributes in the local header
private struct SquizBoxExtraField
{
    enum expectedId = 0x4273; // SB

    LittleEndian!2 id = expectedId;
    LittleEndian!2 size = 4;
    LittleEndian!4 attributes;

    void writeTo(ubyte[] buffer)
    {
        assert(buffer.length == 8);
        auto ptr = id.data.ptr;
        buffer[0 .. SquizBoxExtraField.sizeof] = ptr[0 .. SquizBoxExtraField.sizeof];
    }
}

static assert(SquizBoxExtraField.sizeof == 8);

private struct LittleEndian(size_t sz) if (sz == 2 || sz == 4 || sz == 8)
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
