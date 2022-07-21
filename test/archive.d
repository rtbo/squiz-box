module test.archive;

import test.util;
import squiz_box;

import std.typecons;
import std.digest;
import std.digest.sha;

string[] filesForArchive()
{
    return [
        dataGenPath("file1.txt"),
        dataGenPath("file 2.txt"),
        dataGenPath("folder/chmod 666.txt"),
    ];
}

void testTarArchiveContent(string archivePath, Flag!"testModes" testModes, Flag!"mode666" mode666)
{
    import std.algorithm : canFind;
    import std.path : buildNormalizedPath;
    import std.process : execute;
    import std.regex : matchFirst;
    import std.string : splitLines;

    if (testModes)
    {
        const line1 = `^-rw-r--r-- .+ 7 .+ file1.txt$`;
        const line2 = `^-rw-r--r-- .+ 3521 .+ file 2.txt$`;
        const line3 = mode666 ?
            `^-rw-rw-rw- .+ 26 .+ folder.+chmod 666.txt$`
            : `^-rw-r--r-- .+ 26 .+ folder.+chmod 666.txt$`;

        auto res = execute(["tar", "-tvf", archivePath]);
        assert(res.status == 0);
        const lines = res.output.splitLines();
        assert(lines.length == 3);
        assert(matchFirst(lines[0], line1));
        assert(matchFirst(lines[1], line2));
        assert(matchFirst(lines[2], line3));
    }

    auto sha1sumFile(string filename)
    {
        return sha1sumProcessStdout(["tar", "-xOf", archivePath, filename]);
    }

    auto sha1 = sha1sumFile("file1.txt");
    assert(sha1 == "38505A984F71C07843A5F3E394ADA2BF4C7B6ABC");

    sha1 = sha1sumFile("file 2.txt");
    assert(sha1 == "01FA4C5C29A58449EEF1665658C48C0D7829C45F");

    try
    {
        sha1 = sha1sumFile("folder/chmod 666.txt");
    }
    catch (Exception)
    {
        sha1 = sha1sumFile("folder\\\\chmod 666.txt"); // windows tar is a weirdo
    }
    assert(sha1 == "3E31B8E6B2BBBA1EDFCFDCA886E246C9E120BBE3");
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

    auto archive = DeleteMe("archive", ".tar");
    auto base = dataGenPath();

    filesForArchive()
        .map!(p => fileEntry(p, base))
        .boxTar()
        .writeBinaryFile(archive.path);

    version (Windows)
        enum m666 = No.mode666;
    else
        enum m666 = Yes.mode666;

    testTarArchiveContent(archive.path, Yes.testModes, m666);

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
        .unboxTar()
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
        .unboxTar()
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
        .inflateGz()
        .unboxTar()
        .each!(e => e.extractTo(dm.path));

    testExtractedFiles(dm, Yes.mode666);
}

version (HaveSquizBzip2)
{
    @("Decompress and extract tar.bz2")
    unittest
    {
        import std.algorithm : each;
        import std.file : mkdir;

        const archive = testPath("data/archive.tar.bz2");
        const dm = DeleteMe("extraction_site", null);

        mkdir(dm.path);

        readBinaryFile(archive)
            .decompressBzip2()
            .unboxTar()
            .each!(e => e.extractTo(dm.path));

        testExtractedFiles(dm, Yes.mode666);
    }
}

version (HaveSquizLzma)
{
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
            .unboxTar()
            .each!(e => e.extractTo(dm.path));

        testExtractedFiles(dm, Yes.mode666);
    }
}

@("Create Zip")
unittest
{
    import std.algorithm : map, sum;
    import std.file : read;

    auto archive = DeleteMe("archive", ".zip");
    auto base = dataGenPath();

    filesForArchive()
        .map!(p => fileEntry(p, base))
        .boxZip()
        .writeBinaryFile(archive.path);

    version (Windows)
        testTarArchiveContent(archive.path, No.testModes, No.mode666);
    else
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
        .unboxZip()
        .each!(e => e.extractTo(dm.path));

    testExtractedFiles(dm, No.mode666);
}

@("Extract Zip Searchable stream")
unittest
{
    import std.array : array;
    import std.file : mkdir;
    import std.stdio : File;

    const archive = testPath("data/archive.zip");
    const dm = DeleteMe("extraction_site", null);

    mkdir(dm.path);

    auto entries = File(archive, "rb")
        .unboxZip()
        .array;

    entries[2].extractTo(dm.path);
    entries[1].extractTo(dm.path);
    entries[0].extractTo(dm.path);

    testExtractedFiles(dm, Yes.mode666);
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
        .map!(p => fileEntry(p, base))
        .boxZip()
        .unboxZip()
        .each!(e => e.extractTo(dm.path));

    testExtractedFiles(dm, Yes.mode666);
}

@("BoxAlgo.box")
unittest
{
    import std.algorithm : map;
    import std.range : inputRangeObject;

    const dm = DeleteMe("dest", ".zip");
    auto base = dataGenPath();

    auto algo = BoxAlgo.forFilename(dm.path);

    algo.box(filesForArchive().map!(p => fileEntry(p, base)))
        .writeBinaryFile(dm.path);

    testZipArchiveContent(dm.path);
}

version (HaveSquizLzma)
{
    @("BoxAlgo.unbox")
    unittest
    {
        import std.algorithm : each;
        import std.file : mkdir;
        import std.range : inputRangeObject;

        const archive = testPath("data/archive.tar.xz");
        const dm = DeleteMe("extraction_site", null);

        mkdir(dm.path);

        auto algo = BoxAlgo.forFilename(archive);
        auto entries = algo.unbox(readBinaryFile(archive));
        entries.each!(e => e.extractTo(dm.path));

        testExtractedFiles(dm, Yes.mode666);
    }
}
