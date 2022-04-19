module squiz_box.tar;

import squiz_box.core;

import std.exception;
import std.path;

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
}

struct ArchiveTarCreate
{
    ArchiveEntry[] entries;

    auto byChunk(size_t chunkSz=4096)
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

private struct ArchiveTarCreateByChunk
{
    // init data
    ubyte[] buffer;
    ArchiveEntry[] remainingEntries;

    // current chunk
    ubyte[] chunk;
    ubyte[] avail;

    // current entry being processed
    ArchiveEntry entry;
    bool eof;

    this(size_t bufSize, ArchiveEntry[] entries)
    {
        enforce(bufSize % 512 == 0, "buffer size must be a multiple of 512");
        buffer = new ubyte[bufSize];
        remainingEntries = entries;
        avail = buffer;
        popFront();
    }

    @property bool empty() const
    {
        const res = !buffer || (!chunk.length && remainingEntries.length == 0 && eof);
        return res;
    }

    @property const(ubyte)[] front() const
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

    private bool moreToRead() const
    {
        return remainingEntries.length || !eof;
    }

    private void nextBlock()
    in (avail.length >= 512)
    {
        if (!entry || eof)
        {
            enforce(remainingEntries.length);
            entry = remainingEntries[0];
            remainingEntries = remainingEntries[1 .. $];
            avail = TarHeader.fillWith(entry, avail);
            eof = false;
        }
        else
        {
            auto filled = entry.read(avail);
            eof = filled.length != avail.length;
            avail = avail[filled.length .. $];
            if (eof)
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
        import std.conv : octal;
        import std.string : toStringz;

        version (Posix)
        {
            char[4096] buf;
        }

        block[0 .. 512] = 0;

        TarHeader* th = cast(TarHeader*)(&block[0]);

        // prefix and name
        const name = file.path;
        const prefLen = name.length > 100 ? cast(ptrdiff_t)name.length - 100 : 0;
        if (prefLen)
            th.prefix[0 .. prefLen] = name[0 .. prefLen];
        th.name[0 .. name.length - prefLen] = name[prefLen .. $];

        version (Posix)
        {
            import core.sys.posix.grp;
            import core.sys.posix.pwd;
            import core.sys.posix.unistd;
            import core.sys.posix.sys.stat;
            import core.stdc.string : strlen;
            import std.algorithm : min;

            const stat = file.stat();

            toOctString(stat.st_mode & octal!"777", th.mode[0 .. $ - 1]);
            toOctString(stat.st_uid, th.uid[0 .. $ - 1]);
            toOctString(stat.st_gid, th.gid[0 .. $ - 1]);
            toOctString(stat.st_size, th.size[0 .. $ - 1]);
            toOctString(stat.st_mtime, th.mtime[0 .. $ - 1]);

            th.typeflag = fromStMode(stat.st_mode);

            if (S_ISLNK(stat.st_mode))
            {
                enforce(readlink(toStringz(name), th.linkname.ptr, th.linkname.length) > 0, "Could not read link");
            }

            if (stat.st_uid != 0)
            {
                passwd pwdbuf;
                passwd* pwd;
                enforce(getpwuid_r(stat.st_uid, &pwdbuf, buf.ptr, buf.length, &pwd) == 0, "Could not read user name");
                const urlen = min(strlen(pwd.pw_name), th.uname.length);
                th.uname[0 .. urlen] = pwd.pw_name[0 .. urlen];
            }

            if (stat.st_gid != 0)
            {
                group grpbuf;
                group* grp;
                enforce(getgrgid_r(stat.st_gid, &grpbuf, buf.ptr, buf.length, &grp) == 0, "Could not read group name");
                const grlen = min(strlen(grp.gr_name), th.gname.length);
                th.gname[0 .. grlen] = grp.gr_name[0 .. grlen];
            }
        }
        else version (Windows)
        {
            // default to mode 644 which is the most common on UNIX
            th.mode[0 .. 7] = "0000644";
            th.typeflag = Typeflag.normal;

            // TODO: https://docs.microsoft.com/fr-fr/windows/win32/secauthz/finding-the-owner-of-a-file-object-in-c--

            toOctString(file.size, th.size[0 .. $ - 1]);
            const mtime = file.mtime().toUnixTime!long();
            toOctString(mtime, th.mtime[0 .. $ - 1]);
        }

        th.magic = "ustar ";
        th.version_ = " \0";

        const chksum = th.unsignedChecksum();

        toOctString(chksum, th.chksum[0 .. $ - 1]);

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
    globalExtendedHeader = 'g',
    extendedHeader = 'x',
}

version (Posix)
{
    import core.sys.posix.sys.types : mode_t;

    Typeflag fromStMode(mode_t mode)
    {
        import core.sys.posix.sys.stat;

        if (S_ISLNK(mode))
        {
            return Typeflag.symLink;
        }
        else if (S_ISREG(mode))
        {
            return Typeflag.normal;
        }
        else if (S_ISDIR(mode))
        {
            return Typeflag.directory;
        }
        else if (S_ISCHR(mode))
        {
            return Typeflag.charSpecial;
        }
        else if (S_ISBLK(mode))
        {
            return Typeflag.blockSpecial;
        }
        else if (S_ISFIFO(mode))
        {
            return Typeflag.fifo;
        }
        return Typeflag.normal;
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

private void toOctString(T)(T val, char[] buf)
{
    import std.format : sformat;

    sformat(buf, "%0*o", buf.length, val);
}
