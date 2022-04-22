module squiz_box.core;

import std.datetime.systime;
import std.exception;
import std.range.interfaces;

/// A dynamic type of input range of chunks of bytes
alias ByteRange = InputRange!(ubyte[]);

/// Static check that a type is a byte range.
template isByteRange(BR)
{
    import std.traits : isArray, Unqual;
    import std.range : ElementType, isInputRange;

    alias Arr = ElementType!BR;
    alias El = ElementType!Arr;

    enum isByteRange = isInputRange!BR && is(Unqual!El == ubyte);
}

static assert(isByteRange!ByteRange);

/// Static check that a type is an InputRange of ArchiveCreateEntry
template isArchiveCreateEntryRange(AER)
{
    import std.range : ElementType, isInputRange;

    enum isArchiveCreateEntryRange = isInputRange!AER && is(ElementType!AER : ArchiveCreateEntry);
}

static assert(isArchiveCreateEntryRange!(ArchiveCreateEntry[]));

/// Static check that a type is an InputRange of ArchiveExtractEntry
template isArchiveExtractEntryRange(AER)
{
    import std.range : ElementType, isInputRange;

    enum isArchiveExtractEntryRange = isInputRange!AER && is(ElementType!AER : ArchiveExtractEntry);
}

static assert(isArchiveExtractEntryRange!(ArchiveExtractEntry[]));

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

/// Type of an archive entry
enum EntryType
{
    /// Regular file
    regular,
    /// Directory
    directory,
    /// Symlink
    symlink,
}

/// Describe in what archive mode an entry is for.
enum EntryMode
{
    /// Entry is used for archive creation
    creation,
    /// Entry is used for archive extraction
    extraction,
}

/// Common interface to archive entry.
/// Each type implementing ArchiveEntry is either for creation or for extraction, but not both.
/// Entries for archive creation MUST implement ArchiveCreateEntry.
/// Entries for archive extraction MUST implement ArchiveExtractionEntry.
///
/// Instances of ArchiveCreateEntry are typically instanciated directly by the user or by thin helpers (e.g. FileArchiveEntry)
/// Instances of ArchiveExtractEntry are instantiated by the extraction algorithm and their final type is hidden.
interface ArchiveEntry
{
    /// Tell whether the entry is used for creation (ArchiveCreateEntry)
    /// or extraction (ArchiveExtractEntry)
    @property EntryMode mode();

    /// The archive mode this entry is for.
    /// The path of the entry within the archive.
    /// Should always be a relative path, and never go backward (..)
    @property string path();

    /// The type of entry (directory, file, symlink)
    @property EntryType type();

    /// If symlink, this is the path pointed to by the link (relative to the symlink).
    /// For directories and regular file, returns null.
    @property string linkname();

    /// The size of the entry in bytes (returns zero for directories and symlink)
    /// This is the size of uncompressed, extracted data.
    @property size_t size();

    /// The timeLastModified of the entry
    @property SysTime timeLastModified();

    version (Posix)
    {
        /// The posix permissions of the entry
        @property Permissions permissions();
        /// The owner id of the entry
        @property int ownerId();
        /// The group id of the entry
        @property int groupId();
    }

    /// Check if the entry is a potential bomb.
    /// A bomb is typically an entry that may overwrite other files
    /// outside of the extraction directory.
    /// isBomb will return true if the path is an absolute path
    /// or a relative path going backwards (containing '..' after normalization).
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
}

/// Interface of ArchiveEntry used to create archives
interface ArchiveCreateEntry : ArchiveEntry
{
    /// A byte range to the content of the entry.
    /// Only relevant for regular files.
    /// Other types of entry will return an empty range.
    ByteRange byChunk(size_t chunkSize = 4096);

    /// Helper function that read the complete data of the entry (using byChunk).
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
}

/// Interface of ArchiveEntry used for archive extraction
interface ArchiveExtractEntry : ArchiveEntry
{
    /// The size occupied by the entry in the archive.
    @property size_t entrySize();

    /// A byte range to the content of the entry.
    /// Only relevant for regular files.
    /// Other types of entry will return an empty range.
    ByteRange byChunk(size_t chunkSize = 4096);

    /// Helper function that read the complete data of the entry (using byChunk).
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

/// Create a file entry from a file path, relative to a base.
/// archiveBase must be a parent path from filename,
/// such as the the path of the entry is filename, relative to archiveBase.
ArchiveCreateEntry fileEntryFromBase(string filename, string archiveBase)
{
    import std.path : absolutePath, buildNormalizedPath, relativePath;
    import std.string : startsWith;

    const fn = buildNormalizedPath(absolutePath(filename));
    const ab = buildNormalizedPath(absolutePath(archiveBase));

    enforce(fn.startsWith(ab), "archiveBase is not a parent of filename");

    const pathInArchive = relativePath(fn, ab);

    return new FileArchiveEntry(filename, pathInArchive);
}

/// File based implementation of ArchiveCreateEntry.
/// Used to create archives from files in the file system.
class FileArchiveEntry : ArchiveCreateEntry
{
    string filePath;
    string pathInArchive;

    this(string filePath, string pathInArchive)
    {
        import std.algorithm : canFind;
        import std.file : exists;
        import std.path : isAbsolute;

        enforce(exists(filePath), filePath ~ ": No such file or directory");
        enforce(!isAbsolute(pathInArchive) && !pathInArchive.canFind(".."), "Potential archive bomb");

        if (!pathInArchive)
        {
            pathInArchive = filePath;
        }
        this.filePath = filePath;
        this.pathInArchive = pathInArchive;
    }

    @property EntryMode mode()
    {
        return EntryMode.creation;
    }

    @property string path()
    {
        return pathInArchive;
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

    ByteRange byChunk(size_t chunkSize)
    {
        import std.stdio : File;

        return inputRangeObject(File(filePath, "rb").byChunk(chunkSize));
    }
}
