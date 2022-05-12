module squiz_box.util;

import squiz_box.squiz;
import squiz_box.priv;

/// Helper that return a range of binary chunks of data from a file.
auto readBinaryFile(string filename, size_t chunkSize = defaultChunkSize)
{
    import std.stdio : File;

    return ByChunkImpl(File(filename, "rb"), chunkSize);
}

/// Helper that eagerly writes binary chunks of data to a file.
void writeBinaryFile(I)(I input, string filename) if (isByteRange!I)
{
    import std.algorithm : copy;
    import std.stdio : File;

    input.copy(File(filename, "wb").lockingBinaryWriter);
}
