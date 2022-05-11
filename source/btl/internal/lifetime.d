module btl.internal.lifetime;


import std.meta : AliasSeq;

import core.lifetime : forward, move;
import std.range : isInputRange, ElementEncodingType;
import std.traits : isDynamicArray;

import btl.internal.traits : isBtlInputRange;

/*
    Type used as parameter for function pointer returned from `DestructorType`.
*/
public struct Evoid{

}

//generate `DestructorTypes` alias
/+version(D_BetterC){}else
private string genDestructorTypes(){
    string result;
    result.reserve(16*40);

    import std.range : empty;
    foreach(string _pure; ["pure", ""])
    foreach(string _nothrow; ["nothrow", ""])
    foreach(string _safe; ["@safe", "@system"])
    foreach(string _nogc; ["@nogc", ""])
        result ~= "void function(void* )" ~ _pure
            ~ (_pure.empty?"":" ") ~ _nothrow
            ~ ((_pure.empty && _nothrow.empty)?"":" ") ~ _safe
            ~ ((_pure.empty && _nothrow.empty && _safe.empty)?"":" ") ~ _nogc
            ~ ",\n";

    return result;
}+/


//create all possible DestructorType types, DestructorType can return type with some hidden information and comparsion with it can fail (bug in D compiler).
//If type is created before calling DestructorType then DestructorType return existing type free of hidden informations and comparsion is ok.
public alias DtorTypes = AliasSeq!(
    void function(Evoid* )pure nothrow @safe @nogc,
    void function(Evoid* )pure nothrow @safe,
    void function(Evoid* )pure nothrow @system @nogc,
    void function(Evoid* )pure nothrow @system,
    void function(Evoid* )pure @safe @nogc,
    void function(Evoid* )pure @safe,
    void function(Evoid* )pure @system @nogc,
    void function(Evoid* )pure @system,
    void function(Evoid* )nothrow @safe @nogc,
    void function(Evoid* )nothrow @safe,
    void function(Evoid* )nothrow @system @nogc,
    void function(Evoid* )nothrow @system,
    void function(Evoid* )@safe @nogc,
    void function(Evoid* )@safe,
    void function(Evoid* )@system @nogc,
    void function(Evoid* )@system,
);



/*
    Check if type `Type` is of type destructor type (is(void function(Evoid* )pure nothrow @safe @nogc : Type))
*/
public template isDtorType(Type){
    enum bool isDtorType = is(
        void function(Evoid* )pure nothrow @safe @nogc : Type
    );
}

//
unittest{
    static assert(isDtorType!(void function(Evoid* )pure));
    static assert(isDtorType!(DtorType!long));
    static assert(!isDtorType!(long));
}



public template ClassDtorType(Type)
if(is(Type == class)){
    import std.traits : Unqual, BaseClassesTuple;
    import std.meta : AliasSeq;

    alias Get(T) = T;
    static void impl()(Evoid*){
        // generate a body that calls all the destructors in the chain,
        // compiler should infer the intersection of attributes
        foreach (B; AliasSeq!(Type, BaseClassesTuple!Type)) {
            alias UB = Unqual!B;

            // __dtor, i.e. B.~this
            static if (__traits(hasMember, B, "__dtor"))
                () { UB obj; obj.__dtor; } ();
            // __xdtor, i.e. dtors for all RAII members
            static if (__traits(hasMember, B, "__xdtor"))
                () { UB obj; obj.__xdtor; } ();
        }
    }

    alias ClassDtorType = Get!(typeof(&impl!()));
}

public template DtorType(Type){

    import std.traits : Unqual, isDynamicArray, BaseClassesTuple;
    import std.range : ElementEncodingType;
    import std.meta : AliasSeq;

    alias Get(T) = T;
    static void impl()(Evoid*){
        static if(is(Unqual!Type == void)){
            //nothing
        }
        else static if(is(Type == interface) || is(Type == class)){
            //nothing
        }
        else{
            Unqual!Type tmp;
        }
    }

    alias DtorType = Get!(typeof(&impl!()));
}



