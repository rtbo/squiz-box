module squiz_box.box.seven_z.read;

import squiz_box.box.seven_z.header;
import squiz_box.box.seven_z.utils;
import squiz_box.box;
import squiz_box.squiz;
import squiz_box.priv;

import std.exception;
import io = std.stdio;

auto unbox7z(io.File file)
{
    auto cursor = new FileCursor(file);
    return Unbox7z!FileCursor(cursor);
}

auto unbox7z(ubyte[] data)
{
    auto cursor = new ArrayCursor(data);
    return Unbox7z!ArrayCursor(cursor);
}

private struct Unbox7z(C) if (is(C : SearchableCursor))
{
    private C cursor;

    private ulong packStartOffset;
    private Header header;

    private size_t currentFile;
    private size_t currentFolder;
    private size_t currentSubstream;
    private FolderDecoder decoder;

    private SevZUnboxEntry currentEntry;

    this(C cursor)
    {
        this.cursor = cursor;
        readHeaders();

        if (header.numFiles > 0)
            nextFile();
    }

    private void readHeaders()
    {
        auto signHeader = traceRead!(() => SignatureHeader.read(cursor));
        packStartOffset = cursor.pos;

        if (signHeader.headerSize == 0)
            return;

        cursor.seek(signHeader.headerPos);

        const headerBytes = cursor.readArray(signHeader.headerSize);
        const headerCrc = Crc32.calc(headerBytes);
        if (headerCrc != signHeader.headerCrc)
            bad7z(cursor.source, "Could not verify header integrity");

        auto headerCursor = new ArrayCursor(headerBytes, cursor.source);

        header = traceRead!(() => Header.read(headerCursor, cursor, packStartOffset));
    }

    private void nextFile()
    {
        const info = header.filesInfo.files[currentFile];

        ulong startUnpack = header.streamsInfo
            .folderSubstreamStart(currentFolder, currentSubstream);
        ulong sizeUnpack = header.streamsInfo
            .folderSubstreamSize(currentFolder, currentSubstream);

        if (!decoder)
            decoder = new FolderDecoder(cursor, packStartOffset, header.streamsInfo, currentFolder);

        const expectedCrc = header.streamsInfo.folderSubstreamCrc(currentFolder, currentSubstream);
        currentEntry = new SevZUnboxEntry(info, sizeUnpack, startUnpack, decoder, cursor.source, expectedCrc);

        currentFile++;
        currentSubstream++;

        if (currentSubstream > header.streamsInfo.folderSubstreams(currentFolder))
        {
            decoder = null;
            currentFolder++;
            currentSubstream = 0;
        }
    }

    @property UnboxEntry front()
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
        if (currentFile < header.numFiles)
            nextFile();
    }
}

private final class SevZUnboxEntry : UnboxEntry
{
    FileInfo _info;
    size_t _size;
    size_t _unpackPos;
    FolderDecoder _decoder;
    string _archive;
    Crc32 _expectedCrc;

    this(FileInfo info, size_t size, size_t unpackPos, FolderDecoder decoder, string archive, Crc32 expectedCrc)
    {
        _info = info;
        _size = size;
        _unpackPos = unpackPos;
        _decoder = decoder;
        _archive = archive;
        _expectedCrc = expectedCrc;
    }

    ByteRange byChunk(size_t chunkSize = defaultChunkSize)
    {
        return inputRangeObject!EntryDecoderRange(
            EntryDecoderRange(_decoder, _unpackPos, _unpackPos + _size,
                chunkSize, _archive, _info.name, _expectedCrc));
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
        return _info.name;
    }

    @property EntryType type()
    {
        return attrIsDir(_info.attributes) ? EntryType.directory : EntryType.regular;
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
        return SysTime(_info.mtime);
    }

    @property uint attributes()
    {
        version (Posix)
        {
            if (_info.attributes & 0x8000)
                return (_info.attributes & 0xffff0000) >> 16;
            else
                return octal!"100644";
        }
        else
        {
            return _info.attributes & 0xffff;
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

package class FolderDecoder
{
    SearchableCursor cursor;
    const(MainStreamsInfo) info;
    size_t folder;

    SquizAlgo algo;
    SquizStream stream;
    size_t packPos;
    size_t packEnd;
    size_t unpackPos;
    ubyte[] inBuf;
    ubyte[] outBuf;
    ubyte[] availOut;

    this(SearchableCursor cursor, size_t packStartOffset, const(MainStreamsInfo) info, size_t folder)
    {
        this.cursor = cursor;
        this.info = info;
        this.folder = folder;

        this.algo = info.folderInfo(folder).buildUnpackAlgo();
        this.stream = algo.initialize();
        this.packPos = packStartOffset + info.streamPackStart(folder);
        this.packEnd = this.packPos + info.streamPackSize(folder);
        this.inBuf = new ubyte[defaultChunkSize];
        this.outBuf = new ubyte[defaultChunkSize];
    }

    ubyte[] decode(ubyte[] buf)
    {
        ubyte[] res;

        while (res.length < buf.length)
        {
            // take what's left from stream.output
            if (availOut.length)
            {
                const len = min(availOut.length, buf.length - res.length);
                buf[res.length .. res.length + len] = availOut[0 .. len];
                res = buf[0 .. res.length + len];
                availOut = availOut[len .. $];
                continue;
            }

            // ensurring input data to decoder
            if (stream.input.length == 0 && packPos != packEnd)
            {
                const len = min(inBuf.length, packEnd - packPos);
                cursor.seek(packPos);
                stream.input = cursor.read(inBuf[0 .. len]);
                enforce(stream.input.length == len, "Unexpected end of input");
                packPos += stream.input.length;
            }

            if (stream.output.length == 0)
            {
                stream.output = outBuf;
                assert(availOut.length == 0);
            }

            auto startOut = stream.output;
            const lastChunk = cast(Flag!"lastChunk")(packEnd == packPos);
            algo.process(stream, lastChunk);

            availOut = startOut[0 .. startOut.length - stream.output.length];
        }

        unpackPos += res.length;

        return res;
    }
}

private struct EntryDecoderRange
{
    FolderDecoder decoder;
    ulong pos;
    ulong end;
    ubyte[] buffer;
    ubyte[] chunk;
    string archive;
    string entry;
    Crc32 expectedCrc;
    Crc32 currentCrc;

    this(FolderDecoder decoder, ulong pos, ulong end, size_t chunkSize, string archive, string entry, Crc32 crc)
    {
        this.decoder = decoder;
        this.pos = pos;
        this.end = end;
        this.buffer = new ubyte[chunkSize];
        this.archive = archive;
        this.entry = entry;
        this.expectedCrc = crc;

        prime();
    }

    private void prime()
    {
        while (chunk.length < buffer.length && pos < end)
        {
            assert(pos == decoder.unpackPos, "Cursor has moved, entry no longer valid");
            const len = min(buffer.length - chunk.length, end - pos);
            auto res = decoder.decode(buffer[chunk.length .. chunk.length + len]);
            chunk = buffer[0 .. chunk.length + res.length];
            pos += res.length;
        }

        if (chunk.length && expectedCrc)
        {
            currentCrc.update(chunk);

            if (pos == end && currentCrc != expectedCrc)
            {
                throw new DataIntegrity7zArchiveException(
                    archive,
                    entry,
                    cast(uint) expectedCrc,
                    cast(uint) currentCrc
                );
            }
        }

    }

    bool empty()
    {
        return chunk.length == 0;
    }

    const(ubyte)[] front()
    {
        return chunk;
    }

    void popFront()
    {
        chunk = null;
        prime();
    }
}
