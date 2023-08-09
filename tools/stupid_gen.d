/// Discover unittests and generate stupid test driver
module tools.stupid_gen;

import std.algorithm;
import std.array;
import std.getopt;
import std.file;
import std.path;
import std.stdio;
import std.string;

/// return module name of the D file at filename
/// only if it contains "unittest"
string getUnittestMod(string filename)
{
    string mod;
    auto file = File(filename, "r");
    foreach (l; file.byLine.map!(l => l.strip))
    {
        // reasonable assumption about how module is defined
        if (!mod && l.startsWith("module ") && l.endsWith(";"))
        {
            mod = l["module ".length .. $ - 1].strip().idup;
            continue;
        }
        if (mod && l.canFind("unittest"))
        {
            return mod;
        }
    }
    return null;
}

int main(string[] args)
{
    string root = ".";
    string[] exclusions;

    auto helpInfo = getopt(args, "root", &root, "exclude", &exclusions);
    if (helpInfo.helpWanted)
    {
        defaultGetoptPrinter("Generate stupid test driver.", helpInfo.options);
        return 0;
    }

    string[] mods;

    string[] dFiles = args[1 .. $];
    if (args.length == 0)
    {
        dFiles = dirEntries(root, SpanMode.depth).filter!(f => f.name.endsWith(".d"))
            .map!(e => e.name)
            .array;
    }

    outer: foreach (f; dFiles)
    {
        foreach (ex; exclusions)
        {
            if (f.canFind(ex))
                continue outer;
        }

        const m = getUnittestMod(f);
        if (m)
        {
            mods ~= m;
        }
    }

    mods = mods.sort().uniq().array;

    const tmplate = import("stupid.d.in");

    foreach (inl; lineSplitter(tmplate))
    {
        if (!inl.startsWith("// TESTED MODULES HERE"))
        {
            writeln(inl);
            continue;
        }

        foreach (m; mods)
        {
            writefln("import %s;", m);
        }
        writefln("");
        writefln("alias allModules = AliasSeq!(");
        foreach (m; mods)
        {
            writefln("    %s,", m);
        }
        writefln(");");

    }
    writefln("");

    return 0;
}
