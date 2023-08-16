module squiz_box.box;

import squiz_box.priv;
import squiz_box.squiz;
import squiz_box.util;

import std.datetime.systime;
import std.exception;
import std.range;
import std.typecons;

public import squiz_box.box.tar;
public import squiz_box.box.seven_z;
public import squiz_box.box.zip;

/// A dynamic range of BoxEntry
alias BoxEntryRange = InputRange!BoxEntry;

/// A dynamic range of UnboxEntry
alias UnboxEntryRange = InputRange!UnboxEntry;

/// Static check that a type is an InputRange of BoxEntry
template isBoxEntryRange(I)
{
    import std.range : ElementType, isInputRange;

    enum isBoxEntryRange = isInputRange!I && is(ElementType!I : BoxEntry);
}

static assert(isBoxEntryRange!(BoxEntry[]));

/// Static check that a type is an InputRange of UnboxEntry
template isUnboxEntryRange(I)
{
    import std.range : ElementType, isInputRange;

    enum isUnboxEntryRange = isInputRange!I && is(ElementType!I : UnboxEntry);
}

static assert(isUnboxEntryRange!(UnboxEntry[]));

/// Check whether a type is a proper box/unbox algorithm.
template isBoxAlgo(A)
{
    enum isBoxAlgo = is(typeof((A algo) {
                BoxEntry[] boxEntries;
                const(ubyte)[] bytes = algo.box(boxEntries).join();
                UnboxEntry[] unboxEntries = algo.unbox(only(bytes), No.removePrefix).array;
                string mt = algo.mimetype;
            }));
}

/// A dynamic interface to boxing/unboxing algorithm
interface BoxAlgo
{
    /// Box the provided entries and return the associated byte range
    ByteRange box(BoxEntryRange entries, size_t chunkSize = defaultChunkSize);

    /// ditto
    final ByteRange box(I)(I entries, size_t chunkSize = defaultChunkSize)
            if (isBoxEntryRange!I && !is(I == BoxEntryRange))
    {
        return box(inputRangeObject(entries), chunkSize);
    }

    /// Unbox the given byte range to a range of entries
    UnboxEntryRange unbox(ByteRange bytes, Flag!"removePrefix" removePrefix = No.removePrefix);

    /// ditto
    final UnboxEntryRange unbox(I)(I bytes, Flag!"removePrefix" removePrefix = No.removePrefix)
            if (isByteRange!I && !is(I : ByteRange))
    {
        // It is necessary to disambiguate `!is(I : ByteRange) with non-const `ubyte[]` range.
        // Otherwise we can have infinite recursion and stack overflow at runtime.
        // The assertion could be in the template constraints, but the static assertion gives
        // opportunity of a helpful message.
        // TODO: add an overload accepting a non-const `ubyte[]` range. Can be tested with
        // requests `ReceiveAsRange`
        enum message = "Squiz-Box requires range of `const(ubyte)[]` but received `ubyte[]`. "
            ~ "Consider typecasting your range with `.map!(c => cast(const(ubyte)[])c)`";
        static assert(!is(ElementType!I == ubyte[]), message);

        return unbox(inputRangeObject(bytes), removePrefix);
    }

    /// The mimetype of the compressed archive
    @property string mimetype() const;
}

static assert(isBoxAlgo!BoxAlgo);

private class CBoxAlgo(A) : BoxAlgo if (isBoxAlgo!A)
{
    private A algo;

    this(A algo)
    {
        this.algo = algo;
    }

    ByteRange box(BoxEntryRange entries, size_t chunkSize)
    {
        return inputRangeObject(algo.box(entries, chunkSize));
    }

    /// Unbox the given byte range to a range of entries
    UnboxEntryRange unbox(ByteRange bytes, Flag!"removePrefix" removePrefix)
    {
        return inputRangeObject(algo.unbox(bytes, removePrefix));
    }

    @property string mimetype() const
    {
        return algo.mimetype;
    }
}

/// Build a BoxAlgo interface from a compile-time known box algo structure.
BoxAlgo boxAlgo(A)(A algo) if (isBoxAlgo!A)
{
    return new CBoxAlgo!A(algo);
}

