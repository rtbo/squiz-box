#!/usr/bin/env dub
/+ dub.sdl:
    name "box_upload"
    description "an example for squiz-box: create archive and upload to the web"
    dependency "squiz-box" path=".."
    dependency "requests" version="~>2.1.1"
+/

module examples.box_upload;

import squiz_box;
import requests;

import std.algorithm;
import std.exception;
import std.getopt;
import std.format;
import std.file;
import std.path;
import std.range;
import std.stdio;

void main(string[] args)
{
    string postTo = "https://httpbin.org/post";
    string fmt = ".tar.xz";
    string src = "..";
    string prefix;

    auto opts = getopt(args,
        "post-to", &postTo,
        "format", &fmt,
        "src", &src,
        "prefix", &prefix,
    );

    if (opts.helpWanted)
    {
        defaultGetoptPrinter("Squiz-box example, create archive, list and upload", opts.options);
    }

    // Algorithm matched at runtime (using extension)
    auto algo = boxAlgo(fmt);

    size_t numFiles;
    size_t dataSz;

    const exclusion = [".git", ".dub", ".vscode", "libsquiz-box.a", "build"];

    auto archiveChunks = dirEntries(src, SpanMode.breadth, false)
        .filter!(e => !e.isDir)
        .filter!(e => !exclusion.any!(ex => e.name.canFind(ex)))
        .tee!(e => stdout.writeln(e.name))
        .tee!(e => numFiles += 1)
        .map!(e => fileEntry(e.name, src, prefix))
        .box(algo)
        .tee!(c => stderr.writefln!"uploaded %s bytes"(c.length))
        .tee!(c => dataSz += c.length);

    auto rq = Request();
    auto resp = rq.post(postTo, archiveChunks, algo.mimetype);
    enforce(resp.code < 300, format!"%s responded %s"(postTo, resp.code));

    writefln!"POST %s - status %s"(postTo, resp.code);
    writefln!"Archived %s files. Uploaded %s bytes"(numFiles, dataSz);
}
