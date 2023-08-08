module squiz_box.box.tar;

import squiz_box.box;
import squiz_box.priv;
import squiz_box.squiz;

import std.datetime.systime;
import std.exception;
import std.path;
import std.range;
import std.string;

/// BoxAlgo for ".tar" files
struct TarAlgo
{
    auto box(I)(I entries, size_t chunkSize = defaultChunkSize)
            if (isBoxEntryRange!I)
    {
        return TarBox!I(entries, chunkSize);
    }

    auto unbox(I)(I input, Flag!"removePrefix" removePrefix = No.removePrefix)
            if (isByteRange!I)
    {
        auto dataInput = new ByteRangeCursor!I(input);
        return TarUnbox(dataInput, removePrefix);
    }
}

static assert(isBoxAlgo!TarAlgo);

/// BoxAlgo for ".tar.gz" files
struct TarGzAlgo
{
    auto box(I)(I entries, size_t chunkSize = defaultChunkSize)
            if (isBoxEntryRange!I)
    {
        return TarBox!I(entries, chunkSize).deflateGz(chunkSize);
    }

    auto unbox(I)(I input, Flag!"removePrefix" removePrefix = No.removePrefix)
            if (isByteRange!I)
    {
        auto ii = input.inflateGz();
        alias II = typeof(ii);
        auto dataInput = new ByteRangeCursor!II(ii);
        return TarUnbox(dataInput, removePrefix);
    }
}

static assert(isBoxAlgo!TarGzAlgo);

version (HaveSquizBzip2)
{
    /// BoxAlgo for ".tar.bz2" files
    struct TarBzip2Algo
    {
        auto box(I)(I entries, size_t chunkSize = defaultChunkSize)
                if (isBoxEntryRange!I)
        {
            return TarBox!I(entries, chunkSize).compressBzip2(chunkSize);
        }

        auto unbox(I)(I input, Flag!"removePrefix" removePrefix = No.removePrefix)
                if (isByteRange!I)
        {
            auto ii = input.decompressBzip2();
            alias II = typeof(ii);
            auto dataInput = new ByteRangeCursor!II(ii);
            return TarUnbox(dataInput, removePrefix);
        }
    }

    static assert(isBoxAlgo!TarBzip2Algo);
}

version (HaveSquizLzma)
{
    /// BoxAlgo for ".tar.xz" files
    struct TarXzAlgo
    {
        auto box(I)(I entries, size_t chunkSize = defaultChunkSize)
                if (isBoxEntryRange!I)
        {
            return TarBox!I(entries, chunkSize).compressXz(chunkSize);
        }

        auto unbox(I)(I input, Flag!"removePrefix" removePrefix = No.removePrefix)
                if (isByteRange!I)
        {
            auto ii = input.decompressXz();
            alias II = typeof(ii);
            auto dataInput = new ByteRangeCursor!II(ii);
            return TarUnbox(dataInput, removePrefix);
        }
    }

    static assert(isBoxAlgo!TarXzAlgo);
}

/// Returns a `.tar`, `.tar.gz`, `.tar.bz2` or `.tar.xz` archive as a byte range
/// corresponding to the entries in input.
auto boxTar(I)(I entries, size_t chunkSize = defaultChunkSize)
        if (isBoxEntryRange!I)
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

/// Returns a range of entries from a `.tar`, `.tar.gz`, `.tar.bz2` or `.tar.xz` formatted byte range
auto unboxTar(I)(I input, Flag!"removePrefix" removePrefix = No.removePrefix)
        if (isByteRange!I)
{
    auto dataInput = new ByteRangeCursor!I(input);
    return TarUnbox(dataInput, removePrefix);
}

/// ditto
auto unboxTarGz(I)(I input, Flag!"removePrefix" removePrefix = No.removePrefix)
{
    return input.inflateGz().unboxTar(removePrefix);
}

version (HaveSquizBzip2)
{
    /// ditto
    auto unboxTarBzip2(I)(I input, Flag!"removePrefix" removePrefix = No.removePrefix)
    {
        return input.decompressBzip2().unboxTar(removePrefix);
    }
}