/// Build a BoxAlgo interface from the filename of the archive.
/// Only the externsion of the filename is used.
BoxAlgo boxAlgo(string archiveFilename)
{
    import std.string : endsWith, toLower;
    import std.path : baseName;

    const fn = baseName(archiveFilename).toLower();

    if (fn.endsWith(".tar.xz"))
    {
        version (HaveSquizLzma)
        {
            return boxAlgo(TarXzAlgo.init);
        }
        else
        {
            assert(false, "Squiz-Box built without LZMA support");
        }
    }
    else if (fn.endsWith(".tar.gz"))
    {
        return boxAlgo(TarGzAlgo.init);
    }
    else if (fn.endsWith(".zip"))
    {
        return boxAlgo(ZipAlgo.init);
    }
    else if (fn.endsWith(".tar.bz2"))
    {
        version (HaveSquizBzip2)
        {
            return boxAlgo(TarBzip2Algo.init);
        }
        else
        {
            assert(false, "Squiz-Box built without Bzip2 support");
        }
    }

    throw new Exception(fn ~ " has unsupported archive extension");
}

/// Box entries with the provided `algo`.
/// Params:
///   entries = a `InputRange` of `BoxEntry`
///   algo = the boxing algorithm
///   defaultChunkSize = chunk size of the returned byte range
///   removePrefix = whether the initial prefix should be removed from the entry path.
///
/// Returns: A `ByteRange` of the boxed archive.
ByteRange box(I, A)(I entries, A algo, size_t chunkSize = defaultChunkSize)
        if (isBoxEntryRange!I && !is(I == BoxEntryRange) && isBoxAlgo!A)
{
    return algo.box(inputRangeObject(entries), chunkSize);
}

/// Unbox bytes with the provided `algo`.
/// Returns: A `UnboxEntryRange` of the entries contained in the box.
UnboxEntryRange unbox(I, A)(I bytes, A algo, Flag!"removePrefix" removePrefix = No.removePrefix)
        if (isByteRange!I && !is(I == ByteRange) && isBoxAlgo!A)
{
    return algo.unbox(inputRangeObject(bytes), removePrefix);
}

