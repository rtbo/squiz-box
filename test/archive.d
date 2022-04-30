module test.archive;

import squiz_box.bz2;
import squiz_box.core;
import squiz_box.gz;
import squiz_box.tar;
import squiz_box.xz;
import squiz_box.zip;

import test.util;

import std.typecons;

string[] filesForArchive()
{
    return [
        dataGenPath("file1.txt"),
        dataGenPath("file 2.txt"),
        dataGenPath("folder/chmod 666.txt"),
    ];
}

void testTarArchiveContent(string archivePath)
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

    auto sha1sumFile(string filename)
    {
        const fileShell = escapeShellFileName(filename);
        return executeShell("tar -xOf " ~ archiveShell ~ " " ~ fileShell ~ " | sha1sum");
    }

    res = sha1sumFile("file1.txt");
    assert(res.status == 0);
    assert(res.output.canFind("38505a984f71c07843a5f3e394ada2bf4c7b6abc"));

    res = sha1sumFile("file 2.txt");
    assert(res.status == 0);
    assert(res.output.canFind("01fa4c5c29a58449eef1665658c48c0d7829c45f"));

    res = sha1sumFile("folder/chmod 666.txt");
    assert(res.status == 0);
    assert(res.output.canFind("3e31b8e6b2bbba1edfcfdca886e246c9e120bbe3"));
}

void testZipArchiveContent(string archivePath)
{
    import std.algorithm : canFind;
    import std.process : execute, executeShell, escapeShellFileName;
    import std.regex : matchFirst;
    import std.string : splitLines;

    const line1 = `^\s*7\s.+file1.txt$`;
    const line2 = `^\s*3521\s.+file 2.txt$`;
    const line3 = `^\s*26\s.+folder/chmod 666.txt$`;

    auto res = execute(["unzip", "-l", archivePath]);
    assert(res.status == 0);
    const lines = res.output.splitLines();
    assert(lines.length == 8);
    assert(matchFirst(lines[3], line1));
    assert(matchFirst(lines[4], line2));
    assert(matchFirst(lines[5], line3));

    const archiveShell = escapeShellFileName(archivePath);

    auto sha1sumFile(string filename)
    {
        const fileShell = escapeShellFileName(filename);
        return executeShell("unzip -p " ~ archiveShell ~ " " ~ fileShell ~ " | sha1sum");
    }

    res = sha1sumFile("file1.txt");
    assert(res.status == 0);
    assert(res.output.canFind("38505a984f71c07843a5f3e394ada2bf4c7b6abc"));

    res = sha1sumFile("file 2.txt");
    assert(res.status == 0);
    assert(res.output.canFind("01fa4c5c29a58449eef1665658c48c0d7829c45f"));

    res = sha1sumFile("folder/chmod 666.txt");
    assert(res.status == 0);
    assert(res.output.canFind("3e31b8e6b2bbba1edfcfdca886e246c9e120bbe3"));
}

void testExtractedFiles(DM)(auto ref DM dm, Flag!"mode666" mode666)
{
    import std.conv : octal;
    import std.digest : hexDigest;
    import std.digest.sha : SHA1;
    import std.file : read, getLinkAttributes;

    version (Posix)
    {
        assert(getLinkAttributes(dm.buildPath("file1.txt")) == octal!"100644");
        assert(getLinkAttributes(dm.buildPath("file 2.txt")) == octal!"100644");
        const m666 = mode666 ? octal!"100666" : octal!"100644";
        assert(getLinkAttributes(dm.buildPath("folder", "chmod 666.txt")) == m666);
    }

    assert(hexDigest!SHA1(read(
            dm.buildPath("file1.txt"))) == "38505A984F71C07843A5F3E394ADA2BF4C7B6ABC");
    assert(hexDigest!SHA1(read(
            dm.buildPath("file 2.txt"))) == "01FA4C5C29A58449EEF1665658C48C0D7829C45F");
    assert(hexDigest!SHA1(read(dm.buildPath("folder", "chmod 666.txt"))) == "3E31B8E6B2BBBA1EDFCFDCA886E246C9E120BBE3");
}

@("Create Tar")
unittest
{
    import std.algorithm : map, sum;
    import std.file : read;

    auto archive = Path("archive", ".tar");
    auto base = dataGenPath();

    filesForArchive()
        .map!(p => fileEntryFromBase(p, base))
        .createTarArchive()
        .writeBinaryFile(archive.path);

    testTarArchiveContent(archive.path);

    enum expectedLen = 2 * 512 + 512 + 3584 + 2 * 512 + 2 * 512;
    auto content = cast(const(ubyte)[]) read(archive.path);
    assert(content.length == expectedLen);
    assert(content[$ - 1024 .. $].sum() == 0);
}

