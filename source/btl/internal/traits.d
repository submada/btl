/*
    License:   $(HTTP www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
    Authors:   Adam Búš
*/
module btl.internal.traits;

import std.traits : isSomeChar, isArray;
import std.range : ElementEncodingType, isInputRange;



public enum isCharArray(T) = true
    && is(T : C[N], C, size_t N)
    && isSomeChar!C;

public template isInputCharRange(T){

    enum bool isInputCharRange = true
        && isSomeChar!(ElementEncodingType!T)
        && (isInputRange!T || isArray!T);
}


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