package(squiz_box.box)
{
    string entryPrefix(string path, EntryType type)
    {
        import std.string : indexOf;

        const slash = indexOf(path, '/');

        if (slash >= 0 && slash + 1 == path.length && type != EntryType.directory)
            throw new Exception("regular entry ending with /");

        if (slash != -1)
            return path[0 .. slash + 1];

        if (type == EntryType.directory)
            return path ~ "/";

        return null;
    }

    unittest
    {
        assert(entryPrefix("prefix", EntryType.directory) == "prefix/");
        assert(entryPrefix("prefix/", EntryType.directory) == "prefix/");
        assert(entryPrefix("prefix/file", EntryType.regular) == "prefix/");
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
/// Entries for archive creation implement BoxEntry.
/// Entries for archive extraction implement ArchiveExtractionEntry.
///
/// Instances of BoxEntry are typically instanciated directly by the user or by thin helpers (e.g. FileBoxEntry)
/// Instances of UnboxEntry are instantiated by the extraction algorithm and their final type is hidden.
interface ArchiveEntry
{
    /// Tell whether the entry is used for creation (BoxEntry)
    /// or extraction (UnboxEntry)
    @property EntryMode mode();

    /// The archive mode this entry is for.
    /// The path of the entry within the archive.
    /// Should always be a relative path, and never go backward (..)
    /// The directory separations are always '/' (forward slash) even on Windows
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

        if (size > allowedSz)
            return true;

        const p = path;
        return isAbsolute(p) || buildNormalizedPath(p).startsWith("..");
    }
}

/// Interface of ArchiveEntry used to create archives
interface BoxEntry : ArchiveEntry
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

version (Posix)
{
    version (CRuntime_Musl)
    {
        // C runtime MUSL (Alpine Linux) do not declare lchown
        import core.sys.posix.sys.types : gid_t, uid_t;

        private extern (C) nothrow @nogc @system int lchown(const scope char*, uid_t, gid_t);
    }
    else
    {
        import core.sys.posix.unistd : lchown;

    }
}

/// Interface of ArchiveEntry used for archive extraction
interface UnboxEntry : ArchiveEntry
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
        import std.format : format;
        import std.path : buildNormalizedPath, dirName;
        import std.stdio : File;
        import std.string : startsWith;

        assert(exists(baseDirectory) && isDir(baseDirectory));

        enforce(
            !this.isBomb,
            "archive bomb detected! Extraction aborted (entry will extract to " ~
                this.path ~ " - outside of extraction directory).",
        );

        string entryPath = this.path;

        const extractPath = buildNormalizedPath(baseDirectory, entryPath);

        final switch (this.type)
        {
        case EntryType.directory:
            mkdirRecurse(extractPath);
            break;
        case EntryType.symlink:
            mkdirRecurse(dirName(extractPath));
            version (Posix)
            {
                import std.file : symlink;
                import std.string : toStringz;

                symlink(this.linkname, extractPath);
                if (lchown(toStringz(extractPath), this.ownerId, this.groupId) == -1)
                {
                    // warn? throw? ignore?
                }
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
BoxEntry fileEntry(string filename, string archiveBase, string prefix = null)
{
    import std.path : absolutePath, buildNormalizedPath, relativePath;
    import std.string : replace, startsWith;

    const fn = buildNormalizedPath(absolutePath(filename));
    const ab = buildNormalizedPath(absolutePath(archiveBase));

    enforce(fn.startsWith(ab), "archiveBase is not a parent of filename");

    auto pathInArchive = relativePath(fn, ab);
    if (prefix)
        pathInArchive = prefix ~ pathInArchive;

    version (Windows)
        pathInArchive = pathInArchive.replace('\\', '/');

    return new FileBoxEntry(filename, pathInArchive);
}

/// File based implementation of BoxEntry.
/// Used to create archives from files in the file system.
class FileBoxEntry : BoxEntry
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

struct BoxEntryInfo
{
    /// The archive mode this entry is for.
    /// The path of the entry within the archive.
    /// Should always be a relative path, and never go backward (..)
    /// The directory separations are always '/' (forward slash) even on Windows
    string path;

    /// The type of entry (directory, file, symlink)
    EntryType type;

    /// If symlink, this is the path pointed to by the link (relative to the symlink).
    /// Should be null for directories and regular file.
    string linkname;

    /// The size of the entry in bytes (should be zero for directories and symlink)
    /// This is the size of uncompressed data.
    ulong size;

    /// The timeLastModified of the entry
    SysTime timeLastModified;

    /// The file attributes (as returned std.file.getLinkAttributes)
    uint attributes;

    version (Posix)
    {
        /// The owner id of the entry
        int ownerId;
        /// The group id of the entry
        int groupId;
    }
}

class InfoBoxEntry : BoxEntry
{
    BoxEntryInfo info;
    ByteRange data;

    this(BoxEntryInfo info, ByteRange data)
    in (data is null || data.empty || info.type == EntryType.regular, "data can only be supplied for regular files")
    {
        this.info = info;
        this.data = data;
    }

    override @property EntryMode mode()
    {
        return EntryMode.creation;
    }

    override @property string path()
    {
        return info.path;
    }

    override @property EntryType type()
    {
        return info.type;
    }

    override @property string linkname()
    {
        return info.linkname;
    }

    override @property ulong size()
    {
        return info.size;
    }

    override @property SysTime timeLastModified()
    {
        return info.timeLastModified;
    }

    override @property uint attributes()
    {
        return info.attributes;
    }

    version (Posix)
    {
        override @property int ownerId()
        {
            return info.ownerId;
        }

        override @property int groupId()
        {
            return info.groupId;
        }
    }

    /// Return the data passed in the ctor.
    /// chunkSize has no effect here
    ByteRange byChunk(size_t chunkSize = 0)
    {
        if (data)
            return data;
        return inputRangeObject(emptyByteRange);
    }
}

/// Create a BoxEntry from the provided info.
/// This allows to create archives out of generated data, without any backing file on disk.
InfoBoxEntry infoEntry(I)(BoxEntryInfo info, I data)
if (isByteRange!I)
in (info.type == EntryType.regular || data.empty, "symlinks and directories can't have data")
{
    import std.datetime : Clock;

    if (info.timeLastModified == SysTime.init)
        info.timeLastModified = Clock.currTime;

    return new InfoBoxEntry(info, inputRangeObject(data));
}

/// ditto
InfoBoxEntry infoEntry(BoxEntryInfo info)
{
    return infoEntry(info, inputRangeObject(emptyByteRange));
}
