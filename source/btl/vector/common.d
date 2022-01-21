module btl.vector.common;



public void emplaceElement(T, Args...)(ref T elm, auto ref Args args)nothrow{
    import core.lifetime : forward;
    import core.internal.lifetime : emplaceRef;

    emplaceRef!T(elm, forward!args);
}
/+
public void emplaceElements(T, Args...)(T[] elements, auto ref Args args)nothrow{
    import core.internal.lifetime : emplaceRef;

    foreach(ref elm; elements)
        emplaceElement(elm, args);
}+/


public void initElements(T)(T[] elements)nothrow{
    enum has_init = __traits(compiles, () => emplaceElement(elm));

    static if(has_init){
        foreach(ref elm; elements)
            emplaceElement(elm);
        return true;
    }
    else{
        import std.traits : Unqual;

        assert(0, "fatal error: " ~ Unqual!T.stringof ~ " has @disabled init");

    }


}


public void destroyElement(T)(ref T elm)nothrow{
    import std.traits : hasElaborateDestructor, Unqual;



    static if(hasElaborateDestructor!T)
        destroy!false(*(()@trusted => cast(Unqual!T*)&elm )());
}

public void destroyElements(T)(T[] elements)nothrow{
    import std.traits : hasElaborateDestructor, Unqual;

    static if(hasElaborateDestructor!T)
        foreach(ref elm; (()@trusted => cast(Unqual!T[])elements )())
            destroy!false(elm);
}


public void moveElement(T, U)(ref U source, ref T target)nothrow{
    moveEmplaceImpl(target, source);
}

public void moveElements(bool overlap = true, T, U)(U* source, T* target, const size_t length)nothrow
if(is(immutable T == immutable U)){
    assert(source != target);

    static if(!overlap)
        ()@trusted{
            assert((source + length) <= target || (target + length) <= source);
        }();

    import std.traits : hasElaborateMove;

    static if(hasElaborateMove!T){

        import core.lifetime : move;

        if(!overlap || target < source){
            for(size_t i = 0; i < length; ++i){
                //moveEmplace(source[i], target[i]);
                moveEmplaceImpl(
                    *(()@trusted => target +i )(),
                    *(()@trusted => source +i )()
                );
            }
        }
        else{
            for(size_t i = length; i != 0; --i){
                //moveEmplace(source[i-1], target[i-1]);
                moveEmplaceImpl(
                    *(()@trusted => target + i - 1)(),
                    *(()@trusted => source + i - 1 )()
                );
            }
        }
    }
    else{
        ()@trusted{
            import core.stdc.string : memmove, memcpy;

            static if(overlap)alias op = memmove;
            else alias op = memcpy;

            op(
                cast(void*)target,
                cast(void*)source,
                (length * T.sizeof)
            );

        }();
    }
}

//source: core.lifetime:
// target must be first-parameter, because in void-functions DMD + dip1000 allows it to take the place of a return-scope
private void moveEmplaceImpl(T)(scope ref T target, return scope ref T source)
{
    import core.stdc.string : memcpy, memset;
    import core.internal.traits;

    // TODO: this assert pulls in half of phobos. we need to work out an alternative assert strategy.
//    static if (!is(T == class) && hasAliasing!T) if (!__ctfe)
//    {
//        import std.exception : doesPointTo;
//        assert(!doesPointTo(source, source) && !hasElaborateMove!T),
//              "Cannot move object with internal pointer unless `opPostMove` is defined.");
//    }

    static if (is(T == struct))
    {
        //  Unsafe when compiling without -dip1000
        assert((() @trusted => &source !is &target)(), "source and target must not be identical");

        static if (hasElaborateAssign!T || !isAssignable!T)
            () @trusted { memcpy(&target, &source, T.sizeof); }();
        else
            target = source;

        static if (hasElaborateMove!T)
            __move_post_blt(target, source);

        // If the source defines a destructor or a postblit hook, we must obliterate the
        // object in order to avoid double freeing and undue aliasing
        static if (hasElaborateDestructor!T || hasElaborateCopyConstructor!T)
        {
            // If T is nested struct, keep original context pointer
            static if (__traits(isNested, T))
                enum sz = T.sizeof - (void*).sizeof;
            else
                enum sz = T.sizeof;

            static if (__traits(isZeroInit, T))
                () @trusted { memset(&source, 0, sz); }();
            else
            {
                auto init = typeid(T).initializer();
                () @trusted { memcpy(&source, init.ptr, sz); }();
            }
        }
    }
    else static if (__traits(isStaticArray, T))
    {
        for (size_t i = 0; i < source.length; ++i)
            move(source[i], target[i]);
    }
    else
    {
        // Primitive data (including pointers and arrays) or class -
        // assignment works great
        target = source;
    }
}




