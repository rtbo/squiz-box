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
