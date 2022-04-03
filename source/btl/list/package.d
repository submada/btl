module btl.list;

import std.traits : Unqual, Unconst, isSomeChar, isSomeString, CopyTypeQualifiers;
import std.meta : AliasSeq;
import std.traits : Select;

import btl.internal.traits;
import btl.internal.allocator;
import btl.internal.forward;
import btl.internal.gc;
import btl.internal.lifetime;


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
template isList(T...)
if(T.length == 1){
    enum bool isList = is(Unqual!(T[0]) == List!Args, Args...);
}

enum ListKind{
    Forward,
    Backward,
    Bidirect,
}

private struct ListNode(Type, ListKind kind){
    Type element;

    static if(kind == ListKind.Backward || kind == ListKind.Bidirect)
        ListNode* prev;

    static if(kind == ListKind.Forward || kind == ListKind.Bidirect)
        ListNode* next;

}

template List(
    _Type,
    _Allocator = DefaultAllocator,
    bool _supportGC = shouldAddGCRange!_Type,
    ListKind _kind = ListKind.Bidirect,
){
    import core.lifetime : emplace, forward, move;

    alias Node = ListNode!(_Type, _kind);

    enum bool _hasStatelessAllocator = isStatelessAllocator!_Allocator;
    enum bool _allowHeap = !is(immutable _Allocator == immutable void);

    enum bool forwardList = (kind == ListKind.Forward || kind == ListKind.Bidirect);
    enum bool backwardList = (kind == ListKind.Backward || kind == ListKind.Bidirect);

    struct List{

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
        public alias AllocatorType = _Allocator;



        /**
        */
        public alias supportGC = _supportGC;



        /**
            Allow heap (`false` only if `Allcoator` is void)
        */
        public alias allowHeap = _allowHeap;



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
            Returns whether the list is empty (i.e. whether its length is 0).

            Examples:
                --------------------
                List!(int) list;
                assert(list.empty);

                list.append(42);
                assert(!list.empty);
                --------------------
        */
        public @property bool empty()const scope pure nothrow @safe @nogc{
            return (this._length == 0);
        }



        /**
            Returns the length of the list, in terms of number of elements.

            Examples:
                --------------------
                List!(int) list = null;
                assert(list.length == 0);

                list.append(42);
                assert(list.length == 1);

                list.append(123);
                assert(list.length == 2);

                list.clear();
                assert(list.length == 0);
                --------------------
        */
        public @property size_t length()const scope pure nothrow @safe @nogc{
            return this._length;
        }



        /**
            Destroys the `List` object.

            This deallocates all the storage capacity allocated by the `List` using its allocator.
        */
        public ~this()scope{
            this._release_impl();
        }



        /**
            Constructs a empty `List` with allocator `a`.

            Examples:
                --------------------
                {
                    List!(int) list = DefaultAllocator.init;
                    assert(list.empty);
                }
                --------------------

        */
        static if(allowHeap)
        public this(AllocatorType a)scope pure nothrow @safe @nogc{
            static if(!hasStatelessAllocator)
                this._allocator = forward!a;
        }



        /**
            Constructs a empty `List`

            Examples:
                --------------------
                {
                    List!(int) list = null;
                    assert(list.empty);
                }
                --------------------

        */
        public this(typeof(null) nil)scope pure nothrow @safe @nogc{
        }



        /**
            Constructs a `List` object from other list.

            Parameters:
                `rhs` other list of `List` type.

                `allocator` optional allocator parameter.

            Examples:
                --------------------
                {
                    List!(int) list = List!(int).build(1, 2);
                    assert(list == [1, 2]);
                }
                {
                    auto tmp = List!(int).build(1, 2);
                    List!(int) list = tmp;
                    assert(list == [1, 2]);
                }


                {
                    List!(int) list = List!(int).build(1, 2);
                    assert(list == [1, 2]);
                }
                {
                    auto tmp = List!(int).build(1, 2);
                    List!(int) list = tmp;
                    assert(list == [1, 2]);
                }
                --------------------
        */
        public this(Rhs, this This)(scope auto ref Rhs rhs)scope
        if(    isList!Rhs
            && isConstructable!(Rhs, This)
            && (isRef!Rhs || !is(immutable This == immutable Rhs))
        ){
            this(forward!rhs, Forward.init);
        }

        //forward ctor impl:
        private this(Rhs, this This)(scope auto ref Rhs rhs, Forward)scope
        if(isList!Rhs && isConstructable!(Rhs, This)){

            //move:
            static if(isMoveConstructable!(rhs, This)){

                static if(!hasStatelessAllocator)
                    this._allocator = move(rhs._allocator);

                this._length = rhs.length;
                rhs.length = 0;

                static if(backwardList){
                    this._last = rhs._last;
                    rhs._last = null;
                }
                static if(forwardList){
                    this._first = rhs._first;
                    rhs._first = null;
                }
            }
            //move elements:
            else static if(!isRef!rhs && isMoveConstructableElement!(GetElementType!Rhs, ElementType)){
                static if(!hasStatelessAllocator)
                    this._allocator = rhs._allocator;

                assert(0, "TODO");
            }
            //copy:
            else{
                /+static if(hasStatelessAllocator){
                    this(rhs.storage.elements);
                }
                else{
                    this(rhs.storage.elements, rhs.allocator);
                }+/
                assert(0, "TODO");
            }
        }



        /**
            Constructs a `List` object from range of elements.

            Parameters:
                `range` input reange of `ElementType` elements.

                `allocator` optional allocator parameter.

            Examples:
                --------------------
                import std.range : iota;
                {
                    List!(int) list = iota(0, 5);
                    assert(list == [0, 1, 2, 3, 4]);
                }
                --------------------
        */
        public this(R, this This)(R range)scope
        if(isInputRange!R && is(ElementEncodingType!R : GetElementType!This)){
            this._init_from_range(forward!range);
        }

        /// ditto
        static if(allowHeap)
        public this(R, this This)(R range, AllocatorType allcoator)return
        if(isInputRange!R && is(ElementEncodingType!R : GetElementType!This)){
            static if(!hasStatelessAllocator)
                this._allocator = forward!allcoator;

            this._init_from_range(forward!range);
        }

        private void _init_from_range(R, this This)(R range)scope
        if(isInputRange!R && is(ElementEncodingType!R : GetElementType!This)){
            auto self = (()@trusted => (cast(Unqual!This*)&this) )();

            assert(0, "TODO");
            /+const size_t length = range.length;

            self.reserve(length);

            {
                auto elms = ()@trusted{
                    return cast(GetElementType!This[])self.ptr[0 .. length];
                }();

                size_t emplaced = 0;
                scope(failure){
                    self.storage.length = emplaced;
                }

                emplaceElements(emplaced, elms, forward!range);
            }

            self.storage.length = length;+/
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
            Assigns a new value `rhs` to the list, replacing its current contents.

            Parameter `rhs` can by type of `null`, `List` or input range of ElementType elements.

            Examples:
                --------------------
                List!(int) list = List!(int).build(1, 2, 3);
                assert(!list.empty);

                list = null;
                assert(list.empty);

                list = List!(int).build(3, 2, 1);
                assert(list == [3, 2, 1]);

                list = List!(int).build(4, 2);
                assert(list == [4, 2]);
                --------------------
        */
        public void opAssign()(typeof(null) rhs)scope{
            this.clear();
        }

        /// ditto
        public void opAssign(R)(R range)scope
        if(isInputRange!R && is(ElementEncodingType!R : ElementType)){
            assert(0, "TODO");
        }

        /// ditto
        public void opAssign(Rhs)(scope auto ref Rhs rhs)scope
        if(isList!Rhs && isAssignable!(Rhs, typeof(this)) ){
            ///move:
            static if(isMoveAssignable!(rhs, typeof(this))){
                static if(!hasStatelessAllocator)
                    this._allocator = move(rhs._allocator);

                this._length = rhs.length;
                rhs.length = 0;

                static if(backwardList){
                    this._last = rhs._last;
                    rhs._last = null;
                }
                static if(forwardList){
                    this._first = rhs._first;
                    rhs._first = null;
                }
            }
            else static if(!isRef!rhs
                && isMoveAssignableElement!(GetElementType!Rhs, ElementType)
            ){
                assert(0, "TODO");
            }
            else{
                //this.opAssign(rhs.storage.elements);
                assert(0, "TODO");
            }


        }




        private size_t _length;

        static if(backwardList)
            private Node* _last;
        static if(forwardList)
            private Node* _first;

    }
}


//local traits:
private{

    enum bool safeAllcoate(A) = __traits(compiles, (ref A allcoator)@safe{
        const size_t size;
        allcoator.allocate(size);
    }(*cast(A*)null));


    //copy ctor:
    template hasCopyConstructor(From, To)
    if(is(immutable From == immutable To)){

        enum bool hasCopyConstructor = true
            && !is(From == shared)
            && isConstructable!(From, To)
            && isCopyConstructableElement!(
                GetElementType!From,
                GetElementType!To
            )
            && (From.hasStatelessAllocator
                || isCopyConstructableElement!(
                    GetAllocatorType!From,
                    GetAllocatorType!To
                )
            )
            && (From.hasStatelessAllocator
                || isCopyConstructableElement!(
                    GetAllocatorType!From,
                    To.AllocatorType
                )
            );
    }

    //Move Constructable:
    template isMoveConstructable(alias from, To){
        alias From = typeof(from);

        enum isMoveConstructable = true
            && !isRef!from
            && isConstructable!(From, To)
            && (From.kind == To.kind)
            && is(GetElementReferenceType!From : GetElementReferenceType!To)
            && is(immutable From.AllocatorType == immutable To.AllocatorType)
            && (From.hasStatelessAllocator
                || isMoveConstructableElement!(
                        GetAllocatorType!From,
                        GetAllocatorType!To
                )
            );
    }

    //Move Assignable:
    template isMoveAssignable(alias from, To){
        alias From = typeof(from);

        enum isMoveAssignable = true
            && !isRef!from
            && isAssignable!(From, To)
            && (From.kind == To.kind)
            && is(GetElementReferenceType!From : GetElementReferenceType!To)
            && is(immutable From.AllocatorType == immutable To.AllocatorType)
            && (From.hasStatelessAllocator
                || isMoveAssignableElement!(
                        GetAllocatorType!From,
                        GetAllocatorType!To
                )
            );
    }

    //Constructable:
    template isConstructable(From, To){

        enum isConstructable = true
            && !is(From == shared)
            && (From.supportGC == To.supportGC)
            && is(GetElementType!From : GetElementType!To)
            && (From.hasStatelessAllocator
                ? is(immutable From.AllocatorType == immutable To.AllocatorType)
                : is(immutable From.AllocatorType : immutable To.AllocatorType)
            );
    }

    //Assignable:
    template isAssignable(From, To){
        import std.traits : isMutable;

        enum isAssignable = true
            && isMutable!To
            && !is(From == shared) && !is(To == shared)
            && (From.supportGC == To.supportGC)
            && is(GetElementType!From : GetElementType!To);
    }



    template GetElementType(Container){
        alias GetElementType = CopyTypeQualifiers!(Container, Container.ElementType);
    }

    template GetAllocatorType(Container){
        alias GetAllocatorType = CopyTypeQualifiers!(Container, Container.AllocatorType);
    }

    template GetElementReferenceType(Container){
        alias GetElementReferenceType = ElementReferenceTypeImpl!(GetElementType!Container);
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


}

