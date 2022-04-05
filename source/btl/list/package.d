/**
    Implementation of linked list `List` (similar to c++ `std::list` and `std::forward_list`).

    License:   $(HTTP www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
    Authors:   $(HTTP github.com/submada/basic_string, Adam Búš)
*/
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
    Default allcoator for `List`.
*/
public alias DefaultAllocator = Mallocator;


/**
    True if `T` is a `List` or implicitly converts to one, otherwise false.
*/
template isList(T...)
if(T.length == 1){
    enum bool isList = is(Unqual!(T[0]) == List!Args, Args...);
}

private struct ListNode(Type, bool _bidirectional){
    public alias ElementType = Type;
    public enum bool bidirectional = _bidirectional;
    
    private Type element;
    private ListNode* next;
    static if(bidirectional)
        private ListNode* prev;

}

public template ListRange(Type, bool _bidirectional, bool _reverse = false){
    alias Node = ListNode!(Type, _bidirectional);

    struct ListRange{

        private Node* node;

        public alias Reverse = ListRange!(Type, _bidirectional, !_reverse);

        package this(N)(N* node)pure nothrow @nogc @trusted
        if(is(immutable N : immutable ListNode!(T, bd), T : const Type, bool bd)){
            static assert(is(CopyTypeQualifiers!(N, N.ElementType) : Type));
            static assert(N.bidirectional >= _bidirectional);
            this.node = cast(Node*)node;
        }

        static if(_bidirectional)
        public Reverse reverse()scope pure nothrow @safe @nogc{
            return typeof(return)(node);

        }

        public bool opEquals(const typeof(null))scope const pure nothrow @safe @nogc{
            return (this.node is null);
        }

        public bool opEquals(N)(scope const N* node)scope const pure nothrow @safe @nogc
        if(is(immutable N : immutable ListNode!(T, bd), T, bool bd)){
            return (this.node is node);
        }

        public bool opEquals(R)(scope auto ref R rhs)scope const pure nothrow @safe @nogc
        if(is(immutable R : immutable ListRange!(T, bd, r), T, bool bd, bool r)){
            return (this.node is rhs.node);
        }

        public bool empty()scope const pure nothrow @nogc @safe{
            return (node is null);
        }

        public ref inout(Type) front()inout scope return pure nothrow @nogc @safe{
            assert(node !is null);
            return node.element;
        }

        public Type moveFront()(){
            assert(node !is null);
            return move(node.element);
        }

        public template opUnary(string op : "*")
        if(op == "*"){  //doc
            alias opUnary = front;
        }


        public void popFront()scope pure nothrow @nogc @safe{
            assert(node !is null);
            static if(_reverse){
                static assert(_bidirectional);
                node = node.prev;
            }
            else
                node = node.next;
        }

        public template opBinary(string op : "++")
        if(op == "++"){  //doc
            alias opBinary = popFront;
        }

        static if(_bidirectional){
            public void popBack()scope pure nothrow @nogc @safe{
                assert(node !is null);
                static if(_reverse)
                    node = node.next;
                else
                    node = node.prev;
            }


            public template opBinary(string op : "--")
            if(op == "--"){  //doc
                alias opBinary = popBack;
            }
        }

    }
}



