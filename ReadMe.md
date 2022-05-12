# Squiz-Box

A D library that handles compression / decompression and archiving.

## Compression / decompression

The compression is designed to work with ranges, which makes it suitable
for streaming and for transforming data from any kind of source to
any kind of destination.

### Algorithms and formats

An algorithm refers to the compression algorithm properly, and format refers
to a header and a trailer attached to the compressed data that gives information
about decompression parameters and integrity checking.
A raw format refers to data compressed without such header and trailer and can
be used inside an externally defined format (e.g. game networking protocol).

| Algorithms | Squiz structs | Available formats |
|-----|----|----|
| Deflate | `Deflate` (compression), `Inflate` (decompression) | Zlib, Gzip, Raw |
| Bzip2   | `CompressBzip2`, `DecompressBzip2` | Bzip2           |
| LZMA1 (legacy compression) | `CompressLzma`, `DecompressLzma` | Xz, Lzma (legacy format), Raw |
| LZMA (aka. LZMA2)   | `CompressLzma`, `DecompressLzma` | Xz, Raw |

In addition, the LZMA and LZMA2 compression also support additional filters
that transorm the data before the compression stage in order to increase
the compression ratio:

- Delta
  - higher compression of repetitive binary data such as audio PCM, RGB...
- BCJ (Branch/Call/Jump)
  - higher compression of compiled executable
  - available for a set of architectures (X86, ARM, ...)

### API

Algorithms are represented by structs that share a common interface.
Constructed objects from those structs carry parameters for compression / decompression
and can instantiate a stream (class that derives `SquizStream`) that will carry the
necessary state as well as input and output buffer.

To process these algorithms and streams as D ranges, you use the `squiz` function.
The `squiz` function works for both compression and decompression and there are many
helpers built upon it (`deflate`, `inflate`, `compressXz`, ...).
See code examples below for usage.

## Archiving

Whenever possible, archving and de-archiving are implemented as the
transformation of a range of file entries to a range of bytes.
It is never required to have the full archive in memory at the same time,
so it is possible to create or extract archives of dozens of giga-bytes with
minimal memory foot print.

The following formats are supported:
- Tar
- Zip

There is also WIP for 7z.

### API

README TO BE WRITTEN

## Code examples

### Compress data with zlib
```d
import squiz_box.squiz;
import std.range;

const ubyte[] data = myDataToCompress();
auto algo = Deflate.init; // defaults to zlib format and compression level 6

only(data)              // InputRange of const(ubyte)[] (uncompressed)
  .squiz(algo)          // also InputRange of const(ubyte)[] (deflated)
  .sendOverNetwork();

// the following code is equivalent
only(data)
  .deflate()
  .sendOverNetwork();
```

### Re-inflate data with zlib
```d
import squiz_box.squiz;
import std.array;

const data = receiveFromNetwork() // InputRange of const(ubyte)[]
  .inflate()
  .join();                        // const(ubyte)[]
```

### Full control over the streaming process

Sometimes, D range are not practical. Think of a receiver thread that
receives data, compresses it and sends it over network with low latency.
You will not wait to receive the full data before start streaming, and
a D range is probably not well suited to receive the data from a different
thread. In that situation you can use the streaming API directly.

The following code gives the spirit of it.
```d
import squiz_box.squiz;

// Deflate is a good fit for low latency streaming
auto algo = Deflate.init;
auto stream = algo.initialize();

// repeat for as many chunks of memory as necessary
stream.input = dataChunk;
stream.output = buffer;
auto streamEnded = algo.process(stream, No.lastChunk);
// send buffer content out
// at some point we send the last chunk and receive notification that the stream is done.

// reset the stream, but keep the allocated resources for next round
algo.reset(stream);
// more streaming...

// finally we can release the resources
// (most of which are allocated with GC)
algo.end(stream);
```
