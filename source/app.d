module btl.app;

import std.algorithm : map;

import btl.autoptr.shared_ptr;
import btl.autoptr.unique_ptr;
import btl.autoptr.intrusive_ptr;
import btl.autoptr.rc_ptr;
import btl.autoptr.common;
import btl.string;
import btl.vector;


import std.stdio;
import std.conv;


version(D_BetterC){
    extern(C)void main(){
        main_impl();
    }
}
else
    void main(){
        main_impl();
    }


import std.traits : isDynamicArray;

auto trustedGet(Ptr)(ref scope Ptr ptr)@trusted
if(is(Ptr.ElementType == class) || is(Ptr.ElementType == interface) || isDynamicArray!(Ptr.ElementType)){
    return ptr.get();
}

ref auto trustedGet(Ptr)(ref scope Ptr ptr)@trusted
if(!is(Ptr.ElementType == class) && !is(Ptr.ElementType == interface) && !isDynamicArray!(Ptr.ElementType)){
    return ptr.get();
}


void testasdasd(){

    {
        SmallVector!(const SharedPtr!int, 1) vec;

        vec.append(SharedPtr!int.make(42));
        //vec.append(SmartPtr!int.make(42));
        //vec.append(42);
    }

    {
        static struct Foo{
            void *ptr;

            this(ref typeof(this) rhs){}
            @disable void opAssign(ref typeof(this) rhs){}
            @disable void opAssign(typeof(this) rhs){}
        }

        SmallVector!(const Foo, 1) vec;

        //vec.append(const(Foo).init);
        //vec.append(SmartPtr!int.make(42));
        //vec.append(42);
    }
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

//static assert(is(SharedControlBlock* : immutable(SharedControlBlock)*));
void main_impl(){
    {
        import btl.vector.flat_map;
        
        import btl.string;
        FlatMap!(String, int, 4) dic;
        dic.reserve(100);

        dic["3"] = 3;
        dic["2"] = 2;
        dic["1"] = 1;

        assert(*dic.at("1") == 1);
        assert(*dic.at("2") == 2);
        assert(*dic.at("3") == 3);
        assert(dic.at("4") is null);

        assert(dic["1"] == 1);
        assert(dic["2"] == 2);
        assert(dic["3"] == 3);
        assert(dic["4"] == 0);
        assert(dic["0"] == 0);

        dic["3"] = 42;
        assert(dic["3"] == 42);

        foreach(ref pair; dic[]){
            writeln(pair.key[], " : ", pair.value);
        }
        if(auto pair = dic.at(String("0"))){

        }
    }

    import core.lifetime : move;
    auto p = SharedPtr!(long, const SharedControlBlock).make(42);
    auto p2 = move(p);


    static struct Foo{
        ControlBlock!int control;
    }

    auto ip = IntrusivePtr!(shared Foo).make();
    shared IntrusivePtr!(Foo) sip = ip;


    {
        UniquePtr!long u = UniquePtr!long.make(45);
        auto x = u.move;

    }


    //SmallVector!(String, 2) vec;
    shared String str;
    str.__dtor();
    test_123456();

    //-------------------------------------

    import btl.list;

    {
        List!int list;

        ()pure nothrow @safe @nogc{
            assert(list.empty);
            list.emplaceBack(1);
            list.append(2, 2);
            list ~= (3);
            //assert(list.length == 3);

            list.emplaceFront(42);
            list.prepend(314, 2);
        }();

        foreach(x; list[])
            writeln(x);

        ()pure nothrow @safe @nogc{
            assert(42L in list);
            assert(666 !in list);
        }();

        writeln("-----------------------------");


        ()pure nothrow @safe @nogc{
            assert(list.popFront == 314);
            assert(list.popBack == 3);
            list.popFront!void;
            list.popBack!void;
        }();

        foreach(x; list[])
            writeln(x);

        assert(list == list[]);
        assert(list == list);
    }

    //assert(list.length != 3);

    {
        List!(UniquePtr!int) ulist;

        ulist ~= UniquePtr!int.make(42);
        ulist ~= UniquePtr!int.make(314);
        assert(ulist.length == 2);
        assert(ulist.front.get == 42);
        assert(ulist.moveFront.get == 42);
        assert(ulist.front == null);
        //assert(ulist.copyFront.get == 42);

        assert(ulist.length == 2);
        assert(ulist.popBack.get == 314);
        assert(ulist.length == 1);
        ulist.clear();
        assert(ulist.empty);


    }

    {
        List!int list = [1, 2, 3, 4];
        List!int list2 = move(list);
    }

}
/*
struct TestUPTR{
    UniquePtr!int test;
}*/

void test_123456()@safe{
    static class Data1 {
        SharedControlBlock referenceCounter;
        this() @safe{
            writeln("Data1");
        }
    }
    static class Data2 {
        SharedControlBlock referenceCounter;
        this(int i)@safe {
            writeln("Data2");
        }
    }

    alias RCClass1 = IntrusivePtr!Data1;
    alias RCClass2 = IntrusivePtr!Data2;


    auto t1 = RCClass1.make();
    auto t2 = RCClass2.make(1);

}


import btl.internal.test_allocator;




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

///`SharedPtr`:
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

        for(int i = 0; i < a.length; ++i){
            a.get[i] = i;
        }
        assert(a.get[] == [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]);

        ///aliasing:
        SharedPtr!long a6 = SharedPtr!long(a, &a.get[6]);
        assert(*a6 == a.get[6]);
    }
}

