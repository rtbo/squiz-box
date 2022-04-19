module squiz_box.tar;

import squiz_box.core;

import std.datetime.systime;
import std.exception;
import std.path;
import std.range.interfaces;

struct ArchiveTar
{
    static ArchiveTarCreate createWithFiles(F)(F files, string baseDir = null)
    {
        auto entries = makeEntries(files, baseDir);
        return ArchiveTarCreate(entries);
    }

    private static ArchiveEntry[] makeEntries(F)(F files, string baseDir)
    {
        import std.file : getcwd;

        string base = baseDir ? baseDir : getcwd();

        ArchiveEntry[] entries;
        foreach (f; files)
        {
            string archivePath = absolutePath(f);
            archivePath = relativePath(archivePath, base);
            archivePath = buildNormalizedPath(archivePath);
            entries ~= new ArchiveEntryFile(f, archivePath);
        }
        return entries;
    }

    static ArchiveTarRead readFromPath(string archivePath)
    {
        return ArchiveTarRead(archivePath);
    }
}

struct ArchiveTarCreate
{
    private ArchiveEntry[] entries;

    auto byChunk(size_t chunkSz = 4096)
    in (chunkSz % 512 == 0, "chunk size must be a multiple of 512")
    {
        return ArchiveTarCreateByChunk(chunkSz, entries);
    }

    void writeToFile(string archiveFilePath)
    {
        import std.stdio : File;

        auto f = File(archiveFilePath, "wb");
        foreach (chunk; byChunk())
        {
            f.rawWrite(chunk);
        }
        f.close();
    }
}

struct ArchiveTarRead
{
    private string archivePath;

    this(string archivePath)
    {
        import std.file : exists, isFile;

        enforce(
            exists(archivePath) && isFile(archivePath),
            archivePath ~ ": No such file",
        );

        this.archivePath = archivePath;
    }

    @property auto entries()
    {
        import std.stdio : File;

        return ArchiveTarReadEntries(File(archivePath, "rb"));
    }

    void extractTo(string directory)
    {
        import std.file : exists, isDir, mkdirRecurse, setTimes, symlink, timeLastAccessed;
        import std.path : buildNormalizedPath, dirName;
        import std.stdio : File;

        enforce(exists(directory) && isDir(directory));

        foreach(entry; entries)
        {
            enforce(
                !entry.isBomb,
                "TAR bomb detected! Extraction aborted (entry will extract to " ~
                entry.path ~ " - outside of extraction directory).",
            );

            const path = buildNormalizedPath(directory, entry.path);

            final switch (entry.type)
            {
            case EntryType.directory:
                mkdirRecurse(path);
                break;
            case EntryType.symlink:
                version (Posix)
                {
                    import core.sys.posix.unistd : lchown;
                    import std.string : toStringz;

                    mkdirRecurse(dirName(path));
                    symlink(entry.linkname, path);
                    lchown(toStringz(path), entry.ownerId, entry.groupId);

                    break;
                }
            case EntryType.regular:
                mkdirRecurse(dirName(path));
                auto f = File(path, "wb");
                foreach (chunk; entry.byChunk())
                {
                    f.rawWrite(chunk);
                }
                f.close();

                setTimes(path, Clock.currTime, entry.timeLastModified);

                version (Posix)
                {
                    import core.sys.posix.sys.stat : chmod;
                    import core.sys.posix.unistd : chown;
                    import std.string : toStringz;

                    chmod(toStringz(path), cast(uint)entry.permissions);
                    chown(toStringz(path), entry.ownerId, entry.groupId);
                }
                break;
            }
        }
    }
}

private struct ArchiveTarReadEntries
{
    import std.stdio : File;

    private File file;
    private size_t totalSz;

    // current header data
    private size_t offset;
    private size_t next;
    private ubyte[] block;
    private EntryData data;

    this(File file)
    {
        this.file = file;
        totalSz = file.size;
        enforce(
            totalSz % 512 == 0,
            "inconsistent size of tar file (not multiple of 512): " ~ file.name
        );
        block = new ubyte[512];

        // file with zero bytes is a valid tar file
        if (totalSz > 0)
            readHeaderBlock();
    }

    @property bool empty()
    {
        return next >= totalSz;
    }