//emplaceImpl & emplaceRangeImpl & emplaceClassImpl
public{
    void emplaceImpl(T, Args...)(ref T elm, auto ref Args args){
        static if(is(T == class) || is(T == interface)){
            import std.traits : Unqual;

            static if(Args.length == 0){
                *(()@trusted => cast(Unqual!T*)&elm )() = null;
            }
            else static if(Args.length == 1 && is(Args[0] : T)){
                T src = args[0];

                ()@trusted{
                    *cast(Unqual!T*)&elm = cast(Unqual!T)src;
                }();
            }
            else{
                static assert(0, "cannot emplace class with parameters " ~ args.stringof ~ ", try emplaceClassImpl instead");
            }
        }
        else{
            import core.lifetime : forward;
            import core.internal.lifetime : emplaceRef;

            emplaceRef!T(elm, forward!args);
        }
    }

    void emplaceImpl(T, S)(ref T elm, return ref S src)
    if(is(T == struct) && is(S == struct) && is(immutable T == immutable S)){
        import core.internal.lifetime : emplaceRef;

        emplaceRef!T(elm, src);

    }

    void emplaceRangeImpl(T, Args...)(T[] slice, auto ref Args args){
        foreach(ref elm; slice)
            emplaceImpl(elm, args);

    }

    void emplaceClassImpl(T, Args...)(T elm, auto ref Args args)
    if(is(T == class)){
        import core.lifetime : forward, emplace;

        emplace(elm, forward!args);
    }
}

//destructImpl & destructRangeImpl & destructClassImpl
public{
    //destructImpl:
    void destructImpl(bool initialize = false, T)(ref T obj){
        destructImpl!(initialize, DtorType!T)(obj);
    }
    void destructImpl(bool initialize, DestructorType, T)(ref T obj)
    if(isDtorType!DestructorType){
        import std.traits : Unqual;
        import btl.internal.traits;

        if(false){
            DestructorType dt;
            dt(null);
        }
        Unqual!T* mutableObj = (()@trusted => cast(Unqual!T*)&obj )();

        static if(is(T == class) || is(T == interface)){
            static if(initialize)
                *mutableObj = null;
        }
        else{
            assumePureNoGcNothrow((Unqual!T* o)@trusted{
                destroy!initialize(*o);
            })(mutableObj);
        }
    }


    //destructRangeImpl:
    void destructRangeImpl(bool initialize = false, T)(T[] slice){
        destructRangeImpl!(initialize, DtorType!T)(slice);

    }
    void destructRangeImpl(bool initialize, DestructorType, T)(T[] slice)
    if(isDtorType!DestructorType){

        static if(is(T == void)){
            if(false){
                DestructorType dt;
                dt(null);
            }

            static if(initialize){} //TODO
        }
        else{
            foreach(ref elm; slice)
                destructImpl!(initialize, DestructorType, T)(elm);

        }
    }


    //class destructor
    private extern(C) void rt_finalize2(void* p, bool det = true, bool resetMemory = false)nothrow @safe @nogc pure;

    //destructClassImpl:
    void destructClassImpl(bool initialize, DestructorType, T)(T obj)
    if(is(T == class) && isDtorType!DestructorType){
        import std.traits : Unqual;
        import btl.internal.traits;

        if(false){
            DestructorType dt;
            dt(null);
        }

        ///C++ class
        static if (__traits(getLinkage, T) == "C++"){
            Unqual!T mutableObj = (()@trusted => cast(Unqual!T)obj )();

            assumePureNoGcNothrow((Unqual!T o)@trusted{
                destroy!initialize(o);
            })(mutableObj);
        }
        ///D class
        static if(__traits(getLinkage, T) == "D"){

            assumePureNoGcNothrow((T o)@trusted{
                //resetMemory must be false because intrusiv pointers can contains control block with weak references.
                rt_finalize2(cast(void*)o, true, initialize);
            })(obj);
        }
        else static assert(0, "no impl");
    }
    void destructClassImpl(bool initialize = false, T)(T obj)
    if(is(T == class)){
        destructClassImpl!(initialize, ClassDtorType!T)(obj);
    }
}

