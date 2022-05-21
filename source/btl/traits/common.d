/**
    TODO

    License:   $(HTTP www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
    Authors:   $(HTTP github.com/submada/btl, Adam Búš)
*/
module btl.traits.common;

import std.traits : isSomeChar, isArray;



/**
    Type used in forward constructors.
*/
public struct Forward{}



/**
    same as `__traits(isRef, var)`.
*/
public enum bool isRef(alias var) = __traits(isRef, var);



/**
    TODO
*/
version(D_BetterC){
    public enum bool platformSupportGC = false;
}
else{
    public enum bool platformSupportGC = true;
}



/**
    TODO
*/
template shouldAddGCRange(T){
    import std.traits;

    enum shouldAddGCRange = true
        && platformSupportGC
        && hasIndirections!T;
}



/**
    remove `shared` from type `T`.
*/
public alias Unshared(T) = T;
public alias Unshared(T: shared U, U) = U;



/**
    Same as `std.traits.hasIndirections` but for classes.
*/
public template classHasIndirections(T){
    import std.traits : hasIndirections;

    static if(is(T == class)){
        enum bool classHasIndirections = (){

            import std.traits : BaseClassesTuple;
            import std.meta : AliasSeq;

            bool has_indirection = false;

            static foreach (alias B; AliasSeq!(T, BaseClassesTuple!T)) {
                static foreach(alias Var; typeof(B.init.tupleof)){
                    static if(hasIndirections!Var)
                        has_indirection = true;
                }
            }

            return has_indirection;
        }();
    }
    else{
        enum bool classHasIndirections = false;
    }
}


//alias to `T` if `T` is class or interface, otherwise `T*`.
/+public template PtrOrRef(T){
    static if(is(T == class) || is(T == interface))
        alias PtrOrRef = T;
    else
        alias PtrOrRef = T*;
}+/


/**
    `true` if `T` is class or interface.
*/
public enum bool isClassOrInterface(T) = is(T == class) || is(T == interface);



/**
    Size of instance, if `T` is class then `__traits(classInstanceSize, T)`, otherwise `T.sizeof`
*/
public template instanceSize(T){
    static if(is(T == class))
        enum size_t instanceSize = __traits(classInstanceSize, T);
    else
        enum size_t instanceSize = T.sizeof;
}


/*
    [Copy, Move] ConstructableElement:
*/
template isCopyConstructableElement(From, To = From){
    enum isCopyConstructableElement = true
        && is(typeof((ref From from){
            To tmp = from;
        }));
}

// ditto
template isMoveConstructableElement(From, To = From){
    import core.lifetime : move;
    enum isMoveConstructableElement = true
        && is(typeof((From from){
            To tmp = move(from);
        }));
}



/*
    [Copy, Move] AssignableElement:
*/
template isCopyAssignableElement(From, To = From){
    enum isCopyAssignableElement = true
        && is(typeof((ref From from, ref To to){
            to = from;
        }));
}

// ditto
template isMoveAssignableElement(From, To = From){
    import core.lifetime : move;
    enum isMoveAssignableElement = true
        && is(typeof((From from, ref To to){
            to = move(from);
        }));
}





