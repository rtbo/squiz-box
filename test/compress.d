module test.compress;

import test.archive;
import test.util;
import squiz_box.xz;

@("Compress XZ")
unittest
{
    import std.algorithm : copy;
    import std.stdio : File;

    auto archive = DeleteMe("archive", ".tar.xz");

    auto tarF = File(testPath("data/archive.tar"), "rb");
    auto tarXzF = File(archive.path, "wb");

    enum bufSize = 8192;

    tarF.byChunk(bufSize)
        .compressXz(6, bufSize)
        .copy(tarXzF.lockingBinaryWriter);

    tarF.close();
    tarXzF.close();

    testArchiveContent(archive.path);
}
