/**
    Implementation of dynamic array `Vector` (similar to c++ `std::vector` and `folly::small_vector`).

    License:   $(HTTP www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
    Authors:   $(HTTP github.com/submada/basic_string, Adam Búš)
*/
module btl.vector;

import std.traits : Unqual, Unconst, isSomeChar, isSomeString;
import std.meta : AliasSeq;
import std.traits : Select;

import btl.internal.traits;
import btl.internal.mallocator;
import btl.internal.null_allocator;
import btl.internal.forward;
import btl.internal.gc;
import btl.internal.lifetime;


debug import std.stdio : writeln;



/**
    Type used in forward constructors.
*/
alias Forward = btl.internal.forward.Forward;


/**
    Default allcoator for `Vector`.
*/
public alias DefaultAllocator = Mallocator;


/**
    True if `T` is a `Vector` or implicitly converts to one, otherwise false.
*/
template isVector(T...)
if(T.length == 1){
    enum bool isVector = is(Unqual!(T[0]) == Vector!Args, Args...);
}


/**
    `Vector`s are sequence containers representing arrays that can change in size.

    Just like arrays, vectors use contiguous storage locations for their elements, which means that their elements can also be accessed using offsets on regular pointers to its elements, and just as efficiently as in arrays. But unlike arrays, their size can change dynamically, with their storage being handled automatically by the container.

    Instead, vector containers may allocate some extra storage to accommodate for possible growth, and thus the container may have an actual capacity greater than the storage strictly needed to contain its elements (i.e., its size). Libraries can implement different strategies for growth to balance between memory usage and reallocations, but in any case, reallocations should only happen at logarithmically growing intervals of size so that the insertion of individual elements at the end of the vector can be provided with amortized constant time complexity (see push_back).

    Therefore, compared to arrays, vectors consume more memory in exchange for the ability to manage storage and grow dynamically in an efficient way.

    `Vector` can have preallocated (stack) space for `N` elements.

    Template parameters:

        `_Type` = element type.

        `N` Number of preallocated space for elements.

        `_Allocator` Type of the allocator object used to define the storage allocation model. By default `DefaultAllocator` is used.


    @safe:

        * Inserting element to `Vector` pointer is @safe if constructor of element is @safe (assumption is that constructor doesn't leak `this` pointer).

        * `Vector` assume that deallocation with custom allocator is @safe if allocation is @safe even if method `deallcoate` is @system.

        * Methods returning reference/pointer/slice (`front()`, `back()`, `ptr()`, `elements()`, `opSlice()`, ...) to vector elements are all @system because increasing capacity of vector can realocate all elements to new memory location and invalidate external references to old location.


    `scope` and -dip1000:

        * `Vector` assume that managed object have global lifetime (scope can be ignored).

        * Functions for inserting elements to vector have  non `scope` parameters (global lifetime).
*/
template Vector(
    _Type,
    size_t N = 0,
    _Allocator = DefaultAllocator,
    bool _supportGC = platformSupportGC
){

    import core.lifetime : emplace, forward, move;
    import std.experimental.allocator.common :  stateSize;
    import std.range : empty, front, popFront, isInputRange, ElementEncodingType, hasLength;
    import std.traits : Unqual, hasElaborateDestructor, hasIndirections, CopyTypeQualifiers, isDynamicArray;

    alias Storage = .Storage!(_Type, N, size_t, _supportGC);
    alias InlineStorage = Storage.Inline;
    alias HeapStorage = Storage.Heap;
    alias LengthType = size_t;

    enum external_flag_mask = (_allowHeap && N != 0)
        ? (LengthType(1) << (LengthType.sizeof * 8) -1)
        : 0;
    enum bool _hasStatelessAllocator = (stateSize!_Allocator == 0);
    enum bool _allowHeap = !is(_Allocator : void);
    enum size_t _maximalCapacity = (LengthType.max & ~external_flag_mask);

    struct Vector{

        /**
            True if allocator doesn't have state.
        */
        public alias hasStatelessAllocator = _hasStatelessAllocator;



        /**
            Type of elements.
        */
        public alias ElementType = _Type;



        /**
            Type of reference to elements.
        */
        public alias ElementReferenceType = ElementReferenceTypeImpl!_Type;



        /**
            Type of the allocator object used to define the storage allocation model. By default `DefaultAllocator` is used.
        */
        public alias AllocatorType = _Allocator;/+Select!(
            _allowHeap,
             _Allocator, 
             NullAllocator
        );+/



        /**
        */
        public alias supportGC = _supportGC;



        /**
            Allow heap (`false` only if `Allcoator` is void)
        */
        public alias allowHeap = _allowHeap;



        /**
            Maximal capacity of vector, in terms of number of elements.
        */
        public alias maximalCapacity = _maximalCapacity;



        /**
            Minimal capacity of vector, in terms of number of elements.

            Examples:
                --------------------
                Vector!(int, 10) vec;
                assert(vec.capacity == typeof(vec).minimalCapacity);
                assert(vec.capacity == 10);
                --------------------
        */
        public alias minimalCapacity = InlineStorage.capacity;



        /**
            Returns copy of allocator.
        */
        public @property CopyTypeQualifiers!(This, AllocatorType) allocator(this This)()scope{
            static if(allowHeap)
                return *(()@trusted => &this._allocator )();
            else
                return;
        }



        /**
            Returns whether the vector is empty (i.e. whether its length is 0).

            Examples:
                --------------------
                Vector!(int, 10) vec;
                assert(vec.empty);

                vec.append(42);
                assert(!vec.empty);
                --------------------
        */
        public @property bool empty()const scope pure nothrow @safe @nogc{
            return (this.length == 0);
        }



        /**
            Returns the length of the vector, in terms of number of elements.

            This is the number of actual elements that conform the contents of the `Vector`, which is not necessarily equal to its storage capacity.

            Examples:
                --------------------
                Vector!(int, 10) vec = null;
                assert(vec.length == 0);

                vec.append(42);
                assert(vec.length == 1);

                vec.append(123);
                assert(vec.length == 2);

                vec.clear();
                assert(vec.length == 0);
                --------------------
        */
        public @property size_t length()const scope pure nothrow @safe @nogc{
            return (this._length & ~external_flag_mask);
        }

        private @property void length(const size_t len)scope pure nothrow @trusted @nogc{
            assert(len <= maximalCapacity);
            assert(len <= this.capacity);
            
            this._length = (external_flag_mask & this._length) | LengthType(len);
        }



        /**
            Returns the size of the storage space currently allocated for the `Vector`.

            This capacity is not necessarily equal to the vector length. It can be equal or greater, with the extra space allowing the object to optimize its operations when new elements are added to the `Vector`.

            Notice that this capacity does not suppose a limit on the length of the `Vector`. When this capacity is exhausted and more is needed, it is automatically expanded by the object (reallocating it storage space).

            The capacity of a `Vector` can be altered any time the object is modified, even if this modification implies a reduction in size.

            The capacity of a `Vector` can be explicitly altered by calling member `reserve`.

            Examples:
                --------------------
                Vector!(int, 10) vec;
                assert(vec.capacity == typeof(vec).minimalCapacity);

                vec.reserve(vec.capacity * 2);
                assert(vec.capacity > typeof(vec).minimalCapacity);
                --------------------
        */
        public @property size_t capacity()const scope pure nothrow @trusted @nogc{
            return this._is_external
                ? this._heap_storage.capacity
                : this._inline_storage.capacity;
        }



        /**
            Return pointer to the first element.

            The pointer  returned may be invalidated by further calls to other member functions that modify the object.

            Examples:
                --------------------
                Vector!(int, 6) vec = Vector!(int, 6).build(1, 2, 3);

                assert(vec.ptr[0 .. 3] == [1, 2, 3]);
                --------------------

        */
        public @property inout(ElementType)* ptr()inout return pure nothrow @system @nogc{
            return this._is_external
                ? this._heap_storage.ptr
                : this._inline_storage.ptr;
        }



        /**
            Return slice of all elements (same as `opSlice()`).

            The slice returned may be invalidated by further calls to other member functions that modify the object.

            Examples:
                --------------------
                Vector!(int, 6) vec = Vector!(int, 6).build(1, 2, 3);

                int[] slice = vec.elements;
                assert(slice.length == vec.length);
                assert(slice.ptr is vec.ptr);

                vec.reserve(vec.capacity * 2);
                assert(slice.length == vec.length);
                // slice contains dangling pointer!
                --------------------
        */
        public @property inout(ElementType)[] elements()inout return pure nothrow @system @nogc{
            const len = this.length;

            return this._is_external
                ? this._heap_storage.elements(len)
                : this._inline_storage.elements(len);
        }



        /**
            Return `true` if vector is small (capacity == minimalCapacity)
        */
        public @property bool small()const scope pure nothrow @safe @nogc{
            return !this._is_external;
        }



        /**
            Destroys the `Vector` object.

            This deallocates all the storage capacity allocated by the `Vector` using its allocator.
        */
        public ~this()scope{
            this._release_impl();
        }



        /**
            Constructs a empty `Vector` with allocator `a`.

            Examples:
                --------------------
                {
                    Vector!(int, 6) vec = DefaultAllocator.init;
                    assert(vec.empty);
                }
                --------------------

        */
        static if(allowHeap)
        public this(AllocatorType a)scope pure nothrow @safe @nogc{
            static if(!hasStatelessAllocator)
                this._allocator = forward!a;
        }



        /**
            Constructs a empty `Vector`

            Examples:
                --------------------
                {
                    Vector!(int, 6) vec = null;
                    assert(vec.empty);
                }
                --------------------

        */
        public this(typeof(null) nil)scope pure nothrow @safe @nogc{
        }



        /**
            Constructs a `Vector` object from other vector.

            Parameters:
                `rhs` other vector of `Vector` type.

                `allocator` optional allocator parameter.

            Examples:
                --------------------
                {
                    Vector!(int, 6) vec = Vector!(int, 6).build(1, 2);
                    assert(vec == [1, 2]);
                }
                {
                    auto tmp = Vector!(int, 6).build(1, 2);
                    Vector!(int, 6) vec = tmp;
                    assert(vec == [1, 2]);
                }


                {
                    Vector!(int, 6) vec = Vector!(int, 4).build(1, 2);
                    assert(vec == [1, 2]);
                }
                {
                    auto tmp = Vector!(int, 4).build(1, 2);
                    Vector!(int, 6) vec = tmp;
                    assert(vec == [1, 2]);
                }
                --------------------
        */
        public this(Rhs, this This)(scope auto ref Rhs rhs)scope
        if(    isVector!Rhs
            && isConstructable!(Rhs, This, false)
            && (isRef!Rhs || !is(immutable This == immutable Rhs))
        ){
            this(forward!rhs, Forward.init);
        }

        /// ditto
        static if(allowHeap)
        public this(Rhs, this This)(scope auto ref Rhs rhs, AllocatorType allocator)scope
        if(    isVector!Rhs
            && isConstructable!(Rhs, This, false)
        ){
            this(this._trusted_elements, forward!allocator);
        }

        //forward ctor impl:
        private this(Rhs, this This)(scope auto ref Rhs rhs, Forward)scope
        if(isVector!Rhs && isConstructable!(Rhs, This)){

            //move:
            static if(isMoveConstructable!(rhs, This)){
                if(rhs._is_external){
                    //heap -> heap:
                    if(minimalCapacity <= Rhs.minimalCapacity || minimalCapacity < rhs.length){
                        //debug writeln(minimalCapacity, " <= ", Rhs.minimalCapacity, " || ", minimalCapacity, " < ", rhs.length);
                        static if(!hasStatelessAllocator)
                            this._allocator = move(rhs._allocator);

                        this.release();
                        this._length = rhs._length;

                        this._heap_storage = rhs._heap_storage;
                        rhs._trusted_init_length();

                        assert(this._is_external);
                        //debug writeln("heap -> heap:");
                    }
                    //heap -> inline:
                    else{
                        assert(minimalCapacity >= rhs.length);

                        static if(!hasStatelessAllocator)
                            this._allocator = rhs._allocator;

                        assert(rhs.length <= minimalCapacity);  //this.reserve(rhs.length);

                        if(rhs.length){
                            moveEmplaceRange!false(
                                (()@trusted => this._inline_storage.ptr )(),
                                (()@trusted => rhs._heap_storage.ptr )(),
                                rhs.length
                            );

                            this.length = rhs.length;
                        }

                        //debug writeln("heap -> inline:");
                        assert(!this._is_external);
                    }
                }
                else{
                    static if(!hasStatelessAllocator)
                        this._allocator = move(rhs._allocator);

                    //inline -> inline:
                    if(minimalCapacity >= Rhs.minimalCapacity || minimalCapacity >= rhs.length){

                        if(rhs.length){
                            moveEmplaceRange!false(
                                (()@trusted => this._inline_storage.ptr )(),
                                (()@trusted => rhs._inline_storage.ptr )(),
                                rhs.length
                            );

                            this._length = rhs._length;
                        }

                        assert(!this._is_external);
                        //debug writeln("inline -> inline:");
                    }
                    //inline -> heap
                    else{
                        this.reserve(rhs.length);
                        assert(rhs.length);

                        moveEmplaceRange!false(
                            (()@trusted => this._heap_storage.ptr )(),
                            (()@trusted => rhs._inline_storage.ptr )(),
                            rhs.length
                        );

                        this.length = rhs.length;
                        assert(this._is_external);
                        //debug writeln("inline -> heap:");
                    }
                }
            }
            //move elements:
            else static if(!isRef!rhs && isMoveConstructableElement!(GetElementType!Rhs, ElementType)){
                static if(!hasStatelessAllocator)
                    this._allocator = rhs._allocator;

                auto range = rhs._trusted_elements;
                const size_t new_length = range.length;

                this.downsize(new_length);
                this.reserve(new_length);

                const size_t old_length = this.length;


                //move asign elements from range
                foreach(ref elm; this._trusted_elements){
                    elm = move(range.front);

                    range.popFront;
                }

                //move elements from range
                if(old_length < new_length){
                    moveEmplaceRange!false(
                        (()@trusted => this.ptr + old_length)(),
                        (()@trusted => range.ptr )(),
                        (new_length - old_length)
                    );
                }

                this.length = new_length;
            }
            //copy:
            else{
                static if(hasStatelessAllocator)
                    this(rhs._trusted_elements);
                else
                    this(rhs._trusted_elements, rhs.allocator);
            }
        }



        /**
            Constructs a `Vector` object from range of elements.

            Parameters:
                `range` input reange of `ElementType` elements.

                `allocator` optional allocator parameter.

            Examples:
                --------------------
                import std.range : iota;
                {
                    Vector!(int, 6) vec = iota(0, 5);
                    assert(vec == [0, 1, 2, 3, 4]);
                }
                --------------------
        */
        public this(R, this This)(R range)scope
        if(    hasLength!R
            && isInputRange!R
            && is(ElementEncodingType!R : CopyTypeQualifiers!(This, ElementType))
        ){
            this._init_from_range(forward!range);
        }

        /// ditto
        static if(allowHeap)
        public this(R, this This)(R range, AllocatorType allcoator)return
        if(    hasLength!R
            && isInputRange!R
            && is(ElementEncodingType!R : CopyTypeQualifiers!(This, ElementType))
        ){
            static if(!hasStatelessAllocator)
                this._allocator = forward!allcoator;

            this._init_from_range(forward!range);
        }

        private void _init_from_range(R, this This)(R range)scope
        if(    hasLength!R
            && isInputRange!R
            && is(ElementEncodingType!R : CopyTypeQualifiers!(This, ElementType))
        ){
            auto self = (()@trusted => (cast(Unqual!This*)&this) )();

            const size_t length = range.length;

            self.reserve(length);

            {
                auto elms = ()@trusted{
                    return cast(CopyTypeQualifiers!(This, ElementType)[])self.ptr[0 .. length];
                }();

                size_t emplaced = 0;
                scope(failure){
                    self.length = emplaced;
                }

                emplaceElements(emplaced, elms, forward!range);
            }

            self.length = length;
        }



        /**
            Copy constructors
        */
        static foreach(alias From; AliasSeq!(
            typeof(this),
            const typeof(this),
            immutable typeof(this),
        )){

            static if(hasCopyConstructor!(From, typeof(this)))
                this(scope ref return From rhs)scope{this(rhs, Forward.init);}
            else
                @disable this(scope ref return From rhs)scope pure nothrow @safe;

            static if(hasCopyConstructor!(From, const typeof(this)))
                this(scope ref return From rhs)const scope{this(rhs, Forward.init);}
            else
                @disable this(scope ref return From rhs)const scope pure nothrow @safe;

            static if(hasCopyConstructor!(From, immutable typeof(this)))
                this(scope ref return From rhs)immutable scope{this(rhs, Forward.init);}
            else
                @disable this(scope ref return From rhs)immutable scope pure nothrow @safe;

            static if(hasCopyConstructor!(From, shared typeof(this)))
                this(scope ref return From rhs)shared scope{this(rhs, Forward.init);}
            else
                @disable this(scope ref return From rhs)shared scope pure nothrow @safe;

            static if(hasCopyConstructor!(From, const shared typeof(this)))
                this(scope ref return From rhs)const shared scope{this(rhs, Forward.init);}
            else
                @disable this(scope ref return From rhs)const shared scope pure nothrow @safe;
        }



        /**
            Assigns a new value `rhs` to the vector, replacing its current contents.

            Parameter `rhs` can by type of `null`, `Vector` or input range of ElementType elements.

            Examples:
                --------------------
                Vector!(int, 6) vec = Vector!(int, 6).build(1, 2, 3);
                assert(!vec.empty);

                vec = null;
                assert(vec.empty);

                vec = Vector!(int, 42).build(3, 2, 1);
                assert(vec == [3, 2, 1]);

                vec = Vector!(int, 2).build(4, 2);
                assert(vec == [4, 2]);
                --------------------
        */
        public void opAssign()(typeof(null) rhs)scope{
            this.clear();
        }

        /// ditto
        public void opAssign(R)(R range)scope
        if(hasLength!R
            && isInputRange!R
            && is(ElementEncodingType!R : ElementType)
        ){
            const size_t new_length = range.length;

            this.downsize(new_length);
            this.reserve(new_length);

            const size_t old_length = this.length;

            //asign elements from range
            foreach(ref elm; this._trusted_elements){
                elm = range.front;

                range.popFront;
            }

            //emplace elements from range
            if(old_length < new_length){
                ElementType[] elms = (()@trusted => this.ptr[old_length .. new_length] )();
                size_t emplaced = 0;

                scope(failure)
                    this.length = (old_length + emplaced);

                emplaceElements(emplaced, elms, forward!range);
            }

            this.length = new_length;
        }

        /// ditto
        public void opAssign(Rhs)(scope auto ref Rhs rhs)scope
        if(    isVector!Rhs
            && isAssignable!(Rhs, typeof(this)) //&& (isMoveAssignable!(V, Vector) || isCopyAssignable!(V, Vector))
        ){
            ///move:
            static if(isMoveAssignable!(rhs, typeof(this))){

                if(rhs._is_external){
                    if(minimalCapacity <= Rhs.minimalCapacity || minimalCapacity < rhs.length){
                        static if(!hasStatelessAllocator)
                            this._allocator = move(rhs._allocator);

                        this.release();
                        this._length = rhs._length;

                        this._heap_storage = rhs._heap_storage;
                        rhs._trusted_init_length();
                        return;
                    }
                }
            }

            static if(!isRef!rhs && isMoveAssignableElement!(GetElementType!Rhs, ElementType)){
                auto range = rhs._trusted_elements;
                const size_t new_length = range.length;

                this.downsize(new_length);
                this.reserve(new_length);

                const size_t old_length = this.length;


                //move asign elements from range
                foreach(ref elm; this._trusted_elements){
                    elm = move(range.front);

                    range.popFront;
                }

                //move elements from range
                if(old_length < new_length){

                    moveEmplaceRange!false(
                        (()@trusted => this.ptr + old_length)(),
                        (()@trusted => range.ptr )(),
                        (new_length - old_length)
                    );
                }

                this.length = new_length;
            }
            else{
                this.opAssign(rhs._trusted_elements);
            }


        }



        /**
            Move the last element of the vector, effectively reducing its length by 1.

            Return erased element.

            Examples:
                --------------------
                Vector!(int, 6) vec = Vector!(int, 6).build(10, 20, 30);
                assert(vec.length == 3);

                assert(vec.popBack == 30);
                assert(vec.length == 2);

                assert(vec.popBack == 20);
                assert(vec.length == 1);

                assert(vec.popBack == 10);
                assert(vec.empty);

                assert(vec.popBack == int.init);
                assert(vec.empty);
                --------------------
        */
        public ElementType popBack()(ElementType def = ElementType.init)scope nothrow{
            if(this.empty)
                return move(def);

            const size_t new_length = (this.length - 1);
            this.length = new_length;

            ElementType* ptr = (()@trusted => this.ptr + new_length )();
            ElementType result = move(*ptr);

            ///TODO can be destruct ignored for moved element?
            ///destructImpl!false(*ptr);   //destroyElement(*ptr);

            return move(result);
        }



        /**
            Move the element at position `pos` out of vector, effectively reducing its length by 1.

            Return erased element.

            If `pos` is invalid then return `def` or `ElementType.init`.

            Examples:
                --------------------
                Vector!(int, 6) vec = Vector!(int, 6).build(1, 2, 3, 4, 5);
                assert(vec.length == 5);

                assert(vec.pop(0) == 1);
                assert(vec == [2, 3, 4, 5]);

                assert(vec.pop(3) == 5);
                assert(vec == [2, 3, 4]);

                assert(vec.pop(1) == 3);
                assert(vec == [2, 4]);
                --------------------
        */
        public ElementType pop()(const size_t pos, ElementType def = ElementType.init)scope nothrow{
            const size_t old_length = this.length;

            if(pos >= old_length)
                return move(def);

            const size_t top = (pos + 1);

            ElementType* elm = (()@trusted => this.ptr + pos )();
            ElementType result = move(*elm);

            ///TODO can be destruct ignored for moved element?
            ///destructImpl!false(*elm);   //destroyElement(*elm);

            if(top < old_length){
                moveEmplaceRange(
                    elm,
                    (()@trusted => elm + 1 )(),
                    (old_length - top)
                );
            }

            this.length = (old_length - 1);
            return move(result);
        }



        /**
            Erases the contents of the `Vector`, which becomes an empty vector (with a length of 0 elements).

            Doesn't change capacity of vector.

            Examples:
                --------------------
                Vector!(int, 6) vec = Vector!(int, 6).build(1, 2, 3);

                vec.reserve(vec.capacity * 2);
                assert(vec.length == 3);

                const size_t cap = vec.capacity;
                vec.clear();
                assert(vec.capacity == cap);
                --------------------
        */
        public void clear()()scope nothrow{
            destructRangeImpl!false(this._trusted_elements);    //destroyElements(this._trusted_elements);
            this.length = 0;
        }



        /**
            Erases and deallocate the contents of the `Vector`, which becomes an empty vector (with a length of 0 characters).

            Examples:
                --------------------
                Vector!(int, 6) vec = Vector!(int, 6).build(1, 2, 3);

                vec.reserve(vec.capacity * 2);
                assert(vec.length == 3);

                const size_t cap = vec.capacity;
                vec.clear();
                assert(vec.capacity == cap);

                vec.release();
                assert(vec.capacity < cap);
                assert(vec.capacity == typeof(vec).minimalCapacity);
                --------------------
        */
        public void release()()scope nothrow{
            this._release_impl();
            this._trusted_init_length();
        }



        /**
            Requests that the vector capacity be adapted to a planned change in size to a length of up to `n` elements.

            If `n` is greater than the current vector capacity, the function causes the container to increase its capacity to `n` elements (or greater).

            In all other cases, it do nothing.

            This function has no effect on the vector length and cannot alter its content.

            Examples:
                --------------------
                Vector!(int, 6) vec = Vector!(int, 6).build(1, 2, 3);
                assert(vec.capacity == typeof(vec).minimalCapacity);

                const size_t cap = (vec.capacity * 2);
                vec.reserve(cap);
                assert(vec.capacity > typeof(vec).minimalCapacity);
                assert(vec.capacity >= cap);
                --------------------
        */
        public void reserve()(const size_t n)scope nothrow{

            void _reserve_inline(const size_t n)scope nothrow{
                static if(minimalCapacity > 0)
                    assert(!this._is_external);

                enum size_t old_capacity = InlineStorage.capacity;  //(()@trusted => this._inline_storage.capacity )();

                if(n <= old_capacity)
                    return;

                const size_t new_capacity = max(old_capacity * 2, n);


                HeapStorage heap_storage;   // = this._heap_storage_ptr(); //(()@trusted => &this._heap_storage() )();
                auto inline_elements = (()@trusted => this._inline_storage.elements(this.length) )();

                const bool d = heap_storage.allocate(_allocator, new_capacity, inline_elements);
                if(!d)assert(0, "reallocate fail");

                moveEmplaceRange!false(
                    (()@trusted => this._inline_storage.ptr )(),
                    (()@trusted => heap_storage.ptr )(),
                    this.length
                );

                this._is_external = true;
                this._heap_storage = heap_storage;
            }

            void _reserve_heap(const size_t n)scope nothrow{
                assert(this._is_external);

                const old_capacity = this._heap_storage.capacity;   //(()@trusted => this._heap_storage.capacity )();

                if(n <= old_capacity)
                    return;

                static if(minimalCapacity == 0)
                    const new_capacity = max(2, old_capacity * 2, n);
                else
                    const new_capacity = max(old_capacity * 2, n);

                if(minimalCapacity > 0 || old_capacity > 0){
                    const bool d = this._heap_storage.reallocate(_allocator, new_capacity, this.length);
                    if(!d)assert(0, "reallocate fail");
                }
                else{
                    const bool d = this._heap_storage.allocate(_allocator, new_capacity);
                    if(!d)assert(0, "allocate fail");
                }


            }

            return this._is_external
                ? _reserve_heap(n)
                : _reserve_inline(n);
        }



        /**
            Resizes the vector to a length of `n` elements.

            If `n` is smaller than the current vector length, the current value is shortened to its first `n` character, removing the characters beyond the nth.

            If `n` is greater than the current vector length, the current content is extended by inserting at the end as many elements as needed to reach a size of `n`.

            If `args` are specified, the new elements are emplaced with parameters `args`, otherwise, they are `ElementType.init`.

            Examples:
                --------------------
                Vector!(int, 6) vec = Vector!(int, 6).build(1, 2, 3);

                vec.resize(5, 0);
                assert(vec == [1, 2, 3, 0, 0]);

                vec.resize(2);
                assert(vec == [1, 2]);
                --------------------
        */
        public void resize(Args...)(const size_t n, auto ref Args args)scope{
            const size_t old_length = this.length;

            if(old_length > n){

                ElementType[] slice = (()@trusted => this.ptr[n .. old_length] )();
                destructRangeImpl!false(slice);
                this.length = n;

                /+size_t len = old_length;
                do{
                    len -= 1;

                    ElementType* ptr = (()@trusted => this.ptr + len )();
                    destroyElement(*ptr);
                }while(len != n);

                this.length = n;+/

            }
            else if(old_length < n){
                this.reserve(n);

                ElementType[] elms = ()@trusted{
                    return this._allocated_elements[old_length .. n];
                }();
                size_t emplaced = 0;

                scope(failure){
                    this.length = (old_length + emplaced);
                }

                emplaceElementsArgs(emplaced, elms, forward!args);
                /+foreach(ref elm; elms){
                    emplaceImpl(elm, args); //emplaceElement(elm, args);
                    emplaced += 1;
                }+/
                //emplaceElements(emplaced, elms, forward!args);

                this.length = n;
            }

        }



        /**
            Downsizes the vector to a length of `n` elements.

            If `n` is smaller than the current vector length, the current value is shortened to its first `n` character, removing the characters beyond the nth.

            If `n` is greater than the current vector length, then nothing happend.

            Examples:
                --------------------
                Vector!(int, 6) vec = Vector!(int, 6).build(1, 2, 3);

                vec.downsize(5);
                assert(vec == [1, 2, 3]);

                vec.downsize(2);
                assert(vec == [1, 2]);
                --------------------
        */
        public void downsize()(const size_t n)scope nothrow{
            const size_t old_length = this.length;

            if(old_length > n){

                ElementType[] slice = (()@trusted => this.ptr[n .. old_length] )();
                destructRangeImpl!false(slice);
                this.length = n;

                /+size_t len = old_length;
                do{
                    len -= 1;
                    ElementType* ptr = (()@trusted => this.ptr + len )();
                    destroyElement(*ptr);
                }while(len != n);

                this.length = n;+/
            }
        }



        /**
            Upsize the vector to a length of `n` elements.

            If `n` is smaller than the current vector length, then nothing happend.

            If `n` is greater than the current vector length, the current content is extended by inserting at the end as many elements as needed to reach a size of `n`.

            If `args` are specified, the new elements are emplaced with parameters `args`, otherwise, they are `ElementType.init`.

            Examples:
                --------------------
                Vector!(int, 6) vec = Vector!(int, 6).build(1, 2, 3);

                vec.upsize(5, 0);
                assert(vec == [1, 2, 3, 0, 0]);

                vec.upsize(2);
                assert(vec == [1, 2, 3, 0, 0]);
                --------------------
        */
        public void upsize(Args...)(const size_t n, auto ref Args args)scope @safe{
            const size_t old_length = this.length;

            if(old_length < n){
                this.reserve(n);

                ElementType[] elms = ()@trusted{
                    return this._allocated_elements[old_length .. n];
                }();

                size_t emplaced = 0;
                scope(failure){
                    this.length = (old_length + emplaced);
                }


                emplaceElementsArgs(emplaced, elms, forward!args);
                /+foreach(ref elm; elms){
                    emplaceImpl(elm, args); //emplaceElement(elm, args);
                    emplaced += 1;
                }+/
                //emplaceElements(emplaced, elms, forward!args);
                //emplaceElements(elms, forward!args);

                this.length = n;
            }
        }



        /**
            Requests the `Vector` to reduce its capacity to fit its length.

            The request is non-binding.

            This function has no effect on the vector length and cannot alter its content.

            Returns new capacity.

            Examples:
                --------------------
                Vector!(int, 6) vec = Vector!(int, 6).build(1, 2, 3);

                assert(vec.capacity == typeof(vec).minimalCapacity);

                vec.reserve(vec.capacity * 2);
                assert(vec.capacity > typeof(vec).minimalCapacity);

                vec.shrinkToFit();
                assert(vec.capacity == typeof(vec).minimalCapacity);
                --------------------
        */
        public size_t shrinkToFit(const bool reallocate = true)scope{
            if(!this._is_external)
                return minimalCapacity;

            static if(allowHeap){
                const size_t old_capacity = this._heap_storage.capacity;
                const size_t length = this.length;

                if(length <= minimalCapacity){
                    HeapStorage hs_data = this._heap_storage;

                    this._is_external = false;
                    assert(this.capacity == minimalCapacity);

                    if(minimalCapacity > 0 && length != 0)
                        moveEmplaceRange!false(
                            (()@trusted => this._inline_storage.ptr )(),
                            (()@trusted => hs_data.ptr )(),
                            length
                        );

                    this._is_external = false;
                    assert(this.capacity == minimalCapacity);

                    const bool d = hs_data.deallocate(_allocator);
                    assert(d, "deallocate of memory fail");


                    return minimalCapacity;
                }
                else{
                    if(reallocate && length < old_capacity){
                        if(this._heap_storage.reallocate!false(_allocator, length, length))
                            return length;
                    }

                    return old_capacity;
                }
            }
            else{
                assert(0, "no impl");
            }

        }



        /**
            Operator `~=` and `+=` is same as append
        */
        public template opOpAssign(string op)
        if(op == "~" || op == "+"){
            alias opOpAssign = append;
        }



        /**
            Compares the contents of a vector with another vector, range or null.

            Returns `true` if they are equal, `false` otherwise

            Examples:
                --------------------
                Vector!(int, 6) vec = Vector!(int, 6).build(1, 2, 3);

                assert(vec != null);
                assert(null != vec);

                assert(vec == [1, 2, 3]);
                assert([1, 2, 3] == vec);

                assert(vec == typeof(vec).build(1, 2, 3));
                assert(typeof(vec).build(1, 2, 3) == vec);


                import std.range : only;
                assert(vec == only(1, 2, 3));
                assert(only(1, 2, 3) == vec);
                --------------------
        */
        public bool opEquals(typeof(null) nil)const scope pure nothrow @safe @nogc{
            return this.empty;
        }

        /// ditto
        public bool opEquals(R)(scope R rhs)const scope nothrow
        if(isInputRange!R){
            import std.algorithm.comparison : equal;

            return equal(this._trusted_elements, forward!rhs);
        }

        /// ditto
        public bool opEquals(V)(scope const auto ref V rhs)const scope nothrow
        if(isVector!V){
            import std.algorithm.comparison : equal;

            return equal(this._trusted_elements, rhs._trusted_elements);
        }




        /**
            Compares the contents of a vector with another vector or range.

            Examples:
                --------------------
                auto a1 = Vector!(int, 6).build(1, 2, 3);
                auto a2 = Vector!(int, 6).build(1, 2, 3, 4);
                auto b = Vector!(int, 6).build(3, 2, 1);

                assert(a1 < b);
                assert(a1 < a2);
                assert(a2 < b);
                assert(a1 <= a1);
                --------------------
        */
        public int opCmp(R)(scope R rhs)const scope nothrow
        if(isInputRange!R){
            import std.algorithm.comparison : cmp;

            return cmp(this._trusted_elements, forward!rhs);
        }

        /// ditto
        public int opCmp(V)(scope const auto ref V rhs)const scope nothrow
        if(isVector!V){
            import std.algorithm.comparison : cmp;

            return cmp(this._trusted_elements, rhs._trusted_elements);
        }



        /**
            Returns a slice [begin .. end]. If the requested slice extends past the end of the vector, the returned slice is invalid.

            The slice returned may be invalidated by further calls to other member functions that modify the object.

            Examples:
                --------------------
                Vector!(int, 6) vec = Vector!(int, 6).build(1, 2, 3, 4, 5, 6);

                assert(vec[1 .. 4] == [2, 3, 4]);
                assert(vec[1 .. $] == [2, 3, 4, 5, 6]);
                --------------------
        */
        public inout(ElementType)[] opSlice(bool check = true)(const size_t begin, const size_t end)inout return pure nothrow @system @nogc{
            assert(begin <= this.length);
            assert(end <= this.length);

            return this.ptr[begin .. end];

        }

        //
        public size_t[2] opSlice(size_t dim : 0)(size_t begin, size_t end)const pure nothrow @safe @nogc{
            return [begin, end];
        }



        /**
            Return slice of all elements (same as `Vector.elements`).

            The slice returned may be invalidated by further calls to other member functions that modify the object.

            Examples:
                --------------------
                Vector!(int, 6) vec = Vector!(int, 6).build(1, 2, 3);

                int[] slice = vec[];
                assert(slice.length == vec.length);
                assert(slice.ptr is vec.ptr);

                vec.reserve(vec.capacity * 2);
                assert(slice.length == vec.length);
                // slice contains dangling pointer!
                --------------------
        */
        public inout(ElementType)[] opIndex()inout return pure nothrow @system @nogc{
            return this.elements();
        }



        /**
            Returns a copy to the element at position `pos`.

            Examples:
                --------------------
                Vector!(int, 6) vec = Vector!(int, 6).build(1, 2, 3, 4, 5, 6);

                assert(vec[3] == 4);
                assert(vec[$-1] == 6);
                --------------------
        */
        public CopyTypeQualifiers!(This, ElementType) opIndex(this This)(const size_t pos)scope{
            assert(pos < this.length);

            return *(()@trusted => this.ptr + pos )();
        }



        /**
            Returns reference to element at specified location `pos`.

            Examples:
                --------------------
                auto vec = Vector!(int, 10).build(1, 2, 3);

                assert(vec.at(1) == 2);
                --------------------
        */
        public ref inout(ElementType) at(const size_t pos)inout scope pure nothrow @system @nogc{
            assert(pos < this.length);

            return *(this.ptr + pos);
        }



        /**
            Assign value `val` to element at position `index`.

            Examples:
                --------------------
                {
                    auto vec = Vector!(int, 4).build(1, 2, 3, 4, 5);

                    vec[1] = 42;

                    assert(vec == [1, 42, 3, 4, 5]);
                }

                {
                    auto vec = Vector!(int, 4).build(1, 2, 3, 4, 5);

                    vec[1 .. $-1] = 42;

                    assert(vec == [1, 42, 42, 42, 5]);
                }
                --------------------

        */
        public void opIndexAssign(Val)(auto ref Val val, size_t index){
            assert(index < this.length);

            *(()@trusted => (this.ptr + index) )() = forward!val;
        }

        /// ditto
        public void opIndexAssign(Val)(auto ref Val val, size_t[2] index){
            const begin = index[0];
            const end = index[1];
            assert(begin <= this.length);
            assert(end <= this.length);


            foreach(ref elm; (()@trusted => this.ptr[begin .. end] )() )
                elm = val;
        }



        /**
            Assign `op` value `val` to element at position `index`.

            Examples:
                --------------------
                {
                    auto vec = Vector!(int, 4).build(1, 2, 3, 4, 5);

                    vec[1] += 40;

                    assert(vec == [1, 42, 3, 4, 5]);
                }

                {
                    auto vec = Vector!(int, 4).build(1, 2, 3, 4, 5);

                    vec[1 .. $-1] *= -1;

                    assert(vec == [1, -2, -3, -4, 5]);
                }
                --------------------

        */
        public void opIndexOpAssign(string op, Val)(auto ref Val val, size_t index){
            assert(index < this.length);

            ref ElementType elm()@trusted{
                return *(this.ptr + index);
            }

            mixin("elm() " ~ op ~ "= forward!val;");
        }

        /// ditto
        public void opIndexOpAssign(string op, Val)(auto ref Val val, size_t[2] index){
            const begin = index[0];
            const end = index[1];
            assert(begin <= this.length);
            assert(end <= this.length);


            foreach(ref elm; (()@trusted => this.ptr[begin .. end] )() )
                mixin("elm " ~ op ~ "= val;");
        }



        /**
            Returns the length of the vector, in terms of number of elements.

            Same as `length()`.
        */
        public size_t opDollar()const scope pure nothrow @safe @nogc{
            return this.length;
        }



        /**
            Swaps the contents of `this` and `rhs`.

            Examples:
                --------------------
                auto a = Vector!(int, 6).build(1, 2, 3);
                auto b = Vector!(int, 6).build(4, 5, 6);

                a.proxySwap(b);
                assert(a == [4, 5, 6]);
                assert(b == [1, 2, 3]);

                import std.algorithm.mutation : swap;

                swap(a, b);
                assert(a == [1, 2, 3]);
                assert(b == [4, 5, 6]);
                --------------------
        */
        public void proxySwap()(ref scope typeof(this) rhs)scope{
            import std.algorithm.mutation : swap;

            if(this._is_external && rhs._is_external){
                static if(!hasStatelessAllocator)
                    swap(this._allocator, rhs._allocator);


                ()@trusted {
                    swap(this._length, rhs._length);
                    swap(this._heap_storage, rhs._heap_storage);
                }();

            }
            else if(!this._is_external && !rhs._is_external){
                auto small = (()@trusted => (this.length < rhs.length) ?  &this : &rhs )();
                auto large = (()@trusted => (this.length < rhs.length) ?  &rhs : &this )();

                for(size_t i = 0; i < this.length; ++i)
                    swap(
                        *(()@trusted => small._inline_storage.ptr + i )(),
                        *(()@trusted => large._inline_storage.ptr + i )()
                    );

                moveEmplaceRange(
                    (()@trusted => small._inline_storage.ptr + small.length )(),
                    (()@trusted => large._inline_storage.ptr + small.length )(),
                    (large.length - small.length)
                );

                swap(this._length, rhs._length);
            }
            else{
                assert(this._is_external != rhs._is_external);

                auto heap = (()@trusted => this._is_external ? &this : &rhs )();
                auto inline = (()@trusted => this._is_external ? &rhs : &this )();

                HeapStorage heap_storage = heap._heap_storage;
                const inline_len  = inline._length;
                const heap_len  = heap._length;

                heap._length = inline_len;  //change external to false
                assert(!inline._is_external);

                moveEmplaceRange(
                    (()@trusted => heap._inline_storage.ptr )(),
                    (()@trusted => inline._inline_storage.ptr )(),
                    inline_len
                );

                inline._length = heap_len;  //change external to true
                assert(inline._is_external);
                inline._heap_storage = heap_storage;

            }

        }



        /**
            Inserts a new element into the container directly before `pos` or `ptr`.

            Return index of first inserted element.

            Parameters:
                `pos` Insertion point, the new contents are inserted before the element at position `pos`.

                `ptr` Pointer pointing to the insertion point, the new contents are inserted before the element pointed by ptr.

                `args` arguments to forward to the constructor of the element

            Examples:
                --------------------
                {
                    auto vec = Vector!(int, 6).build(1, 2, 3);

                    vec.emplace(1, 42);
                    assert(vec == [1, 42, 2, 3]);

                    vec.emplace(4, 314);
                    assert(vec == [1, 42, 2, 3, 314]);

                    vec.emplace(100, -1);
                    assert(vec == [1, 42, 2, 3, 314, -1]);
                }

                {
                    auto vec = Vector!(int, 6).build(1, 2, 3);

                    vec.emplace(vec.ptr + 1, 42);
                    assert(vec == [1, 42, 2, 3]);

                    vec.emplace(vec.ptr + 4, 314);
                    assert(vec == [1, 42, 2, 3, 314]);

                    vec.emplace(vec.ptr + 100, -1);
                    assert(vec == [1, 42, 2, 3, 314, -1]);
                }

                {
                    static struct Foo{
                        int i;
                        string str;
                    }

                    auto vec = Vector!(Foo, 6).build(Foo(1, "A"));

                    vec.emplace(1, 2, "B");
                    assert(vec == only(Foo(1, "A"), Foo(2, "B")));

                    vec.emplace(0, 42, "X");
                    assert(vec == only(Foo(42, "X"), Foo(1, "A"), Foo(2, "B")));
                }
                --------------------
        */
        public size_t emplace(Args...)(const size_t pos, auto ref Args args)scope{
            const size_t old_length = this.length;

            if(old_length <= pos){
                this.emplaceBack(forward!args);
                return old_length;
            }
            //return this.insert(pos, ElementType(forward!args));

            const size_t new_length = (old_length + 1);

            this.reserve(new_length);

            auto ptr = (()@trusted => this.ptr + pos)();

            moveEmplaceRange(
                ptr + 1,
                ptr,
                (old_length - pos)  //shift
            );

            this.length = new_length;

            emplaceImpl(*ptr, forward!args); //emplaceElement(*ptr, forward!args);

            return pos;
        }

        /// ditto
        public size_t emplace(Args...)(scope const ElementType* ptr, auto ref Args args)scope{
            auto this_ptr = (()@trusted => this.ptr )();

            const size_t pos = (ptr < this_ptr)
                ? 0
                : (ptr - this_ptr);

            return this.emplace(pos, forward!args);
        }



        /**
            Appends a new element to the end of the container. The element is constructed through `emplace`.

            Parameters:
                `args`  arguments to forward to the constructor of the element.

            Examples:
                --------------------
                {
                    auto vec = Vector!(int, 6).build(1, 2, 3);

                    vec.emplaceBack(42);
                    assert(vec == [1, 2, 3, 42]);

                    vec.emplaceBack();
                    assert(vec == [1, 2, 3, 42, 0]);
                }

                {
                    static struct Foo{
                        int i;
                        string str;
                    }

                    auto vec = Vector!(Foo, 6).build(Foo(1, "A"));

                    vec.emplaceBack(2, "B");
                    assert(vec == only(Foo(1, "A"), Foo(2, "B")));
                }
                --------------------
        */
        public void emplaceBack(Args...)(auto ref Args args)scope{
            const size_t old_length = this.length;
            const size_t new_length = (old_length + 1);

            this.reserve(new_length);
            auto ptr = (()@trusted => this.ptr + old_length )();

            emplaceImpl(*ptr, forward!args);   //emplaceElement(*ptr, forward!args);

            this.length = new_length;
        }



        /**
            Extends the `Vector` by appending additional elements at the end of vector.

            Return index of first inserted element.

            Parameters:
                `val` appended value.

                `vec` appended vector.

                `range` appended input renge.

                `count` Number of times `val` is appended.

            Examples:
                --------------------
                {
                    auto vec = Vector!(int, 6).build(1, 2, 3);

                    vec.append(42);
                    assert(vec == [1, 2, 3, 42]);
                }

                {
                    auto vec = Vector!(int, 6).build(1, 2, 3);

                    vec.append([4, 5, 6]);
                    assert(vec == [1, 2, 3, 4, 5, 6]);
                }

                {
                    auto a = Vector!(int, 6).build(1, 2, 3);
                    auto b = Vector!(int, 6).build(4, 5, 6);

                    a.append(b);
                    assert(a == [1, 2, 3, 4, 5, 6]);
                }
                --------------------
        */
        public size_t append(R)(R range)scope
        if(hasLength!R
            && isInputRange!R
            && is(ElementEncodingType!R : ElementType)
        ){
            return this._append_impl(forward!range);
        }

        /// ditto
        public size_t append(Vec)(scope auto ref Vec vec)scope
        if(isVector!Vec && is(GetElementType!Vec : ElementType)){
            return this.append(vec._trusted_elements);
        }

        /// ditto
        public size_t append(Val)(auto ref Val val, const size_t count = 1)scope
        if(is(Val : ElementType)){
            return this._append_impl(forward!val, count);
        }

        private size_t _append_impl(Args...)(auto ref Args args)scope{
            const size_t args_length = emplaceLength(args);
            const size_t old_length = this.length;
            const size_t new_length = (old_length + args_length);

            this.reserve(new_length);

            {
                ElementType[] elms = ()@trusted{
                    return this.ptr[old_length .. new_length];
                }();

                size_t emplaced = 0;
                scope(failure)
                    this.length = (old_length + emplaced);

                emplaceElements(emplaced, elms, forward!args);
            }

            this.length = new_length;

            return old_length;
        }



        /**
            Inserts additional elements into the `Vector` right before the element indicated by `pos` or `ptr`.

            Return index of first inserted element.

            Parameters:
                `pos` Insertion point, the new contents are inserted before the element at position `pos`.

                `ptr` Pointer pointing to the insertion point, the new contents are inserted before the element pointed by ptr.

                `val` Value inserted before insertion point `pos` or `ptr`.

                `vec` appended vector.

                `range` appended input renge.

                `count` Number of times `val` is inserted.

            Examples:
                --------------------
                //pos:
                {
                    auto vec = Vector!(int, 3).build(1, 2, 3);

                    size_t pos = vec.insert(1, 42, 2);
                    assert(pos == 1);
                    assert(vec == [1, 42, 42, 2, 3]);

                    pos = vec.insert(100, 4, 3);
                    assert(pos == 5);
                    assert(vec == [1, 42, 42, 2, 3, 4, 4, 4]);
                }

                {
                    auto vec = Vector!(int, 3).build(1, 2, 3);

                    size_t pos = vec.insert(1, [20, 30, 40]);
                    assert(pos == 1);
                    assert(vec == [1, 20, 30, 40, 2, 3]);

                    pos = vec.insert(100, [4, 5, 6]);
                    assert(pos == 6);
                    assert(vec == [1, 20, 30, 40, 2, 3, 4, 5, 6]);
                }

                {
                    auto vec = Vector!(int, 3).build(1, 2, 3);
                    auto tmp = Vector!(int, 10).build(-1, -2, -3);

                    size_t pos = vec.insert(1, tmp);
                    assert(pos == 1);
                    assert(vec == [1, -1, -2, -3, 2, 3]);

                    pos = vec.insert(100, Vector!(int, 10).build(40, 50, 60));
                    assert(pos == 6);
                    assert(vec == [1, -1, -2, -3, 2, 3, 40, 50, 60]);
                }

                //ptr:
                {
                    auto vec = Vector!(int, 3).build(1, 2, 3);

                    size_t pos = vec.insert(vec.ptr + 1, 42, 2);
                    assert(pos == 1);
                    assert(vec == [1, 42, 42, 2, 3]);

                    pos = vec.insert(vec.ptr + 100, 4, 3);
                    assert(pos == 5);
                    assert(vec == [1, 42, 42, 2, 3, 4, 4, 4]);
                }

                {
                    auto vec = Vector!(int, 3).build(1, 2, 3);

                    size_t pos = vec.insert(vec.ptr + 1, [20, 30, 40]);
                    assert(pos == 1);
                    assert(vec == [1, 20, 30, 40, 2, 3]);

                    pos = vec.insert(vec.ptr + 100, [4, 5, 6]);
                    assert(pos == 6);
                    assert(vec == [1, 20, 30, 40, 2, 3, 4, 5, 6]);
                }

                {
                    auto vec = Vector!(int, 3).build(1, 2, 3);
                    auto tmp = Vector!(int, 10).build(-1, -2, -3);

                    size_t pos = vec.insert(vec.ptr + 1, tmp);
                    assert(pos == 1);
                    assert(vec == [1, -1, -2, -3, 2, 3]);

                    pos = vec.insert(vec.ptr + 100, Vector!(int, 10).build(40, 50, 60));
                    assert(pos == 6);
                    assert(vec == [1, -1, -2, -3, 2, 3, 40, 50, 60]);
                }
                --------------------
        */
        public size_t insert(R)(const size_t pos, R range)scope
        if(    hasLength!R
            && isInputRange!R
            && is(ElementEncodingType!R : ElementType)
        ){
            return this._insert_impl(pos, forward!range);
        }

        /// ditto
        public size_t insert(Vec)(const size_t pos, scope auto ref Vec vec)scope
        if(isVector!Vec && is(GetElementType!Vec : ElementType)){
            return this._insert_impl(pos, vec._trusted_elements);
        }

        /// ditto
        public size_t insert(Val)(const size_t pos, auto ref Val val, const size_t count = 1)scope
        if(is(Val : ElementType)){
            return this._insert_impl(pos, forward!val, count);
        }

        /// ditto
        public size_t insert(R)(scope const ElementType* ptr, R range)scope
        if(    hasLength!R
            && isInputRange!R
            && is(ElementEncodingType!R : ElementType)
        ){
            return this._insert_impl(ptr, forward!range);
        }

        /// ditto
        public size_t insert(Vec)(scope const ElementType* ptr, scope auto ref Vec vec)scope
        if(isVector!Vec && is(GetElementType!Vec : ElementType)){
            return this._insert_impl(ptr, vec._trusted_elements);
        }

        /// ditto
        public size_t insert(Val)(scope const ElementType* ptr, auto ref Val val, const size_t count = 1)scope
        if(is(Val : ElementType)){
            return this._insert_impl(ptr, forward!val, count);
        }

        private size_t _insert_impl(Args...)(const size_t pos, auto ref Args args)scope{

            if(pos > this.length)
                return this.append(forward!args);

            const size_t args_length = emplaceLength(args);
            const size_t old_length = this.length;
            const size_t new_length = (old_length + args_length);

            this.reserve(new_length);

            ElementType[] elms = (()@trusted => this.ptr[pos .. pos + args_length])();

            moveEmplaceRange(
                (()@trusted => elms.ptr + args_length )(),
                (()@trusted => elms.ptr )(),
                (old_length - pos)  //shift
            );

            this.length = new_length;

            {
                size_t emplaced = 0;
                scope(failure)
                    initElements(elms[emplaced .. $]);

                emplaceElements(emplaced, elms, forward!args);
            }


            return pos;
        }

        private size_t _insert_impl(Args...)(scope const ElementType* ptr, auto ref Args args)scope{
            const size_t pos = (ptr > this.ptr)
                ? (ptr - this.ptr)
                : 0;

            return this._insert_impl(pos, forward!args);
        }



        /**
            Removes specified element from the vector.

            Return index of first removed element.

            Parameters:
                `pos` position of first element to be removed.

                `n` number of elements to be removed.

                `ptr` pointer to elements to be removed.

                `slice` sub-slice to be removed, `slice` must be subset of `this`

            Examples:
                --------------------
                //pos:
                {
                    auto vec = Vector!(int, 3).build(1, 2, 3, 4, 5, 6);

                    size_t pos = vec.erase(3);
                    assert(pos == 3);
                    assert(vec == [1, 2, 3]);

                    pos = vec.erase(100);
                    assert(pos == 3);
                    assert(vec == [1, 2, 3]);
                }

                {
                    auto vec = Vector!(int, 3).build(1, 2, 3, 4, 5, 6);

                    size_t pos = vec.erase(1, 4);
                    assert(pos == 1);
                    assert(vec == [1, 6]);

                    pos = vec.erase(100, 4);
                    assert(pos == 2);
                    assert(vec == [1, 6]);

                    pos = vec.erase(0, 100);
                    assert(pos == 0);
                    assert(vec.empty);
                }

                //ptr:
                {
                    auto vec = Vector!(int, 3).build(1, 2, 3, 4, 5, 6);

                    size_t pos = vec.erase(vec.ptr + 3);
                    assert(pos == 3);
                    assert(vec == [1, 2, 3]);

                    pos = vec.erase(vec.ptr + 100);
                    assert(pos == 3);
                    assert(vec == [1, 2, 3]);
                }

                {
                    auto vec = Vector!(int, 3).build(1, 2, 3, 4, 5, 6);

                    size_t pos = vec.erase(vec[1 .. 5]);
                    assert(pos == 1);
                    assert(vec == [1, 6]);
                }
                --------------------
        */
        public size_t erase()(const size_t pos)scope nothrow{
            const size_t old_length = this.length;

            if(pos >= old_length)
                return old_length;

            ElementType[] elements = this._trusted_elements[pos .. old_length];
            destructRangeImpl!false(elements);  //destroyElements(elements);

            this.length = pos;

            return pos;
        }

        /// ditto
        public size_t erase()(const size_t pos, const size_t n)scope{
            const size_t old_length = this.length;

            if(pos >= old_length)
                return old_length;

            const size_t top = (pos + n);

            if(top >= old_length)
                return this.erase(pos);

            if(n != 0){
                ElementType[] elements = this._trusted_elements;

                destructRangeImpl!false(elements[pos .. top]);  //destroyElements(elements[pos .. top]);

                moveEmplaceRange(
                    (()@trusted => elements.ptr + pos )(),
                    (()@trusted => elements.ptr + top )(),
                    (old_length - top)
                );

                this.length = (old_length - n);
            }

            return pos;
        }

        /// ditto
        public size_t erase()(scope const ElementType* ptr)scope nothrow{
            if(ptr <= this.ptr){
                this.clear();
                return 0;
            }

            return this.erase(ptr - this.ptr);
        }

        /// ditto
        public size_t erase()(scope const ElementType[] slice)scope nothrow @safe{
            const ptr = (()@trusted => this.ptr )();

            if(slice.ptr < ptr){
                const size_t offset = (()@trusted => ptr - slice.ptr)();

                if(offset >= slice.length)
                    return 0;

                return this.erase(0, slice.length - offset);
            }

            debug assert(slice.ptr >= ptr);

            const size_t pos = (()@trusted => slice.ptr - ptr )();

            return this.erase(pos, slice.length);
        }


        /**
            Replaces the portion of the vector that begins at element `pos` and spans `len` characters (or the part of the vector in the slice `slice`) by new contents.

            Parameters:
                `pos` position of the first character to be replaced.

                `len` number of elements to replace (if the vector is shorter, as many elements as possible are replaced).

                `slice` sub-slice to be removed, `slice` must be subset of `this`

                `val` inserted value.

                `count` number of times `val` is inserted.

            Examples:
                --------------------
                //pos:
                {
                    auto vec = Vector!(int, 3).build(1, 2, 3, 4, 5, 6);

                    size_t pos = vec.replace(2, 2, 0, 5);
                    assert(pos == 2);
                    assert(vec == [1, 2,  0, 0, 0, 0, 0,  5, 6]);

                    pos = vec.replace(100, 2, 42, 2);
                    assert(pos == 9);
                    assert(vec == [1, 2,  0, 0, 0, 0, 0,  5, 6,  42, 42]);

                    pos = vec.replace(2, 100, -1);
                    assert(pos == 2);
                    assert(vec == [1, 2,  -1]);
                }

                {
                    auto vec = Vector!(int, 3).build(1, 2, 3, 4, 5, 6);

                    size_t pos = vec.replace(2, 2, [0, 0, 0, 0, 0]);
                    assert(pos == 2);
                    assert(vec == [1, 2,  0, 0, 0, 0, 0,  5, 6]);

                    pos = vec.replace(100, 2, [42, 42]);
                    assert(pos == 9);
                    assert(vec == [1, 2,  0, 0, 0, 0, 0,  5, 6,  42, 42]);

                    pos = vec.replace(2, 100, [-1]);
                    assert(pos == 2);
                    assert(vec == [1, 2,  -1]);
                }

                {
                    auto vec = Vector!(int, 3).build(1, 2, 3, 4, 5, 6);

                    size_t pos = vec.replace(2, 2, Vector!(int, 3).build(0, 0, 0, 0, 0));
                    assert(pos == 2);
                    assert(vec == [1, 2,  0, 0, 0, 0, 0,  5, 6]);

                    pos = vec.replace(100, 2, Vector!(int, 2).build(42, 42));
                    assert(pos == 9);
                    assert(vec == [1, 2,  0, 0, 0, 0, 0,  5, 6,  42, 42]);

                    pos = vec.replace(2, 100, Vector!(int, 2).build(-1));
                    assert(pos == 2);
                    assert(vec == [1, 2,  -1]);
                }

                //ptr:
                {
                    auto vec = Vector!(int, 3).build(1, 2, 3, 4, 5, 6);

                    size_t pos = vec.replace(vec[2 .. 4], 0, 5);
                    assert(pos == 2);
                    assert(vec == [1, 2,  0, 0, 0, 0, 0,  5, 6]);

                    pos = vec.replace(vec.ptr[100 .. 102], 42, 2);
                    assert(pos == 9);
                    assert(vec == [1, 2,  0, 0, 0, 0, 0,  5, 6,  42, 42]);

                    pos = vec.replace(vec.ptr[2 .. 100], -1);
                    assert(pos == 2);
                    assert(vec == [1, 2,  -1]);
                }

                {
                    auto vec = Vector!(int, 3).build(1, 2, 3, 4, 5, 6);

                    size_t pos = vec.replace(vec[2 .. 4], [0, 0, 0, 0, 0]);
                    assert(pos == 2);
                    assert(vec == [1, 2,  0, 0, 0, 0, 0,  5, 6]);

                    pos = vec.replace(vec.ptr[100 .. 102], [42, 42]);
                    assert(pos == 9);
                    assert(vec == [1, 2,  0, 0, 0, 0, 0,  5, 6,  42, 42]);

                    pos = vec.replace(vec.ptr[2 .. 100], [-1]);
                    assert(pos == 2);
                    assert(vec == [1, 2,  -1]);
                }

                {
                    auto vec = Vector!(int, 3).build(1, 2, 3, 4, 5, 6);

                    size_t pos = vec.replace(vec[2 .. 4], Vector!(int, 3).build(0, 0, 0, 0, 0));
                    assert(pos == 2);
                    assert(vec == [1, 2,  0, 0, 0, 0, 0,  5, 6]);

                    pos = vec.replace(vec.ptr[100 .. 102], Vector!(int, 2).build(42, 42));
                    assert(pos == 9);
                    assert(vec == [1, 2,  0, 0, 0, 0, 0,  5, 6,  42, 42]);

                    pos = vec.replace(vec.ptr[2 .. 100], Vector!(int, 2).build(-1));
                    assert(pos == 2);
                    assert(vec == [1, 2,  -1]);
                }
                --------------------
        */
        public size_t replace(Val)(const size_t pos, const size_t len, auto ref Val val, const size_t count = 1)scope
        if(is(Val : ElementType)){
            return this._replace_impl(pos, len, forward!val, count);
        }

        /// ditto
        public size_t replace(R)(const size_t pos, const size_t len, R range)scope
        if(    hasLength!R
            && isInputRange!R
            && is(ElementEncodingType!R : ElementType)
        ){
            return this._replace_impl(pos, len, forward!range);
        }

        /// ditto
        public size_t replace(Vec)(const size_t pos, const size_t len, scope auto ref Vec vec)scope
        if(isVector!Vec && is(GetElementType!Vec : ElementType)){
            return this._replace_impl(pos, len, vec._trusted_elements);
        }

        /// ditto
        public size_t replace(Val)(scope const ElementType[] slice, auto ref Val val, const size_t count = 1)scope
        if(is(Val : ElementType)){
            return this._replace_impl(slice, forward!val, count);
        }

        /// ditto
        public size_t replace(R)(scope const ElementType[] slice, R range)scope
        if(    hasLength!R
            && isInputRange!R
            && is(ElementEncodingType!R : ElementType)
        ){
            return this._replace_impl(slice, forward!range);
        }

        /// ditto
        public size_t replace(Vec)(scope const ElementType[] slice, scope auto ref Vec vec)scope
        if(isVector!Vec && is(GetElementType!Vec : ElementType)){
            return this._replace_impl(slice, vec._trusted_elements);
        }


        private size_t _replace_impl(Args...)(const size_t pos, const size_t len, auto ref Args args)scope{
            const size_t old_length = this.length;

            if(len == 0){
                return this.insert(pos, forward!args);
            }

            if(old_length <= pos){
                return this.append(forward!args);
            }

            const size_t top = (pos + len);

            if(top >= old_length){
                this.erase(pos);
                return this.append(forward!args);
            }

            const size_t args_length = emplaceLength(args);
            alias erase_length = len;

            if(args_length == erase_length){
                ElementType[] elements = this._trusted_elements;
                ElementType[] elms = elements[pos .. top];
                destructRangeImpl!false(elms);  // destroyElements(elms);

                {
                    size_t emplaced = 0;
                    scope(failure)
                        initElements(elms[emplaced .. $]);

                    emplaceElements(emplaced, elms, forward!args);
                }

                return pos;
            }

            if(args_length < erase_length){
                const size_t diff = (erase_length - args_length);
                const size_t new_length = (old_length - diff);

                ElementType[] elements = this._trusted_elements;
                ElementType[] old_elms = elements[pos .. top];
                ElementType[] new_elms = elements[pos .. pos + args_length];

                destructRangeImpl!false(old_elms);  // destroyElements(old_elms);

                moveEmplaceRange(
                    (()@trusted => elements.ptr + top )(),
                    (()@trusted => elements.ptr + top - diff )(),
                    diff
                );

                this.length = new_length;

                {
                    size_t emplaced = 0;
                    scope(failure)
                        initElements(new_elms[emplaced .. $]);

                    emplaceElements(emplaced, new_elms, forward!args);
                }


                return pos;
            }

            assert(args_length > erase_length);
            {
                const size_t diff = (args_length - erase_length);
                const size_t new_length = (old_length + diff);

                this.reserve(new_length);

                ElementType[] elements = (()@trusted => this._allocated_elements)();
                ElementType[] old_elms = elements[pos .. top];
                ElementType[] new_elms = elements[pos .. pos + args_length];

                destructRangeImpl!false(old_elms);  // destroyElements(old_elms);

                moveEmplaceRange(
                    (()@trusted => elements.ptr + top + diff )(),
                    (()@trusted => elements.ptr + top )(),
                    diff
                );

                this.length = new_length;

                {
                    size_t emplaced = 0;
                    scope(failure)
                        initElements(new_elms[emplaced .. $]);

                    emplaceElements(emplaced, new_elms, forward!args);
                }

                return pos;
            }
        }

        private size_t _replace_impl(Args...)(scope const ElementType[] slice, auto ref Args args)scope{
            const ptr = (()@trusted => this.ptr )();

            if(slice.ptr < ptr){
                const size_t offset = (()@trusted => ptr - slice.ptr)();

                return (offset >= slice.length)
                    ? this.insert(0, forward!args)
                    : this.replace(0, slice.length - offset, forward!args);
            }

            debug assert(slice.ptr >= ptr);

            const size_t pos = (()@trusted => slice.ptr - ptr )();

            return this.replace(pos, slice.length, forward!args);
        }



        ///Alias to append.
        public alias put = append;



        /**
            Returns a reference to the first element in the vector.

            Calling this function on an empty container causes undefined behavior.


        */
        public ref inout(ElementType) front()inout return pure nothrow @system @nogc{
            assert(!this.empty);
            return *this.ptr;
        }



        /**
            Returns a reference to the last element in the vector.

            Calling this function on an empty container causes undefined behavior.
        */
        public ref inout(ElementType) back()inout return pure nothrow @system @nogc{
            assert(!this.empty);
            return *((this.ptr - 1) + this.length) ;
        }



        /**
            Returns a copy of the first element in the vector.

            Examples:
                --------------------
                auto vec = Vector!(int, 10).build(1, 2, 3);

                assert(vec.first == 1);
                --------------------
        */
        public auto first(this This)()scope{
            if(this.empty)
                assert(0, "empty vector");

            return *(()@trusted => this.ptr )();
        }



        /**
            Returns a copy to the last element in the vector.

            Calling this function on an empty container causes undefined behavior.

            Examples:
                --------------------
                auto vec = Vector!(int, 10).build(1, 2, 3);

                assert(vec.last == 3);
                --------------------
        */
        public auto last(this This)()scope{
            const size_t length = this.length;
            if(length == 0)
                assert(0, "empty vector");

            return *(()@trusted => (this.ptr + (length - 1)) )();
        }



        /**
            Static function which return `Vector` construct from arguments `args`.

            Parameters:
                `allocator` exists only if template parameter `_Allocator` has state.

                `args` values of type `ElementType`, input range or `Vector`.

            Examples:
                --------------------
                import std.range : only;

                auto vec = Vector!(int, 6).build(1, 2, [3, 4], only(5, 6), Vector!(int, 10).build(7, 8));
                assert(vec == [1, 2, 3, 4, 5, 6, 7, 8]);
                --------------------
        */
        public static typeof(this) build(Args...)(auto ref Args args){
            import core.lifetime : forward;

            auto result = Vector.init;

            result._build_impl(forward!args);

            return ()@trusted{
                return *&result;
            }();
        }

        /// ditto
        static if(allowHeap)
        public static typeof(this) build(Args...)(AllocatorType allocator, auto ref Args args){
            import core.lifetime : forward;

            auto result = (()@trusted => Vector(forward!allocator))();

            result._build_impl(forward!args);

            return ()@trusted{
                return *&result;
            }();
        }

        private void _build_impl(Args...)(auto ref Args args)scope @safe{
            import std.traits : isArray;

            assert(this.empty);

            size_t new_length = 0;

            foreach(ref arg; args)
                new_length += emplaceLength(arg);


            if(new_length == 0)
                return;

            this.reserve(new_length);


            /+foreach(alias arg; args)
                this.append(forward!arg);
            +/

            ElementType* ptr = (()@trusted => this.ptr )();

            foreach(alias arg; args){
                const size_t len = emplaceLength(arg);

                ElementType[] elms = (()@trusted => ptr[0 .. len] )();

                {
                    size_t emplaced = 0;
                    scope(failure)
                        this.length = (this.length + emplaced);

                    emplaceElements(emplaced, elms, forward!arg);
                }


                ()@trusted{
                    ptr += len;
                }();

                this.length = (this.length + len);
            }
        }



        //internals:
        private Storage _storage;
        private LengthType _length;

        static if(!allowHeap)
            private alias _allocator = NullAllocator.instance;   
        else static if(hasStatelessAllocator)
            private alias _allocator = AllocatorType.instance;        
        else
            private AllocatorType _allocator;
        

        private ref inout(InlineStorage) _inline_storage()inout return pure nothrow @trusted @nogc{
            assert(!_is_external);
            return _storage.inline_storage;
        }

        /+private inout(InlineStorage)* _trusted_inline_storage_ptr()inout scope pure nothrow @trusted @nogc{
            auto result = &_storage.inline_storage;
            return result;
        }+/

        private ref inout(HeapStorage) _heap_storage()inout return pure nothrow @trusted @nogc{
            assert(_is_external);
            return _storage.heap_storage;
        }

        private inout(HeapStorage)* _trusted_heap_storage_ptr()inout scope pure nothrow @trusted @nogc{
            auto result = &_storage.heap_storage;
            return result;
        }

        private void _trusted_init_length()pure nothrow @trusted @nogc{
            this._length = 0;

            static if(minimalCapacity == 0)
                this._heap_storage.capacity = 0;
        }

        private @property pragma(inline, true) bool _is_external()const scope pure nothrow @safe @nogc{
            static if(minimalCapacity == 0)
                return true;
            else static if(allowHeap)
                return (_length & external_flag_mask) != 0;
            else
                return false;
        }

        private @property pragma(inline, true) void _is_external(bool x)scope pure nothrow @trusted @nogc
        out(;_is_external() == x){
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

        private inout(ElementType)[] _allocated_elements()inout return pure nothrow @system @nogc{
            return this._is_external
                ? this._heap_storage.allocated_elements()
                : this._inline_storage.allocated_elements();
        }

        private inout(ElementType)[] _trusted_elements()scope inout pure nothrow @trusted @nogc{
            auto elements = this.elements;
            return *&elements;
        }

        private void _release_impl()scope nothrow{
            const bool is_external = this._is_external;

            destructRangeImpl!false(this._trusted_elements);  // destroyElements(this._trusted_elements);

            static if(allowHeap)
                if(is_external){

                    //HeapStorage* heap_storage = this._trusted_heap_storage_ptr;

                    static if(minimalCapacity == 0){
                        const size_t cap = this._heap_storage.capacity;
                        if(cap == 0)
                            return;

                    }

                    const bool d = this._heap_storage.deallocate(_allocator);
                    assert(d, "deallocate of memory fail");
                }
        }
    }


    private{

        static size_t emplaceLength(Val)(ref Val val)
        if(is(immutable Val : immutable _Type)){
            return 1;
        }

        static size_t emplaceLength(Val)(ref Val val, const size_t count)
        if(is(immutable Val : immutable _Type)){
            return count;
        }

        static size_t emplaceLength(Vec)(ref Vec vec)
        if(isVector!Vec && is(immutable Vec.ElementType == immutable _Type)){
            return vec.length;
        }

        static size_t emplaceLength(R)(ref R range)
        if(hasLength!R && isInputRange!R && is(immutable ElementEncodingType!R : immutable _Type)){
            return range.length;
        }



        static void emplaceElements(T, Val)(ref size_t emplaced, T[] slice, auto ref Val val, const size_t count)
        if(is(immutable Val : immutable _Type)){
            assert(slice.length == count);

            foreach(ref elm; slice){
                emplaceImpl(elm, val);   //emplaceElement(elm, val);
                emplaced += 1;
            }
        }

        static void emplaceElements(T, Val)(ref size_t emplaced, T[] slice, auto ref Val val)
        if(is(immutable Val : immutable _Type)){
            assert(slice.length == 1);

            foreach(ref elm; slice){
                emplaceImpl(elm, val);   //emplaceElement(elm, val);
                emplaced += 1;
            }
        }

        static void emplaceElements(T, R)(ref size_t emplaced, T[] slice, R range)
        if(hasLength!R && isInputRange!R && is(immutable ElementEncodingType!R : immutable _Type)){
            auto ptr = (()@trusted => slice.ptr )();

            debug auto end_ptr = (()@trusted => ptr + slice.length )();

            while(!range.empty){
                debug assert(ptr < end_ptr);

                emplaceImpl(*ptr, range.front);   //emplaceElement(*ptr, range.front);
                emplaced += 1;

                range.popFront();
                ()@trusted{
                    ptr += 1;
                }();
            }
        }

        static void emplaceElements(T, Vec)(ref size_t emplaced, T[] slice, scope auto ref Vec vec)
        if(isVector!Vec && is(immutable Vec.ElementType == immutable _Type)){
            emplaceElements(emplaced, slice, (()@trusted => vec.elements )() );
        }

        static void emplaceElements(T)(ref size_t emplaced, T[] slice){

            /// TODO emplaceRangeImpl if nothrow ctors
            foreach(ref elm; slice){
                emplaceImpl(elm);   //emplaceElement(elm, val);
                emplaced += 1;
            }
        }

        static void emplaceElementsArgs(T, Args...)(ref size_t emplaced, T[] slice, auto ref Args args){

            /// TODO emplaceRangeImpl if nothrow ctors
            foreach(ref elm; slice){
                emplaceImpl(elm, args);   //emplaceElement(elm, val);
                emplaced += 1;
            }
        }



        static void initElements(T)(T[] elements)nothrow{
            enum has_init = __traits(compiles, () => emplaceElement(elm));

            static if(has_init){
                foreach(ref elm; elements)
                    emplaceElement(elm);
                return true;
            }
            else{
                import std.traits : Unqual;

                assert(0, "fatal error: " ~ Unqual!T.stringof ~ " has @disabled init");

            }
        }

    }
}

/// Alias to `Vector` with different order of template parameters
template Vector(
    _Type,
    _Allocator,
    bool _supportGC = platformSupportGC
){
    alias Vector = .Vector!(_Type, 0, _Allocator, _supportGC);
}

///
pure nothrow @nogc unittest{
    import std.range : only;
    import std.algorithm : map, equal;

    static struct Foo{
        int i;
        string str;
    }

    Vector!(Foo, 4) vec;

    assert(vec.empty);
    assert(vec.capacity == 4);
    assert(typeof(vec).minimalCapacity == 4);

    vec.append(Foo(1, "A"));
    assert(vec.length == 1);

    vec.append(only(Foo(2, "B"), Foo(3, "C")));
    assert(vec.length == 3);

    vec.emplaceBack(4, "D");
    assert(vec.length == 4);
    assert(vec.capacity == 4);

    vec.insert(1, Foo(5, "E"));
    assert(vec.length == 5);
    assert(vec.capacity > 4);
    assert(equal(vec[].map!(e => e.str), only("A", "E", "B", "C", "D")));

    vec.erase(vec[1 .. $-1]);   //same as vec.erase(1, 3);
    assert(vec == only(Foo(1, "A"), Foo(4, "D")));


    vec = Vector!(Foo, 2).build(Foo(-1, "X"), Foo(-2, "Y"));
    assert(equal(vec[].map!(e => e.str), only("X", "Y")));


    vec.clear();
    assert(vec.length == 0);
    assert(vec.capacity > 4);

    vec.release();
    assert(vec.length == 0);
    assert(vec.capacity == typeof(vec).minimalCapacity);

}


/// Alias to `Vector` with `void` allcoator
template FixedVector(
    _Type,
    size_t N ,
    bool _supportGC = platformSupportGC
)
if(N > 0){
    alias FixedVector = .Vector!(_Type, N, void, _supportGC);
}


/// Alias to `Vector` with with `N > 0`
template SmallVector(
    _Type,
    size_t N ,
    _Allocator = DefaultAllocator,
    bool _supportGC = platformSupportGC
)
if(N > 0){
    alias SmallVector = .Vector!(_Type, N, _Allocator, _supportGC);
}


//storage:
private{

    union Storage(T, size_t N, Capacity, bool gcRange){
        alias Inline = InlineStorage!(T, N);
        alias Heap = HeapStorage!(T, Capacity, gcRange);

        static if(N > 0){
            Inline inline_storage;
            Heap heap_storage;
        }
        else{
            Heap heap_storage;
            Inline inline_storage;
        }

        //void[(Heap.sizeof > Inline.sizeof) ? Heap.sizeof : Inline.sizeof ] raw_storage;
    }

    struct InlineStorage(T, size_t N){
        enum size_t capacity = N;   //max(N, 2);

        static if(N > 0)
            void[capacity * T.sizeof] storage;
        else
            enum void[] storage = null;


        inout(T)* ptr()inout pure nothrow @system @nogc{
            static if(N > 0)
                return cast(inout(T)*)storage.ptr;
            else
                assert(0, "no impl");
        }

        inout(T)[] elements(size_t length)inout pure nothrow @system @nogc{
            assert(length <= capacity);

            static if(N > 0)
                return ptr[0 .. length];
            else
                assert(0, "no impl");
        }

        inout(T)[] allocated_elements()inout pure nothrow @system @nogc{
            static if(N > 0)
                return ptr[0 .. capacity];
            else
                assert(0, "no impl");
        }

        void[] data()pure nothrow @system @nogc{
            static if(N > 0)
                return (cast(void*)storage.ptr)[0 .. capacity * T.sizeof];
            else
                assert(0, "no impl");
        }
    }

    struct HeapStorage(T, Capacity, bool gcRange){

        T* ptr;
        Capacity capacity;


        inout(T)[] elements(size_t length)inout pure nothrow @system @nogc{
            assert(length <= capacity);
            return ptr[0 .. length];
        }

        inout(T)[] allocated_elements()inout pure nothrow @system @nogc{
            return ptr[0 .. capacity];
        }

        void[] data()pure nothrow @system @nogc{
            return (cast(void*)ptr)[0 .. capacity * T.sizeof];
        }

        bool allocate(A)(scope ref A allocator, size_t capacity)scope nothrow{
            void[] data = allocator.allocate(capacity * T.sizeof);
            if(data.length == 0)
                return false;

            ()@trusted{
                this.ptr = cast(T*)data.ptr;
                this.capacity = capacity;
            }();

            static if(gcRange)
                gcAddRange(data);

            return true;
        }

        bool allocate(U, A)(scope ref A allocator, size_t new_capacity, U[] elements)scope nothrow
        if(is(immutable U == immutable T)){
            void[] data = allocator.allocate(new_capacity * T.sizeof);
            if(data.length == 0)
                return false;

            if(elements.length != 0)
                ()@trusted{
                    import core.stdc.string : memcpy;
                    memcpy(data.ptr, cast(const void*)elements.ptr, elements.length * T.sizeof);
                }();

            ()@trusted{
                this.ptr = cast(T*)data.ptr;
                this.capacity = new_capacity;
            }();

            static if(gcRange)
                gcAddRange(data);

            return true;
        }

        bool reallocate(bool force = true, A)(scope ref A allocator, size_t new_capacity, size_t length)scope nothrow{
            import std.traits : hasElaborateMove;

            if(capacity >= new_capacity)
                return true;

            void[] data = (()@trusted => this.data )();
            void[] old_data = data;

            static if(hasElaborateMove!T){
                const bool reallcoated = false;
            }
            else static if(safeAllcoate!A)
                const bool reallcoated = ()@trusted{
                    return allocator.reallocate(data, new_capacity * T.sizeof);
                }();
            else
                const bool reallcoated = allocator.reallocate(data, new_capacity * T.sizeof);

            if(reallcoated){
                this.ptr = (()@trusted => cast(T*)data.ptr)();
                this.capacity = new_capacity;

                static if(gcRange){
                    gcRemoveRange(old_data);
                    gcAddRange(data);
                }

                return true;
            }

            static if(force){
                data = allocator.allocate(new_capacity * T.sizeof);
                if(data.length == 0)
                    return false;

                moveEmplaceRange!false(
                    (()@trusted => cast(T*)data.ptr )(),
                    (()@trusted => this.ptr )(),
                    length
                );
                /+
                ()@trusted{
                    import core.stdc.string : memcpy;
                    mem
                    memcpy(data.ptr, cast(const void*)this.ptr, length * T.sizeof);
                }();+/

                static if(gcRange){
                    gcAddRange(data);
                    gcRemoveRange(old_data);
                }

                static if(safeAllcoate!A)
                    const bool d = ()@trusted{
                        return allocator.deallocate(old_data);
                    }();
                else
                    const bool d = allocator.deallocate(old_data);

                ()@trusted{
                    this.ptr = cast(T*)data.ptr;
                    this.capacity = new_capacity;
                }();

                return d;
            }
            else{
                return false;
            }
        }

        bool deallocate(A)(scope ref A allocator)scope nothrow{
            void[] old_data = (()@trusted => this.data )();

            static if(gcRange)
                gcRemoveRange(old_data);


            this.ptr = null;
            this.capacity = 0;

            static if(safeAllcoate!A)
                return ()@trusted{
                    return allocator.deallocate(old_data);
                }();

            else
                return allocator.deallocate(old_data);

        }
    }



    private enum bool safeAllcoate(A) = __traits(compiles, (ref A allcoator)@safe{
        const size_t size;
        allcoator.allocate(size);
    }(*cast(A*)null));

}

//move:
private{
    void moveEmplaceRange(bool overlap = true, T, S)(T* target, S* source, size_t length){
        if(length)
            moveEmplaceRangeImpl!overlap(target, source, length);
    }
}

//GC add/remove range:
private{
    //same as GC.addRange but `pure nothrow @trusted @nogc` and with debug testing
    /+void gcAddRange(const void[] data)pure nothrow @trusted @nogc{
        gc_add_range(data.ptr, data.length);
    }
    void gc_add_range(const void* data, const size_t length)pure nothrow @trusted @nogc{
        version(D_BetterC){
        }
        else{
            import btl.internal.traits;

            assumePure(function void(const void* ptr, const size_t len){
                import core.memory: GC;
                GC.addRange(ptr, len);
            })(data, length);
        }
    }+/


    //same as GC.removeRange but `pure nothrow @trusted @nogc` and with debug testing
    /+void gc_remove_range(const void[] data)pure nothrow @trusted @nogc{
        gc_remove_range(data.ptr);
    }
    void gc_remove_range(const void* data)pure nothrow @trusted @nogc{
        version(D_BetterC){
        }
        else{
            import btl.internal.traits;

            assumePure(function void(const void* ptr){
                import core.memory: GC;
                GC.removeRange(ptr);
            })(data);
        }
    }+/
}

//local traits:
private{
    //[Copy, Move] ConstructableElement:
    template isCopyConstructableElement(From, To){
        enum isCopyConstructableElement = true
            && is(typeof((ref From from){
                To tmp = from;
            }));
    }
    template isMoveConstructableElement(From, To){
        import core.lifetime : move;
        enum isMoveConstructableElement = true
            && is(typeof((From from){
                To tmp = move(from);
            }));
    }


    //[Copy, Move] AssignableElement:
    template isCopyAssignableElement(From, To){
        enum isCopyAssignableElement = true
            && is(typeof((ref From from, ref To to){
                to = from;
            }));
    }
    template isMoveAssignableElement(From, To){
        import core.lifetime : move;
        enum isMoveAssignableElement = true
            && is(typeof((From from, ref To to){
                to = move(from);
            }));
    }


    //copy ctor:
    template hasCopyConstructor(From, To){
        import std.traits : CopyTypeQualifiers;

        static assert(From.hasStatelessAllocator == To.hasStatelessAllocator);

        static if(From.hasStatelessAllocator){
            enum bool allocator_copyable = true;
        }
        else
            enum bool allocator_copyable = isCopyConstructableElement!(
                CopyTypeQualifiers!(From, From.AllocatorType),
                CopyTypeQualifiers!(To, To.AllocatorType)
            );


        enum bool hasCopyConstructor = true
            && !is(From == shared)
            && allocator_copyable
            && isConstructable!(From, To)
            && isCopyConstructableElement!( 
                CopyTypeQualifiers!(From, From.ElementType), 
                CopyTypeQualifiers!(To, To.ElementType)
            );
    }

    template isMovable(From, To){
        import std.traits : CopyTypeQualifiers;

        enum isMovable = true
            && !is(From == shared)
            //&& (From.minimalCapacity == To.minimalCapacity)
            && (From.supportGC == To.supportGC)
            && is(GetElementReferenceType!From : GetElementReferenceType!To)
            && (From.hasStatelessAllocator == To.hasStatelessAllocator)
            && (From.hasStatelessAllocator
                ? is(immutable From.AllocatorType == immutable To.AllocatorType)
                : is(CopyTypeQualifiers!(From, From.AllocatorType) : CopyTypeQualifiers!(To, To.AllocatorType))
            );
    }
    template isMoveConstructable(alias from, To){
        import std.traits : CopyTypeQualifiers;

        alias From = typeof(from);

        enum isMoveConstructable = true
            && !isRef!from
            && isMovable!(From, To)
            && isMoveConstructableElement!(
                CopyTypeQualifiers!(From, From.AllocatorType),
                CopyTypeQualifiers!(To, To.AllocatorType)
            );
    }
    template isMoveAssignable(alias from, To){
        import std.traits : CopyTypeQualifiers, isMutable;

        alias From = typeof(from);

        enum isMoveAssignable = true
            && !isRef!from
            && isMovable!(From, To)
            && isMoveAssignableElement!(
                CopyTypeQualifiers!(From, From.AllocatorType),
                CopyTypeQualifiers!(To, To.AllocatorType)
            );
    }


    //[Copy, Move] Constructable:
    template isConstructable(From, To, bool check_allcoator = true){
        import std.traits : isMutable, CopyTypeQualifiers;

        static if(!check_allcoator)
            enum bool allocator_copyable = true;

        else static if(From.hasStatelessAllocator && To.hasStatelessAllocator)
            enum bool allocator_copyable = true;

        else static if(!From.hasStatelessAllocator && !To.hasStatelessAllocator)
            enum bool allocator_copyable = true
                && is(CopyTypeQualifiers!(From, From.AllocatorType) : CopyTypeQualifiers!(To, To.AllocatorType))
                && isMutable!To
                && isMutable!(To.AllocatorType);

        else static if(To.hasStatelessAllocator)  //@@!From.hasStatelessAllocator
            enum bool allocator_copyable = true;
        else
            enum bool allocator_copyable = true;    //TODO allcaotor must have init


        enum isConstructable = true
            && !is(From == shared)
            && (From.supportGC == To.supportGC)
            && allocator_copyable
            && is(GetElementType!From : GetElementType!To);
    }


    //[Copy, Move] Assignable:
    template isAssignable(From, To){
        import std.traits : isMutable, CopyTypeQualifiers;

        enum isAssignable = true
            && isMutable!To
            && (From.supportGC == To.supportGC)
            && is(CopyTypeQualifiers!(From, From.ElementType) : CopyTypeQualifiers!(To, To.ElementType));
    }


    



    template ElementReferenceTypeImpl(T){
        import std.traits : Select, isDynamicArray;
        import std.range : ElementEncodingType;

        static if(false
            || is(T == class) || is(T == interface)
            || is(T == function) || is(T == delegate)
            || is(T : U*, U)
        ){
            alias ElementReferenceTypeImpl = T;
        }
        else static if(isDynamicArray!T){
            alias ElementReferenceTypeImpl = ElementEncodingType!T[];
        }
        else{
            alias ElementReferenceTypeImpl = T*;
        }
    }


    template GetElementType(Vec){
        import std.traits : CopyTypeQualifiers;

        alias GetElementType = CopyTypeQualifiers!(Vec, Vec.ElementType);
    }


    template GetElementReferenceType(Vec){
        import std.traits : CopyTypeQualifiers;

        alias GetElementReferenceType = ElementReferenceTypeImpl!(GetElementType!Vec);
    }



}


//Vector examples:
version(unittest){

    private alias ZeroVector(T, size_t N) = .Vector!(T, 0);

    import std.range : only;
    static foreach(alias Vector; AliasSeq!(.Vector, ZeroVector)){

        //Vector.minimalCapacity
        pure nothrow @safe @nogc unittest{
            Vector!(int, 10) vec;
            assert(vec.capacity == typeof(vec).minimalCapacity);
        }

        //Vector.empty
        pure nothrow @safe @nogc unittest{
            Vector!(int, 10) vec;
            assert(vec.empty);

            vec.append(42);
            assert(!vec.empty);
        }

        //Vector.length
        pure nothrow @safe @nogc unittest{
            Vector!(int, 10) vec = null;
            assert(vec.length == 0);

            vec.append(42);
            assert(vec.length == 1);

            vec.append(123);
            assert(vec.length == 2);

            vec.clear();
            assert(vec.length == 0);
        }

        //Vector.capacity
        pure nothrow @safe @nogc unittest{
            Vector!(int, 10) vec;
            assert(vec.capacity == typeof(vec).minimalCapacity);

            vec.reserve(max(2, vec.capacity * 2));
            assert(vec.capacity > typeof(vec).minimalCapacity);
        }

        //Vector.ptr
        pure nothrow @nogc unittest{
            Vector!(int, 6) vec = Vector!(int, 6).build(1, 2, 3);

            assert(vec.ptr[0 .. 3] == [1, 2, 3]);
        }

        //Vector.elements
        pure nothrow @nogc unittest{
            Vector!(int, 6) vec = Vector!(int, 6).build(1, 2, 3);

            int[] slice = vec.elements;
            assert(slice.length == vec.length);
            assert(slice.ptr is vec.ptr);

            const size_t old_capacity = vec.capacity;
            vec.reserve(max(2, vec.capacity * 2));
            assert(vec.capacity != old_capacity);
            assert(slice.length == vec.length);
            // slice contains dangling pointer!
        }

        //Vector.popBack
        pure nothrow @nogc @safe unittest{
            Vector!(int, 6) vec = Vector!(int, 6).build(10, 20, 30);
            assert(vec.length == 3);

            assert(vec.popBack == 30);
            assert(vec.length == 2);

            assert(vec.popBack == 20);
            assert(vec.length == 1);

            assert(vec.popBack == 10);
            assert(vec.empty);

            assert(vec.popBack == int.init);
            assert(vec.empty);
        }

        //Vector.pop
        pure nothrow @nogc @safe unittest{
            Vector!(int, 6) vec = Vector!(int, 6).build(1, 2, 3, 4, 5);
            assert(vec.length == 5);

            assert(vec.pop(0) == 1);
            assert(vec == [2, 3, 4, 5]);

            assert(vec.pop(3) == 5);
            assert(vec == [2, 3, 4]);

            assert(vec.pop(1) == 3);
            assert(vec == [2, 4]);
        }

        //Vector.clear
        pure nothrow @nogc @safe unittest{
            Vector!(int, 6) vec = Vector!(int, 6).build(1, 2, 3);

            vec.reserve(vec.capacity * 2);
            assert(vec.length == 3);

            const size_t cap = vec.capacity;
            vec.clear();
            assert(vec.capacity == cap);
        }

        //Vector.release
        pure nothrow @nogc @safe unittest{
            Vector!(int, 6) vec = Vector!(int, 6).build(1, 2, 3);

            vec.reserve(vec.capacity * 2);
            assert(vec.length == 3);

            const size_t cap = vec.capacity;
            vec.clear();
            assert(vec.capacity == cap);

            vec.release();
            assert(vec.capacity < cap);
            assert(vec.capacity == typeof(vec).minimalCapacity);
        }

        //Vector.reserve
        pure nothrow @nogc @safe unittest{
            Vector!(int, 6) vec = Vector!(int, 6).build(1, 2, 3);

            const size_t old_capacity = vec.capacity;//assert(vec.capacity == typeof(vec).minimalCapacity);
            const size_t cap = (vec.capacity * 2);

            vec.reserve(cap);
            assert(vec.capacity > old_capacity);
            assert(vec.capacity >= cap);
        }

        //Vector.resize
        pure nothrow @nogc @safe unittest{
            Vector!(int, 6) vec = Vector!(int, 6).build(1, 2, 3);

            vec.resize(5, 0);
            assert(vec == [1, 2, 3, 0, 0]);

            vec.resize(2);
            assert(vec == [1, 2]);
        }

        //Vector.downsize
        pure nothrow @nogc @safe unittest{
            Vector!(int, 6) vec = Vector!(int, 6).build(1, 2, 3);

            vec.downsize(5);
            assert(vec == [1, 2, 3]);

            vec.downsize(2);
            assert(vec == [1, 2]);
        }

        //Vector.upsize
        pure nothrow @nogc @safe unittest{
            Vector!(int, 6) vec = Vector!(int, 6).build(1, 2, 3);

            vec.upsize(5, 0);
            assert(vec == [1, 2, 3, 0, 0]);

            vec.upsize(2);
            assert(vec == [1, 2, 3, 0, 0]);
        }

        //Vector.shrinkToFit
        pure nothrow @nogc @safe unittest{
            auto vec = Vector!(int, 3).build(1, 2, 3);


            assert(vec.capacity == vec.length);

            vec.reserve(vec.capacity * 2);
            assert(vec.capacity > vec.length);

            static if(typeof(vec).minimalCapacity != 0){
                vec.shrinkToFit();
                assert(vec.capacity == vec.length);
            }
        }

        //Vector._ctor
        pure nothrow @nogc @safe unittest{
            {
                Vector!(int, 6) vec = null;
                assert(vec.empty);
            }


            {
                Vector!(int, 6) vec = Vector!(int, 6).build(1, 2);
                assert(vec == [1, 2]);
            }
            {
                auto tmp = Vector!(int, 6).build(1, 2);
                Vector!(int, 6) vec = tmp;
                assert(vec == [1, 2]);
            }


            {
                Vector!(int, 6) vec = Vector!(int, 4).build(1, 2);
                assert(vec == [1, 2]);
            }
            {
                auto tmp = Vector!(int, 4).build(1, 2);
                Vector!(int, 6) vec = tmp;
                assert(vec == [1, 2]);
            }
        }

        //Vector.opAssign
        pure nothrow @nogc @safe unittest{
            Vector!(int, 6) vec = Vector!(int, 6).build(1, 2, 3);
            assert(!vec.empty);

            vec = null;
            assert(vec.empty);

            vec = Vector!(int, 42).build(3, 2, 1);
            //debug writeln(vec[]);
            assert(vec == [3, 2, 1]);

            vec = Vector!(int, 2).build(4, 2);
            assert(vec == [4, 2]);
        }

        //Vector.opEquals
        pure nothrow @nogc @safe unittest{
            Vector!(int, 6) vec = Vector!(int, 6).build(1, 2, 3);

            assert(vec != null);
            assert(null != vec);

            assert(vec == [1, 2, 3]);
            assert([1, 2, 3] == vec);

            assert(vec == typeof(vec).build(1, 2, 3));
            assert(typeof(vec).build(1, 2, 3) == vec);


            import std.range : only;
            assert(vec == only(1, 2, 3));
            assert(only(1, 2, 3) == vec);
        }

        //Vector.opCmp
        pure nothrow @nogc @safe unittest{
            auto a1 = Vector!(int, 6).build(1, 2, 3);
            auto a2 = Vector!(int, 6).build(1, 2, 3, 4);
            auto b = Vector!(int, 6).build(3, 2, 1);

            assert(a1 < b);
            assert(a1 < a2);
            assert(a2 < b);
            assert(a1 <= a1);
        }

        //Vector.opIndexAssign
        pure nothrow @nogc @safe unittest{

            {
                auto vec = Vector!(int, 4).build(1, 2, 3, 4, 5);

                vec[1] = 42;

                assert(vec == [1, 42, 3, 4, 5]);
            }

            {
                auto vec = Vector!(int, 4).build(1, 2, 3, 4, 5);

                vec[1 .. $-1] = 42;

                assert(vec == [1, 42, 42, 42, 5]);
            }
        }

        //Vector.opIndexOpAssign
        pure nothrow @nogc @safe unittest{
            {
                auto vec = Vector!(int, 4).build(1, 2, 3, 4, 5);

                vec[1] += 40;

                assert(vec == [1, 42, 3, 4, 5]);
            }

            {
                auto vec = Vector!(int, 4).build(1, 2, 3, 4, 5);

                vec[1 .. $-1] *= -1;

                assert(vec == [1, -2, -3, -4, 5]);
            }
        }

        //Vector.opIndex()
        pure nothrow @nogc @system unittest{
            Vector!(int, 6) vec = Vector!(int, 6).build(1, 2, 3);

            scope int[] slice = vec[];
            assert(slice.length == vec.length);
            assert(slice.ptr is vec.ptr);

            vec.reserve(vec.capacity * 2);
            assert(slice.length == vec.length);
            // slice contains dangling pointer!
        }

        //Vector.opSlice(begin, end)
        pure nothrow @nogc @system unittest{
            Vector!(int, 6) vec = Vector!(int, 6).build(1, 2, 3, 4, 5, 6);

            assert(vec[1 .. 4] == [2, 3, 4]);
            assert(vec[1 .. $] == [2, 3, 4, 5, 6]);
        }

        //Vector.opIndex
        pure nothrow @nogc @system unittest{
            Vector!(int, 6) vec = Vector!(int, 6).build(1, 2, 3, 4, 5, 6);

            assert(vec[3] == 4);
            assert(vec[$-1] == 6);
        }

        //Vector.proxySwap
        pure nothrow @nogc @system unittest{
            auto a = Vector!(int, 6).build(1, 2, 3);
            auto b = Vector!(int, 6).build(4, 5, 6, 7);

            a.proxySwap(b);
            assert(a == [4, 5, 6, 7]);
            assert(b == [1, 2, 3]);

            import std.algorithm.mutation : swap;

            swap(a, b);
            assert(a == [1, 2, 3]);
            assert(b == [4, 5, 6, 7]);
        }


        //Vector.emplace
        pure nothrow @nogc @system unittest{
            {
                auto vec = Vector!(int, 6).build(1, 2, 3);

                vec.emplace(1, 42);
                //debug writeln(vec[]);
                assert(vec == [1, 42, 2, 3]);

                vec.emplace(4, 314);
                assert(vec == [1, 42, 2, 3, 314]);

                vec.emplace(100, -1);
                assert(vec == [1, 42, 2, 3, 314, -1]);
            }

            {
                auto vec = Vector!(int, 6).build(1, 2, 3);

                vec.emplace(vec.ptr + 1, 42);
                assert(vec == [1, 42, 2, 3]);

                vec.emplace(vec.ptr + 4, 314);
                assert(vec == [1, 42, 2, 3, 314]);

                vec.emplace(vec.ptr + 100, -1);
                assert(vec == [1, 42, 2, 3, 314, -1]);
            }

            {
                static struct Foo{
                    int i;
                    string str;
                }

                auto vec = Vector!(Foo, 6).build(Foo(1, "A"));

                vec.emplace(1, 2, "B");
                assert(vec == only(Foo(1, "A"), Foo(2, "B")));

                vec.emplace(0, 42, "X");
                assert(vec == only(Foo(42, "X"), Foo(1, "A"), Foo(2, "B")));
            }
        }


        //Vector.emplaceBack
        pure nothrow @nogc @system unittest{
            {
                auto vec = Vector!(int, 6).build(1, 2, 3);

                vec.emplaceBack(42);
                assert(vec == [1, 2, 3, 42]);

                vec.emplaceBack();
                assert(vec == [1, 2, 3, 42, 0]);
            }

            {
                static struct Foo{
                    int i;
                    string str;
                }

                auto vec = Vector!(Foo, 6).build(Foo(1, "A"));

                vec.emplaceBack(2, "B");
                assert(vec == only(Foo(1, "A"), Foo(2, "B")));
            }
        }

        //Vector.append
        pure nothrow @nogc @system unittest{
            {
                auto vec = Vector!(int, 6).build(1, 2, 3);

                vec.append(42);
                assert(vec == [1, 2, 3, 42]);
            }

            {
                auto vec = Vector!(int, 6).build(1, 2, 3);

                vec.append(only(4, 5, 6));
                assert(vec == [1, 2, 3, 4, 5, 6]);
            }

            {
                auto a = Vector!(int, 6).build(1, 2, 3);
                auto b = Vector!(int, 6).build(4, 5, 6);

                a.append(b);
                assert(a == [1, 2, 3, 4, 5, 6]);
            }
        }

        //Vector.insert
        pure nothrow @nogc @system unittest{
            //pos:
            {
                auto vec = Vector!(int, 3).build(1, 2, 3);

                size_t pos = vec.insert(1, 42, 2);
                assert(pos == 1);
                assert(vec == [1, 42, 42, 2, 3]);

                pos = vec.insert(100, 4, 3);
                assert(pos == 5);
                assert(vec == [1, 42, 42, 2, 3, 4, 4, 4]);
            }

            {
                auto vec = Vector!(int, 3).build(1, 2, 3);

                size_t pos = vec.insert(1, only(20, 30, 40));
                assert(pos == 1);
                assert(vec == [1, 20, 30, 40, 2, 3]);

                pos = vec.insert(100, only(4, 5, 6));
                assert(pos == 6);
                assert(vec == [1, 20, 30, 40, 2, 3, 4, 5, 6]);
            }

            {
                auto vec = Vector!(int, 3).build(1, 2, 3);
                auto tmp = Vector!(int, 10).build(-1, -2, -3);

                size_t pos = vec.insert(1, tmp);
                assert(pos == 1);
                assert(vec == [1, -1, -2, -3, 2, 3]);

                pos = vec.insert(100, Vector!(int, 10).build(40, 50, 60));
                assert(pos == 6);
                assert(vec == [1, -1, -2, -3, 2, 3, 40, 50, 60]);
            }

            //ptr:
            {
                auto vec = Vector!(int, 3).build(1, 2, 3);

                size_t pos = vec.insert(vec.ptr + 1, 42, 2);
                assert(pos == 1);
                assert(vec == [1, 42, 42, 2, 3]);

                pos = vec.insert(vec.ptr + 100, 4, 3);
                assert(pos == 5);
                assert(vec == [1, 42, 42, 2, 3, 4, 4, 4]);
            }

            {
                auto vec = Vector!(int, 3).build(1, 2, 3);

                size_t pos = vec.insert(vec.ptr + 1, only(20, 30, 40));
                assert(pos == 1);
                assert(vec == [1, 20, 30, 40, 2, 3]);

                pos = vec.insert(vec.ptr + 100, only(4, 5, 6));
                assert(pos == 6);
                assert(vec == [1, 20, 30, 40, 2, 3, 4, 5, 6]);
            }

            {
                auto vec = Vector!(int, 3).build(1, 2, 3);
                auto tmp = Vector!(int, 10).build(-1, -2, -3);

                size_t pos = vec.insert(vec.ptr + 1, tmp);
                assert(pos == 1);
                assert(vec == [1, -1, -2, -3, 2, 3]);

                pos = vec.insert(vec.ptr + 100, Vector!(int, 10).build(40, 50, 60));
                assert(pos == 6);
                assert(vec == [1, -1, -2, -3, 2, 3, 40, 50, 60]);
            }
        }

        //Vector.erase
        pure nothrow @nogc @system unittest{
            //pos:
            {
                auto vec = Vector!(int, 3).build(1, 2, 3, 4, 5, 6);

                size_t pos = vec.erase(3);
                assert(pos == 3);
                assert(vec == [1, 2, 3]);

                pos = vec.erase(100);
                assert(pos == 3);
                assert(vec == [1, 2, 3]);
            }

            {
                auto vec = Vector!(int, 3).build(1, 2, 3, 4, 5, 6);

                size_t pos = vec.erase(1, 4);
                assert(pos == 1);
                assert(vec == [1, 6]);

                pos = vec.erase(100, 4);
                assert(pos == 2);
                assert(vec == [1, 6]);

                pos = vec.erase(0, 100);
                assert(pos == 0);
                assert(vec.empty);
            }

            //ptr:
            {
                auto vec = Vector!(int, 3).build(1, 2, 3, 4, 5, 6);

                size_t pos = vec.erase(vec.ptr + 3);
                assert(pos == 3);
                assert(vec == [1, 2, 3]);

                pos = vec.erase(vec.ptr + 100);
                assert(pos == 3);
                assert(vec == [1, 2, 3]);
            }

            {
                auto vec = Vector!(int, 3).build(1, 2, 3, 4, 5, 6);

                size_t pos = vec.erase(vec[1 .. 5]);
                assert(pos == 1);
                assert(vec == [1, 6]);
            }
        }

        //Vector.replace
        pure nothrow @nogc @system unittest{
            //pos:
            {
                auto vec = Vector!(int, 3).build(1, 2, 3, 4, 5, 6);

                size_t pos = vec.replace(2, 2, 0, 5);
                assert(pos == 2);
                assert(vec == [1, 2,  0, 0, 0, 0, 0,  5, 6]);

                pos = vec.replace(100, 2, 42, 2);
                assert(pos == 9);
                assert(vec == [1, 2,  0, 0, 0, 0, 0,  5, 6,  42, 42]);

                pos = vec.replace(2, 100, -1);
                assert(pos == 2);
                assert(vec == [1, 2,  -1]);
            }

            {
                auto vec = Vector!(int, 3).build(1, 2, 3, 4, 5, 6);

                size_t pos = vec.replace(2, 2, only(0, 0, 0, 0, 0));
                assert(pos == 2);
                assert(vec == [1, 2,  0, 0, 0, 0, 0,  5, 6]);

                pos = vec.replace(100, 2, only(42, 42));
                assert(pos == 9);
                assert(vec == [1, 2,  0, 0, 0, 0, 0,  5, 6,  42, 42]);

                pos = vec.replace(2, 100, only(-1));
                assert(pos == 2);
                assert(vec == [1, 2,  -1]);
            }

            {
                auto vec = Vector!(int, 3).build(1, 2, 3, 4, 5, 6);

                size_t pos = vec.replace(2, 2, Vector!(int, 3).build(0, 0, 0, 0, 0));
                assert(pos == 2);
                assert(vec == [1, 2,  0, 0, 0, 0, 0,  5, 6]);

                pos = vec.replace(100, 2, Vector!(int, 2).build(42, 42));
                assert(pos == 9);
                assert(vec == [1, 2,  0, 0, 0, 0, 0,  5, 6,  42, 42]);

                pos = vec.replace(2, 100, Vector!(int, 2).build(-1));
                assert(pos == 2);
                assert(vec == [1, 2,  -1]);
            }

            //ptr:
            {
                auto vec = Vector!(int, 3).build(1, 2, 3, 4, 5, 6);

                size_t pos = vec.replace(vec[2 .. 4], 0, 5);
                assert(pos == 2);
                assert(vec == [1, 2,  0, 0, 0, 0, 0,  5, 6]);

                pos = vec.replace(vec.ptr[100 .. 102], 42, 2);
                assert(pos == 9);
                assert(vec == [1, 2,  0, 0, 0, 0, 0,  5, 6,  42, 42]);

                pos = vec.replace(vec.ptr[2 .. 100], -1);
                assert(pos == 2);
                assert(vec == [1, 2,  -1]);
            }

            {
                auto vec = Vector!(int, 3).build(1, 2, 3, 4, 5, 6);

                size_t pos = vec.replace(vec[2 .. 4], only(0, 0, 0, 0, 0));
                assert(pos == 2);
                assert(vec == [1, 2,  0, 0, 0, 0, 0,  5, 6]);

                pos = vec.replace(vec.ptr[100 .. 102], only(42, 42));
                assert(pos == 9);
                assert(vec == [1, 2,  0, 0, 0, 0, 0,  5, 6,  42, 42]);

                pos = vec.replace(vec.ptr[2 .. 100], only(-1));
                assert(pos == 2);
                assert(vec == [1, 2,  -1]);
            }

            {
                auto vec = Vector!(int, 3).build(1, 2, 3, 4, 5, 6);

                size_t pos = vec.replace(vec[2 .. 4], Vector!(int, 3).build(0, 0, 0, 0, 0));
                assert(pos == 2);
                assert(vec == [1, 2,  0, 0, 0, 0, 0,  5, 6]);

                pos = vec.replace(vec.ptr[100 .. 102], Vector!(int, 2).build(42, 42));
                assert(pos == 9);
                assert(vec == [1, 2,  0, 0, 0, 0, 0,  5, 6,  42, 42]);

                pos = vec.replace(vec.ptr[2 .. 100], Vector!(int, 2).build(-1));
                assert(pos == 2);
                assert(vec == [1, 2,  -1]);
            }
        }

        //Vector.first
        pure nothrow @nogc @safe unittest{
            auto vec = Vector!(int, 10).build(1, 2, 3);

            assert(vec.first == 1);
        }

        //Vector.last
        pure nothrow @nogc @safe unittest{
            auto vec = Vector!(int, 10).build(1, 2, 3);

            assert(vec.last == 3);
        }

        //Vector.at
        pure nothrow @nogc @system unittest{
            auto vec = Vector!(int, 10).build(1, 2, 3);

            assert(vec.at(1) == 2);
        }



        //Vector.build
        pure nothrow @nogc @safe unittest{
            import std.range : only;

            auto vec = Vector!(int, 6).build(1, 2, only(3, 4), only(5, 6), Vector!(int, 10).build(7, 8));
            assert(vec == [1, 2, 3, 4, 5, 6, 7, 8]);
        }
    }
}


//ctors + assign tests:
version(unittest){
    struct Foo{

        static class Counter{
            this(char name)pure @safe @nogc nothrow{
                this.name = name;
            }
            char name;
            int objects = 0;
            uint ctor;
            uint copy;
            uint dtor;
            uint move_assign;
            uint copy_assign;
            uint move;
        }
        private Counter counter;

        //@disable this();

        void opPostMove(const scope ref typeof(this))pure nothrow @safe @nogc{
            if(counter)
                counter.move += 1;
        }
        this(Counter counter)pure nothrow @safe @nogc{
            this.counter = counter;
            counter.objects += 1;
            counter.ctor += 1;
        }

        this(ref scope typeof(this) rhs)pure nothrow @safe @nogc{
            this.counter = (()@trusted => rhs.counter )();

            if(counter){
                counter.objects += 1;
                counter.copy += 1;
            }
        }

        ~this()pure nothrow @safe @nogc{
            if(counter){
                counter.objects -= 1;
                counter.dtor += 1;
            }
        }

        void opAssign(ref scope typeof(this) rhs)scope pure nothrow @safe @nogc{
            this.counter = (()@trusted => rhs.counter )();

            if(counter){
                counter.objects += 1;
                counter.copy_assign += 1;
            }
        }

        void opAssign(scope typeof(this) rhs)scope pure nothrow @safe @nogc{
            this.counter = (()@trusted => *&rhs.counter )();
            if(counter){
                counter.move_assign += 1;
                rhs.counter = null;
            }
        }


    }

    //ctors:
    pure nothrow @safe unittest{
        import core.lifetime : move;
        import std.range : iota, array;
        import std.algorithm : map, all;

        Foo.Counter[3] counters = [new Foo.Counter('A'), new Foo.Counter('B'), new Foo.Counter('C')];

        //small->small
        {
            //copy
            assert(counters[].all!(c => c.objects == 0));
            {
                auto vec = Vector!(Foo, 4).build(iota(0, 3, 1).map!(x => Foo(counters[x])));
                assert(counters[].all!(c => c.objects == 1));
                assert(vec.small);

                auto vec2 = vec;
                assert(counters[].all!(c => c.objects == 2));
                assert(vec2.small);
            }

            //move
            assert(counters[].all!(c => c.objects == 0));
            {
                auto vec = Vector!(Foo, 4).build(iota(0, 3, 1).map!(x => Foo(counters[x])));
                assert(counters[].all!(c => c.objects == 1));
                assert(vec.small);

                auto vec2 = move(vec);
                assert(counters[].all!(c => c.objects == 1));
                assert(vec2.small);
            }
        }

        //large->large
        {
            //copy
            assert(counters[].all!(c => c.objects == 0));
            {
                auto vec = Vector!(Foo, 2).build(iota(0, 3, 1).map!(x => Foo(counters[x])));
                assert(counters[].all!(c => c.objects == 1));
                assert(!vec.small);

                auto vec2 = vec;
                assert(counters[].all!(c => c.objects == 2));
                assert(!vec2.small);
            }

            //move
            assert(counters[].all!(c => c.objects == 0));
            {
                auto vec = Vector!(Foo, 2).build(iota(0, 3, 1).map!(x => Foo(counters[x])));
                assert(counters[].all!(c => c.objects == 1));
                assert(!vec.small);

                auto vec2 = move(vec);
                assert(counters[].all!(c => c.objects == 1));
                assert(!vec2.small);
            }

        }


        //large->small
        {
            //copy
            assert(counters[].all!(c => c.objects == 0));
            {
                auto vec = Vector!(Foo, 2).build(iota(0, 3, 1).map!(x => Foo(counters[x])));
                assert(counters[].all!(c => c.objects == 1));
                assert(!vec.small);

                Vector!(Foo, 4) vec2 = vec;
                assert(counters[].all!(c => c.objects == 2));
                assert(vec2.small);
            }

            //move
            assert(counters[].all!(c => c.objects == 0));
            {
                auto vec = Vector!(Foo, 2).build(iota(0, 3, 1).map!(x => Foo(counters[x])));
                assert(counters[].all!(c => c.objects == 1));
                assert(!vec.small);

                //debug writeln("-----");
                Vector!(Foo, 4) vec2 = move(vec);
                assert(counters[].all!(c => c.objects == 1));
                //debug writeln(vec2.length, ", ", vec2.capacity, ", ", vec2.minimalCapacity);
                assert(vec2.small);
            }

        }


        //small->large
        {
            //copy
            assert(counters[].all!(c => c.objects == 0));
            {
                auto vec = Vector!(Foo, 4).build(iota(0, 3, 1).map!(x => Foo(counters[x])));
                assert(counters[].all!(c => c.objects == 1));
                assert(vec.small);

                Vector!(Foo, 2) vec2 = vec;
                assert(counters[].all!(c => c.objects == 2));
                assert(!vec2.small);
            }

            //move
            assert(counters[].all!(c => c.objects == 0));
            {
                auto vec = Vector!(Foo, 4).build(iota(0, 3, 1).map!(x => Foo(counters[x])));
                assert(counters[].all!(c => c.objects == 1));
                assert(vec.small);

                Vector!(Foo, 2) vec2 = move(vec);
                assert(counters[].all!(c => c.objects == 1));
                assert(!vec2.small);
            }
        }


    }

    //assign:
    pure nothrow @safe unittest{
        //TODO
    }


    //simple rvalue ctor:
    pure nothrow @safe @nogc unittest{
        import core.lifetime : move;
        {
            auto vec = Vector!(int, 4).build(1, 2, 3);
            assert(vec.small);

            auto vec2 = move(vec);
            assert(vec2.small);


            //assert(vec2 == [1, 2, 3]);
            assert(vec.empty);

        }

        {
            auto vec = Vector!(int, 4).build(1, 2, 3);
            assert(vec.small);

            Vector!(int, 2) vec2 = move(vec);
            assert(!vec2.small);

            assert(vec2 == [1, 2, 3]);
            assert(vec.empty);
        }

        {
            auto vec = Vector!(int, 2).build(1, 2, 3);
            assert(!vec.small);

            Vector!(int, 2) vec2 = move(vec);
            assert(!vec2.small);

            assert(vec2 == [1, 2, 3]);
            assert(vec.empty);
        }

        {
            auto vec = Vector!(int, 2).build(1, 2, 3);
            assert(!vec.small);

            Vector!(int, 4) vec2 = move(vec);
            assert(vec2.small);

            assert(vec2 == [1, 2, 3]);
            assert(vec.empty);
        }
    }

    //simple lvalue ctor:
    pure nothrow @safe @nogc unittest{
        import core.lifetime : move;
        {
            auto vec = Vector!(int, 4).build(1, 2, 3);
            auto vec2 = vec;

            assert(vec.small && vec2.small);

            assert(vec2 == [1, 2, 3]);
            assert(vec == [1, 2, 3]);
        }

        {
            auto vec = Vector!(int, 4).build(1, 2, 3);
            Vector!(int, 2) vec2 = vec;

            assert(vec.small && !vec2.small);

            assert(vec2 == [1, 2, 3]);
            assert(vec == [1, 2, 3]);
        }

        {
            auto vec = Vector!(int, 2).build(1, 2, 3);
            Vector!(int, 2) vec2 = vec;

            assert(!vec.small && !vec2.small);

            assert(vec2 == [1, 2, 3]);
            assert(vec == [1, 2, 3]);
        }

        {
            auto vec = Vector!(int, 2).build(1, 2, 3);
            Vector!(int, 4) vec2 = vec;

            assert(!vec.small && vec2.small);

            assert(vec2 == [1, 2, 3]);
            assert(vec == [1, 2, 3]);
        }
    }

}

//opAssign tests:
version(unittest){
    //TODO

}


//swap tests:
version(unittest){

    pure nothrow @safe @nogc unittest{
        auto small = Vector!(int, 4).build(1, 2);
        auto large = Vector!(int, 4).build(10, 20, 30, 40, 50, 60, 70);

        assert(small.small == true);
        assert(large.small == false);

        small.proxySwap(large);
        assert(small == [10, 20, 30, 40, 50, 60, 70]);
        assert(large == [1, 2]);


        assert(small.small == false);
        assert(large.small == true);
    }

    pure nothrow @safe @nogc unittest{
        auto a = Vector!(int, 4).build(1, 2);
        auto b = Vector!(int, 4).build(3, 4);

        assert(a.small == true);
        assert(b.small == true);

        a.proxySwap(b);
        assert(a == [3, 4]);
        assert(b == [1, 2]);

        assert(a.small == true);
        assert(b.small == true);
    }

    pure nothrow @safe @nogc unittest{
        auto a = Vector!(int, 4).build(1, 2, 3, 4, 5, 6, 7);
        auto b = Vector!(int, 4).build(10, 20, 30, 40, 50, 60, 70);

        assert(a.small == false);
        assert(b.small == false);

        a.proxySwap(b);
        assert(a == [10, 20, 30, 40, 50, 60, 70]);
        assert(b == [1, 2, 3, 4, 5, 6, 7]);

        assert(a.small == false);
        assert(b.small == false);
    }


}

//version
version(unittest){
    private import btl.internal.test_allocator;

    nothrow unittest{
        TestAllocator* allcoator = new TestAllocator;

        auto vec = Vector!(int, 2, TestAllocator*)(allcoator);

        assert(allcoator.get_count == 0);

        vec.append([1, 2, 3, 4, 5, 6]);
        assert(allcoator.get_count == 1);

        auto vec2 = vec;
        assert(allcoator.get_count == 2);

        vec.release();
        assert(allcoator.get_count == 1);

        vec2.release();
        assert(allcoator.get_count == 0);
    }

}


//.md example
pure nothrow @nogc unittest{
    import std.range : only;
    import std.algorithm : map, equal;

    static struct Foo{
        int i;
        string str;
    }

    Vector!(Foo, 4) vec;

    assert(vec.empty);
    assert(vec.capacity == 4);
    assert(typeof(vec).minimalCapacity == 4);

    vec.append(Foo(1, "A"));
    assert(vec.length == 1);

    vec.append(only(Foo(2, "B"), Foo(3, "C")));
    assert(vec.length == 3);

    vec.emplaceBack(4, "D");
    assert(vec.length == 4);
    assert(vec.capacity == 4);

    vec.insert(1, Foo(5, "E"));
    assert(vec.length == 5);
    assert(vec.capacity > 4);
    assert(equal(vec[].map!(e => e.str), only("A", "E", "B", "C", "D")));

    vec.erase(vec[1 .. $-1]);   //same as vec.erase(1, 3);
    assert(vec == only(Foo(1, "A"), Foo(4, "D")));


    vec.clear();
    assert(vec.length == 0);
    assert(vec.capacity > 4);

    vec.release();
    assert(vec.length == 0);
    assert(vec.capacity == typeof(vec).minimalCapacity);

    vec = Vector!(Foo, 4).build(Foo(-1, "X"), Foo(-2, "Y"));
    assert(equal(vec[].map!(e => e.str), only("X", "Y")));

}


//opIndexAssign
@safe pure nothrow @nogc unittest{
    auto vec = Vector!int.build(1, 2, 3);

    vec[0] = -1;
    assert(vec == [-1, 2, 3]);

    vec[1 .. $] = -2;
    assert(vec == [-1, -2, -2]);

    vec[0] *= -1;
    assert(vec == [1, -2, -2]);

    vec[1 .. $] *= -1;
    assert(vec == [1, 2, 2]);




}
