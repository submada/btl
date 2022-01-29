module btl.vector.storage;



package template Storage(T, size_t N, bool gcRange, bool allowHeap){
    enum external_flag_mask = (allowHeap && N != 0)
        ? (size_t(1) << (size_t.sizeof * 8) -1)
        : 0;

    struct Storage{
        public alias Inline = InlineStorage!(T, N);

        public alias Heap = HeapStorage!(T, gcRange);

        public enum size_t minimalCapacity = Inline.capacity;

        public enum size_t maximalCapacity = (size_t.max & ~external_flag_mask);

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
        public size_t _length;

        pragma(inline, true){
            public void reset()pure nothrow @trusted @nogc{
                this._length = 0;

                static if(minimalCapacity == 0)
                    this.heap.capacity = 0;
            }

            /+public void swapHeap(ref Storage rhs)pure nothrow @trusted @nogc{
                assert(this.external);
                assert(rhs.external);

                import std.algorithm.mutation : swap;

                swap(this._heap, rhs._heap);
                swap(this._length, rhs._length);
            }
            public void moveHeap(S)(ref S storage)pure nothrow @trusted @nogc{
                assert(this.external);

                storage._heap.ptr = this._heap.ptr;
                storage._heap.capacity = this._heap.capacity;
                storage._length = this._length;

                this.reset();
            }+/



            public @property ref inout(Inline) inline()inout pure nothrow @trusted @nogc{
                return this._inline;
            }

            public @property ref inout(Heap) heap()inout pure nothrow @trusted @nogc{
                return this._heap;
            }

            public @property size_t capacity()scope const pure nothrow @safe @nogc{
                return this.external
                    ? this.heap.capacity
                    : this.inline.capacity;
            }

            public @property size_t length()scope const pure nothrow @safe @nogc{
                return (this._length & ~external_flag_mask);
                //return this._length;
            }

            public @property void length(size_t n)scope pure nothrow @safe @nogc{
                assert(n <= maximalCapacity);
                assert(n <= this.capacity);

                this._length = (external_flag_mask & this._length) | size_t(n);
            }

            public @property inout(T)* ptr()scope inout pure nothrow @trusted @nogc{
                return this.external
                    ? this.heap.ptr
                    : this.inline.ptr;
            }

            public @property inout(T)[] elements()scope inout pure nothrow @trusted @nogc{
                return this.external
                    ? this.heap.elements(this.length)
                    : this.inline.elements(this.length);
            }

            public @property inout(T)[] allocatedElements()inout return pure nothrow @trusted @nogc{
                return this.external
                    ? this.heap.allocatedElements()
                    : this.inline.allocatedElements();
            }

            public @property bool external()const scope pure nothrow @safe @nogc{
                static if(minimalCapacity == 0)
                    return true;
                else static if(allowHeap)
                    return (_length & external_flag_mask) != 0;
                else
                    return false;
            }

            public @property  void external(bool x)scope pure nothrow @trusted @nogc
            out(; external() == x){
                static if(minimalCapacity == 0){
                    assert(x == true);
                }
                else static if(allowHeap){
                    if(x)
                        this._length |= external_flag_mask;
                    else
                        this._length &= ~external_flag_mask;
                }
                else{
                    assert(x == false);
                }
            }
        }

    }
}

private struct InlineStorage(T, size_t N){
    public enum size_t capacity = N;   //max(N, 2);

    static if(N > 0)
        public void[capacity * T.sizeof] storage;
    else
        public enum void[] storage = null;


    pragma(inline, true){
        public @property inout(T)* ptr()inout pure nothrow @system @nogc{
            static if(N > 0)
                return cast(inout(T)*)storage.ptr;
            else
                assert(0, "no impl");
        }

        public @property inout(T)[] elements(size_t length)inout pure nothrow @system @nogc{
            assert(length <= capacity);

            static if(N > 0)
                return ptr[0 .. length];
            else
                assert(0, "no impl");
        }

        public @property inout(T)[] allocatedElements()inout pure nothrow @system @nogc{
            static if(N > 0)
                return ptr[0 .. capacity];
            else
                assert(0, "no impl");
        }

        public @property void[] data()pure nothrow @system @nogc{
            static if(N > 0)
                return (cast(void*)storage.ptr)[0 .. capacity * T.sizeof];
            else
                assert(0, "no impl");
        }
    }
}

private struct HeapStorage(T, bool gcRange){

    public T* ptr;
    public size_t capacity;

    pragma(inline, true){
        public @property inout(T)[] elements(size_t length)inout pure nothrow @system @nogc{
            assert(length <= capacity);
            return ptr[0 .. length];
        }

        public @property inout(T)[] allocatedElements()inout pure nothrow @system @nogc{
            return ptr[0 .. capacity];
        }

        public @property inout(void)[] data()inout pure nothrow @trusted @nogc{
            return (cast(void*)ptr)[0 .. capacity * T.sizeof];
        }
    }
}

