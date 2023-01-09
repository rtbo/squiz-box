module squiz_box.box.seven_z.write;

import squiz_box.box.seven_z.error;
import squiz_box.box.seven_z.header;
import squiz_box.box.seven_z.utils;
import squiz_box.box;
import squiz_box.priv;
import squiz_box.squiz;
import squiz_box.c.lzma;

import std.array;
import std.exception;
import std.range;
import io = std.stdio;
import std.traits;

/// Box the provided entries in a 7z archive.
///
/// The archiving strategy is to put all files in a single compressed stream
/// and to also compress the header.
void box7zToFile(I)(I entries, string filename) if (isBoxEntryRange!I)
{
    auto f = io.File(filename, "wb+");
    auto cursor = new FileWriteCursor(f);
    auto box = SevenZBox!(I)(entries);
    box.write(cursor);
    cursor.close();
}

private struct SevenZBox(I)
{
    private BoxEntry[] entries;

    this(I entries)
    {
        static if (is(Unqual!I == BoxEntry[]))
        {
            this.entries = entries;
        }
        else
        {
            this.entries = entries.array;
        }
    }

    private void write(C)(C cursor)
    {
        // signature header will be written at the end
        const packOffset = SignatureHeader.byteLength;
        cursor.seek(packOffset);

        // setup compression algorithm
        auto filter = Lzma2PresetFilter(6).into;

        auto algo = squizAlgo(CompressLzma(LzmaFormat.raw, [filter]));
        auto squizStream = algo.initialize();
        auto squizBuffer = new ubyte[defaultChunkSize];

        lzma_filter c_filt = filter.toLzma();
        auto coderInfo = CoderInfo(CoderId.lzma2, computeFilterProps(&c_filt));
        auto folderInfo = FolderInfo([coderInfo]);

        Header header;

        ulong packSize;
        Crc32 packCrc;
        Crc32 unpackCrc;
        ulong[] unpackSizes;
        Crc32[] unpackCrcs;

        // write main compressed stream of all entries
        // and compute header properties on the fly
        foreach (i, f; entries)
        {
            import std.datetime;

            FileInfo finfo;
            finfo.name = f.path;
            finfo.mtime = f.timeLastModified.stdTime;
            auto attrs = f.attributes;
            version (Posix)
            {
                finfo.attributes = ((attrs & 0xffff) << 16) | 0x8000;
            }
            else
            {
                finfo.attributes = attrs & 0xffff;
            }

            if (f.type == EntryType.directory)
            {
                finfo.emptyStream = true;
            }
            else if (f.type == EntryType.regular && f.size == 0)
            {
                finfo.emptyStream = true;
                finfo.emptyFile = true;
            }
            else
            {
                enforce(f.type != EntryType.symlink, "Symlink not supported yet for 7z");

                ulong funpackSz;
                Crc32 funpackCrc;

                f.byChunk()
                    .tee!((chunk) {
                        funpackCrc.update(chunk);
                        unpackCrc.update(chunk);
                        funpackSz += chunk.length;
                    })
                    // we're not sure in advance if this is the last input, therefore pass No.lastInput.
                    .squizReuse(algo, squizStream, No.lastInput, squizBuffer)
                    .tee!((chunk) {
                        packCrc.update(chunk);
                        packSize += chunk.length;
                    })
                    .copy(cursorOutputRange(cursor));

                enforce(funpackSz == f.size, "Inconsistent size");

                unpackSizes ~= funpackSz;
                unpackCrcs ~= funpackCrc;
            }

            header.filesInfo.files ~= finfo;
        }

        // hack: closing stream with empty data (see previous comment about squizReuse)
        const(ubyte) [] dummy;
        squizReuse(only(dummy), algo, squizStream, Yes.lastInput, squizBuffer);

        // the main compression state is not needed anymore, but we can keep allocated
        // data to compress the header (`reset` is called instead of `end`)
        algo.reset(squizStream);

        // finish to define header
        if (entries.length > 1)
        {
            header.streamsInfo.subStreamsInfo.nums = [entries.length];
            header.streamsInfo.subStreamsInfo.sizes = unpackSizes[0 .. $ - 1];
            header.streamsInfo.subStreamsInfo.crcs = unpackCrcs;
        }
        header.streamsInfo.packInfo.packStart = 0;
        header.streamsInfo.packInfo.packSizes = [packSize];
        header.streamsInfo.packInfo.packCrcs = [packCrc];
        header.streamsInfo.codersInfo.folderInfos = [folderInfo];
        // TODO: if using multiple filters, write unpack size for each stage,
        // including intermediate ones:
        // - if all LZMA chain, interstage unpacks are the same as
        //      final decompressed data (filters do not change the data size)
        // - if not, implement CompoundAlgo here to extract unpack size for each stage
        header.streamsInfo.codersInfo.unpackSizes = [sum(unpackSizes)];
        header.streamsInfo.codersInfo.unpackCrcs = [unpackCrc];

        // write plain header in memory
        auto headerCursor = new ArrayWriteCursor();
        header.traceWrite(headerCursor);

        size_t headerUnpackSize;
        Crc32 headerUnpackCrc;
        size_t headerPackSize;
        Crc32 headerPackCrc;

        // write compressed header into file
        const headerPackStart = cursor.tell;

        only(headerCursor.data)
            .tee!((chunk) {
                headerUnpackSize += chunk.length;
                headerUnpackCrc.update(chunk);
            })
            .squizReuse(algo, squizStream, Yes.lastInput, squizBuffer)
            .tee!((chunk) {
                headerPackSize += chunk.length;
                headerPackCrc.update(chunk);
            })
            .copy(cursorOutputRange(cursor));

        algo.end(squizStream);

        assert(headerUnpackSize == headerCursor.data.length);

        // define encoded header stream
        HeaderStreamsInfo headerStream;
        headerStream.packInfo.packStart = headerPackStart - packOffset;
        headerStream.packInfo.packSizes = [headerPackSize];
        headerStream.packInfo.packCrcs = [headerPackCrc];
        headerStream.codersInfo.folderInfos = [folderInfo]; // reuse the same coder
        headerStream.codersInfo.unpackSizes = [headerUnpackSize];
        headerStream.codersInfo.unpackCrcs = [headerUnpackCrc];

        // and write it to memory, then to main cursor
        auto headerStreamC = new ArrayWriteCursor;
        headerStream.traceWrite(headerStreamC);

        const headerStreamStart = cursor.tell;
        const headerStreamSize = headerStreamC.data.length;
        const headerStreamCrc = Crc32.calc(headerStreamC.data);
        cursor.write(headerStreamC.data);
        assert(cursor.tell == headerStreamStart + headerStreamSize);

        // and finally the signature header
        SignatureHeader signHeader;
        signHeader.magicBytes = SignatureHeader.magicBytesRef;
        signHeader.versionBytes = SignatureHeader.versionBytesRef;
        signHeader.headerOffset = headerStreamStart - packOffset;
        signHeader.headerSize = headerStreamSize;
        signHeader.headerCrc = headerStreamCrc;
        signHeader.signHeaderCrc = signHeader.calcSignHeaderCrc;

        cursor.seek(0);
        signHeader.write(cursor);
    }
}

private ubyte[] computeFilterProps(lzma_filter* filter)
{
    uint sz;
    enforce(lzma_properties_size(&sz, filter) == lzma_ret.OK, "Could not compute LZMA properties");

    ubyte[] props;
    if (sz != 0)
    {
        props = new ubyte[sz];
        enforce(lzma_properties_encode(filter, &props[0]) == lzma_ret.OK, "Could not compute LZMA properties");
    }

    return props;
}
