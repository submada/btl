/*
    License:   $(HTTP www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
    Authors:   Adam Búš
*/
module btl.string.encoding;

import std.traits : isSomeChar;



/*
    Same as std.utf.isValidDchar.
*/
public bool isValidDchar(dchar c) pure nothrow @safe @nogc{
    return (c < 0xD800) || (0xDFFF < c && c <= 0x10FFFF);
}



/*
    Same as std.utf.codeLength.
*/
public ubyte codeLength(C)(dchar c) @safe pure nothrow @nogc
if(isSomeChar!C){
    static if (C.sizeof == 1)
    {
        if (c <= 0x7F) return 1;
        if (c <= 0x7FF) return 2;
        if (c <= 0xFFFF) return 3;
        if (c <= 0x10FFFF) return 4;
        assert(false);
    }
    else static if (C.sizeof == 2)
    {
        return c <= 0xFFFF ? 1 : 2;
    }
    else
    {
        static assert(C.sizeof == 4);
        return 1;
    }
}


private enum dchar replacementDchar = '\uFFFD';


/*
    Modification of std.utf.encode where output buffer is not fixed array but slice.
*/
public template encode(To){
    //import std.utf : isValidDchar;

    size_t encode(dchar from, To[] to)pure nothrow @safe @nogc{
        return encode_impl(to, from);
    }



    //https://github.com/dlang/phobos/blob/master/std/utf.d#L2264
    size_t encode_impl(char[] buf, dchar c) @safe pure nothrow @nogc{
        if (c <= 0x7F)
        {
            assert(isValidDchar(c));
            buf[0] = cast(char) c;
            return 1;
        }
        if (c <= 0x7FF)
        {
            assert(isValidDchar(c));
            buf[0] = cast(char)(0xC0 | (c >> 6));
            buf[1] = cast(char)(0x80 | (c & 0x3F));
            return 2;
        }
        if (c <= 0xFFFF)
        {
            if (0xD800 <= c && c <= 0xDFFF)
                c = replacementDchar;   //_utfException!useReplacementDchar("Encoding a surrogate code point in UTF-8", c);

            assert(isValidDchar(c));
        L3:
            buf[0] = cast(char)(0xE0 | (c >> 12));
            buf[1] = cast(char)(0x80 | ((c >> 6) & 0x3F));
            buf[2] = cast(char)(0x80 | (c & 0x3F));
            return 3;
        }
        if (c <= 0x10FFFF)
        {
            assert(isValidDchar(c));
            buf[0] = cast(char)(0xF0 | (c >> 18));
            buf[1] = cast(char)(0x80 | ((c >> 12) & 0x3F));
            buf[2] = cast(char)(0x80 | ((c >> 6) & 0x3F));
            buf[3] = cast(char)(0x80 | (c & 0x3F));
            return 4;
        }

        assert(!isValidDchar(c));
        c = replacementDchar;   //_utfException!useReplacementDchar("Encoding an invalid code point in UTF-8", c);
        goto L3;
    }

    //https://github.com/dlang/phobos/blob/master/std/utf.d#L2398
    size_t encode_impl(wchar[] buf, dchar c) @safe pure nothrow @nogc{
        if (c <= 0xFFFF)
        {
            if (0xD800 <= c && c <= 0xDFFF)
                c = replacementDchar;   //_utfException!useReplacementDchar("Encoding an isolated surrogate code point in UTF-16", c);

            assert(isValidDchar(c));
        L1:
            buf[0] = cast(wchar) c;
            return 1;
        }
        if (c <= 0x10FFFF)
        {
            assert(isValidDchar(c));
            buf[0] = cast(wchar)((((c - 0x10000) >> 10) & 0x3FF) + 0xD800);
            buf[1] = cast(wchar)(((c - 0x10000) & 0x3FF) + 0xDC00);
            return 2;
        }

        c = replacementDchar;   //_utfException!useReplacementDchar("Encoding an invalid code point in UTF-16", c);
        goto L1;
    }

    //https://github.com/dlang/phobos/blob/master/std/utf.d#L2451
    size_t encode_impl(dchar[] buf, dchar c) @safe pure nothrow @nogc{
        if ((0xD800 <= c && c <= 0xDFFF) || 0x10FFFF < c)
            c = replacementDchar;   //_utfException!useReplacementDchar("Encoding an invalid code point in UTF-32", c);
        else
            assert(isValidDchar(c));
        buf[0] = c;
        return 1;
    }
}



