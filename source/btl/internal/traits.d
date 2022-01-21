module btl.internal.traits;

import std.traits : isFunctionPointer, isDelegate, isSomeChar, isArray;
import std.range : ElementEncodingType, isInputRange;

version(D_BetterC){
    public enum bool platformSupportGC = false;
}
else{
    public enum bool platformSupportGC = true;
}

public auto assumeNoGC(T)(T t)@trusted
in(isFunctionPointer!T || isDelegate!T){
    import std.traits : functionAttributes, FunctionAttribute, SetFunctionAttributes, functionLinkage;

    enum attrs = functionAttributes!T | FunctionAttribute.nogc;
    return cast(SetFunctionAttributes!(T, functionLinkage!T, attrs)) t;
}


public auto assumePure(T)(T t)@trusted
in(isFunctionPointer!T || isDelegate!T){
    import std.traits : functionAttributes, FunctionAttribute, SetFunctionAttributes, functionLinkage;

    enum attrs = functionAttributes!T | FunctionAttribute.pure_;
    return cast(SetFunctionAttributes!(T, functionLinkage!T, attrs)) t;
}


public auto assumePureNoGc(T)(T t)@trusted
in(isFunctionPointer!T || isDelegate!T){
    import std.traits : functionAttributes, FunctionAttribute, SetFunctionAttributes, functionLinkage;

    enum attrs = functionAttributes!T | FunctionAttribute.pure_ | FunctionAttribute.nogc;
    return cast(SetFunctionAttributes!(T, functionLinkage!T, attrs)) t;
}


public auto assumePureNoGcNothrow(T)(T t)@trusted
in(isFunctionPointer!T || isDelegate!T){
    import std.traits : functionAttributes, FunctionAttribute, SetFunctionAttributes, functionLinkage;

    enum attrs = functionAttributes!T | FunctionAttribute.pure_ | FunctionAttribute.nogc | FunctionAttribute.nothrow_;
    return cast(SetFunctionAttributes!(T, functionLinkage!T, attrs)) t;
}


public enum bool isRef(alias var) = false
    || __traits(isRef, var)
    || __traits(isOut, var);


public enum isCharArray(T) = true
    && is(T : C[N], C, size_t N)
    && isSomeChar!C;

public template isInputCharRange(T){

    enum bool isInputCharRange = true
        && isSomeChar!(ElementEncodingType!T)
        && (isInputRange!T || isArray!T);
}

//remove `shared` from type `T`.
public alias Unshared(T) = T;
public alias Unshared(T: shared U, U) = U;


//Same as `std.traits.hasIndirections` but for classes.
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
public template PtrOrRef(T){
    static if(is(T == class) || is(T == interface))
        alias PtrOrRef = T;
    else
        alias PtrOrRef = T*;
}


//`true` if `T` is class or interface.
public enum bool isReferenceType(T) = is(T == class) || is(T == interface);


//alias to `AliasSeq` containing `T` if `T` has state, otherwise a empty tuple.
public template AllocatorWithState(T){
    import std.experimental.allocator.common : stateSize;
    import std.meta : AliasSeq;

    enum bool hasStatelessAllocator = (stateSize!T == 0);

    static if(stateSize!T == 0)
        alias AllocatorWithState = AliasSeq!();
    else
        alias AllocatorWithState = AliasSeq!T;
}


public template isStatelessAllocator(T){
    import std.experimental.allocator.common : stateSize;

    enum isStatelessAllocator = (stateSize!T == 0);
}

//alias to stateless allocator instance
public template statelessAllcoator(T){
    import std.experimental.allocator.common : stateSize;
    import std.traits : hasStaticMember;

    static assert(stateSize!T == 0);

    static if(hasStaticMember!(T, "instance"))
        alias statelessAllcoator = T.instance;
    else 
        enum T statelessAllcoator = T.init;   
}


//Size of instance, if `T` is class then `__traits(classInstanceSize, T)`, otherwise `T.sizeof`
public template instanceSize(T){
    static if(is(T == class))
        enum size_t instanceSize = __traits(classInstanceSize, T);
    else
        enum size_t instanceSize = T.sizeof;

}


import core.lifetime : move;
public enum bool isConstructableFromRvalue(T) = is(typeof((T x){
    T tmp = move(x);
    return true;
}()));


//min/max:
version(D_BetterC){

    public auto min(A, B)(auto ref A a, auto ref B b){
        return (a < b)
            ? a
            : b;
    }
    public auto max(A, B)(auto ref A a, auto ref B b){
        return (a > b)
            ? a
            : b;
    }
}
else{
    public import std.algorithm.comparison :  min, max;
}


