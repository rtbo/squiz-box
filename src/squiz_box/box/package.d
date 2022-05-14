module squiz_box.box;

import squiz_box.priv;
import squiz_box.squiz;
import squiz_box.util;

import std.datetime.systime;
import std.exception;
import std.range;

public import squiz_box.box.tar;
public import squiz_box.box.zip;

/// Static check that a type is an InputRange of ArchiveCreateEntry
template isCreateEntryRange(I)
{
    import std.range : ElementType, isInputRange;

    enum isCreateEntryRange = isInputRange!I && is(ElementType!I : ArchiveCreateEntry);
}

/// Static check that a type is an InputRange of ArchiveCreateEntry
template isCreateEntryForwardRange(I)
{
    import std.range : ElementType, isForwardRange;

    enum isCreateEntryForwardRange = isForwardRange!I && is(ElementType!I : ArchiveCreateEntry);
}

static assert(isCreateEntryRange!(ArchiveCreateEntry[]));
static assert(isCreateEntryForwardRange!(ArchiveCreateEntry[]));

/// Static check that a type is an InputRange of ArchiveExtractEntry
template isExtractEntryRange(I)
{
    import std.range : ElementType, isInputRange;

    enum isExtractEntryRange = isInputRange!I && is(ElementType!I : ArchiveExtractEntry);
}

static assert(isExtractEntryRange!(ArchiveExtractEntry[]));

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
/// Entries for archive creation implement ArchiveCreateEntry.
/// Entries for archive extraction implement ArchiveExtractionEntry.
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
    @property ulong size();

    /// The timeLastModified of the entry
    @property SysTime timeLastModified();

    /// The file attributes (as returned std.file.getLinkAttributes)
    @property uint attributes();

    version (Posix)
    {
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
    final bool isBomb(ulong allowedSz = ulong.max)
    {
        import std.path : buildNormalizedPath, isAbsolute;
        import std.string : startsWith;

        if (allowedSz != ulong.max && size > allowedSz)
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
    ByteRange byChunk(size_t chunkSize = defaultChunkSize);

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
    @property ulong entrySize();

    /// A byte range to the content of the entry.
    /// Only relevant for regular files.
    /// Other types of entry will return an empty range.
    ByteRange byChunk(size_t chunkSize = defaultChunkSize);

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
        import std.file : exists, isDir, mkdirRecurse, setAttributes, setTimes;
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
            mkdirRecurse(dirName(extractPath));
            version (Posix)
            {
                import core.sys.posix.unistd : lchown;
                import std.file : symlink;
                import std.string : toStringz;

                symlink(this.linkname, extractPath);
                lchown(toStringz(extractPath), this.ownerId, this.groupId);
            }
            else version (Windows)
            {
                import core.sys.windows.winbase : CreateSymbolicLinkW, SYMBOLIC_LINK_FLAG_DIRECTORY;
                import core.sys.windows.windows : DWORD;
                import std.utf : toUTF16z;

                DWORD flags;
                // if not exists (yet - we don't control order of extraction)
                // regular file is assumed
                if (exists(extractPath) && isDir(extractPath))
                {
                    flags = SYMBOLIC_LINK_FLAG_DIRECTORY;
                }
                CreateSymbolicLinkW(extractPath.toUTF16z, this.linkname.toUTF16z, flags);
            }
            break;
        case EntryType.regular:
            mkdirRecurse(dirName(extractPath));

            writeBinaryFile(this.byChunk(), extractPath);

            setTimes(extractPath, Clock.currTime, this.timeLastModified);

            const attrs = this.attributes;
            if (attrs != 0)
            {
                setAttributes(extractPath, attrs);
            }

            version (Posix)
            {
                import core.sys.posix.unistd : chown;
                import std.string : toStringz;

                chown(toStringz(extractPath), this.ownerId, this.groupId);
            }
            break;
        }
    }
}

/// Create a file entry from a file path, relative to a base.
/// archiveBase must be a parent path from filename,
/// such as the the path of the entry is filename, relative to archiveBase.
/// prefix is prepended to the name of the file in the archive.
ArchiveCreateEntry fileEntry(string filename, string archiveBase, string prefix=null)
{
    import std.path : absolutePath, buildNormalizedPath, relativePath;
    import std.string : startsWith;

    const fn = buildNormalizedPath(absolutePath(filename));
    const ab = buildNormalizedPath(absolutePath(archiveBase));

    enforce(fn.startsWith(ab), "archiveBase is not a parent of filename");

    auto pathInArchive = relativePath(fn, ab);
    if (prefix)
        pathInArchive = prefix ~ pathInArchive;

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
            import std.file : isSymlink, readLink;
            if (isSymlink(filePath))
                return readLink(filePath);
        }
        return null;
    }

    @property ulong size()
    {
        import std.file : getSize;

        return getSize(filePath);
    }

    @property SysTime timeLastModified()
    {
        import std.file : stdmtime = timeLastModified;

        return stdmtime(filePath);
    }

    @property uint attributes()
    {
        import std.file : getAttributes;

        return getAttributes(filePath);
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

        return inputRangeObject(ByChunkImpl(File(filePath, "rb"), chunkSize));
    }
}

unittest
{
    import squiz_box.squiz;
    import squiz_box.util;

    import std.algorithm;
    import std.file;
    import std.path;

    import test.util;

    const root = buildNormalizedPath(__FILE_FULL_PATH__.dirName.dirName.dirName.dirName);
    const prefix = "squiz-box-12.5/"; // don't forget trailing '/'!

    const exclusion = [".git", ".dub", ".vscode", "libsquiz-box.a", "build"];

    dirEntries(root, SpanMode.breadth, false)
        .filter!(e => !e.isDir)
        .filter!(e => !exclusion.any!(ex => e.name.canFind(ex)))
        .map!(e => fileEntry(e.name, root, prefix))
        .createTarArchive()
        .compressXz()
        .writeBinaryFile("squiz-box-12.5.tar.xz");
}