module test.util;

import squiz_box;

import std.digest;
import std.digest.sha;
import std.file;
import std.random;
import std.path;
import std.string;

private __gshared string _dataGenPath;

shared static this()
{
    import std.range;

    _dataGenPath = tempPath(null, "squiz-box-test", null);
    mkdir(_dataGenPath);
    mkdir(dataGenPath("folder"));

    const ubyte[] content1 = cast(const(ubyte[])) "File 1\n";
    const ubyte[] content2 = cast(const(ubyte[])) "file 2\n";
    const ubyte[] content3 = cast(const(ubyte[])) "File with 666 permissions\n";

    write(dataGenPath("file1.txt"), cast(const(void)[]) content1);
    repeat(content2).take(503).writeBinaryFile(dataGenPath("file 2.txt"));
    write(dataGenPath("folder", "chmod 666.txt"), cast(const(void)[]) content3);

    version (Posix)
    {
        import std.process;

        execute(["chmod", "644", dataGenPath("file1.txt")]);
        execute(["chmod", "644", dataGenPath("file 2.txt")]);
        execute(["chmod", "666", dataGenPath("folder", "chmod 666.txt")]);
    }
}

shared static ~this()
{
    rmdirRecurse(_dataGenPath);
}

string dataGenPath(Args...)(Args args)
{
    return buildNormalizedPath(_dataGenPath, args);
}

string testPath(Args...)(Args args)
{
    return buildNormalizedPath(__FILE_FULL_PATH__.dirName(), args);
}

/// Find a program executable name in the system PATH and return its full path
string findProgram(in string name)
{
    import std.process : environment;

    version (Windows)
    {
        import std.algorithm : endsWith;

        const efn = name.endsWith(".exe") ? name : name ~ ".exe";
    }
    else
    {
        const efn = name;
    }

    return searchInEnvPath(environment["PATH"], efn);
}

/// environment variable path separator
version (Posix)
    enum envPathSep = ':';
else version (Windows)
    enum envPathSep = ';';
else
    static assert(false);

/// Search for filename in the envPath variable content which can
/// contain multiple paths separated with sep depending on platform.
/// Returns: null if the file can't be found.
string searchInEnvPath(in string envPath, in string filename, in char sep = envPathSep)
{
    import std.algorithm : splitter;
    import std.file : exists;
    import std.path : buildPath;

    foreach (dir; splitter(envPath, sep))
    {
        const filePath = buildPath(dir, filename);
        if (exists(filePath))
            return filePath;
    }
    return null;
}

/// Defines a path in a temporary location
/// and delete the file or directory (recursively) at that path when going out of scope.
struct DeleteMe
{
    string path;

    this(string basename, string ext)
    {
        path = tempPath(null, basename, ext);
    }

    ~this()
    {
        import std.file : exists, isDir, remove, rmdirRecurse;

        if (exists(path))
        {
            if (isDir(path))
                rmdirRecurse(path);
            else
                remove(path);
        }
    }

    string buildPath(Args...)(Args args) const
    {
        import std.path : buildPath;

        return buildPath(path, args);
    }
}

// used in place of DeleteMe if needed to inspect the file after the test
struct DontDeleteMe
{
    this(string basename, string ext)
    {
        path = basename ~ ext;
    }

    string buildPath(Args...)(Args args) const
    {
        import std.path : buildPath;

        return buildPath(path, args);
    }

    string path;
}

/// start a process and return sha1sum of stdout
string sha1sumProcessStdout(string[] args)
{
    import std.algorithm : each;
    import std.exception : enforce;
    import std.process : pipeProcess, Redirect, wait;

    auto pipes = pipeProcess(args, Redirect.stdout);
    scope (exit)
    {
        enforce(wait(pipes.pid) == 0);
    }

    auto sha1 = makeDigest!SHA1();
    pipes
        .stdout
        .byChunk(4096)
        .each!(chunk => sha1.put(chunk));

    const hash = sha1.finish();
    return toHexString(hash[]);
}