    @property ArchiveEntry front()
    {
        return new ArchiveTarReadEntry(file, offset + 512, data);
    }

    void popFront()
    {
        offset = next;
        readHeaderBlock();
    }

    private void readHeaderBlock()
    {
        import std.conv : to;

        file.seek(offset);
        file.rawRead(block);

        TarHeader* th = cast(TarHeader*) block.ptr;

        const computed = th.unsignedChecksum();
        const checksum = parseOctalString(th.chksum);

        if (computed == 256 && checksum == 0)
        {
            // this is an empty header (only zeros)
            // indicates end of archive
            next = totalSz;
            return;
        }

        enforce(
            checksum == computed,
            file.name ~ ": Invalid TAR checksum at 0x" ~ (offset + th.chksum.offsetof).to!string(16) ~
            "\nExpected " ~ computed.to!string ~ " but found " ~ checksum.to!string,
        );

        data.path = (parseString(th.prefix) ~ parseString(th.name)).idup;
        data.type = toEntryType(th.typeflag);
        data.linkname = parseString(th.linkname).idup;
        data.size = parseOctalString!size_t(th.size);
        data.timeLastModified = SysTime(unixTimeToStdTime(parseOctalString!ulong(th.mtime)));
        version (Posix)
        {
            data.ownerId = parseOctalString(th.uid);
            data.groupId = parseOctalString(th.gid);
            data.permissions = cast(Permissions)parseOctalString(th.mode);
        }

        next = next512(offset + 512 + data.size);
    }
}

private struct EntryData
{
    string path;
    string linkname;
    EntryType type;
    size_t size;
    SysTime timeLastModified;

    version (Posix)
    {
        int ownerId;
        int groupId;
        Permissions permissions;
    }
}

private class ArchiveTarReadEntry : ArchiveEntry
{
    import std.stdio : File;

    private File _file;
    private size_t _offset;
    private size_t _end;
    private EntryData _data;

    this(File file, size_t offset, EntryData data)
    {
        _file = file;
        _offset = offset;
        _end = offset + data.size;
        _data = data;
    }

    @property string path()
    {
        return _data.path;
    }

    @property EntryType type()
    {
        return _data.type;
    }

    @property string linkname()
    {
        return _data.linkname;
    }

    @property size_t size()
    {
        return _data.size;
    }

    @property SysTime timeLastModified()
    {
        return _data.timeLastModified;
    }

    version (Posix)
    {
        @property Permissions permissions()
        {
            return _data.permissions;
        }

        @property int ownerId()
        {
            return _data.ownerId;
        }

        @property int groupId()
        {
            return _data.groupId;
        }
    }

    InputRange!(ubyte[]) byChunk(size_t chunkSize)
    {
        return inputRangeObject(FileByChunk(_file, _offset, _end, chunkSize));
    }
}

private struct FileByChunk
{
    import std.stdio : File;

    private File file;
    private size_t start;
    private size_t end;
    private ubyte[] chunk;
    private ubyte[] buffer;

    this(File file, size_t start, size_t end, size_t chunkSize)
    in(end >= start)
    in(chunkSize > 0)
    in(file.size >= end)
    {
        this.file = file;
        this.start = start;
        this.end = end;
        this.buffer = new ubyte[chunkSize];
        popFront();
    }

    @property bool empty()
    {
        return chunk.length == 0;
    }

    @property ubyte[] front()
    {
        return chunk;
    }

    void popFront()
    {
        import std.algorithm : min;

        const len = min(buffer.length, end - start);
        if (len == 0)
        {
            chunk = null;
            return;
        }

        file.seek(start);
        chunk = file.rawRead(buffer[0 .. len]);
        enforce(chunk.length == len, "Could not read file as expected");
        start += chunk.length;
    }
}

private struct ArchiveTarCreateByChunk
{
    // init data
    ubyte[] buffer;
    ArchiveEntry[] remainingEntries;

    // current chunk (front data)
    ubyte[] chunk; // data ready
    ubyte[] avail; // space available in buffer (after chunk)

    // current entry being processed
    ArchiveEntry entry;
    InputRange!(ubyte[]) entryChunk;

