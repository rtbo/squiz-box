module squiz_box.util;

import squiz_box.squiz;
import squiz_box.priv;
import std.range : isOutputRange;

/// Helper that return a range of binary chunks of data from a file.
auto readBinaryFile(string filename, size_t chunkSize = defaultChunkSize)
{
    import std.stdio : File;

    return ByChunkImpl(File(filename, "rb"), chunkSize);
}

/// ditto
auto readBinaryFile(string filename, ubyte[] buffer)
{
    import std.stdio : File;

    return ByChunkImpl(File(filename, "rb"), buffer);
}

/// Helper that eagerly writes binary chunks of data to a file.
void writeBinaryFile(I)(I input, string filename) if (isByteRange!I)
{
    import std.algorithm : copy;
    import std.stdio : File;

    input.copy(File(filename, "wb").lockingBinaryWriter);
}

/// Print hex-dump of the provided data byte-range to the given text output
void hexDump(I, O)(I input, O output)
        if (isByteRange!I && isOutputRange!(O, dchar) && isOutputRange!(O, string))
{
    import std.array : replicate;
    import std.ascii : isPrintable;
    import std.format : format;
    import std.range : iota;

    auto cursor = new ByteRangeCursor!I(input);
    size_t addr;
    ubyte[16] buf;

    output.put(format!"          %( %1x %)  Decoded ASCII\n"(iota(0, 16)));
    while (!cursor.eoi)
    {
        auto data = cursor.read(buf[]);
        output.put(format!"%07x.  %(%02x %)  "(addr >> 4, data));

        if (data.length < 16)
            output.put(replicate("   ", 16 - data.length));

        foreach (b; data)
        {
            if (isPrintable(b) || b == ' ')
                output.put(cast(char)b);
            else
                output.put('.');
        }

        output.put('\n');

        addr += 16;
    }
}