version (HaveSquizLzma)
{
    /// ditto
    auto unboxTarXz(I)(I input, Flag!"removePrefix" removePrefix = No.removePrefix)
    {
        return input.decompressXz().unboxTar(removePrefix);
    }
}

private:

enum blockLen = 512;
enum nameLen = 100;
enum unameLen = 32;
enum prefixLen = 155;

enum char[8] posixMagic = "ustar\x0000";
enum char[8] gnuMagic = "ustar  \x00";

enum Typeflag : ubyte
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
    gnuLongname = 'L',
    gnuLonglink = 'K',
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

struct BlockInfo
{
    static struct Block
    {
        // dfmt off
        char [nameLen]      name;       //   0    0
        char [8]            mode;       // 100   64
        char [8]            uid;        // 108   6C
        char [8]            gid;        // 116   74
        char [12]           size;       // 124   7C
        char [12]           mtime;      // 136   88
        char [8]            chksum;     // 148   94
        Typeflag            typeflag;   // 156   9C
        char [nameLen]      linkname;   // 157   9D
        char [8]            magic;      // 257  101
        char [unameLen]     uname;      // 265  109
        char [unameLen]     gname;      // 297  129
        char [8]            devmajor;   // 329  149
        char [8]            devminor;   // 337  151
        char [prefixLen]    prefix;     // 345  159
        char [12]           padding;    // 500  1F4
        //dfmt on

        private uint checksum()
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
            sum += unsignedSum(uname);
            sum += unsignedSum(gname);
            sum += unsignedSum(devmajor);
            sum += unsignedSum(devminor);
            sum += unsignedSum(prefix);
            return sum;
        }
    }

    static assert(Block.sizeof == blockLen);

    string name;
    uint mode;
    int uid;
    int gid;
    size_t size;
    long mtime;
    Typeflag typeflag;
    string linkname;
    char[8] magic;
    string uname;
    string gname;
    int devmajor;
    int devminor;
    string prefix;

    bool isNull;

    size_t encode(scope ubyte[] buffer) const
    in (buffer.length >= Block.sizeof)
    in (name.length <= Block.name.sizeof)
    in (linkname.length <= Block.linkname.sizeof)
    in (uname.length <= Block.uname.sizeof)
    in (gname.length <= Block.gname.sizeof)
    in (prefix.length <= Block.prefix.sizeof)
    {
        buffer[0 .. blockLen] = 0;
        if (isNull)
            return blockLen;

        Block* blk = cast(Block*)&buffer[0];

        blk.name[0 .. name.length] = name;
        toOctalString(mode, blk.mode[]);
        toOctalString(uid, blk.uid[]);
        toOctalString(gid, blk.gid[]);
        toOctalString(size, blk.size[]);
        toOctalString(mtime, blk.mtime[]);
        blk.typeflag = typeflag;
        blk.linkname[0 .. linkname.length] = linkname;
        blk.magic = magic;
        blk.uname[0 .. uname.length] = uname;
        blk.gname[0 .. gname.length] = gname;
        toOctalString(devmajor, blk.devmajor[]);
        toOctalString(devminor, blk.devminor[]);
        blk.prefix[0 .. prefix.length] = prefix;

        const checksum = blk.checksum();
        toOctalString(checksum, blk.chksum[]);

        return blockLen;
    }

    static BlockInfo decode(Cursor cursor)
    {
        Block blk = void;
        cursor.readValue(&blk);

        const computed = blk.checksum();
        const checksum = parseOctalString!uint(blk.chksum);
        if (computed == 256 && checksum == 0)
        {
            // this is an empty header (only zeros)
            // indicates end of archive

            // dfmt off
            BlockInfo info = {
                isNull: true,
            };
            // dfmt on
            return info;
        }

        enforce(
            checksum == computed,
            format!"Invalid TAR checksum at 0x%08X\nExpected 0x%08x but found 0x%08x"(
                cursor.pos - blockLen + blk.chksum.offsetof,
                computed, checksum)
        );

        BlockInfo info = {
            name: parseString(blk.name).idup,
            mode: parseOctalString!uint(blk.mode),
            uid: parseOctalString!uint(blk.uid),
            gid: parseOctalString!uint(blk.uid),
            size: parseOctalString!size_t(blk.size),
            mtime: parseOctalString!long(blk.mtime),
            typeflag: blk.typeflag,
            linkname: parseString(blk.linkname).idup,
            magic: blk.magic,
            uname: parseString(blk.uname).idup,
            gname: parseString(blk.gname).idup,
            devmajor: parseOctalString!int(blk.devmajor),
            devminor: parseOctalString!int(blk.devminor),
            prefix: parseString(blk.prefix).idup,
        };

        return info;
    }
}

