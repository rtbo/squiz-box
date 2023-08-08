module test.tar;

import squiz_box;

import unit_threaded.assertions;

import std.algorithm;
import std.array;
import std.conv;
import std.range;
import std.stdio;
import std.string;
import std.typecons;

@("tar read/write gnulong #17")
unittest
{
    const content = cast(ByteChunk)("the content of the file".representation);
    const filename = "long-path".repeat(55).join("/") ~ "/file.txt";
    const linkname = "long-path".repeat(55).join("/") ~ "/link.txt";

    const entries = only(
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
        .unboxTar()
        .map!(e => tuple(e.path, e.type, e.linkname, e.size, cast(ByteChunk)e.readContent()))
        .array;

    entries.length.should == 2;
    entries[0].should == tuple(
        filename,
        EntryType.regular,
        cast(string)null,
        content.length,
        content,
    );
    entries[1].should == tuple(
        linkname,
        EntryType.symlink,
        filename,
        ulong(0),
        cast(ByteChunk)null,
    );
}
