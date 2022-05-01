module test.compress;

import test.archive;
import test.util;
import squiz_box.bz2;
import squiz_box.core;
import squiz_box.gz;
import squiz_box.xz;


@("Compress GZ tar")
unittest
{
    import std.algorithm : copy;
    import std.stdio : File;

    auto archive = DeleteMe("archive", ".tar.gz");

    auto tarF = File(testPath("data/archive.tar"), "rb");
    auto tarXzF = File(archive.path, "wb");

    enum bufSize = 8192;

    tarF.byChunk(bufSize)
        .compressGz(6, bufSize)
        .copy(tarXzF.lockingBinaryWriter);

    tarF.close();
    tarXzF.close();

    testTarArchiveContent(archive.path);
}

@("Compress GZ sequential")
unittest
{
    import std.algorithm : filter;
    import std.digest.sha : SHA1;

    auto dataGz = DeleteMe("data", ".gz");

    const len = 1000 * 1000;

    testCompressData!({
        SHA1 sha;
        bool sha1(ubyte[] bytes)
        {
            sha.put(bytes);
            return true;
        }
        generateSequentialData(len, 1239, 13, 8192)
            .filter!sha1
            .compressGz(6, 8192)
            .writeBinaryFile(dataGz.path);

        return sha.finish();
    })(len, dataGz.path, "compressGz", "sequential", "gzip");
}

@("Compress GZ repetitive")
unittest
{
    import std.algorithm : filter;
    import std.digest.sha : SHA1;

    auto dataGz = DeleteMe("data", ".gz");

    const phrase = cast(const(ubyte)[])"Some very repetitive phrase.";
    const len = 100*1000*1000;

    testCompressData!({
        SHA1 sha;
        bool sha1(ubyte[] bytes)
        {
            sha.put(bytes);
            return true;
        }
        generateRepetitiveData(len, phrase, 8192)
            .filter!sha1
            .compressGz(6, 8192)
            .writeBinaryFile(dataGz.path);

        return sha.finish();
    })(len, dataGz.path, "compressGz", "repetitive", "gzip");
}

@("Compress Bz2 tar")
unittest
{
    import std.algorithm : copy;
    import std.stdio : File;

    auto archive = DeleteMe("archive", ".tar.bz2");

    auto tarF = File(testPath("data/archive.tar"), "rb");

    enum bufSize = 8192;

    tarF.byChunk(bufSize)
        .compressBz2(bufSize)
        .writeBinaryFile(archive.path);

    tarF.close();

    testTarArchiveContent(archive.path);
}

@("Compress Bz2 sequential")
unittest
{
    import std.algorithm : filter;
    import std.digest.sha : SHA1;

    auto dm = DeleteMe("data", ".bz2");

    const len = 1000 * 1000;

    testCompressData!({
        SHA1 sha;
        bool sha1(ubyte[] bytes)
        {
            sha.put(bytes);
            return true;
        }
        generateSequentialData(len, 1239, 13, 8192)
            .filter!sha1
            .compressBz2(8192)
            .writeBinaryFile(dm.path);

        return sha.finish();
    })(len, dm.path, "compressBz2", "sequential", "bzip2");
}

@("Compress Bzip2 repetitive")
unittest
{
    // Bzip2 is really inefficient with repetitive data, so I lower the volume for this one
    import std.algorithm : filter;
    import std.digest.sha : SHA1;

    auto dm = DeleteMe("data", ".bz2");

    const phrase = cast(const(ubyte)[])"Some very repetitive phrase.";
    const len = 5*1000*1000;

    generateRepetitiveData(len, phrase, 8192)
        .writeBinaryFile("data");

    testCompressData!({
        SHA1 sha;
        bool sha1(ubyte[] bytes)
        {
            sha.put(bytes);
            return true;
        }
        generateRepetitiveData(len, phrase, 8192)
            .filter!sha1
            .compressBz2(8192)
            .writeBinaryFile(dm.path);

        return sha.finish();
    })(len, dm.path, "compressBz2", "repetitive", "bzip2");
}


@("Compress XZ tar")
unittest
{
    import std.algorithm : copy;
    import std.stdio : File;

    auto archive = DeleteMe("archive", ".tar.xz");

    auto tarF = File(testPath("data/archive.tar"), "rb");
    auto tarXzF = File(archive.path, "wb");

    enum bufSize = 8192;

    tarF.byChunk(bufSize)
        .compressXz(6, bufSize)
        .copy(tarXzF.lockingBinaryWriter);

    tarF.close();
    tarXzF.close();

    testTarArchiveContent(archive.path);
}

@("Compress XZ sequential")
unittest
{
    import std.algorithm : filter;
    import std.digest.sha : SHA1;

    auto dataXz = DeleteMe("data", ".xz");

    const len = 1000 * 1000;

    testCompressData!({
        SHA1 sha;
        bool sha1(ubyte[] bytes)
        {
            sha.put(bytes);
            return true;
        }
        generateSequentialData(len, 1239, 13, 8192)
            .filter!sha1
            .compressXz(6, 8192)
            .writeBinaryFile(dataXz.path);

        return sha.finish();
    })(len, dataXz.path, "compressXz", "sequential", "xz");
}

@("Compress XZ repetitive")
unittest
{
    import std.algorithm : filter;
    import std.digest.sha : SHA1;

    auto dataXz = DeleteMe("data", ".xz");

    const phrase = cast(const(ubyte)[])"Some very repetitive phrase.";
    const len = 100*1000*1000;

    testCompressData!({
        SHA1 sha;
        bool sha1(ubyte[] bytes)
        {
            sha.put(bytes);
            return true;
        }
        generateRepetitiveData(len, phrase, 8192)
            .filter!sha1
            .compressXz(6, 8192)
            .writeBinaryFile(dataXz.path);

        return sha.finish();
    })(len, dataXz.path, "compressXz", "repetitive", "xz");
}

private void testCompressData(alias fun)(size_t len, string filename, string algo, string datatype, string utility)
{
    import std.algorithm : canFind;
    import std.datetime.stopwatch;
    import std.digest : toHexString, LetterCase;
    import std.file : getSize;
    import std.process : executeShell, escapeShellFileName;
    import std.stdio : File, writefln;


    StopWatch sw;
    sw.start();

    const sha1 = fun();

    sw.stop();
    const time = sw.peek;

    const sum = toHexString!(LetterCase.lower)(sha1)[].idup;

    const fileShell = escapeShellFileName(filename);
    const res = executeShell(utility ~ " -d --stdout " ~ fileShell ~ " | sha1sum");

    assert(res.status == 0);
    assert(
        res.output.canFind(sum),
        "checksum failed for " ~ algo ~ " " ~ datatype ~ "\n" ~
        "before algo: " ~ sum ~ "\n" ~
        "after algo: " ~ res.output
    );

    const compressedSz = getSize(filename);
    double ratio = compressedSz / cast(double)len;

    writefln("%s of %sMb of %s data took %s ms", algo, len / (1000*1000), datatype, time.total!"msecs");
    writefln("    compressed size = %.1fKb (compression ratio = %s)", compressedSz / 1000.0, ratio);
}