/// Return a byte range that generates potentially very large amount of binary data.
/// The data contains _num_ bytes in the form of 64 bits integers,
/// starting at _start_ and stepping by _step_.
/// Both num and chunkSize must be a multiple of 8 byte
auto generateSequentialData(size_t num, long start, long step, size_t chunkSize = 8192)
{
    assert(num % 8 == 0);
    assert(chunkSize % 8 == 0);
    return SequentialDataGen(num, start, step, chunkSize);
}

private struct SequentialDataGen
{
    size_t num;
    long current;
    long step;
    long[] buffer;
    long[] chunk;

    size_t processed;
    size_t nextProcess;
    enum processStep = 1000 * 1000;

    this(size_t num, long start, long step, size_t chunkSize)
    {
        this.num = num;
        this.current = start;
        this.step = step;
        this.buffer = new long[chunkSize / 8];
        nextProcess = processStep;
        popFront();
    }

    @property bool empty()
    {
        return chunk.length == 0;
    }

    @property ByteChunk front()
    {
        return cast(ByteChunk) chunk;
    }

    void popFront()
    {
        import std.algorithm : min;

        const len = min(num / 8, buffer.length);
        if (len == 0)
        {
            chunk = null;
            return;
        }

        foreach (ref b; buffer[0 .. len])
        {
            b = current;
            current += step;
        }

        num -= len * 8;
        chunk = buffer[0 .. len];

        processed += chunk.length * 8;
        if (processed > nextProcess)
        {
            nextProcess += processStep;
        }
    }
}

static assert(isByteRange!SequentialDataGen);

@("generateSequentialData")
unittest
{
    import std.file : getSize;

    auto dm = DeleteMe("large", ".data");

    const size_t len = 1_203_960;

    generateSequentialData(len, 1403, 127)
        .writeBinaryFile(dm.path);

    assert(getSize(dm.path) == len);
}

/// Generate potentially large but repetitive data constituted of the same phrase repeated
/// over and over until byteSize is written out.
auto generateRepetitiveData(size_t byteSize, const(ubyte)[] phrase, size_t chunkSize = 8192)
{
    return RepetitiveDataGen(byteSize, phrase, chunkSize);
}

private struct RepetitiveDataGen
{
    size_t remaining;
    const(ubyte)[] phrase;
    size_t nextC;
    ubyte[] buffer;
    ubyte[] chunk;

    this(size_t byteSize, const(ubyte)[] phrase, size_t chunkSize)
    {
        remaining = byteSize;
        this.phrase = phrase;
        buffer = new ubyte[chunkSize];
        prime();
    }

    @property bool empty()
    {
        return chunk.length == 0;
    }

    @property ByteChunk front()
    {
        return chunk;
    }

    private void prime()
    {
        import std.algorithm : min;

        while (chunk.length < buffer.length && remaining > 0)
        {
            const toBeWritten = phrase[nextC .. $];
            const bufStart = chunk.length;
            const len = min(toBeWritten.length, buffer.length - bufStart, remaining);
            buffer[bufStart .. bufStart + len] = toBeWritten[0 .. len];
            chunk = buffer[0 .. bufStart + len];
            nextC += len;
            if (nextC >= phrase.length)
                nextC = 0;
            remaining -= len;
        }
    }

    void popFront()
    {
        chunk = null;
        prime();
    }
}

static assert(isByteRange!RepetitiveDataGen);

@("generateRepetitiveData")
unittest
{
    import std.file : getSize;

    auto dm = DeleteMe("repetitive", ".data");

    const size_t len = 3_201_528;
    const phrase = cast(const(ubyte)[]) "Some phrase to be repeated over and over.";

    generateRepetitiveData(len, phrase)
        .writeBinaryFile(dm.path);

    assert(getSize(dm.path) == len);
}

/// Generate potentially very large amount of binary random data until byteSize is written out
auto generateRandomData(size_t byteSize, uint seed = unpredictableSeed(), size_t chunkSize = 8192)
{
    auto eng = Random(seed);
    return RandomDataGen(byteSize, eng, chunkSize);
}

private struct RandomDataGen
{
    size_t remaining;
    Random eng;
    ubyte[] buffer;
    ubyte[] chunk;

    this(size_t byteSize, Random eng, size_t chunkSize)
    {
        remaining = byteSize;
        this.eng = eng;
        buffer = new ubyte[chunkSize];
        prime();
    }

    @property bool empty()
    {
        return chunk.length == 0;
    }

