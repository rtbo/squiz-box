module test.archive;

import squiz_box.core;
import squiz_box.tar;

import test.util;

string[] filesForArchive()
{
    return [
        testPath("data/file1.txt"),
        testPath("data/file 2.txt"),
        testPath("data/folder/chmod 666.txt"),
    ];
}

version (Posix)
{
    shared static this()
    {
        import std.process;

        execute(["chmod", "666", testPath("data/folder/chmod 666.txt")]);
    }
}

void testArchiveContent(string archivePath)
{
    import std.algorithm : canFind;
    import std.process : execute, executeShell, escapeShellFileName;
    import std.regex : matchFirst;
    import std.string : splitLines;

    const line1 = `^-rw-r--r-- .+ 7 .+ file1.txt$`;
    const line2 = `^-rw-r--r-- .+ 3521 .+ file 2.txt$`;
    const line3 = `^-rw-rw-rw- .+ 26 .+ folder/chmod 666.txt$`;

    auto res = execute(["tar", "-tvf", archivePath]);
    assert(res.status == 0);
    const lines = res.output.splitLines();
    assert(lines.length == 3);
    assert(matchFirst(lines[0], line1));
    assert(matchFirst(lines[1], line2));
    assert(matchFirst(lines[2], line3));

    const archiveShell = escapeShellFileName(archivePath);

    res = executeShell("tar -xOf " ~ archiveShell ~ " file1.txt | sha1sum");
    assert(res.status == 0);
    assert(res.output.canFind("38505a984f71c07843a5f3e394ada2bf4c7b6abc"));

    res = executeShell("tar -xOf " ~ archiveShell ~ " 'file 2.txt' | sha1sum");
    assert(res.status == 0);
    assert(res.output.canFind("01fa4c5c29a58449eef1665658c48c0d7829c45f"));

    res = executeShell("tar -xOf " ~ archiveShell ~ " 'folder/chmod 666.txt' | sha1sum");
    assert(res.status == 0);
    assert(res.output.canFind("3e31b8e6b2bbba1edfcfdca886e246c9e120bbe3"));

}

@("Create tar")
unittest
{
    import std.algorithm : map, sum;
    import std.file : read;

    auto archive = Path("archive", ".tar");
    auto base = testPath("data");

    filesForArchive()
        .map!(p => fileEntryFromBase(p, base))
        .createTarArchive()
        .writeToFile(archive.path);

    testArchiveContent(archive.path);

    enum expectedLen = 2 * 512 + 512 + 3584 + 2 * 512 + 2 * 512;
    auto content = cast(const(ubyte)[]) read(archive.path);
    assert(content.length == expectedLen);
    assert(content[$ - 1024 .. $].sum() == 0);
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
        const content = entry.readContent;

        entries ~= Entry(
            entry.path,
            entry.permissions,
            entry.size,
            hexDigest!SHA1(content)
        );
    }

    assert(entries == expected);
}
