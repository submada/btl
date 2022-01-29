module btl.string.storage;

import std.traits : Select, isUnsigned;

import btl.internal.traits;

package template Storage(T, size_t N, L, bool allowHeap)
if(isUnsigned!L){

    struct Storage{
        union{
            static if(N > 0){
                private Inline _inline;
                private Heap _heap;
            }
            else{
                private Heap _heap;
                private Inline _inline;
            }
        }

        public alias Inline = InlineImpl;

        public alias Heap = HeapImpl;

        public enum Length minimalCapacity = Inline.capacity;

        public enum Length maximalCapacity = allowHeap
            ? (L.max / T.sizeof)
            : Inline.capacity;

        //public enum Length heapFlag = _heapFlag;

        pragma(inline, true){
            public static Length heapCapacity(Length capacity)pure nothrow @safe @nogc{
                capacity |= heapFlag;
                assert(capacity > minimalCapacity);
                assert(capacity <= maximalCapacity);

                return capacity;
            }

            public void reset(Length len = 0)pure nothrow @trusted @nogc{
                assert(len <= minimalCapacity);

                static if(N){
                    this._inline.reset();
                    this._inline.length = len;
                }
                else static if(allowHeap){
                    assert(len == 0);
                    this._heap.capacity = 0;
                    this._heap.length = 0;
                    this._heap.ptr = null;
                }
            }

            public @property ref inout(Inline) inline()inout pure nothrow @trusted @nogc{
                assert(!this.external);
                return this._inline;
            }

            public @property ref inout(Heap) heap()inout pure nothrow @trusted @nogc{
                assert(this.external);
                return this._heap;
            }
            public @property void heap(Heap h)pure nothrow @trusted @nogc{
                static if(allowHeap){
                    assert(h.length <= h.capacity);
                    this._heap.capacity = h.capacity;
                    assert(this.external);
                    this._heap.length = h.length;
                    this._heap.ptr = h.ptr;
                }
                else{
                    assert(0, "no impl");
                }
            }

            public @property Length capacity()const pure nothrow @trusted @nogc{
                return this.external
                    ? this.heap.capacity
                    : this.inline.capacity;
            }

            public @property Length length()const pure nothrow @trusted @nogc{
                return this.external
                    ? this.heap.length
                    : this.inline.length;
            }

            public @property void length(Length n)pure nothrow @trusted @nogc{
                if(this.external){
                    assert(n <= this.heap.capacity);

                    static if(allowHeap)
                        this.heap.length = cast(L)n;
                    else
                        assert(0, "no impl");
                }
                else{
                    assert(n <= this.inline.capacity);
                    this.inline.length = cast(InlineLength)n;
                }
            }

            public @property inout(T)* ptr()inout pure nothrow @trusted @nogc{
                return this.external
                    ? this.heap.ptr
                    : this.inline.ptr;
            }

            public @property inout(T)[] chars()inout pure nothrow @trusted @nogc{
                return this.external
                    ? this.heap.chars
                    : this.inline.chars;
            }

            public @property inout(T)[] allocatedChars()inout pure nothrow @trusted @nogc{
                return this.external
                    ? this.heap.allocatedChars
                    : this.inline.allocatedChars;
            }

            public @property bool external()const pure nothrow @safe @nogc{
                static if(allowHeap && N)
                    return (this._inline.header.length & heapFlag);
                else
                    return allowHeap;
            }

            public @property bool small()const pure nothrow @trusted @nogc{
                static if(allowHeap){
                    static if(N == 0)
                        return (this._heap.capacity == 0);
                    else
                        return !this.external;
                }
                else
                    return true;

            }
        }
    }

    enum L heapFlag = allowHeap
        ? 0x1   //heap capacity must be odd
        : 0;

    enum size_t maxInlineLength(U) = (U.max & (cast(U)~heapFlag));

    template InlineLengthImpl(){
        static if(maxInlineLength!ubyte >= N)
            alias InlineLengthImpl = ubyte;
        else static if(maxInlineLength!ushort >= N)
            alias InlineLengthImpl = ushort;
        else static if(maxInlineLength!uint >= N)
            alias InlineLengthImpl = uint;
        else static if(maxInlineLength!ulong >= N)
            alias InlineLengthImpl = ulong;
        else
            static assert(0, "no impl");
    }

    alias InlineLength = InlineLengthImpl!();

    alias Length = Select!(L.sizeof > InlineLength.sizeof, L, InlineLength);

    alias HeapImpl = .HeapStorage!(T, L, allowHeap);

    align(max(T.sizeof, InlineLength.alignof))
    struct InlineHeader{
        private InlineLength length = 0;

        private enum Length maxLength = maxInlineLength!InlineLength;

        static assert(maxLength >= N);
    }

    enum inlineAlign = max(HeapImpl.alignof, InlineHeader.alignof);

    size_t compute_inline_capacity(){
        if(N == 0)
            return 0;
        else{
            const size_t base_capacity = (HeapImpl.sizeof > InlineHeader.sizeof)
                ? ((HeapImpl.sizeof - InlineHeader.sizeof) / T.sizeof)
                : 0;

            const size_t additional_base_capacity = (base_capacity >= N)
                ? 0
                : (N - base_capacity);

            const size_t additional_base_size = additional_base_capacity * T.sizeof;

            const size_t additional_align_size = (inlineAlign - (additional_base_size % inlineAlign)) % 8;

            const size_t additional_capacity = (additional_base_size + additional_align_size) / T.sizeof;

            const size_t final_capacity = base_capacity + additional_capacity;

            const size_t max_inline_length = InlineHeader.maxLength;

            return (max_inline_length < final_capacity)
                ? max_inline_length
                : final_capacity;
        }
    }

    align(inlineAlign)
    struct InlineImpl{
        private InlineHeader header;

        public enum Length capacity = compute_inline_capacity();
        private T[capacity] elements;

        pragma(inline, true){
            public void reset()pure nothrow @safe @nogc{
                this.header.length = 0;
            }

            public @property Length length()const pure nothrow @safe @nogc{
                static if(allowHeap){
                    static if(InlineHeader.sizeof >= uint.sizeof)
                        return cast(Length)(header.length >> 1);
                    else
                        return cast(Length)((cast(size_t)this.header.length) >> 1);
                }
                else
                    return this.header.length;

            }

            public @property void length(Length n)pure nothrow @safe @nogc{
                assert(n <= capacity);

                static if(allowHeap)
                    this.header.length = cast(InlineLength)(n << 1);
                else
                    this.header.length = cast(InlineLength)n;
            }

            public @property inout(void)[] data()inout pure nothrow @trusted @nogc{
                return (cast(inout(void)*)this.elements.ptr)[0 .. this.capacity * T.sizeof];
            }

            public @property inout(T)* ptr()inout pure nothrow @trusted @nogc{
                return this.elements.ptr;
            }

            public @property inout(T)[] chars()inout pure nothrow @trusted @nogc{
                return this.ptr[0 .. length];
            }

            public @property inout(T)[] allocatedChars()inout pure nothrow @trusted @nogc{
                return this.ptr[0 .. capacity];
            }
        }
    }


}

struct HeapStorage(T, L, bool allowHeap){
    static if(allowHeap){
        public L capacity;
        public L length;
        public T* ptr;
    }
    else{
        public @property L capacity()const pure nothrow @safe @nogc{return 0;}
        public @property void capacity(size_t)pure nothrow @safe @nogc{assert(0, "no impl");}

        public @property L length()const pure nothrow @safe @nogc{return 0;}
        public @property void length(size_t)pure nothrow @safe @nogc{assert(0, "no impl");}

        public @property inout(T)* ptr()inout pure nothrow @safe @nogc{return null;}
        public @property void ptr(T*)pure nothrow @safe @nogc{assert(0, "no impl");}
    }

    pragma(inline, true){

        public @property inout(void)[] data()inout pure nothrow @trusted @nogc{
            return (cast(inout(void)*)this.ptr)[0 .. capacity * T.sizeof];
        }

        public @property inout(T)[] chars()inout pure nothrow @trusted @nogc{
            return this.ptr[0 .. length];
        }

        public @property inout(T)[] allocatedChars()inout pure nothrow @trusted @nogc{
            return this.ptr[0 .. capacity];
        }
    }
}