/*
    Same as std.utf.decodeFront.
*/
public template decode(S){
    dchar decode(ref S str)pure nothrow @trusted @nogc{
        import std.typecons : Yes;

        size_t numCodeUnits;
        return decodeFront(str, numCodeUnits);
    }

    //import std.typecons : Yes, No, Flag;
    import std.meta : AliasSeq;
    import std.range : ElementEncodingType, ElementType, isInputRange, empty, isRandomAccessRange, hasSlicing, hasLength;
    import std.traits : isSomeString, isSomeChar;


    private template codeUnitLimit(S)
    if (isSomeChar!(ElementEncodingType!S)){
        static if (is(immutable ElementEncodingType!S == immutable char))
            enum char codeUnitLimit = 0x80;
        else static if (is(immutable ElementEncodingType!S == immutable wchar))
            enum wchar codeUnitLimit = 0xD800;
        else
            enum dchar codeUnitLimit = 0xD800;
    }

    private dchar decodeFront(S)(ref S str, out size_t numCodeUnits)
    if (!isSomeString!S && isInputRange!S && isSomeChar!(ElementType!S))
    in(!str.empty)
    out (result; isValidDchar(result)){
        immutable fst = str.front;

        if (fst < codeUnitLimit!S)
        {
            str.popFront();
            numCodeUnits = 1;
            return fst;
        }
        else
        {
            // https://issues.dlang.org/show_bug.cgi?id=14447 forces canIndex to be
            // done outside of decodeImpl, which is undesirable, since not all
            // overloads of decodeImpl need it. So, it should be moved back into
            // decodeImpl once https://issues.dlang.org/show_bug.cgi?id=8521
            // has been fixed.
            enum canIndex = is(S : const char[]) || isRandomAccessRange!S && hasSlicing!S && hasLength!S;
            immutable retval = decode_impl!(canIndex)(str, numCodeUnits);

            // The other range types were already popped by decodeImpl.
            static if (isRandomAccessRange!S && hasSlicing!S && hasLength!S)
                str = str[numCodeUnits .. str.length];

            return retval;
        }
    }


    private dchar decodeFront(S)(ref S str, out size_t numCodeUnits) @trusted pure
    if (isSomeString!S)
    in(!str.empty)
    out (result; isValidDchar(result)){

        if (str[0] < codeUnitLimit!S)
        {
            numCodeUnits = 1;
            immutable retval = str[0];
            str = str[1 .. $];
            return retval;
        }
        else static if (is(immutable S == immutable C[], C))
        {
            immutable retval = decode_impl!(true)(cast(const(C)[]) str, numCodeUnits);
            str = str[numCodeUnits .. $];
            return retval;
        }
    }


    private dchar decode_impl(bool canIndex, S)(auto ref S str, ref size_t index)
    if (is(S : const char[]) || (isInputRange!S && is(immutable ElementEncodingType!S == immutable char))){
        /* The following encodings are valid, except for the 5 and 6 byte
         * combinations:
         *  0xxxxxxx
         *  110xxxxx 10xxxxxx
         *  1110xxxx 10xxxxxx 10xxxxxx
         *  11110xxx 10xxxxxx 10xxxxxx 10xxxxxx
         *  111110xx 10xxxxxx 10xxxxxx 10xxxxxx 10xxxxxx
         *  1111110x 10xxxxxx 10xxxxxx 10xxxxxx 10xxxxxx 10xxxxxx
         */

        /* Dchar bitmask for different numbers of UTF-8 code units.
         */
        alias bitMask = AliasSeq!((1 << 7) - 1, (1 << 11) - 1, (1 << 16) - 1, (1 << 21) - 1);

        static if (is(S : const char[]))
            auto pstr = str.ptr + index;    // this is what makes decodeImpl() @system code
        else static if (isRandomAccessRange!S && hasSlicing!S && hasLength!S)
            auto pstr = str[index .. str.length];
        else
            alias pstr = str;

        // https://issues.dlang.org/show_bug.cgi?id=14447 forces this to be done
        // outside of decodeImpl
        //enum canIndex = is(S : const char[]) || (isRandomAccessRange!S && hasSlicing!S && hasLength!S);

        static if (canIndex){
            immutable length = str.length - index;
            ubyte fst = pstr[0];
        }
        else{
            ubyte fst = pstr.front;
            pstr.popFront();
        }



        if ((fst & 0b1100_0000) != 0b1100_0000){
            ++index;            // always consume bad input to avoid infinite loops
            return replacementDchar;    //throw invalidUTF(); // starter must have at least 2 first bits set
        }
        ubyte tmp = void;
        dchar d = fst; // upper control bits are masked out later
        fst <<= 1;

        foreach (i; AliasSeq!(1, 2, 3)){

            static if (canIndex){
                if (i == length){
                    index += i;
                    return replacementDchar;    //outOfBounds
                }
            }
            else{
                if (pstr.empty){
                    index += i;
                    return replacementDchar;    //outOfBounds
                }
            }

            static if (canIndex)
                tmp = pstr[i];
            else{
                tmp = pstr.front;
                pstr.popFront();
            }

            if ((tmp & 0xC0) != 0x80){
                index += i + 1;
                return replacementDchar;    //invalidUTF
            }

            d = (d << 6) | (tmp & 0x3F);
            fst <<= 1;

            if (!(fst & 0x80)){ // no more bytes
                d &= bitMask[i]; // mask out control bits

                // overlong, could have been encoded with i bytes
                if ((d & ~bitMask[i - 1]) == 0){
                    index += i + 1;
                    return replacementDchar;    //invalidUTF
                }

                // check for surrogates only needed for 3 bytes
                static if (i == 2){
                    if (!isValidDchar(d)){
                        index += i + 1;
                        return replacementDchar;    //invalidUTF
                    }
                }

                index += i + 1;
                static if (i == 3){
                    if (d > dchar.max){
                        d = replacementDchar;   //invalidUTF
                    }
                }

                return d;
            }
        }

        index += 4;             // read 4 chars by now
        return replacementDchar;    //invalidUTF
    }

    private dchar decode_impl(bool canIndex, S)(auto ref S str, ref size_t index)
    if (is(S : const wchar[]) || (isInputRange!S && is(immutable ElementEncodingType!S == immutable wchar))){

        static if (is(S : const wchar[]))
            auto pstr = str.ptr + index;
        else static if (isRandomAccessRange!S && hasSlicing!S && hasLength!S)
            auto pstr = str[index .. str.length];
        else
            alias pstr = str;

        // https://issues.dlang.org/show_bug.cgi?id=14447 forces this to be done
        // outside of decodeImpl
        //enum canIndex = is(S : const wchar[]) || (isRandomAccessRange!S && hasSlicing!S && hasLength!S);

        static if (canIndex){
            immutable length = str.length - index;
            uint u = pstr[0];
        }
        else{
            uint u = pstr.front;
            pstr.popFront();
        }


        // The < case must be taken care of before decodeImpl is called.
        assert(u >= 0xD800);

        if (u <= 0xDBFF){
            static if (canIndex)
                immutable onlyOneCodeUnit = length == 1;
            else
                immutable onlyOneCodeUnit = pstr.empty;

            if (onlyOneCodeUnit){
                ++index;
                return replacementDchar;    //throw exception("surrogate UTF-16 high value past end of string");
            }

            static if (canIndex)
                immutable uint u2 = pstr[1];
            else{
                immutable uint u2 = pstr.front;
                pstr.popFront();
            }

            if (u2 < 0xDC00 || u2 > 0xDFFF)
                u = replacementDchar;   //throw exception("surrogate UTF-16 low value out of range");
            else
                u = ((u - 0xD7C0) << 10) + (u2 - 0xDC00);
            ++index;
        }
        else if (u >= 0xDC00 && u <= 0xDFFF)
            u = replacementDchar;   //throw exception("unpaired surrogate UTF-16 value");

        ++index;

        // Note: u+FFFE and u+FFFF are specifically permitted by the
        // Unicode standard for application internal use (see isValidDchar)

        return cast(dchar) u;
    }

    private dchar decode_impl(bool canIndex, S)(auto ref S str, ref size_t index)
    if (is(S : const dchar[]) || (isInputRange!S && is(immutable ElementEncodingType!S == immutable dchar))){
        static if (is(S : const dchar[]))
            auto pstr = str.ptr;
        else
            alias pstr = str;

        static if (is(S : const dchar[]) || isRandomAccessRange!S){
            dchar dc = pstr[index];
            if (!isValidDchar(dc))
                dc = replacementDchar;  //throw new UTFException("Invalid UTF-32 value").setSequence(dc);

            ++index;
            return dc;
        }
        else{
            dchar dc = pstr.front;
            if (!isValidDchar(dc))
                dc = replacementDchar;  //throw new UTFException("Invalid UTF-32 value").setSequence(dc);

            ++index;
            pstr.popFront();
            return dc;
        }
    }

}



