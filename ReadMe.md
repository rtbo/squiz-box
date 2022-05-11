# Squiz-Box

D library that handle compression/decompression and archiving.

## Compression/decompression

The compression is entirely based on ranges, which makes it suitable
for streaming and for transforming data from any kind of source to
any kind of destination.

### Algorithms and formats

An algorithm refer to the compression algorithm properly, and format refers
to a header and a trailer attached to the compressed data to give information
about decompression parameters and integrity check.
Raw format refers to no header and trailer at all.

| Algorithms | Squiz structs | Available formats |
|-----|----|----|
| Deflate | `Deflate` (compression), `Inflate` (decompression) | Zlib, Gzip, Raw |
| Bzip2   | `CompressBzip2`, `DecompressBzip2` | Bzip2           |
| LZMA (legacy compression) | `CompressLzma`, `DecompressLzma` | Xz, Lzma (legacy format), Raw |
| LZMA2   | `CompressLzma`, `DecompressLzma` | Xz, Raw |

In addition, the LZMA and LZMA2 compression also support additional filters
that transorm the data before the compression stage in order to increase
the compression ratio:

- Delta
  - higher compression of repetitive binary data such as audio PCM, RGB...
- BCJ (Branch/Call/Jump)
  - higher compression of compiled executable
  - available for a set of different architectures (X86, ARM, ...)

### Code example

```d
import squiz_box.squiz;
import std.range;

const ubyte[] data = myDataToCompress();
const chunkSize = 8192; // default chunk size if none specified

// deflate with zlib format
// likely the best choice for low latency streaming
only(data)                  // InputRange of const(ubyte)[]
    .deflate(chunkSize)     // also InputRange of const(ubyte)[]
    .sendOverNetwork();     // figurative function, not included in squiz-box

// create .tar.gz from .tar
// we'll see hereunder how to create .tar file
readBinaryFile("the_file.tar")
    .deflateGz()
    .writeBinaryFile("the_file.tar.gz");

// create .tar.xz from .tar
// We could use `compressXz`, but as we package executables, we add here a BCJ filter.
// For this we use directly the algorithm struct.
CompressLzma compAlgo; // defaults to Xz format
compAlgo.filters ~= LzmaFilter.bcjX86;

generateCompiledReleaseTar()
    // generic function to produce an InputRange of const(ubyte)[] from an algorithm struct.
    // other functions such as `compressXz` or `inflateGz` are built on top of `squiz`.
    .squiz(compAlgo)
    .writeBinaryFile("squiz-box-13.2.0-linux-x86_64.tar.xz");

// Full control over the streaming process.
// (e.g. in a receiver thread that streams data over network)
// The algo object carries the parameters and the stream carries the state.
// Following code gives only the spirit of it. Check documentation for usage details
Deflate algo;
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
// (most if not all are allocated with GC)
algo.end(stream);
```
