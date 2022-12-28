module test.compress;

import test.archive;
import test.util;
import squiz_box;

import std.range;
import std.string;
import std.typecons;

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
        .deflateGz(bufSize)
        .copy(tarXzF.lockingBinaryWriter);

    tarF.close();
    tarXzF.close();

    testTarArchiveContent(archive.path, Yes.testModes, Yes.mode666);
}

@("Compress GZ sequential")
unittest
{
    import std.algorithm : filter;
    import std.digest.sha : SHA1;

    auto dataGz = DeleteMe("data", ".gz");

    const len = 10_000;

    testCompressData!({
        SHA1 sha;
        bool sha1(ByteChunk bytes)
        {
            sha.put(bytes);
            return true;
        }

        generateSequentialData(len, 1239, 13, 8192)
            .filter!sha1
            .deflateGz(8192)
            .writeBinaryFile(dataGz.path);

        return sha.finish();
    })(len, dataGz.path, "compressGz", "sequential", "gzip");
}

@("Compress GZ with reuse")
unittest
{
    auto dataGz = DeleteMe("data", ".gz");

    const len = 10_000;

    Deflate algo;
    algo.format = ZlibFormat.gz;

    auto state = algo.initialize();
    auto buffer = new ubyte[defaultChunkSize];

    generateSequentialData(len, 1239, 13, 8192)
        .squizReuse(algo, state, buffer)
        .writeBinaryFile(dataGz.path);

    algo.reset(state);

    generateSequentialData(len, 1239, 13, 8192)
        .squizReuse(algo, state, buffer)
        .writeBinaryFile(dataGz.path);

    algo.end(state);
}

@("Gz header")
unittest
{

}

@("Compress GZ repetitive")
unittest
{
    import std.algorithm : filter;
    import std.digest.sha : SHA1;

    auto dataGz = DeleteMe("data", ".gz");

    const phrase = cast(const(ubyte)[]) "Some very repetitive phrase.";
    const len = 1000 * 1000;

    testCompressData!({
        SHA1 sha;
        bool sha1(ByteChunk bytes)
        {
            sha.put(bytes);
            return true;
        }

        generateRepetitiveData(len, phrase, 8192)
            .filter!sha1
            .deflateGz(8192)
            .writeBinaryFile(dataGz.path);

        return sha.finish();
    })(len, dataGz.path, "compressGz", "repetitive", "gzip");
}

version (HaveSquizBzip2)
{
    @("Compress Bz2 tar")
    unittest
    {
        import std.algorithm : copy;
        import std.stdio : File;

        auto archive = DeleteMe("archive", ".tar.bz2");

        auto tarF = File(testPath("data/archive.tar"), "rb");

        enum bufSize = 8192;

        tarF.byChunk(bufSize)
            .compressBzip2(bufSize)
            .writeBinaryFile(archive.path);

        tarF.close();

        // windows do not have bzip2
        // deactivating for now
        version (Posix)
            testTarArchiveContent(archive.path, Yes.testModes, Yes.mode666);
    }

    @("Compress Bz2 sequential")
    unittest
    {
        import std.algorithm : filter;
        import std.digest.sha : SHA1;

        auto dm = DeleteMe("data", ".bz2");

        const len = 10_000;

        testCompressData!({
            SHA1 sha;
            bool sha1(ByteChunk bytes)
            {
                sha.put(bytes);
                return true;
            }

            generateSequentialData(len, 1239, 13, 8192)
                .filter!sha1
                .compressBzip2(8192)
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

        const phrase = cast(const(ubyte)[]) "Some very repetitive phrase.";
        const len = 1000 * 1000;

        testCompressData!({
            SHA1 sha;
            bool sha1(ByteChunk bytes)
            {
                sha.put(bytes);
                return true;
            }

            generateRepetitiveData(len, phrase, 8192)
                .filter!sha1
                .compressBzip2(8192)
                .writeBinaryFile(dm.path);

            return sha.finish();
        })(len, dm.path, "compressBz2", "repetitive", "bzip2");
    }
}

version (HaveSquizLzma)
{
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
            .compressXz(bufSize)
            .copy(tarXzF.lockingBinaryWriter);

        tarF.close();
        tarXzF.close();

        // windows do not have xz
        // deactivating for now
        version (Posix)
            testTarArchiveContent(archive.path, Yes.testModes, Yes.mode666);
    }

    @("Compress XZ sequential")
    unittest
    {
        import std.algorithm : filter;
        import std.digest.sha : SHA1;

        auto dataXz = DeleteMe("data", ".xz");

        const len = 10_000;

        testCompressData!({
            SHA1 sha;
            bool sha1(ByteChunk bytes)
            {
                sha.put(bytes);
                return true;
            }

            generateSequentialData(len, 1239, 13, 8192)
                .filter!sha1
                .compressXz(8192)
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

        const phrase = cast(const(ubyte)[]) "Some very repetitive phrase.";
        const len = 1000 * 1000;

        testCompressData!({
            SHA1 sha;
            bool sha1(ByteChunk bytes)
            {
                sha.put(bytes);
                return true;
            }

            generateRepetitiveData(len, phrase, 8192)
                .filter!sha1
                .compressXz(8192)
                .writeBinaryFile(dataXz.path);

            return sha.finish();
        })(len, dataXz.path, "compressXz", "repetitive", "xz");
    }
}

private void testCompressData(alias fun)(size_t len, string filename, string algo, string datatype, string utility)
{
    import std.algorithm : canFind;

    // import std.datetime.stopwatch;
    import std.digest : toHexString, LetterCase;
    import std.file : getSize;
    import std.process : executeShell, escapeShellFileName;
    import std.stdio : File, writefln;

    // StopWatch sw;
    // sw.start();

    const sha1 = fun();

    // sw.stop();
    // const time = sw.peek;

    // windows do not have bzip2 and xz
    // deactivating for now
    version (Windows)
        const test = utility != "bzip2" && utility != "xz";
    else
        const test = true;

    if (test)
    {
        const expectedSum = toHexString(sha1)[].idup;
        const sum = sha1sumProcessStdout([utility, "-d", "--stdout", filename]);
        assert(sum == expectedSum);
    }

    // const compressedSz = getSize(filename);
    // double ratio = compressedSz / cast(double)len;

    // writefln("%s of %sMb of %s data took %s ms", algo, len / (1000*1000), datatype, time.total!"msecs");
    // writefln("    compressed size = %.1fKb (compression ratio = %s)", compressedSz / 1000.0, ratio);
}

@("test compound squiz")
unittest
{
    const phrase = "Some phrase to be repeated over and over.\n".representation;
    const data = generateRepetitiveData(1024 * 1024, phrase).join();

    auto algos = [
        squizAlgo(Deflate.init), squizAlgo(Inflate.init)
    ];

    auto identity = squizCompoundAlgo(algos);

    auto dataOut = only(data).squiz(identity).join();

    assert(data == dataOut);
}
