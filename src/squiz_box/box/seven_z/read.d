module squiz_box.box.seven_z.read;

import squiz_box.box.seven_z.header;
import squiz_box.squiz;
import squiz_box.priv;

import std.exception;
import io = std.stdio;

auto read7zArchive(io.File file)
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
    private C cursor;
    private ulong packStartOffset;
    private Header header;

    this(C cursor)
    {
        this.cursor = cursor;
        readHeaders();
    }

    private void readHeaders()
    {
        auto signHeader = trace7z!(() => SignatureHeader.read(cursor));
        packStartOffset = cursor.pos;

        if (signHeader.headerSize == 0)
            return;

        cursor.seek(signHeader.headerPos);

        const headerBytes = cursor.readArray(signHeader.headerSize);
        const headerCrc = Crc32.calc(headerBytes);
        if (headerCrc != signHeader.headerCrc)
            bad7z(cursor.name, "Could not verify header integrity");

        auto headerCursor = new ArrayCursor(headerBytes, cursor.name);

        header = trace7z!(() => Header.read(headerCursor, cursor, packStartOffset));
    }
}

package class FolderDecoder
{
    SearchableCursor cursor;
    const(StreamsInfo) info;
    size_t folder;

    SquizAlgo algo;
    SquizStream stream;
    size_t packPos;
    size_t packEnd;
    size_t unpackPos;
    ubyte[] inBuf;
    ubyte[] outBuf;
    ubyte[] availOut;

    this(SearchableCursor cursor, const(StreamsInfo) info, size_t folder)
    {
        this.cursor = cursor;
        this.info = info;
        this.folder = folder;

        this.algo = info.folderInfo(folder).buildUnpackAlgo();
        this.packPos = info.streamPackStart(folder);
        this.packEnd = this.packPos + info.streamPackSize(folder);
        this.inBuf = new ubyte[defaultChunkSize];
        this.outBuf = new ubyte[defaultChunkSize];
    }

    ubyte[] decode(ubyte[] buf)
    {
        ubyte[] res;

        while(res.length < buf.length)
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

        return res;
    }
}