void ensureLen(ref ubyte[] buffer, size_t len)
{
    if (buffer.length < len)
        buffer.length = len;
}

size_t encodeLongGnu(ref ubyte[] buffer, size_t offset, string name, Typeflag typeflag)
{
    const l512 = next512(name.length);
    buffer.ensureLen(offset + blockLen + l512);

    BlockInfo gnu = {
        name: "././@LongLink",
        size: name.length,
        typeflag: typeflag,
        magic: gnuMagic,
    };
    gnu.encode(buffer[offset .. $]);

    buffer[offset + blockLen .. offset + blockLen + name.length] = name.representation;
    buffer[offset + blockLen + name.length .. offset + blockLen + l512] = 0;

    return blockLen + l512;
}

struct TarInfo
{
    string name;
    uint mode;
    int uid;
    int gid;
    size_t size;
    SysTime mtime;
    string linkname;
    EntryType type;
    string uname;
    string gname;
    int devmajor;
    int devminor;

    size_t entrySize;
    bool isNull;

    // encode this header in buffer, starting at offset
    // buffer can potentially be grown if too small
    size_t encode(ref ubyte[] buffer, size_t offset)
    {
        import std.algorithm : max;
        import std.string : representation;

        if (isNull)
        {
            buffer.ensureLen(offset + blockLen);
            buffer[offset .. offset + blockLen] = 0;
            return blockLen;
        }

        size_t encoded;

        string nm = name;
        string lk = linkname;
        string px;
        if (nm.length > nameLen)
        {
            const pn = splitLongName(nm);
            if (pn[0] != null)
            {
                px = pn[0];
                nm = pn[1];
            }
            else
            {
                encoded += buffer.encodeLongGnu(offset + encoded, nm, Typeflag.gnuLongname);
                nm = null;
            }
        }
        if (lk.length > nameLen)
        {
            encoded += buffer.encodeLongGnu(offset + encoded, lk, Typeflag.gnuLonglink);
            lk = null;
        }

        buffer.ensureLen(offset + encoded + blockLen);

        BlockInfo blk = {
            name: nm,
            mode: mode,
            uid: uid,
            gid: gid,
            size: size,
            mtime: max(0, mtime.toUnixTime()),
            linkname: lk,
            typeflag: toTypeflag(type),
            magic: posixMagic,
            uname: uname,
            gname: gname,
            devmajor: devmajor,
            devminor: devminor,
        };

        return encoded + blk.encode(buffer[offset + encoded .. $]);
    }

    static TarInfo decode(Cursor cursor)
    {
        auto blk = BlockInfo.decode(cursor);
        if (blk.isNull)
        {
            TarInfo info = {entrySize: blockLen,
            isNull: true,};
            return info;
        }

        switch (blk.typeflag)
        {
        case Typeflag.normalNul:
        case Typeflag.normal:
        case Typeflag.hardLink:
        case Typeflag.symLink:
        case Typeflag.charSpecial:
        case Typeflag.blockSpecial:
        case Typeflag.directory:
        case Typeflag.fifo:
        case Typeflag.contiguousFile:
        case Typeflag.posixExtended:
        case Typeflag.extended:
            return decodeHeader(blk);
        case Typeflag.gnuLongname:
        case Typeflag.gnuLonglink:
            return decodeGnuLongHeader(cursor, blk);
        default:
            const msg = format!"Unknown TAR typeflag: '%s'\nWhen extracting \"%s\"."(
                cast(char) blk.typeflag, blk.prefix ~ "/" ~ blk.name
            );
            throw new Exception(msg);
        }
    }

