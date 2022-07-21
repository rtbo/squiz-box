# Squiz-Box

A D library that handles compression / decompression and archiving.

In the Squiz-Box terminology, `squiz` refers to compression/decompression, while `box` refers to
archiving. Squiz-Box API consists almost exclusively on range algorithms.
`squiz` related algorithms map a range of bytes to another range of bytes where one is the compressed stream of the other. `box` and `unbox` related algorithms map a range of file entries to/from a range of bytes.

Squiz-Box provides both compile time known structures and dynamic types over all algorithms.
## Compression / decompression

The range based design makes _squizing_ suiatble for streaming and for
transforming data from any kind of source to any kind of destination.

### Algorithms and formats

An algorithm refers to the compression algorithm properly, and format refers
to a header and a trailer attached to the compressed data that gives information
about decompression parameters and integrity checking.
A raw format refers to data compressed without such header and trailer and can
be used only in applications or archive that know how to decompress the stream by other means.

| Algorithms | Squiz structs | Available formats |
|-----|----|----|
| Deflate | `Deflate` (compression), `Inflate` (decompression) | Zlib, Gzip, Raw |
| Bzip2   | `CompressBzip2`, `DecompressBzip2` | Bzip2           |
| LZMA1 (legacy compression) | `CompressLzma`, `DecompressLzma` | Xz, Lzma (legacy format), Raw |
| LZMA (aka. LZMA2)   | `CompressLzma`, `DecompressLzma` | Xz, Raw |
| Zstandard | `CompressZstd`, `DecompressZstd` | Zstandard |

In addition, the LZMA1 and LZMA compression also support additional filters
that transorm the data before the compression stage in order to increase
the compression ratio:

- Delta
  - higher compression of repetitive binary data such as audio PCM, RGB...
- BCJ (Branch/Call/Jump)
  - higher compression of compiled executable
  - available for different architectures (X86, ARM, ...)

### API

Algorithms are represented by structs that share a common interface.
Constructed objects from those structs carry parameters for compression / decompression
and can instantiate a stream (class that derives `SquizStream`) that will carry the
necessary state as well as input and output buffer.

To process these algorithms and streams as D ranges, you use the `squiz` function.
The `squiz` function works for both compression and decompression and there are many
helpers built upon it (`deflate`, `inflate`, `compressXz`, ...).
See code examples below for usage.

## Archiving (Boxing)

Whenever possible, archving and de-archiving are implemented as the
transformation of a range of file entries to a range of bytes.
It is never required to have the full archive in memory at the same time,
so it is possible to create or extract archives of dozens of giga-bytes with
minimal memory foot print.

The following formats are supported:
- Tar (including `.tar.gz`, `.tar.bz2`, `.tar.xz`)
- Zip

There is also WIP for 7z.

Archive update is not supported at this stage.

## Code examples

### Compress data with zlib
```d
import squiz_box;
import std.range;

const ubyte[] data = myDataToCompress();

auto algo = Deflate.init; // defaults to zlib format

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
import squiz_box;
import std.array;

const data = receiveFromNetwork() // InputRange of const(ubyte)[]
  .inflate()
  .join();                        // const(ubyte)[]
```

### Create an archive from a directory

Zip a directory:

```d
import squiz_box;

import std.algorithm;
import std.file;

const root = buildNormalizedPath(someDir);

dirEntries(root, SpanMode.breadth, false)
    .filter!(e => !e.isDir)
    .map!(e => fileEntry(e.name, root, null))    // range of FileBoxEntry
    .boxZip()                                    // range of bytes
    .writeBinaryFile("some-dir.zip");
```

Create a `.tar.xz` file from a directory (with little bit more control):