public bool validate(S)(auto ref S str)pure nothrow @trusted @nogc{
    import std.range : empty;


    while(!str.empty){
        const d = decode(str);
        if(d == replacementDchar)
            return false;
    }

    return true;
}



/*
    Return number of valid code units at end of string str, 0 if last code point is invalid
*/
public ubyte strideBack(scope const(char)[] str)pure nothrow @safe @nogc{
    import std.range : empty;

    /* The following encodings are valid, except for the 5 and 6 byte
     * combinations:
     *  0xxxxxxx
     *  110xxxxx 10xxxxxx
     *  1110xxxx 10xxxxxx 10xxxxxx
     *  11110xxx 10xxxxxx 10xxxxxx 10xxxxxx
     *  111110xx 10xxxxxx 10xxxxxx 10xxxxxx 10xxxxxx
     *  1111110x 10xxxxxx 10xxxxxx 10xxxxxx 10xxxxxx 10xxxxxx
     */
    assert(!str.empty);

    const size_t index = str.length;

    if((str[index - 1] & 0b1000_0000) == 0)
        return 1;

    if((str[index - 1] & 0b1100_0000) != 0b1000_0000)
        return 0;   //error


    if(index >= 4){
        static foreach (i; 2 .. 5){{
            const ubyte c = str[index-i];
            if ((c & 0b1100_0000) != 0b1000_0000){

                static if(i == 2)
                    return ((c & 0b1110_0000) == 0b1100_0000) ? i : 0;
                else static if(i == 3)
                    return ((c & 0b1111_0000) == 0b1110_0000) ? i : 0;
                else static if(i == 4)
                    return ((c & 0b1111_1000) == 0b1111_0000) ? i : 0;
                else return 0;
            }
        }}

        return 0;

    }
    else{
        static foreach (i; 2 .. 4){{
            if(index < i)
                return 0;

            const ubyte c = str[index-i];
            if ((c & 0b1100_0000) != 0b1000_0000){

                static if(i == 2)
                    return ((c & 0b1110_0000) == 0b1100_0000) ? i : 0;
                else static if(i == 3)
                    return ((c & 0b1111_0000) == 0b1110_0000) ? i : 0;
                else static if(i == 4)
                    return ((c & 0b1111_1000) == 0b1111_0000) ? i : 0;
                else return 0;
            }
        }}

        return 0;
    }
}

// ditto
public ubyte strideBack(scope const(wchar)[] str)pure nothrow @safe @nogc{
    import std.range : empty;

    assert(!str.empty);

    const size_t index = str.length;

    const uint u2 = str[index-1];

    if(u2 < 0xD800)
        return 0;

    if (u2 <= 0xDBFF)
        return 0;   //u2 is first character of 2 character sequence

    //2 character sequence:
    if(0xDC00 <= u2 && u2 < 0xE000){
        if(str.length == 1)
            return 0;   //error

        const uint u = str[index-2];
        if (u <= 0xDBFF)
            return 2;

        /+if(u < 0xD800)
            return 0;   //error

        if (0xDC00 <= u && u < 0xE000)
            return 0;   //unpaired surrogate UTF-16 value+/

        return 0;
    }

    //1 character sequence:
    return 1;
}

// ditto
public ubyte strideBack(scope const(dchar)[] str)pure nothrow @safe @nogc{
    import std.range : empty;
    //import std.utf : isValidDchar;
    assert(!str.empty);

    return isValidDchar(str[$-1]);
}
