module squiz_box.box.seven_z.utils;

package(squiz_box.box.seven_z):

import squiz_box.box.seven_z.error;
import squiz_box.priv;

import std.bitmanip;
import std.format;
import std.range;
import io = std.stdio;
import std.typecons;

auto trace7z(alias fun)(string func = __FUNCTION__)
{
    enum doTrace = false;

    static if (doTrace)
    {
        auto d = fun();
        io.writefln!"%s:\n    %#s\n"(func, d);
        return d;
    }
    else
    {
        return fun();
    }
}

struct Crc32
{
    private uint crc;

    bool opEquals(uint value) const
    {
        return crc == value;
    }

    bool opEquals(Crc32 value) const
    {
        return crc == value.crc;
    }

    uint opCast(T : uint)() const
    {
        return crc;
    }

    bool opCast(T : bool)() const
    {
        return crc != 0;
    }

    size_t toHash() const nothrow @safe
    {
        return hashOf(crc);
    }

    string toString() const
    {
        return format!"Crc32(%08X)"(crc);
    }

    static Crc32 calc(const(ubyte)[] data, Crc32 seed = Crc32(0)) @trusted
    {
        import squiz_box.c.zlib : crc32;

        return Crc32(crc32(seed.crc, data.ptr, cast(uint) data.length));
    }

    static Crc32 calc(const(ubyte)* dataPtr, size_t dataLen, Crc32 seed = Crc32(0)) @trusted
    {
        import squiz_box.c.zlib : crc32;

        return Crc32(crc32(seed.crc, dataPtr, cast(uint) dataLen));
    }
}

Crc32 readCrc32(C)(C cursor)
{
    return Crc32(cursor.getValue!uint);
}

const(ubyte)[] readArray(C)(C cursor, size_t len, string msg = null)
        if (is(C : Cursor))
{
    static if (is(C : ArrayCursor))
    {
        auto res = cursor.readInner(len);
    }
    else
    {
        auto buf = new ubyte[len];
        auto res = cursor.read(buf);
    }

    if (res.length != len)
        bad7z(cursor.source, msg ? msg : "not enough bytes");

    return res;
}

uint readUint32(C)(C cursor)
{
    static immutable ubyte[] lenb = [
        0b0111_1111,
        0b1011_1111,
        0b1101_1111,
        0b1110_1111,
        0b1111_0111,
        0b1111_1011,
        0b1111_1101,
        0b1111_1110,
        0b1111_1111,
    ];
    const b0 = cursor.get;
    if (b0 <= lenb[0])
    return b0;

    uint mask = 0xc0;
    uint len = 1;

    foreach (b; lenb[1 .. $])
    {
        if (b0 <= b)
            break;
        len++;
        mask |= mask >> 1;
    }

    enforce(len <= 3, "Number cannot be represented in 32 bits");

    const uint masked = b0 & ~mask;

    LittleEndian!4 bn;
    enforce(cursor.read(bn.data[0 .. len]).length == len, "Not enough bytes");

    return bn.val | ((b0 & masked) << (len * 8));
}

@("readUint32")
unittest
{
    uint read(ubyte[] pattern)
    {
        auto cursor = new ArrayCursor(pattern);
        return readUint32(cursor);
    }

    assert(read([0x27, 0x27, 0x27, 0x27, 0x27]) == 0x27);
    assert(read([0xa7, 0x27, 0x27, 0x27, 0x27]) == 0x2727);
    assert(read([0xc7, 0x27, 0x27, 0x27, 0x27]) == 0x07_2727);
    assert(read([0xe7, 0x27, 0x27, 0x27, 0x27]) == 0x0727_2727);
    assertThrown(read([0xf7, 0x27, 0x27, 0x27, 0x27]));
}

ulong readUint64(C)(C cursor)
{
    static immutable ubyte[] lenb = [
        0b0111_1111,
        0b1011_1111,
        0b1101_1111,
        0b1110_1111,
        0b1111_0111,
        0b1111_1011,
        0b1111_1101,
        0b1111_1110,
        0b1111_1111,
    ];
    const b0 = cursor.get;
    if (b0 <= lenb[0])
    return b0;

    uint mask = 0xc0;
    uint len = 1;

    foreach (b; lenb[1 .. $])
    {
        if (b0 <= b)
            break;
        len++;
        mask |= mask >> 1;
    }

    const ulong masked = b0 & ~mask;

    LittleEndian!8 bn;
    enforce(cursor.read(bn.data[0 .. len]).length == len, "Not enough bytes");

    auto val = bn.val;
    if (len <= 6)
        val |= (b0 & masked) << (len * 8);
    return val;

}

