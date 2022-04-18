module squiz_box.core;

version (Posix)
{
    import core.sys.posix.unistd;
    import core.sys.posix.sys.stat;
}

interface ArchiveCreateMember
{
    @property string path() const;
    @property size_t size() const;
    @property long mtime() const;

    version (Posix)
    {
        @property stat_t stat() const;
    }

    ubyte[] read(ubyte[] buffer);
}

class ArchiveCreateMemberPath : ArchiveCreateMember
{
    import std.stdio : File;

    string filePath;
    string archivePath;
    File file;

    this (string filePath, string archivePath)
    {
        if (!archivePath)
        {
            archivePath = filePath;
        }
        this.filePath = filePath;
        this.archivePath = archivePath;
        this.file = File(filePath, "rb");
    }

    @property string path() const
    {
        return archivePath;
    }

    @property size_t size() const
    {
        import std.file : getSize;

        return getSize(filePath);
    }

    @property long mtime() const
    {
        import std.file : timeLastModified;

        return timeLastModified(filePath).toUnixTime!long();
    }

    version(Posix)
    {
        @property stat_t stat() const
        {
            import std.exception : errnoEnforce;
            import std.string : toStringz;

            stat_t result;
            errnoEnforce(core.sys.posix.sys.stat.stat(toStringz(filePath), &result) == 0, "Could not retrieve file stat");
            return result;
        }
    }

    ubyte[] read(ubyte[] buffer)
    {
        return file.rawRead(buffer);
    }
}
