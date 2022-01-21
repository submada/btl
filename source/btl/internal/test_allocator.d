module btl.internal.test_allocator;

import std.experimental.allocator.common : platformAlignment, stateSize;

import btl.internal.traits;
struct TestAllocator{
    static assert(stateSize!TestAllocator > 0);

    public enum uint alignment = platformAlignment;

    private static long static_count = 0;
    private long count = 0;

    private void increment()pure @safe @nogc nothrow{

        assumePure(function void(){
            static_count += 1;
        })();

        count += 1;
    }

    private void decrement()pure @safe @nogc nothrow{
        assumePure(function void(){
            static_count -= 1;
        })();
        count -= 1;
    }


    public long get_static_count()scope const nothrow @safe @nogc{
        return static_count;
    }
    public long get_count()scope const pure nothrow @safe @nogc{
        return count;
    }

    public void[] allocate(size_t bytes)pure @trusted @nogc nothrow{
        import core.memory : pureMalloc;
        if (!bytes) return null;
        auto p = pureMalloc(bytes);

        if(p){
            this.increment();
            return p[0 .. bytes];
        }
        return null;
    }

    public bool deallocate(void[] b)pure @system @nogc nothrow{
        import core.memory : pureFree;
        pureFree(b.ptr);
        this.decrement();
        return true;
    }

    public bool reallocate(ref void[] b, size_t s)pure @system @nogc nothrow{
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

    //static TestAllocator instance;

}
