/**
    Implementation of unique pointer `UniquePtr` (alias to `btl.autoptr.rc_ptr.RcPtr` with immutable control block).

    License:   $(HTTP www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
    Authors:   $(HTTP github.com/submada/basic_string, Adam Búš)
*/
module btl.autoptr.unique_ptr;

import btl.internal.mallocator;
import btl.internal.traits;

static import btl.autoptr.rc_ptr;
import btl.autoptr.common;

/**
    Alias to `btl.autoptr.rc_ptr.dynCast`.
*/
public alias dynCast = btl.autoptr.rc_ptr.dynCast;

/**
    Alias to `btl.autoptr.rc_ptr.dynCastMove`.
*/
public alias dynCastMove = btl.autoptr.rc_ptr.dynCastMove;

/**
    Alias to `btl.autoptr.rc_ptr.first`.
*/
public alias first = btl.autoptr.rc_ptr.first;

/**
    Alias to `btl.autoptr.rc_ptr.share`.
*/
public alias share = btl.autoptr.rc_ptr.share;


/**
    `UniquePtr` is a smart pointer that owns and manages object through a pointer and disposes of that object when the `UniquePtr` goes out of scope.

    `UniquePtr` is alias to `btl.autoptr.rc_ptr.RcPtr` with immutable `_ControlType`.

    The object is destroyed and its memory deallocated when either of the following happens:

        1. the managing `UniquePtr` object is destroyed

        2. the managing `UniquePtr` object is assigned another pointer via various methods like `opAssign` and `store`.

    The object is destroyed using delete-expression or a custom deleter that is supplied to `UniquePtr` during construction.

    A `UniquePtr` may alternatively own no object, in which case it is called empty.

    Template parameters:

        `_Type` type of managed object

        `_DestructorType` function pointer with attributes of destructor, to get attributes of destructor from type use `btl.autoptr.common.DestructorType!T`. Destructor of type `_Type` must be compatible with `_DestructorType`

        `_ControlType` represent type of counter, must by of type immutable `btl.autoptr.common.ControlBlock`.
*/
public template UniquePtr(
    _Type,
    _DestructorType = DestructorType!_Type,
    _ControlType = immutable(UniqueControlBlock),
)
if(isControlBlock!_ControlType && isDestructorType!_DestructorType){
    static assert(is(_ControlType == immutable));

    alias UniquePtr = btl.autoptr.rc_ptr.RcPtr!(_Type, _DestructorType, _ControlType);
}

/// ditto
public template UniquePtr(
    _Type,
    _ControlType,
    _DestructorType = DestructorType!_Type
)
if(isControlBlock!_ControlType && isDestructorType!_DestructorType){
    static assert(is(_ControlType == immutable));

    alias UniquePtr = btl.autoptr.rc_ptr.RcPtr!(_Type, _DestructorType, _ControlType);
}

///
unittest{
    static class Foo{
        int i;

        this(int i)pure nothrow @safe @nogc{
            this.i = i;
        }
    }

    static class Bar : Foo{
        double d;

        this(int i, double d)pure nothrow @safe @nogc{
            super(i);
            this.d = d;
        }
    }

    static class Zee : Bar{
        bool b;

        this(int i, double d, bool b)pure nothrow @safe @nogc{
            super(i, d);
            this.b = b;
        }

        ~this()nothrow @system{
        }
    }

    import core.lifetime : move;
    ///simple:
    {
        UniquePtr!long a = UniquePtr!long.make(42);
        UniquePtr!(const long) b = move(a);
        assert(a == null);

        assert(*b == 42);
        assert(b.get == 42);
    }

    ///polymorphism:
    {
        ///create UniquePtr
        UniquePtr!Foo foo = UniquePtr!Bar.make(42, 3.14);
        UniquePtr!Zee zee = UniquePtr!Zee.make(42, 3.14, false);

        ///dynamic cast:
        UniquePtr!Bar bar = dynCastMove!Bar(foo);
        assert(foo == null);
        assert(bar != null);

        ///this doesnt work because Foo destructor attributes are more restrictive then Zee's:
        //UniquePtr!Foo x = move(zee);

        ///this does work:
        UniquePtr!(Foo, DestructorType!(Foo, Zee)) x = move(zee);
        assert(zee == null);
    }


    ///multi threading:
    {
        ///create SharedPtr with atomic ref counting
        UniquePtr!(shared Foo) foo = UniquePtr!(shared Bar).make(42, 3.14);

        ///this doesnt work:
        //foo.get.i += 1;

        import core.atomic : atomicFetchAdd;
        atomicFetchAdd(foo.get.i, 1);
        assert(foo.get.i == 43);


        ///creating `shared(UniquePtr)`:
        shared UniquePtr!(shared Bar) bar = share(dynCastMove!Bar(foo));

        ///`shared(UniquePtr)` is lock free.
        static assert(typeof(bar).isLockFree == true);

        ///multi thread operations (`store`, `exchange`):
        UniquePtr!(shared Bar) bar2 = bar.exchange(null);
    }

    ///dynamic array:
    {
        import std.algorithm : all, equal;

        UniquePtr!(long[]) a = UniquePtr!(long[]).make(10, -1);
        assert(a.length == 10);
        assert(a.get.length == 10);
        assert(a.get.all!(x => x == -1));

        for(long i = 0; i < a.length; ++i){
            a.get[i] = i;
        }
        assert(a.get[] == [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]);
    }
}

