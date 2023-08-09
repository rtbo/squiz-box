module test.tar;

import squiz_box;

import std.algorithm;
import std.array;
import std.conv;
import std.range;
import std.stdio;
import std.string;
import std.typecons;

enum blockLen = 512;
enum nameLen = 100;
enum unameLen = 32;
enum prefixLen = 155;

enum char[8] posixMagic = "ustar\x0000";
enum char[8] gnuMagic = "ustar  \x00";

struct Block
{
    // dfmt off
    char [nameLen]      name;       //   0    0
    char [8]            mode;       // 100   64
    char [8]            uid;        // 108   6C
    char [8]            gid;        // 116   74
    char [12]           size;       // 124   7C
    char [12]           mtime;      // 136   88
    char [8]            chksum;     // 148   94
    char                typeflag;   // 156   9C
    char [nameLen]      linkname;   // 157   9D
    char [8]            magic;      // 257  101
    char [unameLen]     uname;      // 265  109
    char [unameLen]     gname;      // 297  129
    char [8]            devmajor;   // 329  149
    char [8]            devminor;   // 337  151
    char [prefixLen]    prefix;     // 345  159
    char [12]           padding;    // 500  1F4
    //dfmt on
}

@("read/write name 100 chars")
unittest
{
    const content = cast(ByteChunk)("the content of the file".representation);
    const filename = "long-path".repeat(9).join("/") ~ "/123456.txt";

    assert(filename.length == nameLen);

    // dfmt off
    const tarData = only(
            infoEntry(BoxEntryInfo(
                path: filename,
                type: EntryType.regular,
                size: content.length,
                attributes: octal!"100644",
            ),
            only(content))
        )
        .boxTar()
        .join();
    // dfmt on

    //  0   file block
    //  1   file data
    //  2   footer (x2)
    assert(tarData.length == 4 * blockLen);

    const(Block)* blk = cast(const(Block)*)&tarData[0];
    assert(blk.typeflag == '0');
    assert(blk.magic == posixMagic);
    assert(blk.name == filename);
    assert(blk.prefix[0] == '\0');
    assert(tarData[1 * blockLen .. $].startsWith(content));

    assert(tarData[2 * blockLen .. $].all!"a == 0");

    const entries = only(tarData)
        .unboxTar()
        .map!(e => tuple(e.path, e.type, e.size, cast(ByteChunk) e.readContent()))
        .array;

    assert(entries.length == 1);
    assert(entries[0] == tuple(
        filename,
        EntryType.regular,
        content.length,
        content,
    ));
}

@("read/write split prefix")
unittest
{
    const content = cast(ByteChunk)("the content of the file".representation);
    const filename = "long-path".repeat(11).join("/") ~ "/file.txt";

    assert(filename.length > nameLen && filename.length < nameLen + prefixLen);

    // dfmt off
    const tarData = only(
            infoEntry(BoxEntryInfo(
                path: filename,
                type: EntryType.regular,
                size: content.length,
                attributes: octal!"100644",
            ),
            only(content))
        )
        .boxTar()
        .join();
    // dfmt on

    //  0   file block
    //  1   file data
    //  2   footer (x2)
    assert(tarData.length == 4 * blockLen);

    const(Block)* blk = cast(const(Block)*)&tarData[0];
    assert(blk.typeflag == '0');
    assert(blk.magic == posixMagic);
    assert(blk.prefix[0 .. 9] == "long-path");
    assert(tarData[1 * blockLen .. $].startsWith(content));

    assert(tarData[2 * blockLen .. $].all!"a == 0");

    const entries = only(tarData)
        .unboxTar()
        .map!(e => tuple(e.path, e.type, e.size, cast(ByteChunk) e.readContent()))
        .array;

    assert(entries.length == 1);
    assert(entries[0] == tuple(
        filename,
        EntryType.regular,
        content.length,
        content,
    ));
}

@("read/write gnulong #17")
unittest
{
    const content = cast(ByteChunk)("the content of the file".representation);
    const filename = "long-path".repeat(55).join("/") ~ "/file.txt";
    const linkname = "long-path".repeat(55).join("/") ~ "/link.txt";

    assert(filename.length > nameLen + prefixLen);
    assert(linkname.length > nameLen + prefixLen);

    // dfmt off
    const tarData = only(
            infoEntry(BoxEntryInfo(
                path: filename,
                type: EntryType.regular,
                size: content.length,
                attributes: octal!"100644",
            ),
            only(content)),
            infoEntry(BoxEntryInfo(
                path: linkname,
                type: EntryType.symlink,
                linkname: filename,
                attributes: octal!"100644",
            )))
        .boxTar()
        .join();
    // dfmt on

    //  0   file name block
    //  1   file name data (x2)
    //  3   file block
    //  4   file data
    //  5   link name block
    //  6   link name data (x2)
    //  8   link linkname block
    //  9   link linkname data (x2)
    //  11  link block
    //  12  footer (x2)
    assert(tarData.length == 14 * blockLen);

    const(Block)* blk = cast(const(Block)*)&tarData[0];
    assert(blk.typeflag == 'L');
    assert(blk.magic == gnuMagic);
    assert(tarData[blockLen .. $].startsWith(filename.representation));

    blk = cast(const(Block)*)&tarData[3 * blockLen];
    assert(blk.typeflag == '0');
    assert(blk.magic == posixMagic);
    assert(tarData[4 * blockLen .. $].startsWith(content));

    blk = cast(const(Block)*)&tarData[5 * blockLen];
    assert(blk.typeflag == 'L');
    assert(blk.magic == gnuMagic);
    assert(tarData[6 * blockLen .. $].startsWith(linkname.representation));

    blk = cast(const(Block)*)&tarData[8 * blockLen];
    assert(blk.typeflag == 'K');
    assert(blk.magic == gnuMagic);
    assert(tarData[9 * blockLen .. $].startsWith(filename.representation));

    blk = cast(const(Block)*)&tarData[11 * blockLen];
    assert(blk.typeflag == '2');
    assert(blk.magic == posixMagic);

    assert(tarData[14 * blockLen .. $].all!"a == 0");

    const entries = only(tarData)
        .unboxTar()
        .map!(e => tuple(e.path, e.type, e.linkname, e.size, cast(ByteChunk) e.readContent()))
        .array;

    assert(entries.length == 2);
    assert(entries[0] == tuple(
        filename,
        EntryType.regular,
        cast(string) null,
        content.length,
        content,
    ));
    assert(entries[1] == tuple(
        linkname,
        EntryType.symlink,
        filename,
        ulong(0),
        cast(ByteChunk) null,
    ));
}