    this(size_t bufSize, ArchiveEntry[] entries)
    {
        enforce(bufSize % 512 == 0, "buffer size must be a multiple of 512");
        buffer = new ubyte[bufSize];
        remainingEntries = entries;
        avail = buffer;
        popFront();
    }

    @property bool empty()
    {
        const res = !buffer || (!chunk.length && remainingEntries.length == 0 && (!entryChunk || entryChunk.empty));
        return res;
    }

    @property const(ubyte)[] front()
    {
        return chunk;
    }

    void popFront()
    {
        if (chunk.length && !moreToRead())
        {
            chunk = null;
            return;
        }

        while (avail.length && moreToRead)
        {
            nextBlock();
            chunk = buffer[0 .. $ - avail.length];
        }
        avail = buffer;
    }

    private bool moreToRead()
    {
        return remainingEntries.length || (entryChunk && !entryChunk.empty);
    }

    private void nextBlock()
    in (avail.length >= 512)
    {
        if (!entry || !entryChunk || entryChunk.empty)
        {
            enforce(remainingEntries.length);
            entry = remainingEntries[0];
            remainingEntries = remainingEntries[1 .. $];
            avail = TarHeader.fillWith(entry, avail);
            entryChunk = entry.byChunk(512);
        }
        else
        {
            auto filled = entryChunk.front;
            avail = avail[filled.length .. $];
            entryChunk.popFront();
            if (entryChunk.empty)
            {
                const pad = avail.length % 512;
                avail[0 .. pad] = 0;
                avail = avail[pad .. $];
            }
        }
    }
}

private struct TarHeader
{
    // dfmt off
    char [100]  name;       //   0    0
    char [8]    mode;       // 100   64
    char [8]    uid;        // 108   6C
    char [8]    gid;        // 116   74
    char [12]   size;       // 124   7C
    char [12]   mtime;      // 136   88
    char [8]    chksum;     // 148   94
    Typeflag    typeflag;   // 156   9C
    char [100]  linkname;   // 157   9D
    char [6]    magic;      // 257  101
    char [2]    version_;   // 263  107
    char [32]   uname;      // 265  109
    char [32]   gname;      // 297  129
    char [8]    devmajor;   // 329  149
    char [8]    devminor;   // 337  151
    char [155]  prefix;     // 345  159
    char [12]   padding;    // 500  1F4
    //dfmt on

    private static ubyte[] fillWith(ArchiveEntry file, ubyte[] block)
    in (block.length >= 512)
    {
        import std.algorithm : min;
        import std.conv : octal;
        import std.string : toStringz;

        version (Posix)
        {
            char[512] buf;
        }

        block[0 .. 512] = 0;

        TarHeader* th = cast(TarHeader*)(&block[0]);

        // prefix and name
        const name = file.path;
        const prefLen = name.length > 100 ? cast(ptrdiff_t) name.length - 100 : 0;
        if (prefLen)
            th.prefix[0 .. prefLen] = name[0 .. prefLen];
        th.name[0 .. name.length - prefLen] = name[prefLen .. $];

        th.typeflag = fromEntryType(file.type);

        if (th.typeflag == Typeflag.symLink)
        {
            const lname = file.linkname;
            const len = min(lname.length, cast(ptrdiff_t) th.linkname.length - 1);
            th.linkname[0 .. len] = lname[0 .. len];
        }

        version (Posix)
        {
            import core.sys.posix.grp;
            import core.sys.posix.pwd;

            //import core.sys.posix.unistd;
            import core.stdc.string : strlen;

            const uid = file.ownerId;
            const gid = file.groupId;

            toOctalString(cast(int) file.permissions, th.mode[0 .. $ - 1]);
            toOctalString(uid, th.uid[0 .. $ - 1]);
            toOctalString(gid, th.gid[0 .. $ - 1]);

            if (uid != 0)
            {
                passwd pwdbuf;
                passwd* pwd;
                enforce(getpwuid_r(uid, &pwdbuf, buf.ptr, buf.length, &pwd) == 0, "Could not read user name");
                const urlen = min(strlen(pwd.pw_name), th.uname.length);
                th.uname[0 .. urlen] = pwd.pw_name[0 .. urlen];
            }

            if (gid != 0)
            {
                group grpbuf;
                group* grp;
                enforce(getgrgid_r(gid, &grpbuf, buf.ptr, buf.length, &grp) == 0, "Could not read group name");
                const grlen = min(strlen(grp.gr_name), th.gname.length);
                th.gname[0 .. grlen] = grp.gr_name[0 .. grlen];
            }
        }
        else version (Windows)
        {
            // default to mode 644 which is the most common on UNIX
            th.mode[0 .. 7] = "0000644";

            // TODO: https://docs.microsoft.com/fr-fr/windows/win32/secauthz/finding-the-owner-of-a-file-object-in-c--
        }

        toOctalString(file.size, th.size[0 .. $ - 1]);
        const mtime = file.timeLastModified().toUnixTime!long();
        toOctalString(mtime, th.mtime[0 .. $ - 1]);

        th.magic = "ustar\0";
        th.version_ = "00";

        const chksum = th.unsignedChecksum();

        toOctalString(chksum, th.chksum[0 .. $ - 1]);

        return block[512 .. $];
    }

