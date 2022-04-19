module squiz_box.core;

import std.datetime.systime;
import std.exception;

version (Posix)
{
    enum Permissions
    {
        none = 0,

        otherExec = 1 << 0,
        otherWrit = 1 << 1,
        otherRead = 1 << 2,

        groupExec = 1 << 3,
        groupWrit = 1 << 4,
        groupRead = 1 << 5,

        ownerExec = 1 << 6,
        ownerWrit = 1 << 7,
        ownerRead = 1 << 8,

        setUid = 1 << 9,
        setGid = 1 << 10,
        sticky = 1 << 11,

        mask = (1 << 12) - 1,
    }
}

enum EntryType
{
    regular,
    directory,
    symlink,
}

interface ArchiveEntry
{
    @property string path();

    @property EntryType type();

    @property string linkname();

    @property size_t size();
    @property SysTime timeLastModified();

    version (Posix)
    {
        @property Permissions permissions();
        @property int ownerId();
        @property int groupId();
    }

    ubyte[] read(ubyte[] buffer);

    final ubyte[] readContent()
    {
        ubyte[4096] buffer;
        ubyte[] result;

        while (true)
        {
            auto chunk = read(buffer[]);
            result ~= chunk;
            if (chunk.length < 4096)
                break;
        }

        return result;
    }
}

class ArchiveEntryFile : ArchiveEntry
{
    import std.stdio : File;

    string filePath;
    string archivePath;
    File file;

    this(string filePath, string archivePath)
    {
        import std.string : toStringz;
        import std.file : exists;

        enforce(exists(filePath), filePath ~ ": No such file or directory");

        if (!archivePath)
        {
            archivePath = filePath;
        }
        this.filePath = filePath;
        this.archivePath = archivePath;
        this.file = File(filePath, "rb");
    }

    @property string path()
    {
        return archivePath;
    }

    @property EntryType type()
    {
        import std.file : isDir, isSymlink;

        if (isDir(filePath)) return EntryType.directory;
        if (isSymlink(filePath)) return EntryType.symlink;
        return EntryType.regular;
    }

    @property string linkname()
    {
        version(Posix)
        {
            import std.file : readLink;

            return readLink(filePath);
        }
    }


    @property size_t size()
    {
        import std.file : getSize;

        return getSize(filePath);
    }

    @property SysTime timeLastModified()
    {
        import std.file : stdmtime = timeLastModified;

        return stdmtime(filePath);
    }

    version (Posix)
    {
        import core.sys.posix.sys.stat : stat_t, stat;

        stat_t statStruct;
        bool statFetched;

        private void ensureStat()
        {
            import std.string : toStringz;

            if (!statFetched)
            {
                errnoEnforce(
                    stat(toStringz(filePath), &statStruct) == 0,
                    "Could not retrieve file stat of " ~ filePath
                );
                statFetched = true;
            }
        }

        @property Permissions permissions()
        {
            ensureStat();

            enum int mask = cast(int)Permissions.mask;

            return cast(Permissions) (statStruct.st_mode & mask);
        }

        @property int ownerId()
        {
            ensureStat();

            return statStruct.st_uid;
        }

        @property int groupId()
        {
            ensureStat();

            return statStruct.st_gid;
        }
    }

    ubyte[] read(ubyte[] buffer)
    {
        return file.rawRead(buffer);
    }
}