/**
    `List` is a container that supports constant time insertion and removal of elements from anywhere in the container.

    Fast random access is not supported. It is usually implemented as a linked list

    Template parameters:

        `_Type` = element type.

        `_Allocator` = Type of the allocator object used to define the storage allocation model. By default `DefaultAllocator` is used.

        `_supportGC`

        `_bidirectional`
*/
public template List(
    _Type,
    _Allocator = DefaultAllocator,
    bool _supportGC = shouldAddGCRange!_Type,
    bool _bidirectional = true,
){

    import core.lifetime : emplace, forward, move;
    import std.range : empty, front, popFront, isInputRange, ElementEncodingType, hasLength;
    import std.traits : Unqual, hasElaborateDestructor, hasIndirections, isDynamicArray, isSafe;

    alias ListNode = .ListNode!(_Type, _bidirectional);
    alias ListRange = .ListRange!(_Type, _bidirectional);

    enum bool _hasStatelessAllocator = isStatelessAllocator!_Allocator;

    struct List{

        private alias Node = ListNode;



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
            Iterator for list.
        */
        public alias Iterator = .ListRange!(ElementType, bidirectional);



        /**
            Const iterator for list.
        */
        public alias ConstIterator = .ListRange!(const(ElementType), bidirectional);



        /**
            Returns copy of allocator.
        */
        public @property CopyTypeQualifiers!(This, AllocatorType) allocator(this This)()scope{
            return *(()@trusted => &this._allocator )();
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
            assert((this._first is null) == (this._last is null));
            return (this._first is null);
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
        */
        public @property auto begin(this This)()scope pure nothrow @system @nogc{
            alias Range = .ListRange!(GetElementType!This, bidirectional);
            return Range(this._first);
        }



        /**
        */
        public @property ConstIterator cbegin()const scope pure nothrow @system @nogc{
            return ConstIterator(this._first);
        }



        /**
        */
        public enum typeof(null) end = null;



        /**
            Destroys the `List` object.

            This deallocates all the storage capacity allocated by the `List` using its allocator.
        */
        public ~this()scope{
            debug{
                this.release();
            }
            else{
                this._release_impl();
            }
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

                Node* node = this._first;
                auto range = rhs._op_slice();

                while(node !is null && !range.empty){
                    node.element = move(range.front);
                    node = node.next;
                    range.popFront;
                }

                while(!range.empty){
                    node = this._make_node(move(range.front));

                    this._push_back_node!true(node);

                    this._length += 1;
                    range.popFront;
                }
            }
            //copy:
            else{
                static if(hasStatelessAllocator || Rhs.hasStatelessAllocator)
                    this(rhs._op_slice);
                else
                    this(rhs._op_slice, rhs._allocator);
            }
        }



        /**
            Constructs a bidirectional `List` object from range of elements.

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
        public this(R, this This)(R range, AllocatorType allcoator)return
        if(isInputRange!R && is(ElementEncodingType!R : GetElementType!This)){
            static if(!hasStatelessAllocator)
                this._allocator = forward!allcoator;

            this._init_from_range(forward!range);
        }

        private void _init_from_range(R, this This)(R range)scope
        if(isInputRange!R && is(ElementEncodingType!R : GetElementType!This)){
            auto self = (()@trusted => (cast(Unqual!This*)&this) )();

            self.pushBack(forward!range);
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
        if(!isList!R && isInputRange!R && is(ElementEncodingType!R : ElementType)){
            Node* node = this._first;
            while(node !is null && !range.empty){
                node.element = range.front;
                node = node.next;
                range.popFront;
            }

            this.pushBack(forward!range);
        }

        /// ditto
        public void opAssign(Rhs)(scope auto ref Rhs rhs)scope
        if(isList!Rhs && isAssignable!(Rhs, typeof(this)) ){
            ///move:
            static if(isMoveAssignable!(rhs, typeof(this))){
                static if(!hasStatelessAllocator)
                    this._allocator = move(rhs._allocator);

                this._length = rhs._length;
                rhs._length = 0;

                this._last = rhs._last;
                rhs._last = null;

                this._first = rhs._first;
                rhs._first = null;

            }
            else static if(!isRef!rhs
                && isMoveAssignableElement!(GetElementType!Rhs, ElementType)
            ){
                Node* node = this._first;
                auto range = rhs._op_slice();

                while(node !is null && !range.empty){
                    node.element = move(range.front);
                    node = node.next;
                    range.popFront;
                }

                while(!range.empty){
                    node = this._make_node(move(range.front));

                    this._push_back_node!true(node);

                    this._length += 1;
                    range.popFront;
                }
            }
            else{
                this.opAssign(rhs._op_slice);
            }
        }



        /**
            Erases and deallocate the contents of the `List`, which becomes an empty list (with a length of 0 elements).

            Same as `clear`.

            Examples:
                --------------------
                List!(int) list = List!(int).build(1, 2, 3);
                assert(list.length == 3);

                list.release();
                assert(list.length == 0);
                --------------------
        */
        public void release()()scope nothrow{
            this._release_impl();

            this._first = null;
            this._last = null;

            this._length = 0;
        }

        private void _release_impl()()scope nothrow{
            ListNode* node = this._first;

            while(node !is null){
                ListNode* tmp = node;
                node = node.next;
                this._destroy_node(tmp);
            }
        }



        /**
            Erases and deallocate the contents of the `List`, which becomes an empty list (with a length of 0 elements).

            Same as `release`.

            Examples:
                --------------------
                List!(int) list = List!(int).build(1, 2, 3);
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
            foreach(ref e; this._op_slice ){
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
                List!(int) list = List!(int).build(1, 2, 3);

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
        if(isInputRange!R && !isList!R){
            import std.algorithm.comparison : equal;

            return equal(this._op_slice, forward!rhs);
        }

        /// ditto
        public bool opEquals(L)(scope const auto ref L rhs)const scope nothrow
        if(isList!L){
            import std.algorithm.comparison : equal;

            return equal(this._op_slice, rhs._op_slice);
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
        if(isInputRange!R && !isList!R){
            import std.algorithm.comparison : cmp;

            return cmp(this._op_slice, forward!rhs);
        }

        /// ditto
        public int opCmp(L)(scope const auto ref L rhs)const scope nothrow
        if(isList!L){
            import std.algorithm.comparison : cmp;

            return cmp(this._op_slice, rhs._op_slice);
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
            return this._op_slice();
        }

        private @property _op_slice(this This)()return pure nothrow @trusted @nogc{
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
                auto a = List!(int).build(1, 2, 3);
                auto b = List!(int).build(4, 5, 6);

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
            swap(this._last, rhs._last);
        }



        /**
            Returns a reference to the first element in the list.

            Calling this function on an empty container causes null dereference.
        */
        public ref inout(ElementType) front()inout return pure nothrow @system @nogc{
            assert(this._first !is null);
            return this._first.element;
        }



        /**
            Returns a copy of the first element in the list.

            Calling this function on an empty container causes null dereference.

            Examples:
                --------------------
                auto list = List!(int).build(1, 2, 3);

                assert(list.frontCopy == 1);
                assert(list == [1, 2, 3]);
                --------------------
        */
        public auto frontCopy(this This)()scope{
            assert(this._first !is null);

            return this._first.element;
        }



        /**
            Move of the first element in the list and return it.

            Calling this function on an empty container causes null dereference.

            Examples:
                --------------------
                auto list = List!(int).build(1, 2, 3);

                assert(list.moveFront == 1);
                list.popFront;
                assert(list == [2, 3]);
                --------------------
        */
        public ElementType moveFront()scope pure nothrow @safe @nogc{
            assert(this._first !is null);

            return move(this._first.element);
        }



        /**
            Pop the last element of the bidirectional list, effectively reducing its length by 1.

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

                assert(list.popFront(int.init) == int.init);
                assert(list.empty);

                assert(list.popFront(42) == 42);
                assert(list.empty);
                --------------------
        */
        public auto popFront(T = Unqual!ElementType)()scope nothrow
        if(is(T == Unqual!ElementType) || is(T == void)){
            assert(!this.empty);
            return _pop_front_impl!T();
        }

        ///ditto
        public ElementType popFront(T : Unqual!ElementType = Unqual!ElementType)(ElementType def)scope nothrow{
            return (this.empty)
                ? forward!def
                : _pop_front_impl!T();
        }
        
        private auto _pop_front_impl(T)()scope nothrow
        if(is(T == Unqual!ElementType) || is(T == void)){
            ListNode* node = this._first;
            this._first = this._first.next;

            if(this._first is null){
                this._last = null;
            }
            else{
                static if(bidirectional)
                    this._first.prev = null;
            }


            static if(is(T == void)){
                destructImpl(*node);
                this._length -= 1;
            }
            else{
                ElementType result = move(node.element);
                destructImpl(*node);

                this._length -= 1;
                return move(result);
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
        public void emplaceFront(Args...)(auto ref Args args)scope{
            ListNode* node = this._make_node(forward!args);

            this._push_front_node(node);
            this._length += 1;
        }



        /**
            Extends the `List` by appending additional elements at the end of list.

            Parameters:
                `val` appended value.

                `list` appended list.

                `range` appended input renge.

                `count` Number of times `val` is appended.

            Examples:
                --------------------
                {
                    auto list = List!(int).build(1, 2, 3);

                    list.pushFront(42);
                    assert(list == [42, 1, 2, 3]);
                }

                {
                    auto list = List!(int).build(1, 2, 3);

                    list.pushFront(only(4, 5, 6));
                    assert(list == [6, 5, 4, 1, 2, 3]);
                }

                {
                    auto a = List!(int).build(1, 2, 3);
                    auto b = List!(int).build(4, 5, 6);

                    a.pushFront(b);
                    assert(a == [6, 5, 4, 1, 2, 3]);
                }

                {
                    List!(int) list = List!(int).build(1, 2, 3);
                    int[3] tmp = [4, 5, 6];
                    list.pushFront(tmp[]);
                    assert(list == [6, 5, 4, 1, 2, 3]);
                }

                {
                    struct Range{
                        int i;

                        bool empty()(){return i == 0;}
                        int front()(){return i;}
                        void popFront()(){i -= 1;}
                        //size_t length(); //no length
                    }

                    List!(int) list = List!(int).build(6, 5, 4);
                    list.pushFront(Range(3));
                    assert(list == [1, 2, 3, 6, 5, 4]);
                }
                --------------------
        */
        public size_t pushFront(R)(R range)scope
        if(isInputRange!R && is(ElementEncodingType!R : ElementType)){
            size_t len = 0;

            if(!range.empty){
                scope(exit){
                    this._length += len;
                }

                {
                    auto node = this._make_node(range.front);

                    this._push_front_node(node);

                    len += 1;
                    range.popFront;
                }


                while(!range.empty){
                    auto node = this._make_node(range.front);

                    this._push_front_node!true(node);

                    len += 1;
                    range.popFront;
                }
            }

            return len;
        }

        /// ditto
        public size_t pushFront(L)(scope auto ref L list)scope
        if(isList!L && is(GetElementType!L : ElementType)){
            return this.pushFront(list._op_slice);
        }

        /// ditto
        public size_t pushFront(Val)(auto ref Val val)scope
        if(is(Val : ElementType)){
            auto node = this._make_node(forward!val);

            this._push_front_node(node);

            this._length += 1;
            return 1;

        }

        /// ditto
        public size_t pushFront(Val)(auto ref Val val, const size_t count)scope
        if(is(Val : ElementType)){
            size_t len = 0;

            scope(exit){
                this._length += len;
            }
            
            if(count != 0){
                auto node = this._make_node(val);

                this._push_front_node(node);
                len += 1;
            }

            if(count != len){
                for(; len < count; ++len){
                    auto node = this._make_node(val);

                    this._push_front_node!true(node);
                }
            }

            return len;
        }

        

        /**
            Alias to pushFront
        */
        public alias prepend = pushFront;




        /**
            Returns a reference to the last element in the list.

            Calling this function on an empty container causes null dereference.
        */
        public ref inout(ElementType) back()inout return pure nothrow @system @nogc{
            assert(this._last !is null);
            return this._last.element;
        }



        /**
            Returns a copy of the first element in the list.

            Calling this function on an empty container causes null dereference.

            Examples:
                --------------------
                auto list = List!(int).build(1, 2, 3);

                assert(list.backCopy == 3);
                assert(list == [1, 2, 3]);
                --------------------
        */
        public auto backCopy(this This)()scope {
            assert(this._last !is null);

            return this._last.element;
        }



        /**
            Move of the first element in the list and return it.

            Calling this function on an empty container causes null dereference.

            Examples:
                --------------------
                auto list = List!(int).build(1, 2, 3);

                assert(list.moveBack == 3);
                list.popBack;
                assert(list == [1, 2]);
                --------------------
        */
        public ElementType moveBack()scope pure nothrow @safe @nogc{
            assert(this._last !is null);

            return move(this._last.element);
        }



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

                assert(list.popBack(int.init) == int.init);
                assert(list.empty);

                assert(list.popBack(42) == 42);
                assert(list.empty);
                --------------------
        */
        public auto popBack(T = Unqual!ElementType)()scope nothrow
        if(is(T == Unqual!ElementType) || is(T == void)){
            assert(!this.empty);
            return _pop_back_impl!T();
        }

        ///ditto
        public auto popBack(T : Unqual!ElementType = Unqual!ElementType)(ElementType def)scope nothrow{
            return this.empty
                ? move(def)
                : _pop_back_impl!T();
        }

        private auto _pop_back_impl(T)()scope nothrow
        if(is(T == Unqual!ElementType) || is(T == void)){
            assert(!this.empty);

            ListNode* node = this._last;
            this._last = this._last.prev;

            if(this._last is null)
                this._first = null;
            else
                this._last.next = null;

            static if(is(T == void)){
                destructImpl(*node);
                this._length -= 1;
            }
            else{
                ElementType result = move(node.element);
                destructImpl(*node);

                this._length -= 1;
                return move(result);
            }
        }



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
        public void emplaceBack(Args...)(auto ref Args args)scope return{
            ListNode* node = this._make_node(forward!args);

            this._push_back_node(node);
            this._length += 1;
        }



        /**
            Extends the `List` by appending additional elements at the end of list.

            Parameters:
                `val` appended value.

                `list` appended list.

                `range` appended input renge.

                `count` Number of times `val` is appended.

            Examples:
                --------------------
                {
                    auto list = List!(int).build(1, 2, 3);

                    list.pushBack(42);
                    assert(list == [1, 2, 3, 42]);
                }

                {
                    auto list = List!(int).build(1, 2, 3);

                    list.pushBack(only(4, 5, 6));
                    assert(list == [1, 2, 3, 4, 5, 6]);
                }

                {
                    auto a = List!(int).build(1, 2, 3);
                    auto b = List!(int).build(4, 5, 6);

                    a.pushBack(b);
                    assert(a == [1, 2, 3, 4, 5, 6]);
                }

                {
                    List!(int) list = List!(int).build(1, 2, 3);
                    int[3] tmp = [4, 5, 6];
                    list.pushBack(tmp[]);
                    assert(list == [1, 2, 3, 4, 5, 6]);
                }

                {
                    struct Range{
                        int i;

                        bool empty()(){return i == 0;}
                        int front()(){return i;}
                        void popFront()(){i -= 1;}
                        //size_t length(); //no length
                    }

                    List!(int) list = List!(int).build(6, 5, 4);
                    list.pushBack(Range(3));
                    assert(list == [6, 5, 4, 3, 2, 1]);
                }
                --------------------
        */
        public size_t pushBack(R)(R range)scope
        if(!isList!R && isInputRange!R && is(ElementEncodingType!R : ElementType)){
            size_t len = 0;

            if(!range.empty){
                scope(exit){
                    this._length += len;
                }

                {
                    auto node = this._make_node(range.front);

                    this._push_back_node(node);

                    len += 1;
                    range.popFront;
                }


                while(!range.empty){
                    auto node = this._make_node(range.front);

                    this._push_back_node!true(node);

                    len += 1;
                    range.popFront;
                }
            }

            return len;
        }

        /// ditto
        public size_t pushBack(L)(scope auto ref L list)scope
        if(isList!L && is(GetElementType!L : ElementType)){
            return this.pushBack(list._op_slice);
        }

        /// ditto
        public size_t pushBack(Val)(auto ref Val val)scope
        if(is(Val : ElementType)){
            auto node = this._make_node(forward!val);

            this._push_back_node(node);

            this._length += 1;
            return 1;

        }

        /// ditto
        public size_t pushBack(Val)(auto ref Val val, const size_t count)scope
        if(is(Val : ElementType)){
            size_t len = 0;
            scope(exit){
                this._length += len;
            }

            if(count != 0){
                auto node = this._make_node(val);

                this._push_back_node(node);
                len += 1;
            }

            if(count != len){
                for(; len < count; ++len){
                    auto node = this._make_node(val);

                    this._push_back_node!true(node);
                }
            }

            return len;
        }



        /**
            Alias to pushBack
        */
        public alias append = pushBack;



        /**
            Operator `~=` is same as append/pushBack
        */
        public template opOpAssign(string op)
        if(op == "~"){
            alias opOpAssign = pushBack;
        }



        /**
            put
        */
        public alias put = pushBack;



        /**
            Static function which return `List` construct from arguments `args`.

            Parameters:
                `allocator` exists only if template parameter `_Allocator` has state.

                `args` values of type `ElementType`, input range or `List`.

            Examples:
                --------------------
                import std.range : only;

                int[2] tmp = [3, 4];
                auto list = List!(int).build(1, 2, tmp[], only(5, 6), List!(int).build(7, 8));
                assert(list == [1, 2, 3, 4, 5, 6, 7, 8]);
                --------------------
        */
        public static typeof(this) build(Args...)(auto ref Args args){
            import core.lifetime : forward;

            auto result = List.init;

            result._build_impl(forward!args);

            return ()@trusted{
                return *&result;
            }();
        }

        /// ditto
        public static typeof(this) build(Args...)(AllocatorType allocator, auto ref Args args){
            import core.lifetime : forward;

            auto result = (()@trusted => List(forward!allocator))();

            result._build_impl(forward!args);

            return ()@trusted{
                return *&result;
            }();
        }

        private void _build_impl(Args...)(auto ref Args args)scope{
            import std.traits : isArray;

            static foreach(alias arg; args)
                this.pushBack(forward!arg);
        }





        //internals:
        static if(hasStatelessAllocator){
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
        private ListNode* _last;

        private ListNode* _make_node(Args...)(auto ref Args args)scope{

            ListNode* node = ()@trusted{
                return cast(ListNode*)_allocator.allocate(ListNode.sizeof).ptr;
            }();

            _enforce(node !is null, "allocation fail");

            static if(supportGC)
                gcAddRange(node, ListNode.sizeof);

            emplaceImpl(node.element, forward!args);
            node.next = null;
            static if(bidirectional)
                node.prev = null;

            return node;
        }

        private void _destroy_node()(ListNode* node)scope nothrow{
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


        //enforce:
        private void _enforce(bool con, string msg)const pure nothrow @safe @nogc{
            if(!con)assert(0, msg);
        }

        private void _push_front_node(bool not_empty = false)(scope ListNode* node)scope pure nothrow @trusted @nogc{
            assert(node !is null);
            static if(not_empty)
                assert(!this.empty);

            const bool is_empty = not_empty
                ? false
                : (this._first is null);

            if(is_empty){
                this._last = node;
            }
            else{
                node.next = this._first;
                static if(bidirectional)
                    this._first.prev = node;
            }

            this._first = node;
        }

        private void _push_back_node(bool not_empty = false)(scope ListNode* node)scope pure nothrow @trusted @nogc{
            assert(node !is null);
            static if(not_empty)
                assert(!this.empty);

            const bool is_empty = not_empty
                ? false
                : (this._first is null);
            
            if(is_empty){
                this._first = node;
            }
            else{
                static if(bidirectional)
                    node.prev = this._last;

                this._last.next = node;
            }

            this._last = node;
        }

    }
}


///
unittest{
    import std.range : only;
    import std.algorithm : map, equal;

    static struct Foo{
        int i;
        string str;
    }

    List!(Foo) list;

    assert(list.empty);

    list.append(Foo(1, "A"));
    assert(list.length == 1);

    list.append(only(Foo(2, "B"), Foo(3, "C")));
    assert(list.length == 3);

    list.emplaceBack(4, "D");
    assert(list.length == 4);


    list = List!(Foo).build(Foo(-1, "X"), Foo(-2, "Y"));
    assert(equal(list[].map!(e => e.str), only("X", "Y")));

    list.release();
    assert(list.length == 0);

}


/// Alias to `List` with parameter `_bidirectional = true` (single linked list)
public template ForwardList(
    _Type,
    _Allocator = DefaultAllocator,
    bool _supportGC = shouldAddGCRange!_Type
){
    alias ForwardList = .List!(_Type, _Allocator, _supportGC, false);
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
            && (From.bidirectional == To.bidirectional)
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
            && (From.bidirectional == To.bidirectional)
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

//List examples:
version(unittest){

    import std.range : only;
    static foreach(alias List; AliasSeq!(.List)){

        //List.empty
        pure nothrow @safe @nogc unittest{
            List!(int) list;
            assert(list.empty);

            list.append(42);
            assert(!list.empty);
        }

        //List.length
        pure nothrow @safe @nogc unittest{
            List!(int) list = null;
            assert(list.length == 0);

            list.append(42);
            assert(list.length == 1);

            list.append(123);
            assert(list.length == 2);

            list.clear();
            assert(list.length == 0);
        }

        //List.ctor(allocator)
        pure nothrow @safe @nogc unittest{
            {
                List!(int) list = DefaultAllocator.init;
                assert(list.empty);
            }
        }

        //List.ctor(null)
        pure nothrow @safe @nogc unittest{
            {
                List!(int) list = null;
                assert(list.empty);
            }
        }

        //List.ctor(list)
        pure nothrow @safe @nogc unittest{
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
        }

        //List.ctor(range)
        pure nothrow @safe @nogc unittest{
            import std.range : iota;
            {
                List!(int) list = iota(0, 5);
                assert(list == [0, 1, 2, 3, 4]);
            }
        }

        //List.opAssign
        pure nothrow @safe @nogc unittest{
            List!(int) list = List!(int).build(1, 2, 3);
            assert(!list.empty);

            list = null;
            assert(list.empty);

            list = List!(int).build(3, 2, 1);
            assert(list == [3, 2, 1]);

            list = List!(int).build(4, 2);
            assert(list == [4, 2]);
        }

        //List.release
        pure nothrow @safe @nogc unittest{
            List!(int) list = List!(int).build(1, 2, 3);
            assert(list.length == 3);

            list.release();
            assert(list.length == 0);
        }

        //List.clear
        pure nothrow @safe @nogc unittest{
            List!(int) list = List!(int).build(1, 2, 3);
            assert(list.length == 3);

            list.clear();
            assert(list.length == 0);
        }

        //List.contains
        pure nothrow @safe @nogc unittest{
            List!(int) list = List!(int).build(1, 2, 3);

            assert(list.contains(1));
            assert(!list.contains(42L));
        }

        //List.opBinaryRight!"in"
        pure nothrow @safe @nogc unittest{
            List!(int) list = List!(int).build(1, 2, 3);

            assert(1 in list);
            assert(42L !in list);
        }

        //List.opEquals
        pure nothrow @safe @nogc unittest{
            List!(int) list = List!(int).build(1, 2, 3);

            assert(list != null);
            assert(null != list);

            assert(list == [1, 2, 3]);
            assert([1, 2, 3] == list);

            assert(list == typeof(list).build(1, 2, 3));
            assert(typeof(list).build(1, 2, 3) == list);

            import std.range : only;
            assert(list == only(1, 2, 3));
            assert(only(1, 2, 3) == list);
        }

        //List.opCmp
        pure nothrow @safe @nogc unittest{
            auto a1 = List!(int).build(1, 2, 3);
            auto a2 = List!(int).build(1, 2, 3, 4);
            auto b = List!(int).build(3, 2, 1);

            assert(a1 < b);
            assert(a1 < a2);
            assert(a2 < b);
            assert(a1 <= a1);
        }

        //List.opIndex
        pure nothrow @safe @nogc unittest{
            List!(int) list = List!(int).build(1, 2, 3);
        }

        //List.proxySwap
        pure nothrow @safe @nogc unittest{
            auto a = List!(int).build(1, 2, 3);
            auto b = List!(int).build(4, 5, 6);

            a.proxySwap(b);
            assert(a == [4, 5, 6]);
            assert(b == [1, 2, 3]);

            import std.algorithm.mutation : swap;

            swap(a, b);
            assert(a == [1, 2, 3]);
            assert(b == [4, 5, 6]);
        }

        //List.frontCopy
        pure nothrow @safe @nogc unittest{
            auto list = List!(int).build(1, 2, 3);

            assert(list.frontCopy == 1);
            assert(list == [1, 2, 3]);
        }

        //List.moveFront
        pure nothrow @safe @nogc unittest{
            auto list = List!(int).build(1, 2, 3);

            assert(list.moveFront == 1);
            list.popFront;
            assert(list == [2, 3]);
        }

        //List.popFront
        pure nothrow @safe @nogc unittest{
            List!(int) list = List!(int).build(30, 20, 10);
            assert(list.length == 3);

            assert(list.popFront == 30);
            assert(list.length == 2);

            assert(list.popFront == 20);
            assert(list.length == 1);

            assert(list.popFront == 10);
            assert(list.empty);

            assert(list.popFront(int.init) == int.init);
            assert(list.empty);

            assert(list.popFront(42) == 42);
            assert(list.empty);
        }

        //List.emplaceFront
        pure nothrow @safe @nogc unittest{
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
        }

        //List.pushFront
        pure nothrow @safe @nogc unittest{
            {
                auto list = List!(int).build(1, 2, 3);

                list.pushFront(42);
                assert(list == [42, 1, 2, 3]);
            }

            {
                auto list = List!(int).build(1, 2, 3);

                list.pushFront(only(4, 5, 6));
                assert(list == [6, 5, 4, 1, 2, 3]);
            }

            {
                auto a = List!(int).build(1, 2, 3);
                auto b = List!(int).build(4, 5, 6);

                a.pushFront(b);
                assert(a == [6, 5, 4, 1, 2, 3]);
            }

            {
                List!(int) list = List!(int).build(1, 2, 3);
                int[3] tmp = [4, 5, 6];
                list.pushFront(tmp[]);
                assert(list == [6, 5, 4, 1, 2, 3]);
            }

            {
                struct Range{
                    int i;

                    bool empty()(){return i == 0;}
                    int front()(){return i;}
                    void popFront()(){i -= 1;}
                    //size_t length(); //no length
                }

                List!(int) list = List!(int).build(6, 5, 4);
                list.pushFront(Range(3));
                assert(list == [1, 2, 3, 6, 5, 4]);
            }
        }

        //List.backCopy
        pure nothrow @safe @nogc unittest{
            auto list = List!(int).build(1, 2, 3);

            assert(list.backCopy == 3);
            assert(list == [1, 2, 3]);
        }

        //List.moveBack
        pure nothrow @safe @nogc unittest{
            auto list = List!(int).build(1, 2, 3);

            assert(list.moveBack == 3);
            list.popBack;
            assert(list == [1, 2]);
        }

        //List.popBack
        pure nothrow @safe @nogc unittest{
            List!(int) list = List!(int).build(10, 20, 30);
            assert(list.length == 3);

            assert(list.popBack == 30);
            assert(list.length == 2);

            assert(list.popBack == 20);
            assert(list.length == 1);

            assert(list.popBack == 10);
            assert(list.empty);

            assert(list.popBack(int.init) == int.init);
            assert(list.empty);

            assert(list.popBack(42) == 42);
            assert(list.empty);
        }

        //List.emplaceBack
        pure nothrow @safe @nogc unittest{
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
        }

        //List.pushBack
        pure nothrow @safe @nogc unittest{
            {
                auto list = List!(int).build(1, 2, 3);

                list.pushBack(42);
                assert(list == [1, 2, 3, 42]);
            }

            {
                auto list = List!(int).build(1, 2, 3);

                list.pushBack(only(4, 5, 6));
                assert(list == [1, 2, 3, 4, 5, 6]);
            }

            {
                auto a = List!(int).build(1, 2, 3);
                auto b = List!(int).build(4, 5, 6);

                a.pushBack(b);
                assert(a == [1, 2, 3, 4, 5, 6]);
            }

            {
                List!(int) list = List!(int).build(1, 2, 3);
                int[3] tmp = [4, 5, 6];
                list.pushBack(tmp[]);
                assert(list == [1, 2, 3, 4, 5, 6]);
            }

            {
                struct Range{
                    int i;

                    bool empty()(){return i == 0;}
                    int front()(){return i;}
                    void popFront()(){i -= 1;}
                    //size_t length(); //no length
                }

                List!(int) list = List!(int).build(6, 5, 4);
                list.pushBack(Range(3));
                assert(list == [6, 5, 4, 3, 2, 1]);
            }
        }

        //List.build
        pure nothrow @safe @nogc unittest{
            import std.range : only;

            int[2] tmp = [3, 4];
            auto list = List!(int).build(1, 2, tmp[], only(5, 6), List!(int).build(7, 8));
            assert(list == [1, 2, 3, 4, 5, 6, 7, 8]);
        }
    }


}