    private static TarInfo decodeHeader(scope ref BlockInfo blk)
    {
        TarInfo info = {
            name: blk.name,
            mode: blk.mode,
            uid: blk.uid,
            gid: blk.gid,
            size: blk.size,
            mtime: SysTime(unixTimeToStdTime(blk.mtime)),
            type: toEntryType(blk.typeflag),
            linkname: blk.linkname,
            uname: blk.uname,
            gname: blk.gname,
            devmajor: blk.devmajor,
            devminor: blk.devminor,

            entrySize: blockLen + next512(blk.size),
            isNull: false,
        };

        if (blk.prefix.length != 0)
        {
            info.name = blk.prefix ~ "/" ~ blk.name;
        }

        version (Posix)
        {
            // tar mode contains stat.st_mode & 07777.
            // we have to add the missing flags corresponding to file type
            // (and by no way tar mode is meaningful on Windows)
            const filetype = posixModeFileType(blk.typeflag);
            info.mode |= filetype;
        }
        else version (Windows)
        {
            info.name = info.name.replace('\\', '/');
            info.linkname = info.linkname.replace('\\', '/');
        }

        return info;
    }

    private static TarInfo decodeGnuLongHeader(Cursor cursor, scope ref BlockInfo blk)
    {
        auto data = new char[next512(blk.size)];
        enforce(cursor.read(data).length == data.length, "Unexpected end of input");
        const name = parseString(assumeUnique(data));

        auto next = TarInfo.decode(cursor);
        next.entrySize += (blockLen + data.length);

        switch (blk.typeflag)
        {
        case Typeflag.gnuLongname:
            next.name = name;
            break;
        case Typeflag.gnuLonglink:
            next.linkname = name;
            break;
        default:
            assert(false);
        }

        if (next.type == EntryType.directory && !next.name.empty && next.name[$ - 1] == '/')
            next.name = next.name[0 .. $ - 1];

        return next;
    }
}

/// Splits long name into prefix and shorter name if it the name exceeds
/// the length of the tar header name field.
/// If the name is longer than prefix + name fields length, name is returned
/// unchanged.
/// On Windows, the path must be converted to Posix path (with '/' separator)
/// Returns: [prefix, name]
string[2] splitLongName(string name)
{
    if (name.length < nameLen)
        return [null, name];
    if (name.length > nameLen + prefixLen)
        return [null, name];

    foreach (i; 0 .. name.length)
    {
        if (name[i] == '/')
        {
            const p = name[0 .. i];
            const n = name[i + 1 .. $];
            if (p.length <= prefixLen && n.length <= nameLen)
                return [p, n];
        }
    }

    return [null, name];
}

@("tar.splitPrefixName")
unittest
{
    enum shortPath = "some/short/path";
    enum veryLongPath = "some/very/long/long/long/long/long/long/long/long/long/long/long"
        ~ "/long/long/long/long/long/long/long/long/long/long/long/long/long/long/long/long"
        ~ "/long/long/long/long/long/long/long/long/long/long/long/long/long/long/long/long"
        ~ "/long/long/long/long/long/long/long/long/long/long/long/long/long/long/long/long"
        ~ "/long/long/long/long/long/long/long/long/long/path";

    enum longPath = "some/long/long/long/long/long/long/long/long/long/long/long"
        ~ "/long/long/long/long/long/long/long/long/long/long/long/long/long/long/path";
    enum longPrefix = "some/long/long/long/long/long/long";
    enum longName = "long/long/long/long/long/long/long/long/long/long/long/long/long/long/long"
        ~ "/long/long/long/long/path";

    static assert(veryLongPath.length > 255);
    static assert(longPath.length > 100);
    static assert(longPath.length < 155);

    assert(splitLongName(shortPath) == [null, shortPath]);
    assert(splitLongName(veryLongPath) == [null, veryLongPath]);
    assert(splitLongName(longPath) == [longPrefix, longName]);
}

struct TarBox(I)
{
    I entries;
    size_t chunkSize;

    size_t written;
    ubyte[] buffer;
    const(ubyte)[] chunk;

    // current entry being processed
    ubyte[] remainHeader;
    BoxEntry entry;
    ByteRange entryChunks;
    const(ubyte)[] entryChunk;
    size_t padSize;