//old
pure nothrow @nogc unittest{

    static class Foo{
        int i;

        this(int i)pure nothrow @safe @nogc{
            this.i = i;
        }
    }

    static class Bar : Foo{
        double d;

        this(int i, double d)pure nothrow @safe @nogc{
            super(i);
            this.d = d;
        }
    }

    //implicit qualifier cast
    {
        UniquePtr!(const Foo) foo =  UniquePtr!Foo.make(42);
        assert(foo.get.i == 42);

        import core.lifetime : move;
        const UniquePtr!Foo foo2 = foo.move;
        assert(foo2.get.i == 42);

    }

    //polymorphic classes:
    {
        UniquePtr!Foo foo = UniquePtr!Bar.make(42, 3.14);
        assert(foo != null);
        assert(foo.get.i == 42);

        //dynamic cast:
        {
            UniquePtr!Bar bar = dynCastMove!Bar(foo);
            assert(foo == null);
            assert(bar != null);

            assert(bar.get.i == 42);
            assert(bar.get.d == 3.14);
        }

    }

    //dynamic array
    {
        import std.algorithm : all;

        {
            auto arr = UniquePtr!(long[]).make(10, -1);

            assert(arr.length == 10);
            assert(arr.get.all!(x => x == -1));
        }

        {
            auto arr = UniquePtr!(long[]).make(8);
            assert(arr.length == 8);
            assert(arr.get.all!(x => x == long.init));
        }
    }

    //static array
    {
        import std.algorithm : all;

        {
            auto arr = UniquePtr!(long[4]).make(-1);
            assert(arr.get[].all!(x => x == -1));

        }

        {
            long[4] tmp = [0, 1, 2, 3];
            auto arr = UniquePtr!(long[4]).make(tmp);
            assert(arr.get[] == tmp[]);
        }
    }

}

///
pure nothrow @safe @nogc unittest{
    //make UniquePtr object
    static struct Foo{
        int i;

        this(int i)pure nothrow @safe @nogc{
            this.i = i;
        }
    }

    {
        auto foo = UniquePtr!Foo.make(42);
        auto foo2 = UniquePtr!Foo.make!Mallocator(42);  //explicit stateless allocator
    }

    {
        auto arr = UniquePtr!(long[]).make(10); //dynamic array with length 10
        assert(arr.length == 10);
    }
}

///
nothrow unittest{
    //alloc UniquePtr object
    import std.experimental.allocator : make, dispose, allocatorObject;

    auto allocator = allocatorObject(Mallocator.instance);

    {
        auto x = UniquePtr!(long).alloc(allocator, 42);
    }

    {
        auto arr = UniquePtr!(long[]).alloc(allocator, 10); //dynamic array with length 10
        assert(arr.length == 10);
    }

}





// make:
pure nothrow @safe @nogc unittest{

    enum bool supportGC = true;

    //
    {
        auto s = UniquePtr!long.make(42);
    }

    {
        auto s = UniquePtr!long.make!(DefaultAllocator, supportGC)(42);
    }

    {
        auto s = UniquePtr!(long, immutable(SharedControlBlock)).make!(DefaultAllocator, supportGC)(42);
    }

    // dynamic array:
    {
        auto s = UniquePtr!(long[]).make(10, 42);
        assert(s.length == 10);
    }

    {
        auto s = UniquePtr!(long[]).make!(DefaultAllocator, supportGC)(10, 42);
        assert(s.length == 10);
    }

    {
        auto s = UniquePtr!(long[], immutable(SharedControlBlock)).make!(DefaultAllocator, supportGC)(10, 42);
        assert(s.length == 10);
    }
}

