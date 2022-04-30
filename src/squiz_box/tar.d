module squiz_box.tar;

import squiz_box.core;
import squiz_box.priv;

import std.datetime.systime;
import std.exception;
import std.path;
import std.range.primitives;

/// Returns a Tar archive as a byte range
/// corresponding to the entries in input.
/// chunkSize must be a multiple of 512.
auto createTarArchive(I)(I entries, size_t chunkSize = defaultChunkSize)
        if (isCreateEntryRange!I)
in (chunkSize >= 512 && chunkSize % 512 == 0)
{
    return TarArchiveCreate!I(entries, chunkSize);
}

private struct TarArchiveCreate(I)
{
    // init data
    I entriesInput;
    ubyte[] buffer;

    // current chunk (front data)
    ubyte[] chunk; // data ready
    ubyte[] avail; // space available in buffer (after chunk)

    // current entry being processed
    ArchiveCreateEntry entry;
    ByteRange entryChunks;

    // footer is two empty blocks
    size_t footer;
    enum footerLen = 1024;

    this(I entries, size_t chunkSize)
    {
        enforce(chunkSize % 512 == 0, "chunk size must be a multiple of 512");
        entriesInput = entries;
        buffer = new ubyte[chunkSize];
        avail = buffer;
        popFront();
    }

    @property bool empty()
    {
        // handle .init
        if (!buffer)
            return true;

        // more files to be processed
        if (!entriesInput.empty)
            return false;

        // current entry not exhausted
        if (hasEntryChunks())
            return false;

        // some unconsumed flying data
        if (chunk.length)
            return false;

        return true;
    }

    @property const(ubyte)[] front()
    {
        return chunk;
    }

    void popFront()
    {
        if (!moreToRead())
        {
            if (footer >= footerLen)
            {
                chunk = null;
            }
            else
            {
                import std.algorithm : min;

                const len = min(buffer.length, footerLen - footer);
                buffer[0 .. len] = 0;
                chunk = buffer[0 .. len];
                footer += len;
            }
            return;
        }

        while (avail.length && moreToRead)
        {
            nextBlock();
            chunk = buffer[0 .. $ - avail.length];
        }
        avail = buffer;
    }

    private bool hasEntryChunks()
    {
        return entryChunks && !entryChunks.empty;
    }

    private bool moreToRead()
    {
        return !entriesInput.empty || hasEntryChunks();
    }

    private void nextBlock()
    in (avail.length >= 512)
    {
        if (!entry || !hasEntryChunks())
        {
            enforce(!entriesInput.empty);
            entry = entriesInput.front;
            entriesInput.popFront();
            avail = TarHeader.fillWith(entry, avail);
            entryChunks = entry.byChunk(512);
        }
        else
        {
            auto filled = entryChunks.front;
            avail[0 .. filled.length] = filled;
            avail = avail[filled.length .. $];
            entryChunks.popFront();
            if (entryChunks.empty)
            {
                const pad = avail.length % 512;
                avail[0 .. pad] = 0;
                avail = avail[pad .. $];
            }
        }
    }
}

static assert(isByteRange!(TarArchiveCreate!(ArchiveCreateEntry[])));

/// Return a range of entries from a Tar formatted byte range
auto readTarArchive(I)(I tarInput) if (isByteRange!I)
{
    auto dataInput = new ByteRangeStream!I(tarInput);
    return ArchiveTarRead(dataInput);
}

private struct ArchiveTarRead
{
    private Stream _input;

    // current header data
    private size_t _next;
    private ubyte[] _block;
    private ArchiveExtractEntry _entry;

    this(Stream input)
    {
        _input = input;
        _block = new ubyte[512];

        // file with zero bytes is a valid tar file
        if (!_input.eoi)
            readHeaderBlock();
    }

    @property bool empty()
    {
        return _input.eoi;
    }

    @property ArchiveExtractEntry front()
    {
        return _entry;
    }

    void popFront()
    {
        assert(_input.pos <= _next);

        if (_input.pos < _next)
        {
            // the current entry was not fully read, we move the stream forward
            // up to the next header
            const dist = _next - _input.pos;
            _input.ffw(dist);
        }
        readHeaderBlock();
    }