    // footer
    size_t footerSize;

    this(I entries, size_t chunkSize)
    {
        import std.algorithm : max;

        this.entries = entries;
        this.chunkSize = chunkSize;
        this.buffer = new ubyte[max(512, chunkSize)];
        this.footerSize = blockLen * 2;

        popFront();
    }

    @property bool empty()
    {
        return chunk.length == 0;
    }

    @property ByteChunk front()
    {
        return chunk;
    }

    void popFront()
    {
        chunk = null;
        scope (success)
        {
            written += chunk.length;
        }

        while (!remainHeader.empty || padSize != 0 || hasEntryChunks || !entries.empty)
        {
            if (nextRemainHeader())
                return;

            if (fillPad())
                return;

            if (nextEntryChunk())
                return;

            if (nextHeader())
                return;
        }

        footerSize -= fillZeros(footerSize);
    }

    private size_t pos()
    {
        return written + chunk.length;
    }

    private bool hasEntryChunks()
    {
        return (entryChunks && !entryChunks.empty) || !entryChunk.empty;
    }

    private bool nextHeader()
    {
        import std.algorithm : min;

        assert(chunk.length < chunkSize);
        assert(remainHeader.empty);
        assert(!hasEntryChunks);

        if (entries.empty)
            return false;

        entry = entries.front;
        entries.popFront();
        entryChunks = entry.byChunk(chunkSize);
        if (!entryChunks.empty)
            entryChunk = entryChunks.front;

        // common fields
        TarInfo info = {
            name: entry.path,
            size: entry.size,
            mtime: entry.timeLastModified,
            type: entry.type,
            linkname: entry.linkname,
        };

        version (Posix)
        {
            import core.sys.posix.grp;
            import core.sys.posix.pwd;
            import core.stdc.string : strlen;
            import std.conv : octal;

            char[512] buf;

            info.mode = entry.attributes & octal!7777;
            info.uid = entry.ownerId;
            info.gid = entry.groupId;

            if (info.uid != 0)
            {
                passwd pwdbuf;
                passwd* pwd;
                if (getpwuid_r(info.uid, &pwdbuf, buf.ptr, buf.length, &pwd) == 0)
                {
                    const len = min(strlen(pwd.pw_name), unameLen);
                    info.uname = pwd.pw_name[0 .. len].idup;
                }
            }
            if (info.gid != 0)
            {
                group grpbuf;
                group* grp;
                if (getgrgid_r(info.gid, &grpbuf, buf.ptr, buf.length, &grp) == 0)
                {
                    const len = min(strlen(grp.gr_name), unameLen);
                    info.gname = grp.gr_name[0 .. len].idup;
                }
            }
        }
        else version (Windows)
        {
            // default to mode 644 which is the most common on UNIX
            info.mode = "0000644";
            // TODO: https://docs.microsoft.com/fr-fr/windows/win32/secauthz/finding-the-owner-of-a-file-object-in-c--
        }

        const len = info.encode(buffer, chunk.length);
        assert(buffer.length >= chunk.length + len);

        const chunkTo = min(chunk.length + len, chunkSize);
        if (chunk.length + len > chunkSize)
            remainHeader = buffer[chunkSize .. chunk.length + len];

        chunk = buffer[0 .. chunkTo];
        return chunkTo == chunkSize;
    }

    // fill chunk with what remains of previous header (if any)
    private bool nextRemainHeader()
    {
        import std.algorithm : min;

        if (remainHeader.empty)
            return false;

        if (chunk.empty && remainHeader.length > chunkSize)
        {
            chunk = remainHeader[0 .. chunkSize];
            remainHeader = remainHeader[chunkSize .. $];
            return true;
        }

        const len = min(chunkSize - chunk.length, remainHeader.length);
        buffer[chunk.length .. chunk.length + len] = remainHeader[0 .. len];
        remainHeader = remainHeader[len .. $];
        chunk = buffer[0 .. chunk.length + len];

        return chunk.length == chunkSize;
    }

