module squiz_box.priv;

package(squiz_box):

import core.memory;
import std.traits : isIntegral;

extern(C) void* gcAlloc(T)(void* opaque, T n, T m)
if (isIntegral!T)
{
    return GC.malloc(n*m);
}

extern(C) void gcFree(void* opaque, void* addr)
{
    GC.free(addr);
}