// alloc:
nothrow unittest{
    import std.experimental.allocator : allocatorObject;

    auto a = allocatorObject(Mallocator.instance);
    enum bool supportGC = true;

    //
    {
        auto s = UniquePtr!long.alloc(a, 42);
    }

    {
        auto s = UniquePtr!long.alloc!supportGC(a, 42);
    }

    {
        auto s = UniquePtr!(long, immutable(SharedControlBlock)).alloc!supportGC(a, 42);
    }

    // dynamic array:
    {
        auto s = UniquePtr!(long[]).alloc(a, 10, 42);
        assert(s.length == 10);
    }

    {
        auto s = UniquePtr!(long[]).alloc!supportGC(a, 10, 42);
        assert(s.length == 10);
    }

    {
        auto s = UniquePtr!(long[], immutable(SharedControlBlock)).alloc!supportGC(a, 10, 42);
        assert(s.length == 10);
    }
}

///
nothrow @nogc unittest{
    {
        auto x = UniquePtr!(shared long).make(123);

        import core.lifetime : move;
        shared s = share(x.move);
        assert(x == null);

        auto y = s.exchange(null);
        assert(*y == 123);
    }

    {
        auto x = UniquePtr!(long).make(123);

        ///error `shared UniquePtr` need shared `ControlType` and shared `ElementType`.
        //shared s = share(x);

    }
}

//
pure nothrow @nogc unittest{
    import core.lifetime : move;

    {
        auto x = UniquePtr!(long[]).make(10, -1);
        assert(x.length == 10);

        auto y = first(x.move);
        static assert(is(typeof(y) == UniquePtr!long));
        assert(*y == -1);
    }

    {
        auto x = UniquePtr!(long[10]).make(-1);
        assert(x.get.length == 10);

        auto y = first(x.move);
        static assert(is(typeof(y) == UniquePtr!long));
        assert(*y == -1);
    }
}

//
pure @safe nothrow @nogc unittest{
    static class Foo{
        int i;

        this(int i)pure nothrow @safe @nogc{
            this.i = i;
        }
    }

    static class Bar : Foo{
        double d;

        this(int i, double d)pure nothrow @safe @nogc{
            super(i);
            this.d = d;
        }
    }

    static class Zee{
    }

    {
        UniquePtr!(const Foo) foo = UniquePtr!Bar.make(42, 3.14);
        //assert(foo.get.i == 42);

        auto bar = dynCastMove!Bar(foo);
        assert(bar != null);
        assert(foo == null);
        //assert(bar.get.d == 3.14);
        static assert(is(typeof(bar) == UniquePtr!(const Bar)));

        auto zee = dynCastMove!Zee(bar);
        assert(zee == null);
        assert(bar != null);
        static assert(is(typeof(zee) == UniquePtr!(const Zee)));
    }
}


//
unittest{
    static class Foo{
        int i;

        this(int i)pure nothrow @safe @nogc{
            this.i = i;
        }
    }

    static class Bar : Foo{
        double d;

        this(int i, double d)pure nothrow @safe @nogc{
            super(i);
            this.d = d;
        }
    }

    static class Zee{
    }

    {
        import core.lifetime : move;

        UniquePtr!(const Foo) foo = UniquePtr!Bar.make(42, 3.14);
        assert(foo.get.i == 42);

        auto bar = dynCast!Bar(foo.move);
        assert(bar != null);
        assert(foo == null);
        assert(bar.get.d == 3.14);
        static assert(is(typeof(bar) == UniquePtr!(const Bar)));

        auto zee = dynCast!Zee(bar.move);
        assert(zee == null);
        assert(bar == null);
        static assert(is(typeof(zee) == UniquePtr!(const Zee)));
    }
}


