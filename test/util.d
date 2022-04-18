module test.util;

import std.file;
import std.path;
import std.string;

string testPath(Args...)(Args args)
{
    return buildNormalizedPath(dirName(__FILE_FULL_PATH__), args);
}

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
}

/// Generate a unique name for temporary path (either dir or file)
/// Params:
///     location = some directory to place the file in. If omitted, std.file.tempDir is used
///     prefix = prefix to give to the base name
///     ext = optional extension to append to the path (must contain '.')
/// Returns: a path (i.e. location/prefix-{uniquestring}.ext)
string tempPath(string location = null, string prefix = null, string ext = null)
in (!location || (exists(location) && isDir(location)))
in (!ext || ext.startsWith('.'))
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
