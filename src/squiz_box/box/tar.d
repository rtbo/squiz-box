module squiz_box.box.tar;

import squiz_box.box;
import squiz_box.priv;
import squiz_box.squiz;

import std.datetime.systime;
import std.exception;
import std.path;
import std.range;

/// BoxAlgo for ".tar" files
class TarAlgo : BoxAlgo
{
    ByteRange box(BoxEntryRange entries, size_t chunkSize = defaultChunkSize)
    {
        auto bytes = entries.boxTar(chunkSize);
        return inputRangeObject(bytes);
    }

    UnboxEntryRange unbox(ByteRange bytes)
    {
        auto entries = bytes.unboxTar();
        return inputRangeObject(entries);
    }
}

/// BoxAlgo for ".tar.gz" files
class TarGzAlgo : BoxAlgo
{
    ByteRange box(BoxEntryRange entries, size_t chunkSize = defaultChunkSize)
    {
        auto bytes = entries.boxTarGz(chunkSize);
        return inputRangeObject(bytes);
    }

    UnboxEntryRange unbox(ByteRange bytes)
    {
        auto entries = bytes.unboxTarGz();
        return inputRangeObject(entries);
    }
}

version (HaveSquizBzip2)
{
    /// BoxAlgo for ".tar.bz2" files
    class TarBzip2Algo : BoxAlgo
    {
        ByteRange box(BoxEntryRange entries, size_t chunkSize = defaultChunkSize)
        {
            auto bytes = entries.boxTarBzip2(chunkSize);
            return inputRangeObject(bytes);
        }

        UnboxEntryRange unbox(ByteRange bytes)
        {
            auto entries = bytes.unboxTarBzip2();
            return inputRangeObject(entries);
        }
    }
}

version (HaveSquizLzma)
{
    /// BoxAlgo for ".tar.xz" files
    class TarXzAlgo : BoxAlgo
    {
        ByteRange box(BoxEntryRange entries, size_t chunkSize = defaultChunkSize)
        {
            auto bytes = entries.boxTarXz(chunkSize);
            return inputRangeObject(bytes);
        }

        UnboxEntryRange unbox(ByteRange bytes)
        {
            auto entries = bytes.unboxTarXz();
            return inputRangeObject(entries);
        }
    }
}

/// Returns a `.tar`, `.tar.gz`, `.tar.bz2` or `.tar.xz` archive as a byte range
/// corresponding to the entries in input.
/// chunkSize must be a multiple of 512.
auto boxTar(I)(I entries, size_t chunkSize = defaultChunkSize)
        if (isBoxEntryRange!I)
in (chunkSize >= 512 && chunkSize % 512 == 0)
{
    return TarBox!I(entries, chunkSize);
}

/// ditto
auto boxTarGz(I)(I entries, size_t chunkSize = defaultChunkSize)
{
    return boxTar(entries, chunkSize).deflateGz(chunkSize);
}

version (HaveSquizBzip2)
{
    /// ditto
    auto boxTarBzip2(I)(I entries, size_t chunkSize = defaultChunkSize)
    {
        return boxTar(entries, chunkSize).compressBzip2(chunkSize);
    }
}

version (HaveSquizLzma)
{
    /// ditto
    auto boxTarXz(I)(I entries, size_t chunkSize = defaultChunkSize)
    {
        return boxTar(entries, chunkSize).compressXz(chunkSize);
    }
}

private struct TarBox(I)
{
    // init data
    I entriesInput;
    ubyte[] buffer;

    // current chunk (front data)
    ubyte[] chunk; // data ready
    ubyte[] avail; // space available in buffer (after chunk)

    // current entry being processed
    BoxEntry entry;
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

