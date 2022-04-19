module test.archive;

import squiz_box.tar;

import test.util : binDiff, DeleteMe, testPath;

string[] filesForArchive()
{
    return [
        testPath("data/file1.txt"),
        testPath("data/file 2.txt"),
        testPath("data/folder/chmod 666.txt"),
    ];
}

@("Write tar")
unittest
{
    import std.conv : to;
    import std.file : read;
    import std.process : execute;
    import std.regex : matchFirst;
    import std.stdio : File;
    import std.string : splitLines;

    auto archive = DeleteMe("archive", ".tar");
    const files = filesForArchive();
    auto tar = ArchiveTar.createWithFiles(files, testPath("data"));
    auto f = File(archive.path, "wb");
    foreach (chunk; tar.byChunk(4096))
    {
        f.rawWrite(chunk);
    }
    f.close();

    const line1 = `^-rw-r--r-- .+ 7 .+ file1.txt$`;
    const line2 = `^-rw-r--r-- .+ 3521 .+ file 2.txt$`;
    const line3 = `^-rw-rw-rw- .+ 26 .+ folder/chmod 666.txt$`;

    const res = execute(["tar", "-tvf", archive.path]);
    assert(res.status == 0);
    const lines = res.output.splitLines();
    assert(matchFirst(lines[0], line1));
    assert(matchFirst(lines[1], line2));
    assert(matchFirst(lines[2], line3));
}

@("Read tar")
unittest
{
    import std.conv : octal;
    import std.digest.sha : SHA1;
    import std.digest : hexDigest;

    struct Entry
    {
        string path;
        uint permissions;
        size_t size;
        char[40] sha1;
    }

    const expected = [
        Entry("file1.txt", octal!"644", 7, "38505A984F71C07843A5F3E394ADA2BF4C7B6ABC"),
        Entry("file 2.txt", octal!"644", 3521, "01FA4C5C29A58449EEF1665658C48C0D7829C45F"),
        Entry("folder/chmod 666.txt", octal!"666", 26, "3E31B8E6B2BBBA1EDFCFDCA886E246C9E120BBE3"),
    ];

    auto archive = ArchiveTar.readFromPath(testPath("data/archive.tar"));

    Entry[] entries;
    foreach (entry; archive.entries)
    {
        entries ~= Entry(entry.path, entry.permissions, entry.size, hexDigest!SHA1(
                entry.readContent()));
    }

    import std.stdio;

    writeln(entries);

    assert(entries == expected);
}
