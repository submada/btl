module btl.string.storage;

import btl.internal.traits;

package template Storage(T, size_t N, bool allowHeap){
    import std.traits : Select;

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

        alias Inline = InlineImpl;

        alias Heap = HeapImpl;

        enum size_t minimalCapacity = N ? Inline.capacity : 0;

        enum size_t maximalCapacity = allowHeap
            ? (size_t.max / T.sizeof)
            : N;

        enum size_t heapFlag = _heapFlag;

        pragma(inline, true){
            static size_t heapCapacity(size_t capacity)pure nothrow @safe @nogc{
                capacity |= heapFlag;
                assert(capacity > minimalCapacity);
                assert(capacity <= maximalCapacity);

                return capacity;
            }

            void reset(size_t len = 0)pure nothrow @trusted @nogc{
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

            void setHeap(size_t capacity, size_t length, T* ptr)pure nothrow @trusted @nogc{
                static if(allowHeap){
                    assert(length <= capacity);
                    this._heap.capacity = capacity;
                    assert(this.external);
                    this._heap.length = length;
                    this._heap.ptr = ptr;
                }
                else{
                    assert(0, "no impl");
                }
            }
            void setHeap(H)(ref H heap)pure nothrow @trusted @nogc{
                this.setHeap(heap.capacity, heap.length, heap.ptr);
            }

            @property ref inout(Inline) inline()inout pure nothrow @trusted @nogc{
                assert(!this.external);
                return this._inline;
            }

            @property ref inout(Heap) heap()inout pure nothrow @trusted @nogc{
                assert(this.external);
                return this._heap;
            }

            @property size_t capacity()const pure nothrow @trusted @nogc{
                return this.external
                    ? this.heap.capacity
                    : this.inline.capacity;
            }

            @property size_t length()const pure nothrow @trusted @nogc{
                return this.external
                    ? this.heap.length
                    : this.inline.length;
            }

            @property void length(size_t n)pure nothrow @trusted @nogc{
                if(this.external){
                    assert(n <= this.heap.capacity);

                    static if(allowHeap)
                        this.heap.length = n;
                    else
                        assert(0, "no impl");
                }
                else{
                    assert(n <= this.inline.capacity);
                    this.inline.length = cast(InlineLength)n;
                }
            }

            @property inout(T)* ptr()inout pure nothrow @trusted @nogc{
                return this.external
                    ? this.heap.ptr
                    : this.inline.ptr;
            }

            @property inout(T)[] chars()inout pure nothrow @trusted @nogc{
                return this.external
                    ? this.heap.chars
                    : this.inline.chars;
            }

            @property inout(T)[] allocatedChars()inout pure nothrow @trusted @nogc{
                return this.external
                    ? this.heap.allocatedChars
                    : this.inline.allocatedChars;
            }

            @property bool external()const pure nothrow @safe @nogc{
                static if(allowHeap && N)
                    return (this._inline.header.length & heapFlag);
                else
                    return allowHeap;
            }

            @property bool small()const pure nothrow @trusted @nogc{
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

    enum size_t _heapFlag = allowHeap
        ? 0x1   //heap capacity must be odd
        : 0;

    enum size_t maxInlineLength(U) = U.max & (cast(U)~_heapFlag);

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

    struct HeapImpl{
        static if(allowHeap){
            size_t capacity;
            size_t length;
            T* ptr;
        }
        else{
            size_t capacity()const pure nothrow @safe @nogc{return 0;}
            size_t length()const pure nothrow @safe @nogc{return 0;}
            inout(T)* ptr()inout pure nothrow @safe @nogc{return null;}

            void capacity(size_t)pure nothrow @safe @nogc{assert(0, "no impl");}
            void length(size_t)pure nothrow @safe @nogc{assert(0, "no impl");}
            void ptr(T*)pure nothrow @safe @nogc{assert(0, "no impl");}
        }

        pragma(inline, true){

            @property inout(void)[] data()inout pure nothrow @trusted @nogc{
                return (cast(inout(void)*)this.ptr)[0 .. capacity * T.sizeof];
            }

            @property inout(T)[] chars()inout pure nothrow @trusted @nogc{
                return this.ptr[0 .. length];
            }

            @property inout(T)[] allocatedChars()inout pure nothrow @trusted @nogc{
                return this.ptr[0 .. capacity];
            }
        }
    }

    align(max(T.sizeof, InlineLength.alignof))
    struct InlineHeader{
        InlineLength length = 0;

        enum size_t maxLength = maxInlineLength!InlineLength;

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

        enum size_t capacity = compute_inline_capacity();
        private T[capacity] elements;

        pragma(inline, true){
            void reset()pure nothrow @safe @nogc{
                this.header.length = 0;
            }

            @property size_t length()const pure nothrow @safe @nogc{
                static if(allowHeap)
                    return (cast(size_t)this.header.length) >> 1;
                else
                    return this.header.length;

            }

            @property void length(size_t n)pure nothrow @safe @nogc{
                assert(n <= capacity);

                static if(allowHeap)
                    this.header.length = cast(InlineLength)(n << 1);
                else
                    this.header.length = cast(InlineLength)n;
            }

            @property inout(void)[] data()inout pure nothrow @trusted @nogc{
                return (cast(inout(void)*)this.elements.ptr)[0 .. this.capacity * T.sizeof];
            }

            @property inout(T)* ptr()inout pure nothrow @trusted @nogc{
                return this.elements.ptr;
            }

            @property inout(T)[] chars()inout pure nothrow @trusted @nogc{
                return this.ptr[0 .. length];
            }

            @property inout(T)[] allocatedChars()inout pure nothrow @trusted @nogc{
                return this.ptr[0 .. capacity];
            }
        }
    }


}

