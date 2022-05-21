/*
    License:   $(HTTP www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
    Authors:   $(HTTP github.com/submada/btl, Adam Búš)
*/
module btl.internal.allocator;


public template isStatelessAllocator(T){
    import std.experimental.allocator.common : stateSize;

    enum isStatelessAllocator = (stateSize!T == 0);
}

//alias to stateless allocator instance
public template statelessAllcoator(T){
    import std.experimental.allocator.common : stateSize;
    import std.traits : hasStaticMember;

    static assert(isStatelessAllocator!T);

    static if(hasStaticMember!(T, "instance"))
        alias statelessAllcoator = T.instance;
    else 
        enum T statelessAllcoator = T.init;   
}


//NullAllocator:
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

//Mallocator:
version(D_BetterC){
    public struct Mallocator{
        import std.experimental.allocator.common : platformAlignment;

        enum uint alignment = platformAlignment;

        static void[] allocate(size_t bytes)@trusted @nogc nothrow pure{
            import core.memory : pureMalloc;
            if (!bytes) return null;
            auto p = pureMalloc(bytes);
            return p ? p[0 .. bytes] : null;
        }

        static bool deallocate(void[] b)@system @nogc nothrow pure{
            import core.memory : pureFree;
            pureFree(b.ptr);
            return true;
        }

        static bool reallocate(ref void[] b, size_t s)@system @nogc nothrow pure{
            import core.memory : pureRealloc;
            if (!s){
                // fuzzy area in the C standard, see http://goo.gl/ZpWeSE
                // so just deallocate and nullify the pointer
                deallocate(b);
                b = null;
                return true;
            }

            auto p = cast(ubyte*) pureRealloc(b.ptr, s);
            if (!p) return false;
            b = p[0 .. s];
            return true;
        }

        static Mallocator instance;
    }
}
else{
    public import std.experimental.allocator.mallocator : Mallocator;
}


