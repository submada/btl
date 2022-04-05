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

private struct ListNode(Type, bool bidirectional){
    private Type element;
    private ListNode* next;
    static if(bidirectional)
        private ListNode* prev;

}

private template ListRange(Type, bool bidirectional){
    alias Node = ListNode!(Type, bidirectional);

    struct ListRange{

        private Node* node;

        public this(Node* node)pure nothrow @nogc @safe{
            this.node = node;
        }

        public bool empty()scope const pure nothrow @nogc @safe{
            return (node is null);
        }

        public ref inout(Type) front()inout scope return pure nothrow @nogc @safe{
            assert(node !is null);
            return node.element;
        }

        public void popFront()scope pure nothrow @nogc @safe{
            assert(node !is null);
            node = node.next;
        }

        static if(bidirectional)
        public void popBack()scope pure nothrow @nogc @safe{
            assert(node !is null);
            node = node.prev;
        }

    }
}


template List(
    _Type,
    _Allocator = DefaultAllocator,
    bool _supportGC = shouldAddGCRange!_Type,
    bool _bidirectional = true,
){
    import core.lifetime : emplace, forward, move;

    alias ListNode = .ListNode!(_Type, _bidirectional);
    alias ListRange = .ListRange!(_Type, _bidirectional);

    enum bool _hasStatelessAllocator = isStatelessAllocator!_Allocator;
    enum bool _allowHeap = !is(immutable _Allocator == immutable void);

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
        */
        public alias bidirectional = _bidirectional;



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



        static if(bidirectional){
            /**
                Pop the last element of the bidirectional list, effectively reducing its length by 1.

                Return erased element.

                Examples:
                    --------------------
                    List!(int) list = List!(int).build(10, 20, 30);
                    assert(list.length == 3);

                    assert(list.popBack == 30);
                    assert(list.length == 2);

                    assert(list.popBack == 20);
                    assert(list.length == 1);

                    assert(list.popBack == 10);
                    assert(list.empty);

                    assert(list.popBack == int.init);
                    assert(list.empty);

                    assert(list.popBack(42) == 42);
                    assert(list.empty);
                    --------------------
            */
            public ElementType popBack()()scope nothrow{
                if(this.empty)
                    return ElementType.init;

                ListNode* node = this._last;
                this._last = this._last.prev;

                ElementType result = move(node.element);
                destructImpl(*node);

                this._length -= 1;
                return move(result);
            }

            ///ditto
            public ElementType popBack()(ElementType def)scope nothrow{
                if(this.empty)
                    return move(def);

                ListNode* node = this._last;
                this._last = this._last.prev;

                ElementType result = move(node.element);
                destructImpl(*node);

                this._length -= 1;
                return move(result);
            }
        }



        /**
            Pop the first element of the list, effectively reducing its length by 1.

            Return erased element.

            Examples:
                --------------------
                List!(int) list = List!(int).build(30, 20, 10);
                assert(list.length == 3);

                assert(list.popFront == 30);
                assert(list.length == 2);

                assert(list.popFront == 20);
                assert(list.length == 1);

                assert(list.popFront == 10);
                assert(list.empty);

                assert(list.popFront == int.init);
                assert(list.empty);

                assert(list.popFront(42) == 42);
                assert(list.empty);
                --------------------
        */
        public ElementType popFront()()scope nothrow{
            if(this.empty)
                return ElementType.init;

            ListNode* node = this._last;
            this._last = this._last.prev;

            ElementType result = move(node.element);
            destructImpl(*node);

            this._length -= 1;
            return move(result);
        }

        ///ditto
        public ElementType popFront()(ElementType def)scope nothrow{
            if(this.empty)
                return move(def);

            ListNode* node = this._last;
            this._last = this._last.prev;

            ElementType result = move(node.element);
            destructImpl(*node);

            this._length -= 1;
            return move(result);
        }



        /**
            Erases and deallocate the contents of the `List`, which becomes an empty list (with a length of 0 elements).

            Same as `clear`.

            Examples:
                --------------------
                List!(int) list = Vector!(List).build(1, 2, 3);
                assert(list.length == 3);

                list.release();
                assert(list.length == 0);
                --------------------
        */
        public void release()()scope nothrow{
            ListNode* node = this._first;

            while(node !is null){
                ListNode* tmp = node;
                node = node.next;
                this._destroy_node(tmp);
            }

            this._first = null;
            static if(bidirectional)
                this._last = null;

            this._length = 0;
        }



        /**
            Erases and deallocate the contents of the `List`, which becomes an empty list (with a length of 0 elements).

            Same as `release`.

            Examples:
                --------------------
                List!(int) list = Vector!(List).build(1, 2, 3);
                assert(list.length == 3);

                list.clear();
                assert(list.length == 0);
                --------------------
        */
        public alias clear = release;



        /**
            Same as operator `in`

            Examples:
                --------------------
                List!(int) list = List!(int).build(1, 2, 3);

                assert(list.contains(1));
                assert(!list.contains(42L));
                --------------------
        */
        public bool contains(Elm)(scope auto ref Elm elm)scope const{
            foreach(ref e; this[]){
                if(e == elm)
                    return true;
            }

            return false;
        }



        /**
            Operator `in`


            Examples:
                --------------------
                List!(int) list = List!(int).build(1, 2, 3);

                assert(1 in list);
                assert(42L !in list);
                --------------------
        */
        public bool opBinaryRight(string op, Elm)(scope auto ref Elm elm)scope const
        if(op == "in"){
            return this.contains(forward!elm);
        }



        /**
            Compares the contents of a list with another list, range or null.

            Returns `true` if they are equal, `false` otherwise

            Examples:
                --------------------
                List!(int, 6) list = List!(int, 6).build(1, 2, 3);

                assert(list != null);
                assert(null != list);

                assert(list == [1, 2, 3]);
                assert([1, 2, 3] == list);

                assert(list == typeof(list).build(1, 2, 3));
                assert(typeof(list).build(1, 2, 3) == list);

                import std.range : only;
                assert(list == only(1, 2, 3));
                assert(only(1, 2, 3) == list);
                --------------------
        */
        public bool opEquals(typeof(null) nil)const scope pure nothrow @safe @nogc{
            return this.empty;
        }

        /// ditto
        public bool opEquals(R)(scope R rhs)const scope nothrow
        if(isInputRange!R){
            import std.algorithm.comparison : equal;

            return equal(this[], forward!rhs);
        }

        /// ditto
        public bool opEquals(L)(scope const auto ref L rhs)const scope nothrow
        if(isList!L){
            import std.algorithm.comparison : equal;

            return equal(this[], rhs[]);
        }




        /**
            Compares the contents of a list with another list or range.

            Examples:
                --------------------
                auto a1 = List!(int).build(1, 2, 3);
                auto a2 = List!(int).build(1, 2, 3, 4);
                auto b = List!(int).build(3, 2, 1);

                assert(a1 < b);
                assert(a1 < a2);
                assert(a2 < b);
                assert(a1 <= a1);
                --------------------
        */
        public int opCmp(R)(scope R rhs)const scope nothrow
        if(isInputRange!R){
            import std.algorithm.comparison : cmp;

            return cmp(this[], forward!rhs);
        }

        /// ditto
        public int opCmp(L)(scope const auto ref L rhs)const scope nothrow
        if(isList!L){
            import std.algorithm.comparison : cmp;

            return cmp(this[], rhs[]);
        }



        /**
            Return slice of all elements.

            The slice returned may be invalidated by further calls to other member functions that modify the object.

            Examples:
                --------------------
                List!(int) list = List!(int).build(1, 2, 3);
                --------------------
        */
        public auto opIndex(this This)()return pure nothrow @system @nogc{
            alias Range = .ListRange!(GetElementType!This, bidirectional);

            return Range(this._first);
        }



        /**
            Returns the length of the list, in terms of number of elements.

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

            static if(!hasStatelessAllocator)
                swap(this._allocator, rhs._allocator);

            swap(this._length, rhs._length);
            swap(this._first, rhs._first);
            static if(bidirectional)
                swap(this._last, rhs._last);
        }



        static if(bidirectional){
            /**
                Appends a new element to the end of the bidirectional list. The element is constructed through `emplace`.

                Parameters:
                    `args`  arguments to forward to the constructor of the element.

                Examples:
                    --------------------
                    {
                        auto list = List!(int).build(1, 2, 3);

                        list.emplaceBack(42);
                        assert(list == [1, 2, 3, 42]);

                        list.emplaceBack();
                        assert(list == [1, 2, 3, 42, 0]);
                    }

                    {
                        static struct Foo{
                            int i;
                            string str;
                        }

                        auto list = List!(Foo).build(Foo(1, "A"));

                        list.emplaceBack(2, "B");
                        assert(list == only(Foo(1, "A"), Foo(2, "B")));
                    }
                    --------------------
            */
            public ref ElementType emplaceBack(Args...)(auto ref Args args)scope return{
                ListNode* node = this._make_node(forward!args);

                node.prev = this._last;
                this._last = node;
                this._length += 1;

                return node.element;
            }
        }



        /**
            Appends a new element to the begin of the list. The element is constructed through `emplace`.

            Parameters:
                `args`  arguments to forward to the constructor of the element.

            Examples:
                --------------------
                {
                    auto list = List!(int).build(1, 2, 3);

                    list.emplaceFront(42);
                    assert(list == [42, 1, 2, 3]);

                    list.emplaceFront();
                    assert(list == [0, 42, 1, 2, 3]);
                }

                {
                    static struct Foo{
                        int i;
                        string str;
                    }

                    auto list = List!(Foo).build(Foo(1, "A"));

                    list.emplaceFront(2, "B");
                    assert(list == only(Foo(2, "B"), Foo(1, "A")));
                }
                --------------------
        */
        public ref ElementType emplaceFront(Args...)(auto ref Args args)scope return{
            ListNode* node = this._make_node(forward!args);

            node.next = this._first;
            this._first = node;
            this._length += 1;

            return node.element;
        }



        static if(bidirectional){
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

                        vec.append(only(4, 5, 6));
                        assert(vec == [1, 2, 3, 4, 5, 6]);
                    }

                    {
                        auto a = Vector!(int, 6).build(1, 2, 3);
                        auto b = Vector!(int, 6).build(4, 5, 6);

                        a.append(b);
                        assert(a == [1, 2, 3, 4, 5, 6]);
                    }

                    {
                        Vector!(int, 3) vec = Vector!(int, 3).build(1, 2, 3);
                        int[3] tmp = [4, 5, 6];
                        vec.append(tmp[]);
                        assert(vec == [1, 2, 3, 4, 5, 6]);
                    }

                    {
                        struct Range{
                            int i;

                            bool empty()(){return i == 0;}
                            int front()(){return i;}
                            void popFront()(){i -= 1;}
                            //size_t length(); //no length
                        }

                        Vector!(int, 3) vec = Vector!(int, 3).build(6, 5, 4);
                        vec.append(Range(3));
                        assert(vec == [6, 5, 4, 3, 2, 1]);
                    }
                    --------------------
            */
            public void append(R)(R range)scope
            if(isInputRange!R && is(ElementEncodingType!R : ElementType)){
                size_t len = 0;

                if(!range.empty){
                    {
                        auto node = this._make_node(range.front);

                        if(this._last is null){
                            this._last = node;
                            this._first = node;
                        }
                        else{
                            node.prev = this._last;
                            this._last = node;
                        }

                        len += 1;
                        range.popFront;
                    }


                    while(!range.empty){
                        auto node = this._make_node(range.front);

                        node.prev = this._last;
                        this._last = node;

                        len += 1;
                        range.popFront;
                    }

                    this._length += len;
                }

                return len;
            }

            /// ditto
            public size_t append(L)(scope auto ref L list)scope
            if(isList!L && is(GetElementType!L : ElementType)){
                return this.append( (()@trusted => list[] )() );
            }

            /// ditto
            public size_t append(Val)(auto ref Val val)scope
            if(is(Val : ElementType)){
                auto node = this._make_node(forward!val);

                if(this._last is null){
                    this._last = node;
                    this._first = node;
                }
                else{
                    node.prev = this._last;
                    this._last = node;
                }

                this._length += 1;
                return 1;

            }

            /+
            /// ditto
            public size_t append(Val)(auto ref Val val, const size_t count)scope
            if(is(Val : ElementType)){
                size_t len = 0;

                if(this.empty)
                if(!range.empty){
                    {
                        auto node = this._make_node(range.front);

                        if(this._last is null){
                            this._last = node;
                            this._first = node;
                        }
                        else{
                            node.prev = this._last;
                            this._last = node;
                        }

                        len += 1;
                        range.popFront;
                    }


                    while(!range.empty){
                        auto node = this._make_node(range.front);

                        node.prev = this._last;
                        this._last = node;

                        len += 1;
                        range.popFront;
                    }

                    this._length += len;
                }

                return len;
            }
            +/

        }






        static if(!allowHeap){
            private alias _allocator = statelessAllcoator!NullAllocator;
            private enum safeAllocate = true;
        }
        else static if(hasStatelessAllocator){
            public alias _allocator = statelessAllcoator!AllocatorType;

            private enum safeAllocate = isSafe!((){
                size_t capacity = size_t.max;

                cast(void)_allocator.allocate(capacity);
            });
        }
        else{
            public AllocatorType _allocator;

            private enum safeAllocate = isSafe!((ref AllocatorType a){
                size_t capacity = size_t.max;

                cast(void)a.allocate(capacity);
            });
        }

        private size_t _length;
        private ListNode* _first;
        static if(bidirectional)
            private ListNode* _last;

        private ListNode* _make_node(Args)(auto ref Args args)scope{

            ListNode* node = cast(ListNode*)_allocator.allocate(ListNode.sizeof).ptr;

            _enforce(node !is null, "allocation fail");

            static if(supportGC)
                gcAddRange(data);

            emplaceImpl(node.element, forward!args);
            node.next = null;
            static if(bidirectional)
                node.prev = null;

            return node;
        }

        private void _destroy_node()(ListNode* node)scope @trusted{
            assert(node !is null);

            destructImpl(node.element);

            void[] data = ()@trusted{
                return (cast(void*)node)[0 .. ListNode.sizeof];
            }();

            static if(supportGC)
                gcRemoveRange(data);

            static if(safeAllcoate!(typeof(_allocator)))
                const d = ()@trusted{
                    return _allocator.deallocate(data);
                }();

            else
                const d = _allocator.deallocate(data);

            _enforce(d, "deallocation fail");
        }

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

