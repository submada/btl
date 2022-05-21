/**
    Ranges with non copyable elements.

    License:   $(HTTP www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
    Authors:   $(HTTP github.com/submada/btl, Adam Búš)
*/
module btl.traits.range;

import std.traits : ReturnType, isAutodecodableString, isAggregateType, lvalueOf;
import std.range : empty, popFront, front, popBack, back, save,
    isInputRange, ElementType, hasLength, isInfinite;




/**
    Same as std.range.isInputRange but support non copyable elements.
*/
public template isBtlInputRange(R){
    static if(isInputRange!R)
        enum bool impl = true;
    else{
        static ref front_check(R)(R r){
            return r.front;
        }
        enum bool impl = true
            && is(typeof(R.init) == R)
            && is(ReturnType!((R r) => r.empty) == bool)
            && is(typeof(*(return ref R r)@trusted => &r.front))
            && !is(ReturnType!(front_check!R) == void)
            && is(typeof((R r) => r.popFront));
    }

    enum bool isBtlInputRange = impl;
};



/**
    Same as std.range.isForwardRange but support non copyable elements.
*/
public enum bool isBtlForwardRange(R) = isBtlInputRange!R
    && is(ReturnType!((R r) => r.save) == R);



/**
    Same as std.range.isBidirectionalRange but support non copyable elements.
*/
public enum bool isBtlBidirectionalRange(R) = isBtlForwardRange!R
    && is(typeof((R r) => r.popBack))
    && is(ReturnType!((R r) => r.back) == ElementType!R);


/**
    Same as std.range.isRandomAccessRange but support non copyable elements.
*/
public enum bool isBtlRandomAccessRange(R) =
    is(typeof(lvalueOf!R[1]) == ElementType!R)
    && !(isAutodecodableString!R && !isAggregateType!R)
    && isBtlForwardRange!R
    && (isBtlBidirectionalRange!R || isInfinite!R)
    && (hasLength!R || isInfinite!R)
    && (isInfinite!R || !is(typeof(lvalueOf!R[$ - 1]))
        || is(typeof(lvalueOf!R[$ - 1]) == ElementType!R));