//transferEmplaceImpl
private{
    void transferEmplaceImpl(bool move, S, T)(scope ref T target, return scope ref S source)
    if(is(immutable S == immutable T)){
        static if(move)
            moveEmplaceImpl(target, source);
        else
            copyEmplaceImpl(target, source);
    }

    void transferEmplaceImpl(bool move, S, T)(scope ref T target, return scope ref S source)
    if(!is(immutable S == immutable T) && is(immutable S : immutable T)){
        import std.range : ElementEncodingType;
        import std.traits :
            CopyTypeQualifiers, Unqual,
            isDynamicArray, isStaticArray,
            isPointer, PointerTarget,
            isFunctionPointer, isDelegate;


        static if(is(S == struct) || is(S == union)){
            transferEmplaceImpl!(move, CopyTypeQualifiers!(S, Unqual!T), T)(target, source);
        }
        else static if(isStaticArray!S){
            static if(S.length){
                transferEmplaceRangeImpl!move(
                    (()@trusted => target.ptr )(),
                    (()@trusted => source.ptr )(),
                    T.length
                );
            }
        }
        else static if(is(S == class) || is(S == interface)){
            CopyTypeQualifiers!(S, Unqual!T) src = source;
            transferEmplaceImpl!move(target, src);
        }
        else static if(isDynamicArray!S){
            auto src = ()@trusted{
                return cast(CopyTypeQualifiers!(ElementEncodingType!S, Unqual!(ElementEncodingType!T))[] )source;
            }();
            transferEmplaceImpl!move(target, src);
        }
        else static if(isPointer!S){
            auto src = ()@trusted{
                return cast(CopyTypeQualifiers!(PointerTarget!S, Unqual!(PointerTarget!T))* )source;
            }();
            transferEmplaceImpl!move(target, src);
        }
        else{
            CopyTypeQualifiers!(S, Unqual!T) src = source;
            transferEmplaceImpl!move(target, src);
        }
    }

    void transferEmplaceRangeImpl(bool move, S, T)(T* target, S* source, size_t length)
    if(is(immutable S[] : immutable T[])){
        static if(move)
            moveEmplaceRangeImpl!false(target, source, length);
        else
            copyEmplaceRangeImpl(target, source, length);


    }

    void transferAssignRangeImpl(bool move, S, T)(T* target, S* source, size_t length)
    if(is(immutable S[] : immutable T[])){
        import std.traits : Unqual, hasElaborateAssign;

        if(length == 0)
            return;

        static if (hasElaborateAssign!T){
            for (size_t i = 0; i < length; i++){
                static if(move)
                    *(()@trusted => target + i )() = .move(*(()@trusted => source + i )());
                else
                    *(()@trusted => target + i )() = *(()@trusted => source + i )();

            }
        }
        else // trivial copy
        {
            static assert(T.sizeof == S.sizeof);

            () @trusted{
                import core.stdc.string : memcpy;

                memcpy(
                    cast(Unqual!T*) target,
                    cast(Unqual!T*) source,
                    T.sizeof * length
                );
            }();
        }
    }

    void transferAssignRange(bool move, T, S)(T[] target, ref S[] source){
        import btl.internal.traits : min;

        assert(target.length <= source.length);

        transferAssignRangeImpl!move(
            (()@trusted => target.ptr )(),
            (()@trusted => source.ptr )(),
            target.length//min(target.length, source.length)
        );
    }

    void transferAssignRange(bool move, T, R)(T[] target, ref R source)
    if(isBtlInputRange!R && is(immutable ElementEncodingType!R[] : immutable T[]) && !isDynamicArray!R){
        import std.range ; popFront;
        import core.lifetime : mv = move;

        foreach(ref elm; target){
            assert(!source.empty);

            static if(move)
                elm = mv(source.front);
            else
                elm = source.front;

            source.popFront;
        }
    }
}

