module squiz_box.box.seven_z.error;

import std.exception;
import std.format;

class SevenZArchiveException : Exception
{
    mixin basicExceptionCtors!();
}

class NotA7zArchiveException : SevenZArchiveException
{
    string source;
    string reason;

    this(string source, string reason, string file = __FILE__, size_t line = __LINE__)
    {
        super(format!"'%s' is not a 7z archive (%s)"(source, reason));
        this.source = source;
        this.reason = reason;
    }
}

class Bad7zArchiveException : SevenZArchiveException
{
    string source;
    string reason;

    this(string source, string reason, string file = __FILE__, size_t line = __LINE__)
    {
        super(format!"'%s' is a corrupted 7z archive (%s)"(source, reason));
        this.source = source;
        this.reason = reason;
    }
}

class Unsupported7zArchiveException : SevenZArchiveException
{
    string source;
    string reason;

    this(string source, string reason, string file = __FILE__, size_t line = __LINE__)
    {
        super(format!"'%s' is not a supported 7z archive (%s)"(source, reason));
        this.source = source;
        this.reason = reason;
    }
}

class DataIntegrity7zArchiveException : SevenZArchiveException
{
    string archive;
    string entry;
    uint expectedCrc;
    uint currentCrc;

    this(string archive, string entry, uint expectedCrc, uint currentCrc)
    {
        this.archive = archive;
        this.entry = entry;
        this.expectedCrc = expectedCrc;
        this.currentCrc = currentCrc;
        super(format!"Data integrity error for entry '%s' in archive '%s'"(entry, archive));
    }
}

package(squiz_box.box.seven_z):

noreturn bad7z(string source, string reason, string file = __FILE__, size_t line = __LINE__)
{
    throw new Bad7zArchiveException(source, reason, file, line);
}

noreturn unsupported7z(string source, string reason, string file = __FILE__, size_t line = __LINE__)
{
    throw new Unsupported7zArchiveException(source, reason, file, line);
}
