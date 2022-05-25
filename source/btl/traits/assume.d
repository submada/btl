/**
    TODO

    License:   $(HTTP www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
    Authors:   Adam Búš
*/
module btl.traits.assume;

import std.traits : isFunctionPointer, isDelegate;



/**
    TODO
*/
public auto assumeNoGC(T)(T fn)@trusted
in(isFunctionPointer!T || isDelegate!T){
    import std.traits : functionAttributes, FunctionAttribute, SetFunctionAttributes, functionLinkage;

    enum attrs = functionAttributes!T | FunctionAttribute.nogc;
    return cast(SetFunctionAttributes!(T, functionLinkage!T, attrs)) fn;
}



/**
    TODO
*/
public auto assumePure(T)(T fn)@trusted
in(isFunctionPointer!T || isDelegate!T){
    import std.traits : functionAttributes, FunctionAttribute, SetFunctionAttributes, functionLinkage;

    enum attrs = functionAttributes!T | FunctionAttribute.pure_;
    return cast(SetFunctionAttributes!(T, functionLinkage!T, attrs)) fn;
}



/**
    TODO
*/
public auto assumePureNoGc(T)(T fn)@trusted
in(isFunctionPointer!T || isDelegate!T){
    import std.traits : functionAttributes, FunctionAttribute, SetFunctionAttributes, functionLinkage;

    enum attrs = functionAttributes!T | FunctionAttribute.pure_ | FunctionAttribute.nogc;
    return cast(SetFunctionAttributes!(T, functionLinkage!T, attrs)) fn;
}



/**
    TODO
*/
public auto assumePureNoGcNothrow(T)(T fn)@trusted
in(isFunctionPointer!T || isDelegate!T){
    import std.traits : functionAttributes, FunctionAttribute, SetFunctionAttributes, functionLinkage;

    enum attrs = functionAttributes!T | FunctionAttribute.pure_ | FunctionAttribute.nogc | FunctionAttribute.nothrow_;
    return cast(SetFunctionAttributes!(T, functionLinkage!T, attrs)) fn;
}