    // fill chunk with next chunk of current entry
    private bool nextEntryChunk()
    {
        import std.algorithm : min;

        assert(chunk.length < chunkSize);
        assert(padSize == 0);
        assert(remainHeader.empty);

        while (hasEntryChunks() && chunk.length < chunkSize)
        {
            if (entryChunk.empty)
            {
                entryChunks.popFront();
                if (!entryChunks.empty)
                    entryChunk = entryChunks.front;

                if (entryChunk.empty)
                    break;
            }

            if (chunk.empty && entryChunk.length >= chunkSize)
            {
                // can directly use entryChunk without copying
                chunk = entryChunk[0 .. chunkSize];
                entryChunk = entryChunk[chunkSize .. $];
                break;
            }

            // copy slice into buffer
            const len = min(chunkSize - chunk.length, entryChunk.length);
            buffer[chunk.length .. chunk.length + len] = entryChunk[0 .. len];
            chunk = buffer[0 .. chunk.length + len];
            entryChunk = entryChunk[len .. $];
        }

        if (!hasEntryChunks())
        {
            padSize = next512(pos) - pos;
            padSize -= fillZeros(padSize);
        }

        return chunk.length == chunkSize;
    }

    size_t fillZeros(size_t zeros)
    {
        import std.algorithm : min;

        const len = min(chunkSize - chunk.length, zeros);
        buffer[chunk.length .. chunk.length + len] = 0;
        chunk = buffer[0 .. chunk.length + len];
        return len;
    }

    bool fillPad()
    {
        if (padSize != 0)
            padSize -= fillZeros(padSize);

        return chunk.length == chunkSize;
    }
}

static assert(isByteRange!(TarBox!(BoxEntry[])));

private struct TarUnbox
{
    private Cursor _input;

    // current header data
    private size_t _next;
    private UnboxEntry _entry;
    private Flag!"removePrefix" _removePrefix;
    private string _prefix;

    this(Cursor input, Flag!"removePrefix" removePrefix)
    {
        _input = input;
        _removePrefix = removePrefix;

        if (!_input.eoi)
            popFront();
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

        _entry = null;

        if (_input.pos < _next)
        {
            // the current entry was not fully read, we move the stream forward
            // up to the next header
            const dist = _next - _input.pos;
            _input.ffw(dist);
        }

        auto info = TarInfo.decode(_input);

        if (info.isNull)
        {
            while (!_input.eoi)
                _input.ffw(512);
            return;
        }

        if (_removePrefix)
        {
            info.name = removePrefix(info.name, info.type);

            // skipping empty directory
            while (!info.name.length && info.type == EntryType.directory)
            {
                info = TarInfo.decode(_input);
                info.name = removePrefix(info.name, info.type);
            }
        }

        _entry = new TarUnboxEntry(_input, info);
        _next = next512(_input.pos + info.size);
    }

    private string removePrefix(string name, EntryType type)
    {
        import std.algorithm : min;

        const pref = enforce(entryPrefix(name, type), format!`"%s": no prefix to be removed`(
                name));

        if (!_prefix)
            _prefix = pref;

        enforce(_prefix == pref, format!`"%s": path prefix mismatch with "%s"`(name, _prefix));

        const len = min(name.length, _prefix.length);
        name = name[len .. $];

        return name;
    }
}

static assert(isUnboxEntryRange!TarUnbox);

private class TarUnboxEntry : UnboxEntry
{
    import std.stdio : File;

    private Cursor _input;
    private size_t _start;
    private size_t _end;
    private TarInfo _info;

    this(Cursor input, TarInfo info)
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
        return _info.name;
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
        return _info.mtime;
    }

    @property uint attributes()
    {
        return _info.mode;
    }

    version (Posix)
    {
        @property int ownerId()
        {
            return _info.uid;
        }

        @property int groupId()
        {
            return _info.gid;
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

    sformat(buf[0 .. $ - 1], "%0*o", buf.length - 1, val);
    buf[$ - 1] = '\0';
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

private inout(char)[] parseString(inout(char)[] chars)
{
    // function similar to strnlen, but operate on slices.
    size_t count;
    while (count < chars.length && chars[count] != '\0')
        count++;
    return chars[0 .. count];
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