    @property ByteChunk front()
    {
        return chunk;
    }

    private void prime()
    {
        import std.algorithm : min;

        while (chunk.length < buffer.length && remaining > 0)
        {
            const uint irnd = eng.front();
            eng.popFront();
            const ubyte[4] rnd = (cast(const(ubyte)*)&irnd)[0 .. 4];
            const bufStart = chunk.length;
            const len = min(4, buffer.length - bufStart, remaining);
            buffer[bufStart .. bufStart + len] = rnd[0 .. len];
            chunk = buffer[0 .. bufStart + len];
            remaining -= len;
        }
    }

    void popFront()
    {
        chunk = null;
        prime();
    }
}

static assert(isByteRange!RandomDataGen);

// @("bench CRC32")
// unittest
// {
//     import squiz_box.c.zlib;
//     import std.digest.crc : crc32Of;
//     import std.datetime.stopwatch : benchmark;
//     import std.stdio : writefln;

//     const sz = 1024 * 1024;
//     const ubyte[] data = generateRandomData(sz).join();

//     const ubyte[4] phobosResult = crc32Of(data);

//     const uint zlibIRes = squiz_box.c.zlib.crc32(0, &data[0], sz);
//     const ubyte[4] zlibResult = (cast(const(ubyte)*)&zlibIRes)[0 .. 4];
//     assert(cast(ubyte[4]) zlibResult == phobosResult);

//     void zlibRun()
//     {
//         cast(void) squiz_box.c.zlib.crc32(0, &data[0], sz);
//     }

//     version (HaveSquizLzma)
//     {
//         import squiz_box.c.lzma;

//         const uint lzmaIRes = lzma_crc32(&data[0], sz, 0);
//         const ubyte[4] lzmaResult = (cast(const(ubyte)*)&lzmaIRes)[0 .. 4];

//         void lzmaRun()
//         {
//             cast(void)lzma_crc32(&data[0], sz, 0);
//         }
//     }

//     void phobosRun()
//     {
//         cast(void) crc32Of(data);
//     }


//     version (HaveSquizLzma)
//     {
//         auto res = benchmark!(phobosRun, zlibRun, lzmaRun)(100);
//     }
//     else
//     {
//         auto res = benchmark!(phobosRun, zlibRun)(100);
//     }

//     writefln!"phobos crc32 took %s µs"(res[0].total!"usecs");
//     writefln!"zlib   crc32 took %s µs"(res[1].total!"usecs");
//     version (HaveSquizLzma)
//     {
//         writefln!"lzma   crc32 took %s µs"(res[2].total!"usecs");
//     }
// }

/// Generate a unique name for temporary path (either dir or file)
/// Params:
///     location = some directory to place the file in. If omitted, std.file.tempDir is used
///     prefix = prefix to give to the base name
///     ext = optional extension to append to the path (must contain '.')
/// Returns: a path (i.e. location/prefix-{uniquestring}.ext)
string tempPath(string location = null, string prefix = null, string ext = null)
in (!location || (exists(location) && isDir(location)))
in (!ext.length || ext.startsWith('.'))
out (res; (!location || res.startsWith(location)) && !exists(res))
{
    import std.array : array;
    import std.path : buildPath;
    import std.random : Random, unpredictableSeed, uniform;
    import std.range : generate, only, takeExactly;

    auto rnd = Random(unpredictableSeed);

    if (prefix)
        prefix ~= "-";

    if (!location)
        location = tempDir;

    string res;
    do
    {
        const basename = prefix ~ generate!(() => uniform!("[]")('a', 'z',
                rnd)).takeExactly(10).array ~ ext;

        res = buildPath(location, basename);
    }
    while (exists(res));

    return res;
}

size_t binDiff(const(void)[] content1, const(void)[] content2)
{
    auto bytes1 = cast(const(ubyte)[]) content1;
    auto bytes2 = cast(const(ubyte)[]) content2;
    for (size_t i; i < bytes1.length; ++i)
    {
        if (bytes2.length <= i)
            return i;
        if (bytes1[i] != bytes2[i])
        return i;
    }
    if (bytes2.length > bytes1.length)
        return bytes1.length;

    return size_t.max;
}