    @property ByteChunk front()
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

static assert(isByteRange!(TarBox!(BoxEntry[])));

/// Returns a range of entries from a `.tar`, `.tar.gz`, `.tar.bz2` or `.tar.xz` formatted byte range
auto unboxTar(I)(I input) if (isByteRange!I)
{
    auto dataInput = new ByteRangeCursor!I(input);
    return TarUnbox(dataInput);
}

/// ditto
auto unboxTarGz(I)(I input)
{
    return input.inflateGz().unboxTar();
}

version (HaveSquizBzip2)
{
    /// ditto
    auto unboxTarBzip2(I)(I input)
    {
        return input.decompressBzip2().unboxTar();
    }
}

version (HaveSquizLzma)
{
    /// ditto
    auto unboxTarXz(I)(I input)
    {
        return input.decompressXz().unboxTar();
    }
}

private struct TarUnbox
{
    private Cursor _input;

    // current header data
    private size_t _next;
    private ubyte[] _block;
    private UnboxEntry _entry;

    this(Cursor input)
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

    @property UnboxEntry front()
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

        if (th.typeflag == Typeflag.posixExtended || th.typeflag == Typeflag.extended)
        {
            // skipping extended Tar headers
            const sz = next512(parseOctalString!size_t(th.size));
            _input.ffw(sz);
            readHeaderBlock();
            return;
        }

        TarEntryInfo info;
        info.path = (parseString(th.prefix) ~ parseString(th.name)).idup;
        info.type = toEntryType(th.typeflag);
        info.linkname = parseString(th.linkname).idup;
        info.size = parseOctalString!size_t(th.size);
        info.entrySize = 512 + next512(info.size);
        info.timeLastModified = SysTime(unixTimeToStdTime(parseOctalString!ulong(th.mtime)));
        version (Posix)
        {
            // tar mode contains stat.st_mode & 07777.
            // we have to add the missing flags corresponding to file type
            // (and by no way tar mode is meaningful on Windows)
            const filetype = posixModeFileType(th.typeflag);
            info.attributes = parseOctalString(th.mode) | filetype;
            info.ownerId = parseOctalString(th.uid);
            info.groupId = parseOctalString(th.gid);
        }

        _entry = new TarUnboxEntry(_input, info);

        _next = next512(_input.pos + info.size);
    }
}

static assert(isUnboxEntryRange!TarUnbox);

struct TarEntryInfo
{
    string path;
    string linkname;
    EntryType type;
    ulong size;
    ulong entrySize;
    SysTime timeLastModified;
    uint attributes;

    version (Posix)
    {
        int ownerId;
        int groupId;
    }
}

private class TarUnboxEntry : UnboxEntry
{
    import std.stdio : File;

    private Cursor _input;
    private size_t _start;
    private size_t _end;
    private TarEntryInfo _info;

    this(Cursor input, TarEntryInfo info)
    {
        _input = input;
        _start = input.pos;
        _end = _start + info.size;
        _info = info;
    }

    @property EntryMode mode()
    {
        return EntryMode.extraction;
    }

    @property string path()
    {
        return _info.path;
    }

    @property EntryType type()
    {
        return _info.type;
    }

    @property string linkname()
    {
        return _info.linkname;
    }

    @property size_t size()
    {
        return _info.size;
    }

    @property size_t entrySize()
    {
        return _info.entrySize;
    }

    @property SysTime timeLastModified()
    {
        return _info.timeLastModified;
    }

    @property uint attributes()
    {
        return _info.attributes;
    }

    version (Posix)
    {
        @property int ownerId()
        {
            return _info.ownerId;
        }

        @property int groupId()
        {
            return _info.groupId;
        }
    }

    ByteRange byChunk(size_t chunkSize)
    {
        import std.range.interfaces : inputRangeObject;

        enforce(
            _input.pos == _start,
            "Data cursor has moved, this entry is not valid anymore"
        );
        return inputRangeObject(cursorByteRange(_input, _end - _input.pos, chunkSize));
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
    posixExtended = 'g',
    extended = 'x',
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
        import std.format : format;

        switch (flag)
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
        default:
            throw new Exception(format!"Unexpected Tar entry type: '%s'"(cast(char) flag));
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