version(unittest){


    //this null
    pure nothrow @nogc unittest{
        UniquePtr!long x = null;

        assert(x == null);
        assert(x == UniquePtr!long.init);
    }

    //this rhs
    pure nothrow @nogc unittest{
        //TODO
    }


    //opAssign null
    pure nothrow @nogc unittest{

        {
            UniquePtr!long x = UniquePtr!long.make(1);

            assert(x != null);
            assert(*x == 1);
            x = null;
            assert(x == null);
        }

        {
            UniquePtr!(shared long) x = UniquePtr!(shared long).make(1);

            assert(x != null);
            assert(*x == 1);
            x = null;
            assert(x == null);
        }
    }

    //opAssign UniquePtr
    pure nothrow @nogc unittest{

        import core.lifetime : move;
        {
            UniquePtr!long px1 = UniquePtr!long.make(1);
            UniquePtr!long px2 = UniquePtr!long.make(2);

            px1 = move(px2);
            assert(px2 == null);
            assert(px1 != null);
            assert(*px1 == 2);
        }


        {
            UniquePtr!long px = UniquePtr!long.make(1);
            UniquePtr!(const long) pcx = UniquePtr!long.make(2);

            pcx = move(px);
            assert(px == null);
            assert(pcx != null);
            assert(*pcx == 1);

        }
    }

    //store
    nothrow @nogc unittest{
        //null store:
        {
            shared x = UniquePtr!(shared long).make(123);
            //*x == 123

            x.store(null);
            //x is null
        }

        //rvalue store:
        {
            shared x = UniquePtr!(shared long).make(123);
            //*x == 123

            x.store(UniquePtr!(shared long).make(42));
            //*x == 42

            auto tmp = x.exchange(null);
            //x is null
            assert(tmp.get == 42);
        }
    }

    //exchange
    pure nothrow @nogc unittest{
        import core.lifetime : move;

        {
            shared UniquePtr!(shared long) x = UniquePtr!(shared long).make(123);
            UniquePtr!(shared long) y = UniquePtr!(shared long).make(42);

            auto z = x.exchange(y.move);
            assert(y == null);
            assert(*z == 123);

            auto tmp = x.exchange(null);
            assert(*tmp == 42);
        }

        //swap:
        {
            shared UniquePtr!(shared long) x = UniquePtr!(shared long).make(123);
            UniquePtr!(shared long) y = UniquePtr!(shared long).make(42);

            y = x.exchange(y.move);
            assert(*y == 123);

            auto tmp = x.exchange(null);
            assert(*tmp == 42);
        }
    }

    //make
    pure nothrow @nogc unittest{

        {
            UniquePtr!long a = UniquePtr!long.make();
            assert(a.get == 0);

            UniquePtr!(const long) b = UniquePtr!long.make(2);
            assert(b.get == 2);
        }

        {
            static struct Struct{
                int i = 7;

                this(int i)pure nothrow @safe @nogc{
                    this.i = i;
                }
            }

            UniquePtr!Struct s1 = UniquePtr!Struct.make();
            assert(s1.get.i == 7);

            UniquePtr!Struct s2 = UniquePtr!Struct.make(123);
            assert(s2.get.i == 123);
        }
    }

    //make dynamic array
    pure nothrow @nogc unittest{
        auto arr = UniquePtr!(long[]).make(6, -1);
        assert(arr.length == 6);
        assert(arr.get.length == 6);

        import std.algorithm : all;
        assert(arr.get.all!(x => x == -1));

        for(long i = 0; i < 6; ++i)
            arr.get[i] = i;

        assert(arr.get == [0, 1, 2, 3, 4, 5]);
    }

    //alloc
    nothrow unittest{
        import std.experimental.allocator : allocatorObject;
        auto a = allocatorObject(Mallocator.instance);
        {
            auto x = UniquePtr!long.alloc(a);
            assert(x.get == 0);

            auto y = UniquePtr!(const long).alloc(a, 2);
            assert(y.get == 2);
        }

        {
            static struct Struct{
                int i = 7;

                this(int i)pure nothrow @safe @nogc{
                    this.i = i;
                }
            }

            auto s1 = UniquePtr!Struct.alloc(a);
            assert(s1.get.i == 7);

            auto s2 = UniquePtr!Struct.alloc(a, 123);
            assert(s2.get.i == 123);
        }
    }

    //alloc dynamic array
    nothrow unittest{
        import std.experimental.allocator : allocatorObject;
        auto a = allocatorObject(Mallocator.instance);
        {
            auto x = UniquePtr!long.alloc(a);
            assert(x.get == 0);

            auto y = UniquePtr!(const long).alloc(a, 2);
            assert(y.get == 2);
        }

        {
            static struct Struct{
                int i = 7;

                this(int i)pure nothrow @safe @nogc{
                    this.i = i;
                }
            }

            auto s1 = UniquePtr!Struct.alloc(a);
            assert(s1.get.i == 7);

            auto s2 = UniquePtr!Struct.alloc(a, 123);
            assert(s2.get.i == 123);
        }
    }

    //proxySwap
    pure nothrow @nogc unittest{
        {
            UniquePtr!long a = UniquePtr!long.make(1);
            UniquePtr!long b = UniquePtr!long.make(2);
            a.proxySwap(b);
            assert(*a == 2);
            assert(*b == 1);
            import std.algorithm : swap;
            swap(a, b);
            assert(*a == 1);
            assert(*b == 2);
        }
    }

    //opUnary : '*'
    pure nothrow @nogc unittest{
        import core.lifetime : move;

        UniquePtr!long x = UniquePtr!long.make(123);
        assert(*x == 123);
        (*x = 321);
        assert(*x == 321);
        const y = move(x);
        assert(*y == 321);
        assert(x == null);
        static assert(is(typeof(*y) == const long));
    }

    //get
    pure nothrow @nogc unittest{
        import core.lifetime : move;

        UniquePtr!long x = UniquePtr!long.make(123);
        assert(x.get == 123);
        x.get = 321;
        assert(x.get == 321);
        const y = move(x);
        assert(y.get == 321);
        assert(x == null);
        static assert(is(typeof(y.get) == const long));
    }

    //element
    pure nothrow @nogc unittest{
        import core.lifetime : move;

        UniquePtr!long x = UniquePtr!long.make(123);
        assert(*x.element == 123);
        x.get = 321;
        assert(*x.element == 321);
        const y = move(x);
        assert(*y.element == 321);
        assert(x == null);
        static assert(is(typeof(y.element) == const(long)*));
    }

    //length
    pure nothrow @nogc unittest{
        auto x = UniquePtr!(int[]).make(10, -1);
        assert(x.length == 10);
        assert(x.get.length == 10);

        import std.algorithm : all;
        assert(x.get.all!(i => i == -1));
    }

    //opCast : bool
    /+TODO
    pure nothrow @nogc unittest{

        UniquePtr!long x = UniquePtr!long.make(123);
        assert(cast(bool)x);    //explicit cast
        assert(x);              //implicit cast
        x = null;
        assert(!cast(bool)x);   //explicit cast
        assert(!x);             //implicit cast
    }
    +/


    //opEquals
    pure nothrow @nogc unittest{

        {
            UniquePtr!long x = UniquePtr!long.make(0);
            assert(x != null);
            x = null;
            assert(x == null);
        }

        {
            UniquePtr!long x = UniquePtr!long.make(123);
            UniquePtr!long y = UniquePtr!long.make(123);
            assert(x == x);
            assert(y == y);
            assert(x != y);
        }

        {
            UniquePtr!long x;
            UniquePtr!(const long) y;
            assert(x == x);
            assert(y == y);
            assert(x == y);
        }

        {
            UniquePtr!long x = UniquePtr!long.make(123);
            UniquePtr!long y = UniquePtr!long.make(123);
            assert(x == x.element);
            assert(y.element == y);
            assert(x != y.element);
        }
    }

    //opCmp
    pure nothrow @nogc unittest{
        {
            const a = UniquePtr!long.make(42);
            const b = UniquePtr!long.make(123);
            const n = UniquePtr!long.init;

            assert((a < b) == !(a >= b));
            assert((a > b) == !(a <= b));

            assert(a > n);
            assert(n < a);
        }

        {
            const a = UniquePtr!long.make(42);
            const b = UniquePtr!long.make(123);

            assert((a < b.element) == !(a.element >= b));
            assert((a > b.element) == !(a.element <= b));
        }
    }

    //toHash
    pure nothrow @nogc unittest{
        import core.lifetime : move;
        {
            UniquePtr!long x = UniquePtr!long.make(123);
            UniquePtr!long y = UniquePtr!long.make(123);
            assert(x.toHash == x.toHash);
            assert(y.toHash == y.toHash);
            assert(x.toHash != y.toHash);

            const x_hash = x.toHash;
            UniquePtr!(const long) z = move(x);
            assert(x_hash == z.toHash);
        }
        {
            UniquePtr!long x;
            UniquePtr!(const long) y;
            assert(x.toHash == x.toHash);
            assert(y.toHash == y.toHash);
            assert(x.toHash == y.toHash);
        }
    }


}