@("Read Tar")
unittest
{
    import std.algorithm : equal, map;
    import std.array : array;
    import std.conv : octal;
    import std.digest.sha : SHA1;
    import std.digest : hexDigest;
    import std.stdio : File;

    const path = testPath("data/archive.tar");

    struct Entry
    {
        string path;
        uint attributes;
        size_t size;
        char[40] sha1;
    }

    version (Posix)
    {
        const attr644 = octal!"100644";
        const attr666 = octal!"100666";
    }
    else
    {
        const attr644 = 0;
        const attr666 = 0;
    }

    const expectedEntries = [
        Entry("file1.txt", attr644, 7, "38505A984F71C07843A5F3E394ADA2BF4C7B6ABC"),
        Entry("file 2.txt", attr644, 3521, "01FA4C5C29A58449EEF1665658C48C0D7829C45F"),
        Entry("folder/chmod 666.txt", attr666, 26, "3E31B8E6B2BBBA1EDFCFDCA886E246C9E120BBE3"),
    ];

    const readEntries = File(path, "rb")
        .byChunk(defaultChunkSize)
        .readTarArchive()
        .map!((entry) {
            const content = entry.readContent();
            return Entry(
                entry.path,
                entry.attributes,
                entry.size,
                hexDigest!SHA1(content)
            );
        })
        .array;

    assert(readEntries.equal(expectedEntries));
}

@("Extract Tar")
unittest
{
    import std.algorithm : each;
    import std.file : mkdir;

    const archive = testPath("data/archive.tar");
    const dm = DeleteMe("extraction_site", null);

    mkdir(dm.path);

    readBinaryFile(archive)
        .readTarArchive()
        .each!(e => e.extractTo(dm.path));

    testExtractedFiles(dm, Yes.mode666);
}

@("Decompress and extract tar.gz")
unittest
{
    import std.algorithm : each;
    import std.file : mkdir;

    const archive = testPath("data/archive.tar.gz");
    const dm = DeleteMe("extraction_site", null);

    mkdir(dm.path);

    readBinaryFile(archive)
        .decompressGz()
        .readTarArchive()
        .each!(e => e.extractTo(dm.path));

    testExtractedFiles(dm, Yes.mode666);
}

@("Decompress and extract tar.bz2")
unittest
{
    import std.algorithm : each;
    import std.file : mkdir;

    const archive = testPath("data/archive.tar.bz2");
    const dm = DeleteMe("extraction_site", null);

    mkdir(dm.path);

    readBinaryFile(archive)
        .decompressBz2()
        .readTarArchive()
        .each!(e => e.extractTo(dm.path));

    testExtractedFiles(dm, Yes.mode666);
}

@("Decompress and extract tar.xz")
unittest
{
    import std.algorithm : each;
    import std.file : mkdir;

    const archive = testPath("data/archive.tar.xz");
    const dm = DeleteMe("extraction_site", null);

    mkdir(dm.path);

    readBinaryFile(archive)
        .decompressXz()
        .readTarArchive()
        .each!(e => e.extractTo(dm.path));

    testExtractedFiles(dm, Yes.mode666);
}

@("Create Zip")
unittest
{
    import std.algorithm : map, sum;
    import std.file : read;

    auto archive = DeleteMe("archive", ".zip");
    auto base = dataGenPath();

    filesForArchive()
        .map!(p => fileEntryFromBase(p, base))
        .createZipArchive()
        .writeBinaryFile(archive.path);

    testZipArchiveContent(archive.path);
}

@("Extract Zip")
unittest
{
    import std.algorithm : each;
    import std.file : mkdir;

    const archive = testPath("data/archive.zip");
    const dm = DeleteMe("extraction_site", null);

    mkdir(dm.path);

    readBinaryFile(archive)
        .readZipArchive()
        .each!(e => e.extractTo(dm.path));

    testExtractedFiles(dm, No.mode666);
}

@("Extract Zip squiz-box extra-flags")
unittest
{
    import std.algorithm : each, map;
    import std.file : mkdir;

    const dm = DeleteMe("extraction_site", null);
    auto base = dataGenPath();

    mkdir(dm.path);

    filesForArchive()
        .map!(p => fileEntryFromBase(p, base))
        .createZipArchive()
        .readZipArchive()
        .each!(e => e.extractTo(dm.path));

    testExtractedFiles(dm, Yes.mode666);
}
