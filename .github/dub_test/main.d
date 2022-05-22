module main;

import squiz_box;

import std.array;
import std.exception;
import std.range;

auto generateRepetitiveData(size_t byteSize, const(ubyte)[] phrase, size_t chunkSize = 8192)
{
    return RepetitiveDataGen(byteSize, phrase, chunkSize);
}

private struct RepetitiveDataGen
{
    size_t remaining;
    const(ubyte)[] phrase;
    size_t nextC;
    ubyte[] buffer;
    ubyte[] chunk;

    this(size_t byteSize, const(ubyte)[] phrase, size_t chunkSize)
    {
        remaining = byteSize;
        this.phrase = phrase;
        buffer = new ubyte[chunkSize];
        prime();
    }

    @property bool empty()
    {
        return chunk.length == 0;
    }

    @property ByteChunk front()
    {
        return chunk;
    }

    private void prime()
    {
        import std.algorithm : min;

        while (chunk.length < buffer.length && remaining > 0)
        {
            const toBeWritten = phrase[nextC .. $];
            const bufStart = chunk.length;
            const len = min(toBeWritten.length, buffer.length - bufStart, remaining);
            buffer[bufStart .. bufStart + len] = toBeWritten[0 .. len];
            chunk = buffer[0 .. bufStart + len];
            nextC += len;
            if (nextC >= phrase.length)
                nextC = 0;
            remaining -= len;
        }
    }

    void popFront()
    {
        chunk = null;
        prime();
    }
}


void main()
{
    const len = 100_000;
    const phrase = cast(const(ubyte)[]) "Some very repetitive phrase.\n";
    const input = generateRepetitiveData(len, phrase).join();

    const(ubyte)[] squized;
    const(ubyte)[] output;

    void test(string algo)
    {
        enforce(squized.length < input.length, algo ~ " failed to compress");
        enforce(output == input, algo ~ " decompression failed");
    }

    squized = only(input)
        .deflate()
        .join();
    output = only(squized)
        .inflate()
        .join();
    test("Zlib");

    squized = only(input)
        .compressBzip2()
        .join();
    output = only(squized)
        .decompressBzip2()
        .join();
    test("Bzip2");

    squized = only(input)
        .compressXz()
        .join();
    output = only(squized)
        .decompressXz()
        .join();
    test("LZMA Xz");

    squized = only(input)
        .compressZstd()
        .join();
    output = only(squized)
        .decompressZstd()
        .join();
    test("Zstandard");
}
