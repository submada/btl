/**
    Implementation of associative container that supports unique keys `FlatMap` (similar to c++ `boost::flat_map`).

    License:   $(HTTP www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
    Authors:   $(HTTP github.com/submada/btl, Adam Búš)
*/
module btl.vector.flat_map;

import btl.internal.traits;
import btl.internal.allocator;
import btl.internal.forward;
import btl.internal.gc;
import btl.internal.lifetime;

import btl.vector;


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
template isFlatMap(T...)
if(T.length == 1){
    import std.traits : Unqual;
    enum bool isFlatMap = is(Unqual!(T[0]) == FlatMap!Args, Args...);
}


/**
*/
template FlatMap(
    _Key,
    _Value,
    size_t N = 0,
    _Allocator = DefaultAllocator,
    bool _supportGC = (shouldAddGCRange!_Key || shouldAddGCRange!_Value)
){
    import core.lifetime : forward, move;
    import std.traits : CopyConstness, isMutable;
    import std.meta : AliasSeq;


    alias Pair = .Pair!(_Key, _Value);
    alias Storage = Vector!(Pair, N, _Allocator, _supportGC);

    static _Key makeKey(K)(auto ref K key){
        static if(is(immutable K : immutable _Key)){
            return forward!key;
        }
        else{
            return _Key(forward!key);
        }
    }

    struct FlatMap{
        /**
            Type of key.
        */
        public alias KeyType = _Key;



        /**
            Type of value.
        */
        public alias ValueType = _Value;



        /**
            Type of internal vector.
        */
        public alias VectorType = Storage;



        /**
            True if allocator doesn't have state.
        */
        public alias hasStatelessAllocator = Storage.hasStatelessAllocator;



        /**
            Type of elements (pair of key and value).
        */
        public alias ElementType = Storage.ElementType;



        /**
            Type of reference to elements.
        */
        public alias ElementReferenceType = Storage.ElementReferenceType;



        /**
            Type of the allocator object used to define the storage allocation model. By default `DefaultAllocator` is used.
        */
        public alias AllocatorType = Storage.AllocatorType;



        /**
        */
        public alias supportGC = Storage.supportGC;



        /**
            Allow heap (`false` only if `Allcoator` is void)
        */
        public alias allowHeap = Storage.allowHeap;



        /**
            Maximal capacity of container, in terms of number of elements.
        */
        public alias maximalCapacity = Storage.maximalCapacity;



        /**
            Minimal capacity of container, in terms of number of elements.
        */
        public alias minimalCapacity = Storage.minimalCapacity;



        /**
            Returns copy of allocator.
        */
        public @property auto allocator(this This)()scope{
            return this.storage.allcoator();
        }



        /**
            Returns whether the falt map is empty (i.e. whether its length is 0).

            More: `btl.vector.Vector.empty`
        */
        public @property bool empty()scope const pure nothrow @safe @nogc{
            return this.storage.empty;
        }



        /**
            Returns the length of the flat map, in terms of number of elements.

            More: `btl.vector.Vector.length`
        */
        public @property size_t length()scope const pure nothrow @safe @nogc{
            return this.storage.length;
        }



        /**
            Returns the size of the storage space currently allocated for the container.

            More: `btl.vector.Vector.capacity`
        */
        public @property size_t capacity()const scope pure nothrow @trusted @nogc{
            return this.storage.capacity;
        }



        /**
            Constructs a `FlatMap` object from other flat map.

            Parameters:
                `rhs` other vector of `FlatMap` type.

                `allocator` optional allocator parameter.

            Examples:
                --------------------
                TODO 
                --------------------
        */
        public this(Rhs, this This)(scope auto ref Rhs rhs)scope
        if(    isFlatMap!Rhs
            && isConstructable!(Rhs, This)
            && (isRef!Rhs || !is(immutable This == immutable Rhs))
        ){
            static if(isRef!rhs || !isMutable!Rhs)
                this.storage = Storage(rhs.storage, wf);
            else
                this.storage = Storage(move(rhs.storage), wf);
        }



        /**
            Forward constructor.
        */
        public this(Rhs, this This)(scope auto ref Rhs rhs, Forward wf)scope
        if(isFlatMap!Rhs && isConstructable!(Rhs, This)){
            static if(isRef!rhs || !isMutable!Rhs)
                this.storage = Storage(rhs.storage, wf);
            else
                this.storage = Storage(move(rhs.storage), wf);
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
                this(scope ref From rhs)scope{this(rhs, Forward.init);}
            else
                @disable this(scope ref From rhs)scope pure nothrow @safe;

            static if(hasCopyConstructor!(From, const typeof(this)))
                this(scope ref From rhs)const scope{this(rhs, Forward.init);}
            else
                @disable this(scope ref From rhs)const scope pure nothrow @safe;

            static if(hasCopyConstructor!(From, immutable typeof(this)))
                this(scope ref From rhs)immutable scope{this(rhs, Forward.init);}
            else
                @disable this(scope ref From rhs)immutable scope pure nothrow @safe;

            static if(hasCopyConstructor!(From, shared typeof(this)))
                this(scope ref From rhs)shared scope{this(rhs, Forward.init);}
            else
                @disable this(scope ref From rhs)shared scope pure nothrow @safe;

            static if(hasCopyConstructor!(From, const shared typeof(this)))
                this(scope ref From rhs)const shared scope{this(rhs, Forward.init);}
            else
                @disable this(scope ref From rhs)const shared scope pure nothrow @safe;
        }



        /**
            Assigns a new value `rhs` to the flat map, replacing its current contents.

            Examples:
                --------------------
                TODO
                --------------------
        */
        public void opAssign(Rhs)(scope auto ref Rhs rhs)scope
        if(isFlatMap!Rhs && isAssignable!(Rhs, typeof(this)) ){
            static if(isRef!rhs || !isMutable!Rhs)
                this.storage.opAssign(rhs.storage);
            else
                this.storage.opAssign(move(rhs.storage));
        }



        /**
            Returns pointer elements value with specified `key` or null if container doesn't contains `key`.

            Examples:
                --------------------
                TODO
                --------------------
        */
        public CopyConstness!(This, ValueType)* at(K, this This)(scope auto ref K key)return scope pure nothrow @system @nogc
        out(ret){
            scope const(ValueType)* tmp = null;

            foreach(ref pair; this.storage[]){
                if(pair.key == key){
                    tmp = &pair.value;
                    break;
                }
            }

            assert(ret is tmp);

        }
        do{
            
            auto slice = (()@trusted => this.storage.opIndex() )();
            size_t begin = 0;
            size_t end = slice.length;

            while(begin < end){
                const diff = (end - begin) / 2;
                const pos = (begin + diff);

                if(slice[pos].key == key){
                    return &slice[pos].value;
                }

                if(slice[pos].key > key)
                    end = pos;
                else
                    begin = (pos + 1);
            }

            return null;
        }



        /**
            Returns copy of element value with specified `key` or ValueType.init if container doesn't contains `key`.

            Examples:
                --------------------
                TODO
                --------------------
        */
        public CopyConstness!(This, ValueType) atCopy(K, this This)(scope auto ref K key){
            if(auto val = this.at(forward!key))
                return *val;

            return typeof(return).init;
        }



        /**
            Returns reference of element value with specified `key`.

            If container doesn't contains value with key `key` then ValueType.init is created for it.

            Examples:
                --------------------
                TODO
                --------------------
        */
        public ref ValueType opIndex(K)(scope auto ref K key)return pure nothrow @system @nogc{
            
            auto slice = (()@trusted => this.storage.opIndex() )();
            size_t begin = 0;
            size_t end = slice.length;

            while(begin < end){
                const diff = (end - begin) / 2;
                const pos = (begin + diff);

                if(slice[pos].key == key){
                    return slice[pos].value;
                }

                if(slice[pos].key > key)
                    end = pos;
                else
                    begin = (pos + 1);
            }

            const pos = this.storage.insert(
                begin,
                Pair(
                    makeKey(forward!key),
                    ValueType.init,
                )
            );

            return this.storage[pos].value;
        }



        /**
        */
        public void opIndexAssign(V : ValueType, K)(auto ref V value, auto ref K key){
            auto slice = (()@trusted => this.storage.opIndex() )();
            size_t begin = 0;
            size_t end = slice.length;

            while(begin < end){
                const diff = (end - begin) / 2;
                const pos = (begin + diff);

                if(slice[pos].key == key){
                    slice[pos].value = forward!value;
                    return;
                }

                if(slice[pos].key > key)
                    end = pos;
                else
                    begin = (pos + 1);
            }

            this.storage.insert(
                begin,
                Pair(
                    makeKey(forward!key),
                    forward!value,
                )
            );
        }



        /**
        */
        public CopyConstness!(This, .Pair!(const KeyType, ValueType))[] opIndex(this This)()return scope @system{
            return cast(typeof(return))this.storage[];
        }



        /**
            Returns the length of the container, in terms of number of elements.

            Same as `length()`.
        */
        public size_t opDollar()const scope pure nothrow @safe @nogc{
            return this.length;
        }



        /**
            Operator `in`


            Examples:
                --------------------
                TODO
                --------------------
        */
        public bool opBinaryRight(string op : "in", K)(scope auto ref K key)scope const pure nothrow @trusted @nogc{
            return this.at(forward!key) !is null;
        }



        /**
            Compares the contents of a container with another container, range or null.

            Returns `true` if they are equal, `false` otherwise

            Examples:
                --------------------
                TODO
                --------------------
        */
        public bool opEquals(R)(scope R rhs)const scope nothrow
        if(isBtlInputRange!R){
            return this.storage.opEquals(forward!rhs);
        }

        /// ditto
        public bool opEquals(V)(scope const auto ref V rhs)const scope nothrow
        if(isVector!V){
            return this.storage.opEquals(rhs);
        }

        /// ditto
        public bool opEquals(FM)(scope const auto ref FM rhs)const scope nothrow
        if(isFlatMap!FM){
            return this.storage.opEquals(rhs.storage);
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
        if(isBtlInputRange!R){
            return this.storage.opCmp(forward!rhs);
        }

        /// ditto
        public int opCmp(V)(scope const auto ref V rhs)const scope nothrow
        if(isVector!V){
            return this.storage.opCmp(rhs);
        }

        /// ditto
        public int opCmp(FM)(scope const auto ref FM rhs)const scope nothrow
        if(isFlatMap!FM){
            return this.storage.opCmp(rhs.storage);
        }



        /**
            Swaps the contents of `this` and `rhs`.

            More: `btl.vector.Vector.proxySwap`
        */
        public void proxySwap()(ref scope typeof(this) rhs)scope{
            this.storage.proxySwap(rhs.storage);
        }



        /**
            Swaps the contents of `this` and `rhs` only if both are heap allocated.

            Return `true` if swap successed or `false` if not (`this` or `rhs` is non heap allocated).

            More: `btl.vector.Vector.heapSwap`
        */
        public bool heapSwap()(ref scope typeof(this) rhs)scope{
            return this.storage.heapSwap(rhs.storage);
        }



        /**
            Erases the contents of the container, which becomes an empty (with a length of 0 elements).

            Doesn't change capacity of container.

            More: `btl.vector.Vector.clear`
        */
        public void clear()()scope nothrow{
            this.storage.clear();
        }



        /**
            Erases and deallocate the contents of the container, which becomes an empty (with a length of 0 elements).

            More: `btl.vector.Vector.release`
        */
        public void release()()scope nothrow{
            this.storage.release();
        }



        /**
            Requests that the container capacity be adapted to a planned change in size to a length of up to `n` elements.

            More: `btl.vector.Vector.reserve`
        */
        public void reserve()(const size_t n)scope nothrow{
            this.storage.reserve(n);
        }



        /**
            Requests the `Vector` to reduce its capacity to fit its length.

            More: `btl.vector.Vector.shrinkToFit`
        */
        public void shrinkToFit(const bool reallocate = true)scope{
            this.storage.shrinkToFit(reallocate);
        }



        /**
        */
        public bool remove(scope const ValueType* val)@trusted{
            if(val is null)
                return false;

            scope const Pair* pair = cast(const Pair*)((cast(const void*)val) - Pair.value.offsetof);

            if(!this.storage.ownsElement(pair))
                return false;

            this.storage.erase(pair[0 .. 1]);
            return true;
        }



        /**
        */
        public bool remove(K)(scope auto ref K key)scope{
            return this.remove((()@trusted => this.at(forward!key) )());
        }



        /**
        */
        public void remove(size_t index)scope{
            this.storage.erase(index, 1);
        }



        private Storage storage;
    }


}


private struct Pair(_Key, _Value){
    public alias KeyType = _Key;
    public alias ValueType = _Value;

    public KeyType key;
    public ValueType value;
}

//local traits:
package{

    enum bool safeAllcoate(A) = __traits(compiles, (ref A allcoator)@safe{
        const size_t size;
        allcoator.allocate(size);
    }(*cast(A*)null));


    //copy ctor:
    template hasCopyConstructor(From, To)
    if(is(immutable From == immutable To)){
        enum bool hasCopyConstructor = btl.vector.hasCopyConstructor!(
            GetVectorType!From,
            GetVectorType!To
        );

    }

    //Constructable:
    template isConstructable(From, To){
        enum isConstructable = btl.vector.isConstructable!(
            GetVectorType!From,
            GetVectorType!To
        );
    }

    //Assignable:
    template isAssignable(From, To){
        enum isAssignable = btl.vector.isAssignable!(
            GetVectorType!From,
            GetVectorType!To
        );
    }


    template GetVectorType(FM){
        import std.traits : CopyTypeQualifiers;
        alias GetVectorType = CopyTypeQualifiers!(FM, FM.VectorType);
    }
    


}



