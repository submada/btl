# Autoptr

## Documentation
https://submada.github.io/autoptr

## C++-style smart pointers for D.

This library contains:
* `SharedPtr` is a smart pointer that retains shared ownership of an object through a pointer. Support weak pointers and aliasing like C++ std::shared_ptr. Pointer to managed object is separated from pointer to control block conataining reference counter. `SharedPtr` contains 2 pointers or 2 pointers + length if managed object is slice). 
* `RcPtr`     is a smart pointer that retains shared ownership of an object through a pointer. Support weak pointers and only limited aliasing unlike `SharedPtr`. Managed object must be allcoated with control block (reference counter) in one continuous memory block. `RcPtr` contains only 1 pointer or 1 pointer + length if managed object is slice.
* `IntrusivePtr` is a smart pointer that retains shared ownership of an object through a pointer. Support weak pointers and only limited aliasing unlike `SharedPtr`. Managed object must contain control block (`autoptr.common.ControlBlock`). `IntrusivePtr` contains only 1 pointer and type of managed object must be `struct` or `class`
* `UniquePtr` is a smart pointer that owns and manages object through a pointer and disposes of that object when the `UniquePtr` goes out of scope. `UniquePtr` is alias to `RcPtr` with immutable `_ControlType`.

`SharedPtr`, `RcPtr` and `UniquePtr` have 3 template parameters:
* `_Type` type of managed object.
* `_DestructorType` type reprezenting attributes of destructor for managed object. 
  * This parameter is inferred from parameter `_Type` like this: `autoptr.common.DestructorType!_Type`.
* `_ControlType` type representing control block. This parameter specify reference counting for smart pointer. 
  * Default value for `UniquePtr` is `autoptr.common.ControlBlock!void` which mean that there is no reference counting.
  * Default value for `SharedPtr` and `RefPtr` is `autoptr.common.ControlBlock!(int, int)` which mean that type of reference counter is int and  weak reference counter type is int. `autoptr.common.ControlBlock!(int, void)` disable weak reference counting.
  * If control block is shared then reference counting is atomic. Qualiffier shared is inferred from `_Type` for `_ControlType`. If `_Type` is shared then `_ControlType` is shared too.

`IntrusivePtr` has only 1 template parameters, `_Type`.
* `_DestructorType` is inferred from `_Type`.
* `_ControlType` is inferred from `_Type`.

Smart pointers can be created with static methods `make` and `alloc`.
* `make` create smart pointer with stateless allocator (default `Mallocator`)
* `alloc` create smart pointer using allocator with state. Allocator is saved in control block.

Constructors of smart pointers never allocate memory, only static methods `make` and `alloc` allocate.