    private uint unsignedChecksum()
    {
        uint sum = 0;
        sum += unsignedSum(name);
        sum += unsignedSum(mode);
        sum += unsignedSum(uid);
        sum += unsignedSum(gid);
        sum += unsignedSum(size);
        sum += unsignedSum(mtime);
        sum += 32 * 8;
        sum += cast(uint) typeflag;
        sum += unsignedSum(linkname);
        sum += unsignedSum(magic);
        sum += unsignedSum(version_);
        sum += unsignedSum(uname);
        sum += unsignedSum(gname);
        sum += unsignedSum(devmajor);
        sum += unsignedSum(devminor);
        sum += unsignedSum(prefix);
        return sum;
    }
}

static assert(TarHeader.sizeof == 512);

private enum Typeflag : ubyte
{
    normalNul = 0,
    normal = '0',
    hardLink = '1',
    symLink = '2',
    charSpecial = '3',
    blockSpecial = '4',
    directory = '5',
    fifo = '6',
    contiguousFile = '7',
}

Typeflag fromEntryType(EntryType type)
{
    final switch (type)
    {
    case EntryType.regular:
        return Typeflag.normal;
    case EntryType.directory:
        return Typeflag.directory;
    case EntryType.symlink:
        return Typeflag.symLink;
    }
}

EntryType toEntryType(Typeflag flag)
{
    switch (flag)
    {
    case Typeflag.directory:
        return EntryType.directory;
    case Typeflag.symLink:
        return EntryType.symlink;
    default:
        return EntryType.regular;
    }
}

private uint unsignedSum(const(char)[] buf)
{
    uint sum;
    foreach (ubyte b; cast(const(ubyte)[]) buf)
    {
        sum += cast(uint) b;
    }
    return sum;
}

private void toOctalString(T)(T val, char[] buf)
{
    import std.format : sformat;

    sformat(buf, "%0*o", buf.length, val);
}

import std.traits;
import std.range;

alias Source = const(char)[];
alias Target = uint;

static assert(isInputRange!Source);
static assert(isSomeChar!(ElementType!Source));
static assert(isIntegral!Target);
static assert(!is(Target == enum));

private T parseOctalString(T = uint)(const(char)[] octal)
{
    import std.algorithm : countUntil;
    import std.conv : parse;
    import std.range : retro;

    size_t nuls = retro(octal).countUntil!(c => c != '\0');

    if (nuls == octal.length || nuls == -1)
        return 0;

    auto src = octal[0 .. $ - nuls];

    return parse!(T)(src, 8);
}

private char[] parseString(char[] chars)
{
    import core.stdc.string : strlen;

    const len = strlen(chars.ptr);
    return chars[0 .. len];
}

private size_t next512(size_t off)
{
    const rem = off % 512;
    if (rem == 0)
        return off;
    return off + 512 - rem;
}

@("next512")
unittest
{
    assert(next512(0) == 0);
    assert(next512(1) == 512);
    assert(next512(300) == 512);
    assert(next512(511) == 512);
    assert(next512(512) == 512);
    assert(next512(1024) == 1024);
    assert(next512(1025) == 1536);
    assert(next512(1225) == 1536);
    assert(next512(1535) == 1536);
    assert(next512(1536) == 1536);
}