@("readUint64")
unittest
{
    ulong read(ubyte[] pattern)
    {
        auto cursor = new ArrayCursor(pattern);
        return readUint64(cursor);
    }

    assert(read([0x27, 0x27, 0x27, 0x27, 0x27, 0x27, 0x27, 0x27, 0x27]) == 0x27);
    assert(read([0xa7, 0x27, 0x27, 0x27, 0x27, 0x27, 0x27, 0x27, 0x27]) == 0x2727);
    assert(read([0xc7, 0x27, 0x27, 0x27, 0x27, 0x27, 0x27, 0x27, 0x27]) == 0x07_2727);
    assert(read([0xe7, 0x27, 0x27, 0x27, 0x27, 0x27, 0x27, 0x27, 0x27]) == 0x0727_2727);
    assert(read([0xf7, 0x27, 0x27, 0x27, 0x27, 0x27, 0x27, 0x27, 0x27]) == 0x07_2727_2727);
    assert(read([0xfb, 0x27, 0x27, 0x27, 0x27, 0x27, 0x27, 0x27, 0x27]) == 0x0327_2727_2727);
    assert(read([0xfd, 0x27, 0x27, 0x27, 0x27, 0x27, 0x27, 0x27, 0x27]) == 0x01_2727_2727_2727);
    assert(read([0xfe, 0x27, 0x27, 0x27, 0x27, 0x27, 0x27, 0x27, 0x27]) == 0x0027_2727_2727_2727);
    assert(read([0xff, 0x27, 0x27, 0x27, 0x27, 0x27, 0x27, 0x27, 0x27]) == 0x2727_2727_2727_2727);
}

void writeUint64(WC)(WC cursor, ulong number)
{
    static immutable ulong[] lenn = [
        0x7f,
        0x3fff,
        0x1f_ffff,
        0x0fff_ffff,
        0x07_ffff_ffff,
        0x03ff_ffff_ffff,
        0x01_ffff_ffff_ffff,
        0xff_ffff_ffff_ffff,
        0xffff_ffff_ffff_ffff,
    ];

    // shortcut
    if (number <= lenn[0])
    {
        cursor.put(cast(ubyte) number);
        return;
    }

    ubyte b0 = 0x80;
    uint b0mask = 0xc0;
    ulong bnmask = 0xff;
    uint len = 1;
    foreach (n; lenn[1 .. $])
    {
        if (number <= n)
            break;
        b0 |= b0 >> 1;
        b0mask |= b0mask >> 1;
        bnmask |= bnmask << 8;
        len++;
    }

    LittleEndian!8 le = number & bnmask;

    if (len <= 6)
        b0 |= (number >> len * 8) & ~b0mask;
    cursor.put(b0);
    cursor.write(le.data[0 .. len]);
}

@("writeUint64")
unittest
{
    const(ubyte)[] write(ulong number)
    {
        auto cursor = new ArrayWriteCursor();
        writeUint64(cursor, number);
        return cursor.data;
    }

    assert([0x27] == write(0x27));
    assert([0xa7, 0x27] == write(0x2727));
    assert([0xc7, 0x27, 0x27] == write(0x07_2727));
    assert([0xe7, 0x27, 0x27, 0x27] == write(0x0727_2727));
    assert([0xf7, 0x27, 0x27, 0x27, 0x27] == write(0x07_2727_2727));
    assert([0xfb, 0x27, 0x27, 0x27, 0x27, 0x27] == write(0x0327_2727_2727));
    assert([0xfd, 0x27, 0x27, 0x27, 0x27, 0x27, 0x27] == write(0x01_2727_2727_2727));
    assert([0xfe, 0x27, 0x27, 0x27, 0x27, 0x27, 0x27, 0x27] == write(0x0027_2727_2727_2727));
    assert([0xff, 0x27, 0x27, 0x27, 0x27, 0x27, 0x27, 0x27, 0x27] == write(
        0x2727_2727_2727_2727));
}

BitArray readBitField(C)(C cursor, size_t count)
{
    BitArray res;
    res.length = count;

    ubyte b;
    ubyte mask;
    foreach (i; 0 .. count)
    {
        if (mask == 0)
        {
            b = cursor.get;
            mask = 0x80;
        }
        res[i] = (b & mask) != 0;
        mask >>= 1;
    }
    return res;
}

BitArray readBooleanList(C)(C cursor, size_t count)
{
    // check all-defined in a single bool
    if (cursor.get != 0)
    {
        BitArray res;
        res.length = count;
        res.flip();
        return res;
    }

    // otherwise it is a bitfield
    return cursor.readBitField(count);
}