//moveEmplaceImpl
public{
    // https://github.com/dlang/druntime/blob/master/src/core/lifetime.d : moveEmplaceImpl
    // target must be first-parameter, because in void-functions DMD + dip1000 allows it to take the place of a return-scope
    void moveEmplaceImpl(S, T)(scope ref T target, return scope ref S source)
    if(is(immutable S == immutable T)){
        // TODO: this assert pulls in half of phobos. we need to work out an alternative assert strategy.
    //    static if (!is(T == class) && hasAliasing!T) if (!__ctfe)
    //    {
    //        import std.exception : doesPointTo;
    //        assert(!doesPointTo(source, source) && !hasElaborateMove!T),
    //              "Cannot move object with internal pointer unless `opPostMove` is defined.");
    //    }

        import core.internal.traits : hasElaborateAssign, isAssignable, hasElaborateMove,
                                      hasElaborateDestructor, hasElaborateCopyConstructor, Unqual;

        Unqual!T* mutableTarget = (()@trusted => cast(Unqual!T*)&target )();
        Unqual!S* mutableSource = (()@trusted => cast(Unqual!S*)&source )();

        static if (is(T == struct))
        {

            //  Unsafe when compiling without -preview=dip1000
            assert((() @trusted => &source !is &target)(), "source and target must not be identical");



            static if (hasElaborateAssign!T || !isAssignable!T)
            {
                import core.stdc.string : memcpy;
                () @trusted{
                    memcpy(
                        mutableTarget,
                        mutableSource,
                        T.sizeof
                    );
                }();
            }
            else
                *mutableTarget = *mutableSource;

            static if (hasElaborateMove!T)
                __move_post_blt(target, source);

            // If the source defines a destructor or a postblit hook, we must obliterate the
            // object in order to avoid double freeing and undue aliasing
            static if (hasElaborateDestructor!T || hasElaborateCopyConstructor!T)
            {
                // If there are members that are nested structs, we must take care
                // not to erase any context pointers, so we might have to recurse
                static if (__traits(isZeroInit, T))
                    wipe(source);
                else
                    wipe(source, ref () @trusted { return *cast(immutable(T)*) __traits(initSymbol, T).ptr; } ());
            }
        }
        else static if (__traits(isStaticArray, T))
        {
            static if (T.length)
            {
                /+moveEmplaceRangeImpl!false(
                    (()@trusted => target.ptr )(),
                    (()@trusted => source.ptr )(),
                    T.length
                );+/
                static if (!hasElaborateMove!T &&
                           !hasElaborateDestructor!T &&
                           !hasElaborateCopyConstructor!T)
                {
                    // Single blit if no special per-instance handling is required
                    () @trusted
                    {
                        assert(source.ptr !is target.ptr, "source and target must not be identical");
                        *cast(ubyte[T.sizeof]*) &target = *cast(ubyte[T.sizeof]*) &source;
                    } ();
                }
                else
                {
                    for (size_t i = 0; i < source.length; ++i)
                        moveEmplaceImpl(target[i], source[i]);
                }

            }
        }
        else
        {
            // Primitive data (including pointers and arrays) or class -
            // assignment works great
            static if(is(S : T)){

                *mutableTarget = *mutableSource;

            }
            else
                static assert(0, "no impl");
        }
    }

    void moveEmplaceImpl(S, T)(scope ref T target, return scope ref S source)
    if(!is(immutable S == immutable T) && is(immutable S : immutable T)){
        transferEmplaceImpl!true(target, source);
    }

    void moveEmplaceRangeImpl(bool overlap = true, S, T)(T* target, S* source, size_t length)
    if(is(immutable S[] : immutable T[])){
        import std.traits : hasElaborateMove, hasElaborateDestructor, hasElaborateCopyConstructor, Unqual;

        if(length == 0)
            return;

        static if(is(immutable S* : immutable T*)
            && !hasElaborateMove!T
            && !hasElaborateDestructor!T
            && !hasElaborateCopyConstructor!T
        ){
            // Single blit if no special per-instance handling is required
            /+() @trusted{
                assert(source.ptr !is target.ptr, "source and target must not be identical");
                *cast(ubyte[T.sizeof]*) target = *cast(ubyte[T.sizeof]*) source;
            }();+/

            static assert(T.sizeof == S.sizeof);

            () @trusted{
                import core.stdc.string : memcpy, memmove;
                static if(overlap)
                    memmove(
                        cast(Unqual!T*) target,
                        cast(Unqual!T*) source,
                        T.sizeof * length
                    );
                else
                    memcpy(
                        cast(Unqual!T*) target,
                        cast(Unqual!T*) source,
                        T.sizeof * length
                    );
            }();
        }
        else{

            if(!overlap || target < source){
                for(size_t i = 0; i < length; ++i){
                    //moveEmplace(source[i], target[i]);
                    moveEmplaceImpl(
                        *(()@trusted => target + i )(),
                        *(()@trusted => source + i )()
                    );
                }
            }
            else{
                size_t i = length;
                do{
                    i -= 1;
                    moveEmplaceImpl(
                        *(()@trusted => target + i )(),
                        *(()@trusted => source + i )()
                    );

                }while(i > 0);
            }
        }

    }

    void moveAssignRangeImpl(S, T)(T* target, S* source, size_t length)
    if(is(immutable S[] : immutable T[])){
        transferAssignRangeImpl!true(target, source, length);
    }

    void moveAssignRange(T, R)(T[] target, ref R source)
    if(isBtlInputRange!R && is(immutable ElementEncodingType!R[] : immutable T[])){
        transferAssignRange!true(target, source);
    }

    @safe pure nothrow @nogc unittest{
        {
            const int trg;
            int src;
            moveEmplaceImpl(trg, src);
        }
        {
            const long trg;
            int src;
            moveEmplaceImpl(trg, src);
        }
        {
            const int* trg;
            int* src;
            moveEmplaceImpl(trg, src);
        }
        {
            const int* trg;
            int* src;
            moveEmplaceImpl(trg, src);
        }
        {
            struct S{
                void* p;
                int i;
            }
            const S trg;
            S src;
            moveEmplaceImpl(trg, src);
        }
        {
            struct S{
                void* p;
                int i;
                ~this(){}
            }
            const S trg;
            S src;
            moveEmplaceImpl(trg, src);
        }
        {
            struct S{
                void* p;
                int i;
                ~this(){}
            }
            const S[4] trg;
            S[4] src;
            moveEmplaceImpl(trg, src);
        }
        {
            static class B{}
            static class D : B{}
            {
                const B trg;
                D src;
                moveEmplaceImpl(trg, src);
            }
            {
                const B[] trg;
                D[] src;
                moveEmplaceImpl(trg, src);
            }
            {
                const B* trg;
                D* src;
                moveEmplaceImpl(trg, src);
            }
            {
                const B[4] trg;
                D[4] src;
                moveEmplaceImpl(trg, src);
            }
        }

        {
            void delegate()@system trg;
            void delegate()@safe src;
            moveEmplaceImpl(trg, src);

        }

    }

    // https://github.com/dlang/druntime/blob/master/src/core/lifetime.d : wipe
    // wipes source after moving
    pragma(inline, true)
    private void wipe(T, Init...)(return scope ref T source, ref const scope Init initializer) @trusted
    if (!Init.length ||
        ((Init.length == 1) && (is(immutable T == immutable Init[0]))))
    {
        static if (__traits(isStaticArray, T) && hasContextPointers!T)
        {
            for (auto i = 0; i < T.length; i++)
                static if (Init.length)
                    wipe(source[i], initializer[0][i]);
                else
                    wipe(source[i]);
        }
        else static if (is(T == struct) && hasContextPointers!T)
        {
            import core.internal.traits : anySatisfy;
            static if (anySatisfy!(hasContextPointers, typeof(T.tupleof)))
            {
                static foreach (i; 0 .. T.tupleof.length - __traits(isNested, T))
                    static if (Init.length)
                        wipe(source.tupleof[i], initializer[0].tupleof[i]);
                    else
                        wipe(source.tupleof[i]);
            }
            else
            {
                static if (__traits(isNested, T))
                    enum sz = T.tupleof[$-1].offsetof;
                else
                    enum sz = T.sizeof;

                static if (Init.length)
                    *cast(ubyte[sz]*) &source = *cast(ubyte[sz]*) &initializer[0];
                else
                    *cast(ubyte[sz]*) &source = 0;
            }
        }
        else
        {
            import core.internal.traits : hasElaborateAssign, isAssignable;
            static if (Init.length)
            {
                static if (hasElaborateAssign!T || !isAssignable!T)
                    *cast(ubyte[T.sizeof]*) &source = *cast(ubyte[T.sizeof]*) &initializer[0];
                else
                    source = *cast(T*) &initializer[0];
            }
            else
            {
                *cast(ubyte[T.sizeof]*) &source = 0;
            }
        }
    }

    // https://github.com/dlang/druntime/blob/master/src/core/lifetime.d : hasContextPointers
    private enum bool hasContextPointers(T) = {
        static if (__traits(isStaticArray, T))
        {
            return hasContextPointers!(typeof(T.init[0]));
        }
        else static if (is(T == struct))
        {
            import core.internal.traits : anySatisfy;
            return __traits(isNested, T) || anySatisfy!(hasContextPointers, typeof(T.tupleof));
        }
        else return false;
    } ();
}

