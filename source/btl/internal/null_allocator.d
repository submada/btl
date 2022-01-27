module btl.internal.null_allocator;

//mallocator:
version(D_BetterC){
    public struct NullAllocator{
        import std.experimental.allocator.common : platformAlignment;

        enum uint alignment = platformAlignment;

        static void[] allocate(size_t bytes)@trusted @nogc nothrow pure{
            return null;
        }

        static bool deallocate(void[] b)@system @nogc nothrow pure{
            return false;
        }

        static bool reallocate(ref void[] b, size_t s)@system @nogc nothrow pure{
            return false;
        }

        static NullAllocator instance;
    }
}
else{
    public import std.experimental.allocator.building_blocks.null_allocator : NullAllocator;
}