    private void readHeaderBlock()
    {
        import std.conv : to;

        enforce(_input.read(_block).length == 512, "Unexpected end of input");

        TarHeader* th = cast(TarHeader*) _block.ptr;

        const computed = th.unsignedChecksum();
        const checksum = parseOctalString(th.chksum);

        if (computed == 256 && checksum == 0)
        {
            // this is an empty header (only zeros)
            // indicates end of archive

            while (!_input.eoi)
            {
                _input.ffw(512);
            }
            return;
        }

        enforce(
            checksum == computed,
            "Invalid TAR checksum at 0x" ~ (
                _input.pos - 512 + th.chksum.offsetof)
                .to!string(16) ~
                "\nExpected " ~ computed.to!string ~ " but found " ~ checksum.to!string,
        );

        EntryData data;
        data.path = (parseString(th.prefix) ~ parseString(th.name)).idup;
        data.type = toEntryType(th.typeflag);
        data.linkname = parseString(th.linkname).idup;
        data.size = parseOctalString!size_t(th.size);
        data.entrySize = 512 + next512(data.size);
        data.timeLastModified = SysTime(unixTimeToStdTime(parseOctalString!ulong(th.mtime)));
        version (Posix)
        {
            // tar mode contains stat.st_mode & 07777.
            // we have to add the missing flags corresponding to file type
            // (and by no way tar mode is meaningful on Windows)
            const filetype = posixModeFileType(th.typeflag);
            data.attributes = parseOctalString(th.mode) | filetype;
            data.ownerId = parseOctalString(th.uid);
            data.groupId = parseOctalString(th.gid);
        }

        _entry = new ArchiveTarExtractEntry(_input, data);

        _next = next512(_input.pos + data.size);
    }
}

static assert(isExtractEntryRange!ArchiveTarRead);

private class ArchiveTarExtractEntry : ArchiveExtractEntry
{
    import std.stdio : File;

    private Stream _input;
    private size_t _start;
    private size_t _end;
    private EntryData _data;

    this(Stream input, EntryData data)
    {
        _input = input;
        _start = input.pos;
        _end = _start + data.size;
        _data = data;
    }

    @property EntryMode mode()
    {
        return EntryMode.extraction;
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

    @property size_t entrySize()
    {
        return _data.entrySize;
    }

    @property SysTime timeLastModified()
    {
        return _data.timeLastModified;
    }

    @property uint attributes()
    {
        return _data.attributes;
    }

    version (Posix)
    {
        @property int ownerId()
        {
            return _data.ownerId;
        }

        @property int groupId()
        {
            return _data.groupId;
        }
    }

    ByteRange byChunk(size_t chunkSize)
    {
        import std.range.interfaces : inputRangeObject;

        enforce(
            _input.pos == _start,
            "Data cursor has moved, this entry is not valid anymore"
        );
        return inputRangeObject(StreamByteRange(_input, chunkSize, _end));
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

        th.typeflag = toTypeflag(file.type);

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
            import core.stdc.string : strlen;
            import std.conv : octal;

            const uid = file.ownerId;
            const gid = file.groupId;

            toOctalString(file.attributes & octal!7777, th.mode[0 .. $ - 1]);
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

Typeflag toTypeflag(EntryType type)
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

version (Posix)
{
    // stat.st_mode part corresponding to file type
    uint posixModeFileType(Typeflag flag)
    {
        import std.conv : octal;

        final switch (flag)
        {
        case Typeflag.normalNul:
        case Typeflag.normal:
            return octal!100_000;
        case Typeflag.hardLink:
            // is regular file right for hard links?
            return octal!100_000;
        case Typeflag.symLink:
            return octal!120_000;
        case Typeflag.charSpecial:
            return octal!20_000;
        case Typeflag.blockSpecial:
            return octal!60_000;
        case Typeflag.directory:
            return octal!40_000;
        case Typeflag.fifo:
            return octal!10_000;
        case Typeflag.contiguousFile:
            // is regular file right for contiguous files?
            return octal!100_000;
        }
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