//copyEmplaceImpl
public{
    // https://github.com/dlang/druntime/blob/master/src/core/lifetime.d : copyEmplace
    void copyEmplaceImpl(S, T)(ref T target, return auto ref S source)
    if (is(immutable S == immutable T)){
        emplaceImpl(target, source);
        /+import core.internal.traits : BaseElemOf, hasElaborateCopyConstructor, Unconst, Unqual;

        // cannot have the following as simple template constraint due to nested-struct special case...
        static if (!__traits(compiles, (ref S src) { T tgt = src; }))
        {
            alias B = BaseElemOf!T;
            enum isNestedStruct = is(B == struct) && __traits(isNested, B);
            static assert(isNestedStruct, "cannot copy-construct " ~ T.stringof ~ " from " ~ S.stringof);
        }

        Unqual!T* mutableTarget = (()@trusted => cast(Unqual!T*)&target )();
        Unqual!S* mutableSource = (()@trusted => cast(Unqual!S*)&source )();

        void blit()
        {
            import core.stdc.string : memcpy;
            ()@trusted{
                memcpy(mutableTarget, mutableSource, T.sizeof);
            }();
        }

        static if (is(T == struct))
        {
            static if (__traits(hasPostblit, T))
            {
                blit();
                (cast() target).__xpostblit();
            }
            else static if (__traits(hasCopyConstructor, T))
            {
                emplace(cast(Unqual!(T)*) &target); // blit T.init
                static if (__traits(isNested, T))
                {
                     // copy context pointer
                    *(cast(void**) &target.tupleof[$-1]) = cast(void*) source.tupleof[$-1];
                }
                target.__ctor(source); // invoke copy ctor
            }
            else
            {
                blit(); // no opAssign
            }
        }
        else static if (is(T == E[n], E, size_t n))
        {
            static if(n){
                copyEmplaceRangeImpl(
                    (()@trusted => target.ptr )(),
                    (()@trusted => source.ptr )(),
                    T.length
                );
            }
            /+static if (hasElaborateCopyConstructor!E)
            {
                size_t i;
                scope(failure){
                    // destroy, in reverse order, what we've constructed so far
                    while (i--)
                        destroy(*cast(Unconst!(E)*) &target[i]);

                }
                for (i = 0; i < n; i++)
                    copyEmplaceImpl(target[i], source[i]);
            }
            else // trivial copy
            {
                blit(); // all elements at once
            }+/
        }
        else
        {
            *mutableTarget = *mutableSource;
        }+/
    }

    void copyEmplaceImpl(S, T)(ref T target, return ref S source)
    if(!is(immutable S == immutable T) && is(immutable S : immutable T)){
        transferEmplaceImpl!false(target, source);
    }

    void copyEmplaceRangeImpl(S, T)(T* target, S* source, size_t length)
    if(is(immutable S[] : immutable T[])){
        import std.traits : Unqual, hasElaborateCopyConstructor;

        if(length == 0)
            return;

        static if (hasElaborateCopyConstructor!T){
            size_t i;
            scope(failure){
                // destroy, in reverse order, what we've constructed so far
                while (i--)
                    destroy(*cast(Unconst!T*) &target[i]);

            }
            for (i = 0; i < length; i++)
                copyEmplaceImpl(
                    *(()@trusted => target + i )(),
                    *(()@trusted => source + i )()
                );
        }
        else // trivial copy
        {
            static assert(T.sizeof == S.sizeof);

            () @trusted{
                import core.stdc.string : memcpy;

                memcpy(
                    cast(Unqual!T*) target,
                    cast(Unqual!T*) source,
                    T.sizeof * length
                );
            }();
        }
    }

    void copyAssignRangeImpl(S, T)(T* target, S* source, size_t length)
    if(is(immutable S[] : immutable T[])){
        transferAssignRangeImpl!false(target, source, length);
    }

    void copyAssignRange(T, R)(T[] target, ref R source)
    if(isBtlInputRange!R && is(immutable ElementEncodingType!R[] : immutable T[])){
        transferAssignRange!false(target, source);
    }

    @safe pure nothrow @nogc unittest{
        {
            const int trg;
            int src;
            copyEmplaceImpl(trg, src);
        }
        {
            const long trg;
            int src;
            copyEmplaceImpl(trg, src);
        }
        {
            const int* trg;
            int* src;
            copyEmplaceImpl(trg, src);
        }
        {
            const int* trg;
            int* src;
            copyEmplaceImpl(trg, src);
        }
        {
            struct S{
                void* p;
                int i;
            }
            const S trg;
            S src;
            copyEmplaceImpl(trg, src);
        }
        {
            struct S{
                void* p;
                int i;
                ~this(){}
            }
            const S trg;
            S src;
            copyEmplaceImpl(trg, src);
        }
        {
            struct S{
                void* p;
                int i;
                ~this(){}
            }
            const S[4] trg;
            S[4] src;
            copyEmplaceImpl(trg, src);
        }
        {
            static class B{}
            static class D : B{}
            {
                const B trg;
                D src;
                copyEmplaceImpl(trg, src);
            }
            {
                const B[] trg;
                D[] src;
                copyEmplaceImpl(trg, src);
            }
            {
                const B* trg;
                D* src;
                copyEmplaceImpl(trg, src);
            }
            {
                const B[4] trg;
                D[4] src;
                copyEmplaceImpl(trg, src);
            }
        }

        {
            void delegate()@system trg;
            void delegate()@safe src;
            copyEmplaceImpl(trg, src);

        }

    }
}




