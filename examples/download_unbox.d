#!/usr/bin/env dub
/+ dub.sdl:
    name "download_unbox"
    description "an example for squiz-box: download, list and extract archive"
    dependency "squiz-box" path=".."
    dependency "requests" version="~>2.1.1"
+/

module examples.download_unbox;

import squiz_box;
import requests;

import std.algorithm;
import std.getopt;
import std.file;
import std.path;
import std.range;
import std.stdio;

void main(string[] args)
{
    string url = "https://github.com/dlang/dmd/archive/master.tar.gz";
    string dest;

    auto opts = getopt(args,
        "url", "URL of archive to download", &url,
        "dest", "The destination directory. Extracted files will disappear if not specified.", &dest,
    );

    if (opts.helpWanted)
    {
        defaultGetoptPrinter("Squiz-box, download, list and extract archive", opts.options);
    }

    const outDir = dest.length ? dest : buildPath(tempDir, "squiz-box-example");

    if (!exists(outDir))
        mkdirRecurse(outDir);

    scope(success)
    {
        if (!dest)
            rmdirRecurse(outDir);
    }

    // Algorithm matched at runtime with url (using extension)
    auto algo = boxAlgo(url);

    writefln!"GET %s"(url);

    size_t dataSz;
    size_t numFiles;

    auto rq = Request();
    rq.useStreaming = true;
    rq.get(url).receiveAsRange()
        .map!(c => cast(const(ubyte)[])c)
        .tee!(c => stderr.writefln!"received %s bytes"(c.length))
        .tee!(c => dataSz += c.length)
        .unbox(algo)
        .tee!(e => stdout.writeln(buildPath(dest, e.path)))
        .tee!(e => numFiles += 1)
        .each!(e => e.extractTo(outDir));

    writefln!"Downloaded %s bytes. Extracted %s files."(dataSz, numFiles);
}