```d
import squiz_box;

import std.algorithm;
import std.file;
import std.path;

const root = squizBoxDir;

// prefix all files path in the archive
// don't forget the trailing '/'!
const prefix = "squiz-box-12.5/";

const exclusion = [".git", ".dub", ".vscode", "libsquiz-box.a", "build"];

dirEntries(root, SpanMode.breadth, false)
    .filter!(e => !e.isDir)
    .filter!(e => !exclusion.any!(ex => e.name.canFind(ex)))
    .map!(e => fileEntry(e.name, root, prefix))
    .boxTar()
    .compressXz()
    .writeBinaryFile("squiz-box-12.5.tar.xz");
```

### Extract an archive into a directory

```d
import squiz_box;

const archive = "my-archive.tar.gz";
const extractionSite = "some-dir";

mkdir(extractionSite);

readBinaryFile(archive)
    .inflateGz()
    .unboxTar()                               // range of UnboxEntry
    .each!(e => e.extractTo(extractionSite));
```

### Compression/Decompression with algorithm known at runtime

```d
import squiz_box;

// SquizAlgo is a D interface
// it must be instantiated from a compile-time known algorithm
SquizAlgo algo = squizAlgo(Deflate.init);

// the rest is the same as previously

const ubyte[] data = myDataToCompress();

only(data)
  .squiz(algo)
  .sendOverNetwork();
```

### Boxing/Unboxing with algorithm known at runtime

```d
import squiz_box;

import std.algorithm;
import std.file;
import std.path;

const filename = "squiz-box-12.5.tar.xz";

/// BoxAlgo is a D interface
/// It can be instantiated from a filename with archive extension
/// or directly with the implementing classes (ZipBox, TarXzBox, ...)
BoxAlgo algo = BoxAlgo.fromFilename(filename);

/// the rest is (almost) the same as before

const root = squizBoxDir;

// prefix all files path in the archive
// don't forget the trailing '/'!
const prefix = "squiz-box-12.5/";

const exclusion = [".git", ".dub", ".vscode", "libsquiz-box.a", "build"];

// no need to collect entries in an array
auto entries = dirEntries(root, SpanMode.breadth, false)
    .filter!(e => !e.isDir)
    .filter!(e => !exclusion.any!(ex => e.name.canFind(ex)))
    .map!(e => fileEntry(e.name, root, prefix));

// algo.box is a template function that can receive any range of BoxEntry
algo.box(entries).writeBinaryFile(filename);
```

### Full control over the streaming process

Sometimes, D ranges are not practical. Think of a receiver thread that
receives data, compresses it and sends it over network with low latency.
You will not wait to receive the full data before to start streaming, and
a D range is probably not well suited to receive the data from a different
thread. In that situation you can use the streaming API directly.

The following code gives the spirit of it.

```d
import squiz_box;

// Zstandard is a good fit for low latency streaming
auto algo = CompressZstd.init;
auto stream = algo.initialize();

// repeat for as many chunks of memory as necessary
stream.input = dataChunk;
stream.output = buffer;
auto streamEnded = algo.process(stream, No.lastChunk);
// send buffer content out
// at some point we send the last chunk and receive notification that the stream is done.

// we can reset the stream and keep the allocated resources for a new round
algo.reset(stream);

// more streaming...

// finally we can release the resources
algo.end(stream);
```


## Download, build, install

To use `squiz-box`, the easiest is to use the Dub package from the registry.
On Linux, you will need `liblzma`, `libbz2` and `libzstd` installed.
On Windows, a compiled copy of these libraries is shipped with the package (only Windows 64 bit is supported).

Squiz-box is developped with Meson, which will build the C libraries if they are not found.
If you want to use squiz-box in a Meson project, you can should it as a subproject.

To build, test on Linux:
```sh
meson builddir -Ddefault_library=static
cd builddir
ninja && ./squiz-test
```

To build test on Windows:
```dos
rem Visual Studio prompt is required
rem A script is provided to help this (needs vswhere)
win_env_vs.bat
meson builddir -Ddefault_library=static
cd builddir
ninja && squiz-test.exe
```