///`UniquePtr`:
unittest{
    ///simple:
    {
        import core.lifetime : move;
        SharedPtr!long a = SharedPtr!long.make(42);
        SharedPtr!(const long) b = move(a);
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
        //UniquePtr!Foo x = zee.move;

        ///this does work:
        import core.lifetime : move;
        UniquePtr!(Foo, DestructorType!(Foo, Zee)) x = zee.move;
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

        for(int i = 0; i < a.length; ++i){
            a.get[i] = i;
        }
        assert(a.get[] == [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]);
    }
}



///`RcPtr`:
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

        for(int i = 0; i < a.length; ++i){
            a.get[i] = i;
        }
        assert(a.get[] == [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]);
    }
}






struct Allocator(T){
    T allocator;

    this(ref T allocator){
        this.allocator = allocator;
    }

    this(T allocator){
        import core.lifetime : forward;
        this.allocator = forward!allocator;
    }

    this(ref Allocator!T a){
        this.allocator = a.allocator;
    }

    void opAssing(Allocator!T a){
        import core.lifetime : forward;
        this.allocator = forward!(a.allocator);
    }

    void[] allocate()(const size_t n){
        auto element = (()@trusted => this.allocator.element)();

        return element.allocate(n);
    }

    bool deallocate()(void[] data){
        auto element = (()@trusted => this.allocator.element)();

        return element.deallocate(data);
    }
}

struct Query{
    import std.experimental.allocator.mallocator;

    ControlBlock!int control;

    void[] allocate(const size_t n)pure nothrow @safe @nogc{
        return Mallocator.instance.allocate(n);
    }
    bool deallocate(void[] data)pure nothrow @nogc{
        return Mallocator.instance.deallocate(data);
    }

    auto make(T : Column, Args...)(auto ref Args args){
        auto a = Allocator!(IntrusivePtr!Query)(intrusivePtr(&this));
        /+pragma(msg, DestructorAllocatorType!(typeof(a)));
        pragma(msg, .DestructorType!(DestructorAllocatorType!(typeof(a))));
        pragma(msg, .DestructorType!(void function(Evoid*) nothrow @system));
        static assert(is(void function(Evoid*)pure nothrow @safe @nogc : void function(Evoid*) nothrow @system));
        pragma(msg, .DestructorType!(void function(Evoid*) nothrow @system));+/

        return SharedPtr!T.alloc(a);


    }

    ~this(){
        import std.stdio;
        debug writeln("Query.~this()");
    }
}

class Column{

}

void testQuery(){

    static assert(is(void function(Evoid*) pure nothrow @nogc @safe : void function(Evoid*) @system));


    {
        auto query = IntrusivePtr!Query.make();

        /+auto c = +/query.get.make!Column();
        //assert(query.useCount == 2);
    }

}



unittest{
    {
        auto a = RcPtr!int.make(1);
        auto b = a;
        RcPtr!int.WeakType x = a;
        assert(a.useCount == 2);
        assert(a.weakCount == 1);
    }
    {
        import core.lifetime : move;

        auto a = RcPtr!int.make(1);
        auto b = a;
        assert(a.useCount == 2);
        assert(a.weakCount == 0);

        RcPtr!int.WeakType x = move(a);
        assert(b.useCount == 1);
        assert(b.weakCount == 1);
    }
}



