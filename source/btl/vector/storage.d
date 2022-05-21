/*
    License:   $(HTTP www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
    Authors:   $(HTTP github.com/submada/btl, Adam Búš)
*/
module btl.vector.storage;




package template Storage(T, size_t N, bool allowHeap){

    struct Storage{
        public alias Inline = InlineStorage!(T, N);

        public alias Heap = HeapStorage!(T, allowHeap);

        public enum size_t minimalCapacity = Inline.capacity;

        public enum size_t maximalCapacity = allowHeap ? size_t.max : N;

        public size_t length;

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

        pragma(inline, true){
            public static size_t heapCapacity(size_t new_capacity)pure nothrow @safe @nogc{
                new_capacity |= heapFlag;
                assert(new_capacity > minimalCapacity);
                assert(new_capacity <= maximalCapacity);

                return new_capacity;
            }

            public void reset()pure nothrow @trusted @nogc{
                this.length = 0;


                static if(N){
                    this._inline.reset();
                }
                else static if(allowHeap){
                    this._heap.capacity = 0;
                    this._heap.ptr = null;

                }
            }

            public @property ref inout(Inline) inline()inout pure nothrow @trusted @nogc{
                return this._inline;
            }

            public @property ref inout(Heap) heap()inout pure nothrow @trusted @nogc{
                return this._heap;
            }
            public @property void heap(Heap h)pure nothrow @trusted @nogc{
                static if(allowHeap){
                    assert(this.length <= h.capacity);
                    this._heap.capacity = h.capacity;
                    assert(this.external);
                    this._heap.ptr = h.ptr;
                }
                else{
                    assert(0, "no impl");
                }
            }

            public @property size_t capacity()scope const pure nothrow @safe @nogc{
                return this.external
                    ? this.heap.capacity
                    : this.inline.capacity;
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

            public @property bool external()const scope pure nothrow @trusted @nogc{
                static if(allowHeap && N)
                    return (this._inline.flag & heapFlag);
                else
                    return allowHeap;
            }
            public @property void external(bool x)scope pure nothrow @trusted @nogc{
                static if(allowHeap && N)
                    this._inline.flag = x ? heapFlag : 0;
                else
                    assert(0, "no impl");
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

    enum ubyte heapFlag = allowHeap
        ? 0x1   //heap capacity must be odd
        : 0;
}

private struct InlineStorage(T, size_t N){
    public enum size_t capacity = N;   //max(N, 2);

    static if(N){
        public align(T.alignof)ubyte flag = 0;
        public void[capacity * T.sizeof] storage;
    }
    else{
        public enum ubyte flag = 0;
        public enum void[] storage = null;
    }


    pragma(inline, true){
        public void reset()pure nothrow @safe @nogc{
            static if(N)
                this.flag = 0;
        }

        public @property inout(T)* ptr()inout pure nothrow @system @nogc{
            return cast(inout(T)*)storage.ptr;
        }

        public @property inout(void)[] data()inout pure nothrow @system @nogc{
            return storage[];
        }

        public @property inout(T)[] elements(size_t length)inout pure nothrow @system @nogc{
            assert(length <= capacity);
            return ptr[0 .. length];
        }

        public @property inout(T)[] allocatedElements()inout pure nothrow @system @nogc{
            return ptr[0 .. capacity];
        }
    }
}

private struct HeapStorage(T, bool allowHeap){

    static if(allowHeap){
        public size_t capacity;
        public T* ptr;
    }
    else{
        public @property size_t capacity()const pure nothrow @safe @nogc{return 0;}
        public @property void capacity(size_t)pure nothrow @safe @nogc{assert(0, "no impl");}

        public @property inout(T)* ptr()inout pure nothrow @safe @nogc{return null;}
        public @property void ptr(T*)pure nothrow @safe @nogc{assert(0, "no impl");}
    }

    pragma(inline, true){

        public @property inout(void)[] data()inout pure nothrow @trusted @nogc{
            return (cast(inout void*)ptr)[0 .. capacity * T.sizeof];
        }

        public @property inout(T)[] elements(size_t length)inout pure nothrow @system @nogc{
            assert(length <= capacity);
            return ptr[0 .. length];
        }

        public @property inout(T)[] allocatedElements()inout pure nothrow @system @nogc{
            return ptr[0 .. capacity];
        }
    }
}
