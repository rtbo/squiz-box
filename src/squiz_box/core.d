module squiz_box.core;

import std.datetime.systime;
import std.exception;
import std.range.interfaces;

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

    InputRange!(ubyte[]) byChunk(size_t chunkSize = 4096);

    final ubyte[] readContent()
    {
        ubyte[] result = new ubyte[size];
        size_t offset;

        foreach (chunk; byChunk())
        {
            assert(offset + chunk.length <= result.length);
            result[offset .. offset + chunk.length] = chunk;
            offset += chunk.length;
        }

        return result;
    }

    /// Check if the entry is a potential bomb.
    /// A bomb is typically an entry that may overwrite other files
    /// outside of the extraction directory.
    /// In addition, a criteria of maximum allowed size can be provided (by default all sizes are accepted).
    final bool isBomb(size_t allowedSz = size_t.max)
    {
        import std.path : buildNormalizedPath, isAbsolute;
        import std.string : startsWith;

        if (allowedSz != size_t.max && size > allowedSz)
            return true;

        const p = path;
        return isAbsolute(p) || buildNormalizedPath(p).startsWith("..");
    }

    /// Extract the entry to a file under the given base directory
    final void extractTo(string baseDirectory)
    {
        import std.file : exists, isDir, mkdirRecurse, setTimes;
        import std.path : buildNormalizedPath, dirName;
        import std.stdio : File;

        assert(exists(baseDirectory) && isDir(baseDirectory));

        enforce(
            !this.isBomb,
            "archive bomb detected! Extraction aborted (entry will extract to " ~
                this.path ~ " - outside of extraction directory).",
        );

        const extractPath = buildNormalizedPath(baseDirectory, this.path);

        final switch (this.type)
        {
        case EntryType.directory:
            mkdirRecurse(extractPath);
            break;
        case EntryType.symlink:
            version (Posix)
            {
                import core.sys.posix.unistd : lchown;
                import std.file : symlink;
                import std.string : toStringz;

                mkdirRecurse(dirName(extractPath));
                symlink(this.linkname, extractPath);
                lchown(toStringz(extractPath), this.ownerId, this.groupId);
                break;
            }
        case EntryType.regular:
            mkdirRecurse(dirName(extractPath));
            auto f = File(extractPath, "wb");
            foreach (chunk; this.byChunk())
            {
                f.rawWrite(chunk);
            }
            f.close();

            setTimes(extractPath, Clock.currTime, this.timeLastModified);

            version (Posix)
            {
                import core.sys.posix.sys.stat : chmod;
                import core.sys.posix.unistd : chown;
                import std.string : toStringz;

                chmod(toStringz(extractPath), cast(uint) this.permissions);
                chown(toStringz(extractPath), this.ownerId, this.groupId);
            }
            break;
        }
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

        if (isDir(filePath))
            return EntryType.directory;
        if (isSymlink(filePath))
            return EntryType.symlink;
        return EntryType.regular;
    }

    @property string linkname()
    {
        version (Posix)
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

            enum int mask = cast(int) Permissions.mask;

            return cast(Permissions)(statStruct.st_mode & mask);
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

    InputRange!(ubyte[]) byChunk(size_t chunkSize)
    {
        return inputRangeObject(file.byChunk(chunkSize));
    }

    ubyte[] read(ubyte[] buffer)
    {
        return file.rawRead(buffer);
    }
}