@safe:
* Creating smart pointer with `make` or `alloc` is @safe if constructor of type `_Type` is @safe (assumption is that constructor doesn't leak `this` pointer).
* Smart pointers assume that deallocation with custom allocator is @safe if allocation is @safe even if method `deallcoate` is @system.
* Methods returning reference/pointer (`get()`, `element()`, `opUnary!"*"()`) to managed object are all @system because of this:
    ```d
    auto trustedGet(Ptr)(ref scope Ptr ptr)@trusted{
        return ptr.get();
    }

    struct S{
        long x;

        this(long x)@safe{
            this.x = x;
        }

        ~this()@safe{
            this.x = -1;
        }
    }

    void main()@safe{
        auto p = SharedPtr!S.make(42);

        (scope ref S s)@safe{
            assert(s.x == 42);
            p = null;           ///release pointer
            assert(s.x == -1);  ///`s` is dangling reference

        }(p.trustedGet);

    }
    ```

    @safe access to managed object:

    ```d
    struct S{
        long x;

        this(long x)@safe{
            this.x = x;
        }

        ~this()@safe{
            this.x = -1;
        }
    }

    void main()@safe{
        auto p = SharedPtr!S.make(42);

        p.apply!((scope ref S s)@safe{
            assert(p.useCount == 2);
            assert(s.x == 42);
            p = null;           ///release
            assert(s.x == 42);  ///`s` is NOT dangling reference

        });
    }
    ```

## Examples
```d
class Foo{
    int i;

    this(int i)pure nothrow @safe @nogc{
        this.i = i;
    }
}

class Bar : Foo{
    double d;

    this(int i, double d)pure nothrow @safe @nogc{
        super(i);
        this.d = d;
    }
}

class Zee : Bar{
    bool b;

    this(int i, double d, bool b)pure nothrow @safe @nogc{
        super(i, d);
        this.b = b;
    }

    ~this()nothrow @system{
    }
}
```

### SharedPtr
```d
unittest{
    ///simple:
    {
        SharedPtr!long a = SharedPtr!long.make(42);
        assert(a.useCount == 1);

        SharedPtr!(const long) b = a;
        assert(a.useCount == 2);

        SharedPtr!long.WeakType w = a.weak; //or WeakPtr!long
        assert(a.useCount == 2);
        assert(a.weakCount == 1);

        SharedPtr!long c = w.lock;
        assert(a.useCount == 3);
        assert(a.weakCount == 1);

        assert(*c == 42);
        assert(c.get == 42);
    }

    ///polymorphism and aliasing:
    {
        ///create SharedPtr
        SharedPtr!Foo foo = SharedPtr!Bar.make(42, 3.14);
        SharedPtr!Zee zee = SharedPtr!Zee.make(42, 3.14, false);

        ///dynamic cast:
        SharedPtr!Bar bar = dynCast!Bar(foo);
        assert(bar != null);
        assert(foo.useCount == 2);

        ///this doesnt work because Foo destructor attributes are more restrictive then Zee's:
        //SharedPtr!Foo x = zee;

        ///this does work:
        SharedPtr!(Foo, DestructorType!(Foo, Zee)) x = zee;
        assert(zee.useCount == 2);

        ///aliasing (shared ptr `d` share ref counting with `bar`):
        SharedPtr!double d = SharedPtr!double(bar, &bar.get.d);
        assert(d != null);
        assert(*d == 3.14);
        assert(foo.useCount == 3);
    }


    ///multi threading:
    {
        ///create SharedPtr with atomic ref counting
        SharedPtr!(shared Foo) foo = SharedPtr!(shared Bar).make(42, 3.14);

        ///this doesnt work:
        //foo.get.i += 1;

        import core.atomic : atomicFetchAdd;
        atomicFetchAdd(foo.get.i, 1);
        assert(foo.get.i == 43);


        ///creating `shared(SharedPtr)`:
        shared SharedPtr!(shared Bar) bar = share(dynCast!Bar(foo));

        ///`shared(SharedPtr)` is not lock free but `RcPtr` is lock free.
        static assert(typeof(bar).isLockFree == false);

        ///multi thread operations (`load`, `store`, `exchange` and `compareExchange`):
        SharedPtr!(shared Bar) bar2 = bar.load();
        assert(bar2 != null);
        assert(bar2.useCount == 3);

        SharedPtr!(shared Bar) bar3 = bar.exchange(null);
        assert(bar3 != null);
        assert(bar3.useCount == 3);
    }

    ///dynamic array:
    {
        import std.algorithm : all, equal;

        SharedPtr!(long[]) a = SharedPtr!(long[]).make(10, -1);
        assert(a.length == 10);
        assert(a.get.length == 10);
        assert(a.get.all!(x => x == -1));

        for(long i = 0; i < a.length; ++i){
            a.get[i] = i;
        }
        assert(a.get[] == [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]);

        ///aliasing:
        SharedPtr!long a6 = SharedPtr!long(a, &a.get[6]);
        assert(*a6 == a.get[6]);
    }
}
```

### UniquePtr:
```d
unittest{
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
```

### RcPtr:
```d
unittest{
    ///simple:
    {
        RcPtr!long a = RcPtr!long.make(42);
        assert(a.useCount == 1);

        RcPtr!(const long) b = a;
        assert(a.useCount == 2);

        RcPtr!long.WeakType w = a.weak; //or WeakRcPtr!long
        assert(a.useCount == 2);
        assert(a.weakCount == 1);

        RcPtr!long c = w.lock;
        assert(a.useCount == 3);
        assert(a.weakCount == 1);

        assert(*c == 42);
        assert(c.get == 42);
    }

    ///polymorphism and aliasing:
    {
        ///create RcPtr
        RcPtr!Foo foo = RcPtr!Bar.make(42, 3.14);
        RcPtr!Zee zee = RcPtr!Zee.make(42, 3.14, false);

        ///dynamic cast:
        RcPtr!Bar bar = dynCast!Bar(foo);
        assert(bar != null);
        assert(foo.useCount == 2);

        ///this doesnt work because Foo destructor attributes are more restrictive then Zee's:
        //RcPtr!Foo x = zee;

        ///this does work:
        RcPtr!(Foo, DestructorType!(Foo, Zee)) x = zee;
        assert(zee.useCount == 2);
    }


    ///multi threading:
    {
        ///create RcPtr with atomic ref counting
        RcPtr!(shared Foo) foo = RcPtr!(shared Bar).make(42, 3.14);

        ///this doesnt work:
        //foo.get.i += 1;

        import core.atomic : atomicFetchAdd;
        atomicFetchAdd(foo.get.i, 1);
        assert(foo.get.i == 43);


        ///creating `shared(RcPtr)`:
        shared RcPtr!(shared Bar) bar = share(dynCast!Bar(foo));

        ///`shared(RcPtr)` is lock free (except `load` and `useCount`/`weakCount`).
        static assert(typeof(bar).isLockFree == true);

        ///multi thread operations (`load`, `store`, `exchange` and `compareExchange`):
        RcPtr!(shared Bar) bar2 = bar.load();
        assert(bar2 != null);
        assert(bar2.useCount == 3);

        RcPtr!(shared Bar) bar3 = bar.exchange(null);
        assert(bar3 != null);
        assert(bar3.useCount == 3);
    }

    ///dynamic array:
    {
        import std.algorithm : all, equal;

        RcPtr!(long[]) a = RcPtr!(long[]).make(10, -1);
        assert(a.length == 10);
        assert(a.get.length == 10);
        assert(a.get.all!(x => x == -1));

        for(long i = 0; i < a.length; ++i){
            a.get[i] = i;
        }
        assert(a.get[] == [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]);
    }
}
```

### IntrusivePtr:
```d
nothrow unittest{
    static struct Struct{
        ControlBlock!(int, int) control;
        int i;

        this(int i)pure nothrow @safe @nogc{
            this.i = i;
        }
    }

    static class Base{
        int i;
        ControlBlock!(int, int) control;

        this(int i)pure nothrow @safe @nogc{
            this.i = i;
        }
    }
    static class Derived : Base{
        double d;

        this(int i, double d)pure nothrow @safe @nogc{
            super(i);
            this.d = d;
        }
    }
    static class Class : Derived{
        bool b;
        this(int i, double d, bool b)pure nothrow @safe @nogc{
            super(i, d);
            this.b = b;
        }

        /+~this()nothrow @system{
        }+/
    }

    ///simple:
    {
        IntrusivePtr!Struct a = IntrusivePtr!Struct.make(42);
        assert(a.useCount == 1);

        IntrusivePtr!(const Struct) b = a;
        assert(a.useCount == 2);

        IntrusivePtr!Struct.WeakType w = a.weak;
        assert(a.useCount == 2);
        assert(a.weakCount == 1);

        IntrusivePtr!Struct c = w.lock;
        assert(a.useCount == 3);
        assert(a.weakCount == 1);

        assert(c.get.i == 42);
    }

    ///polymorphism and aliasing:
    {
        ///create IntrusivePtr
        IntrusivePtr!Base foo = IntrusivePtr!Derived.make(42, 3.14);
        IntrusivePtr!Class zee = IntrusivePtr!Class.make(42, 3.14, false);

        ///dynamic cast:
        IntrusivePtr!Derived bar = dynCast!Derived(foo);
        assert(bar != null);
        assert(foo.useCount == 2);

        ///this doesnt work because Foo destructor attributes are more restrictive then Class's:
        //IntrusivePtr!Class x = zee;

        ///this does work:
        IntrusivePtr!Base x = zee;
        assert(zee.useCount == 2);
    }


    ///multi threading:
    {
        ///create IntrusivePtr with atomic ref counting
        IntrusivePtr!(shared Base) foo = IntrusivePtr!(shared Derived).make(42, 3.14);

        ///this doesnt work:
        //foo.get.i += 1;

        import core.atomic : atomicFetchAdd;
        atomicFetchAdd(foo.get.i, 1);
        assert(foo.get.i == 43);


        ///creating `shared(IntrusivePtr)`:
        shared IntrusivePtr!(shared Derived) bar = share(dynCast!Derived(foo));

        ///`shared(IntrusivePtr)` is lock free (except `load` and `useCount`/`weakCount`).
        static assert(typeof(bar).isLockFree == true);

        ///multi thread operations (`load`, `store`, `exchange` and `compareExchange`):
        IntrusivePtr!(shared Derived) bar2 = bar.load();
        assert(bar2 != null);
        assert(bar2.useCount == 3);

        IntrusivePtr!(shared Derived) bar3 = bar.exchange(null);
        assert(bar3 != null);
        assert(bar3.useCount == 3);
    }

}
```
